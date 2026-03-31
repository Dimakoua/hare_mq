defmodule HareMq.DedupCache do
  @moduledoc """
  ETS-backed deduplication cache for RabbitMQ message processing.

  ## Storage

  Each cache instance owns a named ETS table (`:named_table, :public, :set`).
  The table name is derived from the registered server name so lookups can go
  directly to ETS without passing through the GenServer message queue.

  ## Writes vs reads

  - `add/3` (and `add/4`) — synchronous `GenServer.call`. This guarantees that
    a subsequent `is_dup?` call on any process will see the entry.
  - `is_dup?/2` (and `is_dup?/3`) — reads ETS directly, completely bypassing
    the GenServer. Concurrent read throughput is not limited by a single process.

  ## Expiry

  A 1-second timer runs `handle_info(:clear_cache)` which calls
  `:ets.select_delete/2` to remove all rows whose `expired_at` timestamp is in
  the past. This is a C-level operation with no Elixir-side allocation,
  keeping the GenServer responsive regardless of cache size.

  ## Named instances

  Pass `name:` to `start_link/1` to run isolated caches side-by-side:

      {HareMq.DedupCache, name: {:global, :dedup_cache_tenant_a}}

  Then pass the same name as the third/fourth argument to `is_dup?/3` and
  `add/4`. Publishers accept a `dedup_cache_name:` option.
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

    # Store :infinity as the atom directly. Erlang term ordering places atoms
    # above all numbers, so :infinity > any_integer is always true. This means
    # ets_is_dup?'s '>' guard always passes, and clear_cache's '=<' guard
    # never deletes these entries — achieving a true infinite TTL without
    # relying on a large magic number that would eventually expire.
    expired_at =
      case deduplication_ttl do
        :infinity -> :infinity
        ms -> :os.system_time(:millisecond) + ms
      end

    :ets.insert(table, {hash, message, expired_at})
    {:reply, :ok, table}
  end

  defp ets_is_dup?(table, message, deduplication_keys) do
    hash = generate_hash(message, deduplication_keys)
    now = :os.system_time(:millisecond)

    # Use select so the expiry guard and key match are evaluated atomically
    # in a single C-level ETS operation, with no window between lookup and check.
    match_spec = [{{hash, :"$1", :"$2"}, [{:>, :"$2", now}], [:"$1"]}]

    case :ets.select(table, match_spec) do
      [cached_message] -> check_keys(message, cached_message, deduplication_keys)
      _ -> false
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
