# frozen_string_literal: true

class CreateJobMarkers < ActiveRecord::Migration[8.0]
  def change
    create_table :job_markers do |t|
      t.string :source, null: false            # "ruby" | "beam"
      t.string :marker, null: false
      t.float :enqueued_at_f                   # epoch float, set at enqueue
      t.float :performed_at_f, null: false     # epoch float, set at execution
      t.datetime :created_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
    end
    add_index :job_markers, :marker
    add_index :job_markers, :performed_at_f
  end
end
