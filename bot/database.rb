require "aws-sdk-dynamodb"

##
# AWS/DynamoDB helper methods
class Database
  class DatabaseError < RuntimeError
  end

  ##
  # Get the schema's table name
  # @return [String]
  def table_name
    @@table_def[:table_name]
  end

  ##
  # @param [Aws::DynamoDB::Client] db The AWS DynamoDB client instance to use
  def initialize(db)
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
  # @returns [Array<String>]
  def servers
    @db.scan({
      table_name: table_name,
      filter_expression: "#filter_key = :key_value",
      expression_attribute_names: {
        "#filter_key" => "key"
      },
      expression_attribute_values: {
        ":key_value" => "channels"
      }
    }).to_h[:items].map { |res| res["server"] } # Only retrieve the server key
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
              "key"    => "control_channels"
            }
          }
        },
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
      }).to_h[:item]["values"].each do |channel|
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

    responses = []
    requests.each_slice(25) do |slice|
      responses << @db.batch_write_item({
        request_items: {
          table_name => slice
        }
      })
    end

    responses.inject(0) { |r, v| r + v[:unprocessed_items].size } == 0 ? nil : responses
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
              "server"     => server,
              "key"        => "control_channels",
              "channel_id" => []
            }
          }
        },
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
              "server" => server,
              "key"    => "channels",
              "values" => []
            }
          }
        }
      ]

      requests.push(*req)
    end

    responses = []
    # Limit to 25 items at a time
    requests.each_slice(25) do |slice|
      responses << @db.batch_write_item({
        request_items: {
          table_name => slice
        }
      }).to_h
    end

    # Count the number of unprocessed items
    responses.inject(0) { |r, v| r + v[:unprocessed_items].size } == 0 ? nil : responses
  end

  private
  # Partition by server
  #
  # Every server has:
  # * `control_channels`, where the bot responds to commands
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
