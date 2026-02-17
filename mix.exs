defmodule BluetabPhoenix.MixProject do
  use Mix.Project

  def project do
    [
      app: :bluetab_phoenix,
      version: "26.2.17",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:igniter, "~> 0.7", optional: true},
      {:ash, "~> 3.0", optional: true},
      {:ash_authentication, "~> 4.0", optional: true},
      {:spark, "~> 2.0", optional: true}
    ]
  end
end
