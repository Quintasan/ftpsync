# frozen_string_literal: true

require 'test_helper'
require_relative 'ftp_server'

class FtpsyncIntegrationTest < Minitest::Test
  def self.server
    @server ||= FtpServer.new.tap(&:start)
  end

  Minitest.after_run do
    @server&.stop
  end

  def setup
    server.reset
  end

  def test_pulls_a_directory_tree
    server.seed(
      'root/a.txt' => 'hello a',
      'root/sub/b.txt' => 'hello b'
    )

    Dir.mktmpdir do |local|
      sync.pull_dir('root', local)

      assert_equal 'hello a', File.read(File.join(local, 'a.txt'))
      assert_equal 'hello b', File.read(File.join(local, 'sub', 'b.txt'))
    end
  end

  def test_preserves_binary_file_contents
    payload = Random.bytes(1_048_576)
    server.seed('root/blob.bin' => payload)

    Dir.mktmpdir do |local|
      sync.pull_dir('root', local)

      assert_equal payload, File.binread(File.join(local, 'blob.bin'))
    end
  end

  def test_creates_missing_local_directories
    server.seed('root/a.txt' => 'hello')

    Dir.mktmpdir do |base|
      local = File.join(base, 'nested', 'deep')

      sync.pull_dir('root', local)

      assert File.directory?(local)
      assert_equal 'hello', File.read(File.join(local, 'a.txt'))
    end
  end

  def test_invokes_block_for_each_downloaded_file
    server.seed('root/a.txt' => 'one', 'root/b.txt' => 'two')

    Dir.mktmpdir do |local|
      downloaded = []
      sync.pull_dir('root', local) { |path| downloaded << path }

      assert_equal [File.join(local, 'a.txt'), File.join(local, 'b.txt')],
                   downloaded.sort
    end
  end

  def test_since_skips_unchanged_files
    server.seed('root/a.txt' => 'v1')

    Dir.mktmpdir do |local|
      sync.pull_dir('root', local, since: true)

      downloaded = []
      sync.pull_dir('root', local, since: true) { |path| downloaded << path }

      assert_empty downloaded
      assert_equal 'v1', File.read(File.join(local, 'a.txt'))
    end
  end

  def test_since_refetches_changed_files
    server.seed('root/a.txt' => 'version one')

    Dir.mktmpdir do |local|
      sync.pull_dir('root', local, since: true)
      server.seed('root/a.txt' => 'version two, longer')

      downloaded = []
      sync.pull_dir('root', local, since: true) { |path| downloaded << path }

      assert_equal [File.join(local, 'a.txt')], downloaded
      assert_equal 'version two, longer', File.read(File.join(local, 'a.txt'))
    end
  end

  def test_pushes_a_directory_tree
    Dir.mktmpdir do |local|
      FileUtils.mkdir_p(File.join(local, 'sub'))
      File.write(File.join(local, 'a.txt'), 'hello a')
      File.write(File.join(local, 'sub/b.txt'), 'hello b')

      sync.push_dir(local, 'root')

      Dir.mktmpdir do |pulled|
        sync.pull_dir('root', pulled)

        assert_equal 'hello a', File.read(File.join(pulled, 'a.txt'))
        assert_equal 'hello b', File.read(File.join(pulled, 'sub', 'b.txt'))
      end
    end
  end

  def test_pushes_binary_files
    payload = Random.bytes(1_048_576)

    Dir.mktmpdir do |local|
      File.binwrite(File.join(local, 'blob.bin'), payload)

      sync.push_dir(local, 'root')

      Dir.mktmpdir do |pulled|
        sync.pull_dir('root', pulled)

        assert_equal payload, File.binread(File.join(pulled, 'blob.bin'))
      end
    end
  end

  def test_push_since_skips_unchanged_files
    Dir.mktmpdir do |local|
      path = File.join(local, 'a.txt')
      File.write(path, 'v1')
      # The server stamps the upload with its own clock, so a file written well
      # before the upload must still count as unchanged.
      File.utime(Time.now - 3600, Time.now - 3600, path)
      sync.push_dir(local, 'root')

      uploaded = []
      sync.push_dir(local, 'root', since: true) { |remote| uploaded << remote }

      assert_empty uploaded
    end
  end

  def test_push_since_refetches_changed_files
    Dir.mktmpdir do |local|
      File.write(File.join(local, 'a.txt'), 'v1')
      sync.push_dir(local, 'root')

      File.write(File.join(local, 'a.txt'), 'version two, longer')
      uploaded = []
      sync.push_dir(local, 'root', since: true) { |path| uploaded << path }

      assert_equal ['root/a.txt'], uploaded
    end
  end

  # MDTM answers in UTC while LIST is a server-local wall clock. On a non-UTC
  # server a LIST timestamp parsed as UTC moves into the future, so a same-size
  # edit made after the 2 s MDTM tolerance would look unchanged and be skipped.
  # Run with TZ=Europe/Warsaw: this fails if push :since ever falls back to
  # LIST timestamps.
  def test_push_since_detects_a_same_size_edit
    Dir.mktmpdir do |local|
      path = File.join(local, 'a.txt')
      File.write(path, 'aaaa')
      sync.push_dir(local, 'root')
      # The remote copy is stored with the server's clock at upload time. Move
      # past the MDTM tolerance before editing, or the edit is legitimately
      # indistinguishable from clock jitter.
      sleep 3

      File.write(path, 'bbbb')
      uploaded = []
      sync.push_dir(local, 'root', since: true) { |remote| uploaded << remote }

      assert_equal ['root/a.txt'], uploaded

      assert_remote_content('root', 'a.txt', 'bbbb')
    end
  end

  # The default upload path stores a side file and renames it into place. A
  # push that replaces a file uploaded earlier therefore needs RNFR/RNTO that
  # overwrite, and the server log proves the rename ran instead of the in-place
  # fallback.
  def test_push_replaces_an_existing_remote_file_through_rename
    Dir.mktmpdir do |local|
      path = File.join(local, 'a.txt')
      File.write(path, 'v1')
      sync.push_dir(local, 'root')

      server.clear_log
      File.write(path, 'version two')
      sync.push_dir(local, 'root')

      assert_includes server.log, 'RNFR'
      assert_includes server.log, 'RNTO'

      assert_remote_content('root', 'a.txt', 'version two')
    end
  end

  # The fallback stores directly at the destination, truncating whatever the
  # server had there, so it has to be exercised against a real server too.
  def test_push_in_place_replaces_an_existing_remote_file
    Dir.mktmpdir do |local|
      path = File.join(local, 'a.txt')
      File.write(path, 'v1')
      sync.push_dir(local, 'root')

      File.write(path, 'version two')
      sync(atomic_uploads: false).push_dir(local, 'root')

      assert_remote_content('root', 'a.txt', 'version two')
    end
  end

  private

  def server
    self.class.server
  end

  # Pulls the remote directory and asserts the file's contents, so the check
  # goes through the protocol instead of the server's temp directory.
  def assert_remote_content(remote_dir, basename, expected)
    Dir.mktmpdir do |pulled|
      sync.pull_dir(remote_dir, pulled)

      assert_equal expected, File.read(File.join(pulled, basename))
    end
  end

  def sync(**options)
    FtpSync::Simple.new(FtpServer::HOST, FtpServer::USER, FtpServer::PASS,
                        passive: true, port: server.port, **options)
  end
end
