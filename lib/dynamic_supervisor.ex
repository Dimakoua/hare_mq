defmodule HareMq.DynamicSupervisor do
  use DynamicSupervisor
  require Logger
  alias HareMq.AutoScalerConfiguration

  # Timeout for the :cancel_consume GenServer.call when gracefully removing
  # a consumer. Set high enough to let a slow consume/1 callback finish its
  # current message before the worker is terminated.
  @timeout 70_000

  @moduledoc """
  Per-module dynamic supervisor for `HareMq.DynamicConsumer` worker pools.

  Each module that `use HareMq.DynamicConsumer` gets its own supervisor
  registered as `:<ModuleName>.Supervisor` (e.g. `MyApp.Consumer.Supervisor`).
  This allows multiple consumer modules to coexist on the same node without
  name conflicts.

  Worker processes are started asynchronously (unlinked `Task`) so a startup
  failure (e.g. transient connection error) does not crash the supervisor.
  """

  @doc """
  Returns the registered atom name for the supervisor managing `module_name`.

  ## Example

      HareMq.DynamicSupervisor.supervisor_name(MyApp.Consumer)
      # => :"MyApp.Consumer.Supervisor"
  """
  def supervisor_name(module_name), do: :"#{module_name}.Supervisor"

  def start_link([config: config, consume: _] = opts) do
    name = supervisor_name(config[:module_name])
    DynamicSupervisor.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Initializes the dynamic supervisor.

  Spawns an unlinked `Task` to start consumers and (if configured) the
  auto-scaler. Using an unlinked task means transient errors during consumer
  startup (e.g. waiting for a connection) do not crash the supervisor.
  """
  def init([config: _, consume: _] = opts) do
    {:ok, _} =
      Task.start(fn ->
        try do
          start_consumers(opts)
          start_auto_scaler(opts)
        rescue
          e -> Logger.error("[dynamic_supervisor] Failed to start workers: #{inspect(e)}")
        catch
          :exit, e -> Logger.error("[dynamic_supervisor] Failed to start workers: #{inspect(e)}")
        end
      end)

    DynamicSupervisor.init(strategy: :one_for_one)
  end

  defp start_consumers([config: config, consume: _] = opts) do
    supervisor = supervisor_name(config[:module_name])

    Enum.each(1..config[:consumer_count], fn number ->
      name = "#{config[:module_name]}.W#{number}"

      case start_child(supervisor,
        worker: config[:consumer_worker],
        name: name,
        opts: opts
      ) do
        {:ok, _pid} ->
          :ok

        {:error, reason} ->
          Logger.error("[dynamic_supervisor] Failed to start worker #{name}: #{inspect(reason)}")
      end
    end)
  end

  @doc """
  Starts a child worker under `supervisor`.

  - `supervisor` — the name returned by `supervisor_name/1`.
  - `worker:` — the worker module (must implement `start_link/1`).
  - `name:` — global registration name string for the worker.
  - `opts:` — options forwarded to the worker's `start_link`.
  """
  def start_child(supervisor, worker: worker, name: name, opts: opts) do
    DynamicSupervisor.start_child(supervisor, {worker, {name, opts}})
  end

  @doc """
  Adds a new consumer worker to the running pool.

  Delegates to `start_child/2`. Useful when the auto-scaler scales up.
  """
  def add_consumer(supervisor, worker: worker, name: name, opts: opts) do
    start_child(supervisor, worker: worker, name: name, opts: opts)
  end

  @doc """
  Gracefully removes a running consumer by global name.

  Sends `:cancel_consume` to allow the consumer to finish its current message,
  then terminates the process under the given `supervisor`.
  Returns `:ok` immediately if the named process is not found.
  """
  def remove_consumer(supervisor, name) do
    case :global.whereis_name(name) do
      pid when is_pid(pid) ->
        # Send a cancellation message to allow the consumer to finish processing gracefully
        GenServer.call(pid, :cancel_consume, @timeout)
        DynamicSupervisor.terminate_child(supervisor, pid)

      _ ->
        :ok
    end
  end

  @doc """
  Returns all child specs currently managed by `supervisor`.
  """
  def list_consumers(supervisor) do
    DynamicSupervisor.which_children(supervisor)
  end

  @doc """
  Starts the AutoScaler as a child under this DynamicSupervisor.
  """
  def start_auto_scaler([config: config, consume: consume] = opts) do
    if config[:auto_scaling] do
      supervisor = supervisor_name(config[:module_name])

      configuration =
        AutoScalerConfiguration.get_auto_scaler_configuration(
          queue_name: config[:queue_name],
          consumer_worker: config[:consumer_worker],
          module_name: config[:module_name],
          consumer_count: config[:consumer_count],
          consume: consume,
          auto_scaling: config[:auto_scaling],
          consumer_opts: opts
        )

      DynamicSupervisor.start_child(supervisor, {HareMq.AutoScaler, configuration})
    else
      :ok
    end
  end
end
