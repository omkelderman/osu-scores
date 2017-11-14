{logger, submitLogger} = require '../Logger'

config = require 'config'
express = require 'express'
multer = require 'multer'
MulterOsrMemoryStorage = require '../MulterOsrMemoryStorage'
OsuScoreBadgeCreator = require '../OsuScoreBadgeCreator'
OsuApi = require '../OsuApi'
CoverCache = require '../CoverCache'
OsuMods = require '../OsuMods'
OsuAcc = require '../OsuAcc'
uuidV4 = require 'uuid/v4'
path = require 'path'
fs = require 'fs'
PathConstants = require '../PathConstants'
_ = require './_shared'
DiscordWebhookShooter = require '../DiscordWebhookShooter'

MYSQL_DATE_STRING_REGEX = /^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$/
ISO_UTC_DATE_STRING_REGEX = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z$/

postDiscordWebhook = (artist, title, creator, diff, beatmapId, date, imageUrl, username, userId) ->
    webhook =
        username: 'Look At My Score'
        content: 'New image just got generated!'
        embeds: [{
            title: "#{artist} - #{title} (#{creator}) [#{diff}]"
            description: '_[LookAtMySco.re](https://lookatmysco.re/)_'
            timestamp: date
            image:
                url: imageUrl
            footer:
                text: 'Generated'
            author:
                name: username
        }]

    if beatmapId
        webhook.embeds[0].url = 'https://osu.ppy.sh/b/' + beatmapId
    if userId
        webhook.embeds[0].author.url = 'https://osu.ppy.sh/u/' + userId
        webhook.embeds[0].author.icon_url = 'https://a.ppy.sh/' + userId

    DiscordWebhookShooter.shoot webhook


convertDateStringToDateObject = (str) ->
    # lets trim cuz why not
    str = str.trim()

    # convert str into a date object.
    # two formats allowed:
    #   - a mysql-date-string (xxxx-xx-xx xx:xx:xx), asume +8 timezone like osu api
    #   - ISO UTC string (xxxx-xx-xxTxx:xx:xx[.xxx]Z)
    if MYSQL_DATE_STRING_REGEX.test str
        # is mysql-date, lets convert it to an ISO string
        str = str.replace(' ', 'T')+'+08:00'
    else if not ISO_UTC_DATE_STRING_REGEX.test str
        # both not mysql date or iso date string, abort
        return null

    # convert to date object
    date = new Date str

    # the original string had a sortof valid ISO date format, but no idea yet if it is an actual valid date, so lets do a final check on that
    if isNaN date.getTime()
        # invalid date!
        return null

    # valid date!
    return date

router = express.Router()

router.get '/test', (req, res, next) ->
    res.json
        a: 'OK'

handleSubmitError = (nextHandler, req, err) ->
    submitLogger.warn {req: req, ip: req.ip, body: req.body, err: err}, 'submit error'
    nextHandler err

handleSubmitSuccess = (req, res, data) ->
    submitLogger.info {req: req, ip: req.ip, body: req.body, data: data}, 'submit success'
    res.json data


renderImageResponse = (req, res, next, coverJpg, beatmap, gameMode, score) ->
    # create the thing :D
    imageId = uuidV4()
    createdDate = new Date()
    tmpPngLocation = path.resolve PathConstants.tmpDir, imageId + '.png'

    await OsuScoreBadgeCreator.create coverJpg, beatmap, gameMode, score, tmpPngLocation, defer err, stdout, stderr, gmCommand
    # if img gen failed, lets imidiately return
    return handleSubmitError next, req, _.internalServerError 'error while generating image', err, {stdout: stdout, stderr: stderr, gmCommand: gmCommand} if err

    # img created, now move to correct location
    pngLocation = path.resolve PathConstants.dataDir, imageId + '.png'
    await fs.rename tmpPngLocation, pngLocation, defer err
    return handleSubmitError next, req, _.internalServerError 'error while moving png file', err if err

    # also write a json-file with the meta-data
    jsonLocation = path.resolve PathConstants.dataDir, imageId + '.json'
    outputData =
        date: createdDate
        id: imageId
        mode: gameMode
        beatmap: beatmap
        score: score
    await fs.writeFile jsonLocation, JSON.stringify(outputData), defer err
    return handleSubmitError next, req, _.internalServerError 'error while writing json file to disk', err if err

    resultUrl = config.get 'image-result-url'
        .replace '{protocol}', req.protocol
        .replace '{host}', req.get 'host'
        .replace '{image-id}', imageId

    logger.info 'CREATED:', imageId
    handleSubmitSuccess req, res,
        result: 'image'
        image:
            id: imageId
            url: resultUrl

    postDiscordWebhook beatmap.artist, beatmap.title, beatmap.creator, beatmap.version, beatmap.beatmap_id, createdDate, resultUrl, score.username, score.user_id

