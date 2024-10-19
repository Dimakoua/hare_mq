defmodule HareMq.GlobalNodeManager do
  require Logger

  # Function to wait until all nodes are ready
  def wait_for_all_nodes_ready(name) do
    nodes = Node.list() ++ [node()]  # Include self

    wait_until_ready(nodes, name, 30_000) # 30 seconds timeout
  end

  defp wait_until_ready(nodes, name, remaining_time) when remaining_time > 0 do
    cond do
      length(Node.list()) == 0 ->
        Logger.info("All nodes are ready for #{name}.")
        :ok
      length(Node.list()) > 0 and :global.whereis_name(name) != :undefined ->
        Logger.info("All nodes are ready for #{name}.")
        :ok
      true ->
        Logger.info("Waiting for all nodes to be ready for #{name}...")
        Process.sleep(1000)  # Sleep for 1 second
        wait_until_ready(nodes, name, remaining_time - 1000)
    end

  end

  defp wait_until_ready(_, _, _) do
    Logger.error("Timeout waiting for all nodes to be ready.")
    {:error, :timeout}
  end
end
