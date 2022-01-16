require "discordrb"

##
# Represents a channel and the bound tags
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
