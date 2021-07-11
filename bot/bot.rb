require "dotenv/load"

require_relative "accord"

accord = Accord.new(token: ENV["DISCORD_TOKEN"], prefix: "a!", log_target: STDERR)

# Handle SIGINT for shutdown
trap("INT") do
  puts "Caught interrupt, shutting down"
  accord.stop
  exit 0
end

accord.run
