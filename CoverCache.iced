request = require 'request'
gm = require 'gm'
fs = require 'fs'
path = require 'path'
RedisCache = require './RedisCache'
config = require 'config'
PathConstants = require './PathConstants'

CACHE_TIME = config.get 'cacheTimes.get_beatmaps'
COVER_CACHE_DIR = PathConstants.coverCacheDir

DEFAULT_COVER = path.resolve PathConstants.inputDir, 'defaultCover.jpg'

grabCoverFromOsuServer = (beatmapSetId, done) ->
    # return default on falsy values
    return done null, DEFAULT_COVER if not beatmapSetId

    cacheKey = 'coverCache:' + beatmapSetId
    await RedisCache.get cacheKey, defer isInCache, cachedResult
    if isInCache # yay cache exists
        if cachedResult
            return done null, cachedResult
        else
            return done null, DEFAULT_COVER

    # cache didnt exist, lets get it
    url = "https://assets.ppy.sh/beatmaps/#{beatmapSetId}/covers/cover.jpg"

    req = request.get url
    await
        reqDone = defer err, res
        req.once 'response', (res) -> reqDone null, res
        req.once 'error', (err) ->
            console.log 'req error'
            reqDone err
    return done err if err

    localLocation = path.resolve COVER_CACHE_DIR, beatmapSetId + '.jpg'
    if res.statusCode isnt 200
        # not found, use default
        done null, DEFAULT_COVER

        # and store 'null' in cache, which causes default to be used
        RedisCache.storeInCache CACHE_TIME, cacheKey, null
        return

    pipe = req.pipe fs.createWriteStream localLocation
    await
        pipeDone = defer err
        pipe.once 'finish', () -> pipeDone()
        pipe.once 'error', (err) -> pipeDone err
    return done err if err

    # all gud, lets give it back right now, no need to wait for redis right
    done null, localLocation

    # also store it in cache
    RedisCache.storeInCache CACHE_TIME, cacheKey, localLocation


module.exports =
    grabCoverFromOsuServer: grabCoverFromOsuServer
