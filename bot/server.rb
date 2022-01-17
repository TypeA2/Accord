require "forwardable"

require "discordrb"

require_relative "channel"

##
# Represents a server which the bot is in
class Server
  extend Forwardable
  
  # @return [Set<Integer>] ID of users in this server that can control the bot
  attr_reader :admins

  # @return [Array<Channel>] IDs of channels in which to post
  attr_reader :channels

  # @return [Discordrb::Server] Server instance
  attr_reader :server

  def_delegators :@server, :owner, :id, :bot, :member, :name

  # @param [Integer] id Server ID
  # @param [Set<Integer>] admins IDs of  users to listen to
  # @param [Array<Channel>] channels objects to post in
  # @param [Discordrb::Server] server Server instance
  def initialize(admins:, channels:, server:)
    @admins = admins
    @channels = channels
    @server = server
  end

  # Refresh this server's channels
  # @param [Danbooru::User] user
  # @param [Database] db
  def refresh(user, db)
    Accord.logger.info("Refreshing #{@server.name} (#{@server.id})")

    @channels.each do |ch|
      count = Danbooru.post_count(user, ch.prepare_tags)

      Accord.logger.debug("Got #{count} post#{count == 1 ? "" : "s"} for tags #{ch.prepare_tags.join("+")}")
      if count > 0
        begin
          pages = (count / Danbooru::PAGE_SIZE).ceil

          # @type [Array<Danbooru::Post>]
          posts = []

          (1..pages).each do |i|
            posts += Danbooru.posts(user, i, ch.prepare_tags)
          end

          # @type post [Danbooru::Post]
          posts.sort_by! { |post| post.id }

          posts.each do |post|
            ch.channel.send_message("`[#{post.created_at}]`\nhttps://danbooru.donmai.us/posts/#{post.id}")
            ch.latest = post.id
            ch.count += 1

            # Light attempt at preemptive rate limiting
            sleep 1
          end
  
          Accord.logger.debug "Last: #{ch.latest}"
        ensure
          db.update_channel(
            channel_id:  ch.id,
            server_id:   @server.id,
            new_count:   ch.count,
            latest_post: ch.latest
          )
        end
      end
    end

  end

  # Sort all channels
  def sort
    @channels.sort_by! { |ch| ch.channel.name }
  end

  # Whether the user has bot permissions in this server
  # @param [Discordrb::Member]
  def allowed?(user)
    # Always allow owner
    user.owner? || @admins.include?(user.id)
  end

  def to_s
    "<Server id=#{@id}, admins=#{@admins}, channels=#{@channels.map(&:id)}>"
  end
end
