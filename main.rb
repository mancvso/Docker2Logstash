require 'rubygems'
require 'docker'
require 'colorize'
require 'json'
require 'socket'
require 'bunny'
require 'uri'

class Container < Docker::Container
  Excon.defaults[:read_timeout] = nil
  def logs(metadata,opts = {})
    #logstash_sender = LogstashSender.new(metadata)
    amqp_sender = AMQPSender.new(metadata)
    streamer = lambda do |chunk, remaining_bytes, total_bytes|
      #logstash_sender.sender(chunk.force_encoding('iso-8859-1').encode('utf-8'))
      amqp_sender.sender(chunk.force_encoding('iso-8859-1').encode('utf-8'))
    end
    connection.get(path_for(:logs), opts, :response_block => streamer)
  end

  def self.get(id, opts = {}, conn = Docker.connection)
    container_json = conn.get("/containers/#{URI.encode(id)}/json", opts)
    JSON.parse(container_json)
  end

end

class DockerToLogstash
  def initialize()
    Docker.url = ENV['DOCKER_HOST']
    if ENV.has_key?('DOCKER_CERT_PATH')
      cert_path = ENV['DOCKER_CERT_PATH']
      Docker.options = {
        client_cert: File.join(cert_path, 'cert.pem'),
        client_key: File.join(cert_path, 'key.pem'),
        ssl_ca_file: File.join(cert_path, 'ca.pem'),
        ssl_verify_peer: false
      }
    end
    begin
      puts "#{Docker.version}".green
    rescue Exception => e
      puts "Failed to connect to the docker API. Please check https://github.com/MaksymBilenko/Docker2Logstash/blob/master/README.md".red
      raise e
    end
    @threads = {}

  end

  def thread_manager
    containers = Container.all(:all => true)
    containers.each {|container|
      new_thread(container)
    }
    @threads['daemon'] = Thread.new do
      loop do
        check = Container.all(:all => false)
        check.each { |container|
          if @threads[container.id] == nil
            new_thread(container)
          end
        }
        sleep 5
      end
    end
    begin
      @threads['daemon'].join
    rescue Interrupt
      puts "stopping threads:".yellow
      @threads.each { |id, t|
        puts "stopping thread: #{id}".yellow
        t.kill}
    end
  end

  def new_thread(container)
    puts "Starting thread for container: #{Container.get(container.id)['Name']}".blue
    @threads[container.id] = Thread.new do
      @threads[container.id].abort_on_exception=true
      metadata = Container.get(container.id)
      container.logs(metadata ,stdout: true, stderr: true, stream: true, follow: true)
      puts "Container #{metadata['Name']} (#{metadata['Id']}) Detached!".yellow
    end
  end

end

class LogstashSender
  def initialize(metadata)
    @metadata = metadata
    @host = ENV.has_key?('LOGSTASH_URL') ? URI(ENV['LOGSTASH_URL']).host : '192.168.59.103'
    @port = ENV.has_key?('LOGSTASH_URL') ? URI(ENV['LOGSTASH_URL']).port : '9290'

  end
  def open_socket()
    begin
      TCPSocket.open(@host, @port)
    rescue Exception => e
      sleep 5
      puts "Unable to connect to the Logstash TCP Listner.".yellow
      puts "Please check https://github.com/MaksymBilenko/Docker2Logstash/blob/master/README.md".red
      puts e.to_s.red
      retry
    end
  end

  def sender(chunk)
    buffer = {}
    if valid_json?(chunk) then
      buffer = JSON.parse(chunk).inject({}){|memo,(k,v)| memo[k.to_sym] = v; memo}
    else
      buffer[:Message] = chunk.gsub(/\e\[(\d+)m/, '').gsub(/\x1B\[([0-9]{1,2}(;[0-9]{1,2})?)?[m|K]/,'')
    end

    buffer[:Name] = @metadata['Name']
    buffer[:Image] = @metadata['Config']['Image']
    buffer[:HostName] = @metadata['Config']['Hostname']
    buffer[:Image_Hash] = @metadata['Image']
    buffer[:IP] = @metadata['NetworkSettings']['IPAddress']
    buffer[:ID] = @metadata['Id']

    socket = open_socket()
    socket.puts(buffer.to_json)
    socket.close
  end

  def valid_json?(json)
    begin
      JSON.parse(json)
      return true
    rescue JSON::ParserError => e
      return false
    end
  end

end

class AMQPSender
  def initialize(metadata)
    @metadata = metadata
    @url = ENV.has_key?('RABBITMQ_URL') ? ENV['RABBITMQ_URL'] : 'amqp://guest:guest@localhost:5672'
    @machine = ENV.has_key?('MACHINE_TOKEN') ? ENV['MACHINE_TOKEN'] : 'nomachinetoken'

    begin
      conn = Bunny.new(@url,
        :tls_cert              => "/etc/certs/cert.pem",
        :tls_key               => "/etc/certs/key.pem",
        :tls_ca_certificates   => ["/etc/certs/cacert.pem"])
      conn.start
      channel = conn.create_channel
      @exchange = channel.topic("amq.topic")
    rescue Exception => e
      sleep 5
      puts "Unable to connect to the AMQP Listner.".yellow
      puts e.to_s.red
      retry
    end

  end

  def sender(chunk)
    buffer = {}
    if valid_json?(chunk) then
      buffer = JSON.parse(chunk).inject({}){|memo,(k,v)| memo[k.to_sym] = v; memo}
    else
      buffer[:Message] = chunk.gsub(/\e\[(\d+)m/, '').gsub(/\x1B\[([0-9]{1,2}(;[0-9]{1,2})?)?[m|K]/,'')
    end

    buffer[:Name] = @metadata['Name']
    buffer[:Image] = @metadata['Config']['Image']
    buffer[:HostName] = @metadata['Config']['Hostname']
    buffer[:Image_Hash] = @metadata['Image']
    buffer[:IP] = @metadata['NetworkSettings']['IPAddress']
    buffer[:ID] = @metadata['Id']
    buffer[:Machine] = @machine # MACHINE_TOKEN
    
    @exchange.publish(buffer.to_json, :content_type => "application/json", :routing_key => "antarkt.logs.service." + @metadata['Id'])
  end

  def valid_json?(json)
    begin
      JSON.parse(json)
      return true
    rescue JSON::ParserError => e
      return false
    end
  end

end

logstash = DockerToLogstash.new
logstash.thread_manager
