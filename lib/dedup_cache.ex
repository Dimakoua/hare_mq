defmodule HareMq.DedupCache do
  use GenServer

  # Client API
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # GenServer callbacks
  def init(_opts) do
    send(self(), :clear_cache)
    {:ok, %{}}
  end

  def is_dup?(message, deduplication_ttl, deduplication_keys \\ []) do
    GenServer.call(__MODULE__, {:is_dup, message, deduplication_ttl, deduplication_keys})
  end

  def add(message, deduplication_keys \\ []) do
    GenServer.cast(__MODULE__, {:add, message, deduplication_keys})
  end

  def handle_info(:clear_cache, state) do
    new_state =
      state
      |> Enum.filter(fn {_k, v} ->
        v.inserted_at > :os.system_time(:millisecond)
      end)
      |> Enum.into(%{})

    Process.send_after(self(), :clear_cache, 1_000)

    {:noreply, new_state}
  end

  def handle_cast({:add, message, deduplication_keys}, state) do
    hash = generate_hash(message, deduplication_keys)

    message =
      %{}
      |> Map.put(:message, message)
      |> Map.put(:inserted_at, :os.system_time(:millisecond))

    new_state = Map.put(state, hash, message)

    {:noreply, new_state}
  end

  def handle_call({:is_dup, message, deduplication_ttl, deduplication_keys}, _from, state) do
    hash = generate_hash(message, deduplication_keys)

    is_dup =
      case Map.get(state, hash) do
        nil ->
          false

        cached_message when deduplication_ttl == :infinite ->
          Enum.all?(deduplication_keys, fn key -> message[key] === cached_message.message[key] end)

        cached_message ->
          is_dub_by_keys =
            Enum.all?(deduplication_keys, fn key ->
              message[key] === cached_message.message[key]
            end)

          is_cached =
            cached_message.inserted_at + deduplication_ttl > :os.system_time(:millisecond)

          is_dub_by_keys && is_cached
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
