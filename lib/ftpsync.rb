# frozen_string_literal: true

require 'fileutils'
require 'ftpsync/version'
require 'net/ftp'
require 'net/ftp/list'

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

    MDTM_FORMAT = /(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})/.freeze

    # Reply codes that mean the server has no MDTM at all, as opposed to a
    # per-file failure such as a missing or unreadable path.
    MDTM_UNSUPPORTED = /\A50[012]/.freeze

    # Reply codes that mean the server has no RNFR/RNTO at all. Any other
    # rename failure is real and must not disable atomic uploads for the
    # connection.
    RENAME_UNSUPPORTED = /\A50[024]/.freeze

    CONSTRUCTOR_OPTIONS = %i[port passive verbose implicit_ftps ssl open_timeout
                             read_timeout mtime_tolerance atomic_uploads].freeze

    # :protect_local only means something when pulling, so pushing rejects it
    # like any other option the direction does not understand.
    PULL_OPTIONS = %i[since skip_errors protect_local].freeze
    PUSH_OPTIONS = %i[since skip_errors].freeze

    # Outcome of one top-level sync. +transferred+ counts files that reached
    # their destination, +skipped+ counts entries deliberately left alone (up to
    # date under :since, symlinks and other non-files, protected local files,
    # leftover partial files) and +failed+ counts errors :skip_errors swallowed,
    # each also listed in +errors+ as a [path, message] pair.
    Result = Struct.new(:transferred, :skipped, :failed, :errors)

    # State of one top-level sync: the caller's options, the tally that becomes
    # the return value, and the remote directories already created or confirmed.
    # It is dropped when the sync ends, which is exactly how long those stay
    # valid, and it keeps a nested sync started from a callback independent.
    class Session
      attr_reader :options, :result

      def initialize(options)
        @options = options
        @result = Result.new(0, 0, 0, [])
        @known_directories = {}
      end

      def known_directory?(path)
        @known_directories.key?(path)
      end

      def remember_directory(path)
        @known_directories[path] = true
      end
    end

    # Read when a connection is opened. Assigning to them afterwards does not
    # move an open connection and does not relabel it in the log.
    attr_accessor :server, :port, :username, :password, :passive

    def initialize(server, username, password, options = {})
      options = {} if options.nil?
      validate_options(options, CONSTRUCTOR_OPTIONS, 'constructor')
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
    #
    # If a block is given, it is invoked with the local path of each downloaded
    # file. Returns a Result.
    def pull_dir(remotepath, localpath, options = {}, &block)
      options = sync_options(options, PULL_OPTIONS)
      validate_remote_path(remotepath)
      validate_local_path(localpath)
      session = Session.new(options)
      synchronize { pull_into(remotepath, localpath, session, &block) }
      session.result
    end

    # Recursively pushes +localpath+ into +remotepath+, creating any missing
    # remote directories on the way.
    #
    # Options:
    #   :since          skip files that already exist remotely and are up to date
    #   :skip_errors    rescue Net::FTPError, log it and keep going
    #
    # If a block is given, it is invoked with the remote path of each uploaded
    # file. Returns a Result.
    def push_dir(localpath, remotepath, options = {}, &block)
      options = sync_options(options, PUSH_OPTIONS)
      validate_local_path(localpath)
      validate_remote_path(remotepath)
      raise ArgumentError, "#{localpath} is not a directory" unless File.directory?(localpath)

      session = Session.new(options)
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

    private

    # The options are read here, once, because they describe the connection
    # this instance opens rather than one it already has.
    def apply_options(options)
      @verbose = options.fetch(:verbose, false)
      @mtime_tolerance = options.fetch(:mtime_tolerance, DEFAULT_MTIME_TOLERANCE)
      validate_mtime_tolerance(@mtime_tolerance)
      @atomic_uploads = options.fetch(:atomic_uploads, true)
      # Passive mode is the default: active mode cannot traverse NAT or most
      # firewalls.
      @passive = options.fetch(:passive, true)
      @implicit_ftps = options.fetch(:implicit_ftps, false)
      @ssl = options.fetch(:ssl, @implicit_ftps)
      @open_timeout = options.fetch(:open_timeout, DEFAULT_OPEN_TIMEOUT)
      @read_timeout = options.fetch(:read_timeout, DEFAULT_READ_TIMEOUT)
    end

    # A tolerance that is not a non-negative number would only fail later, in
    # the upload decision and outside :skip_errors, so it is rejected while the
    # option is still in the caller's hands.
    def validate_mtime_tolerance(value)
      return if value.is_a?(Numeric) && value.real? && value >= 0

      raise ArgumentError, "mtime_tolerance must be a non-negative Numeric, got #{value.inspect}"
    end

    # Rejects option keys the library does not understand, so that a typo such
    # as +ssll:+ cannot silently leave the connection unencrypted.
    def validate_options(options, allowed, context)
      raise ArgumentError, "#{context} options must be a Hash" unless options.is_a?(Hash)

      options.each_key do |key|
        raise ArgumentError, "Unknown #{context} option: #{key.inspect}" unless allowed.include?(key)
      end
    end

    def sync_options(options, allowed)
      options = {} if options.nil?
      validate_options(options, allowed, 'sync')
      options
    end

    # An empty remote path is the login directory, which the rest of the path
    # handling already expresses: no component to create and relative names.
    def validate_remote_path(path)
      return if path.is_a?(String)

      raise ArgumentError, "remote path must be a String, got #{path.inspect}"
    end

    def validate_local_path(path)
      return if path.is_a?(String) && !path.empty?

      raise ArgumentError, "local path must be a non-empty String, got #{path.inspect}"
    end

    # Runs a top-level sync on a live connection and always closes it
    # afterwards. Reentrant calls from a block reuse the open connection and
    # only the outermost one closes it.
    def synchronize
      @depth += 1
      begin
        connect! unless @connection
        yield
      ensure
        @depth -= 1
        close! if @depth.zero?
      end
    end

    # Capability probes are per connection: a different server, or the same one
    # after a restart, must not inherit an older verdict.
    def reset_capabilities
      @mdtm_supported = true
      @rename_supported = true
    end

    def connection_options
      {
        passive: @passive,
        ssl: @ssl,
        implicit_ftps: @implicit_ftps,
        open_timeout: @open_timeout,
        read_timeout: @read_timeout
      }
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

    # Yields each entry reported for +remotepath+, skipping the "." and ".."
    # pseudo entries, and returns whether the listing worked.
    def each_entry(remotepath, session)
      @connection.list(remotepath) do |line|
        entry = Net::FTP::List.parse(line)
        next if %w[. ..].include?(entry.name)

        yield entry
      end
      true
    rescue Net::FTPError => e
      raise unless session.options[:skip_errors]

      report_error(session.result, remotepath, e)
      false
    end

    # Maps the basenames of the files present in +remotepath+ to their LIST
    # entry. An empty hash means the directory is empty; nil means the listing
    # failed and was swallowed, which is a different answer.
    def remote_entries(remotepath, session)
      entries = {}
      listed = each_entry(remotepath, session) do |entry|
        entries[entry.basename] = entry if entry.file?
      end
      entries if listed
    end

    # The parsed entries for +path+, or nil when the server will not list it.
    def entries_at(path)
      entries = []
      @connection.list(path) { |line| entries << Net::FTP::List.parse(line) }
      entries
    rescue Net::FTPError
      nil
    end

    # The LIST entry for +path+ in its parent directory, or nil when the parent
    # cannot be listed or does not report the name.
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
      return false unless remote_entry.filesize == File.size(local_path)

      remote_time, provenance = remote_time(remote_file, remote_entry)
      File.mtime(local_path) < remote_time + tolerance_for(provenance)
    end

    # A LIST timestamp is a wall clock reading, so it needs the wide default
    # tolerance. An MDTM timestamp is UTC with second precision and needs almost
    # none, which is what keeps a recent edit visible.
    def tolerance_for(provenance)
      provenance == :mdtm ? MDTM_TOLERANCE : @mtime_tolerance
    end

    # The remote file's modification time as UTC, together with where it came
    # from. MDTM is timezone independent, unlike LIST, whose timestamp is a wall
    # clock reading that net-ftp-list interprets as UTC. Servers without MDTM
    # fall back to the LIST value, which can be off by the server's UTC offset.
    def remote_time(remote_file, entry)
      return [entry.mtime, :list] unless @mdtm_supported

      stamp = @connection.mdtm(remote_file)
      match = stamp && MDTM_FORMAT.match(stamp)
      return [entry.mtime, :list] unless match

      [Time.utc(*match.captures.map(&:to_i)), :mdtm]
    rescue ArgumentError
      log "Ignoring malformed MDTM time for #{remote_file}"
      [entry.mtime, :list]
    rescue Net::FTPError => e
      note_mdtm_failure(remote_file, e)
      [entry.mtime, :list]
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
    def transfer_file(path, session)
      yield
      session.result.transferred += 1
      true
    rescue Net::FTPError => e
      raise unless session.options[:skip_errors]

      report_error(session.result, path, e)
      false
    end

    def report_error(result, path, error)
      result.failed += 1
      result.errors << [path, error.message]
      log "Error while processing #{path}: #{error.message}"
    end

    # The pull direction: what a listed tree turns into locally. The two
    # directions live in their own modules so each reads in one place, while
    # the connection, the error policy and the transfer guard stay shared.
    module Pull
      private

      def pull_into(remotepath, localpath, session, &block)
        listing = scan_directory(remotepath, localpath, session)
        # Nothing local exists until the listing succeeded, so a wrong remote path
        # cannot leave an empty local tree behind.
        return unless listing

        ensure_local_directory(localpath)
        directories, files = listing
        directories.each { |remote_dir, local_dir| pull_into(remote_dir, local_dir, session, &block) }
        files.each { |remote_file, local_file, entry| download(remote_file, local_file, entry, session, &block) }
      end

      def ensure_local_directory(localpath)
        return if File.directory?(localpath)

        FileUtils.mkpath(localpath)
        log "Creating #{localpath} directory"
      end

      # The directory's entries split into directories to recurse into and files
      # to download, or nil when the listing itself failed and was swallowed.
      def scan_directory(remotepath, localpath, session)
        directories = []
        files = []
        listed = each_entry(remotepath, session) do |entry|
          remote_child = join_remote(remotepath, entry.basename)
          local_child = File.join(localpath, entry.basename)

          if entry.dir?
            directories << [remote_child, local_child]
          elsif entry.file?
            files << [remote_child, local_child, entry] if pull_file?(local_child, entry, session)
          else
            skip_entry(remote_child, entry_type(entry), session)
          end
        end
        return unless listed

        [directories, files]
      end

      # The LIST type in words, for the skip log. A line none of the parsers
      # understood produces an entry with no type at all.
      def entry_type(entry)
        case entry.type
        when :symlink then 'symbolic link'
        when :device then 'device'
        else 'not a regular file or directory'
        end
      end

      # Whether a listed file is downloaded at all. :since skips a file that is
      # already current. A local file newer than the remote one is still replaced
      # by default, but never quietly: that is the one destructive thing a pull
      # does, and :protect_local turns it into a skip.
      def pull_file?(local_path, entry, session)
        if skip_file?(local_path, entry, session)
          session.result.skipped += 1
          return false
        end
        return true unless newer_local?(local_path, entry)

        if session.options[:protect_local]
          skip_entry(local_path, 'newer than the remote copy', session)
          return false
        end

        log "Overwriting #{local_path}, which is newer than the remote copy"
        true
      end

      # A file is up to date when it has the same size locally and the remote
      # copy is not newer. Downloaded files keep the server mtime, so an
      # unchanged file compares equal on the next run.
      def skip_file?(local_path, entry, session)
        return false unless session.options[:since]
        return false unless File.file?(local_path)
        return false unless entry.filesize == File.size(local_path)

        File.mtime(local_path) >= entry.mtime
      end

      def newer_local?(local_path, entry)
        File.file?(local_path) && File.mtime(local_path) > entry.mtime
      end

      def download(remote_file, local_file, entry, session)
        partial = "#{local_file}#{PART_SUFFIX}"
        log "#{remote_file} => #{local_file}"
        completed = transfer_file(remote_file, session) do
          @connection.getbinaryfile(remote_file, partial)
          warn_size_mismatch(remote_file, partial, entry)
          File.utime(entry.mtime, entry.mtime, partial)
          FileUtils.mv(partial, local_file)
        end
        yield(local_file) if completed && block_given?
      ensure
        # The rename consumed the partial; any other outcome is a failure that
        # must not leave one behind.
        FileUtils.rm_f(partial)
      end

      # LIST's size and the transfer's own count can disagree; the file is kept
      # because the entry is only metadata, but the difference is worth saying.
      def warn_size_mismatch(remote_file, partial, entry)
        expected = entry.filesize.to_i
        actual = File.size(partial)
        return if expected <= 0 || expected == actual

        log "Size mismatch for #{remote_file}: expected #{expected} bytes, received #{actual}"
      end
    end
    include Pull

    # The push direction: creating the remote tree and storing files in it.
    module Push
      private

      def push_into(localpath, remotepath, session, &block)
        known_remote = session.options[:since] ? remote_entries(remotepath, session) : {}
        # :since protects a remote file by proving it is current. A listing that
        # could not be read proves nothing, so this directory is left alone
        # rather than re-uploading over possibly newer remote files.
        return if known_remote.nil?

        Dir.children(localpath).sort.each do |basename|
          push_entry(File.join(localpath, basename), join_remote(remotepath, basename),
                     known_remote[basename], session, &block)
        end
      end

      # One local entry, dispatched by what it is. Symlinks and leftovers of
      # interrupted downloads are skipped instead of uploaded.
      def push_entry(local_child, remote_child, remote_entry, session, &block)
        if local_child.end_with?(PART_SUFFIX)
          skip_entry(local_child, 'leftover partial download', session)
        elsif File.symlink?(local_child)
          skip_entry(local_child, 'symbolic link', session)
        elsif File.directory?(local_child)
          ensure_remote_directory(remote_child, session)
          push_into(local_child, remote_child, session, &block)
        elsif File.file?(local_child)
          upload(local_child, remote_child, remote_entry, session, &block)
        else
          skip_entry(local_child, 'not a regular file or directory', session)
        end
      end

      # Walks +remotepath+ top-down, creating the directories that do not exist
      # yet. Absolute remote paths keep their leading slash.
      def ensure_remote_directory(remotepath, session)
        current = remotepath.start_with?('/') ? '/' : ''
        remote_components(remotepath).each do |component|
          current = join_remote(current, component)
          create_remote_directory(current, session)
        end
      end

      # Creates +path+ on the server unless this sync already created or confirmed
      # it. A failed MKD cannot be taken at face value: it is also how a server
      # says the directory is already there, so only a listing can tell the two
      # apart.
      def create_remote_directory(path, session)
        return if session.known_directory?(path)

        @connection.mkdir(path)
        session.remember_directory(path)
        log "Created #{path} directory"
      rescue Net::FTPError => e
        explain_failed_mkdir(path, session, e)
      end

      def explain_failed_mkdir(path, session, error)
        if remote_directory?(path)
          session.remember_directory(path)
          return log("#{path} directory already exists")
        end
        raise unless session.options[:skip_errors]

        report_error(session.result, path, error)
      end

      # Whether +path+ is a directory, decided from the listing of its parent.
      # Only a non-directory entry with exactly that name proves the path is not
      # a directory; anything less is not enough to fail a push, because the
      # uploads into a really missing directory report the failure by
      # themselves. That keeps the quirk where a server answers LIST for a
      # missing path with an empty listing from turning into an error, and it
      # keeps a directory that happens to contain one entry of the same name
      # from looking like a file.
      def remote_directory?(path)
        entry = parent_entry(path)
        return true if entry.nil? || entry.dir?

        log "#{path} exists but is not a directory"
        false
      end

      def upload(local_file, remote_file, remote_entry, session)
        if skip_upload?(remote_file, remote_entry, local_file, session)
          session.result.skipped += 1
          return
        end

        log "#{local_file} => #{remote_file}"
        uploaded = transfer_file(remote_file, session) { store_file(local_file, remote_file) }
        yield(remote_file) if uploaded && block_given?
      end

      # Uploads +local_file+ to +remote_file+. STOR truncates the remote file
      # before the data arrives, so an upload that fails halfway destroys the copy
      # that was there; unless :atomic_uploads is off, the data goes to a side file
      # that is renamed into place instead.
      def store_file(local_file, remote_file)
        return store_in_place(local_file, remote_file) unless @atomic_uploads && @rename_supported

        temporary = "#{remote_file}#{PART_SUFFIX}"
        store_side_file(local_file, temporary)
        error = rename_side_file(temporary, remote_file)
        store_without_rename(local_file, remote_file, error) if error
      end

      # STOR is the upload itself, not the probe: a failure here is a failed
      # upload, so the side file is discarded and the error propagates as it is.
      def store_side_file(local_file, temporary)
        @connection.putbinaryfile(local_file, temporary)
      rescue Net::FTPError
        discard_remote_file(temporary)
        raise
      end

      # Returns the rejection when the server has no RNFR/RNTO, and re-raises
      # every other rename failure. Only this call is evidence about rename
      # support, because a 500 from STOR would otherwise turn atomic uploads off
      # and retry the file in place, where a failure truncates.
      def rename_side_file(temporary, remote_file)
        @connection.rename(temporary, remote_file)
        nil
      rescue Net::FTPError => e
        discard_remote_file(temporary)
        raise unless RENAME_UNSUPPORTED.match?(e.message)

        e
      end

      # A server without RNFR/RNTO would reject every upload this way, so the
      # verdict is remembered for the connection and the fallback is logged once.
      def store_without_rename(local_file, remote_file, error)
        @rename_supported = false
        log "Server cannot rename files (#{error.message}); uploading in place instead"
        store_in_place(local_file, remote_file)
      end

      def store_in_place(local_file, remote_file)
        @connection.putbinaryfile(local_file, remote_file)
      end

      # Cleanup of the side file must not replace the failure being reported.
      def discard_remote_file(path)
        @connection.delete(path)
      rescue Net::FTPError => e
        log "Could not remove #{path}: #{e.message}"
      end
    end
    include Push
  end
end
