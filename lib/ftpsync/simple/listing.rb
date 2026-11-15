# frozen_string_literal: true

module FtpSync
  # Reopened so that each part of the client can live in its own file.
  class Simple
    # What one remote directory listing turned into. +names+ is every name the
    # source reports, which is the keep-set when pruning; +status+ says how
    # completely the listing could be interpreted, and therefore whether pruning
    # is allowed at all.
    Listing = Struct.new(:directories, :files, :names, :status)
  end
end
