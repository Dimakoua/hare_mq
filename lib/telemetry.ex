defmodule HareMq.Telemetry do
  @moduledoc """
  Telemetry events emitted by HareMq.

  Attach handlers using `:telemetry.attach/4` or `:telemetry.attach_many/4`.

  ## Connection events

  ### `[:hare_mq, :connection, :connected]`

  Emitted when a broker connection is successfully opened.

  | Key | Value |
  |---|---|
  | measurements `:system_time` | `System.system_time()` |
  | metadata `:connection_name` | Registered process name (e.g. `{:global, HareMq.Connection}`) |
  | metadata `:host` | AMQP URL string |

  ### `[:hare_mq, :connection, :disconnected]`

  Emitted when a monitored connection process goes down unexpectedly.

  | Key | Value |
  |---|---|
  | measurements `:system_time` | `System.system_time()` |
  | metadata `:connection_name` | Registered process name |
  | metadata `:reason` | Exit reason from the `:DOWN` message |

  ### `[:hare_mq, :connection, :reconnecting]`

  Emitted whenever a reconnect attempt is scheduled (missing config or failed open).

  | Key | Value |
  |---|---|
  | measurements `:retry_delay_ms` | Milliseconds until next attempt |
  | metadata `:connection_name` | Registered process name |
  | metadata `:reason` | `:missing_config` or the connection error term |

  ## Consumer events

  ### `[:hare_mq, :consumer, :connected]`

  Emitted when a consumer channel is open and `Basic.consume` has been called.

  | Key | Value |
  |---|---|
  | measurements `:system_time` | `System.system_time()` |
  | metadata `:consumer` | Consumer module name |
  | metadata `:queue` | Queue name |
  | metadata `:exchange` | Exchange name |
  | metadata `:routing_key` | Routing key |
  | metadata `:stream` | `true` for stream consumers |

  ### `[:hare_mq, :consumer, :message, :start]`
  ### `[:hare_mq, :consumer, :message, :stop]`
  ### `[:hare_mq, :consumer, :message, :exception]`

  Emitted by `:telemetry.span/3` around the user-supplied `consume/1` callback.
  Start/stop/exception events follow the standard `:telemetry.span` contract.

  Start metadata:

  | Key | Value |
  |---|---|
  | metadata `:queue` | Queue name |
  | metadata `:exchange` | Exchange name |
  | metadata `:routing_key` | Routing key |

  Stop measurements additionally include `:duration` (native time units).
  Stop metadata additionally includes `:result` (`:ok` or `:error`).

  ## Publisher events

  ### `[:hare_mq, :publisher, :connected]`

  Emitted when a publisher channel is open and ready to publish.

  | Key | Value |
  |---|---|
  | measurements `:system_time` | `System.system_time()` |
  | metadata `:publisher` | Publisher module name |
  | metadata `:exchange` | Exchange name |
  | metadata `:routing_key` | Routing key |

  ### `[:hare_mq, :publisher, :message, :published]`

  Emitted after `AMQP.Basic.publish/5` returns `:ok`.

  | Key | Value |
  |---|---|
  | measurements `:system_time` | `System.system_time()` |
  | metadata `:publisher` | Publisher module name |
  | metadata `:exchange` | Exchange name |
  | metadata `:routing_key` | Routing key |

  ### `[:hare_mq, :publisher, :message, :not_connected]`

  Emitted when `publish_message/1` is called but no channel is available.

  | Key | Value |
  |---|---|
  | measurements `:system_time` | `System.system_time()` |
  | metadata `:publisher` | Publisher module name |
  | metadata `:exchange` | Exchange name |
  | metadata `:routing_key` | Routing key |

  ## Retry publisher events

  ### `[:hare_mq, :retry_publisher, :message, :retried]`

  Emitted when a failed message is sent to a delay queue.

  | Key | Value |
  |---|---|
  | measurements `:retry_count` | Current retry attempt number |
  | measurements `:system_time` | `System.system_time()` |
  | metadata `:queue` | Main queue name |
  | metadata `:delay_queue` | Target delay queue name |

  ### `[:hare_mq, :retry_publisher, :message, :dead_lettered]`

  Emitted when a message has exceeded `retry_limit` and is sent to the dead-letter queue.

  | Key | Value |
  |---|---|
  | measurements `:retry_count` | Final retry count |
  | measurements `:system_time` | `System.system_time()` |
  | metadata `:queue` | Main queue name |
  | metadata `:dead_queue` | Dead-letter queue name |

  ## Example: attaching a simple logger handler

      :telemetry.attach_many(
        "hare-mq-logger",
        [
          [:hare_mq, :connection, :connected],
          [:hare_mq, :connection, :disconnected],
          [:hare_mq, :consumer, :message, :stop],
          [:hare_mq, :retry_publisher, :message, :dead_lettered]
        ],
        fn event, measurements, metadata, _config ->
          require Logger
          Logger.info("[telemetry] \#{inspect(event)} \#{inspect(measurements)} \#{inspect(metadata)}")
        end,
        nil
      )
  """
end
