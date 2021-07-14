##
# Represents a server which the bot is in
class Server
  # @return [String] The server's unique ID
  attr_reader :id

  # @return [Array<String>] ID of roles in this server that can control the bot
  attr_reader :roles

  # @return [Array<String>] IDs of channels in which to post
  attr_reader :channels

  # @return [Discordrb::Server] Server instance
  attr_accessor :server

  # @param [String] id Server ID
  # @param [List<String>] roles IDs of roles to listen to
  # @param [List<String>] channels IDs of channels to post in
  # @param [Discordrb::Server] server Server instance
  def initialize(id:, roles: [], channels: [], server: nil)
    @id = id
    @roles = roles
    @channels = channels
    @server = server
  end

  def to_s
    "#<Server @id=#{@id}, @roles=#{@roles}, @channels=#{@channels}>"
  end
end
