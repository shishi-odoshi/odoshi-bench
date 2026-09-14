defmodule BenchRunner.Application do
  @moduledoc """
  Track D worker: `OdoshiBeam.Queue` claiming the designated "elixir" queue
  of the app's Solid Queue database, with a handler registered for the bench
  job class. Concurrency mirrors the Ruby worker's queue.yml (3 threads):
  see the Track D caveats in the README — same job, different runtime,
  configs matched where a knob exists on both sides.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {OdoshiBeam.Queue,
       db: db(System.get_env("QUEUE_DB", "app_production_queue")),
       queues: ["elixir"],
       handlers: %{
         "BenchNoopJob" => BenchRunner.Handlers.Noop
       }}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: BenchRunner.Supervisor)
  end

  defp db(database) do
    [
      hostname: System.get_env("DB_HOST", "postgres"),
      username: System.get_env("DB_USER", "postgres"),
      password: System.get_env("DB_PASSWORD", "postgres"),
      database: database
    ]
  end
end
