require "forwardable"


require "discordrb"

##
# Represents a channel and the bound tags
class Channel
  extend Forwardable

  def_delegators :@channel, :id

  # @return [Array<String>] Array of all tags to search for
  attr_reader :tags

  # @return [Integer] Last post ID in this channel
  attr_accessor :latest

  # @return[Integer] Total number of posts
  attr_accessor :count

  # @return [Discordrb::Channel] Channel instance this object belongs to
  attr_reader :channel

  # @param [Array<String>] tags
  # @param [Integer] latest
  # @param [Discordrb::Channel] channel
  def initialize(tags:, latest:, count:, channel:)
    @tags   = tags
    @latest  = latest
    @count   = count
    @channel = channel
  end

  def to_s
    "<Channel id=#{id} latest=#{@latest} count=#{@count} tags=#{@tags}>"
  end

  # @return [String] compact Discord-ready description of this channel
  def describe
    "<##{id}> [#{@count} posts, up to #{@latest}] => `#{@tags.join(" ")}`"
  end

  # @return [String] Compact-er embed-ready description, without the channel ID
  def render_field
    "[#{@count} posts, up to #{@latest}] => `#{@tags.join(" ")}`"
  end

  # @return [Array<String>] All tags used to describe this channel
  def prepare_tags
    @tags.clone << "id:>#{@latest}"
  end

  # @return [Array<Hash>]
  def render_embed
    [Accord::EMBED_BASE.merge({
      title: "Recording",
      fields: [
        { name: "Channel",     value: "<##{id}>"             },
        { name: "Latest post", value: @latest.to_s           },
        { name: "Post count",  value: @count.to_s            },
        { name: "Tags",        value: "`#{@tags.join(" ")}`" }
      ]
    })]
  end
end
