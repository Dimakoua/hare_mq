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

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    send(self(), :clear_cache)
    {:ok, %{}}
  end

  def is_dup?(message, deduplication_keys \\ []) do
    GenServer.call(__MODULE__, {:is_dup, message, deduplication_keys})
  end

  def add(message, deduplication_ttl, deduplication_keys \\ []) do
    GenServer.cast(__MODULE__, {:add, message, deduplication_ttl, deduplication_keys})
  end

  def handle_info(:clear_cache, state) do
    new_state =
      state
      |> Enum.filter(fn {_k, v} ->
        v.expired_at > :os.system_time(:millisecond)
      end)
      |> Enum.into(%{})

    Process.send_after(self(), :clear_cache, 1_000)

    {:noreply, new_state}
  end

  def handle_cast({:add, message, deduplication_ttl, deduplication_keys}, state) do
    hash = generate_hash(message, deduplication_keys)

    deduplication_ttl =
      case deduplication_ttl do
        # 5 years
        :infinity -> 31_556_952_000 * 5
        _ -> deduplication_ttl
      end

    message =
      %{}
      |> Map.put(:message, message)
      |> Map.put(:expired_at, :os.system_time(:millisecond) + deduplication_ttl)

    new_state = Map.put(state, hash, message)

    {:noreply, new_state}
  end

  def handle_call({:is_dup, message, deduplication_keys}, _from, state) do
    hash = generate_hash(message, deduplication_keys)

    is_dup =
      case Map.get(state, hash) do
        nil ->
          false

        %{message: message} = cached_message when is_map(message) ->
          is_dub_by_keys =
            Enum.all?(deduplication_keys, fn key ->
              message[key] === cached_message.message[key]
            end)

          is_cached = cached_message.expired_at > :os.system_time(:millisecond)

          is_dub_by_keys && is_cached

        %{message: message} = cached_message when is_binary(message) ->
          cached_message.expired_at > :os.system_time(:millisecond)
      end

    {:reply, is_dup, state}
  end

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