router.post '/submit', (req, res, next) ->
    # required:
    #  - beatmap_id  OR   beatmap
    #  - username    OR   score
    # only required if beatmap is supplied instead of beatmap_id, altho it is ofc always possible to override (for converts):
    #  - mode
    if not(req.body.beatmap_id? or req.body.beatmap?)
        return handleSubmitError next, req, _.badRequest 'missing either beatmap_id or beatmap object'

    if not(req.body.username? or req.body.score?)
        return handleSubmitError next, req, _.badRequest 'missing either username or score object'

    if req.body.beatmap? and not req.body.mode
        return handleSubmitError next, req, _.badRequest 'when using custom beatmap object, mode is required'

    gameMode = req.body.mode

    # get beatmap
    if req.body.beatmap_id?
        # get beatmap
        await OsuApi.getBeatmap req.body.beatmap_id, gameMode, defer err, beatmap
        return handleSubmitError next, req, _.osuApiServerError err if err
        return handleSubmitError next, req, _.notFound 'beatmap does not exist' if not beatmap

        if not gameMode?
            # mode was not supplied, get it from beatmap object
            gameMode = beatmap.mode
    else
        # no beatmap_id, so beatmap object must be supplied
        return handleSubmitError next, req, _.badRequest 'beatmap parameters not valid' if not OsuScoreBadgeCreator.isValidBeatmapObj req.body.beatmap
        beatmap = req.body.beatmap

    # get score
    if req.body.username?
        await OsuApi.getScores beatmap.beatmap_id, gameMode, req.body.username, defer err, scores
        return handleSubmitError next, req, _.osuApiServerError err if err
        if not scores or scores.length is 0
            return handleSubmitError next, req, _.notFound 'user does not exist, or does not have a score on the selected beatmap'

        if scores.length > 1
            # oh no, multiple scores, dunno what to do, ask user
            scores.sort (a, b) -> b.date - a.date
            logger.info 'MULTIPLE SCORES'
            return handleSubmitSuccess req, res,
                result: 'multiple-scores'
                data:
                    beatmap_id: beatmap.beatmap_id
                    mode: gameMode
                    scores: scores
                    textData: scores.map (score) ->
                        return [
                            score.date.toISOString().replace(/T/, ' ').replace(/\..+/, '') + ' UTC'
                            score.score
                            OsuAcc.getAccStr(gameMode, score) + '%'
                            score.maxcombo
                            (+score.pp).toFixed(2) + ' pp'
                            OsuMods.toModsStrLong(score.enabled_mods)
                        ]

        score = scores[0]
    else
        # no username, so score object must be supplied
        return handleSubmitError next, req, _.badRequest 'score parameters not valid' if not OsuScoreBadgeCreator.isValidScoreObj req.body.score
        score = req.body.score
        score.date = convertDateStringToDateObject score.date
        return handleSubmitError next, req, _.badRequest 'date value is invalid' if not score.date

    # grab the new.ppy.sh cover of the beatmap to start with
    await CoverCache.grabCoverFromOsuServer beatmap.beatmapset_id, defer err, coverJpg
    return handleSubmitError next, req, _.coverError err if err

    renderImageResponse req, res, next, coverJpg, beatmap, gameMode, score

createScoreObjFromOsrData = (data) ->
    return {
        date: data.date
        enabled_mods: data.modsBitmask
        count50: data.count50
        count100: data.count100
        count300: data.count300
        countmiss: data.countmiss
        countkatu: data.countkatu
        countgeki: data.countgeki
        score: data.score
        maxcombo: data.maxCombo
        username: data.username
    }

