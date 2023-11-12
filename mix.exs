defmodule HareMq.MixProject do
  use Mix.Project

  def project do
    [
      app: :hare_mq,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      package: [
        licenses: ["MIT"],
        links: %{"GitHub" => "https://github.com/Dimakoua/hare_mq"}
      ],
      description:
        "Elixir messaging library using RabbitMQ, providing easy-to-use modules for message publishing, consuming, and retry handling"
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {HareMq, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:amqp, "~> 3.3"},
      {:jason, "~> 1.4"}
      # {:dep_from_hexpm, "~> 0.3.0"},
      # {:dep_from_git, git: "https://github.com/elixir-lang/my_dep.git", tag: "0.1.0"}
    ]
  end
end
