require "net/https"
require "uri"
require "json"
require "time"

module Danbooru
  PAGE_SIZE = 200.0

  class User
    # @return [String]
    attr_reader :login

    # @return [String]
    attr_reader :key

    # @param [String] login
    # @param [String] key
    def initialize(login:, key:)
      @login = login
      @key = key
    end

    # @return [Hash]
    def to_h
      {
        login: @login,
        api_key: @key
      }
    end
  end

  class Post
    # @return [Integer]
    attr_accessor :id

    # @return [Time]
    attr_accessor :created_at

    # @param [Integer] id
    # @param [Time] created_at
    def initialize(id, created_at)
      @id = id
      @created_at = created_at
    end

    # @return [String]
    def url
      "https://danbooru.donmai.us/posts/#{@id}"
    end

    def inspect
      "<Post id=#{@id}, created_at=#{@created_at}>"
    end
  end

  # @param [User] user
  # @param [Array<String>] tags
  # @return [Integer]
  def self.post_count(user, tags)
    uri = URI.parse("https://danbooru.donmai.us/counts/posts.json")
    uri.query = URI.encode_www_form(user.to_h.merge({
      tags: tags.join(" ")
    }))

    JSON.parse(Net::HTTP.get(uri))["counts"]["posts"]
  rescue JSON::ParserError => e
    Accord.logger.warn("JSON parsing error in Danbooru::post_count, Danbooru may be down: #{e.to_s}")
    0
  end

  # @param [User] user
  # @param [Integer] page
  # @param [Array<String>] tags
  # @return [Array<Post>]
  def self.posts(user, page, tags)
    # @type [Array<Post>]
    posts = []
    uri = URI.parse("https://danbooru.donmai.us/posts.json")
    uri.query = URI.encode_www_form(user.to_h.merge({
      tags:  tags.join(" "),
      page:  page,
      limit: PAGE_SIZE
    }))

    JSON.parse(Net::HTTP.get(uri)).map { |p| Post.new(p["id"], Time.parse(p["created_at"])) }
  rescue JSON::ParserError => e
    Accord.logger.warn("JSON parsing error in Danbooru::posts, Danbooru may be down: #{e.to_s}")
    []
  end
end
