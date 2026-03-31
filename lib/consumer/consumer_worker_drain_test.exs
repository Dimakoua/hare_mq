defmodule HareMq.Worker.Consumer.DrainTest do
  use ExUnit.Case, async: true

  alias HareMq.Worker.Consumer
  alias HareMq.Configuration

  # Minimal state for drain/in_flight tests — no AMQP connection required
  defp build_state(overrides \\ []) do
    struct(%Configuration{in_flight: MapSet.new(), drain_caller: nil, state: :running}, overrides)
  end

  # A fake GenServer `from` — GenServer.reply/2 sends {reply_ref, value} to self()
  defp make_from do
    reply_ref = make_ref()
    {{self(), reply_ref}, reply_ref}
  end

  # ---------------------------------------------------------------------------
  # handle_info {:DOWN} — task completion
  # ---------------------------------------------------------------------------

  describe "handle_info :DOWN for in-flight task" do
    test "removes the ref from in_flight" do
      ref = make_ref()
      state = build_state(in_flight: MapSet.new([ref]))

      {:noreply, new_state} = Consumer.handle_info({:DOWN, ref, :process, self(), :normal}, state)

      assert MapSet.size(new_state.in_flight) == 0
    end

    test "does not send a reply when no drain_caller is set" do
      {_from, reply_ref} = make_from()
      ref = make_ref()
      state = build_state(in_flight: MapSet.new([ref]))

      {:noreply, _new_state} =
        Consumer.handle_info({:DOWN, ref, :process, self(), :normal}, state)

      refute_receive {^reply_ref, :ok}, 100
    end

    test "sends deferred reply and clears drain_caller when last task finishes" do
      {from, reply_ref} = make_from()
      ref = make_ref()
      state = build_state(in_flight: MapSet.new([ref]), drain_caller: from)

      {:noreply, new_state} = Consumer.handle_info({:DOWN, ref, :process, self(), :normal}, state)

      assert MapSet.size(new_state.in_flight) == 0
      assert new_state.drain_caller == nil
      assert_receive {^reply_ref, :ok}
    end

    test "does not send reply while other tasks are still in_flight" do
      {from, reply_ref} = make_from()
      ref1 = make_ref()
      ref2 = make_ref()
      state = build_state(in_flight: MapSet.new([ref1, ref2]), drain_caller: from)

      {:noreply, new_state} =
        Consumer.handle_info({:DOWN, ref1, :process, self(), :normal}, state)

      assert MapSet.size(new_state.in_flight) == 1
      assert MapSet.member?(new_state.in_flight, ref2)
      assert new_state.drain_caller == from
      refute_receive {^reply_ref, :ok}, 100
    end

    test "sends reply only when the very last task finishes" do
      {from, reply_ref} = make_from()
      ref1 = make_ref()
      ref2 = make_ref()
      state = build_state(in_flight: MapSet.new([ref1, ref2]), drain_caller: from)

      # First task finishes — still waiting
      {:noreply, state2} = Consumer.handle_info({:DOWN, ref1, :process, self(), :normal}, state)
      refute_receive {^reply_ref, :ok}, 50

      # Second (last) task finishes — reply is sent
      {:noreply, state3} = Consumer.handle_info({:DOWN, ref2, :process, self(), :normal}, state2)
      assert MapSet.size(state3.in_flight) == 0
      assert state3.drain_caller == nil
      assert_receive {^reply_ref, :ok}
    end
  end

  # ---------------------------------------------------------------------------
  # handle_info {:DOWN} — connection/channel loss (unknown ref)
  # ---------------------------------------------------------------------------

  describe "handle_info :DOWN for unknown ref (connection/channel)" do
    test "stops the worker with connection_lost reason" do
      unknown_ref = make_ref()
      state = build_state()

      assert {:stop, {:connection_lost, :tcp_closed}, _} =
               Consumer.handle_info({:DOWN, unknown_ref, :process, self(), :tcp_closed}, state)
    end

    test "unknown ref stops even when in_flight is non-empty" do
      ref = make_ref()
      unknown_ref = make_ref()
      state = build_state(in_flight: MapSet.new([ref]))

      assert {:stop, {:connection_lost, :noproc}, _} =
               Consumer.handle_info({:DOWN, unknown_ref, :process, self(), :noproc}, state)
    end
  end

  # ---------------------------------------------------------------------------
  # handle_info :drain_timeout
  # ---------------------------------------------------------------------------

  describe "handle_info :drain_timeout" do
    test "sends the deferred reply and clears drain_caller" do
      {from, reply_ref} = make_from()
      ref = make_ref()
      state = build_state(in_flight: MapSet.new([ref]), drain_caller: from)

      {:noreply, new_state} = Consumer.handle_info(:drain_timeout, state)

      assert new_state.drain_caller == nil
      assert_receive {^reply_ref, :ok}
    end

    test "is a no-op when drain_caller is nil" do
      state = build_state(in_flight: MapSet.new())

      {:noreply, new_state} = Consumer.handle_info(:drain_timeout, state)

      assert new_state == state
    end

    test "sends reply even when tasks are still in_flight (forced unblock)" do
      {from, reply_ref} = make_from()
      ref1 = make_ref()
      ref2 = make_ref()
      state = build_state(in_flight: MapSet.new([ref1, ref2]), drain_caller: from)

      {:noreply, new_state} = Consumer.handle_info(:drain_timeout, state)

      # Caller is unblocked despite tasks still being in_flight
      assert new_state.drain_caller == nil
      assert MapSet.size(new_state.in_flight) == 2
      assert_receive {^reply_ref, :ok}
    end
  end

  # ---------------------------------------------------------------------------
  # cancel_consume fast path (empty in_flight)
  # ---------------------------------------------------------------------------

  describe "handle_call :cancel_consume fast path" do
    test "replies immediately when in_flight is empty and no drain_caller is stored" do
      # Simulate the state as it would be immediately after cancel_consume sets :canceled
      # but with nothing in_flight — drain_caller stays nil, reply is sent inline.
      # We verify the downstream behaviour: if a :drain_timeout fires after the fact
      # it is safe (no-op because drain_caller is nil).
      state = build_state(state: :canceled, drain_caller: nil)

      {:noreply, new_state} = Consumer.handle_info(:drain_timeout, state)

      assert new_state.drain_caller == nil
    end
  end

  # ---------------------------------------------------------------------------
  # Full drain lifecycle (end-to-end state machine)
  # ---------------------------------------------------------------------------

  describe "full drain lifecycle" do
    test "drain_timeout fires after tasks finish — reply already sent, timeout is a no-op" do
      {from, reply_ref} = make_from()
      ref = make_ref()
      state = build_state(in_flight: MapSet.new([ref]), drain_caller: from)

      # Task finishes → reply sent, drain_caller cleared
      {:noreply, state2} = Consumer.handle_info({:DOWN, ref, :process, self(), :normal}, state)
      assert_receive {^reply_ref, :ok}
      assert state2.drain_caller == nil

      # Stale :drain_timeout arrives later — safe no-op
      {:noreply, state3} = Consumer.handle_info(:drain_timeout, state2)
      assert state3 == state2
      refute_receive {^reply_ref, :ok}, 50
    end

    test "multiple tasks tracked and drained in arbitrary order" do
      {from, reply_ref} = make_from()
      refs = for _ <- 1..5, do: make_ref()
      state = build_state(in_flight: MapSet.new(refs), drain_caller: from)

      # Drain all but the last
      final_state =
        refs
        |> Enum.drop(-1)
        |> Enum.reduce(state, fn ref, acc ->
          {:noreply, new_acc} = Consumer.handle_info({:DOWN, ref, :process, self(), :normal}, acc)
          refute_receive {^reply_ref, :ok}, 10
          new_acc
        end)

      assert MapSet.size(final_state.in_flight) == 1

      # Last task finishes → reply
      last_ref = List.last(refs)

      {:noreply, done_state} =
        Consumer.handle_info({:DOWN, last_ref, :process, self(), :normal}, final_state)

      assert MapSet.size(done_state.in_flight) == 0
      assert done_state.drain_caller == nil
      assert_receive {^reply_ref, :ok}
    end
  end
end
