#!/usr/bin/ruby

require 'discordrb'
require 'net/http'
require 'uri'
require 'json'
require 'timers'
require 'sqlite3'
require 'mysql2'
require 'rss'
require 'open-uri'
require 'twitter'

shard = ENV["SHARD"].to_i unless ENV["SHARD"].nil?
total_shards = ENV["TOTALSHARDS"].to_i unless ENV["TOTALSHARDS"].nil?
if shard.nil?
  shard = 0
  total_shards = 1
end

$bot = Discordrb::Commands::CommandBot.new token: ENV["DISCORD_TOKEN"], client_id: ENV["DISCORD_CLIENTID"], prefix: '!', shard_id: shard, num_shards: total_shards
$mysql = Mysql2::Client.new( :host => ENV["DB_HOST"], :username => ENV["DB_USER"], :password => ENV["DB_PASSWORD"], :port => ENV["DB_PORT"], :database => ENV["DATABASE"], :reconnect => true)
$sqlite = SQLite3::Database.new "./manifest/world_sql_content_ce1aaa244657c301a58058dd93868733.content.sqlite"

$twitter = Twitter::REST::Client.new do |config|
  config.consumer_key        = ENV["TWITTER_CONSUMER_KEY"]
  config.consumer_secret     = ENV["TWITTER_CONSUMER_SECRET"]
  config.access_token        = ENV["TWITTER_ACCESS_TOKEN"]
  config.access_token_secret = ENV["TWITTER_ACCESS_SECRET"]
end

$bot.bucket :D2, limit: 3, time_span: 60, delay: 10
$bot.bucket :general, limit: 3, time_span: 60, delay: 10

$base_url = "https://www.bungie.net"

def game
  $bot.game = quotes 
end

$bot.server_create do |event|
  default_channel = event.server.default_channel
  default_channel.send_message "Thanks for adding me Guardian, but I won't function until I am configured!"
  default_channel.send_message "I require only a few moments of your time to complete this important step."
  default_channel.send_message "Please take a moment to run the !configure *guild id* command in a text channel on your server."
  default_channel.send_message "*Example:* !configure 123456"
end

$bot.server_delete do |event|
  statement = $mysql.prepare("DELETE FROM servers WHERE sid=? LIMIT 1")
  statement.execute(event.server.id)
end

$bot.command(:commands, bucket: :general, rate_limit_message: 'Calm down for %time% more seconds!') do |event|
  event.send_temporary_message "```
