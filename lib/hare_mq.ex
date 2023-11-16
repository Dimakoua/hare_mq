defmodule HareMq do
  @moduledoc """
  To use HareMq in your Elixir project, follow these steps:

  Install the required dependencies by adding them to your `mix.exs` file:

  ```elixir
  defp deps do
  [
    {:hare_mq, "~> 0.1.2"}
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
  """
  use Application
  require Logger

  def start(_type, _args) do
    children = [
      HareMq.Connection
    ]

    opts = [strategy: :one_for_one, name: HareMq.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
