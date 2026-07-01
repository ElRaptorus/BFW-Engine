defmodule FeelNifSpike.MixProject do
  use Mix.Project

  def project do
    [
      app: :feel_nif_spike,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: false,
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:rustler, "~> 0.37.3", runtime: false}
    ]
  end
end
