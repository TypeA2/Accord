require "logger/colors"
require "discordrb"

class Accord
  ##
  # @param [String] token Discord token for the bot
  # @param [String] prefix Command prefix
  # @param [Database] db Databse instance to use
  # @param [Logger] logger Logger instance to use
  #
  def initialize(token:, prefix:, db:, logger: Logger.new(STDERR))
    @db = db
    @logger = logger

    # Automatically create table in debug mode, require manual creation in release mode
    if @db.table_exists?
      @logger.info("Table found, proceeding")
    else
      if ENV["DEBUG"]
        @logger.warn("Creating new table")

        @db.create_table
      else
        @logger.fatal("Expected database does not exist, create it and run again")
        exit
      end
    end

    @accord = Discordrb::Commands::CommandBot.new(token: token, prefix: prefix)

    @accord.command(:ping, &method(:ping))
  end

  # Simple ping/pong for testing
  def ping(event)
    event.respond("Pong!")
    @logger.info("Got Ping, sent Pong")
  end

  ##
  # Start the bot
  def run
    @accord.run(true)

    stored_servers = @db.servers

    # Servers the bot is in but not stored
    servers_to_add = [ ]
    @accord.servers.each do |id, server|
      unless stored_servers.include?(id.to_s)
        servers_to_add << id.to_s
      end
    end

    # Servers stored but not joined by the bot
    servers_to_remove = []
    stored_servers.each do |id|
      unless @accord.servers.include?(id.to_i)
        servers_to_remove << id
      end
    end

    @logger.debug("Storing #{servers_to_add} and removing #{servers_to_remove}")

    if (responses = @db.delete_servers(servers_to_remove))
      @logger.error("Not all servers were deleted: #{responses}")
      raise "Failed to delete all servers"
    end

    if (responses = @db.add_servers(servers_to_add))
      # Not all servers were added
      @logger.error("Not all servers were added: #{responses}")
      raise "Failed to add all new servers"
    end

    @accord.join
  end

  ##
  # Stop the bot
  def stop
    @accord.stop
  end
end
