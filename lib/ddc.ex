defmodule HareMq.Ddc do
  use HareMq.Consumer,
    queue_name: "haremq.test.1",
    routing_key: "haremq.test",
    exchange: "haremq"

  # HareMq.Ddc.start_link([])
  # def consume(message) do
  #   IO.inspect("LKSLDKSLDKSLDK")
  #   IO.inspect(message)

  #   raise "[ERROR]"
  #   :error
  # end

  # HareMq.Ddc.republish_dead_messages(12)
end

defmodule HareMq.Ddp do
  use HareMq.Publisher,
    routing_key: "haremq.test",
    exchange: "haremq"

  # HareMq.Ddp.start_link([])
  # HareMq.Ddp.publish()
  def publish() do
    message = "asdasdasdasd"
    IO.inspect("LKSLDKSLDKSLDK")
    IO.inspect(message)
    raise "[ERROR 33]"

    publish_message(message)
    |> IO.inspect()
  end
end
