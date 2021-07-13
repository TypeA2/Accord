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

logger = Logger.new(STDERR)

if debug
  logger.info("Running in DEBUG mode")
  ENV["DEBUG"] = "true"

  # Use local database
  Aws.config.update(
    endpoint: "http://localhost:8000"
  )
end

aws = Aws::DynamoDB::Client.new
db = Database.new(aws)
accord = Accord.new(token: ENV["DISCORD_TOKEN"], prefix: "a!", db: db, logger: logger)

# Handle SIGINT for shutdown
trap("INT") do
  puts "Caught interrupt, shutting down"
  accord.stop
  exit
end

accord.run
