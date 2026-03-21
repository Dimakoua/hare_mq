defmodule HareMq.DedupCache do
  @moduledoc """
  A GenServer-based cache for message deduplication in a RabbitMQ system.

  ## Overview

  The `HareMq.DedupCache` module provides functionality to manage a cache of messages to prevent
  the processing of duplicate messages. It uses a GenServer to store messages along with their
  expiration timestamps and supports deduplication based on specific keys within a message.

  ## Features

  - **Deduplication:** Checks if a message is a duplicate based on its content and optional deduplication keys.
  - **TTL Management:** Allows setting a time-to-live (TTL) for cached messages. Messages can be set to expire after a certain time or remain in the cache indefinitely.
  - **Automatic Cache Clearing:** Periodically clears expired messages from the cache.

  ## Functions

  - `is_dup?/2`: Checks if a given message is a duplicate based on the cache.
  - `add/3`: Adds a message to the cache with a specified TTL.

  ## Usage

  This module is intended for use in systems where message deduplication is required, such as in RabbitMQ consumers
  where the same message might be delivered multiple times. The cache ensures that duplicate messages are identified
  and not processed multiple times.
  """

  use GenServer

  def start_link(opts \\ []) do
    server_name = Keyword.get(opts, :name, {:global, __MODULE__})
    table_name = ets_table_name(server_name)
    GenServer.start_link(__MODULE__, table_name, name: server_name)
    |> HareMq.CodeFlow.successful_start()
  end

  def init(table_name) do
    :ets.new(table_name, [:named_table, :public, :set, {:read_concurrency, true}])
    schedule_clear()
    {:ok, table_name}
  end

  def is_dup?(message, deduplication_keys \\ []) do
    ets_is_dup?(__MODULE__, message, deduplication_keys)
  end

  def is_dup?(message, deduplication_keys, cache_name) do
    ets_is_dup?(ets_table_name(cache_name), message, deduplication_keys)
  end

  def add(message, deduplication_ttl, deduplication_keys \\ []) do
    add(message, deduplication_ttl, deduplication_keys, {:global, __MODULE__})
  end

  def add(message, deduplication_ttl, deduplication_keys, cache_name) do
    GenServer.call(cache_name, {:add, message, deduplication_ttl, deduplication_keys})
  end

  def handle_info(:clear_cache, table) do
    now = :os.system_time(:millisecond)
    :ets.select_delete(table, [{{"$1", :"$2", :"$3"}, [{:"=<", :"$3", now}], [true]}])
    schedule_clear()
    {:noreply, table}
  end

  def handle_call({:add, message, deduplication_ttl, deduplication_keys}, _from, table) do
    hash = generate_hash(message, deduplication_keys)

    ttl_ms =
      case deduplication_ttl do
        :infinity -> 31_556_952_000 * 5
        _ -> deduplication_ttl
      end

    expired_at = :os.system_time(:millisecond) + ttl_ms
    :ets.insert(table, {hash, message, expired_at})
    {:reply, :ok, table}
  end

  defp ets_is_dup?(table, message, deduplication_keys) do
    hash = generate_hash(message, deduplication_keys)
    now = :os.system_time(:millisecond)

    case :ets.lookup(table, hash) do
      [{^hash, cached_message, expired_at}] when expired_at > now ->
        check_keys(message, cached_message, deduplication_keys)

      _ ->
        false
    end
  rescue
    # Table doesn't exist (cache not started)
    ArgumentError -> false
  end

  defp check_keys(message, cached_message, deduplication_keys) when is_map(message) do
    Enum.all?(deduplication_keys, fn key ->
      message[key] === cached_message[key]
    end)
  end

  defp check_keys(_message, _cached_message, _deduplication_keys), do: true

  defp schedule_clear do
    Process.send_after(self(), :clear_cache, 1_000)
  end

  defp ets_table_name({:global, name}), do: name
  defp ets_table_name(name) when is_atom(name), do: name
  defp ets_table_name(_), do: __MODULE__

  defp generate_hash(message, _deduplication_keys) when is_binary(message) do
    :crypto.hash(:md5, message) |> Base.encode16()
  end

  defp generate_hash(message, deduplication_keys) when is_map(message) do
    message =
      case deduplication_keys do
        [_ | _] -> Map.take(message, deduplication_keys)
        _ -> message
      end

    encoded_message = Jason.encode!(message)

    :crypto.hash(:md5, encoded_message) |> Base.encode16()
  end
end