!botinfo     - Displays bot statistics and info.
!nightfall   - Pulls the realtime info about the current nightfall.
!newschannel - Sets the channel this is run in as your news channel. Any posts from Bungie's blog or @BungieHelp on twitter will be linked in this channel.
!claninfo    - Pulls the realtime info about your clan.
!engrams     - Pulls the realtime info about the clan engrams.```", 60.to_f
  temp_timers = Timers::Group.new
  temp_timers.after(60) { event.message.delete }
  temp_timers.wait
  event.drain
end

$bot.command(:botinfo, bucket: :general, rate_limit_message: 'Calm down for %time% more seconds!') do |event|
  channel = event.channel
  shard_value = (shard + 1).to_s + "/" + total_shards.to_s
  channel.send_embed do |embed|
    embed.title = "Ghost"
    embed.description = "A discord bot for Destiny 2 clans"
    embed.footer = Discordrb::Webhooks::EmbedFooter.new(text: quotes, icon_url: "https://ghost.sysad.ninja/Ghost.png")
    embed.color = Discordrb::ColourRGB.new(0x00ff00).combined
    embed.add_field(name: "Servers", value: $bot.servers.count, inline: true)
    embed.add_field(name: "Shard", value: shard_value, inline: true)
    embed.add_field(name: "Support Server", value: "https://discord.gg/8My2HqS", inline: true)
  end
end

$bot.command(:configure, bucket: :general, rate_limit_message: 'Calm down for %time% more seconds!') do |event,guild_id|
  if guild_id.nil?
    event.send_message "Guardian, I need the guild ID. Please provide it as an arguement to the command."
  else
    if guild_id.to_i
      statement = $mysql.prepare("INSERT INTO servers (sid,d2_guild_id,created_at,updated_at) VALUES (?, ?,NOW(),NOW())")
      result = statement.execute(event.channel.server.id.to_s,guild_id)

      event.send_message "Thank you Guardian! My commands are available via *!commands*."
    end
  end
end

$bot.command(:newschannel, bucket: :general, rate_limit_message: 'Calm down for %time% more seconds!') do |event|
  statement = $mysql.prepare("UPDATE servers SET news_channel=? where sid=?")
  result = statement.execute(event.channel.id.to_s, event.channel.server.id.to_s)

  event.send_message "Guardian, Once news comes from Bungie, I will post it here."
end

$bot.command(:claninfo, bucket: :D2, rate_limit_message: 'Calm down for %time% more seconds!') do |event|
  @clan = get_clanid event.channel.server.id

  @json = bungie_api_request "/Platform/GroupV2/#{@clan}/"

  @progression = @json["Response"]["detail"]["clanInfo"]["d2ClanProgressions"]["584850370"]

  channel = event.channel
  channel.send_embed do |embed|
    embed.title = @json["Response"]["detail"]["name"]
    embed.description = @json["Response"]["detail"]["about"]
    embed.footer = Discordrb::Webhooks::EmbedFooter.new(text: quotes, icon_url: "https://ghost.sysad.ninja/Ghost.png")
    embed.color = Discordrb::ColourRGB.new(0x00ff00).combined
    embed.add_field(name: "Level", value: @progression["level"], inline: true)
    embed.add_field(name: "Next Level", value: @progression["progressToNextLevel"].to_s + "/" + @progression["nextLevelAt"].to_s + " (" + (@progression["progressToNextLevel"].to_f / @progression["nextLevelAt"].to_f * 100.0).round(2).to_s + "%)", inline: true)
    embed.add_field(name: "Weekly Progress", value: @progression["weeklyProgress"].to_s + "/" + @progression["weeklyLimit"].to_s + " (" + (@progression["weeklyProgress"].to_f / @progression["weeklyLimit"].to_f * 100.0).round(2).to_s + "%)", inline: true)
  end
end

$bot.command(:nightfall, bucket: :D2, rate_limit_message: 'Calm down for %time% more seconds!') do |event|
  json = bungie_api_request "/Platform/Destiny2/Milestones/"

  modifiers = json["Response"]["2171429505"]['availableQuests'][0]['activity']['modifierHashes']
  hash = json["Response"]["2171429505"]['availableQuests'][0]['activity']['activityHash']

  activity = $sqlite.execute("select * from DestinyActivityDefinition where id = " + hash.to_s)[0]
  if activity.nil?
    activity = $sqlite.execute("select * from DestinyActivityDefinition where id + 4294967296 = " + hash.to_s)[0]
  end

  @lookup = JSON.load(activity[1])

  channel = event.channel
  channel.send_embed do |embed|
    embed.title = @lookup["displayProperties"]["name"]
    embed.description = @lookup["displayProperties"]["description"]
    embed.image = Discordrb::Webhooks::EmbedImage.new(url: $base_url + @lookup["pgcrImage"])
    embed.thumbnail = Discordrb::Webhooks::EmbedImage.new(url: $base_url + @lookup["displayProperties"]["icon"])
    embed.footer = Discordrb::Webhooks::EmbedFooter.new(text: quotes, icon_url: "https://ghost.sysad.ninja/Ghost.png")
    embed.color = Discordrb::ColourRGB.new(0x00ff00).combined
    modifiers.each do |mod|
      mod_lookup = $sqlite.execute("select * from DestinyActivityModifierDefinition where id = " + mod.to_s)[0]
      if !mod_lookup.nil?
        mod_info = JSON.load(mod_lookup[1])
        embed.add_field(name: mod_info["displayProperties"]["name"], value: mod_info["displayProperties"]["description"], inline: true)
      else
        mod_lookup = $sqlite.execute("select * from DestinyActivityModifierDefinition where id + 4294967296 = " + mod.to_s)[0]
        mod_info = JSON.load(mod_lookup[1])
        embed.add_field(name: mod_info["displayProperties"]["name"], value: mod_info["displayProperties"]["description"], inline: true)
      end
    end
  end
end

$bot.command(:server, bucket: :general, rate_limit_message: 'Calm down for %time% more seconds!', help_available: false) do |event|
  event.send_message event.channel.server.id
end

$bot.command(:engrams, bucket: :D2, rate_limit_message: 'Calm down for %time% more seconds!') do |event|

  @clan = get_clanid event.channel.server.id

  json = bungie_api_request "/Platform/Destiny2/Clan/#{@clan}/WeeklyRewardState/"
  
  @crucible = false
  @trials = false
  @nightfall = false
  @raid = false
  
  json["Response"]["rewards"][0]["entries"].each do |entry|
    if entry["rewardEntryHash"] == 3789021730
      if entry["earned"] == true
        @nightfall = true
      end
    elsif entry["rewardEntryHash"] == 2112637710
      if entry["earned"] == true
        @trials = true
      end
    elsif entry["rewardEntryHash"] == 2043403989
      if entry["earned"] == true
        @raid = true
      end
    elsif entry["rewardEntryHash"] == 964120289
      if entry["earned"] == true
        @crucible = true
      end
    end
  end
  
  hash = json['Response']['milestoneHash']
  @lookup = JSON.load($sqlite.execute("select * from DestinyMilestoneDefinition where id + 4294967296 = " + hash.to_s)[0][1])
  
  channel = event.channel
  channel.send_embed do |embed|
    embed.title = @lookup["displayProperties"]["name"]
    embed.description = @lookup["displayProperties"]["description"]
    embed.thumbnail = Discordrb::Webhooks::EmbedImage.new(url: $base_url + @lookup["displayProperties"]["icon"])
    embed.footer = Discordrb::Webhooks::EmbedFooter.new(text: quotes, icon_url: "https://ghost.sysad.ninja/Ghost.png")
    embed.color = Discordrb::ColourRGB.new(0x00ff00).combined
    # 3789021730 - Nightfall
    if @nightfall
      embed.add_field(name: @lookup["rewards"]["1064137897"]["rewardEntries"]["3789021730"]["displayProperties"]["name"], value: "Available", inline: true)
    else
      embed.add_field(name: @lookup["rewards"]["1064137897"]["rewardEntries"]["3789021730"]["displayProperties"]["name"], value: "Not Obtained", inline: true)
    end
    # 2112637710 - Trials
    if @trials
      embed.add_field(name: @lookup["rewards"]["1064137897"]["rewardEntries"]["2112637710"]["displayProperties"]["name"], value: "Available", inline: true)
    else
      embed.add_field(name: @lookup["rewards"]["1064137897"]["rewardEntries"]["2112637710"]["displayProperties"]["name"], value: "Not Obtained", inline: true)
    end
    # 2043403989 - Raid
    if @raid
      embed.add_field(name: @lookup["rewards"]["1064137897"]["rewardEntries"]["2043403989"]["displayProperties"]["name"], value: "Available", inline: true)
    else
      embed.add_field(name: @lookup["rewards"]["1064137897"]["rewardEntries"]["2043403989"]["displayProperties"]["name"], value: "Not Obtained", inline: true)
    end
    # 964120289 - Crucible
    if @crucible
      embed.add_field(name: @lookup["rewards"]["1064137897"]["rewardEntries"]["964120289"]["displayProperties"]["name"], value: "Available", inline: true)
    else
      embed.add_field(name: @lookup["rewards"]["1064137897"]["rewardEntries"]["964120289"]["displayProperties"]["name"], value: "Not Obtained", inline: true)
    end
  end
end

def bungie_api_request(path)
  uri = URI.parse($base_url + path)
  request = Net::HTTP::Get.new(uri)
  request["X-Api-Key"] = ENV["BUNGIE_API"]
  
  req_options = {
    use_ssl: uri.scheme == "https",
  }
  
  response = Net::HTTP.start(uri.hostname, uri.port, req_options) do |http|
    http.request(request)
  end
  
  return JSON.load(response.body)
end

def news
  query = $mysql.query("SELECT news_channel FROM servers;")
  @channels = []
  query.each do |r|
    if !r["news_channel"].nil?
      @channels.push r["news_channel"]
    end
  end

  tweets = $twitter.user_timeline("bungiehelp")
  tweets.each do |tweet|
    statement = $mysql.prepare("SELECT tweet_id FROM bungie_help WHERE tweet_id=?;")
    result = statement.execute(tweet.id)
    if result.entries.empty?
      insert_statement = $mysql.prepare("INSERT INTO bungie_help (tweet_id,text,url) VALUES (?,?,?);")
      insert_statement.execute(tweet.id, tweet.text, tweet.url.to_s)
      @channels.each do |channel|
        $bot.channel(channel).send_embed do |embed|
          embed.title = tweet.user.name + " (@#{tweet.user.screen_name})"
          embed.description = tweet.text
          embed.url = tweet.url.to_s
          embed.thumbnail = Discordrb::Webhooks::EmbedImage.new(url: tweet.user.profile_image_url.to_s)
          embed.footer = Discordrb::Webhooks::EmbedFooter.new(text: quotes, icon_url: "https://ghost.sysad.ninja/Ghost.png")
          embed.color = Discordrb::ColourRGB.new(0x00ff00).combined
        end
        sleep 1
      end
    end
  end 

  url = 'https://www.bungie.net/en-us/Rss/NewsByCategory'
  open(url) do |rss|
    feed = RSS::Parser.parse(rss)
    feed.items.each do |item|
      statement = $mysql.prepare("SELECT guid FROM bungie_news WHERE guid=?;")
      result = statement.execute(item.guid.content)
      if result.entries.empty?
        insert_statement = $mysql.prepare("INSERT INTO bungie_news (guid,title,link,description) VALUES (?,?,?,?);")
        insert_statement.execute(item.guid.content, item.title, item.link, item.description)
        @channels.each do |channel|
          $bot.channel(channel).send_embed do |embed|
            embed.title = item.title
            embed.description = item.description
            embed.url = item.link
            embed.footer = Discordrb::Webhooks::EmbedFooter.new(text: quotes, icon_url: "https://ghost.sysad.ninja/Ghost.png")
            embed.color = Discordrb::ColourRGB.new(0x00ff00).combined
          end
        end
      end
      sleep 1
    end
  end
end

def quotes
  result = $mysql.query("SELECT quote,source FROM quotes ORDER BY RAND() LIMIT 1;")
  quote_string = result.entries[0]["quote"] + " - " + result.entries[0]["source"]
  return quote_string
end

def get_clanid(server)
  statement = $mysql.prepare("SELECT * FROM servers WHERE sid = ?")
  result = statement.execute(server.to_s)
  return result.first["d2_guild_id"]
end

$bot.run :async
game

$timers = Timers::Group.new
timer = $timers.every(60) { game }
news_timer = $timers.every(60) { news }
loop { $timers.wait }
