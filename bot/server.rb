##
# Represents a server which the bot is in
class Server
  class Channel
    # @return [String] channel ID
    attr_reader :id

    # @return [Array<String>] Array of all tags to search for
    attr_reader :tags

    # @return [Integer] Last post ID in this channel
    attr_reader :latest

    # @param [String] id
    # @param [Array<String>] tags
    # @param [Integer] latest
    def initialize(id:, tags:, latest:)
      @id = id
      @tags = tags
      @latest = latest
    end

    # The database object, aka the tags and latest post
    # @return [Hash]
    def db_h
      {
        tags: @tags,
        latest: @latest
      }
    end

    def to_s
      "<Channel id=#{@id} latest=#{@latest} tags=#{@tags}>"
    end

    # @return [String] compact Discord-ready description of this channel
    def describe
      "<##{@id}> [#{@latest}] => `#{@tags.join(" ")}`"
    end
  end
  # @return [String] The server's unique ID
  attr_reader :id

  # @return [Array<String>] ID of roles in this server that can control the bot
  attr_reader :roles

  # @return [Array<Channel>] IDs of channels in which to post
  attr_reader :channels

  # @return [Discordrb::Server] Server instance
  attr_accessor :server

  # @param [String] id Server ID
  # @param [Array<String>] roles IDs of roles to listen to
  # @param [Array<Channel>] channels objects to post in
  # @param [Discordrb::Server] server Server instance
  def initialize(id:, roles: [], channels: [], server: nil)
    @id = id
    @roles = roles
    @channels = channels
    @server = server
  end

  # Refresh this server's channels
  def refresh
    @channels.each do |ch|
      $stderr.puts ch.id
    end
  end

  # Whether the user has bot permissions in this server
  # @param [Discordrb::Member]
  def allowed?(user)
    # Always allow owner
    return true if user.owner?

    @roles.each do |role|
      return true if user.role?(role)
    end

    false
  end

  def to_s
    "<Server id=#{@id}, roles=#{@roles}, channels=#{@channels.map(&:id)}>"
  end
end
