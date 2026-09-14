defmodule BenchRunner.MixProject do
  use Mix.Project

  def project do
    [
      app: :bench_runner,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {BenchRunner.Application, []}
    ]
  end

  defp deps do
    [
      # The Elixir sidecar under test — its published main, same artifact
      # policy as the Ruby side (odoshi from RubyGems).
      {:odoshi_beam, git: "https://github.com/shishi-odoshi/beam.git", branch: "main"}
    ]
  end
end
