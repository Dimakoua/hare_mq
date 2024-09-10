defmodule HareMq.AutoScaler do
  use GenServer
  alias HareMq.AutoScalerConfiguration

  @moduledoc """
  A GenServer that automatically scales the number of consumers based on the
  number of messages in the RabbitMQ queue.
  """

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(%AutoScalerConfiguration{} = config) do
    schedule_check(config.check_interval)
    {:ok, %{config: config, current_consumer_count: config[:initial_consumer_count]}}
  end

  @impl true
  def handle_info(:check_queue, state) do
    queue_length = get_queue_length(channel: state.config[:channel], queue: state.config[:queue])
    adjust_consumers(queue_length, state)
    schedule_check(state.config[:check_interval])
    {:noreply, state}
  end

  defp schedule_check(interval) do
    Process.send_after(self(), :check_queue, interval)
  end

  defp get_queue_length(channel: channel, queue: queue) do
    AMQP.Queue.message_count(channel, queue)
  end

  defp adjust_consumers(
         queue_length,
         %{config: config, current_consumer_count: current_count} = state
       ) do
    target_consumer_count = calculate_target_consumer_count(queue_length, config)

    cond do
      target_consumer_count > current_count ->
        Enum.each(1..(target_consumer_count - current_count), fn _ ->
          HareMq.DynamicSupervisor.add_consumer(
            worker: config[:consumer_worker],
            name: generate_consumer_name(config[:consumer_worker], current_count + 1),
            opts: [config: config, consume: config[:consume]]
          )
        end)

      target_consumer_count < current_count ->
        Enum.each(1..(current_count - target_consumer_count), fn _ ->
          HareMq.DynamicSupervisor.remove_consumer(
            generate_consumer_name(config[:consumer_worker], current_count)
          )
        end)
    end

    %{state | current_consumer_count: target_consumer_count}
  end

  defp calculate_target_consumer_count(queue_length, config) do
    # one consumer per N messages in the queue.
    div(queue_length + config[:messages_per_consumer] - 1, config[:messages_per_consumer])
    |> max(config[:min_consumers])
    |> min(config[:max_consumers])
  end

  defp generate_consumer_name(worker, count) do
    "#{worker}.W#{count}"
  end
end
