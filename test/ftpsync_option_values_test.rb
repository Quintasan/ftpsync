# frozen_string_literal: true

require 'support/sync_test_case'

# The values a caller passes rather than the keys: a count, a timeout and the
# patterns that decide what a sync touches.
class FtpsyncOptionValuesTest < SyncTestCase
  def test_passes_the_data_connection_options_to_net_ftp
    with_local_dir do |base|
      with_ftp('root' => []) do |ftp|
        sync = FtpSync::Simple.new('ftp.example.com', 'user', 'pass',
                                   private_data_connection: false, ssl_handshake_timeout: 3)
        sync.pull_dir('root', base)

        options = ftp.new_args.last[1]

        assert_equal [false, 3], [options[:private_data_connection], options[:ssl_handshake_timeout]]
      end
    end
  end

  def test_rejects_a_retry_count_that_is_not_a_whole_number
    [1.5, -1, '2'].each do |retries|
      error = assert_raises(ArgumentError) { FtpSync::Simple.new('ftp.example.com', 'user', 'pass', retries: retries) }

      assert_match(/retries must be a non-negative Integer, got #{Regexp.escape(retries.inspect)}/, error.message)
    end
  end

  def test_rejects_a_negative_ssl_handshake_timeout
    error = assert_raises(ArgumentError) { FtpSync::Simple.new('ftp.example.com', 'user', 'pass', ssl_handshake_timeout: -1) }

    assert_match(/ssl_handshake_timeout must be a finite, non-negative Numeric/, error.message)
  end

  # A pattern that is not a string matches nothing, which would quietly sync
  # more than the caller asked for.
  def test_rejects_a_pattern_that_is_not_a_string
    with_local_dir do |base|
      with_ftp do
        [5, ['a', ''], ['a', nil]].each do |patterns|
          error = assert_raises(ArgumentError) { sync.pull_dir('root', base, exclude: patterns) }

          assert_match(/option :exclude must be a String or an Array of Strings/, error.message)
        end
      end
    end
  end
end
