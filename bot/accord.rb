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
      description: "Get the current branch (ping/pong)",
      enabled:     true
    ),
    Command.new(
      name:        :allow,
      read_only:   false,
      description: "Allow a user to control the bot",
      enabled:     true
    ) do |cmd|
      cmd.user(:new_admin, "User to give admin permissions to", required: true)
    end,
    Command.new(
      name:        :disallow,
      read_only:   false,
      description: "Remove a user's ability to control the bot",
      enabled:     true
    ) do |cmd|
      cmd.user(:admin, "User to remove admin permissions from", required: true)
    end,
    Command.new(
      name:        :allowed,
      read_only:   true,
      description: "Retrieve a list of all admins",
      enabled:     true
    ),
    Command.new(
      name:        :record,
      read_only:   false,
      description: "Add a recording",
      enabled:     true
    ) do |cmd|
      cmd.subcommand(:new, "Add a new recording") do |subcmd|
        # Text channels only
        subcmd.channel(:channel, "Channel to record to", required: true, types: [0])

        subcmd.string(:tags, "List of tags", required: true)
      end

      cmd.subcommand(:continue, "Continue an existing recording") do |subcmd|
        subcmd.channel(:channel, "Channel to record to", required: true, types: [0])

        # Latest post ID
        subcmd.integer(:latest, "Latest post in the current recording", required: true)

        subcmd.string(:tags, "List of tags", required: true)
      end
    end,
    Command.new(
      name:        :recordings,
      read_only:   true,
      description: "List all recordings",
      enabled:     true
    ),
    Command.new(
      name:        :remove,
      read_only:   false,
      description: "Remove a recording",
      enabled:     true
    ) do |cmd|
      cmd.channel(:channel, "Channel whose recording to remove", required: true, types: [0])
    end,
    Command.new(
      name:        :describe,
      read_only:   true,
      description: "Describe the current or specified recording",
      enabled:     true
    ) do |cmd|
      cmd.channel(:channel, "Channel to describe", required: false, types: [0])
    end,
    Command.new(
      name:        :refresh,
      read_only:   false,
      description: "Refresh this server's recordings",
      enabled:      true
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

    # @type [Thread]
    @timer

    # @type [Array<Integer>]
    @refresh = []

    # @type [Thread]
    @recording_thread

    @major = rand(1..4)
    @minor = 0
    @micro = 1

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

      sleep(rand(60...360))
    end

    logger.debug("Stopping branch thread") if @debug
  end

  @recording = false

  def recording_updater
    @recording = true

    loop do
      start = Time.now

      # Update every hour
      wake = start + 3600

      # Refresh every server
      @servers.each_value do |server|
        server.refresh(@user, @db)
      end

      # Sleep till wake
      while Time.now < wake
        sleep_now = [3600, wake - Time.now].min.clamp(0..)

        logger.info("Sleeping for #{sleep_now} s until #{wake}")

        sleep(sleep_now)

        # Break if the bot is shutting down
        return unless @running

        # Woken, may need to manually refresh some servers
        unless @refresh.empty?
          @refresh.each do |id|
            @servers[id].refresh(@user, @db)
          end

          @refresh.clear
          next
        end

        # May have been cancelled during refresh
        return unless @running
      end
    end

  rescue StandardError => e
    logger.error("Recording error")
    logger.error(e.message)
    e.backtrace.each{ |line| logger.error(line) }
  ensure
    @recording = false
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
          admins:   @db.admins(server),
          channels: @db.channels(server),
          server:   server
        )
      else
        # New server
        @db.add_server(id)
        @servers[id] = Server.new(admins: Set.new, channels: [], server: server)
      end
    end

    # Remove any servers we're not in anymore
    stored_servers.each do |id|
      unless @servers.key?(id)
        @db.del_server(id)
      end
    end

    @recording_thread = Thread.new(&method(:recording_updater))

    logger.info("Servers: ")
    @servers.each do |_, s|
      s.sort
      logger.info("  #{s.server.name}: #{s}")

      if @debug
        s.channels.each do |ch|
          logger.info("    #{ch.id}: >= #{ch.latest}, #{ch.tags.join("+")}")
        end
      end
    end

    if @debug
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
  def allowed(event)
    server = @servers[event.server_id]

    event.respond(embeds: embed(title: "Admin users in `#{server.name}`", fields: server.admins.map do |id|
      { name: "\u200B", value: " - <@#{id}>" }
    end))
  end

  ##
  # Add a recording
  # @param [Discordrb::ApplicationCommandEvent]
  def record_new(event)
    event.options["latest"] = 0
    record_continue(event)
  end

  ##
  # Continue an existing recording
  # @param [Discordrb::ApplicationCommandEvent]
  def record_continue(event)
    server = @servers[event.server_id]
    opts = event.symbol_options

    channel = @bot.channel(opts[:channel].to_i, server:)
    tag_arr = opts[:tags].gsub("`", "").split(" ")
    latest  = opts[:latest].to_i

    unless channel.nsfw?
      event.respond(embeds: embed(title: "Channel must be tagged as NSFW"))
      return
    end

    unless tag_arr.length < 12
      event.respond(embeds: embed(title: "At most 11 tags are allowed"))
      return
    end
    
    unless latest >= 0
      event.respond(embeds: embed(title: "Latest post ID must be greater than 0"))
      return
    end

    if (ch = server.channels.find { |ch| ch.id == channel.id })
      event.respond(content: "Duplicate recording:", embeds: ch.render_embed)
    else
      ch = Channel.new(
        tags:    tag_arr,
        latest:  latest,
        count:   0,
        channel: 
      )
      
      server.channels << ch
      @db.add_recording(
        channel_id: channel.id,
        server_id:  server.id,
        latest:     ch.latest,
        count:      ch.count,
        tags:       ch.tags
      )
      
      event.respond(embeds: ch.render_embed)
    end
  end

  ##
  # List all recordings
  # @param [Discordrb::ApplicationCommandEvent]
  def recordings(event)
    server = @servers[event.server_id]

    if server.channels.empty?
      event.respond(embeds: embed(title: "No recordings"))
      return
    end

    event.defer(ephemeral: false)

    embeds = []
    channels_buf = ""
    post_count_buf = ""
    tags_buf = ""

    # Gather all embeds
    server.channels.each do |ch|
      this_channel = "<##{ch.id}>\n"
      this_post_count = "#{ch.count}\n"
      this_tags = "`#{ch.tags.join(" ")}`\n"

      if (channels_buf.length + this_channel.length) > 1024 \
        || (post_count_buf.length + this_post_count.length) > 1024 \
        || (tags_buf.length + this_tags.length) > 1024
        # Length exceeded, flush
        embeds << [ channels_buf, post_count_buf, tags_buf ]

        channels_buf = post_count_buf = tags_buf = ""
      end

      channels_buf += this_channel
      post_count_buf += this_post_count
      tags_buf += this_tags
    end

    if !channels_buf.empty? || !post_count_buf.empty? || tags_buf.empty?
      embeds << [ channels_buf, post_count_buf, tags_buf ]
    end

    # Dispatch
    event.send_message(content: "Listing #{server.channels.length} recording#{"s" unless server.channels.length == 1}")

    i = 1
    embeds.each do |e|
      event.channel.send_embed() do |embed|
        embed.title = "Recordings (#{i} of #{embeds.length})"
        embed.color = EMBED_COLOR

        embed.add_field(
          name:   "Channels",
          value:  e[0],
          inline: true
        )
  
        embed.add_field(
          name:   "Post count",
          value:  e[1],
          inline: true
        )
  
        embed.add_field(
          name:   "Tags",
          value:  e[2],
          inline: true
        )

        i += 1
      end
    end
  end

  ##
  # Remove a recording
  # @param [Discordrb::ApplicationCommandEvent]
  def remove(event)
    server = @servers[event.server_id]
    channel = @bot.channel(event.symbol_options[:channel].to_i, server:)

    if server.channels.find { |ch| ch.id == channel.id }
      logger.debug("Removing recording for #{channel.id} in #{server.id}") if @debug

      server.channels.delete_if { |ch| ch.id == channel.id }

      @db.del_recording(channel_id: channel.id, server_id: server.id)

      event.respond(embeds: embed(title: "Recording removed"))
    else
      event.respond(embeds: embed(title: "No recording for this channel"))
    end
  end

  ##
  # Describe a channel
  # @param [Discordrb::ApplicationCommandEvent]
  def describe(event)
    server = @servers[event.server_id]
    channel = if event.symbol_options.key?(:channel)
      server.channels.find { |ch| ch.id == event.symbol_options[:channel].to_i }
    else
      server.channels.find { |ch| ch.id == event.channel.id }
    end

    if channel
      event.respond(embeds: channel.render_embed)
    else
      event.respond(embeds: embed(title: "No recording for this channel"))
    end
  end

  ##
  # Refresh this server
  # @param [Discordrb::ApplicationCommandEvent]
  def refresh(event)
    @refresh << event.server.id

    # Wake recording thread
    @recording_thread.run

    event.respond(embeds: embed(title: "Refreshing now"))
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

    @recording_thread.run if @recording_thread.alive?
    @recording_thread.join

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
