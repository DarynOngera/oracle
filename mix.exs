defmodule SearchService.MixProject do
  use Mix.Project

  def project do
    [
      app: :search_service,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :runtime_tools],
      mod: {SearchService.Application, []}
    ]
  end

  defp deps do
    [
      {:phoenix, "~> 1.7"},
      {:bandit, "~> 1.0"},
      {:telemetry, "~> 1.0"},
      {:jason, "~> 1.0"}
    ]
  end
end
