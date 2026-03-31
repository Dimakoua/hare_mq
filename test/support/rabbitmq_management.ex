defmodule HareMq.Test.RabbitMQManagement do
  @moduledoc """
  HTTP client for the RabbitMQ management API, used in integration tests.

  Reads the following environment variables (with dev-container defaults):

  | Variable | Default |
  |---|---|
  | `RABBITMQ_MGMT_URL` | `http://localhost:15672` |
  | `RABBITMQ_USER` | `guest` |
  | `RABBITMQ_PASSWORD` | `guest` |
  | `RABBITMQ_URL` | `amqp://guest:guest@localhost` |
  """

  @default_vhost "/"

  # ---------------------------------------------------------------------------
  # AMQP URL helper (for setting Application env in test setup)
  # ---------------------------------------------------------------------------

  @doc "Returns the AMQP URL to use in integration test setups."
  def amqp_url do
    System.get_env("RABBITMQ_URL", "amqp://guest:guest@rabbitmq")
  end

  # ---------------------------------------------------------------------------
  # Queue operations
  # ---------------------------------------------------------------------------

  @doc "Returns `{:ok, queue_info_map}` or `{:error, reason}`."
  def get_queue(queue_name, vhost \\ @default_vhost) do
    get("/queues/#{encode_vhost(vhost)}/#{URI.encode(queue_name)}")
  end

  @doc "Returns `true` if the queue exists."
  def queue_exists?(queue_name, vhost \\ @default_vhost) do
    match?({:ok, _}, get_queue(queue_name, vhost))
  end

  @doc "Deletes a queue. Returns `:ok` or `{:error, reason}`. 404 is silently ignored."
  def delete_queue(queue_name, vhost \\ @default_vhost) do
    case request(:delete, "/queues/#{encode_vhost(vhost)}/#{URI.encode(queue_name)}") do
      {:ok, _} -> :ok
      {:error, :not_found} -> :ok
      error -> error
    end
  end

  @doc "Purges all messages from a queue."
  def purge_queue(queue_name, vhost \\ @default_vhost) do
    request(:delete, "/queues/#{encode_vhost(vhost)}/#{URI.encode(queue_name)}/contents")
  end

  # ---------------------------------------------------------------------------
  # Exchange operations
  # ---------------------------------------------------------------------------

  @doc "Returns `{:ok, exchange_info_map}` or `{:error, reason}`."
  def get_exchange(exchange_name, vhost \\ @default_vhost) do
    get("/exchanges/#{encode_vhost(vhost)}/#{URI.encode(exchange_name)}")
  end

  @doc "Returns `true` if the exchange exists."
  def exchange_exists?(exchange_name, vhost \\ @default_vhost) do
    match?({:ok, _}, get_exchange(exchange_name, vhost))
  end

  # ---------------------------------------------------------------------------
  # Polling helpers
  # ---------------------------------------------------------------------------

  @doc """
  Polls until `queue_name` appears or `timeout_ms` expires.
  Returns `{:ok, queue_info}` or `{:error, :timeout}`.
  """
  def wait_for_queue(queue_name, vhost \\ @default_vhost, timeout_ms \\ 5_000) do
    poll_until(timeout_ms, fn ->
      case get_queue(queue_name, vhost) do
        {:ok, info} -> {:done, {:ok, info}}
        _ -> :continue
      end
    end)
  end

  @doc """
  Polls until the message count in `queue_name` is >= `expected` or `timeout_ms` expires.
  Returns `:ok` or `{:error, :timeout}`.
  """
  def wait_for_messages(queue_name, expected_count, vhost \\ @default_vhost, timeout_ms \\ 10_000) do
    poll_until(timeout_ms, fn ->
      case get_queue(queue_name, vhost) do
        {:ok, %{"messages" => n}} when n >= expected_count -> {:done, :ok}
        _ -> :continue
      end
    end)
  end

  @doc """
  Polls until the consumer count on `queue_name` is >= `expected` or `timeout_ms` expires.
  Returns `:ok` or `{:error, :timeout}`.

  Use this to guarantee a stream consumer (with `stream_offset: "next"`) has
  subscribed before publishing — otherwise messages published earlier are missed.
  """
  def wait_for_consumers(
        queue_name,
        expected_count \\ 1,
        vhost \\ @default_vhost,
        timeout_ms \\ 10_000
      ) do
    poll_until(timeout_ms, fn ->
      case get_queue(queue_name, vhost) do
        {:ok, %{"consumers" => n}} when n >= expected_count -> {:done, :ok}
        _ -> :continue
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp get(path), do: request(:get, path)

  # Uses curl instead of :httpc to avoid OTP 26 inets :http_util.timestamp/0 breakage.
  defp request(method, path) do
    url = "#{base_url()}/api#{path}"
    user = System.get_env("RABBITMQ_USER", "guest")
    pass = System.get_env("RABBITMQ_PASSWORD", "guest")

    method_args =
      case method do
        :get -> []
        :delete -> ["-X", "DELETE"]
        :put -> ["-X", "PUT", "-H", "Content-Type: application/json", "-d", ""]
        :post -> ["-X", "POST", "-H", "Content-Type: application/json", "-d", ""]
      end

    args =
      ["-s", "--max-time", "5", "-u", "#{user}:#{pass}", "-w", "\n%{http_code}"] ++
        method_args ++ [url]

    case System.cmd("curl", args, stderr_to_stdout: false) do
      {output, 0} -> parse_curl_response(output)
      {_, code} -> {:error, {:curl_failed, code}}
    end
  end

  defp parse_curl_response(output) do
    # curl appends \n{http_code} after the body; split on the last newline
    {status_str, body_parts} = List.pop_at(String.split(output, "\n"), -1)

    body = Enum.join(body_parts, "\n")

    case Integer.parse(String.trim(status_str)) do
      {200, _} -> {:ok, Jason.decode!(body)}
      {201, _} -> {:ok, Jason.decode!(body)}
      {204, _} -> {:ok, :no_content}
      {404, _} -> {:error, :not_found}
      {status, _} -> {:error, {status, body}}
      :error -> {:error, {:bad_response, output}}
    end
  end

  defp poll_until(timeout_ms, fun, interval_ms \\ 100) do
    deadline = :os.system_time(:millisecond) + timeout_ms
    do_poll(fun, deadline, interval_ms)
  end

  defp do_poll(fun, deadline, interval_ms) do
    case fun.() do
      {:done, result} ->
        result

      :continue ->
        if :os.system_time(:millisecond) >= deadline do
          {:error, :timeout}
        else
          :timer.sleep(interval_ms)
          do_poll(fun, deadline, interval_ms)
        end
    end
  end

  defp base_url do
    host = System.get_env("RABBITMQ_HOST", "rabbitmq")
    System.get_env("RABBITMQ_MGMT_URL", "http://#{host}:15672")
  end

  defp encode_vhost("/"), do: "%2F"
  defp encode_vhost(vhost), do: URI.encode(vhost)
end
