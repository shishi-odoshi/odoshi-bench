# frozen_string_literal: true

# Track D payload: a genuine no-op, so claim/finish bookkeeping is the whole
# cost. The beam twin is BenchRunner.Handlers.Noop (beam/runner) registered
# under this class name.
class BenchNoopJob < ApplicationJob
  queue_as :default

  def perform(*)
  end
end
