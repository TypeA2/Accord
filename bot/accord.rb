require "logger/colors"
require "discordrb"

class Accord
  def initialize(token:, prefix:, log_target: STDERR)
    @logger = Logger.new(log_target)
    @accord = Discordrb::Commands::CommandBot.new(token: token, prefix: prefix)

    @accord.command(:ping, &method(:ping))
  end

  # Simple ping/pong for testing
  def ping(event)
    event.respond("Pong!")
    @logger.info("Got Ping, sent Pong")

  end

  # Forwarders
  def stop
    @accord.stop
  end

  def run
    @accord.run
  end
end
