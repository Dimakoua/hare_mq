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

  def is_dup?(message, deduplication_ttl) do
    GenServer.call(__MODULE__, {:is_dup, message, deduplication_ttl})
  end

  def add(message) do
    GenServer.cast(__MODULE__, {:add, message})
  end

  def handle_info(:clear_cache, state) do
    new_state =
      state
      |> Enum.filter(fn {_k, v} ->
        v.inserted_at > :os.system_time(:millisecond)
      end)
      |> Enum.into(%{})

    {:noreply, new_state}
  end

  def handle_cast({:add, message}, state) do
    hash = generate_hash(message)

    message =
      %{}
      |> Map.put(:message, message)
      |> Map.put(:inserted_at, :os.system_time(:millisecond))

    new_state = Map.put(state, hash, message)

    {:noreply, new_state}
  end

  def handle_call({:is_dup, message, deduplication_ttl}, _from, state) do
    hash = generate_hash(message)

    is_dup =
      case Map.get(state, hash) do
        nil ->
          false

        _ when deduplication_ttl == :infinite ->
          true

        cached_message ->
          cached_message.inserted_at + deduplication_ttl > :os.system_time(:millisecond)
      end

    {:reply, is_dup, state}
  end

  defp generate_hash(message) when is_binary(message) do
    :crypto.hash(:md5, message) |> Base.encode16()
  end

  defp generate_hash(message) when is_map(message) do
    encoded_message = Jason.encode!(message)

    :crypto.hash(:md5, encoded_message) |> Base.encode16()
  end
end
