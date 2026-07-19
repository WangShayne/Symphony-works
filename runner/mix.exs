defmodule SymphonyRunner.MixProject do
  use Mix.Project

  def project do
    [
      app: :symphony_runner,
      version: "0.0.1",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      test_coverage: [
        summary: [threshold: 100]
      ],
      dialyzer: [
        plt_add_apps: [:mix]
      ],
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {SymphonyRunner.Application, []}
    ]
  end

  defp deps do
    [
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false}
    ]
  end
end
