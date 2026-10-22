# frozen_string_literal: true

require 'support/sync_test_case'

class FtpsyncTest < SyncTestCase
  def test_that_it_has_a_version_number
    refute_nil ::FtpSync::VERSION
  end

  def test_downloads_files_and_recurses_into_directories
    with_local_dir do |base|
      with_ftp('root' => [dir_entry('subdir'), file_entry('a.txt')],
               'root/subdir' => [file_entry('b.txt')]) do |ftp|
        sync.pull_dir('root', base)

        assert_equal remote_content('root/a.txt'), File.read(File.join(base, 'a.txt'))
        assert_equal remote_content('root/subdir/b.txt'),
                     File.read(File.join(base, 'subdir', 'b.txt'))
        # Directories are pulled before files, hence b.txt comes first.
        assert_equal %w[root/subdir/b.txt root/a.txt], ftp.downloaded.map(&:first)
      end
    end
  end

  def test_creates_missing_local_directories
    with_local_dir do |base|
      with_ftp('root' => []) do
        local = File.join(base, 'nested', 'deep')

        sync.pull_dir('root', local)

        assert File.directory?(local)
      end
    end
  end

  def test_yields_block_with_local_path_of_each_downloaded_file
    with_local_dir do |base|
      with_ftp('root' => [file_entry('a.txt')]) do
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

      with_ftp('root' => [file_entry('a.txt', mtime: time - 100, filesize: 4)]) do |ftp|
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
        'root' => [
          file_entry('a.txt', mtime: time + 100, filesize: 4), # newer than local
          file_entry('b.txt', mtime: time - 100, filesize: 4)  # missing locally
        ]
      ) do |ftp|
        sync.pull_dir('root', base, since: true)

        assert_equal %w[root/a.txt root/b.txt], ftp.downloaded.map(&:first)
      end
    end
  end

  # The server mtime is kept on the downloaded file, so a second :since run
  # recognises its own work instead of re-fetching it.
  def test_preserves_remote_mtime_so_the_next_since_run_changes_nothing
    with_local_dir do |base|
      time = Time.now - 7200
      with_ftp({ 'root' => [file_entry('a.txt', mtime: time, filesize: 4)] },
               { 'root/a.txt' => 'data' }) do |ftp|
        sync.pull_dir('root', base)

        assert_in_delta time.to_f, File.mtime(File.join(base, 'a.txt')).to_f, 0.01

        sync.pull_dir('root', base, since: true)

        assert_equal 1, ftp.downloaded.size
      end
    end
  end

  def test_skip_errors_continues_after_permission_denied
    with_local_dir do |base|
      with_ftp('root' => [file_entry('secret.txt'), file_entry('a.txt')]) do |ftp|
        ftp.fail_gets['root/secret.txt'] = nil

        sync.pull_dir('root', base, skip_errors: true)

        assert_equal %w[root/a.txt], ftp.downloaded.map(&:first)
      end
    end
  end

  def test_raises_without_skip_errors
    with_local_dir do |base|
      with_ftp('root' => [file_entry('secret.txt')]) do |ftp|
        ftp.fail_gets['root/secret.txt'] = nil

        assert_raises Net::FTPPermError do
          sync.pull_dir('root', base)
        end
      end
    end
  end

  def test_skip_errors_also_covers_directory_listings
    with_local_dir do |base|
      with_ftp('root' => [dir_entry('locked'), file_entry('a.txt')],
               'root/locked' => []) do |ftp|
        ftp.fail_lists << 'root/locked'

        sync.pull_dir('root', base, skip_errors: true)

        assert_equal %w[root/a.txt], ftp.downloaded.map(&:first)
      end
    end
  end

  def test_raises_when_a_listing_fails_without_skip_errors
    with_local_dir do |base|
      with_ftp('root' => []) do |ftp|
        ftp.fail_lists << 'root'

        assert_raises Net::FTPPermError do
          sync.pull_dir('root', base)
        end
      end
    end
  end

  # A failed transfer must not leave a truncated file behind, nor clobber the
  # file that was already there.
  def test_failed_download_leaves_no_partial_file
    with_local_dir do |base|
      destination = File.join(base, 'a.txt')
      File.write(destination, 'previous')

      with_ftp('root' => [file_entry('a.txt')]) do |ftp|
        ftp.fail_gets['root/a.txt'] = 'partial'

        sync.pull_dir('root', base, skip_errors: true)

        assert_equal 'previous', File.read(destination)
        refute_path_exists "#{destination}#{FtpSync::Simple::PART_SUFFIX}"
      end
    end
  end

  def test_failed_download_does_not_invoke_the_block
    with_local_dir do |base|
      with_ftp('root' => [file_entry('a.txt')]) do |ftp|
        ftp.fail_gets['root/a.txt'] = 'partial'
        downloaded = []

        sync.pull_dir('root', base, skip_errors: true) { |path| downloaded << path }

        assert_empty downloaded
      end
    end
  end

  def test_reuses_connection_across_nested_directories
    with_local_dir do |base|
      with_ftp('root' => [dir_entry('subdir')], 'root/subdir' => []) do |ftp|
        sync.pull_dir('root', base)

        assert_equal 1, ftp.connect_count
        assert_predicate ftp, :closed?
      end
    end
  end

  def test_reconnects_for_a_fresh_top_level_pull
    with_local_dir do |base|
      with_ftp('root' => []) do |ftp|
        simple = sync
        simple.pull_dir('root', base)
        simple.pull_dir('root', base)

        assert_equal 2, ftp.connect_count
      end
    end
  end

  def test_closes_the_connection_when_a_sync_fails
    with_local_dir do |base|
      with_ftp('root' => [file_entry('a.txt')]) do |ftp|
        ftp.fail_gets['root/a.txt'] = nil

        assert_raises(Net::FTPPermError) { sync.pull_dir('root', base) }
        assert_predicate ftp, :closed?
      end
    end
  end

  def test_reconnects_after_a_failed_sync
    with_local_dir do |base|
      with_ftp('root' => [file_entry('a.txt')]) do |ftp|
        simple = sync
        ftp.fail_gets['root/a.txt'] = nil
        assert_raises(Net::FTPPermError) { simple.pull_dir('root', base) }

        ftp.fail_gets.delete('root/a.txt')
        simple.pull_dir('root', base)

        assert_equal 2, ftp.connect_count
        assert_equal remote_content('root/a.txt'), File.read(File.join(base, 'a.txt'))
      end
    end
  end

  # A callback that starts another sync keeps the connection open; only the
  # outermost call closes it.
  def test_nested_pull_from_a_block_reuses_the_connection
    with_local_dir do |outer|
      with_local_dir do |inner|
        with_ftp('root' => [file_entry('a.txt')], 'other' => [file_entry('b.txt')]) do |ftp|
          simple = sync
          simple.pull_dir('root', outer) do
            simple.pull_dir('other', inner)
          end

          assert_equal 1, ftp.connect_count
          assert_predicate ftp, :closed?
          assert_equal remote_content('other/b.txt'), File.read(File.join(inner, 'b.txt'))
        end
      end
    end
  end

  def test_close_is_safe_when_never_connected
    sync.close!
    sync.close!

    assert_nil sync.instance_variable_get(:@connection)
  end

  # A failed connect must not leave the socket open, and it must not stop the
  # next sync from connecting afresh. That only holds when the nesting counter
  # is incremented before the connection is attempted.
  def test_a_failed_connect_propagates_and_does_not_poison_the_next_sync
    with_local_dir do |base|
      with_ftp('root' => [file_entry('a.txt')]) do |ftp|
        simple = sync
        ftp.fail_connect = true

        assert_raises(Net::FTPConnectionError) { simple.pull_dir('root', base) }
        assert_predicate ftp, :closed?

        ftp.fail_connect = false
        simple.pull_dir('root', base)

        assert_equal [2, remote_content('root/a.txt')],
                     [ftp.connect_count, File.read(File.join(base, 'a.txt'))]
      end
    end
  end

  def test_a_failed_login_propagates_and_closes_the_socket
    with_local_dir do |base|
      with_ftp('root' => []) do |ftp|
        ftp.fail_login = true

        assert_raises(Net::FTPPermError) { sync.pull_dir('root', base) }
        assert_predicate ftp, :closed?
      end
    end
  end
end
