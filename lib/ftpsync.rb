# frozen_string_literal: true

require 'fileutils'
require 'ftpsync/version'
require 'net/ftp'
require 'net/ftp/list'

module FtpSync
  # Synchronizes directories against an FTP server.
  class Simple
    attr_accessor :server, :port, :username, :password, :passive

    def initialize(server, username, password, options = {})
      @server = server
      @port = options.fetch(:port, 21)
      @username = username
      @password = password
      @passive = options.fetch(:passive, false)
      @verbose = options.fetch(:verbose, false)

      @connection = nil
      @level = 0
    end

    # Recursively pulls +remotepath+ into +localpath+.
    #
    # Options:
    #   :since       skip files that already exist locally and are up to date
    #   :skip_errors rescue Net::FTPPermError and keep going
    #
    # If a block is given, it is invoked with the local path of each
    # downloaded file.
    def pull_dir(remotepath, localpath, options = {}, &block)
      ensure_local_directory(localpath)
      connect! unless @connection
      @level += 1

      directories, files = scan_directory(remotepath, localpath, options)

      directories.each do |remote_dir, local_dir|
        pull_dir(remote_dir, local_dir, options, &block)
      end

      files.each do |remote_file, local_file|
        download(remote_file, local_file, options, &block)
      end

      @level -= 1
      close! if @level.zero?
    end

    def connect!
      @connection = Net::FTP.new
      log "Connecting to #{@server}:#{@port} in #{@passive ? 'passive' : 'active'} mode"
      @connection.connect(@server, @port)
      @connection.passive = @passive
      log "Logging in as #{@username}"
      @connection.login(@username, @password)
      log "Successfully opened connection to #{@server}:#{@port}"
    end

    def close!
      @connection.close
      @connection = nil
      log "Closed connection to #{@server}:#{@port}"
    end

    def log(message)
      warn message if @verbose
    end

    private

    def ensure_local_directory(localpath)
      return if File.directory?(localpath)

      FileUtils.mkpath(localpath)
      log "Creating #{localpath} directory"
    end

    def scan_directory(remotepath, localpath, options)
      directories = []
      files = []

      @connection.list(remotepath) do |line|
        entry = Net::FTP::List.parse(line)
        next if %w[. ..].include?(entry.name)

        remote_child = join_remote(remotepath, entry.basename)
        local_child = File.join(localpath, entry.basename)

        if entry.dir?
          directories << [remote_child, local_child]
        elsif entry.file?
          files << [remote_child, local_child] unless skip_file?(local_child, entry, options)
        end
      end

      [directories, files]
    end

    def skip_file?(local_path, entry, options)
      return false unless options[:since]
      return false unless File.file?(local_path)

      entry.mtime < File.mtime(local_path) && entry.filesize == File.size(local_path)
    end

    def download(remote_file, local_file, options)
      log "#{remote_file} => #{local_file}"
      @connection.get(remote_file, local_file)
      yield(local_file) if block_given?
    rescue Net::FTPPermError => e
      log "Error when reading #{remote_file}"
      raise e unless options[:skip_errors]
    end

    def join_remote(remote_dir, basename)
      "#{remote_dir}/#{basename}".gsub(%r{/+}, '/')
    end
  end
end
