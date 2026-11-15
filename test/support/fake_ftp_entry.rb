# frozen_string_literal: true

class FakeFtp
  # Minimal Net::FTP::List::Entry lookalike. +type+ mirrors the real gem:
  # :file, :dir, :symlink, :device, or nil for a line no parser understood.
  Entry = Struct.new(:name, :type, :mtime, :filesize) do
    def basename
      name
    end

    def dir?
      type == :dir
    end

    def file?
      type == :file
    end

    def symlink?
      type == :symlink
    end

    def device?
      type == :device
    end

    def unknown?
      !dir? && !file? && !symlink? && !device?
    end
  end
end
