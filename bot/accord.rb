require "logger/colors"
require "discordrb"

require_relative "database"
require_relative "command"

class Discordrb::Events::ApplicationCommandEvent
  def symbol_options
    options.transform_keys(&:to_sym)
  end
end

class Accord
  # @type [Integer]
  EMBED_COLOR = 0xCD8FCE.freeze

  # @type [Hash]
  EMBED_BASE = {
    type: "rich",
    color: EMBED_COLOR,
  }.freeze

  # @type [Array<Command>]
  COMMANDS = [
    Command.new(
      name:        :branch,
      read_only:   true,
      description: "Get the current branch (ping/pong)"
    ),
    Command.new(
      name:        :allow,
      read_only:   false,
      description: "Allow a user to control the bot"
    ) do |cmd|
      cmd.user(:new_admin, "User to give admin permissions to", required: true)
    end,
    Command.new(
      name:        :disallow,
      read_only:   false,
      description: "Remove a user's ability to control the bot"
    ) do |cmd|
      cmd.user(:admin, "User to remove admin permissions from", required: true)
    end,
    Command.new(
      name:        :admins,
      read_only:   true,
      description: "Retrieve a list of all admins"
    )
  ].freeze

  # @return [Logger] Global logger instance
  def self.logger
    @logger ||= Logger.new(STDERR)
  end

  # @return [Logger] Global logger instance
  def logger
    Accord.logger
  end

  # @return [Bool]
  attr_reader :running

  # @param [String] token Discord bot token
  # @param [Danbooru::User] user Danbooru user to connect with
  # @param [Database] db Database instance to use
  def initialize(token:, user:, db:, debug: false)
    @user = user
    @db = db
    @debug = debug

    # @type [Hash{Integer => Server}]
    @servers = {}

    # @type [Bool]
    @running = false

    @major = rand(1..4)
    @minor = 0
    @micro = 1

    # Prevent console spam
    Discordrb::API::trace = false

    # But don't eat errors
    Discordrb::LOGGER.instance_variable_set(:@enabled_modes, %i[ error ])

    # @type [Discordrb::Bot]
    @bot = Discordrb::Bot.new(token: token)

    @bot.ready(&method(:ready))
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

    logger.debug("Stopping branch thread") if @debug
  end

  # @return [String]
  def current_branch
    "EID_#{@major}#{@minor}#{@micro}0"
  end

  # Bot is connected, perform setup
  def ready(_)
    # @type [Set<Integer>]
    stored_servers = @db.servers

    # May need to add some servers to the db
    @bot.servers.each do |id, server|
      if stored_servers.include?(id)
        # Already exists
        @servers[id] = Server.new(
          id:       id,
          admins:   @db.admins(server),
          channels: @db.channels(server),
          server:   server)
      else
        # New server
        @db.add_server(id)
        @servers[id] = Server.new(id: id, admins: Set.new, channels: [], server: server)
      end
    end

    # Remove any servers we're not in anymore
    stored_servers.each do |id|
      unless @servers.key?(id)
        @db.del_server(id)
      end
    end

    logger.info("Servers: ")
    @servers.each do |_, s|
      s.sort
      logger.info("  #{s.server.name}: #{s}")

      if @debug
        s.channels.each do |ch|
          logger.info("    #{ch.id}: >= #{ch.latest}, #{tags.join("+")}")
        end
      end
    end

    if @debug
      # Check all methods exist
      begin
        COMMANDS.each { |cmd| method(cmd.name) }
      rescue NameError => e
        @bot.log_exception(e)
        $wait_queue.push(nil)
        return
      end

      logger.debug("Registering application commands for each server separately...")

      start = Time.now
      @servers.each_value do |server|
        logger.debug("  #{server.id}...")
        # Ensure the method exists
        COMMANDS.each { |cmd| cmd.register(self, @bot, server:) }
      end

      logger.debug("Done (#{Time.now - start} s)")
    else
      
    end
  end

  ##
  # Convenience method to create an array with a single embed
  # @return [Array<Hash>]
  def embed(**args)
    [EMBED_BASE.merge(args)]
  end

  ##
  # Ping/pong
  # @param [Discordrb::ApplicationCommandEvent]
  def branch(event)
    event.respond(embeds: embed(title: "Current branch", description: current_branch))
  end

  ##
  # Add an admin
  # @param [Discordrb::ApplicationCommandEvent]
  def allow(event)
    server = @servers[event.server_id]
    user = server.member(event.symbol_options[:new_admin].to_i)

    # Still need some input checking
    if user == server.bot
      event.respond(embeds: embed(description: "That's me!"))
    elsif server.admins.include?(user.id)
      event.respond(embeds: embed(description: "<@#{user.id}> is already an admin"))
    else
      # Add if user is not already in the list
      logger.info("Adding #{user.id} as admin in #{server.id}")

      server.admins << user.id
      @db.add_admin(server_id: server.id, admin_id: user.id)

      event.respond(embeds: embed(description: "<@#{user.id}> is being added to the admins..."))
      
      COMMANDS.each do |cmd|
        unless cmd.read_only
          @bot.edit_application_command_permissions(cmd.id, server.id) do |perms|
            server.admins.union([server.owner.id]).each { |id| perms.allow_user(id) }
          end
        end
      end

      event.edit_response(embeds: embed(description: "<@#{user.id}> was added as an admin"))
    end
  end

  ##
  # Remove an admin
  # @param [Discordrb::ApplicationCommandEvent]
  def disallow(event)
    server = @servers[event.server_id]
    user = server.member(event.symbol_options[:admin].to_i)

    if user == server.bot
      event.respond(embeds: embed(description: "That's me!"))
    elsif !server.admins.include?(user.id)
      event.respond(embeds: embed(description: "<@#{user.id}> is not an admin"))
    else
      logger.info("Removing #{user.id} as admin in #{server.id}")

      server.admins.delete(user.id)
      @db.del_admin(server_id: server.id, admin_id: user.id)

      event.respond(embeds: embed(description: "<@#{user.id}> is being removed from the admins..."))

      COMMANDS.each do |cmd|
        unless cmd.read_only
          @bot.edit_application_command_permissions(cmd.id, server.id) do |perms|
            server.admins.union([server.owner.id]).each { |id| perms.allow_user(id) }
          end
        end
      end

      event.edit_response(embeds: embed(description: "<@#{user.id}> is no longer an admin"))
      
    end
  end

  ##
  # List all admins
  # @param [Discordrb::ApplicationCommandEvent]
  def admins(event)
    server = @servers[event.server_id]

    event.respond(embeds: embed(title: "Admin list of `#{server.name}`", fields: server.admins.map do |id|
      { name: "\u200B", value: " - <@#{id}>" }
    end))
  end

  public
  ##
  # Start the bot
  def run
    @running = true
    @timer = Thread.new(&method(:branch_updater))

    @bot.run(true)
  end

  ##
  # Stop the bot
  def stop
    if @debug
      logger.debug("Unregistering commands...")

      start = Time.now
      @servers.each_key do |server_id|
        logger.debug("  #{server_id}...")
        @bot.get_application_commands(server_id:).map!(&:delete)
      end

      logger.debug("Done (#{Time.now - start} s)")
    end

    @bot.stop

    @running = false
    # Interrupt sleep
    @timer.run if @timer.alive?
    @timer.join

    @bot.join
  end

  ##
  # Connect to the bot and register all global application commands
  def register_globals
    logger.info("Registering global application commands")

    @bot.clear!
    @bot.run(true)
  end

  ##
  # Connect the bot, unregister global application commands and exit
  def unregister_globals
    logger.info("Clearing global application commands")

    @bot.clear!
    @bot.run(true)

    @bot.get_application_commands.map!(&:delete)

    @bot.stop
    @bot.join
  end
end
