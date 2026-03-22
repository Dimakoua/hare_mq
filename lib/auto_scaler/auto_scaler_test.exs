defmodule HareMq.AutoScalerTest do
  use ExUnit.Case, async: false
  alias HareMq.AutoScaler
  alias HareMq.AutoScalerConfiguration

  @default_config %AutoScalerConfiguration{
    module_name: "TestModule",
    check_interval: 1000,
    initial_consumer_count: 1,
    min_consumers: 1,
    max_consumers: 5,
    messages_per_consumer: 10,
    consumer_worker: TestConsumerWorker,
    consumer_opts: []
  }

  setup do
    {:ok, config: @default_config}
  end

  test "initializes with correct state", %{config: config} do
    {:ok, state} = AutoScaler.init(config)

    assert state == %{
             config: config,
             current_consumer_count: config.initial_consumer_count
           }
  end

  test "schedules a check after initialization", %{config: config} do
    {:ok, _state} = AutoScaler.init(config)

    assert_receive :check_queue, config.check_interval + 100
  end

  test "calculate_target_consumer_count calculates the correct number of consumers", %{
    config: config
  } do
    assert AutoScaler.calculate_target_consumer_count(0, config) == 1
    assert AutoScaler.calculate_target_consumer_count(5, config) == 1
    assert AutoScaler.calculate_target_consumer_count(10, config) == 1
    assert AutoScaler.calculate_target_consumer_count(15, config) == 2
    assert AutoScaler.calculate_target_consumer_count(50, config) == 5
  end

  describe "handling workers with nil channel (still connecting)" do
    test "skips worker with nil channel and uses next healthy worker" do
      module_name = "SkipNilChannelTest_#{System.unique_integer()}"

      # Start worker W1 with nil channel (simulating a worker still connecting)
      {:ok, _pid1} = start_mock_worker("#{module_name}.W1", %{channel: nil, queue_name: "test_queue"})

      # Start worker W2 with a valid mocked channel
      {:ok, _pid2} = start_mock_worker("#{module_name}.W2", %{channel: :mock_channel, queue_name: "test_queue"})

      # Mock AMQP.Queue.message_count
      :meck.new(AMQP.Queue, [:passthrough])
      :meck.expect(AMQP.Queue, :message_count, fn :mock_channel, "test_queue" -> 5 end)

      try do
        config = %AutoScalerConfiguration{
          module_name: module_name,
          queue_name: "test_queue",
          check_interval: 1000,
          initial_consumer_count: 1,
          min_consumers: 1,
          max_consumers: 5,
          messages_per_consumer: 10,
          consumer_worker: TestConsumerWorker,
          consumer_opts: []
        }

        # Create initial state and call handle_info which internally calls get_queue_length
        state = %{config: config, current_consumer_count: 1}

        # This should not raise FunctionClauseError, it should handle nil channels gracefully
        {:noreply, new_state} = AutoScaler.handle_info(:check_queue, state)

        assert new_state.current_consumer_count >= config.min_consumers
      after
        :meck.unload()
      end
    end

    test "falls back to 0 message count when all workers are unreachable" do
      module_name = "AllUnreachableTest_#{System.unique_integer()}"

      config = %AutoScalerConfiguration{
        module_name: module_name,
        queue_name: "test_queue",
        check_interval: 1000,
        initial_consumer_count: 2,
        min_consumers: 1,
        max_consumers: 5,
        messages_per_consumer: 10,
        consumer_worker: TestConsumerWorker,
        consumer_opts: []
      }

      state = %{config: config, current_consumer_count: 2}

      # Don't register any workers - all should be unreachable
      # This should return 0 message count and scale down to min_consumers
      {:noreply, new_state} = AutoScaler.handle_info(:check_queue, state)

      assert new_state.current_consumer_count == config.min_consumers
    end
  end

  # Helper function to start a mock GenServer worker
  defp start_mock_worker(name, config) do
    {:ok, pid} = GenServer.start_link(MockWorker, config)
    :global.register_name(name, pid)
    {:ok, pid}
  end
end

defmodule MockWorker do
  use GenServer

  def init(config) do
    {:ok, config}
  end

  def handle_call(:get_config, _from, state) do
    {:reply, state, state}
  end

  def handle_call(:cancel_consume, _from, state) do
    {:reply, :ok, state}
  end
end
