defmodule HareMq.Connection do
  @moduledoc """
  GenServer that manages a single AMQP connection.

  ## Lifecycle

  On start it immediately sends itself a `:connect` message. If the broker is
  unavailable or misconfigured it logs the error and retries after
  `reconnect_interval_ms` (from `config :hare_mq, :configuration`;
  default 10 000 ms). All configuration is read at runtime so changes via
  `Application.put_env` take effect on the next reconnect.

  The underlying `AMQP.Connection` is monitored. On a clean broker-initiated
  close (status 200) the GenServer goes idle. On any unexpected drop it logs
  and schedules a reconnect.

  ## Named instances (multi-vhost)

  By default the process registers as `{:global, HareMq.Connection}`. Pass
  `name:` to `start_link/1` to run multiple independent connections:

      {HareMq.Connection, name: {:global, :conn_vhost_b}}

  Consumers and publishers accept a matching `connection_name:` option.
  """
  use GenServer
  use AMQP
  require Logger

  defp reconnect_interval,
    do: (Application.get_env(:hare_mq, :configuration) || [])[:reconnect_interval_ms] || 10_000

  # Exponential backoff capped at 60 s with per-attempt jitter to avoid
  # thundering-herd reconnection storms after an outage.
  defp backoff_delay(attempt) do
    base = reconnect_interval()
    delay = trunc(base * :math.pow(2, min(attempt - 1, 5)))
    jitter = :rand.uniform(max(base, 1))
    min(delay + jitter, 60_000)
  end

  def start_link(opts \\ []) do
    opts = opts || []
    name = Keyword.get(opts, :name, {:global, __MODULE__})

    GenServer.start_link(__MODULE__, name, name: name)
    |> HareMq.CodeFlow.successful_start()
  end

  def init(name) do
    send(self(), :connect)
    {:ok, %{name: name, conn: nil, attempt: 0}}
  end

  @doc """
  Returns the current AMQP connection.

  Accepts an optional `name` argument (default `{:global, HareMq.Connection}`) to
  query a specific named instance.

  Returns:
  - `{:ok, %AMQP.Connection{}}` when connected.
  - `{:error, :not_connected}` when the GenServer is not running or not yet connected.
  """
  def get_connection(name \\ {:global, __MODULE__}) do
    case GenServer.whereis(name) do
      nil ->
        {:error, :not_connected}

      pid ->
        case GenServer.call(pid, :get_connection, 1_000) do
          %AMQP.Connection{} = conn -> {:ok, conn}
          _ -> {:error, :not_connected}
        end
    end
  end

  @doc """
  Closes the current AMQP connection.

  Accepts an optional `name` argument (default `{:global, HareMq.Connection}`).
  Sets internal state to `nil` so subsequent `get_connection/1` calls return
  `{:error, :not_connected}` immediately.

  Returns:
  - `{:ok, %AMQP.Connection{}}` when the connection was open and is now closed.
  - `{:error, :not_connected}` when there was no active connection.
  """
  def close_connection(name \\ {:global, __MODULE__}) do
    case GenServer.call(name, :close_connection) do
      nil -> {:error, :not_connected}
      %AMQP.Connection{} = conn -> {:ok, conn}
    end
  end

  def handle_call(:get_connection, _, %{conn: %AMQP.Connection{} = conn} = state) do
    {:reply, conn, state}
  end

  def handle_call(:get_connection, _, state) do
    {:reply, nil, state}
  end

  def handle_call(:close_connection, _, %{conn: %AMQP.Connection{} = conn} = state) do
    Connection.close(conn)
    {:reply, conn, %{state | conn: nil}}
  end

  def handle_call(:close_connection, _, state) do
    {:reply, nil, state}
  end

  def handle_info(:connect, state) do
    configs = Application.get_env(:hare_mq, :amqp)
    attempt = state.attempt + 1

    case configs[:url] do
      nil ->
        delay = backoff_delay(attempt)

        Logger.error(
          "[connection] Missing :amqp config. Retrying in #{delay}ms (attempt #{attempt})..."
        )

        :telemetry.execute(
          [:hare_mq, :connection, :reconnecting],
          %{retry_delay_ms: delay},
          %{connection_name: state.name, reason: :missing_config}
        )

        Process.send_after(self(), :connect, delay)
        {:noreply, %{state | attempt: attempt}}

      host ->
        case Connection.open(host) do
          {:ok, %AMQP.Connection{} = conn} ->
            Process.monitor(conn.pid)

            :telemetry.execute(
              [:hare_mq, :connection, :connected],
              %{system_time: System.system_time()},
              %{connection_name: state.name, host: host}
            )

            {:noreply, %{state | conn: conn, attempt: 0}}

          {:error, reason} ->
            delay = backoff_delay(attempt)

            Logger.error(
              "[connection] Failed to connect #{host}. Reconnecting in #{delay}ms (attempt #{attempt})..."
            )

            :telemetry.execute(
              [:hare_mq, :connection, :reconnecting],
              %{retry_delay_ms: delay},
              %{connection_name: state.name, host: host, reason: reason}
            )

            Process.send_after(self(), :connect, delay)
            {:noreply, %{state | attempt: attempt}}
        end
    end
  end

  def handle_info({:DOWN, _, :process, _pid, {:shutdown, :normal}}, state) do
    {:noreply, %{state | conn: nil}}
  end

  def handle_info(
        {:DOWN, _, :process, _pid, {:shutdown, {:server_initiated_close, 200, _}}},
        state
      ) do
    {:noreply, %{state | conn: nil}}
  end

  def handle_info({:DOWN, _, :process, _pid, reason}, state) do
    Logger.error("[connection] Connection lost: #{inspect(reason)}. Reconnecting...")

    :telemetry.execute(
      [:hare_mq, :connection, :disconnected],
      %{system_time: System.system_time()},
      %{connection_name: state.name, reason: reason}
    )

    # Reset attempt counter — first reconnect after a real disconnect should be prompt.
    Process.send_after(self(), :connect, reconnect_interval())
    {:noreply, %{state | conn: nil, attempt: 0}}
  end

  def handle_info(reason, state) do
    # Stop GenServer. Will be restarted by Supervisor.
    {:stop, {:connection_lost, reason}, state}
  end
end
