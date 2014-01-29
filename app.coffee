fs = require 'fs'
cronJob = (require 'cron').CronJob
request = require 'request'
OAuth = (require 'oauth').OAuth
es = require 'event-stream'
ent = require 'ent'

colors = require 'colors'
dateformat = require 'dateformat'
log = (msg, options={error:false, object:false}) ->
  return unless config.debug
  if options.error
    console.log "#{dateformat new Date(), 'HH:MM:ss'} #{msg.red}"
  else if options.object
    console.log dateformat new Date(), 'HH:MM:ss'
    console.log msg
  else
    console.log "#{dateformat new Date(), 'HH:MM:ss'} #{msg.green}"


redis = require 'redis'
redisClient = do redis.createClient
redisClient.on 'error', (err) ->
  log "Redis Error: #{err}", {error: true}

config = ''
configMtime = 0
loadConfig = (lastTime=0) ->
  configPath = './config'
  configMtime = (fs.statSync require.resolve configPath).mtime.getTime()
  if lastTime < configMtime
    delete require.cache[require.resolve configPath]
    config = require configPath
    log 'config loaded'
do loadConfig

users= []
loadUser = ->
  redisClient.get config.redisKey, (err, data) ->
    users = JSON.parse data
    for key, user of users
      pattern = (user.titles.join '|').replace /\s/g, '\\s?'
      user.regexp = new RegExp pattern, 'i'
    log users, {object: true}
do loadUser

posts = []
request "http://www.reddit.com/r/#{config.subreddit}/new/.json?sort=new&limit=100", (err, res, body) ->
  if not err and res.statusCode is 200
    JSON.parse(body).data.children.reverse().forEach (post) ->
      posts.push post.data.id
    do job.start
    log 'job started'

job = new cronJob config.cronTime, ->
  loadConfig configMtime

  request "http://www.reddit.com/r/#{config.subreddit}/new/.json?sort=new&limit=10", (err, res, body) ->
    if not err and res.statusCode is 200
      JSON.parse(body).data.children.reverse().forEach (post) ->
        post.data.title = ent.decode post.data.title
        if (posts.indexOf post.data.id) is -1 and not (config.ignoreTitle.test post.data.title) and (config.ignoreDomain.indexOf post.data.domain) is -1 and not (config.ignoreFlair.test post.data.link_flair_text) and (post.data.created_utc+config.waitingTime < new Date / 1000)
          title = if post.data.title.length > 100 then "#{post.data.title.substr 0, 100}..." else post.data.title
          postTweet "#{title} - http://redd.it/#{post.data.id}"
          for key, user of users
            if user.regexp.test post.data.title
              postTweet "@#{user.screen_name} #{title} - http://redd.it/#{post.data.id}"
          posts.push post.data.id
          posts.shift if posts.length > 100

oauth = new OAuth 'http://twitter.com/oauth/request_token',
  'http://twitter.com/oauth/access_token',
  config.consumerKey,
  config.consumerSecret,
  '1.0A',
  null,
  'HMAC-SHA1'

postTweet = (msg, reply=false) ->
  body = {
    status: msg
    in_reply_to_status_id: reply?
  }
  oauth.post 'https://api.twitter.com/1.1/statuses/update.json',
    config.accessToken,
    config.accessTokenSecret,
    body,
    (err, data, res) ->
      if res.statusCode is 200
        log "\"#{msg}\" posted"
      else
        log "#{data} => #{msg}", {error: true}

restartCount = 0
restartStream = ->
  setTimeout (-> do streaming), 10 * 1000
  restartCount++

streaming = ->
  streamUrl = 'https://userstream.twitter.com/1.1/user.json?replies=all'
  req = oauth.get streamUrl, config.accessToken, config.accessTokenSecret
  req.on 'response', (res) ->
    res.setEncoding 'utf8'
    ls =  res.pipe es.split '\n'

    ls.on 'data', (line) ->
      return unless line.length > 1
      tweet = JSON.parse line
      if tweet.in_reply_to_user_id_str is config.id_str
        tmp = (tweet.text.split '@rGameDeals')[1].trim().split ' '
        command = tmp.shift()
        param = tmp.join(' ')
        switch command
          when 'add'
            unless users[tweet.user.id_str]
              users[tweet.user.id_str] = {}
              users[tweet.user.id_str].titles = []
            user = users[tweet.user.id_str]
            user.screen_name = tweet.user.screen_name
            user.titles.push param
            redisClient.set config.redisKey, (JSON.stringify users), (err, res) ->
              if res is 'OK'
                postTweet "@#{tweet.user.screen_name} #{param} added"
            do loadUser
          when 'ls', 'list'
            if user = users[tweet.user.id_str]
              list = ''
              for v, i in user.titles
                list += "#{i}:'#{v}' "
              postTweet "@#{tweet.user.screen_name} #{list}"
          when 'del', 'delete'
            param = (param.split '')[0]
            if user = users[tweet.user.id_str]
              if user.titles.length >= param
                title = user.titles[param]
                user.titles.splice param, 1
                redisClient.set config.redisKey, (JSON.stringify users), (err, res) ->
                  if res is 'OK'
                    postTweet "@#{tweet.user.screen_name} #{param}:'#{title}' deleted"
                do loadUser

    ls.on 'end', ->
      do restartStream
      log "restartCount: #{restartCount}"

  do req.end

do streaming
