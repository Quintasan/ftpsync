# frozen_string_literal: true

module FtpSync
  # Reopened so that each part of the client can live in its own file.
  class Simple
    # The rules for what a caller may pass: which keys an entry point takes,
    # which options are flags, and which numbers have to be non-negative. None
    # of it touches a connection, so a typo is refused before anything opens.
    module Options
      private

      # A tolerance or timeout that is not a finite, non-negative number would
      # only fail later, in the upload decision or inside Net::FTP, and outside
      # :skip_errors, so it is rejected while the option is still in the caller's
      # hands. An infinite tolerance would make every file look current and turn
      # :since into a no-op.
      def validate_non_negative_number(name, value)
        return if value.is_a?(Numeric) && value.real? && value >= 0 && value.finite?

        raise ArgumentError, "#{name} must be a finite, non-negative Numeric, got #{value.inspect}"
      end

      # A non-numeric tolerance is caught by the same check; this only names the
      # option the way its readers know it.
      def validate_mtime_tolerance(value)
        validate_non_negative_number('mtime_tolerance', value)
      end

      # A retry count is a number of re-issues, so a string or a fraction of one
      # means the caller expected something else. Rejecting it here is clearer
      # than retrying forever or never.
      def validate_retries(value)
        return if value.is_a?(Integer) && value >= 0

        raise ArgumentError, "retries must be a non-negative Integer, got #{value.inspect}"
      end

      # Rejects option keys and flag values the library does not understand, so
      # that a typo such as +ssll:+ cannot silently leave the connection
      # unencrypted, and returns the hash with nil read as an empty one.
      def validate_options(options, allowed, context)
        options = {} if options.nil?
        raise ArgumentError, "#{context} options must be a Hash" unless options.is_a?(Hash)

        options.each_key do |key|
          raise ArgumentError, "Unknown #{context} option: #{key.inspect}" unless allowed.include?(key)

          validate_option_value(key, options[key], context)
        end
        options
      end

      # nil is accepted and reads as false. :ssl may also be a hash of OpenSSL
      # options; a truthy value such as "no" would enable TLS with default
      # options, which is not what it says. :exclude and :include take one glob or
      # a list of them, and nothing else: a pattern that is not a string would
      # silently match nothing.
      def validate_option_value(key, value, context)
        case key
        when :ssl then validate_ssl_option(value, context)
        when :exclude, :include then validate_patterns(key, value, context)
        else validate_boolean_option(key, value, context) if BOOLEAN_OPTIONS.include?(key)
        end
      end

      def validate_boolean_option(key, value, context)
        return if [true, false, nil].include?(value)

        raise ArgumentError, "#{context} option #{key.inspect} must be true or false, got #{value.inspect}"
      end

      def validate_ssl_option(value, context)
        return if [true, false, nil].include?(value) || value.is_a?(Hash)

        raise ArgumentError, "#{context} option :ssl must be true, false or a Hash, got #{value.inspect}"
      end

      def validate_patterns(key, value, context)
        patterns = value.is_a?(String) ? [value] : value
        return if patterns.is_a?(Array) && patterns.all? { |pattern| pattern.is_a?(String) && !pattern.empty? }

        raise ArgumentError,
              "#{context} option #{key.inspect} must be a String or an Array of Strings, got #{value.inspect}"
      end

      # An empty remote path is the login directory, which the rest of the path
      # handling already expresses: no component to create and relative names.
      def validate_remote_path(path)
        return if path.is_a?(String)

        raise ArgumentError, "remote path must be a String, got #{path.inspect}"
      end

      def validate_local_path(path)
        return if path.is_a?(String) && !path.empty?

        raise ArgumentError, "local path must be a non-empty String, got #{path.inspect}"
      end
    end
  end
end
