require "logger/colors"
require "discordrb"

require_relative "danbooru"

class Accord
  # @return [Logger] Global logger instance
  def self.logger
    @logger ||= Logger.new(STDERR)
  end

  # @return [Logger] Global logger instance
  def logger
    Accord.logger
  end

  # @return [Database] Global database instance
  def self.db
    db ||= Database.new(Aws::DynamoDB::Client.new)
  end

  # @return [Database] Global database instance
  def db
    Accord.db
  end

  # @param [String] token Discord token for the bot
  # @param [String] prefix Command prefix
  # @param [Danbooru::User] user Danbooru user to connect to the API with
  def initialize(token:, prefix:, user:)
    # @type [Danbooru::User]
    @user = user
    # @type [Boolean]
    @running = false

    @major = rand(1..4)
    @minor = 0
    @micro = 1

    # @type [Thread]
    @timer

    # @type [Thread]
    @recording_thread

    # All servers in which to refresh
    # @type [Array<String>]
    @refresh = []

    # Automatically create table in debug mode, require manual creation in release mode
    if db.table_exists?
      logger.info("Table found, proceeding")
    else
      if ENV["DEBUG"]
        logger.warn("Creating new table")

        db.create_table
      else
        logger.fatal("Expected database does not exist, create it and run again")
        exit
      end
    end

    # @type [Hash{String => Server}]
    @servers = {}

    # Don't spam console
    Discordrb::API::trace = false

    # Do log errors
    Discordrb::LOGGER.instance_variable_set(:@enabled_modes, %i[ error ])

    @accord = Discordrb::Commands::CommandBot.new(token: token, prefix: prefix)

    @accord.server_create(&method(:server_create))
    @accord.command(:branch, { max_args: 0 }, &method(:branch))
    @accord.command(:allow, {
      min_args: 1,
      max_args: 1,
      arg_types: [ Discordrb::Role ]
    }, &method(:allow))
    @accord.command(:allowed, { max_args: 0 }, &method(:allowed))
    @accord.command(:record, { min_args: 2, max_args: 12 }, &method(:record))
    @accord.command(:record2, { min_args: 3, max_args: 13 }, &method(:record2))
    @accord.command(:recordings, { max_args: 0 }, &method(:recordings))
    @accord.command(:remove, { min_args: 1, max_args: 1 }, &method(:remove))
    @accord.command(:refresh, { max_args: 0 }, &method(:refresh))
    @accord.command(:describe, { max_args: 1 }, &method(:describe))
    @accord.command(:prune, { min_args: 1, max_args: 1, arg_types: [ Integer ] }, &method(:prune))

    @accord.ready(&method(:ready))
  end

  ##
  # @param [Discordrb::Events::ServerCreateEvent] event
  def server_create(event)
    server = event.server
    if (responses = db.add_servers([server.id]))
      logger.error("Failed to join server with id #{server.id} (\"#{server.name}\")")
    else
      @servers[server.id.to_s] = Server.new(id: server.id.to_s, roles: [], channels: [], server: server)
    end
  end

  private
  def branch_updater
    loop do
      @micro = @micro + rand(1...3) if rand > 0.5

      if @micro > 6
        @micro = (@micro % 6) + 1
        @minor += 1
      end

      if @minor > 3
        @minor = (@minor % 3) + 1
        @major += 1
      end

      if @major > 5
        # Reset
        @major = rand(1...3)
        @minor = 0
        @micro = 1
      end

      logger.debug("Moved to EID_#{@major}#{@minor}#{@micro}0")
      break unless @running

      sleep(rand(25...95))
    end

    logger.debug("Stopping branch thread")
  end

  def recording_updater
    loop do
      start = Time.now
      wake = start + 3600

      # @type [Server] server
      @servers.each do |_, server|
        server.refresh(@user)
      end

      while Time.now < wake
        sleep_now = [3600, wake - Time.now].min.clamp(0..)

        logger.debug("Sleeping for #{sleep_now} seconds until #{wake}")

        sleep(sleep_now)

        break unless @running

        # Refresh posts if there's a manual refresh
        unless @refresh.empty?
          # @type [String] id
          @refresh.each do |id|
            @servers[id].refresh(@user)
          end

          @refresh.clear
          next
        end

        break unless @running
      end
    end

    logger.debug("Stopping recording thread")
  end

  public
  # Simple ping/pong for testing
  # @param [Discordrb::CommandEvent] event
  def branch(event)
    event.respond("EID_#{@major}#{@minor}#{@micro}0")
  end

  # Register a role to be allowed to control the bot
  # @param [Discordrb::CommandEvent] event
  # @param [Discordrb::Role] role
  def allow(event, role)
    # Require owner
    return unless event.author.owner?

    # Require a role
    return unless role.class == Discordrb::Role

    server = @servers[event.server.id.to_s]
    role_id = role.id.to_s

    if server.roles.include?(role_id)
      event.send_message("Role already allowed")
      return
    end

    logger.info("Adding role @#{role.name} (#{role.id})")

    server.roles << role_id

    db.set_roles(server)

    event.send_message("Role <@&#{role.id}> added", false, nil, nil, { parse: [] })
  end

  # List all allowed roles for this server
  # @param [Discordrb::CommandEvent] event
  def allowed(event)
    server = @servers[event.server.id.to_s]
    return unless server.allowed?(event.author)

    if server.roles.empty?
      event.send_message("No roles registered for this server")
      return
    end

    msg = "Allowed roles for this server:\n"

    server.roles.each do |role|
      msg += "  - <@&#{role}>"
    end

    event.send_message(msg, false, nil, nil, { parse: [] })
  end

  # Register a channel
  # @param [Discordrb::CommandEvent] event
  # @param [Discordrb::Channel, String] channel
  # @param [Array<String>] tags
  def record(event, channel, *tags)
    record2(event, channel, 0, *tags)
  end

  # Register a channel, starting at a specific post ID
  # @param [Discordrb::CommandEvent] event
  # @param [Discordrb::Channel, String] channel
  # @param [Integer] start
  # @param [Array<String>] tags
  def record2(event, channel, start, *tags)
    # @type [Server]
    server = @servers[event.server.id.to_s]
    return "No permissions" unless server.allowed?(event.author)

    # @type [Discordrb::Channel]
    channel = @accord.parse_mention(channel) unless channel.class == Discordrb::Channel
    return "Channel not found" if channel == nil
    return "Tag count cannot exceed 11" if tags.size > 11
    return "Channel must be a text channel" unless channel.type == Discordrb::Channel::TYPES[:text]
    return "Channel must be tagged as NSFW" unless channel.nsfw?

    # @type c [Server::Channel]
    # @type found [Server::Channel]
    if (found = server.channels.find { |c| c.id == channel.id.to_s })
      return "Channel already registered: #{found.describe}"
    end

    # Remove inline code delimiters
    tags = tags.map { |t| t.gsub("`", "") }

    logger.info(
      "Recording channel #{channel.name} with tags `#{tags.join(" ")}`, starting at post #{start}")

    this_channel = Server::Channel.new(id: channel.id.to_s, tags: tags, latest: start, channel: channel)

    db.add_channel(server, this_channel)

    server.channels << this_channel
    server.sort

    "Recording complete."
  end

  # Remove a channel's recording
  # @param [Discordrb::CommandEvent] event
  # @param [Discordrb::Channel, String] channel
  def remove(event, channel)
    # @type [Server]
    server = @servers[event.server.id.to_s]
    return "No permissions" unless server.allowed?(event.author)

    # @type [Discordrb::Channel]
    channel = @accord.parse_mention(channel) unless channel.class == Discordrb::Channel
    return "Channel not found" if channel == nil

    # @type [Server::Channel]
    found = server.channels.find { |c| c.id == channel.id.to_s }
    return "Recording not present" unless found

    if (responses = db.delete_channel(server, found))
      logger.warn("Failed to delete channel #{found.id} of server #{server.id}")
      logger.warn(responses)
      return "Removal error."
    end

    server.channels.delete(found)

    logger.info("Removed #{found.describe}")

    "Removal of recording for #{found.describe} complete"
  end

  # @param [Discordrb::CommandEvent] event
  def recordings(event)
    # @type [Server]
    server = @servers[event.server.id.to_s]
    return "No permissions" unless server.allowed?(event.author)

    return "No recordings" if server.channels.empty?

    response = "#{server.channels.size} recording#{server.channels.size == 1 ? "" : "s"}:\n"
    server.channels.each do |channel|
      response += "- #{channel.describe}\n"
    end

    event.channel.split_send(response)
  end

  # @param [Discordrb::CommandEvent] event
  # @param [String, Discordrb::Channel] channel
  def describe(event, channel = event.channel)
    # @type [Server]
    server = @servers[event.server.id.to_s]
    return "No permissions" unless server.allowed?(event.author)

    if channel.class == String
      # Channel argument given, parse
      channel = @accord.parse_mention(channel)
      return "Channel not found" if channel == nil
    end
    # Else current channel


    # @type [Server::Channel] found
    if (found = server.channels.find { |ch| ch.id == channel.id.to_s })
      "Recording: #{found.describe}"
    else
      "No recording for #{(event.channel.id == channel.id) ? "this channel" : "<##{channel.id}>"}."
    end
  end

  # @param [Discordrb::CommandEvent] event
  def refresh(event)
    # @type [Server]
    server = @servers[event.server.id.to_s]
    return "No permissions" unless server.allowed?(event.author)

    @refresh << server.id
    @recording_thread.run

    "Refreshing recordings now"
  end

  # @param [Discordrb::CommandEvent] event
  # @param [Integer] count
  def prune(event, count)
    # @type [Server]
    server = @servers[event.server.id.to_s]
    return "No permissions" unless event.author.owner?

    return "Invalid number of messsages" unless count > 0

    event.channel.prune(count)
    nil
  end

  # First-time setup stuff
  def ready(_)
    @running = true

    server_mapping = db.servers

    # Servers the bot is in but not stored
    servers_to_add = []
    @accord.servers.each do |id, server|
      if !server_mapping.key?(id.to_s)
        servers_to_add << id.to_s
        @servers[id.to_s] = Server.new(id: id.to_s, roles: [], channels: [], server: server)
      else
        # Server already in database
        # @type [Hash{Symbol => Array<String>}]
        data = server_mapping[id.to_s]

        @servers[id.to_s] = Server.new(id: id.to_s, roles: data[:control_roles],
          channels: db.channels(server, data[:channels]), server: server)
      end

    end

    # Servers stored but not joined by the bot
    servers_to_remove = []
    @servers.each do |id, _|
      unless @accord.servers.key?(id.to_i)
        servers_to_remove << id
      end
    end

    logger.debug("Adding #{servers_to_add} to and removing #{servers_to_remove} from database")

    if (responses = db.delete_servers(servers_to_remove))
      logger.error("Not all servers were deleted: #{responses}")
      raise "Failed to delete all servers"
    end

    if (responses = db.add_servers(servers_to_add))
      # Not all servers were added
      logger.error("Not all servers were added: #{responses}")
      raise "Failed to add all new servers"
    end

    @recording_thread = Thread.new(&method(:recording_updater))

    logger.info("Current servers:")
    @servers.each do |_, s|
      s.sort
      logger.info("  #{s.server.name}: #{s}")
    end
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

    @recording_thread.run if @recording_thread.alive?
    @recording_thread.join

    @accord.join
  end

  def to_s
    "<Accord servers=#{@servers}>"
  end
end
