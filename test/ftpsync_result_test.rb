# frozen_string_literal: true

require 'support/sync_test_case'

# The return value of a sync: what was moved, what was left alone and what went
# wrong. Both directions have to report the same way.
class FtpsyncResultTest < SyncTestCase
  def test_a_pull_returns_counts_and_the_errors_skip_errors_swallowed
    with_local_dir do |base|
      entries = [file_entry('a.txt'), file_entry('secret.txt'), symlink_entry('link.txt')]

      with_ftp('root' => entries) do |ftp|
        ftp.fail_gets['root/secret.txt'] = nil

        result = sync.pull_dir('root', base, skip_errors: true)

        assert_instance_of FtpSync::Simple::Result, result
        assert_equal [1, 1, 1], [result.transferred, result.skipped, result.failed]
        assert_equal [['root/secret.txt', '550 root/secret.txt: Permission denied']], result.errors
      end
    end
  end

  def test_a_push_returns_counts_and_the_errors_skip_errors_swallowed
    with_local_dir do |base|
      write_files(base, 'a.txt' => 'one', 'b.txt' => 'two')

      with_ftp do |ftp|
        ftp.fail_puts << 'root/a.txt'

        result = sync.push_dir(base, 'root', skip_errors: true)

        assert_equal [1, 0, 1], [result.transferred, result.skipped, result.failed]
        assert_equal ['root/a.txt'], result.errors.map(&:first)
        assert_match(/553 .*Permission denied/, result.errors.first.last)
      end
    end
  end

  def test_the_result_exposes_the_documented_fields
    assert_equal %i[transferred skipped failed errors deleted], FtpSync::Simple::Result.members
  end

  def test_a_sync_counts_files_it_skips_because_they_are_up_to_date
    with_local_dir do |base|
      write_files(base, 'a.txt' => 'data')
      set_mtime(File.join(base, 'a.txt'), Time.now - 3600)

      with_ftp do
        sync.push_dir(base, 'root')

        result = sync.push_dir(base, 'root', since: true)

        assert_equal 0, result.transferred
        assert_equal 1, result.skipped
        assert_equal 0, result.failed
      end
    end
  end
end
