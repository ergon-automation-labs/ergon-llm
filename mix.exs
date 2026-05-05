defmodule BotArmyLlm.MixProject do
  use Mix.Project

  def project do
    [
      app: :bot_army_llm,
      version: "0.6.74",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: [
        llm_proxy: [
          applications: [bot_army_llm: :permanent]
        ]
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {BotArmyLlm.Application, []}
    ]
  end

  defp deps do
    [
      {:bot_army_core, path: "../bot_army_core"},
      {:bot_army_runtime, path: "../bot_army_runtime"},
      {:ecto_sql, "~> 3.10"},
      {:postgrex, "~> 0.17"},
      {:pgvector, "~> 0.2"},
      {:jason, "~> 1.4"},
      {:logger_json, "~> 5.1"},
      {:elixir_uuid, "~> 1.2"},
      {:finch, "~> 0.18"},
      {:bandit, "~> 1.0"},
      {:plug, "~> 1.14"},

      # Development/Test
      {:ex_doc, "~> 0.30", only: :dev},
      {:credo, "~> 1.7", only: [:dev, :test]},
      {:dialyxir, "~> 1.4", only: [:dev, :test]},
      {:excoveralls, "~> 0.17", only: :test}
    ]
  end
end
