require 'sneakers'
require 'sneakers/metrics/logging_metrics'
require 'sneakers/handlers/maxretry'
require 'json'
require 'oj'
require 'rollbar'

opts = {
  amqp: ENV['ampq_address'] || 'amqp://localhost:5672',
  vhost: ENV['ampq_vhost'] || '/',
  exchange: 'sneakers',
  exchange_type: :direct,
  metrics: Sneakers::Metrics::LoggingMetrics.new,
  handler: Sneakers::Handlers::Maxretry
}

Sneakers.configure(opts)
Sneakers.logger.level = ENV['log_level'] == 'debug' ? Logger::DEBUG : Logger::INFO

Rollbar.configure do |config|
  config.access_token = ENV['rollbar_access_token']
  config.environment = ENV['RACK_ENV']
  config.enabled = ENV['RACK_ENV'] == 'staging' || ENV['RACK_ENV'] == 'production'
end

module Harmony
  module Service
    class RpcService
  
      include Sneakers::Worker
  
      def work_with_params(message, delivery_info, metadata)
        begin
          logger.debug "Request: #{message}"
          request = Oj.load(message)
          result = work_with_request(request)
          json = Oj.dump(result)
          logger.debug "Response: #{json}"
          send_response(json, metadata.reply_to, metadata.correlation_id)
          ack!
        rescue StandardError => error
          logger.error error.message
          logger.error error.backtrace.join("\n")
          
          Rollbar.error(error)
          
          error_response = ErrorResponse.new
          error_response.message = "An error occured."
          error_response.detailed_message = error.message
          json = Oj.dump(error_response)
          logger.debug "Response: #{json}"  
            
          send_response(json, metadata.reply_to, metadata.correlation_id)
          reject!
        end
      end
  
      def stop
        super
        #reply_to_exchange.close # not working
        reply_to_connection.close
      end
  
      def reply_to_connection
        @reply_to_connection ||= create_reply_to_connection
      end
  
      def create_reply_to_connection
        opts = Sneakers::CONFIG
        conn = Bunny.new(opts[:amqp], :vhost => opts[:vhost], :heartbeat => opts[:heartbeat], :logger => Sneakers::logger)
        conn.start
        conn
      end
  
      def reply_to_exchange
        @reply_to_queue ||= create_reply_to_exchange
      end
  
      def create_reply_to_exchange
        ch = reply_to_connection.create_channel
        ch.exchange(AMQ::Protocol::EMPTY_STRING, :auto_delete => true)    
      end
  
      def send_response(result, reply_to, correlation_id)
        reply_to_exchange.publish(result, :routing_key => reply_to, :correlation_id => correlation_id)
      end
    end
  end
end