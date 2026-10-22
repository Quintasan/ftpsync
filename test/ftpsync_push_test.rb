# frozen_string_literal: true

require 'support/sync_test_case'

class FtpsyncPushTest < SyncTestCase
  def test_uploads_files_and_creates_missing_remote_directories
    with_local_dir do |base|
      write_files(base, 'a.txt' => 'one', 'sub/b.txt' => 'two')

      with_ftp do |ftp|
        sync.push_dir(base, 'root')

        assert_equal %w[root root/sub], ftp.created_dirs
        assert_equal %w[root/a.txt root/sub/b.txt], ftp.uploaded.map(&:last).sort
        assert_equal 'one', ftp.contents['root/a.txt']
      end
    end
  end

  def test_reuses_remote_directories_that_already_exist
    with_local_dir do |base|
      write_files(base, 'sub/b.txt' => 'two')

      with_ftp('root' => [], 'root/sub' => []) do |ftp|
        sync.push_dir(base, 'root')

        assert_empty ftp.created_dirs
        assert_equal %w[root/sub/b.txt], ftp.uploaded.map(&:last)
      end
    end
  end

  def test_creates_only_the_missing_remote_directories
    with_local_dir do |base|
      write_files(base, 'sub/deep/b.txt' => 'two')

      with_ftp('root' => [], 'root/sub' => []) do |ftp|
        sync.push_dir(base, 'root')

        assert_equal %w[root/sub/deep], ftp.created_dirs
      end
    end
  end

  def test_uploads_empty_directories
    with_local_dir do |base|
      FileUtils.mkdir_p(File.join(base, 'empty'))

      with_ftp do |ftp|
        sync.push_dir(base, 'root')

        assert_equal %w[root root/empty], ftp.created_dirs
        assert_empty ftp.uploaded
      end
    end
  end

  def test_yields_block_with_remote_path_of_each_uploaded_file
    with_local_dir do |base|
      write_files(base, 'a.txt' => 'one', 'b.txt' => 'two')

      with_ftp do
        uploaded = []

        sync.push_dir(base, 'root') { |path| uploaded << path }

        assert_equal %w[root/a.txt root/b.txt], uploaded
      end
    end
  end

  # The remote mtime is the upload time, so a file written long before its
  # upload must still be recognised as unchanged.
  def test_skip_errors_continues_after_a_failed_upload
    with_local_dir do |base|
      write_files(base, 'a.txt' => 'one', 'b.txt' => 'two')

      with_ftp do |ftp|
        ftp.fail_puts << 'root/a.txt'

        result = sync.push_dir(base, 'root', skip_errors: true)

        # a.txt was tried and failed; only b.txt made it, and the run continued.
        assert_equal [partial_path('root/a.txt'), 'root/b.txt'],
                     [ftp.attempted_puts.map(&:last).first, ftp.uploaded.map(&:last).last]
        assert_equal 1, result.failed
      end
    end
  end

  def test_raises_after_a_failed_upload_without_skip_errors
    with_local_dir do |base|
      write_files(base, 'a.txt' => 'one')

      with_ftp do |ftp|
        ftp.fail_puts << 'root/a.txt'

        assert_raises(Net::FTPPermError) { sync.push_dir(base, 'root') }
        assert_predicate ftp, :closed?
      end
    end
  end

  def test_skips_symlinks
    with_local_dir do |base|
      write_files(base, 'a.txt' => 'one')
      FileUtils.mkdir_p(File.join(base, 'empty'))
      File.symlink('a.txt', File.join(base, 'link.txt'))
      File.symlink('empty', File.join(base, 'linkdir'))

      with_ftp do |ftp|
        sync.push_dir(base, 'root')

        assert_equal %w[root/a.txt], ftp.uploaded.map(&:last)
        assert_equal %w[root root/empty], ftp.created_dirs
      end
    end
  end

  def test_supports_absolute_remote_paths
    with_local_dir do |base|
      write_files(base, 'a.txt' => 'one')

      with_ftp do |ftp|
        sync.push_dir(base, '/srv/data')

        assert_equal %w[/srv /srv/data], ftp.created_dirs
        assert_equal 'one', ftp.contents['/srv/data/a.txt']
      end
    end
  end

  # An empty remote path means the login directory: nothing to create there, and
  # remote names stay relative.
  def test_uploads_into_the_login_directory_for_an_empty_remote_path
    with_local_dir do |base|
      write_files(base, 'a.txt' => 'one')

      with_ftp do |ftp|
        sync.push_dir(base, '')

        assert_empty ftp.created_dirs
        assert_equal ['a.txt'], ftp.uploaded.map(&:last)
        assert_equal 'one', ftp.contents['a.txt']
      end
    end
  end

  def test_raises_for_a_missing_local_directory
    with_local_dir do |base|
      assert_raises(ArgumentError) { sync.push_dir(File.join(base, 'nope'), 'root') }
    end
  end

  def test_closes_the_connection_when_a_push_fails
    with_local_dir do |base|
      write_files(base, 'a.txt' => 'one')

      with_ftp do |ftp|
        ftp.fail_puts << 'root/a.txt'

        assert_raises(Net::FTPPermError) { sync.push_dir(base, 'root') }
        assert_predicate ftp, :closed?
      end
    end
  end

  def test_skip_errors_continues_after_a_failed_remote_directory_creation
    with_local_dir do |base|
      write_file(base, 'sub/a.txt', 'one')

      with_ftp do |ftp|
        ftp.fail_mkdirs << 'root/sub'

        sync.push_dir(base, 'root', skip_errors: true)

        assert_empty ftp.uploaded
      end
    end
  end

  def test_raises_after_a_failed_remote_directory_creation_without_skip_errors
    with_local_dir do |base|
      write_file(base, 'sub/a.txt', 'one')

      with_ftp do |ftp|
        ftp.fail_mkdirs << 'root/sub'

        assert_raises(Net::FTPPermError) { sync.push_dir(base, 'root') }
        assert_predicate ftp, :closed?
      end
    end
  end

  # A failed MKD is 550 both for "already there" and for a real failure. A file
  # sitting on the path is the second kind and must not pass as a directory.
  def test_names_a_file_that_sits_where_a_remote_directory_is_needed
    with_local_dir do |base|
      write_files(base, 'sub/a.txt' => 'one')

      with_ftp('root' => [file_entry('sub')]) do
        simple = recording_sync

        error = assert_raises(Net::FTPPermError) { simple.push_dir(base, 'root') }

        assert_match(/File exists/, error.message)
        assert_logged(simple, 'root/sub exists but is not a directory')
      end
    end
  end

  def test_reports_a_file_in_the_way_and_skip_errors_keeps_the_run_going
    with_local_dir do |base|
      write_files(base, 'sub/a.txt' => 'one')

      with_ftp('root' => [file_entry('sub')]) do |ftp|
        result = sync.push_dir(base, 'root', skip_errors: true)

        # The failed MKD and the upload into the missing directory are reported
        # by the same path, which is what the caller has to act on.
        assert_equal 2, result.failed
        assert_equal ['root/sub', 'root/sub/a.txt'], result.errors.map(&:first)
        assert_empty ftp.uploaded
      end
    end
  end

  # A directory may hold a single entry with the same name as itself. Only the
  # listing of the parent can tell that apart from a file in the way.
  def test_a_directory_holding_one_entry_named_after_itself_is_still_a_directory
    with_local_dir do |base|
      write_files(base, 'data/x.txt' => 'one')

      with_ftp('root' => [dir_entry('data')], 'root/data' => [file_entry('data')]) do |ftp|
        result = sync.push_dir(base, 'root')

        assert_equal ['root/data/x.txt'], ftp.uploaded.map(&:last)
        assert_equal [1, 0], [result.transferred, result.failed]
      end
    end
  end

  # An unreadable parent listing proves nothing about the directory itself, so
  # it must not turn a push that used to work into an error.
  def test_an_unreadable_parent_listing_does_not_turn_a_directory_into_an_error
    with_local_dir do |base|
      write_files(base, 'sub/a.txt' => 'one')

      with_ftp('root' => [dir_entry('sub')], 'root/sub' => []) do |ftp|
        ftp.fail_lists << 'root'

        result = sync.push_dir(base, 'root')

        assert_equal ['root/sub/a.txt'], ftp.uploaded.map(&:last)
        assert_equal 0, result.failed
      end
    end
  end

  # Every directory used to re-probe every ancestor, which is O(depth) round
  # trips per directory. One MKD per directory in the tree is the contract.
  def test_probes_each_remote_directory_once_per_sync
    with_local_dir do |base|
      write_files(base, 'a/b/c/d/file.txt' => 'one')

      with_ftp do |ftp|
        sync.push_dir(base, 'root')

        assert_equal %w[root root/a root/a/b root/a/b/c root/a/b/c/d], ftp.mkdir_calls
      end
    end
  end

  def test_skips_leftover_partial_downloads
    with_local_dir do |base|
      write_files(base, 'a.txt' => 'one', "b.txt#{FtpSync::Simple::PART_SUFFIX}" => 'partial')

      with_ftp do |ftp|
        simple = recording_sync
        result = simple.push_dir(base, 'root')

        assert_equal ['root/a.txt'], ftp.uploaded.map(&:last)
        assert_equal [1, nil], [result.skipped, ftp.contents[partial_path('root/b.txt')]]
        assert_logged(simple, 'b.txt.ftpsync-part', 'leftover partial download')
      end
    end
  end
end
