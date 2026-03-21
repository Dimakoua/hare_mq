# HareMq

HareMq is an Elixir library for interacting with AMQP systems such as RabbitMQ. It provides supervised connection management, queue/exchange topology declaration, message publishing with deduplication, message consumption with automatic retry/dead-letter routing, and dynamic consumer scaling with an optional auto-scaler.

## Watch video tutorial

### Introduction
Learn the basics of HareMq and how it can simplify your interaction with AMQP systems.

[![Watch the video](https://img.youtube.com/vi/cohYx1E3d0s/hqdefault.jpg)](https://youtu.be/cohYx1E3d0s)

### Tutorial
Dive deeper into the features and capabilities of HareMq with our step-by-step tutorial.

[![Watch the video](https://img.youtube.com/vi/iajN-1gCr34/hqdefault.jpg)](https://youtu.be/iajN-1gCr34)

## Getting Started

Add the dependency to your `mix.exs`:

```elixir
defp deps do
  [
    {:hare_mq, "~> 1.3.0"}
  ]
end
```

HareMq starts `HareMq.Connection` and `HareMq.DedupCache` as part of its own OTP application. You do **not** need to start them manually — just add modules that `use HareMq.Publisher` or `use HareMq.Consumer` to your application's supervision tree.

---

## Configuration

```elixir
# config/config.exs
config :hare_mq, :amqp,
  url: "amqp://guest:guest@localhost:5672"

# Optional overrides for retry/delay behaviour
config :hare_mq, :configuration,
  delay_in_ms: 10_000,       # delay before first retry (default 10 000)
  retry_limit: 15,            # retries before dead-lettering (default 15)
  message_ttl: 31_449_600,    # queue message TTL in ms (default ~1 year)
  reconnect_interval_in_ms: 10_000  # AMQP reconnect delay (default 10 000)

# Optional auto-scaler defaults
config :hare_mq, :auto_scaler,
  min_consumers: 1,
  max_consumers: 20,
  messages_per_consumer: 10,
  check_interval: 5_000
```

> **Note:** `url` takes precedence over `host`. Credentials embedded in the URL (`amqp://user:pass@host`) will appear in crash reports. Use environment variables to keep them out of source control:
>
> ```elixir
> config :hare_mq, :amqp,
>   url: System.get_env("RABBITMQ_URL", "amqp://guest:guest@localhost")
> ```

All configuration values are read at runtime with `Application.get_env`, so changes via `Application.put_env` in tests take effect immediately without recompilation.

---

## Publisher

```elixir
defmodule MyApp.MessageProducer do
  use HareMq.Publisher,
    routing_key: "my_routing_key",
    exchange: "my_exchange"

  def send_message(message) do
    publish_message(message)
  end
end
```

`publish_message/1` accepts a `map` (JSON-encoded automatically) or a `binary`. It returns `:ok`, `{:error, :not_connected}`, or `{:error, {:encoding_failed, reason}}`.

The publisher declares its exchange as durable on connect, so messages are never silently dropped even if consumers have not started yet.

### Deduplication

```elixir
defmodule MyApp.MessageProducer do
  use HareMq.Publisher,
    routing_key: "my_routing_key",
    exchange: "my_exchange",
    unique: [
      period: :infinity,   # TTL in ms, or :infinity
      keys: [:project_id]  # deduplicate by these map keys; omit for full-message hashing
    ]

  def send_message(message) do
    publish_message(message)  # returns {:duplicate, :not_published} if already seen
  end
end
```

### Multi-vhost / named connections

```elixir
defmodule MyApp.ProducerVhostA do
  use HareMq.Publisher,
    routing_key: "rk",
    exchange: "ex",
    connection_name: {:global, :conn_vhost_a}
end
```

---

## Consumer

```elixir
defmodule MyApp.MessageConsumer do
  use HareMq.Consumer,
    queue_name: "my_queue",
    routing_key: "my_routing_key",
    exchange: "my_exchange"

  def consume(message) do
    IO.puts("Received: #{inspect(message)}")
    :ok  # return :ok | {:ok, any()} to ack, :error | {:error, any()} to retry
  end
end
```

Options for `use HareMq.Consumer`:

| Option | Default | Description |
|---|---|---|
| `queue_name` | **required** | Queue to consume from |
| `routing_key` | `queue_name` | AMQP routing key |
| `exchange` | `nil` | Exchange to bind to |
| `prefetch_count` | `1` | AMQP QoS prefetch count |
| `retry_limit` | config / `15` | Max retries before dead-lettering |
| `delay_in_ms` | config / `10_000` | Delay before retry |
| `delay_cascade_in_ms` | `[]` | List of per-retry delays, e.g. `[1_000, 5_000, 30_000]` |
| `connection_name` | `{:global, HareMq.Connection}` | Named connection for multi-vhost use |
| `stream` | `false` | `true` to consume a [RabbitMQ stream queue](#stream-consumer) |
| `stream_offset` | `"next"` | Where to start reading — see [Stream Consumer](#stream-consumer) |

---

## Stream Consumer

RabbitMQ [stream queues](https://www.rabbitmq.com/docs/streams) are persistent, append-only logs. Unlike classic queues, messages are never removed after consumption — every consumer maintains its own read offset, making streams ideal for event-sourcing, audit logs, and fan-out replay.

### Enabling stream mode

Set `stream: true` on either `HareMq.Consumer` or `HareMq.DynamicConsumer`:

```elixir
defmodule MyApp.EventLog do
  use HareMq.Consumer,
    queue_name: "domain.events",
    stream: true,
    stream_offset: "first"   # replay from the very beginning

  def consume(message) do
    IO.inspect(message, label: "event")
    :ok
  end
end
```

### `stream_offset` values

| Value | Behaviour |
|---|---|
| `"next"` | Only messages published **after** the consumer registers (default) |
| `"first"` | Replay from the oldest retained message |
| `"last"` | Start from the last stored chunk |
| `42` | Resume from a specific numeric offset |
| `%DateTime{}` | All messages published at or after the given UTC datetime |

### Behaviour differences vs classic queues

| | Classic queue | Stream queue |
|---|---|---|
| Queue type declared | classic / quorum | `x-queue-type: stream` |
| Delay queue created | yes | no |
| Dead-letter queue created | yes | no |
| `consume_fn` returns `:error` | retried via delay queue | **acked** (stream is immutable) |
| Multiple consumers | compete for messages | each gets a full copy at its own offset |

> **Prerequisite:** stream queues require the `rabbitmq_stream` plugin to be enabled on your broker (`rabbitmq-plugins enable rabbitmq_stream`).

---

## Dynamic Consumer

Starts a pool of `consumer_count` worker processes managed by a per-module `DynamicSupervisor`.

```elixir
defmodule MyApp.MessageConsumer do
  use HareMq.DynamicConsumer,
    queue_name: "my_queue",
    routing_key: "my_routing_key",
    exchange: "my_exchange",
    consumer_count: 10

  def consume(message) do
    IO.puts("Received: #{inspect(message)}")
    :ok
  end
end
```

### Auto-scaling

```elixir
defmodule MyApp.MessageConsumer do
  use HareMq.DynamicConsumer,
    queue_name: "my_queue",
    routing_key: "my_routing_key",
    exchange: "my_exchange",
    consumer_count: 2,
    auto_scaling: [
      min_consumers: 1,
      max_consumers: 20,
      messages_per_consumer: 100,  # scale up 1 consumer per N queued messages
      check_interval: 5_000        # check every 5 s
    ]

  def consume(message) do
    :ok
  end
end
```

Multiple `DynamicConsumer` modules can coexist in the same node — each gets its own named supervisor (`MyApp.MessageConsumer.Supervisor`) and its own auto-scaler (`MyApp.MessageConsumer.AutoScaler`).

---

## Usage in Application

```elixir
defmodule MyApp.Application do
  use Application

  def start(_type, _args) do
    children = [
      MyApp.MessageConsumer,
      MyApp.MessageProducer
    ]

    opts = [strategy: :one_for_one, name: MyApp.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

---

## Multi-vhost / Multiple Connections

Start additional named `Connection` (and optionally `DedupCache`) instances in your supervision tree, then reference them by name:

```elixir
children = [
  {HareMq.Connection, name: {:global, :conn_vhost_a}},
  {HareMq.Connection, name: {:global, :conn_vhost_b}},
  MyApp.ConsumerA,   # uses connection_name: {:global, :conn_vhost_a}
  MyApp.ConsumerB,   # uses connection_name: {:global, :conn_vhost_b}
]
```

---

## Modules

### HareMq.Connection

Manages the AMQP TCP connection. Reconnects automatically on failure or broker-initiated close. Accepts an optional `name:` keyword in `start_link/1` for multi-connection deployments.

### HareMq.Publisher

`use HareMq.Publisher, routing_key: ..., exchange: ...` injects a GenServer that connects to RabbitMQ, declares its exchange on connect, and exposes `publish_message/1`. Supports optional deduplication via `unique:` and a custom `connection_name:` / `dedup_cache_name:`.

### HareMq.Consumer

`use HareMq.Consumer, queue_name: ..., exchange: ...` injects a single-worker GenServer consumer with automatic retry and dead-letter routing.

### HareMq.DynamicConsumer

`use HareMq.DynamicConsumer, queue_name: ..., consumer_count: N` starts a pool of N workers under a per-module `HareMq.DynamicSupervisor`. Supports auto-scaling via `auto_scaling: [...]`.

### HareMq.DynamicSupervisor

Manages worker processes for a `DynamicConsumer` module. Each module gets a uniquely named supervisor so multiple modules can coexist. Exposes `add_consumer/2`, `remove_consumer/2`, `list_consumers/1`, and `supervisor_name/1`.

### HareMq.AutoScaler

Periodically samples queue depth and scales consumer count between `min_consumers` and `max_consumers`. Registered globally as `:"<ModuleName>.AutoScaler"` — unique per consumer module.

### HareMq.DedupCache

ETS-backed deduplication cache. `add/3` is synchronous (prevents race conditions with `is_dup?/2`). `is_dup?/2` reads directly from ETS without going through the GenServer. Expires entries via a periodic `:ets.select_delete` sweep. Accepts an optional `name:` for multi-tenant isolation.

### HareMq.RetryPublisher

Handles retry routing: publishes to delay queues (with optional cascade of per-retry delays) and moves messages to the dead-letter queue after `retry_limit` attempts. Short-circuits immediately when the dead queue is empty during `republish_dead_messages/2`.

### HareMq.Configuration

Struct + builder for per-queue runtime configuration. All default values (`delay_in_ms`, `retry_limit`, `message_ttl`) are read from `Application.get_env` at call time. Accepts keys in any order.

### HareMq.Exchange / HareMq.Queue

Low-level helpers for declaring and binding exchanges and queues. Exchange type defaults to `:direct` but can be overridden via `config :hare_mq, :exchange_type, :topic`. `HareMq.Queue.declare_stream_queue/1` declares a durable `x-queue-type: stream` queue — called automatically when `stream: true` is set on a consumer.

---

## Contributing and Testing

We welcome contributions. Please write tests for any new features or bug fixes using [ExUnit](https://hexdocs.pm/ex_unit/ExUnit.html). Test files live under `test/` and `lib/` (integration tests alongside source).

### Running Tests

```bash
mix test
```

Integration tests require a running RabbitMQ instance. Set `RABBITMQ_URL` (or `RABBITMQ_HOST`, `RABBITMQ_USER`, `RABBITMQ_PASSWORD`) to point at your broker:

```bash
RABBITMQ_URL=amqp://guest:guest@localhost mix test
```

## Rate Us

If you enjoy using HareMq, please consider giving us a star on GitHub! Your feedback and support are highly appreciated.
[GitHub](https://github.com/Dimakoua/hare_mq)


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
    {:hare_mq, "~> 1.3.0"}
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
