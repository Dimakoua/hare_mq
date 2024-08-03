defmodule HareMq.Connection do
  @moduledoc """
  GenServer module for managing AMQP connection.

  This module handles the lifecycle of the AMQP connection and provides functions for getting, closing, and monitoring the connection.
  """
  use GenServer
  use AMQP
  require Logger

  @reconnect_interval Application.compile_env(:hare_mq, :configuration)[:reconnect_interval_in_ms] ||
                        10_000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  def init(_) do
    send(self(), :connect)
    {:ok, nil}
  end

  @doc """
  Get the current connection.

  Returns:
    - `{:ok, connection}`: If the connection is established.
    - `{:error, :not_connected}`: If the connection is not established.

  ## Examples

      case HareMq.Connection.get_connection() do
        {:ok, conn} -> IO.inspect(conn)
        {:error, :not_connected} -> IO.puts("Not connected!")
      end
  """
  def get_connection do
    case GenServer.whereis(__MODULE__) do
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
  Close the current connection.

  Returns:
    - `{:ok, connection}`: If the connection is successfully closed.
    - `{:error, :not_connected}`: If the connection is not established.

  ## Examples

      case HareMq.Connection.close_connection() do
        {:ok, conn} -> IO.inspect(conn)
        {:error, :not_connected} -> IO.puts("Not connected!")
      end
  """
  def close_connection do
    case GenServer.call(__MODULE__, :close_connection) do
      nil -> {:error, :not_connected}
      %AMQP.Connection{} = conn -> {:ok, conn}
    end
  end

  def handle_call(:get_connection, _, %AMQP.Connection{} = conn) do
    {:reply, conn, conn}
  end

  def handle_call(:get_connection, _, state) do
    {:reply, state, state}
  end

  def handle_call(:close_connection, _, %AMQP.Connection{} = state) do
    Connection.close(state)
    {:reply, state, state}
  end

  def handle_call(:close_connection, _, state) do
    {:reply, nil, state}
  end

  def handle_info(:connect, _) do
    configs = Application.get_env(:hare_mq, :amqp)
    host = configs[:url]

    case Connection.open(host) do
      {:ok, %AMQP.Connection{} = conn} ->
        Process.monitor(conn.pid)
        {:noreply, conn}

      {:error, _} ->
        Logger.error("[connection] Failed to connect #{host}. Reconnecting later...")

        Process.send_after(self(), :connect, @reconnect_interval)
        {:noreply, nil}
    end
  end

  def handle_info({:DOWN, _, :process, _pid, {:shutdown, :normal}}, _) do
    {:noreply, nil}
  end

  def handle_info(reason, _state) do
    # Stop GenServer. Will be restarted by Supervisor.
    {:stop, {:connection_lost, reason}, nil}
  end
end
