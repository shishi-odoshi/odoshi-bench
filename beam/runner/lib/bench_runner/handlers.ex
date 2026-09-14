defmodule BenchRunner.Handlers do
  @moduledoc "Elixir twins of the bench ActiveJob classes."

  defmodule Noop do
    @moduledoc "Elixir twin of BenchNoopJob — a genuine no-op."
    @behaviour OdoshiBeam.Queue.Handler

    @impl true
    def perform(_args), do: :ok
  end
end
