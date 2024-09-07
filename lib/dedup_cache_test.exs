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

  test "add and check for duplicate based on all keys" do
    message1 = %{id: 1, key: 1, value: 2}
    message2 = %{id: 2, key: 1, value: 2}

    HareMq.DedupCache.add(message1, 1000)
    # Should return false because of different `id`
    refute HareMq.DedupCache.is_dup?(message2)

    # Add the message1 again to test the deduplication based on all keys
    HareMq.DedupCache.add(message2, 1000)
    # Should return true because of same `key` and `value`
    assert HareMq.DedupCache.is_dup?(message2)
  end

  test "check for duplicate based on specific keys" do
    message1 = %{id: 1, key: 1, value: 2}
    message2 = %{id: 2, key: 1, value: 2}

    HareMq.DedupCache.add(message1, 1000, [:key, :value])

    # Check based on [key, value]
    # Should return true
    assert HareMq.DedupCache.is_dup?(message2, [:key, :value])

    # Check based on [id]
    # Should return false
    refute HareMq.DedupCache.is_dup?(message2, [:id])
  end

  test "TTL functionality" do
    message1 = %{id: 1, key: 1, value: 2}
    message2 = %{id: 2, key: 1, value: 2}

    HareMq.DedupCache.add(message1, 1000)

    # Check if TTL works
    # Sleep for longer than TTL
    :timer.sleep(1500)
    # Should return false after TTL expires
    refute HareMq.DedupCache.is_dup?(message2, [:key, :value])
  end

  test "infinite TTL" do
    message1 = %{id: 1, key: 1, value: 2}
    message2 = %{id: 2, key: 1, value: 2}

    HareMq.DedupCache.add(message1, :infinity, [:key, :value])

    # Check if infinite TTL works
    # Should return true
    assert HareMq.DedupCache.is_dup?(message2, [:key, :value])
  end

  test "should return false for a message that is not in the cache" do
    refute DedupCache.is_dup?("test_message")
  end

  test "should return true for a message that was added" do
    DedupCache.add("test_message", 1000)
    assert DedupCache.is_dup?("test_message")
  end

  test "should return false for a message that has expired" do
    DedupCache.add("test_message", 1000)
    # Sleep longer than the TTL
    :timer.sleep(2000)
    refute DedupCache.is_dup?("test_message")
  end

  test "should handle infinite TTL correctly" do
    DedupCache.add("test_message", :infinity)
    assert DedupCache.is_dup?("test_message")
  end

  test "should clear expired cache entries" do
    DedupCache.add("test_message", 1000)
    # Sleep longer than the TTL
    :timer.sleep(2000)
    # Manually trigger cache clearing
    DedupCache.handle_info(:clear_cache, %{})
    refute DedupCache.is_dup?("test_message")
  end

  test "should handle messages as maps" do
    message_map = %{key: "value"}
    DedupCache.add(message_map, 1000)
    assert DedupCache.is_dup?(message_map)
  end

  test "should generate different hashes for different messages" do
    DedupCache.add("message1", 1000)
    refute DedupCache.is_dup?("message2")
  end
end
