# frozen_string_literal: true

# Type checking of the library against the hand-written signatures in sig/.
#
# `rake steep` is not part of the default task (that stays test + RuboCop) and
# the Steep gems only install on Ruby >= 3.3; see the Gemfile and Rakefile.
target :lib do
  signature 'sig'

  # `lib/ftpsync.rb` requires fileutils; its RBS lives in the stdlib collection,
  # which Steep does not load by itself.
  library 'fileutils'

  check 'lib'

  # Two diagnostics cannot be satisfied from signatures alone. Everything else
  # keeps Steep's defaults, so real mismatches still fail the check.
  configure_code_diagnostics do |hash|
    # `Time.utc(*match.captures.map(&:to_i))` in `Simple::Pull#remote_time`
    # splats the six MDTM fields into a C function that RBS declares with fixed
    # arity; Steep rejects every splat into a method without a rest parameter,
    # and the type assertion that would satisfy it has to live in lib/.
    hash[Steep::Diagnostic::Ruby::UnexpectedPositionalArgument] = :information

    # The empty collection literals in lib/ (`options = {}`, the two listing
    # accumulators, `known_remote = ... : {}`) are locals, so the `# @type`
    # annotation Steep asks for can only be added in lib/.
    hash[Steep::Diagnostic::Ruby::UnannotatedEmptyCollection] = :information
  end
end
