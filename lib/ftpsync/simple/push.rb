# frozen_string_literal: true

module FtpSync
  # Reopened so that each part of the client can live in its own file.
  class Simple
    # The push direction: creating the remote tree and storing files in it.
    module Push
      private

      def push_into(localpath, remotepath, session, &block)
        status, known_remote = remote_entries(remotepath, session)
        # :since protects a remote file by proving it is current. A listing that
        # failed or held entries nobody could interpret proves nothing, so this
        # directory is left alone rather than uploading over newer remote files.
        return if session.options[:since] && status && status != :ok

        local_names = {}
        Dir.children(localpath).sort.each do |basename|
          local_names[basename] = true
          push_entry(File.join(localpath, basename), join_remote(remotepath, basename),
                     known_remote[basename], session, &block)
        end
        prune_remote_directory(remotepath, known_remote, local_names, status, session)
      end

      # One local entry, dispatched by what it is. Symlinks and leftovers of
      # interrupted downloads are skipped instead of uploaded.
      def push_entry(local_child, remote_child, remote_entry, session, &)
        relative = relative_path(local_child, session.local_root)
        if local_child.end_with?(PART_SUFFIX)
          skip_entry(local_child, 'leftover partial download', session)
        elsif File.symlink?(local_child)
          skip_entry(local_child, 'symbolic link', session)
        elsif filtered_out?(relative, File.directory?(local_child), session)
          skip_entry(local_child, FILTERED_OUT, session)
        elsif File.directory?(local_child)
          ensure_remote_directory(remote_child, session)
          push_into(local_child, remote_child, session, &)
        elsif File.file?(local_child)
          upload(local_child, remote_child, remote_entry, session, &)
        else
          skip_entry(local_child, 'not a regular file or directory', session)
        end
      end

      # Walks +remotepath+ top-down, creating the directories that do not exist
      # yet. Absolute remote paths keep their leading slash.
      # A dry run makes no directory either, and says nothing about it: a real
      # run creates one only to hold a file, which the dry run already reports.
      def ensure_remote_directory(remotepath, session)
        return if dry_run?(session)

        current = remotepath.start_with?('/') ? '/' : ''
        remote_components(remotepath).each do |component|
          current = join_remote(current, component)
          create_remote_directory(current, session)
        end
      end

      # Creates +path+ on the server unless this sync already created or confirmed
      # it. A failed MKD cannot be taken at face value: it is also how a server
      # says the directory is already there, so only a listing can tell the two
      # apart.
      def create_remote_directory(path, session)
        return if session.known_directory?(path)

        @connection.mkdir(path)
        session.remember_directory(path)
        log "Created #{path} directory"
      rescue Net::FTPError => e
        explain_failed_mkdir(path, session, e)
      end

      def explain_failed_mkdir(path, session, error)
        if remote_directory?(path)
          session.remember_directory(path)
          return log("#{path} directory already exists")
        end
        raise unless session.options[:skip_errors]

        report_error(session.result, path, error)
      end

      # Whether +path+ is a directory, decided from the listing of its parent.
      # Only a non-directory entry with exactly that name proves the path is not
      # a directory; anything less is not enough to fail a push, because the
      # uploads into a really missing directory report the failure by
      # themselves. That keeps the quirk where a server answers LIST for a
      # missing path with an empty listing from turning into an error, and it
      # keeps a directory that happens to contain one entry of the same name
      # from looking like a file.
      def remote_directory?(path)
        entry = parent_entry(path)
        return true if entry.nil? || entry.dir?

        log "#{path} exists but is not a directory"
        false
      end

      def upload(local_file, remote_file, remote_entry, session)
        if skip_upload?(remote_file, remote_entry, local_file, session)
          session.result.skipped += 1
          return
        end

        return planned_transfer("upload #{local_file} => #{remote_file}", session) if dry_run?(session)

        log "#{local_file} => #{remote_file}"
        uploaded = transfer_file(remote_file, session) { store_file(local_file, remote_file) }
        yield(remote_file) if uploaded && block_given?
      end
    end
  end
end
