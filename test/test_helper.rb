# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'ftpsync'

# Object#stub comes from minitest/mock. It must be required explicitly:
# minitest 6 drops it, and relying on it arriving with minitest/autorun would
# break this suite on upgrade.
require 'minitest/mock'
require 'minitest/autorun'
