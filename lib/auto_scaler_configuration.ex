defmodule HareMq.AutoScalerConfiguration do
  @moduledoc """
  Configuration module for HareMq AutoScaler.

  This module provides functions for configuring the auto-scaler component of HareMq.
  """

  @doc """
  Structure representing the configuration for the auto-scaler.

  ## Fields

  - `:queue_name`: The name of the queue to monitor.
  - `:consumer_worker`: The module to use for the consumer worker.
  - `:module_name`:  The module whic use consumer_worker module.
  - `:initial_consumer_count`: The initial number of consumers to start.
  - `:min_consumers`: The minimum number of consumers to maintain.
  - `:max_consumers`: The maximum number of consumers to maintain.
  - `:messages_per_consumer`: The number of messages per consumer.
  - `:check_interval`: The interval (in milliseconds) at which to check the queue length.

  ## Examples

      config = %AutoScalerConfiguration{
        queue_name: "my_queue",
        consumer_worker: HareMq.Consumer,
        module_name: MyApp.Consumer,
        initial_consumer_count: 1,
        min_consumers: 1,
        max_consumers: 20,
        messages_per_consumer: 100,
        check_interval: 5_000
      }
  """
  defstruct [
    :queue_name,
    :consumer_worker,
    :module_name,
    :consume,
    :initial_consumer_count,
    :min_consumers,
    :max_consumers,
    :messages_per_consumer,
    :check_interval,
    :consumer_opts
  ]

  @default_check_interval Application.compile_env(:hare_mq, :auto_scaler)[:check_interval] ||
                            5_000
  @default_min_consumers Application.compile_env(:hare_mq, :auto_scaler)[:min_consumers] || 1
  @default_max_consumers Application.compile_env(:hare_mq, :auto_scaler)[:max_consumers] || 20
  @default_messages_per_consumer Application.compile_env(:hare_mq, :auto_scaler)[
                                   :messages_per_consumer
                                 ] || 10

  @doc """
  Get the configuration for the auto-scaler.

  ## Examples

      config = get_auto_scaler_configuration(
        queue_name: "my_queue",
        consumer_worker: MyApp.Consumer,
        consume: MyApp.Consumer
      )
  """
  def get_auto_scaler_configuration(
        queue_name: queue_name,
        consumer_worker: consumer_worker,
        module_name: module_name,
        consumer_count: initial_consumer_count,
        consume: consume,
        auto_scaling: auto_scaling,
        consumer_opts: consumer_opts
      ) do
    %HareMq.AutoScalerConfiguration{
      queue_name: queue_name,
      consumer_worker: consumer_worker,
      module_name: module_name,
      consume: consume,
      initial_consumer_count: initial_consumer_count,
      consumer_opts: consumer_opts,
      min_consumers: auto_scaling[:min_consumers] || @default_min_consumers,
      max_consumers: auto_scaling[:max_consumers] || @default_max_consumers,
      messages_per_consumer:
        auto_scaling[:messages_per_consumer] || @default_messages_per_consumer,
      check_interval: auto_scaling[:check_interval] || @default_check_interval
    }
  end
end
