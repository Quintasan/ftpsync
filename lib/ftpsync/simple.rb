# frozen_string_literal: true

require 'fileutils'
require 'net/ftp'
require 'net/ftp/list'

require 'ftpsync/version'
require 'ftpsync/simple/result'
require 'ftpsync/simple/session'
require 'ftpsync/simple/entry'
require 'ftpsync/simple/listing'
require 'ftpsync/simple/filtering'
require 'ftpsync/simple/options'
require 'ftpsync/simple/transfer'
require 'ftpsync/simple/store'
require 'ftpsync/simple/pull'
require 'ftpsync/simple/push'
require 'ftpsync/simple/prune'

module FtpSync
  # Synchronizes directories against an FTP server.
  #
  # A single instance owns at most one connection at a time. The connection is
  # opened lazily and closed once a top-level sync finishes, whether it
  # succeeded or raised, so a failed sync never leaves a socket behind for the
  # next call to trip over.
  #
  # An instance is not thread-safe: it holds one connection and the state of the
  # sync in progress, so use one instance per thread.
  class Simple
    # Suffix used for downloads in progress and for uploads that are renamed
    # into place. A transfer only ever reaches the destination path once it has
    # completed, so that path never holds a partial file and the callback only
    # ever sees complete files.
    PART_SUFFIX = '.ftpsync-part'

    DEFAULT_OPEN_TIMEOUT = 30
    DEFAULT_READ_TIMEOUT = 60

    # How far a local file may lead the remote timestamp and still count as
    # unchanged. A server stamps an upload with its own clock, and LIST reports
    # that time with minute precision, so the two sides have to be compared with
    # a tolerance. The cost: on a server whose remote time can only come from
    # LIST, a same-size edit made within this many seconds of an upload is not
    # noticed.
    DEFAULT_MTIME_TOLERANCE = 60

    # MDTM answers with second precision in UTC, so only clock jitter has to be
    # absorbed and the blind spot above does not apply.
    MDTM_TOLERANCE = 2

    MDTM_FORMAT = /(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})/

    # Reply codes that mean the server has no MDTM at all, as opposed to a
    # per-file failure such as a missing or unreadable path.
    MDTM_UNSUPPORTED = /\A50[012]/

    # Reply codes that mean the server has no RNFR/RNTO at all. Any other
    # rename failure is real and must not disable atomic uploads for the
    # connection.
    RENAME_UNSUPPORTED = /\A50[024]/

    # Reply codes that mean the server has no MLSD at all. LIST is then the only
    # source of listings for the rest of the connection.
    MLSD_UNSUPPORTED = /\A50[0124]/

    # Reported for a listing entry whose type could not be determined. Such an
    # entry is a failure, not a skip: a run that cannot read its listing must
    # not look successful.
    UNUSABLE_ENTRY = 'unusable listing entry: type unknown'

    # Logged for an entry that :exclude keeps out or :include does not name.
    FILTERED_OUT = 'left out by the :exclude / :include patterns'

    CONSTRUCTOR_OPTIONS = %i[port passive verbose implicit_ftps ssl open_timeout
                             read_timeout mtime_tolerance atomic_uploads retries
                             private_data_connection ssl_handshake_timeout].freeze

    # :protect_local only means something when pulling, so pushing rejects it
    # like any other option the direction does not understand. :prune applies to
    # both directions.
    PULL_OPTIONS = %i[since skip_errors protect_local prune dry_run exclude include].freeze
    PUSH_OPTIONS = %i[since skip_errors prune dry_run exclude include].freeze

    # Options read as true/false, with nil reading as false. :ssl is checked
    # separately because it also takes an OpenSSL options hash. A string such as
    # "false" is truthy in Ruby, so accepting one would switch the option on.
    BOOLEAN_OPTIONS = %i[verbose passive implicit_ftps atomic_uploads private_data_connection
                         since skip_errors protect_local prune dry_run].freeze

    # The two directions and the pruner each live in their own file; they are
    # modules so that the connection, the error policy and the transfer guard stay
    # shared here.
    include Options
    include Filtering
    include Transfer
    include Store
    include Pull
    include Push
    include Prune

    # Read when a connection is opened. Assigning to them afterwards does not
    # move an open connection and does not relabel it in the log.
    attr_accessor :server, :port, :username, :password, :passive

    def initialize(server, username, password, options = {})
      options = validate_options(options, CONSTRUCTOR_OPTIONS, 'constructor')
      @server = server
      @username = username
      @password = password
      @port = options.fetch(:port, 21)
      apply_options(options)

      @connection = nil
      @depth = 0
      @endpoint = nil
      reset_capabilities
    end

    # Recursively pulls +remotepath+ into +localpath+.
    #
    # Options:
    #   :since          skip files that already exist locally and are up to date
    #   :skip_errors    rescue Net::FTPError, log it and keep going
    #   :protect_local  skip files that are newer locally than on the server
    #   :prune          delete local entries the remote directory no longer has
    #   :dry_run        report what would happen and change nothing
    #   :exclude        a pattern or patterns to leave out
    #   :include        a pattern or patterns to keep; other files are left out
    #
    # If a block is given, it is invoked with the local path of each downloaded
    # file. Returns a Result.
    def pull_dir(remotepath, localpath, options = {}, &block)
      options = validate_options(options, PULL_OPTIONS, 'sync')
      validate_remote_path(remotepath)
      validate_local_path(localpath)
      session = Session.new(options)
      session.remote_root = remotepath
      session.local_root = localpath
      synchronize { pull_into(remotepath, localpath, session, &block) }
      session.result
    end

    # Recursively pushes +localpath+ into +remotepath+, creating any missing
    # remote directories on the way.
    #
    # Options:
    #   :since          skip files that already exist remotely and are up to date
    #   :skip_errors    rescue Net::FTPError, log it and keep going
    #   :prune          delete remote entries the local directory no longer has
    #   :dry_run        report what would happen and change nothing
    #   :exclude        a pattern or patterns to leave out
    #   :include        a pattern or patterns to keep; other files are left out
    #
    # If a block is given, it is invoked with the remote path of each uploaded
    # file. Returns a Result.
    def push_dir(localpath, remotepath, options = {}, &block)
      options = validate_options(options, PUSH_OPTIONS, 'sync')
      validate_local_path(localpath)
      validate_remote_path(remotepath)
      raise ArgumentError, "#{localpath} is not a directory" unless File.directory?(localpath)

      session = Session.new(options)
      session.local_root = localpath
      session.remote_root = remotepath
      synchronize do
        ensure_remote_directory(remotepath, session)
        push_into(localpath, remotepath, session, &block)
      end
      session.result
    end

    def connect!
      close!
      reset_capabilities
      @endpoint = "#{@server}:#{@port}"
      log "Connecting to #{@endpoint} in #{@passive ? 'passive' : 'active'} mode"
      @connection = Net::FTP.new(nil, connection_options)
      @connection.connect(@server, @port)
      @connection.passive = @passive
      log "Logging in as #{@username}"
      @connection.login(@username, @password)
      log "Successfully opened connection to #{@endpoint}"
    end

    # Closes the connection if one is open. Safe to call when no connection was
    # ever established and safe to call more than once.
    def close!
      return unless @connection

      connection = @connection
      @connection = nil
      connection.close
      log "Closed connection to #{@endpoint}"
    end

    def log(message)
      warn message if @verbose
    end

    # Keeps the password out of logs and error reports: an inspect of a client is
    # exactly what ends up in both.
    def inspect
      "#<#{self.class} server=#{@server.inspect} port=#{@port} username=#{@username.inspect} passive=#{@passive}>"
    end

    private

    # The options are read here, once, because they describe the connection
    # this instance opens rather than one it already has.
    def apply_options(options)
      @verbose = options.fetch(:verbose, false)
      @mtime_tolerance = options.fetch(:mtime_tolerance, DEFAULT_MTIME_TOLERANCE)
      validate_mtime_tolerance(@mtime_tolerance)
      @atomic_uploads = options.fetch(:atomic_uploads, true)
      @retries = options.fetch(:retries, 0)
      validate_retries(@retries)
      # nil leaves the choice to Net::FTP, which protects data connections
      # whenever TLS is on. False is for servers that break on protected data.
      @private_data_connection = options.fetch(:private_data_connection, nil)
      @ssl_handshake_timeout = options.fetch(:ssl_handshake_timeout, nil)
      validate_non_negative_number('ssl_handshake_timeout', @ssl_handshake_timeout) unless @ssl_handshake_timeout.nil?
      # Passive mode is the default: active mode cannot traverse NAT or most
      # firewalls.
      @passive = options.fetch(:passive, true)
      @implicit_ftps = options.fetch(:implicit_ftps, false)
      @ssl = options.fetch(:ssl, @implicit_ftps)
      @open_timeout = options.fetch(:open_timeout, DEFAULT_OPEN_TIMEOUT)
      @read_timeout = options.fetch(:read_timeout, DEFAULT_READ_TIMEOUT)
    end

    # Runs a top-level sync on a live connection and always closes it
    # afterwards. Reentrant calls from a block reuse the open connection and
    # only the outermost one closes it.
    def synchronize
      @depth += 1
      connect! unless @connection
      yield
    ensure
      @depth -= 1
      close! if @depth.zero?
    end

    # Capability probes are per connection: a different server, or the same one
    # after a restart, must not inherit an older verdict.
    def reset_capabilities
      @mdtm_supported = true
      @rename_supported = true
      @mlsx_supported = true
    end

    def connection_options
      {
        passive: @passive,
        ssl: @ssl,
        implicit_ftps: @implicit_ftps,
        private_data_connection: @private_data_connection,
        open_timeout: @open_timeout,
        read_timeout: @read_timeout,
        ssl_handshake_timeout: @ssl_handshake_timeout
      }.compact
    end

    def skip_entry(path, reason, session)
      log "Skipping #{path}: #{reason}"
      session.result.skipped += 1
    end

    def join_remote(remote_dir, basename)
      return basename if remote_dir.nil? || remote_dir.empty?

      "#{remote_dir}/#{basename}".gsub(%r{/+}, '/')
    end

    def remote_components(remotepath)
      remotepath.split('/').reject { |part| part.empty? || part == '.' }
    end

    # Yields each entry the server reports for +remotepath+, normalised and
    # without the "." / ".." pseudo entries.
    #
    # Returns :ok when every entry could be interpreted, :partial when at least
    # one could not (each is reported as a failure, so a run that cannot read
    # its own listing never looks successful) and :failed when the listing
    # itself failed: raised, or reported under :skip_errors.
    def each_entry(remotepath, session)
      status = :ok
      listing_entries(remotepath) do |entry|
        next if entry.pseudo?

        if entry.type.nil?
          report_failure(session.result, join_remote(remotepath, entry.basename), UNUSABLE_ENTRY)
          status = :partial
          next
        end

        yield entry
      end
      status
    rescue Net::FTPError => e
      raise unless session.options[:skip_errors]

      report_error(session.result, remotepath, e)
      :failed
    end

    # Yields the raw listing, preferring MLSD: it types every entry and dates it
    # in UTC, while LIST has to be parsed and depends on the server's locale.
    # A 500/501/502/504 answer to MLSD means the server has none, so that verdict
    # is remembered for the connection and LIST is used from then on. Every
    # other failure is a real listing failure and is not retried with LIST.
    def listing_entries(remotepath)
      if @mlsx_supported
        begin
          @connection.mlsd(remotepath) do |mlsx_entry|
            entry = Entry.from_mlsx(mlsx_entry)
            yield entry if entry
          end
          return
        rescue Net::FTPError => e
          raise unless MLSD_UNSUPPORTED.match?(e.message)

          @mlsx_supported = false
          log 'Server does not implement MLSD; falling back to LIST'
        end
      end

      @connection.list(remotepath) do |line|
        next if line.strip.empty?

        list_entry = Net::FTP::List.parse(line)
        yield Entry.from_list(list_entry) if list_entry
      end
    end

    # The entries of +remotepath+ by basename. A nil status means no listing was
    # asked for; :partial and :failed mean the answer cannot be trusted to skip
    # or delete anything.
    def remote_entries(remotepath, session)
      return [nil, {}] unless session.options[:since] || session.options[:prune]

      entries = {}
      status = each_entry(remotepath, session) { |entry| entries[entry.basename] = entry }
      [status, entries]
    end

    # The normalised entries for +path+, or nil when the server will not list
    # it. Entries whose type is unknown are left out: this answers one yes/no
    # question about one name, and such an entry proves nothing either way.
    def entries_at(path)
      entries = []
      listing_entries(path) { |entry| entries << entry unless entry.type.nil? || entry.pseudo? }
      entries
    rescue Net::FTPError
      nil
    end

    # The entry for +path+ in the listing of its parent directory, or nil when
    # the parent cannot be listed or does not report the name.
    def parent_entry(path)
      entries = entries_at(File.dirname(path))
      entries&.find { |entry| entry.basename == File.basename(path) }
    end

    # An upload is skipped when the remote copy has the same size and the local
    # file has not been modified since that copy was uploaded. The remote mtime
    # is the server's upload time, not the local file's mtime.
    def skip_upload?(remote_file, remote_entry, local_path, session)
      return false unless session.options[:since]
      return false unless remote_entry
      return false unless remote_entry.file?
      return false unless remote_entry.filesize == File.size(local_path)

      remote_time, provenance = remote_time(remote_file, remote_entry)
      # Without a usable remote time nothing can be proven current.
      return false if remote_time.nil?

      File.mtime(local_path) < remote_time + tolerance_for(provenance)
    end

    # A LIST timestamp is a wall clock reading and needs the wide default
    # tolerance; MLSD and MDTM date the entry in UTC with second precision and
    # need almost none, which is what keeps a recent edit visible.
    def tolerance_for(provenance)
      provenance == :list ? @mtime_tolerance : MDTM_TOLERANCE
    end

    # The remote file's modification time as UTC, together with where it came
    # from. MDTM is timezone independent, unlike LIST, whose timestamp is a wall
    # clock reading that net-ftp-list interprets as UTC. An MLSx entry already
    # carries a UTC time of the same precision, so MDTM is not asked for it;
    # servers without MDTM fall back to the LIST value, which can be off by the
    # server's UTC offset.
    def remote_time(remote_file, entry)
      return entry_time(entry) if entry.mtime_source == :mlsx || !@mdtm_supported

      stamp = @connection.mdtm(remote_file)
      match = stamp && MDTM_FORMAT.match(stamp)
      return entry_time(entry) unless match

      [Time.utc(*match.captures.map(&:to_i)), :mdtm]
    rescue ArgumentError
      log "Ignoring malformed MDTM time for #{remote_file}"
      entry_time(entry)
    rescue Net::FTPError => e
      note_mdtm_failure(remote_file, e)
      entry_time(entry)
    end

    def entry_time(entry)
      [entry.mtime, entry.mtime_source]
    end

    # A 500/501/502 reply means the server has no MDTM, which is a different
    # thing from one file failing to report its time.
    def note_mdtm_failure(remote_file, error)
      if MDTM_UNSUPPORTED.match?(error.message)
        @mdtm_supported = false
        log 'Server does not implement MDTM; using LIST timestamps instead'
      else
        log "Ignoring MDTM error for #{remote_file}: #{error.message}"
      end
    end

    # The shared transfer guard. One place decides what a completed transfer
    # means, applies the :skip_errors policy and reports the failure. It stays
    # separate from both directions so they cannot drift apart, and callbacks
    # stay outside it: a callback exception is never swallowed and only fires
    # for a file that is already in place.
    def report_error(result, path, error)
      report_failure(result, path, error.message)
    end

    # Records a failure that did not come from an FTP reply, such as a listing
    # entry whose type could not be determined.
    def report_failure(result, path, message)
      result.failed += 1
      result.errors << [path, message]
      log "Error while processing #{path}: #{message}"
    end
  end
end
