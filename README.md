# HareMq

HareMq is an Elixir library for interacting with AMQP (Advanced Message Queuing Protocol) systems, such as RabbitMQ. It provides modules for configuring connections, declaring queues and exchanges, publishing messages, and handling message retries.

## Watch video tutorial

### Introduction
Learn the basics of HareMq and how it can simplify your interaction with AMQP systems.

[![Watch the video](https://img.youtube.com/vi/cohYx1E3d0s/hqdefault.jpg)](https://youtu.be/cohYx1E3d0s)

### Tutorial
Dive deeper into the features and capabilities of HareMq with our step-by-step tutorial.

[![Watch the video](https://img.youtube.com/vi/iajN-1gCr34/hqdefault.jpg)](https://youtu.be/iajN-1gCr34)

## Getting Started

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
    IO.puts("Processing message: #{inspect(message)}")
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
    IO.puts("Processing message: #{inspect(message)}")
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
    IO.puts("Processing message: #{inspect(message)}")
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

## Modules

### HareMq.Configuration

The `HareMq.Configuration` module defines a configuration structure for AMQP connections and queues. It provides a function to retrieve queue configurations.

### HareMq.Connection

The `HareMq.Connection` module manages the connection to the AMQP server using the GenServer behavior. It handles connection monitoring and reconnects in case of failures.

### HareMq.Queue

The `HareMq.Queue` module provides functions for declaring and configuring queues, including binding, declaring regular, delayed, and dead-letter queues.

### HareMq.Exchange

The `HareMq.Exchange` module offers functions for declaring and binding exchanges, allowing users to set up routing between queues.

### HareMq.Publisher

The `HareMq.Publisher` module defines a behavior for publishing messages to an AMQP system. It includes connection handling, channel retrieval, and message publishing with a retry mechanism.

### HareMq.RetryPublisher

The `HareMq.RetryPublisher` module handles the republishing of messages with retry logic. It tracks the retry count in message headers and decides whether to republish to a delay queue or a dead letter queue.

### HareMq.Consumer

The `HareMq.Consumer` module defines a behavior for consuming messages from an AMQP system. It includes connection setup, channel declaration, and message consumption with error handling and retry mechanisms.

## Contributing and Testing

We welcome contributions to improve and expand this project. If you're interested in contributing, please follow these steps:

### Writing Tests

To ensure the stability and reliability of the project, we strongly encourage writing tests for any new features or bug fixes. Tests are crucial for maintaining the quality of the codebase and catching issues early in the development process.

We use [ExUnit](https://hexdocs.pm/ex_unit/ExUnit.html) for testing in Elixir. You can find the test files in the `test/` directory. Follow the existing test patterns and write new tests to cover the functionality you're adding or modifying.

### Running Tests

To run the tests, execute the following command in your terminal:

```bash
mix test
