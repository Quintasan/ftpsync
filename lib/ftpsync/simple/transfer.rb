# frozen_string_literal: true

module FtpSync
  # Reopened so that each part of the client can live in its own file.
  class Simple
    # The bookkeeping around one transfer: the retry loop, the tally, and
    # whether the run only reports. Both directions share it, so a retry or a
    # dry run behaves the same way in each.
    module Transfer
      private

      # A dry run reads both sides and reports what a real run would have done,
      # so its Result can be compared with one.
      def dry_run?(session)
        session.options[:dry_run]
      end

      # Counts a transfer a dry run did not perform, and says what it would do.
      def planned_transfer(action, session)
        log "Would #{action}"
        session.result.transferred += 1
      end

      def transfer_file(path, session, &)
        retrying(path, &)
        session.result.transferred += 1
        true
      rescue Net::FTPError => e
        raise unless session.options[:skip_errors]

        report_error(session.result, path, e)
        false
      end

      # Re-issues a failed transfer up to :retries times on the same connection. A
      # transfer that has to resume from a dead socket fails again and is reported
      # like any other failure: reconnecting in the middle of a sync is a
      # different decision, and one the caller can make by retrying the sync.
      def retrying(path, &)
        attempt = 0
        begin
          yield
        rescue Net::FTPError => e
          attempt += 1
          raise if attempt > @retries

          log "Retrying #{path} (attempt #{attempt} of #{@retries}): #{e.message}"
          retry
        end
      end
    end
  end
end
