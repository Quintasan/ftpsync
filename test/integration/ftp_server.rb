# frozen_string_literal: true

require 'fileutils'
require 'logger'
require 'net/ftp'
require 'socket'
require 'tempfile'
require 'tmpdir'

# ftpd never requires stringio, and on Ruby 4 every LIST then answers
# "451 Local error in processing"; load it before the server library.
require 'stringio'
require 'ftpd'

# Runs a real FTP server inside the test process.
#
# The integration tests used to drive a Dockerized vsftpd container. That
# server process exited 139 (SIGSEGV) a few logins into a run on GitHub's
# runners, independent of this library, so the job could not be trusted.
# Ftpd::FtpServer is pure Ruby: the same protocol over real sockets, no Docker,
# and the suite always runs. See .operator/guides/local-ftp-verification.md for
# the caveats that shaped this harness (Ruby 4 needs stringio, TLS is unusable
# under OpenSSL 3).
class FtpServer
  HOST = '127.0.0.1'
  USER = 'testuser'
  PASS = 'testpass'

  # Passive data connections use a small window of ports so a run stays
  # predictable, but the window is picked at start-up: repeated or parallel
  # runs on one machine must not hand out the same data port.
  PASV_PORT_COUNT = 10
  PASV_PORT_RANGE = (40_000..60_000).freeze
  PASV_PORT_ATTEMPTS = 20

  # Authentication and storage for Ftpd::FtpServer.
  class Driver
    def initialize(root)
      @root = root
    end

    # ftpd fixes this method name in its driver API; it answers a yes/no
    # question, so the predicate-name cop does not apply.
    # rubocop:disable-next Naming/PredicateMethod
    def authenticate(user, password)
      user == USER && password == PASS
    end

    def file_system(_user)
      Ftpd::DiskFileSystem.new(@root)
    end
  end

  # ftpd 2.1.0 has no MLSD at all, and the command loop answers an unknown
  # command with 500 while leaving the passive listener open. The next PASV then
  # answers "200 Already in passive mode" and the LIST fallback dies on a
  # surprise reply. A real server without MLSD answers 502 and forgets the
  # listener, so this handler does exactly that: the integration suite keeps
  # exercising the LIST fallback against a server that really has no MLSD.
  class CmdMlsd < Ftpd::CommandHandler
    def cmd_mlsd(_argument)
      ensure_logged_in
      close_data_server_socket
      unimplemented_error
    end
  end

  # Handler classes are read from this factory whenever a session starts.
  module MlsdHandlerRegistration
    def standard_command_handlers
      super + [CmdMlsd]
    end
  end
  Ftpd::CommandHandlerFactory.singleton_class.prepend(MlsdHandlerRegistration)

  # FTP's RNTO is allowed to reject an existing destination (ftpd answers
  # 550 "Already exists"), but servers in practice replace it, and this library
  # relies on that: a push updates files uploaded by an earlier run through
  # RNFR/RNTO on a side file. Without this, every re-upload would fail instead
  # of exercising the atomic path. Everything else is stock ftpd.
  module OverwritingRename
    def cmd_rnto(argument)
      ensure_logged_in
      ensure_file_system_supports :rename
      syntax_error unless argument
      to_path = File.expand_path(argument, name_prefix)
      ensure_accessible to_path
      file_system.delete(to_path) if file_system.exists?(to_path)
      file_system.rename(@rename_from_path, to_path)
      reply '250 Rename successful'
    end
  end
  Ftpd::CmdRename.prepend(OverwritingRename)

  # Always true: the server is in this process, so nothing has to be installed
  # or reachable.
  def self.available?
    true
  end

  attr_reader :root, :port

  def initialize
    @root = Dir.mktmpdir('ftpsync-integration')
    @log = StringIO.new
    @server = nil
  end

  def start
    return if @server

    FileUtils.mkdir_p(@root)
    @server = Ftpd::FtpServer.new(Driver.new(@root))
    @server.interface = HOST
    # Port 0 lets the kernel pick a free control port; #bound_port reports the
    # one it actually got.
    @server.port = 0
    @server.passive_ports = passive_ports
    @server.log = Logger.new(@log)
    @server.start
    @port = @server.bound_port
  end

  def stop
    @server&.stop
    @server = nil
    @port = nil
    FileUtils.rm_rf(@root)
  end

  # Empties the FTP root so every test starts from a clean slate.
  def reset
    FileUtils.mkdir_p(@root)
    Dir.children(@root).each { |entry| FileUtils.remove_entry(File.join(@root, entry)) }
    clear_log
  end

  # Uploads the given files (remote path => content), creating any intermediate
  # directories on the way.
  def seed(files)
    with_ftp do |ftp|
      files.each do |remote_path, content|
        mkdir_p(ftp, File.dirname(remote_path))
        with_tempfile(content) { |tmp| ftp.putbinaryfile(tmp.path, remote_path) }
      end
    end
  end

  # The server's own debug log, so a test can prove which protocol path ran
  # (for example that an upload really used RNFR/RNTO).
  def log
    @log.string
  end

  def clear_log
    @log.truncate(0)
    @log.rewind
  end

  private

  def passive_ports
    PASV_PORT_ATTEMPTS.times do
      first = rand(PASV_PORT_RANGE.first..(PASV_PORT_RANGE.last - PASV_PORT_COUNT + 1))
      range = (first..(first + PASV_PORT_COUNT - 1))
      return range if range.all? { |port| port_free?(port) }
    end
    # Every window tried was busy. ftpd then falls back to an ephemeral port
    # per data connection, which is safe, just less predictable.
    nil
  end

  def port_free?(port)
    server = TCPServer.new(HOST, port)
    true
  rescue SystemCallError
    false
  ensure
    server&.close
  end

  def with_ftp
    ftp = Net::FTP.new
    ftp.connect(HOST, @port)
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

  def mkdir_p(ftp, dir)
    return if dir.empty? || dir == '.'

    parts = dir.split('/')
    parts.each_index do |index|
      path = parts[0..index].join('/')
      begin
        ftp.mkdir(path)
      rescue Net::FTPPermError
        # The directory already exists.
      end
    end
  end
end
