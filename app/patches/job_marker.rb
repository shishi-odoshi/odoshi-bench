# frozen_string_literal: true

# One row per executed marker job. `performed_at_f` (epoch float, written by
# the executing process) is the measurement primitive: time-to-jobs-flowing
# after a kill = min(performed_at_f > kill_ts) - kill_ts, in plain SQL.
# `source` records which runtime ran it ("ruby" | "beam").
class JobMarker < ApplicationRecord
end
