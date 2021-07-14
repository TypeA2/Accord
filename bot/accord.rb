require "logger/colors"
require "discordrb"

class Accord
  # @param [String] token Discord token for the bot
  # @param [String] prefix Command prefix
  # @param [Database] db Databse instance to use
  # @param [Logger] logger Logger instance to use
  def initialize(token:, prefix:, db:, logger: Logger.new(STDERR))

    # @type [Database]
    @db = db

    # @type [Logger]
    @logger = logger

    # @type [Boolean]
    @running = false

    @major = 0
    @minor = 0
    @micro = 0

    # @type [Thread]
    @timer

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

    # @type [Array<Server>]
    @servers = []

    @accord = Discordrb::Commands::CommandBot.new(token: token, prefix: prefix)

    @accord.server_create(&method(:server_create))
    @accord.command(:branch, &method(:branch))

    @accord.ready(&method(:ready))
  end

  ##
  # @param [Discordrb::Events::ServerCreateEvent] event
  def server_create(event)
    server = event.server
    if (responses = @db.add_servers([server.id]))
      @logger.error("Failed to join server with id #{server.id} (\"#{server.name}\")")
    else
      @servers << Server.new(id: server.id.to_s, roles: [], channels: [], server: server)
    end
  end

  private
  def branch_updater
    loop do
      @major = ((@major + rand(1...3)) % 5) + 1 if rand > 0.8
      @minor =  (@minor + rand(1...3)) % 6      if rand > 0.5
      @micro = ((@micro + rand(1...3)) % 6) + 1 if rand > 0.2

      @logger.debug("Moved to EID_#{@major}#{@minor}#{@micro}0")
      break unless @running

      sleep(rand(15...60))
    end

    @logger.debug("Stopping branch thread")
  end

  public
  # Simple ping/pong for testing
  # @param [Discordrb::CommandEvent] event
  def branch(event)
    event.respond("EID_#{@major}#{@minor}#{@micro}0")
  end

  # First-time setup stuff
  # @param [Discordrb::ReadyEvent] event
  def ready(event)
    @running = true

    @servers = @db.servers

    stored_servers = @servers.map { |s| s.id }

    # Servers the bot is in but not stored
    servers_to_add = []
    @accord.servers.each do |id, server|
      if !stored_servers.include?(id.to_s)
        servers_to_add << id.to_s
        @servers << Server.new(id: id.to_s, roles: [], channels: [], server: server)
      else
        # Server already in database, attach instance
        @servers.find{ |s| s.id == id.to_s }.server = server
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

    @logger.info("Current servers:")
    @servers.each { |s| @logger.info("  #{s.server.name}: #{s}") }
  end

  ##
  # Start the bot
  def run
    @running = true

    @timer = Thread.new(&method(:branch_updater))

    @accord.run
  end

  ##
  # Stop the bot
  def stop
    @accord.stop

    @running = false

    @timer.run if @timer.alive?
    @timer.join

    @accord.join
  end
end
