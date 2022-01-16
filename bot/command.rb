require "discordrb"

##
# Slash command wrapper
class Command
  # @return [Symbol]
  attr_reader :name

  # @return [Bool]
  attr_reader :read_only

  # @return [String]
  attr_reader :description

  # @return [Integer]
  attr_reader :id

  # @param [Symbol] name
  # @param [Bool]   read_only
  # @param [String] description
  def initialize(name:, read_only:, description:, &block)
      @name        = name
      @read_only   = read_only
      @description = description

      @constructor = block
  end

  ##
  # Register this command to the given bot
  # @param [Object] instance
  # @param [Discordrb::Bot] bot
  # @param [Server] server Server to register to, if any
  def register(instance, bot, server: nil)
    if @read_only
      # Read-only commands can be accessed by anyone
      cmd = bot.register_application_command(@name, @description, server_id: server&.id) do |cmd|
        @constructor&.call(cmd)
      end

      @id = cmd.id
    else
      # Non-read-only commands can only be accessed by admins and the server owner
      cmd = bot.register_application_command(
        @name, @description, server_id: server&.id, default_permission: false) do |cmd, perms|
        @constructor&.call(cmd)
        server&.admins.union([server.owner.id]).each { |id| perms.allow_user(id) }
      end
      
      @id = cmd.id
    end

    bot.application_command(@name) { |event| instance.method(@name).call(event) }
  end
end
