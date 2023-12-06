defmodule HareMq do
  @moduledoc """
  To use HareMq in your Elixir project, follow these steps:

  Install the required dependencies by adding them to your `mix.exs` file:

  ```elixir
  defp deps do
  [
    {:hare_mq, "~> 1.0.0"}
  ]
  end
  ```

  ### Publisher
  ```elixir
  defmodule MyApp.MessageProducer do
    use HareMq.Publisher,
      routing_key: "routing_key",
      exchange: "exchange"

    # Function to send a message to the message queue.
    def send_message(message) do
      # Publish the message using the HareMq.Publisher behavior.
      publish_message(message)
    end
  end
  ```

  ### Consumer
  ```elixir
  defmodule MyApp.MessageConsumer do
    use HareMq.Consumer,
      queue_name: "queue_name",
      routing_key: "routing_key",
      exchange: "exchange"

    # Function to process a received message.
    def consume(message) do
      # Log the beginning of the message processing.
      IO.puts("Processing message: \#{inspect(message)}")
    end
  end
  ```

  The consumer_count: 10 option indicates that it should run 10 worker processes.
  ### Dynamic Consumer
  ```elixir
  defmodule MyApp.MessageConsumer do
    use HareMq.DynamicConsumer,
      queue_name: "queue_name",
      routing_key: "routing_key",
      exchange: "exchange",
      consumer_count: 10

    # Function to process a received message.
    def consume(message) do
      # Log the beginning of the message processing.
      IO.puts("Processing message: \#{inspect(message)}")
    end
  end
  ```

  ### Usage in Application: MyApp.Application
  ```elixir
  defmodule MyApp.Application do
    use Application

    def start(_type, _args) do
      children = [
        # Start the message consumer.
        MyApp.MessageConsumer,

        # Start the message producer.
        MyApp.MessageProducer,
      ]

      opts = [strategy: :one_for_one, name: MyApp.Supervisor]
      Supervisor.start_link(children, opts)
    end
  end
  ```
  ## Configuration
  ```elixir
  config :hare_mq, :amqp,
    host: "localhost",
    url: "amqp://guest:guest@myhost:12345",
    user: "guest",
    password: "guest"

  config :hare_mq, :configuration,
    delay_in_ms: 10_000,
    retry_limit: 15,
    message_ttl: 31_449_600
  ```

  ## Rate Us:
  If you enjoy using HareMq, please consider giving us a star on GitHub! Your feedback and support are highly appreciated.
  [GitHub](https://github.com/Dimakoua/hare_mq)
  """
  use Application
  require Logger

  def start(_type, _args) do
    children = [
      HareMq.Connection,
      {Registry, keys: :unique, name: :consumers}
    ]

    opts = [strategy: :one_for_one, name: HareMq.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
