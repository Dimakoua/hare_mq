defmodule HareMq.TestCase do
  @moduledoc """
  A custom test case template that includes additional setup and helper functions.
  """
  use ExUnit.CaseTemplate

  using opts do
    quote do
      # Import conveniences for testing with ExUnit
      use ExUnit.Case, async: unquote(Keyword.get(opts, :async, false))

      # Import commonly used modules and functions
      import HareMq.TestCase.Helpers
    end
  end

  # Define any helper functions or modules specific to this custom case
  defmodule Helpers do
    @moduledoc """
    A set of helper functions for tests using `HareMq.TestCase`.
    """
    def wait_until(condition, timeout \\ 5000, interval \\ 100) do
      start_time = :os.system_time(:millisecond)
      wait_loop(condition, start_time, timeout, interval)
    end

    defp wait_loop(condition, start_time, timeout, interval) do
      if condition.() do
        :ok
      else
        if :os.system_time(:millisecond) - start_time > timeout do
          {:error, :timeout}
        else
          :timer.sleep(interval)
          wait_loop(condition, start_time, timeout, interval)
        end
      end
    end
  end
end
