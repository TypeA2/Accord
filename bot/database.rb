require "aws-sdk-dynamodb"

require_relative "server"

##
# AWS/DynamoDB helper methods
class Database
  BACKOFF_SEQUENCE = [ 1, 2, 3, 4, 6, 8, 12, 16, 24, 32 ]
  MAX_RETRIES = 10

  class DatabaseError < RuntimeError
  end

  # Automatic exponential backoff
  # @param [Symbol] method
  # @param [Hash, Array] request
  def backoff(method, request)
    retries = 0
    request = {
      table_name => request
    }

    until request.empty?
      response = @db.method(method).call({
        request_items: request
      })

      if response.members.include?(:responses)
        if response.responses.key?(table_name)
          # Read request
          response.responses[table_name].each do |obj|
            yield obj if block_given?
          end

          request = response.unprocessed_keys
        end

      else
        # Write request
        request = response.unprocessed_items
      end

      unless request.empty?
        Accord.logger.debug("Retrying request, got: #{request} #{response}")

        raise "AWS error for #{method} after #{MAX_RETRIES} retries" if retries == MAX_RETRIES

        # Exponential-ish backoff
        sleep BACKOFF_SEQUENCE[retries]

        retries += 1
      end
    end
  end

  # @return [String]
  def table_name
    # noinspection RubyYardReturnMatch
    @@table_def[:table_name]
  end

  # @param [Aws::DynamoDB::Client] db The AWS DynamoDB client instance to use
  def initialize(db)
    # @type [Aws::DynamoDB::Client]
    @db = db
  end

  ##
  # Create the table required for the bot on the given connection
  #
  # @returns The created table status
  def create_table
    response = @db.create_table(@@table_def)
    raise DatabaseError.new("Table creation failed") unless response.table_description.table_status

  rescue StandardError => e
    raise DatabaseError.new(e.message)

  end

  ##
  # Return whether the required table exists
  #
  # @returns [Boolean]
  def table_exists?
    res = @db.list_tables
    res[:table_names].include?(table_name)
  end

  ##
  # Get a list of all stored servers
  # @returns [Array<Hash>]
  def servers
    res = @db.scan({
      table_name: table_name,
      filter_expression: "#filter_key = :val1 OR #filter_key = :val2 OR #filter_key = :val3",
      expression_attribute_names: {
        "#filter_key" => "key"
      },
      expression_attribute_values: {
        ":val1" => "control_roles",
        ":val2" => "control_channels",
        ":val3" => "channels"
      }
    }).to_h[:items]

    # Extract all server info to a tree structure
    mapping = Hash.new { |hash, key| hash[key] = {}}
    res.each do |server|
      id = server["server"]
      case server["key"]
        when "control_roles"
          mapping[id][:control_roles] = server["roles"]
        when "channels"
          mapping[id][:channels] = server["channels"]
        else
          raise "Unexpected values #{server["key"]} encountered"
      end
    end

    mapping
  end

  ##
  # Get all channel data by ID
  # @param [Discordrb::Server] server The server ID the channels belong to
  # @param [Array<String>] ids
  # @returns [Array<Server::Channel>]
  def channels(server, ids)
    # @type [Array<Server::Channels>]
    res = []

    # Consume 100 items at a time
    ids.each_slice(100) do |slice|
      request = {
        keys: slice.map do |channel|
          {
            "server" => server.id.to_s,
            "key"    => channel
          }
        end,
        projection_expression:      "#key,channel",
        expression_attribute_names: {
          "#key" => "key"
        }
      }

      backoff(:batch_get_item, request) do |obj|
        res << Server::Channel.new(
          id:      obj["key"],
          tags:    obj["channel"]["tags"],
          latest:  obj["channel"]["latest"].to_i,
          channel: server.channels.find { |ch| ch.id.to_s == obj["key"] })
      end
    end

    res
  end

  ##
  # Register and add a channel
  # @param [Server] server
  # @param [Server::Channel] channel
  def add_channel(server, channel)
    backoff(:batch_write_item, [
      {
        put_request: {
          item: {
            "server"   => server.id,
            "key"      => "channels",
            "channels" => server.channels.map { |c| c.id } << channel.id
          }
        }
      },
      {
        put_request: {
          item: {
            "server"  => server.id,
            "key"     => channel.id,
            "channel" => channel.db_h
          }
        }
      }
    ])
  end

  # Update channel data
  # @param [String] server
  # @param [Array<Server::Channel>] channels
  def update_channels(server, channels)
    channels.each_slice(25) do |slice|
      backoff(:batch_write_item, slice.map do |ch|
          {
            put_request: {
              item: {
                "server"  => server,
                "key"     => ch.id,
                "channel" => ch.db_h
              }
            }
          }
      end)
    end
  end

  # Remove a channel
  # @param [Server] server
  # @param [Server::Channel] channel
  def delete_channel(server, channel)
    backoff(:batch_write_item, [
      {
        delete_request: {
          key: {
            "server" => server.id,
            "key"    => channel.id
          }
        }
      },
      {
        put_request: {
          item: {
            "server"   => server.id,
            "key"      => "channels",
            "channels" => server.channels.select { |c| c.id != channel.id }.map { |c| c.id }
          }
        }
      }
    ])
  end


  ##
  # Deletes the specified servers
  #
  # @param [Array<String>] servers
  def delete_servers(servers)
    requests = []

    servers.each do |server|
      # Prepare to delete the 3 control rows
      req = [
        {
          delete_request: {
            key: {
              "server" => server,
              "key"    => "control_roles"
            }
          }
        },
        {
          delete_request: {
            key: {
              "server" => server,
              "key"    => "channels"
            }
          }
        }
      ]

      requests.push(*req)

      # Get all channel rows
      @db.get_item({
        table_name: table_name,
        key: {
          "server" => server,
          "key"    => "channels"
        }
      }).to_h[:item]["channels"].each do |channel|
        requests << {
          delete_request: {
            key: {
              "server" => server,
              "key"    => channel
            }
          }
        }
      end
    end

    requests.each_slice(25) { |slice| backoff(:batch_write_item, slice) }
  end

  ##
  # Add servers to storage
  #
  # @param [Array<String>] servers
  def add_servers(servers)
    requests = []

    servers.each do |server|
      req = [
        {
          put_request: {
            item: {
              "server" => server,
              "key"    => "control_roles",
              "roles"  => []
            }
          }
        },
        {
          put_request: {
            item: {
              "server"   => server,
              "key"      => "channels",
              "channels" => []
            }
          }
        }
      ]

      requests.push(*req)
    end

    requests.each_slice(25) { |slice| backoff(:batch_write_item, slice) }
  end

  ##
  # Update the roles parameter server-side
  #
  # @param [Server] server
  def set_roles(server)
    req = {
      item: {
        "server" => server.id,
        "key"    => "control_roles",
        "roles"  => server.roles
      },
      table_name: table_name
    }

    @db.put_item(req)
  end

  private
  # Partition by server
  #
  # Every server has:
  # * `control_roles`, which roles the bot responds to (bot always responds to server owner)
  # * `channels`, list of channels the bot should post in
  #
  # For every channel in `channels`, a row is created with the channel ID as the sort key, and the following object:
  #   {
  #     tags: String,   # Danbooru tags corresponding to this channel
  #     latest: Integer # The latest post in this channel, so the next post's ID
  #                     # with the corresponding tags should exceed this number
  #   }
  @@table_def = {
    table_name: "accord",
    key_schema: [
      {
        attribute_name: "server",
        key_type: "HASH"
      },
      {
        attribute_name: "key",
        key_type: "RANGE"
      }
    ],
    attribute_definitions: [
      {
        attribute_name: "server",
        attribute_type: "S"
      },
      {
        attribute_name: "key",
        attribute_type: "S"
      }
    ],
    provisioned_throughput: {
      read_capacity_units: 5,
      write_capacity_units: 5
    }
  }
end
