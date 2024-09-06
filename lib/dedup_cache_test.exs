defmodule HareMq.DedupCacheTest do
  use HareMq.TestCase
  alias HareMq.Connection
  alias HareMq.DedupCache

  defmodule TestPublisher do
    use HareMq.Publisher, exchange: "test_routing_key", routing_key: "test_routing_key"
  end

  setup do
    Connection.start_link(nil)
    {:ok, _pid} = DedupCache.start_link([])
    :ok
  end

  test "should return false for a message that is not in the cache" do
    refute DedupCache.is_dup?("test_message", 1000)
  end

  test "should return true for a message that was added" do
    DedupCache.add("test_message")
    assert DedupCache.is_dup?("test_message", 1000)
  end

  test "should return false for a message that has expired" do
    DedupCache.add("test_message")
    :timer.sleep(2000)  # Sleep longer than the TTL
    refute DedupCache.is_dup?("test_message", 1000)
  end

  test "should handle infinite TTL correctly" do
    DedupCache.add("test_message")
    assert DedupCache.is_dup?("test_message", :infinite)
  end

  test "should clear expired cache entries" do
    DedupCache.add("test_message")
    :timer.sleep(2000)  # Sleep longer than the TTL
    DedupCache.handle_info(:clear_cache, %{})  # Manually trigger cache clearing
    refute DedupCache.is_dup?("test_message", 1000)
  end

  test "should handle messages as maps" do
    message_map = %{key: "value"}
    DedupCache.add(message_map)
    assert DedupCache.is_dup?(message_map, 1000)
  end

  test "should generate different hashes for different messages" do
    DedupCache.add("message1")
    DedupCache.add("message2")
    refute DedupCache.is_dup?("message1", 1000)
    refute DedupCache.is_dup?("message2", 1000)
  end
end
