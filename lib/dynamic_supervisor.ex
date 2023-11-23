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
    Enum.each(1..config[:consumer_count], fn number ->
      start_child(
        worker: config[:consumer_worker],
        name: String.to_atom("#{config[:consumer_worker]}.#{number}"),
        opts: opts
      )
    end)
  end

  def start_child(worker: worker, name: name, opts: opts) do
    spec = %{id: name, start: {worker, :start_link, [opts]}}
    DynamicSupervisor.start_child(__MODULE__, spec)
  end
end
