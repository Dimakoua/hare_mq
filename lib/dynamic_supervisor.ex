defmodule HareMq.DynamicSupervisor do
  use DynamicSupervisor
  alias HareMq.AutoScalerConfiguration

  def start_link([config: _, consume: _] = opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  @doc """
  Initializes the dynamic supervisor with the specified options.

  It starts a Task to asynchronously run the start_consumers function and initializes
  the dynamic supervisor with a one_for_one restart strategy.

  ## Examples

      iex> HareMq.DynamicSupervisor.start_link([config: %{consumer_count: 3}, consume: MyApp.Consumer])
      {:ok, #PID<0.123.0>}
  """
  def init([config: _, consume: _] = opts) do
    {:ok, _} =
      Task.start_link(fn ->
        start_consumers(opts)
        # start_auto_scaler(opts)
      end)

    DynamicSupervisor.init(strategy: :one_for_one)
  end

  defp start_consumers([config: config, consume: _] = opts) do
    Enum.each(1..config[:consumer_count], fn number ->
      start_child(
        worker: config[:consumer_worker],
        name: "#{config[:module_name]}.W#{number}",
        opts: opts
      )
    end)
  end

  @doc """
  Starts a child worker process with the specified worker and options.

  ## Examples

      iex> HareMq.DynamicSupervisor.start_child(worker: MyApp.Consumer, name: :consumer1, opts: [config: %{}, consume: MyApp.Consumer])
      {:ok, #PID<0.124.0>}
  """
  def start_child(worker: worker, name: name, opts: opts) do
    DynamicSupervisor.start_child(__MODULE__, {worker, {name, opts}})
  end

  @doc """
  Adds a new consumer process to the dynamic supervisor.

  ## Examples

      iex> HareMq.DynamicSupervisor.add_consumer(worker: MyApp.Consumer, name: "MyApp.Consumer.W4", opts: [config: %{}, consume: MyApp.Consumer])
      {:ok, #PID<0.125.0>}
  """
  def add_consumer(worker: worker, name: name, opts: opts) do
    start_child(worker: worker, name: name, opts: opts)
  end

  @doc """
  Removes a consumer process by its name.

  ## Examples

      iex> HareMq.DynamicSupervisor.remove_consumer("MyApp.Consumer.W4")
      :ok
  """
  def remove_consumer(name) do
    DynamicSupervisor.which_children(__MODULE__)
    |> Enum.find(fn {_id, pid, _type, _module} ->
      Process.info(pid, :registered_name) == {:registered_name, name}
    end)
    |> case do
      {_, pid, _, _} -> DynamicSupervisor.terminate_child(__MODULE__, pid)
      nil -> {:error, :not_found}
    end
  end

  @doc """
  Returns a list of all consumers managed by this dynamic supervisor.

  ## Examples

      iex> HareMq.DynamicSupervisor.list_consumers()
      ["MyApp.Consumer.W1", "MyApp.Consumer.W2", "MyApp.Consumer.W3"]
  """
  def list_consumers do
    DynamicSupervisor.which_children(__MODULE__)
    |> Enum.filter_map(
      fn {_id, pid, _type, _module} ->
        case Process.info(pid, :registered_name) do
          {:registered_name, name} when is_atom(name) -> true
          _ -> false
        end
      end,
      fn {_id, pid, _type, _module} -> Process.info(pid, :registered_name) |> elem(1) end
    )
  end

  @doc """
  Starts the AutoScaler as a child under this DynamicSupervisor.
  """
  def start_auto_scaler(config: [auto_scaling: nil], consume: _), do: :ok

  def start_auto_scaler([config: config, consume: _] = opts) do
    configuration = AutoScalerConfiguration.get_auto_scaler_configuration(config)
    DynamicSupervisor.start_child(__MODULE__, {HareMq.AutoScaler, configuration})
  end
end
