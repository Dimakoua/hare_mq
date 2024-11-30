defmodule HareMq.RetryPublisherTest do
  use HareMq.TestCase
  alias HareMq.RetryPublisher
  alias HareMq.Configuration
  alias HareMq.Connection

  defmodule TestPublisher do
    use HareMq.Publisher, exchange: "test_routing_key", routing_key: "test_routing_key"
  end

  describe "retry_count/1" do
    test "returns 0 for undefined headers" do
      assert RetryPublisher.retry_count(:undefined) == 0
    end

    test "returns 0 for empty headers" do
      assert RetryPublisher.retry_count([]) == 0
    end

    test "extracts retry count from headers", _ do
      headers = [{"retry_count", :long, 2}]
      assert RetryPublisher.retry_count(headers) == 2
    end

    test "extracts retry count with mixed headers" do
      headers = [{"other_header", :shortstr, "value"}, {"retry_count", :long, 3}]
      assert RetryPublisher.retry_count(headers) == 3
    end
  end

  describe "republish/3" do
    setup do
      Connection.start_link(nil)
      TestPublisher.start_link()
      Process.sleep(300)
      # Verify the GenServer has a channel connected
      assert {:ok, channel} = TestPublisher.get_channel()
      # Define a mock configuration
      config = %Configuration{
        channel: channel,
        delay_queue_name: "test_delay_queue",
        dead_queue_name: "test_dead_queue",
        queue_name: "test_queue",
        retry_limit: 3
      }

      {:ok, config: config}
    end

    test "sends to delay queue when retry count is below limit", %{config: config} do
      headers = [{"retry_count", :long, 1}]
      metadata = %{headers: headers}
      payload = "test message"

      assert :ok = RetryPublisher.republish(payload, config, metadata)
    end
  end
end
