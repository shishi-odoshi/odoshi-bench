# frozen_string_literal: true

# Bench HTTP surface. Enqueue runs inside the (possibly supervised) web
# child, so job traffic exercises the production ActiveJob -> Solid Queue
# path for every contender identically. GET-only on purpose: test harness.
class BenchController < ActionController::Base
  # GET /bench/enqueue?count=1&prefix=a1&queue=default&job=marker|noop
  def enqueue
    count  = Integer(params.fetch(:count, 1))
    prefix = params.require(:prefix)
    queue  = params.fetch(:queue, "default")
    klass  = params[:job] == "noop" ? BenchNoopJob : BenchMarkerJob
    now    = Process.clock_gettime(Process::CLOCK_REALTIME)

    jobs = count.times.map { |i| klass.set(queue: queue).perform_later("#{prefix}-#{now}-#{i}", now) }
    raise "enqueue returned false" unless jobs.all?

    render json: { enqueued: count, queue: queue, job: klass.name }
  end
end
