# frozen_string_literal: true

require 'fileutils'
require 'net/ftp'
require 'net/ftp/list'

# In-memory stand-in for Net::FTP used by the unit tests.
#
# It models the pieces of an FTP server the library talks to: directory
# listings (as parsed LIST entries), file contents, MDTM, MKD, STOR
# (truncation and all), RNFR/RNTO and DELE. Specific operations can be made to
# fail so error handling can be exercised.
class FakeFtp
  # Minimal Net::FTP::List::Entry lookalike. +type+ mirrors the real gem:
  # :file, :dir, :symlink, :device, or nil for a line no parser understood.
  Entry = Struct.new(:name, :type, :mtime, :filesize) do
    def basename
      name
    end

    def dir?
      type == :dir
    end

    def file?
      type == :file
    end

    def symlink?
      type == :symlink
    end

    def device?
      type == :device
    end

    def unknown?
      !dir? && !file? && !symlink? && !device?
    end
  end

  attr_reader :downloaded, :uploaded, :attempted_puts, :created_dirs, :mkdir_calls,
              :deleted, :renames, :connect_count, :new_args, :contents, :get_calls,
              :list_calls, :mlsd_calls, :rmdir_calls, :mlsx_facts, :fail_gets,
              :fail_puts, :fail_put_replies, :fail_lists, :fail_lists_after, :fail_mlsd,
              :fail_mkdirs,
              :fail_mdtms, :fail_renames, :mdtm_calls, :mdtm_replies

  # +server_offset+ is how far the server's LIST wall clock leads UTC; real
  # servers emit LIST in their local time, which net-ftp-list then reads as UTC.
  #
  # +fail_connect+ and +fail_login+ model a server that refuses the connection
  # or the credentials. +rename_unsupported+ models a server without RNFR/RNTO.
  # +mlsx+ says whether the server answers MLSD; it is off by default, like the
  # integration server (ftpd), so the LIST fallback stays the common path.
  attr_accessor :server_offset, :fail_connect, :fail_login, :rename_unsupported, :mlsx

  # +listings+ maps a remote directory to the entries it holds, +contents+
  # maps remote file paths to their contents.
  def initialize(listings = {}, contents: {}, server_offset: 0)
    @entries = listings.each_with_object({}) { |(path, entries), memo| memo[path] = entries.dup }
    @dirs = ['.'] + @entries.keys
    @contents = contents.dup
    @server_offset = server_offset
    @line_index = {}
    reset_state
    reset_failures
  end

  def connect(_host, _port)
    @connect_count += 1
    # A refused connection leaves no usable socket behind.
    @closed = true
    raise Net::FTPConnectionError, 'getaddrinfo: connection refused' if @fail_connect

    @closed = false
  end

  def passive=(_enabled); end

  def login(_username, _password)
    return unless @fail_login

    @closed = true
    raise Net::FTPPermError, '530 Login incorrect'
  end

  def record_new_args(args)
    @new_args << args
  end

  # LIST output is handed to Net::FTP::List.parse, which the tests stub. Each
  # yielded line is registered so the stub can map it back to its entry.
  #
  # Listing a path that is a file answers with that file's own entry, as a real
  # server does; only a path that is neither lists nothing.
  def list(remote, &block)
    @list_calls << remote
    raise Net::FTPPermError, "550 #{remote}: Permission denied" if @fail_lists.include?(remote)

    lines = entries_at(remote).map { |entry| register(list_view(entry)) }
    lines.each(&block) if block
    raise_after_cut_listing(remote)
    block ? nil : lines
  end

  # A server whose data connection dies mid-listing has already sent a prefix:
  # the client saw entries but must not treat them as the whole directory.
  def raise_after_cut_listing(remote)
    return unless @fail_lists_after.key?(remote)

    raise Net::FTPPermError, @fail_lists_after[remote]
  end

  # MLSx answers with typed facts and a UTC modify stamp, which is what the
  # library prefers over LIST when the server has it. The first two entries are
  # the cdir/pdir pseudo entries a real server emits, so the client has to
  # ignore them.
  def mlsd(remote, &block)
    @mlsd_calls << remote
    raise Net::FTPPermError, @fail_mlsd[remote] if @fail_mlsd.key?(remote)
    raise Net::FTPPermError, '502 MLSD not implemented' unless @mlsx

    entries = [mlsx_entry('.', { 'type' => 'cdir' }), mlsx_entry('..', { 'type' => 'pdir' })]
    entries += entries_at(remote).reject { |entry| %w[. ..].include?(entry.basename) }
                                 .map { |entry| mlsx_entry(entry.basename, mlsx_facts_for(entry)) }
    return entries unless block

    entries.each(&block)
  end

  # RMD only succeeds on a directory that is already empty, so a recursive
  # removal that skipped something shows up as a failure.
  def rmdir(path)
    @rmdir_calls << path
    raise Net::FTPPermError, "550 #{path}: Permission denied" unless @dirs.include?(path)
    raise Net::FTPPermError, "550 #{path}: Directory not empty" unless (@entries[path] || []).empty?

    @dirs.delete(path)
    @entries.delete(path)
    # The parent listing must stop mentioning the directory, as on a real server.
    remove_entry(path)
    nil
  end

  # MDTM reports a file's modification time in UTC, without the wall clock
  # ambiguity of LIST, and returns the raw time-val as Net::FTP#mdtm does.
  def mdtm(remote)
    @mdtm_calls << remote
    raise Net::FTPPermError, @fail_mdtms[remote] if @fail_mdtms.key?(remote)
    return @mdtm_replies[remote] if @mdtm_replies.key?(remote)

    entry = find_entry(remote)
    raise Net::FTPPermError, "550 #{remote}: No such file or directory" unless entry

    entry.mtime.utc.strftime('%Y%m%d%H%M%S')
  end

  def entry_for(line)
    @line_index.fetch(line)
  end

  def getbinaryfile(remote, local)
    if @fail_gets.key?(remote)
      File.write(local, @fail_gets[remote]) if @fail_gets[remote]
      raise Net::FTPPermError, "550 #{remote}: Permission denied"
    end

    File.write(local, @contents.fetch(remote, "content of #{remote}"))
    @downloaded << [remote, local]
  end

  # Net::FTP#get dispatches on the binary flag, so a transfer that must be
  # binary should ask for it explicitly. Recording the call lets a test see
  # that it did.
  def get(remote, local)
    @get_calls << [remote, local]
    getbinaryfile(remote, local)
  end

  # STOR truncates the remote file before any data arrives, so an upload that
  # fails halfway through leaves the earlier copy destroyed. That is the
  # behaviour atomic uploads exist to avoid, and the tests need it to be real.
  def putbinaryfile(local, remote)
    @attempted_puts << [local, remote]
    parent = File.dirname(remote)
    raise Net::FTPPermError, "550 #{parent}: No such file or directory" unless @dirs.include?(parent)

    @contents[remote] = ''
    # A reply code a test chose itself, for failures the client must not read as
    # something else (a 500 from STOR is not a verdict about rename support).
    raise Net::FTPPermError, @fail_put_replies.fetch(remote) if @fail_put_replies.key?(remote)
    raise Net::FTPPermError, "553 #{remote}: Permission denied" if puts_failing?(remote)

    @contents[remote] = File.binread(local)
    store_entry(parent, Entry.new(File.basename(remote), :file, upload_mtime, File.size(local)))
    @uploaded << [local, remote]
  end

  # RNFR/RNTO replaces the destination in one step, keeping the source's entry.
  def rename(from, to)
    raise Net::FTPPermError, '502 RNFR not implemented' if @rename_unsupported
    raise Net::FTPPermError, "550 #{from}: No such file or directory" unless @contents.key?(from)
    raise Net::FTPPermError, "550 #{to}: Permission denied" if @fail_renames.include?(to)

    @contents[to] = @contents.delete(from)
    move_entry(from, to)
    @renames << [from, to]
    replace_uploaded(from, to)
    nil
  end

  def delete(remote)
    @deleted << remote
    raise Net::FTPPermError, "550 #{remote}: No such file or directory" unless @contents.key?(remote)

    @contents.delete(remote)
    remove_entry(remote)
    nil
  end

  def mkdir(path)
    @mkdir_calls << path
    raise Net::FTPPermError, "550 #{path}: Permission denied" if @fail_mkdirs.include?(path)
    raise Net::FTPPermError, "550 #{path}: File exists" if @dirs.include?(path) || find_entry(path)

    @dirs << path
    @entries[path] = []
    @created_dirs << path
    path
  end

  def close
    @closed = true
  end

  def closed?
    @closed
  end

  # How the fake's entry types look in an MLSx type fact.
  MLSX_TYPES = { file: 'file', dir: 'dir', symlink: 'OS.unix=slink', device: 'OS.unix=chr' }.freeze

  private

  def reset_state
    @list_calls = []
    @mlsd_calls = []
    @rmdir_calls = []
    @mlsx_facts = {}
    @downloaded = []
    @get_calls = []
    @uploaded = []
    @attempted_puts = []
    @created_dirs = []
    @mkdir_calls = []
    @deleted = []
    @renames = []
    @new_args = []
    @mdtm_calls = []
    @connect_count = 0
    @line_counter = 0
    reset_flags
  end

  def reset_flags
    @mlsx = false
    @closed = true
    @fail_connect = false
    @fail_login = false
    @rename_unsupported = false
  end

  # Whether storing +remote+ is injected as failing. Naming a file to fail
  # fails the side file it would have been uploaded as too, so a test can say
  # "this file cannot be stored" without encoding how it is uploaded.
  def puts_failing?(remote)
    @fail_puts.include?(remote) || @fail_puts.include?(remote.sub(/\.ftpsync-part\z/, ''))
  end

  # The upload that went to +from+ landed at +to+, so a caller asking what was
  # uploaded keeps seeing the destination instead of the side file.
  def replace_uploaded(from, to)
    @uploaded.map! { |local, remote| [local, remote == from ? to : remote] }
  end

  def entries_at(remote)
    return @entries.fetch(remote) if @entries.key?(remote)

    entry = find_entry(remote)
    raise Net::FTPPermError, "550 #{remote}: No such file or directory" unless entry

    [entry]
  end

  # Facts a test wants to control exactly, merged over the generated ones. An
  # MLSx fact set is the only way to express a missing modify stamp, an unknown
  # type or a pseudo entry, none of which a LIST line can carry.
  def mlsx_facts_for(entry)
    facts = {}
    type = MLSX_TYPES[entry.type]
    facts['type'] = type if type
    facts['size'] = entry.filesize if entry.filesize
    facts['modify'] = entry.mtime.utc if entry.mtime
    facts.merge(@mlsx_facts.fetch(entry.basename, {}))
  end

  def mlsx_entry(pathname, facts)
    Net::FTP::MLSxEntry.new(facts, pathname)
  end

  def register(entry)
    @line_counter += 1
    line = "line#{@line_counter}"
    @line_index[line] = entry
    line
  end

  # LIST output is a wall clock reading, so the server's offset from UTC shows
  # up here but not in MDTM.
  def list_view(entry)
    return entry if @server_offset.zero?

    Entry.new(entry.name, entry.type, entry.mtime + @server_offset, entry.filesize)
  end

  def find_entry(remote)
    directory = File.dirname(remote)
    name = File.basename(remote)
    (@entries[directory] || []).find { |entry| entry.basename == name }
  end

  def reset_failures
    @fail_gets = {}
    @fail_puts = []
    @fail_put_replies = {}
    @fail_lists = []
    @fail_lists_after = {}
    @fail_mlsd = {}
    @fail_mkdirs = []
    @fail_mdtms = {}
    @fail_renames = []
    @mdtm_replies = {}
  end

  def store_entry(directory, entry)
    entries = @entries[directory] ||= []
    entries.reject! { |existing| existing.basename == entry.basename }
    entries << entry
  end

  def move_entry(from, to)
    source = find_entry(from)
    remove_entry(from)
    return unless source

    store_entry(File.dirname(to), Entry.new(File.basename(to), source.type, source.mtime, source.filesize))
  end

  def remove_entry(remote)
    directory = File.dirname(remote)
    name = File.basename(remote)
    return unless @entries[directory]

    @entries[directory].reject! { |entry| entry.basename == name }
  end

  # A server stamps an upload with its own clock, not with the client's file
  # mtime, and LIST reports it with minute precision.
  def upload_mtime
    mtime = Time.now.to_i
    Time.at(mtime - (mtime % 60))
  end
end
