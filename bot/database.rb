require "json"
require "sqlite3"

require_relative "server"
require_relative "channel"

class Database
  class DatabaseError < RuntimeError
  end

  # @param [String] path sqlite3 file path
  def initialize(path)
    @db = SQLite3::Database::new(path)

    # Ensure foreign keys are handled correctly
    @db.foreign_keys = true

    # Make sure all our tables exist
    @db.execute <<-SQL
      create table if not exists servers (
        id integer primary key
      );
    SQL
    
    @db.execute <<-SQL
      create table if not exists channels (
        channel_id integer primary key,
        server_id integer,
        latest_post integer,
        post_count integer,
        tags text,
        foreign key(server_id) references servers(id) on delete cascade
      );
    SQL
    
    @db.execute <<-SQL
      create table if not exists admins (
        server_id integer,
        user_id integer,
        foreign key(server_id) references servers(id) on delete cascade
      );
    SQL
  end

  ##
  # Get a list of all stored servers
  # @returns [Set<Integer>]
  def servers
    res = Set.new
    @db.execute("select id from servers") do |row|
      res << row[0]
    end

    res
  end

  ##
  # Get a set of all admins for a given server
  # @param [Server] server Server to retrieve admins for
  # @return [Set<Integer>]
  def admins(server)
    res = Set.new
    @db.execute("select user_id from admins where server_id = ?", [server.id]) do |row|
      res << row[0]
    end
    res
  end

  ##
  # Get a list of all channels in a specific server
  # @param [Server] server Server instance to which the channels belong
  # @return [Array<Channel>]
  def channels(server)
    res = []
    @db.execute("select channel_id, latest_post, post_count, tags from channels where server_id = ?",
                [server.id]) do |row|
      res << Channel.new(
        channel: server.channels.find { |ch| ch.id == row[0] },
        latest:  row[1],
        count:   row[2],
        tags:    JSON.parse(row[3])
      )
    end

    res
  end

  ##
  # Add a server to the database
  # @param [Integer] id The server's ID
  def add_server(id)
    @db.execute("insert into servers(id) values (?)", [id])
  end

  ##
  # Remove the server by it's ID and delete any attached data
  # @param [Integer] id The server ID
  def del_server(id)
    @db.execute("delete from servers where id = ?", [id])
  end

  ##
  # Add an admin to the server's admin list
  # @param [Integer] server_id
  # @param [Integer] admin_id
  def add_admin(server_id:, admin_id:)
    @db.execute("insert into admins(server_id, user_id) values (?, ?)", [server_id, admin_id])
  end

  ##
  # Remove an admin from the server's admin lsit
  # @param [Integer] server_id
  # @param [Integer] admin_id
  def del_admin(server_id:, admin_id:)
    @db.execute("delete from admins where server_id = ? and user_id = ?", [server_id, admin_id])
  end

  ##
  # Add a recording
  # @param [Integer] channel_id
  # @param [Integer] server_id
  # @param [Integer] latest
  # @param [Array<String>] tags
  def add_recording(channel_id:, server_id:, latest:, count:, tags:)
    @db.execute("insert into channels(channel_id, server_id, latest_post, post_count, tags) values (?, ?, ?, ?, ?)", [
      channel_id, server_id, latest, count, JSON.generate(tags)
    ])
  end

  ##
  # Remove a channel's recording
  # @param [Integer] channel_id
  # @param [Integer] server_id
  def del_recording(channel_id:, server_id:)
    @db.execute("delete from channels where channel_id = ? and server_id = ?", [channel_id, server_id])
  end

  ##
  # Update a channel's latest post and post count
  # @param [Integer] channel_id
  # @param [Integer] server_id
  # @param [Integer] new_count
  # @param [Integer] latest_post
  def update_channel(channel_id:, server_id:, new_count:, latest_post:)
    @db.execute("update channels set latest_post = ?, post_count = ? where channel_id = ? and server_id = ?", [
      latest_post, new_count, channel_id, server_id
    ])
  end
end
