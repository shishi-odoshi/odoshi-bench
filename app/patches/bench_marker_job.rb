# frozen_string_literal: true

# The Track A lag probe: enqueued once per second by the harness enqueue
# loop; whichever worker executes it stamps the wall-clock instant it ran.
class BenchMarkerJob < ApplicationJob
  queue_as :default

  def perform(marker, enqueued_at_f = nil)
    JobMarker.create!(source: "ruby", marker: marker,
                      enqueued_at_f: enqueued_at_f,
                      performed_at_f: Process.clock_gettime(Process::CLOCK_REALTIME))
  end
end
