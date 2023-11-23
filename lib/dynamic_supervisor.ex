defmodule HareMq.DynamicSupervisor do
  use DynamicSupervisor

  def start_link([config: _, consume: _] = opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init([config: _, consume: _] = opts) do
    {:ok, _} = Task.start_link(fn -> start_consumers(opts) end)
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  defp start_consumers([config: config, consume: _] = opts) do
    IO.inspect("DLDLDLDL")
    # Enum.each(0..config.consumer_count, fn number ->
    #   start_child(worker: worker, name: name)
    # end)
  end

  def start_child(worker: worker, name: name) do
    DynamicSupervisor.start_child(__MODULE__, {worker, name})
  end
end
