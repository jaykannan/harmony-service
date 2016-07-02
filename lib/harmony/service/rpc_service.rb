require 'sneakers'
require 'sneakers/metrics/logging_metrics'
require 'sneakers/handlers/maxretry'
require 'json'

opts = {
  amqp: ENV['ampq_address'] || 'amqp://localhost:5672',
  vhost: ENV['ampq_vhost'] || '/',
  exchange: 'sneakers',
  exchange_type: :direct,
  metrics: Sneakers::Metrics::LoggingMetrics.new,
  handler: Sneakers::Handlers::Maxretry
}

Sneakers.configure(opts)
Sneakers.logger.level = Logger::INFO

class Harmony::Service::RpcService
  
  include Sneakers::Worker
  from_queue ENV['harmony_queue']
  
  def work_with_params(message, delivery_info, metadata)
    params = JSON.parse(message)   
    result = work_with_message_params(params)
    send_response(result.to_json, metadata.reply_to, metadata.correlation_id)
    ack!
  end
  
  def stop
    super
    reply_to_exchange.close
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
    ch.default_exchange    
  end
  
  def send_response(result, reply_to, correlation_id)
    reply_to_exchange.publish(result, :routing_key => reply_to, :correlation_id => correlation_id)
  end
  
end