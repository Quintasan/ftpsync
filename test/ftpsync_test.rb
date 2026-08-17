# frozen_string_literal: true

require 'test_helper'
require 'minitest/mock'

class FtpsyncTest < Minitest::Test
  FakeEntry = Struct.new(:name, :dir, :mtime, :filesize) do
    def basename
      name
    end

    def dir?
      dir
    end

    def file?
      !dir
    end
  end

  # Stand-in for Net::FTP that serves precomputed LIST lines and records
  # downloads instead of touching a real server.
  class FakeFtp
    attr_reader :downloaded, :connect_count

    def initialize(listings)
      @listings = listings
      @downloaded = []
      @connect_count = 0
      @closed = false
    end

    def connect(_host, _port)
      @connect_count += 1
      @closed = false
    end

    def passive=(_enabled); end

    def login(_username, _password); end

    def list(remote, &block)
      @listings.fetch(remote, {}).each_key { |line| block.call(line) }
    end

    def get(remote, local)
      raise Net::FTPPermError, 'Permission denied' if remote.include?('secret')

      @downloaded << [remote, local]
    end

    def close
      @closed = true
    end

    def closed?
      @closed
    end
  end

  def test_that_it_has_a_version_number
    refute_nil ::FtpSync::VERSION
  end

  def test_downloads_files_and_recurses_into_directories
    with_local_dir do |base|
      with_ftp(
        'root' => {
          'd subdir' => file_entry('subdir', dir: true),
          'f a.txt' => file_entry('a.txt')
        },
        'root/subdir' => {
          'f b.txt' => file_entry('b.txt')
        }
      ) do |ftp|
        sync = build_sync
        sync.pull_dir('root', base)

        # Directories are pulled before files, hence b.txt comes first.
        assert_equal [
          ['root/subdir/b.txt', File.join(base, 'subdir', 'b.txt')],
          ['root/a.txt', File.join(base, 'a.txt')]
        ], ftp.downloaded
      end
    end
  end

  def test_creates_missing_local_directories
    with_local_dir do |base|
      with_ftp('root' => {}) do
        sync = build_sync
        local = File.join(base, 'nested', 'deep')

        sync.pull_dir('root', local)

        assert File.directory?(local)
      end
    end
  end

  def test_yields_block_with_local_path_of_each_downloaded_file
    with_local_dir do |base|
      with_ftp('root' => { 'f a.txt' => file_entry('a.txt') }) do
        sync = build_sync
        downloaded = []

        sync.pull_dir('root', base) { |path| downloaded << path }

        assert_equal [File.join(base, 'a.txt')], downloaded
      end
    end
  end

  def test_since_skips_unchanged_files
    with_local_dir do |base|
      time = Time.now - 3600
      local = File.join(base, 'a.txt')
      File.write(local, 'data')
      File.utime(time, time, local)

      with_ftp('root' => { 'f a.txt' => file_entry('a.txt', mtime: time - 100, filesize: 4) }) do |ftp|
        sync = build_sync
        sync.pull_dir('root', base, since: true)

        assert_empty ftp.downloaded
      end
    end
  end

  def test_since_downloads_missing_or_changed_files
    with_local_dir do |base|
      time = Time.now - 3600
      local = File.join(base, 'a.txt')
      File.write(local, 'data')
      File.utime(time, time, local)

      with_ftp(
        'root' => {
          'f a.txt' => file_entry('a.txt', mtime: time + 100, filesize: 4), # newer than local
          'f b.txt' => file_entry('b.txt', mtime: time - 100, filesize: 4)  # missing locally
        }
      ) do |ftp|
        sync = build_sync
        sync.pull_dir('root', base, since: true)

        assert_equal [
          ['root/a.txt', File.join(base, 'a.txt')],
          ['root/b.txt', File.join(base, 'b.txt')]
        ], ftp.downloaded
      end
    end
  end

  def test_skip_errors_continues_after_permission_denied
    with_local_dir do |base|
      with_ftp(
        'root' => {
          'f secret.txt' => file_entry('secret.txt'),
          'f a.txt' => file_entry('a.txt')
        }
      ) do |ftp|
        sync = build_sync
        sync.pull_dir('root', base, skip_errors: true)

        assert_equal [['root/a.txt', File.join(base, 'a.txt')]], ftp.downloaded
      end
    end
  end

  def test_raises_without_skip_errors
    with_local_dir do |base|
      with_ftp('root' => { 'f secret.txt' => file_entry('secret.txt') }) do
        sync = build_sync

        error = assert_raises Net::FTPPermError do
          sync.pull_dir('root', base)
        end

        assert_equal 'Permission denied', error.message
      end
    end
  end

  def test_reuses_connection_across_nested_directories
    with_local_dir do |base|
      with_ftp(
        'root' => { 'd subdir' => file_entry('subdir', dir: true) },
        'root/subdir' => {}
      ) do |ftp|
        sync = build_sync
        sync.pull_dir('root', base)

        assert_equal 1, ftp.connect_count
        assert_predicate ftp, :closed?
      end
    end
  end

  def test_reconnects_for_a_fresh_top_level_pull
    with_local_dir do |base|
      with_ftp('root' => {}) do |ftp|
        sync = build_sync
        sync.pull_dir('root', base)
        sync.pull_dir('root', base)

        assert_equal 2, ftp.connect_count
      end
    end
  end

  private

  def file_entry(name, dir: false, mtime: Time.now, filesize: 0)
    FakeEntry.new(name, dir, mtime, filesize)
  end

  def build_sync
    FtpSync::Simple.new('ftp.example.com', 'user', 'pass', verbose: false)
  end

  def with_local_dir(&block)
    Dir.mktmpdir(&block)
  end

  # Runs the block with Net::FTP.new and Net::FTP::List.parse substituted by
  # fakes. +listings+ maps a remote path to a hash of raw LIST line => entry.
  def with_ftp(listings)
    entries = listings.each_with_object({}) do |(_path, lines), memo|
      lines.each { |line, entry| memo[line] = entry }
    end

    ftp = FakeFtp.new(listings)
    Net::FTP.stub(:new, ftp) do
      Net::FTP::List.stub(:parse, ->(line) { entries.fetch(line) }) do
        yield ftp
      end
    end
  end
end
