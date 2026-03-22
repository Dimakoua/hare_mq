defmodule HareMq.AutoScaler do
  use GenServer
  require Logger
  alias HareMq.AutoScalerConfiguration

  @moduledoc """
  A GenServer that automatically scales the number of consumers based on the
  number of messages in the RabbitMQ queue.
  """

  # How long to wait for a worker's :get_config call before trying the next one.
  # Configurable via `config :hare_mq, :auto_scaler, worker_timeout_ms: 5_000`.
  defp worker_call_timeout do
    (Application.get_env(:hare_mq, :auto_scaler) || [])[:worker_timeout_ms] || 5_000
  end

  def start_link(%HareMq.AutoScalerConfiguration{module_name: module_name} = opts) do
    GenServer.start_link(__MODULE__, opts, name: {:global, :"#{module_name}.AutoScaler"})
  end

  @impl true
  def init(%AutoScalerConfiguration{} = config) do
    schedule_check(config.check_interval)
    {:ok, %{config: config, current_consumer_count: config.initial_consumer_count}}
  end

  @impl true
  def handle_info(:check_queue, state) do
    queue_length = get_queue_length(state.config, state.current_consumer_count)
    state = adjust_consumers(queue_length, state)

    schedule_check(state.config.check_interval)
    {:noreply, state}
  end

  defp schedule_check(interval) do
    Process.send_after(self(), :check_queue, interval)
  end

  # Walk workers W1..W{count} and return the queue depth from the first one
  # that is alive and responsive. Falls back to 0 only if none can be reached,
  # preventing a single dead worker from causing a spurious scale-down.
  defp get_queue_length(%AutoScalerConfiguration{} = config, current_count) do
    find_worker_queue_length(config.module_name, 1, max(current_count, 1))
  end

  defp find_worker_queue_length(_module_name, index, max) when index > max, do: 0

  defp find_worker_queue_length(module_name, index, max) do
    case :global.whereis_name("#{module_name}.W#{index}") do
      pid when is_pid(pid) ->
        try do
          queue_config = GenServer.call(pid, :get_config, worker_call_timeout())
          # Check if channel is available before attempting to get message count
          if queue_config.channel do
            AMQP.Queue.message_count(queue_config.channel, queue_config.queue_name)
          else
            # Worker hasn't finished connecting yet, try next worker
            find_worker_queue_length(module_name, index + 1, max)
          end
        catch
          :exit, _ -> find_worker_queue_length(module_name, index + 1, max)
        end

      _ ->
        find_worker_queue_length(module_name, index + 1, max)
    end
  end

  defp adjust_consumers(
         queue_length,
         %{config: config, current_consumer_count: current_count} = state
       ) do
    target_consumer_count = calculate_target_consumer_count(queue_length, config)

    Logger.debug(
      "[#{config.module_name}] Queue check: #{queue_length} messages, current consumers: #{current_count}, target: #{target_consumer_count}"
    )

    cond do
      target_consumer_count > current_count ->
        supervisor = HareMq.DynamicSupervisor.supervisor_name(config.module_name)
        scale_up_count = target_consumer_count - current_count

        Logger.debug(
          "[#{config.module_name}] Scaling UP from #{current_count} to #{target_consumer_count} consumers (adding #{scale_up_count})"
        )

        Enum.each(1..scale_up_count, fn index ->
          HareMq.DynamicSupervisor.add_consumer(
            supervisor,
            worker: config.consumer_worker,
            name: generate_consumer_name(config.module_name, current_count + index),
            opts: config.consumer_opts
          )
        end)

      target_consumer_count < current_count ->
        supervisor = HareMq.DynamicSupervisor.supervisor_name(config.module_name)
        scale_down_count = current_count - target_consumer_count

        Logger.debug(
          "[#{config.module_name}] Scaling DOWN from #{current_count} to #{target_consumer_count} consumers (removing #{scale_down_count})"
        )

        Enum.each((target_consumer_count + 1)..current_count, fn index ->
          HareMq.DynamicSupervisor.remove_consumer(
            supervisor,
            generate_consumer_name(config.module_name, index)
          )
        end)

      true ->
        :ok
    end

    %{state | current_consumer_count: target_consumer_count}
  end

  def calculate_target_consumer_count(queue_length, config) do
    # one consumer per N messages in the queue.
    div(queue_length + config.messages_per_consumer - 1, config.messages_per_consumer)
    |> max(config.min_consumers)
    |> min(config.max_consumers)
  end

  defp generate_consumer_name(module_name, count) do
    "#{module_name}.W#{count}"
  end
end
