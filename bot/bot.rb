#!/usr/bin/env ruby

require "dotenv/load"
require "optparse"
require "discordrb"

require_relative "database"
require_relative "accord"
require_relative "danbooru"

$debug = false
$dbfile = "accord.db"

$register_globals = false
$unregister_globals = false

OptionParser.new do |opts|
  opts.banner = "Usage: #{File.basename($0)} [--debug]"
  opts.on("-d", "--debug") { |v| $debug = v }
  opts.on("--db=some_file.db", "File path to the database file to use") { |f| $dbfile = f }
  opts.on("--register", "Register all global slash commands") { |v| $register_globals = v }
  opts.on("--unregister", "Unregister any global slash commands") { |v| $unregister_globals = v }
end.parse!

if $debug
  Accord.logger.info("Running in DEBUG mode")
  ENV["DEBUG"] = "true"
end

user = Danbooru::User.new(login: ENV["DANBOORU_USERNAME"], key: ENV["DANBOORU_API_KEY"])
db = Database.new($dbfile)
accord = Accord.new(token: ENV["DISCORD_TOKEN"], user: user, db: db, debug: $debug)

if $register_globals
  accord.register_globals
elsif $unregister_globals
  accord.unregister_globals
else
  #ccord.ready do |_|
    #  accord.register_application_command(:test, "help", server_id: 863757781685108746) do |cmd|
    #    cmd.subcommand_group(:nested, "nested lvl 1") do |group|
    #      group.subcommand(:theend, "is near")
    #    end
    #  end
  #  accord.get_application_commands(server_id: 863757781685108746).each do |cmd|
  #    accord.delete_application_command(cmd.id, server_id: 863757781685108746)
  #  end
  #end

  $wait_queue = Queue.new

  def shutdown
    puts "Caught interrupt, shutting down"
    $wait_queue.push(nil)
  end

  # Handle SIGINT and SIGTERM for shutdown
  trap("INT", proc { shutdown })
  trap("TERM", proc { shutdown })

  accord.run
  $wait_queue.pop
  accord.stop
end
