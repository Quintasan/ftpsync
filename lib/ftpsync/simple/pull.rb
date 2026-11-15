# frozen_string_literal: true

module FtpSync
  # Reopened so that each part of the client can live in its own file.
  class Simple
    # The pull direction: what a listed tree turns into locally. The two
    # directions live in their own modules so each reads in one place, while
    # the connection, the error policy and the transfer guard stay shared.
    module Pull
      # Listing types in words, for the skip log. An entry whose type nobody could
      # determine is reported as a failure before it gets here, so the fallback is
      # there for a type added to Entry later rather than for a real listing.
      TYPE_NAMES = { symlink: 'symbolic link', device: 'device' }.freeze

      private

      def pull_into(remotepath, localpath, session, &block)
        listing = scan_directory(remotepath, localpath, session)
        # Nothing local exists until the listing succeeded, so a wrong remote path
        # cannot leave an empty local tree behind.
        return unless listing

        ensure_local_directory(localpath, session)
        listing.directories.each do |remote_dir, local_dir|
          pull_into(remote_dir, local_dir, session, &block)
        end
        listing.files.each do |remote_file, local_file, entry, remote_mtime|
          download(remote_file, local_file, entry, remote_mtime, session, &block)
        end
        prune_local_directory(localpath, listing.names, listing.status, session)
      end

      # A dry run makes no directory either, and says nothing about it: a real
      # run creates one only to hold a file, which the dry run already reports.
      def ensure_local_directory(localpath, session)
        return if File.directory?(localpath) || dry_run?(session)

        FileUtils.mkpath(localpath)
        log "Creating #{localpath} directory"
      end

      # Turns one remote directory into the subdirectories to recurse into, the
      # files to download, the names the source has and the listing status; nil
      # when the listing itself failed.
      def scan_directory(remotepath, localpath, session)
        listing = Listing.new([], [], {}, :ok)
        status = each_entry(remotepath, session) do |entry|
          listing.names[entry.basename] = true
          scan_entry(listing, remotepath, localpath, entry, session)
        end
        listing.status = status
        listing unless status == :failed
      end

      # Sorts one entry into the listing: directories to recurse into, files to
      # fetch unless they are current, and everything else skipped and logged.
      def scan_entry(listing, remotepath, localpath, entry, session)
        remote_child = join_remote(remotepath, entry.basename)
        local_child = File.join(localpath, entry.basename)
        return if skip_filtered_entry?(remote_child, entry, session)

        if entry.dir?
          listing.directories << [remote_child, local_child]
        elsif entry.file?
          # The remote time the file was judged by is kept with it, so the
          # download stamps the local copy with exactly that time and the next
          # run compares equal.
          remote_mtime, source = pull_time(remote_child, entry, session)
          if pull_file?(local_child, entry, remote_mtime, source, session)
            listing.files << [remote_child, local_child, entry, remote_mtime]
          end
        else
          skip_entry(remote_child, entry_type(entry), session)
        end
      end

      # The remote time a pull decides with, and where it came from. A plain pull
      # lets the remote copy win unconditionally, so it asks for no times.
      def pull_time(remote_file, entry, session)
        return entry_time(entry) unless session.options[:since] || session.options[:protect_local]

        remote_time(remote_file, entry)
      end

      def entry_type(entry)
        TYPE_NAMES.fetch(entry.type, 'unknown type')
      end

      # Whether a listed file is downloaded at all. :since skips a file that is
      # already current. A local file newer than the remote one is still replaced
      # by default, but never quietly: that is the one destructive thing a pull
      # does, and :protect_local turns it into a skip.
      def pull_file?(local_path, entry, remote_mtime, source, session)
        if skip_file?(local_path, entry, remote_mtime, source, session)
          session.result.skipped += 1
          return false
        end
        return keep_local_without_remote_time?(local_path, session) if remote_mtime.nil?
        return true unless newer_local?(local_path, remote_mtime)

        if session.options[:protect_local]
          skip_entry(local_path, 'newer than the remote copy', session)
          return false
        end

        log "Overwriting #{local_path}, which is newer than the remote copy"
        true
      end

      # Without a remote timestamp nothing proves the remote copy is the newer
      # one, so :protect_local keeps the local file instead of guessing.
      def keep_local_without_remote_time?(local_path, session)
        return true unless session.options[:protect_local]

        skip_entry(local_path, 'remote modification time unknown', session)
        false
      end

      # A file is up to date when it has the same size locally and the remote
      # copy is not newer. Downloaded files keep the remote time, so an
      # unchanged file compares equal on the next run.
      def skip_file?(local_path, entry, remote_mtime, source, session)
        return false unless session.options[:since]
        return false unless File.file?(local_path)
        return false unless entry.filesize == File.size(local_path)
        # Without a usable remote time nothing can be proven current.
        return false if remote_mtime.nil?

        # A LIST stamp is minute-aligned already; a wider grace would hide a
        # remote change for a whole minute. MDTM keeps the clock jitter allowance.
        File.mtime(local_path) >= remote_mtime - (source == :list ? 0 : MDTM_TOLERANCE)
      end

      def newer_local?(local_path, remote_mtime)
        File.file?(local_path) && File.mtime(local_path) > remote_mtime
      end

      def download(remote_file, local_file, entry, remote_mtime, session)
        partial = "#{local_file}#{PART_SUFFIX}"
        return planned_transfer("download #{remote_file} => #{local_file}", session) if dry_run?(session)

        log "#{remote_file} => #{local_file}"
        completed = transfer_file(remote_file, session) do
          @connection.getbinaryfile(remote_file, partial)
          warn_size_mismatch(remote_file, partial, entry)
          File.utime(remote_mtime, remote_mtime, partial) if remote_mtime
          FileUtils.mv(partial, local_file)
        end
        yield(local_file) if completed && block_given?
      ensure
        # The rename consumed the partial; any other outcome is a failure that
        # must not leave one behind.
        FileUtils.rm_f(partial)
      end

      # LIST's size and the transfer's own count can disagree; the file is kept
      # because the entry is only metadata, but the difference is worth saying.
      def warn_size_mismatch(remote_file, partial, entry)
        expected = entry.filesize.to_i
        actual = File.size(partial)
        return if expected <= 0 || expected == actual

        log "Size mismatch for #{remote_file}: expected #{expected} bytes, received #{actual}"
      end
    end
  end
end
