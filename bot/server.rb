##
# Represents a server which the bot is in
class Server
  class Channel
    # @return [String] channel ID
    attr_reader :id

    # @return [Array<String>] Array of all tags to search for
    attr_reader :tags

    # @return [Integer] Last post ID in this channel
    attr_accessor :latest

    # @return [Discordrb::Channel] Channel instance this object belongs to
    attr_reader :channel

    # @param [String] id
    # @param [Array<String>] tags
    # @param [Integer] latest
    # @param [Discordrb::Channel] channel
    def initialize(id:, tags:, latest:, channel:)
      @id = id
      @tags = tags
      @latest = latest
      @channel = channel
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

    # @return [Array<String>] All tags used to describe this channel
    def prepare_tags
      @tags.clone << "id:>#{@latest}"
    end
  end
  # @return [String] The server's unique ID
  attr_reader :id

  # @return [Array<String>] ID of roles in this server that can control the bot
  attr_reader :roles

  # @return [Array<Channel>] IDs of channels in which to post
  attr_reader :channels

  # @return [Discordrb::Server] Server instance
  attr_reader :server

  # @param [String] id Server ID
  # @param [Array<String>] roles IDs of roles to listen to
  # @param [Array<Channel>] channels objects to post in
  # @param [Discordrb::Server] server Server instance
  def initialize(id:, roles:, channels:, server:)
    @id = id
    @roles = roles
    @channels = channels
    @server = server
  end

  # Refresh this server's channels
  # @param [Danbooru::User] user
  def refresh(user)
    Accord.logger.info("Refreshing #{@server.name} (#{@id}")

    changed = []
    @channels.each do |ch|
      count = Danbooru.post_count(user, ch.prepare_tags)

      Accord.logger.debug("Got #{count} post#{count == 1 ? "" : "s"} for tags #{ch.prepare_tags.join("+")}")
      if count > 0
        pages = (count / Danbooru::PAGE_SIZE).ceil

        # @type [Array<Danbooru::Post>]
        posts = []

        (1..pages).each do |i|
          posts += Danbooru.posts(user, i, ch.prepare_tags)
        end

        new_max = posts.map { |p| p.id }.max

        posts.each do |post|
          ch.channel.send_message("`[#{post.created_at}]` https://danbooru.donmai.us/posts/#{post.id}")
        end

        Accord.logger.debug "Last: #{new_max}"

        ch.latest = new_max

        changed << ch
      end
    end

    Accord.db.update_channels(@id, changed)
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
