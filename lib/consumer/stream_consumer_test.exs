defmodule HareMq.StreamConsumerTest do
  use HareMq.TestCase
  alias HareMq.Configuration

  @moduledoc """
  Unit tests for the stream-related fields added to `HareMq.Configuration`.

  These tests operate purely on the configuration struct and require no live
  RabbitMQ connection. Integration tests that verify stream queue behaviour
  against a real broker live in `test/integration/stream_integration_test.exs`.
  """

  describe "Configuration.get_queue_configuration/1 stream fields" do
    test "defaults stream to false and stream_offset to 'next'" do
      config =
        Configuration.get_queue_configuration(
          channel: nil,
          consume_fn: fn _ -> :ok end,
          name: "my_queue"
        )

      assert config.stream == false
      assert config.stream_offset == "next"
    end

    test "stream: true is stored correctly" do
      config =
        Configuration.get_queue_configuration(
          channel: nil,
          consume_fn: fn _ -> :ok end,
          name: "my_queue",
          stream: true
        )

      assert config.stream == true
      assert config.stream_offset == "next"
    end

    test "accepts string stream_offset values" do
      for offset <- ["first", "last", "next"] do
        config =
          Configuration.get_queue_configuration(
            channel: nil,
            consume_fn: fn _ -> :ok end,
            name: "my_queue",
            stream: true,
            stream_offset: offset
          )

        assert config.stream_offset == offset
      end
    end

    test "accepts integer stream_offset" do
      config =
        Configuration.get_queue_configuration(
          channel: nil,
          consume_fn: fn _ -> :ok end,
          name: "my_queue",
          stream: true,
          stream_offset: 42
        )

      assert config.stream_offset == 42
    end

    test "accepts DateTime stream_offset" do
      dt = ~U[2024-01-01 00:00:00Z]

      config =
        Configuration.get_queue_configuration(
          channel: nil,
          consume_fn: fn _ -> :ok end,
          name: "my_queue",
          stream: true,
          stream_offset: dt
        )

      assert config.stream_offset == dt
    end

    test "non-stream config still builds delay and dead queue names" do
      config =
        Configuration.get_queue_configuration(
          channel: nil,
          consume_fn: fn _ -> :ok end,
          name: "orders"
        )

      assert config.delay_queue_name == "orders.delay"
      assert config.dead_queue_name == "orders.dead"
    end

    test "stream config does not affect delay or dead queue name fields" do
      config =
        Configuration.get_queue_configuration(
          channel: nil,
          consume_fn: fn _ -> :ok end,
          name: "events",
          stream: true
        )

      # Fields are still set; the consumer_worker simply never declares them
      assert config.delay_queue_name == "events.delay"
      assert config.dead_queue_name == "events.dead"
    end
  end
end
