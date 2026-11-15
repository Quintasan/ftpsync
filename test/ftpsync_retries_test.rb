# frozen_string_literal: true

require 'support/sync_test_case'

# :retries re-issues a failed transfer on the same connection. It is for the
# transient failure (a dropped data connection, a busy server), not for a dead
# control connection, and it never hides a failure that outlasts the budget.
class FtpsyncRetriesTest < SyncTestCase
  def test_a_transient_download_failure_is_retried
    with_local_dir do |base|
      with_ftp({ 'root' => [file_entry('a.txt')] }, 'root/a.txt' => 'data') do |ftp|
        ftp.fail_gets_times['root/a.txt'] = 1
        simple = recording_sync(retries: 1)
        result = simple.pull_dir('root', base)

        assert_equal [1, 0], [result.transferred, result.failed]
        assert_equal 'data', File.read(File.join(base, 'a.txt'))
      end
    end
  end

  def test_the_retry_is_logged_with_its_attempt_number
    with_local_dir do |base|
      with_ftp({ 'root' => [file_entry('a.txt')] }) do |ftp|
        ftp.fail_gets_times['root/a.txt'] = 1
        simple = recording_sync(retries: 2)
        simple.pull_dir('root', base)

        assert_logged(simple, 'Retrying root/a.txt (attempt 1 of 2)')
      end
    end
  end

  def test_a_transfer_is_not_retried_by_default
    with_local_dir do |base|
      with_ftp({ 'root' => [file_entry('a.txt')] }) do |ftp|
        ftp.fail_gets_times['root/a.txt'] = 1

        assert_raises(Net::FTPPermError) { sync.pull_dir('root', base) }
        assert_empty ftp.downloaded
      end
    end
  end

  def test_retries_stop_at_the_budget_and_report_the_failure
    with_local_dir do |base|
      with_ftp({ 'root' => [file_entry('a.txt')] }) do |ftp|
        ftp.fail_gets['root/a.txt'] = nil
        simple = recording_sync(retries: 2)
        result = simple.pull_dir('root', base, skip_errors: true)

        assert_equal(2, simple.messages.count { |message| message.include?('Retrying root/a.txt') })
        assert_equal [0, 1], [result.transferred, result.failed]
      end
    end
  end

  def test_a_transient_upload_failure_is_retried
    with_local_dir do |base|
      write_file(base, 'a.txt', 'data')

      with_ftp('root' => []) do |ftp|
        ftp.fail_puts_times['root/a.txt'] = 1
        result = recording_sync(retries: 1).push_dir(base, 'root')

        assert_equal [1, 0], [result.transferred, result.failed]
        assert_equal 'data', ftp.contents['root/a.txt']
      end
    end
  end
end
