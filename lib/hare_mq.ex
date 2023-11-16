defmodule HareMq do
  use Application
  require Logger

  def start(_type, _args) do
    children = [
      HareMq.Connection
    ]

    opts = [strategy: :one_for_one, name: HareMq.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
