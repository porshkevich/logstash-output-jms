# encoding: utf-8
require "logstash/outputs/base"
require "logstash/namespace"
require "gene_pool"

# Write events to a Jms Broker. Supports both Jms Queues and Topics.
#
# For more information about Jms, see <http://docs.oracle.com/javaee/6/tutorial/doc/bncdq.html>
# For more information about the Ruby Gem used, see <http://github.com/reidmorrison/jruby-jms>
# Here is a config example :
#  jms {
#     delivery_mode => "persistent"
#     pub_sub => true
#     estination => "mytopic"
#     yaml_file => "~/jms.yml"
#     yaml_section => "mybroker"
#  }
#
#
class LogStash::Outputs::Jms < LogStash::Outputs::Base
  config_name "jms"

  default :codec, 'plain'

  # Name of delivery mode to use
  # Options are "persistent" and "non_persistent" if not defined nothing will be passed.
  config :delivery_mode, :validate => :string, :default => nil

  # If pub-sub (topic) style should be used or not.
  # Mandatory
  config :pub_sub, :validate => :boolean, :default => false
  # Name of the destination queue or topic to use.
  # Mandatory
  config :destination, :validate => :string

  # Yaml config file
  config :yaml_file, :validate => :string
  # Yaml config file section name
  # For some known examples, see: [Example jms.yml](https://github.com/reidmorrison/jruby-jms/blob/master/examples/jms.yml)
  config :yaml_section, :validate => :string

  # If you do not use an yaml configuration use either the factory or jndi_name.

  # An optional array of Jar file names to load for the specified
  # JMS provider. By using this option it is not necessary
  # to put all the JMS Provider specific jar files into the
  # java CLASSPATH prior to starting Logstash.
  config :require_jars, :validate => :array

  # Name of JMS Provider Factory class
  config :factory, :validate => :string
  # Username to connect to JMS provider with
  config :username, :validate => :string
  # Password to use when connecting to the JMS provider
  config :password, :validate => :string
  # Url to use when connecting to the JMS provider
  config :broker_url, :validate => :string

  # Name of JNDI entry at which the Factory can be found
  config :jndi_name, :validate => :string
  # Mandatory if jndi lookup is being used,
  # contains details on how to connect to JNDI server
  config :jndi_context, :validate => :hash

  # While the output tries to reuse connections efficiently we have a maximum.
  # This sets the maximum number of open connections the output will create.
  # Setting this too low may mean frequently closing / opening connections
  # which is bad.
  config :pool_max, :validate => :number, :default => 10

  # :yaml_file, :factory and :jndi_name are mutually exclusive, both cannot be supplied at the
  # same time. The priority order is :yaml_file, then :jndi_name, then :factory
  #
  # JMS Provider specific properties can be set if the JMS Factory itself
  # has setters for those properties.
  #
  # For some known examples, see: [Example jms.yml](https://github.com/reidmorrison/jruby-jms/blob/master/examples/jms.yml)

  concurrency :shared

  public
  def register
    require "jms"
    @connection = nil

    if @yaml_file
      @jms_config = YAML.load_file(@yaml_file)[@yaml_section]

    elsif @jndi_name
      @jms_config = {
        :require_jars => @require_jars,
        :jndi_name => @jndi_name,
        :jndi_context => @jndi_context}

    elsif @factory
      @jms_config = {
        :require_jars => @require_jars,
        :factory => @factory,
        :username => @username,
        :password => @password,
        :broker_url => @broker_url,
        :url => @broker_url # "broker_url" is named "url" with Oracle AQ
        }
    end

    @logger.debug("JMS Config being used", :context => @jms_config)
    @connection = JMS::Connection.new(@jms_config)

    @destination_key = @pub_sub ? :topic_name : :queue_name

    logger         = SemanticLogger[self.class]
    SemanticLogger.add_appender(logger: @logger)

    @pool          = GenePool.new(
      name:         '',
      pool_size:    @pool_max,
      warn_timeout: 5,
      timeout:      60,
      close_proc:   nil,
      logger:       logger
    ) do
      session                      = @connection.create_session()
      # Turn on Java class persistence: https://github.com/jruby/jruby/wiki/Persistence
      session.class.__persistent__ = true
      session
    end

    # Handle connection failures
    @connection.on_exception do |jms_exception|
      @logger.error "JMS Connection Exception has occurred: #{jms_exception.inspect}"
    end

  end # def register

  public
  def multi_receive_encoded(events_and_encoded)
    session = nil
    begin
      session = @pool.checkout
      producer = get_producer(session)
      events_and_encoded.each do |event, encoded|
        begin
          producer.send(session.message(encoded))
        rescue javax.jms.JMSException => e
          @logger.error("Failed to send event to JMS", :event => event, :exception => e,
                        :backtrace => e.backtrace)
          session.close rescue nil
          @pool.remove(session)
          session = @pool.checkout
          producer = get_producer(session)
          retry
        rescue => e
          @logger.error("Failed to send event to JMS", :event => event, :exception => e,
                      :backtrace => e.backtrace)
          sleep 10
          retry
        end
      end
    ensure
      producer.close if producer
      @pool.checkin(session) if session
    end
  end # multi_receive_encoded

  def get_producer(session)
    producer = session.create_producer(session.create_destination(@destination_key => @destination))
    if !@delivery_mode.nil?
      case @delivery_mode
      when "persistent"
        producer.delivery_mode_sym = :persistent
      when "non_persistent"
        producer.delivery_mode_sym = :non_persistent
      end
    end
    producer
  end # producer

  def close
    @pool.close()
    @connection.close()
  end
end # class LogStash::Output::Jms
