# frozen_string_literal: true

require 'support/sync_test_case'

# Uploads replace the remote copy in one step by default, because STOR
# truncates the file it is about to write before any data arrives.
class FtpsyncAtomicUploadTest < SyncTestCase
  def test_uploads_atomically_by_default
    with_local_dir do |base|
      write_files(base, 'a.txt' => 'one')

      with_ftp do |ftp|
        sync.push_dir(base, 'root')

        assert_equal [[partial_path('root/a.txt'), 'root/a.txt']], ftp.renames
        assert_equal 'one', ftp.contents['root/a.txt']
        refute ftp.contents.key?(partial_path('root/a.txt'))
      end
    end
  end

  # STOR truncates the remote copy before the data arrives, so an in-place
  # upload that fails destroys what was there. This is the reason the default
  # is atomic, and the reason :atomic_uploads exists as an escape hatch.
  def test_an_in_place_upload_destroys_the_remote_copy_when_the_transfer_fails
    with_local_dir do |base|
      write_files(base, 'a.txt' => 'new!')

      with_ftp('root' => [file_entry('a.txt', filesize: 3)]) do |ftp|
        ftp.contents['root/a.txt'] = 'old'
        ftp.fail_puts << 'root/a.txt'

        sync = FtpSync::Simple.new('ftp.example.com', 'user', 'pass', atomic_uploads: false)
        sync.push_dir(base, 'root', skip_errors: true)

        assert_equal '', ftp.contents['root/a.txt']
        assert_empty ftp.renames
      end
    end
  end

  def test_an_atomic_upload_keeps_the_remote_copy_and_the_side_file_goes_away
    with_local_dir do |base|
      write_files(base, 'a.txt' => 'new!')

      with_ftp('root' => [file_entry('a.txt', filesize: 3)]) do |ftp|
        ftp.contents['root/a.txt'] = 'old'
        ftp.fail_puts << 'root/a.txt'

        result = sync.push_dir(base, 'root', skip_errors: true)

        assert_equal ['old', nil, 1],
                     [ftp.contents['root/a.txt'], ftp.contents[partial_path('root/a.txt')], result.failed]
        assert_empty ftp.renames
      end
    end
  end

  def test_falls_back_to_in_place_uploads_when_the_server_cannot_rename
    with_local_dir do |base|
      write_files(base, 'a.txt' => 'one', 'b.txt' => 'two')

      with_ftp do |ftp|
        ftp.rename_unsupported = true
        sync.push_dir(base, 'root')

        # No side files left behind, and both files are where they belong.
        assert_equal %w[root/a.txt root/b.txt], ftp.contents.keys.sort
        assert_equal %w[one two], [ftp.contents['root/a.txt'], ftp.contents['root/b.txt']]
      end
    end
  end

  # The rename verdict belongs to one connection, so a new one probes again.
  def test_rename_support_is_probed_again_after_reconnecting
    with_local_dir do |base|
      write_files(base, 'a.txt' => 'one')

      with_ftp do |ftp|
        ftp.rename_unsupported = true
        simple = sync
        simple.push_dir(base, 'root')

        ftp.rename_unsupported = false
        write_files(base, 'a.txt' => 'two')
        simple.push_dir(base, 'root')

        assert_equal [[partial_path('root/a.txt'), 'root/a.txt']], ftp.renames
        assert_equal 'two', ftp.contents['root/a.txt']
      end
    end
  end

  def test_the_in_place_fallback_is_logged_once_and_not_retried_for_the_next_file
    with_local_dir do |base|
      write_files(base, 'a.txt' => 'one', 'b.txt' => 'two')

      with_ftp do |ftp|
        ftp.rename_unsupported = true
        simple = recording_sync
        simple.push_dir(base, 'root')

        fallbacks = simple.messages.count { |message| message.include?('cannot rename') }

        assert_empty ftp.renames
        # a.txt is tried as a side file and again in place, b.txt in place once.
        assert_equal [3, 1], [ftp.attempted_puts.size, fallbacks]
      end
    end
  end

  # A 500 for STOR says nothing about RNFR/RNTO. Reading it as "cannot rename"
  # would switch atomic uploads off and retry the file in place, where a failure
  # truncates the remote copy.
  def test_a_stor_rejection_is_not_mistaken_for_missing_rename_support
    with_local_dir do |base|
      write_files(base, 'a.txt' => 'one', 'b.txt' => 'two')
      temporary = partial_path('root/a.txt')

      with_ftp('root' => [file_entry('a.txt', filesize: 3)]) do |ftp|
        ftp.contents['root/a.txt'] = 'old'
        ftp.fail_put_replies[temporary] = '500 STOR not understood'

        result = sync.push_dir(base, 'root', skip_errors: true)

        assert_equal [1, 'old', nil, [[partial_path('root/b.txt'), 'root/b.txt']]],
                     [result.failed, ftp.contents['root/a.txt'], ftp.contents[temporary], ftp.renames]
      end
    end
  end

  def test_a_failed_rename_is_reported_and_does_not_disable_atomic_uploads
    with_local_dir do |base|
      write_files(base, 'a.txt' => 'one', 'b.txt' => 'two')

      with_ftp do |ftp|
        ftp.fail_renames << 'root/a.txt'

        result = sync.push_dir(base, 'root', skip_errors: true)

        assert_equal [1, [['root/a.txt', '550 root/a.txt: Permission denied']]],
                     [result.failed, result.errors]
        assert_equal [nil, nil], [ftp.contents['root/a.txt'], ftp.contents[partial_path('root/a.txt')]]
        # b.txt still goes through a rename, so the failure did not disable the
        # atomic path for the rest of the connection.
        assert_equal [[partial_path('root/b.txt'), 'root/b.txt']], ftp.renames
      end
    end
  end
end
