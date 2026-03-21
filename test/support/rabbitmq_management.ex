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
    System.get_env("RABBITMQ_URL", "amqp://guest:guest@localhost")
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
  def wait_for_messages(queue_name, expected_count, vhost \\ @default_vhost, timeout_ms \\ 5_000) do
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
  def wait_for_consumers(queue_name, expected_count \\ 1, vhost \\ @default_vhost, timeout_ms \\ 5_000) do
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

  defp request(method, path) do
    Application.ensure_all_started(:inets)
    url = String.to_charlist("#{base_url()}/api#{path}")
    headers = [{'authorization', String.to_charlist(auth_header())}]

    http_opts = [{:timeout, 5_000}]
    req = if method == :get, do: {url, headers}, else: {url, headers, 'application/json', ''}

    case :httpc.request(method, req, http_opts, []) do
      {:ok, {{_, 200, _}, _, body}} -> {:ok, Jason.decode!(List.to_string(body))}
      {:ok, {{_, 201, _}, _, body}} -> {:ok, Jason.decode!(List.to_string(body))}
      {:ok, {{_, 204, _}, _, _}} -> {:ok, :no_content}
      {:ok, {{_, 404, _}, _, _}} -> {:error, :not_found}
      {:ok, {{_, status, _}, _, body}} -> {:error, {status, List.to_string(body)}}
      {:error, reason} -> {:error, reason}
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

  defp base_url, do: System.get_env("RABBITMQ_MGMT_URL", "http://localhost:15672")

  defp auth_header do
    user = System.get_env("RABBITMQ_USER", "guest")
    pass = System.get_env("RABBITMQ_PASSWORD", "guest")
    "Basic " <> Base.encode64("#{user}:#{pass}")
  end

  defp encode_vhost("/"), do: "%2F"
  defp encode_vhost(vhost), do: URI.encode(vhost)
end
