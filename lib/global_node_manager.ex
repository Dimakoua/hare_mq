defmodule HareMq.GlobalNodeManager do
  require Logger

  @doc """
  Waits until the `:global` name registry is synchronized across all connected
  nodes before returning, with a 30-second timeout.

  Two cases:

  * **Single-node** (`Node.list()` is empty) — no remote nodes to synchronize
    with, so we return immediately. `:global` registration on a single node is
    always instantaneous.

  * **Multi-node** — we call `:global.sync/0` which blocks until the registry
    has been reconciled across all connected nodes. This ensures that a
    subsequent `GenServer.start_link(..., name: {:global, name})` call will not
    race with an identical registration on another node.

  Called from `HareMq.Worker.Consumer.start_link/1` before registering the
  consumer globally.
  """
  def wait_for_all_nodes_ready(name) do
    wait_until_ready(name, 30_000)
  end

  defp wait_until_ready(_name, remaining_time) when remaining_time <= 0 do
    Logger.error("[GlobalNodeManager] Timeout waiting for :global sync.")
    {:error, :timeout}
  end

  defp wait_until_ready(name, remaining_time) do
    if Node.list() == [] do
      # Single-node deployment — nothing to synchronize.
      :ok
    else
      case :global.sync() do
        :ok ->
          # After sync, check if another node already registered this name.
          # If so, our own GenServer.start_link will return {:already_started, pid}
          # which CodeFlow.successful_start/1 converts to :ignore — this log
          # just makes that situation visible before it happens.
          case :global.whereis_name(name) do
            pid when is_pid(pid) ->
              Logger.debug(
                "[GlobalNodeManager] #{inspect(name)} already registered globally on node #{inspect(node(pid))}."
              )

            :undefined ->
              Logger.debug("[GlobalNodeManager] :global registry synced for #{inspect(name)}.")
          end

          :ok

        {:error, reason} ->
          Logger.warning(
            "[GlobalNodeManager] :global sync failed (#{inspect(reason)}), retrying..."
          )

          Process.sleep(1_000)
          wait_until_ready(name, remaining_time - 1_000)
      end
    end
  end
end
