require 'socket'
require 'fog'

module SimpleJob

# A SimpleJob::JobQueue implementation that uses AWS SQS
class SQSJobQueue < JobQueue

  DEFAULT_POLL_INTERVAL = 1

  # Registers this queue implementation with SimpleJob::JobQueue with identifier "sqs".
  register_job_queue 'sqs', self

  def self.config(options = {})
    @config ||= {
      :queue_prefix => ENV['SIMPLE_JOB_SQS_JOB_QUEUE_PREFIX'],
      :default_visibility_timeout => 60,
      :environment => (defined?(Rails) && Rails.env) || 'development',
      :cloud_watch_namespace => nil,
    }

    @config.merge!(options) if options

    raise 'must configure :queue_prefix using SQSJobQueue.config' if !@config[:queue_prefix]

    @config
  end

  def self.default_queue
    @default_queue || super
  end

  def self.define_queue(type, options = {})
    type = type.to_s

    options = {
      :visibility_timeout => config[:default_visibility_timeout],
      :default => false,
    }.merge(options)

    queue = self.new(type, options[:visibility_timeout])
    self.queues ||= {}
    self.queues[type] = queue

    @default_queue = queue if options[:default]
    
    queue
  end

  def self.get_queue(type, options = {})
    type = type.to_s
    (self.queues || {})[type] || super
  end

  def enqueue(message, options = {})
    raise("enqueue expects a raw string") unless message.is_a?(String)
    sqs_queue.send_message(message)
  end

  # Polls the queue, matching incoming messages with registered jobs, and
  # executing the proper job/version.
  #
  # If called without a block, it will simply call the #execute method of the
  # matched job. A block may be passed to add custom logic, but in this case
  # the caller is responsible for calling #execute. The block will be passed
  # two arguments, the matching job definition (already populated with the
  # contents of the message) and the raw AWS message.
  #
  # The queue's configured visibility timeout will be used unless the
  # :visibility_timeout option is passed (as a number of seconds).
  #
  # By default, the message's 'sent_at', 'receive_count', and
  # 'first_received_at' attributes will be populated in the AWS message, but
  # this may be overridden by passing an array of symbols to the :attributes
  # option.
  #
  # By default, errors during job execution or message polling will be logged
  # and the polling will continue, but that behavior may be changed by setting
  # the :raise_exceptions option to true.
  #
  # By defult, this method will poll indefinitely. If you pass an :idle_timeout
  # option, the polling will stop and this method will return if that number
  # of seconds passes without receiving a message. In both cases, the method
  # will safely complete processing the current message and return if a HUP,
  # INT, or TERM signal is sent to the process.
  #
  # Note that this method will override any signal handlers for the HUP, INT,
  # or TERM signals during its execution, but the previous handlers will be
  # restored once the method returns.
  def poll(options = {}, &block)
    options = {
      :visibility_timeout => visibility_timeout,
      :attributes => [ :sent_at, :receive_count, :first_received_at ],
      :raise_exceptions => false,
      :idle_timeout => nil,
      :poll_interval => DEFAULT_POLL_INTERVAL,
      :max_executions => nil
    }.merge(options)

    message_handler = block || lambda do |definition, message|
      execute_method = definition.method(:execute)
      arguments = []
      if execute_method.arity >= 1
        arguments << message
      end
      execute_method.call(*arguments)
    end

    exit_next = false

    logger.debug 'trapping terminate signals with function to exit loop'
    signal_exit = lambda do
      logger.info "caught signal to shutdown; finishing current message and quitting..."
      exit_next = true
    end
    previous_traps = {}
    ['HUP', 'INT', 'TERM'].each do |signal|
      previous_traps[signal] = Signal.trap(signal, signal_exit)
    end

    last_message_at = Time.now

    max_executions = options[:max_executions]
    loop do
      break if max_executions && (max_executions <= 0)
      last_message = nil
      current_start_milliseconds = get_milliseconds
      current_job_type = 'unknown'
      begin
        sqs_queue.receive_messages(options) do |message|
          last_message = message
          raw_message = JSON.parse(message.body)
          current_job_type = raw_message['type']
          definition_class = JobDefinition.job_definition_class_for(raw_message['type'], raw_message['version'])

          raise('no definition found') if !definition_class

          if definition_class.max_attempt_count && (message.receive_count > definition_class.max_attempt_count)
            raise('max attempt count reached') 
          end

          definition = definition_class.new.from_json(message.body)
          message_handler.call(definition, message)
        end

        log_execution(true, last_message, current_job_type, current_start_milliseconds)

        break if options[:idle_timeout] && ((Time.now - last_message_at) > options[:idle_timeout])

        unless last_message
          Kernel.sleep(options[:poll_interval]) unless options[:poll_interval] == 0
        end
      rescue Exception => e
        log_execution(false, last_message, current_job_type, current_start_milliseconds)

        if options[:raise_exceptions]
          raise e
        else
          logger.error("unable to process message: #{e.message}")
          logger.error("message body: #{last_message && last_message.body}")
          logger.error(e.backtrace.join("\n  "))
        end
      end
      max_executions -= 1 if max_executions
      break if exit_next
    end

    logger.debug 'restoring previous signal traps'
    previous_traps.each do |signal, command|
      Signal.trap(signal, command)
    end

    logger.info "shutdown successful"
  end

  private

  class << self
    attr_accessor :queues
  end

  attr_accessor :queue_name, :sqs_queue, :visibility_timeout, :cloud_watch

  def initialize(type, visibility_timeout)
    sqs = ::AWS::SQS.new
    self.queue_name = "#{self.class.config[:queue_prefix]}-#{type}-#{self.class.config[:environment]}"
    self.sqs_queue = sqs.queues.create(queue_name)
    self.visibility_timeout = visibility_timeout
    self.cloud_watch = Fog::AWS::CloudWatch.new(
      :aws_access_key_id => AWS.config.access_key_id,
      :aws_secret_access_key => AWS.config.secret_access_key
    )
  end

  def logger
    JobQueue.config[:logger]
  end

  def get_milliseconds(time = Time.now)
    (time.to_f * 1000).round
  end

  def log_execution(successful, message, job_type, start_milliseconds)
    if self.class.config[:cloud_watch_namespace]
      timestamp = DateTime.now.to_s
      environment = self.class.config[:environment]
      hostname = Socket.gethostbyname(Socket.gethostname).first

      message_dimensions = [
        { 'Name' => 'Environment', 'Value' => environment }, 
        { 'Name' => 'SQSQueueName', 'Value' => queue_name },
        { 'Name' => 'Host', 'Value' => hostname },
      ]

      job_dimensions = message_dimensions + [
        { 'Name' => 'JobType', 'Value' => job_type },
      ]

      metric_data = [
        {
          'MetricName' => 'MessageCheckCount',
          'Timestamp' => timestamp,
          'Unit' => 'Count',
          'Value' => 1,
          'Dimensions' => message_dimensions
        },
        {
          'MetricName' => 'MessageReceivedCount',
          'Timestamp' => timestamp,
          'Unit' => 'Count',
          'Value' => message ? 1 : 0,
          'Dimensions' => message_dimensions
        },
        {
          'MetricName' => 'MessageMissCount',
          'Timestamp' => timestamp,
          'Unit' => 'Count',
          'Value' => message ? 0 : 1,
          'Dimensions' => message_dimensions
        }
      ]
       
      if message
        now = get_milliseconds

        metric_data.concat([
          {
            'MetricName' => 'ExecutionCount',
            'Timestamp' => timestamp,
            'Unit' => 'Count',
            'Value' => 1,
            'Dimensions' => job_dimensions
          },
          {
            'MetricName' => 'SuccessCount',
            'Timestamp' => timestamp,
            'Unit' => 'Count',
            'Value' => successful ? 1 : 0,
            'Dimensions' => job_dimensions
          },
          {
            'MetricName' => 'ErrorCount',
            'Timestamp' => timestamp,
            'Unit' => 'Count',
            'Value' => successful ? 0 : 1,
            'Dimensions' => job_dimensions
          },
          {
            'MetricName' => 'ExecutionTime',
            'Timestamp' => timestamp,
            'Unit' => 'Milliseconds',
            'Value' => now - start_milliseconds,
            'Dimensions' => job_dimensions
          }
        ])

        if successful
          metric_data.concat([
            {
              'MetricName' => 'TimeToCompletion',
              'Timestamp' => timestamp,
              'Unit' => 'Milliseconds',
              'Value' => now - get_milliseconds(message.sent_at),
              'Dimensions' => job_dimensions
            },
            {
              'MetricName' => 'ExecutionAttempts',
              'Timestamp' => timestamp,
              'Unit' => 'Count',
              'Value' => message.receive_count,
              'Dimensions' => job_dimensions
            }
          ])
        end
      end

      cloud_watch.put_metric_data(self.class.config[:cloud_watch_namespace], metric_data)
    end
  end

end
end

