defmodule WebWidget.Integration.ToolSnapshotTest do
  use ExUnit.Case, async: true

  alias WebWidget.Conversation.State
  alias WebWidget.Integration.Response

  test "streamed snapshots reach presentation state and match restored terminal evidence" do
    running = step("running")
    initial = State.new() |> apply_host(:message_create, %{body: ""})

    live =
      apply_host(initial, :message_step, %{tool_steps: [Map.put(running, "params", "private")]})

    assert [%{steps: [%{id: "lookup", kind: "tool_call", state: "started", sequence: 1}]}] =
             live.messages

    refute inspect(live) =~ "private"

    terminal = step("unknown") |> Map.put("duration_ms", 18)
    done = apply_host(live, :message_complete, %{body: "Answer", tool_steps: [terminal]})
    assert [%{steps: [%{state: "unknown", duration_ms: 18}]}] = done.messages
    assert apply_host(done, :message_step, %{tool_steps: [running]}) == done

    response = %{
      protocol_version: 2,
      type: :conversation_history,
      conversation_id: "chat",
      payload: %{
        messages: [
          %{
            message_id: "saved",
            position: 2,
            role: "assistant",
            content: "Answer",
            tool_steps: [terminal]
          }
        ]
      }
    }

    assert {:ok, encoded, [2]} = Response.history(response, "12")
    restored = State.apply_event(State.new(), encoded)
    assert hd(restored.messages).steps == hd(done.messages).steps
  end

  test "omission preserves snapshots, empty clears, and answer completion never invents tool success" do
    running =
      State.new()
      |> apply_host(:message_create, %{body: ""})
      |> apply_host(:message_step, %{tool_steps: [step("running")]})

    assert hd(apply_host(running, :message_edit, %{body: "text"}).messages).steps ==
             hd(running.messages).steps

    assert hd(apply_host(running, :message_step, %{tool_steps: []}).messages).steps == []

    assert [%{state: "unknown"}] =
             hd(apply_host(running, :message_complete, %{body: "done"}).messages).steps

    failed =
      apply_host(running, :message_failed, %{body: "partial", tool_steps: [step("failed")]})

    assert [%{state: "failed"}] = hd(failed.messages).steps
  end

  test "snapshots preserve invocation ordering, labels and terminal facts across stream updates" do
    first = Map.put(step("succeeded"), "label", "Lookup records")
    second = Map.merge(step("running"), %{"id" => "second", "sequence" => 2})

    state =
      State.new()
      |> apply_host(:message_create, %{body: ""})
      |> apply_host(:message_step, %{tool_steps: [second, first]})

    assert [%{id: "lookup", label: "Lookup records", state: "completed"}, %{id: "second"}] =
             hd(state.messages).steps

    stale = Map.put(first, "state", "running")
    state = apply_host(state, :message_step, %{tool_steps: [stale, second]})
    assert hd(hd(state.messages).steps).state == "completed"
  end

  test "invalid snapshots are rejected rather than entering public state" do
    for steps <- [
          nil,
          [%{}],
          [step("running"), step("running")],
          [Map.put(step("running"), "duration_ms", -1)],
          [Map.put(step("running"), "state", "completed")]
        ] do
      response = %{
        protocol_version: 2,
        type: :message_step,
        conversation_id: "chat",
        message_id: "transport",
        payload: %{tool_steps: steps}
      }

      assert {:error, :invalid_response} =
               Response.encode("response.message.step", response, "12")
    end
  end

  defp step(state),
    do: %{
      "id" => "lookup",
      "kind" => "tool",
      "name" => "lookup",
      "sequence" => 1,
      "state" => state
    }

  defp apply_host(state, type, payload) do
    response = %{
      protocol_version: 2,
      type: type,
      conversation_id: "chat",
      message_id: "transport",
      payload: payload
    }

    event = "response." <> (type |> Atom.to_string() |> String.replace("_", "."))
    assert {:ok, encoded} = Response.encode(event, response, "12")
    State.apply_event(state, encoded)
  end
end