osrFileUploadMiddleware = multer({
    storage: new MulterOsrMemoryStorage()
    limits:
        fileSize: 512000 # 500KB
    fileFilter: (req, file, cb) -> cb null, file.originalname.endsWith('.osr')
}).single('osr_file')
router.post '/submit-osr', (req, res, next) ->
    await osrFileUploadMiddleware req, res, defer uploadErr
    if uploadErr
        return handleSubmitError next, req, _.badRequestWithError 'invalid osr file', 'failed to read .osr-file', uploadErr

    if not req.file
        return handleSubmitError next, req, _.badRequest 'no .osr file was supplied'

    gameMode = req.file.osrData.gameMode
    beatmapHash = req.file.osrData.beatmapMd5

    # get beatmap
    await OsuApi.getBeatmapByHash beatmapHash, gameMode, defer err, beatmap
    return handleSubmitError next, req, _.osuApiServerError err if err
    return handleSubmitError next, req, _.notFound 'beatmap does not exist' if not beatmap

    # grab the new.ppy.sh cover of the beatmap to start with
    await CoverCache.grabCoverFromOsuServer beatmap.beatmapset_id, defer err, coverJpg
    return handleSubmitError next, req, _.coverError err if err

    score = createScoreObjFromOsrData req.file.osrData
    pp = +req.body.score_pp
    if pp
        score.pp = pp
    renderImageResponse req, res, next, coverJpg, beatmap, gameMode, score

router.get '/image-count', (req, res, next) ->
    await OsuScoreBadgeCreator.getGeneratedImagesAmount defer err, imagesAmount
    return next _.internalServerError 'error while retrieving image count', err if err
    res.json imagesAmount

getDefaultFromSet = (set) ->
    prevMode = set[0].mode
    prevId = set[0].beatmap_id
    size = set.length
    index = 1
    while index < size
        map = set[index]
        if map.mode isnt prevMode
            break
        prevId = map.beatmap_id
        ++index
    return prevId

router.get '/diffs/:set_id([0-9]+)', (req, res, next) ->
    setId = req.params.set_id
    await OsuApi.getBeatmapSet setId, defer err, set
    return next _.osuApiServerError err if err

    if not set or set.length is 0
        return next _.notFound 'no beatmap-set found with that id'

    set.sort (a, b) -> a.mode - b.mode || a.difficultyrating - b.difficultyrating
    set = set.map (b) -> beatmap_id: b.beatmap_id, version: b.version, mode: b.mode
    res.json
        setId: setId
        stdOnlySet: set.every (b) -> +b.mode is 0
        defaultVersion: getDefaultFromSet set
        set: set

    preloadBeatmapCover setId

beatmapHandler = (req, res, next) ->
    beatmapId = req.params.beatmap_id
    mode = req.params.mode
    await OsuApi.getBeatmap beatmapId, mode, defer err, beatmap
    return next _.osuApiServerError err if err
    return next _.notFound 'no beatmap found with that id' if not beatmap

    res.json
        beatmapId: beatmap.beatmap_id
        beatmapSetId: beatmap.beatmapset_id
        mode: mode || beatmap.mode
        converted: mode? and (beatmap.mode isnt mode)
        title: beatmap.title
        artist: beatmap.artist
        version: beatmap.version
        creator: beatmap.creator

    preloadBeatmapCover beatmap.beatmapset_id

preloadBeatmapCover = (beatmapSetId) ->
    # lets already *start* loading beatmap-cover since we know it'll be requested after this anyway
    CoverCache.grabCoverFromOsuServer beatmapSetId, (err, coverJpg) ->
        if err
            logger.err {err: err}, 'preloading beatmap-cover failed'
        else
            logger.debug {coverJpg: coverJpg}, 'preloaded beatmap-cover'

router.get '/beatmap/:beatmap_id([0-9]+)/:mode([0-3])', beatmapHandler
router.get '/beatmap/:beatmap_id([0-9]+)', beatmapHandler

# not found? gen 404
router.use (req, res, next) ->
    next
        message: 'Not Found'
        status: 404

# on error
router.use (err, req, res, next) ->
    res.status err.status || 500
    res.json
        error: err.message
        status: err.status
        detailMessage: err.detail || err.stack

module.exports = router
