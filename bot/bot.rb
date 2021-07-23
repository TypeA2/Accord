require "dotenv/load"
require "optparse"

require_relative "database"
require_relative "accord"

debug = false
OptionParser.new do |opts|
  opts.banner = "Usage: bot.rb [--debug]"
  opts.on("-d", "--debug") do |v|
    debug = v
  end
end.parse!

if debug
  Accord.logger.info("Running in DEBUG mode")
  ENV["DEBUG"] = "true"

  # Use local database
  Aws.config.update(
    endpoint: "http://localhost:8000"
  )
end

user = Danbooru::User.new(login: ENV["DANBOORU_USERNAME"], key: ENV["DANBOORU_API_KEY"])
accord = Accord.new(token: ENV["DISCORD_TOKEN"], prefix: "a!", user: user)

def shutdown(accord)
  puts "Caught interrupt, shutting down"
  accord.stop
  exit(0)
end

# Handle SIGINT and SIGTERM for shutdown
trap("INT", proc { shutdown accord })
trap("TERM", proc { shutdown accord })

accord.run
