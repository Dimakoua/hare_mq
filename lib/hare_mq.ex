defmodule HareMq do
  @moduledoc """
  To use HareMq in your Elixir project, follow these steps:

  Install the required dependencies by adding them to your `mix.exs` file:

  ```elixir
  defp deps do
  [
    {:hare_mq, "~> 1.2.0"}
  ]
  end
  ```

  ### Publisher

  The `MyApp.MessageProducer` module is responsible for publishing messages to a message queue using the `HareMq.Publisher` behavior. This module provides an interface for sending messages with specified routing and exchange settings. It also supports deduplication based on specific keys.

  The `MyApp.MessageProducer` module is configured with the following options:

  - **`routing_key`**: Specifies the routing key used to route messages to the appropriate queue. In this example, the routing key is set to `"routing_key"`.

  - **`exchange`**: Defines the exchange to which messages will be published. In this example, the exchange is set to `"exchange"`.

  - **`unique`**: This configuration option sets up deduplication rules:
  - **`period`**: Defines the time period for deduplication in ms. In this example, it is set to `:infinity`, meaning that messages are considered unique indefinitely based on the specified keys.
  - **`keys`**: A list of keys used to determine message uniqueness. If the message is a string, deduplication is managed by default behavior and you do not need to specify `keys`. If provided, deduplication is based on the specified keys. In the example, deduplication is based on the `:project_id` key.


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

  ```elixir
  defmodule MyApp.MessageProducer do
  use HareMq.Publisher,
    routing_key: "routing_key",
    exchange: "exchange",
    unique: [
      period: :infinity,
      keys: [:project_id]
    ]

  # Function to send a message to the message queue.
  def send_message(message) do
    # Publish the message using the HareMq.Publisher behavior.
    publish_message(message)
  end
  end
  ```


  ### Consumer

  The `MyApp.MessageConsumer` module is designed to consume messages from a message queue using the `HareMq.Consumer` behavior. This module provides the functionality to receive and process messages with specific routing and exchange settings.

  The `MyApp.MessageConsumer` module is configured with the following options:

  - **`queue_name`**: Specifies the name of the queue from which messages will be consumed. In this example, the queue name is set to `"queue_name"`.

  - **`routing_key`**: Defines the routing key used to filter messages. In this example, the routing key is set to `"routing_key"`.

  - **`exchange`**: Defines the exchange from which messages will be consumed. In this example, the exchange is set to `"exchange"`.

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

  ### Dynamic Consumer

  The `MyApp.MessageConsumer` module is designed to consume messages from a message queue using the `HareMq.DynamicConsumer` behavior. This module provides the functionality to receive and process messages with dynamic scaling based on the specified number of worker processes.

  The `MyApp.MessageConsumer` module is configured with the following options:

  - **`queue_name`**: Specifies the name of the queue from which messages will be consumed. In this example, the queue name is set to `"queue_name"`.

  - **`routing_key`**: Defines the routing key used to filter messages. In this example, the routing key is set to `"routing_key"`.

  - **`exchange`**: Defines the exchange from which messages will be consumed. In this example, the exchange is set to `"exchange"`.

  - **`consumer_count`**: Indicates the number of worker processes that should be used to handle incoming messages. In this example, `consumer_count` is set to `10`, which means that 10 worker processes will be run to consume and process messages concurrently.

  - **`auto_scaling`**: Allows configuration for dynamic scaling of consumers:
  - **`min_consumers`**: The minimum number of consumers to maintain.
  - **`max_consumers`**: The maximum number of consumers to maintain.
  - **`messages_per_consumer`**: The number of messages each consumer should handle before scaling adjustments are considered.
  - **`check_interval`**: The interval (in milliseconds) at which to check the queue length and adjust the number of consumers accordingly.

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

  ### MessageConsumer with auto scaling
  ```elixir
  defmodule MyApp.MessageConsumer do
  use HareMq.DynamicConsumer,
    queue_name: "queue_name",
    routing_key: "routing_key",
    exchange: "exchange",
    consumer_count: 10,
    auto_scaling: [
      min_consumers: 1,
      max_consumers: 20,
      messages_per_consumer: 100,
      check_interval: 5_000
    ]

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
  config :hare_mq,
  :amqp,
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
      HareMq.DedupCache
    ]

    opts = [strategy: :one_for_one, name: HareMq.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
