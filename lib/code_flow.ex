defmodule HareMq.CodeFlow do
  def successful_start({:ok, pid}), do: {:ok, pid}
  def successful_start({:error, {:already_started, _pid}}), do: :ignore

  def successful_start(result, _error), do: result
end
