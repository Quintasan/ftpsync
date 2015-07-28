require "ftpsync/version"
require "net/ftp"
require "net/ftp/list"
require 'fileutils'

module FtpSync
  class Simple
    attr_accessor :server, :port, :username, :password, :passive

    def initialize(server, username, password, options = {})
      @server = server
      @port = options[:port] || 21
      @username = username
      @password = password
      @passive = options[:passive] || false
      @verbose = options[:verbose] || false

      @connection = nil
      @level = 0
    end

    def pull_dir(remotepath, localpath, options = {}, &block)
      FileUtils.mkpath(localpath) unless File.exist?(localpath) and log "Creating #{localpath} directory"
      connect! unless @connection
      @level += 1

      todelete = Dir.glob(File.join(localpath, '*'))
      directories = []
      files = []

      @connection.list(remotepath) do |e|
        entry = Net::FTP::List.parse(e)

        paths = [ "#{remotepath}/#{entry.basename}".gsub(/\/+/, '/'),  File.join(localpath, entry.basename)]

        if entry.dir?
          if entry.name == "." or entry.name == ".."
            next
          else
            directories << paths
          end
        elsif entry.file?
          if options[:since]
            files << paths unless File.exist?(paths[1]) and entry.mtime < File.mtime(paths[1]) and entry.filesize == File.size(paths[1])
          else
            files << paths
          end
        end
        todelete.delete paths[1]
      end

      directories.each do |paths|
        remotedir, localdir = paths
        pull_dir(remotedir, localdir, options, &block)
      end

      files.each do |paths|
        remotefile, localfile = paths
        begin
          log "#{remotefile} => #{localfile}"
          @connection.get(remotefile, localfile)
          if block_given?
            log "Executing block"
            yield(localfile)
          end
        rescue Net::FTPPermError
          log "Error when reading #{remotefile}"
          raise Net::FTPPermError unless options[:skip_errors]
        end
      end

      @level -= 1
      close! if @level == 0
    end

    def connect!
      @connection = Net::FTP.new
      log "Connecting to #{@server}:#{@port} in #{@passive ? "passive" : "active"} mode"
      @connection.connect(@server, @port)
      @connection.passive = @passive
      log "Logging in as #{@username}:#{@password}"
      @connection.login(@username, @password)
      log "Successfully opened connection to #{@server}:#{@port}"
    end

    def close!
      @connection.close
      log "Closed connection to #{@server}:#{@port}"
    end

    def log(message)
      $stderr.puts message if @verbose
    end

  end
end
