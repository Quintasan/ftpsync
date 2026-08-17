# frozen_string_literal: true

require 'net/ftp'
require 'open3'
require 'tempfile'

# Manages a garethflowers/ftp-server (vsftpd) container for integration
# tests. See https://garethflowers.dev/docker-ftp-server/
class FtpServer
  IMAGE = 'garethflowers/ftp-server'
  HOST = '127.0.0.1'
  FTP_PORT = Integer(ENV.fetch('FTPSYNC_TEST_FTP_PORT', '2121'))
  PASV_PORTS = (40_000..40_009).freeze
  USER = ENV.fetch('FTPSYNC_TEST_USER', 'testuser')
  PASS = ENV.fetch('FTPSYNC_TEST_PASS', 'testpass')
  CONTAINER = "ftpsync-test-#{Process.pid}"

  def self.available?
    system('docker', 'version', out: File::NULL, err: File::NULL)
  end

  def start
    remove_container
    docker_run
    wait_until_ready
  end

  def stop
    remove_container
  end

  # Deletes everything from the FTP home so tests start from a clean slate.
  def reset
    with_ftp { |ftp| delete_tree(ftp, '.') }
  end

  # Uploads the given files (remote path => content) to the FTP server,
  # creating any intermediate directories on the way.
  def seed(files)
    with_ftp do |ftp|
      files.each do |remote_path, content|
        mkdir_p(ftp, File.dirname(remote_path))
        with_tempfile(content) { |tmp| ftp.putbinaryfile(tmp.path, remote_path) }
      end
    end
  end

  def logs
    `docker logs #{CONTAINER} 2>&1`.lines.last(20).join
  end

  private

  def docker_run
    docker('run', '-d', '--name', CONTAINER,
           '-p', "#{HOST}:#{FTP_PORT}:21",
           '-p', "#{HOST}:#{PASV_PORTS.first}-#{PASV_PORTS.last}:#{PASV_PORTS.first}-#{PASV_PORTS.last}",
           '-e', "FTP_USER=#{USER}",
           '-e', "FTP_PASS=#{PASS}",
           '-e', "PUBLIC_IP=#{HOST}",
           IMAGE)
  end

  def wait_until_ready(timeout: 60)
    deadline = Time.now + timeout
    until ftp_ready?
      raise "FTP server did not become ready within #{timeout}s\n#{logs}" if Time.now > deadline

      sleep 0.5
    end
  end

  def ftp_ready?
    with_ftp(&:pwd)
    true
  rescue StandardError
    false
  end

  def with_ftp
    ftp = Net::FTP.new
    ftp.connect(HOST, FTP_PORT)
    ftp.login(USER, PASS)
    ftp.passive = true
    yield ftp
  ensure
    ftp&.close
  end

  def with_tempfile(content)
    Tempfile.create do |tmp|
      tmp.binmode
      tmp.write(content)
      tmp.flush
      yield tmp
    end
  end

  def delete_tree(ftp, dir)
    ftp.nlst(dir).each do |name|
      next if %w[. ..].include?(name)

      begin
        ftp.delete(name)
      rescue Net::FTPPermError
        delete_tree(ftp, name)
        ftp.rmdir(name)
      end
    end
  end

  def mkdir_p(ftp, dir)
    return if dir.empty? || dir == '.'

    parts = dir.split('/')
    parts.each_index do |i|
      path = parts[0..i].join('/')
      begin
        ftp.mkdir(path)
      rescue Net::FTPPermError
        # Ignore: the directory already exists.
      end
    end
  end

  def remove_container
    docker('rm', '-f', CONTAINER) if container_exists?
  end

  def container_exists?
    system('docker', 'inspect', CONTAINER, out: File::NULL, err: File::NULL)
  end

  def docker(*args)
    _stdout, stderr, status = Open3.capture3('docker', *args)
    raise "docker #{args.join(' ')} failed: #{stderr.strip}" unless status.success?
  rescue Errno::ENOENT
    raise 'Docker is not installed or not reachable'
  end
end
