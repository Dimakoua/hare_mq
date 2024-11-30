defmodule HareMq.AutoScalerTest do
  use ExUnit.Case, async: true
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
end
