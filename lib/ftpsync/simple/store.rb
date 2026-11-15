# frozen_string_literal: true

module FtpSync
  # Reopened so that each part of the client can live in its own file.
  class Simple
    # How one file is written to the server. STOR truncates the remote file
    # before the data arrives, so an upload that fails halfway destroys the copy
    # that was there; unless :atomic_uploads is off, the data goes to a side file
    # that is renamed into place instead. A server without RNFR/RNTO is detected
    # once and then written to in place.
    module Store
      private

      # Uploads +local_file+ to +remote_file+. STOR truncates the remote file
      # before the data arrives, so an upload that fails halfway destroys the copy
      # that was there; unless :atomic_uploads is off, the data goes to a side file
      # that is renamed into place instead.
      def store_file(local_file, remote_file)
        return store_in_place(local_file, remote_file) unless @atomic_uploads && @rename_supported

        temporary = "#{remote_file}#{PART_SUFFIX}"
        store_side_file(local_file, temporary)
        error = rename_side_file(temporary, remote_file)
        store_without_rename(local_file, remote_file, error) if error
      end

      # STOR is the upload itself, not the probe: a failure here is a failed
      # upload, so the side file is discarded and the error propagates as it is.
      def store_side_file(local_file, temporary)
        @connection.putbinaryfile(local_file, temporary)
      rescue Net::FTPError
        discard_remote_file(temporary)
        raise
      end

      # Returns the rejection when the server has no RNFR/RNTO, and re-raises
      # every other rename failure. Only this call is evidence about rename
      # support, because a 500 from STOR would otherwise turn atomic uploads off
      # and retry the file in place, where a failure truncates.
      def rename_side_file(temporary, remote_file)
        @connection.rename(temporary, remote_file)
        nil
      rescue Net::FTPError => e
        discard_remote_file(temporary)
        raise unless RENAME_UNSUPPORTED.match?(e.message)

        e
      end

      # A server without RNFR/RNTO would reject every upload this way, so the
      # verdict is remembered for the connection and the fallback is logged once.
      def store_without_rename(local_file, remote_file, error)
        @rename_supported = false
        log "Server cannot rename files (#{error.message}); uploading in place instead"
        store_in_place(local_file, remote_file)
      end

      def store_in_place(local_file, remote_file)
        @connection.putbinaryfile(local_file, remote_file)
      end

      # Cleanup of the side file must not replace the failure being reported.
      def discard_remote_file(path)
        @connection.delete(path)
      rescue Net::FTPError => e
        log "Could not remove #{path}: #{e.message}"
      end
    end
  end
end
