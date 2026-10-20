defmodule WebWidget.Conversation.State do
  @moduledoc "Pure presentation state shared by real and mock host responses."

  def new, do: %{messages: [], pending_reply: nil, typing: false, error: nil}

  def submit(state, message) do
    %{
      state
      | messages: state.messages ++ [Map.put(message, :role, "user")],
        pending_reply: %{request_id: message.id, id: nil},
        error: nil,
        typing: false
    }
  end

  def acknowledge(%{pending_reply: %{request_id: request}} = state, request),
    do: %{state | pending_reply: nil}

  def acknowledge(state, _), do: state

  def submission_error(state, error), do: %{state | pending_reply: nil, error: error}

  def apply_event(state, %{type: "response.message.create", payload: payload}) do
    if Enum.any?(state.messages, &(&1.id == payload.id)) do
      state
    else
      message = %{
        id: payload.id,
        role: "assistant",
        content: payload.content,
        timestamp: Map.get(payload, :timestamp, DateTime.to_iso8601(DateTime.utc_now())),
        status: "running",
        steps: [],
        error: nil
      }

      pending =
        case state.pending_reply do
          %{id: nil} = pending -> %{pending | id: payload.id}
          pending -> pending
        end

      %{state | messages: state.messages ++ [message], pending_reply: pending}
    end
  end

  def apply_event(state, %{type: "response.message.edit", payload: payload}) do
    update_message(state, payload.id, fn message ->
      %{message | content: payload.content, steps: snapshot_steps(message.steps, payload)}
    end)
  end

  def apply_event(state, %{type: "response.message.step", payload: %{steps: _} = payload}) do
    update_message(state, payload.message_id, fn message ->
      %{message | steps: snapshot_steps(message.steps, payload)}
    end)
  end

  def apply_event(state, %{type: "response.message.step", payload: step}) do
    update_message(state, step.message_id, fn message ->
      previous = Enum.find(message.steps, &(&1.id == step.id))

      steps =
        cond do
          previous && previous.state in ["completed", "failed"] -> message.steps
          previous -> replace_step(message.steps, step)
          true -> message.steps ++ [step]
        end

      %{message | steps: steps}
    end)
  end

  def apply_event(state, %{type: "response.message.complete", payload: payload}) do
    state
    |> update_message(payload.id, fn message ->
      %{
        message
        | content: payload.content,
          status: "complete",
          steps: finish_steps(snapshot_steps(message.steps, payload), "completed")
      }
    end)
    |> finish(payload.id)
  end

  def apply_event(state, %{type: "response.message.failed", payload: payload}) do
    state
    |> update_message(payload.message_id, fn message ->
      %{message | steps: snapshot_steps(message.steps, payload)}
    end)
    |> fail_message(payload.message_id, payload.message)
    |> finish(payload.message_id)
  end

  def apply_event(state, %{type: "response.typing", payload: %{active: active}}),
    do: %{state | typing: active and state.pending_reply != nil}

  def apply_event(%{pending_reply: nil} = state, %{
        type: "response.conversation.history",
        payload: %{messages: messages}
      }) do
    %{
      state
      | messages:
          Enum.map(
            messages,
            &Map.merge(&1, %{status: "complete", steps: Map.get(&1, :steps, []), error: nil})
          ),
        error: nil
    }
  end

  def apply_event(state, %{type: "response.error", payload: payload}) do
    if state.pending_reply do
      state =
        if state.pending_reply.id do
          fail_message(state, state.pending_reply.id, payload.message)
        else
          state
        end

      %{state | pending_reply: nil, typing: false, error: payload.message}
    else
      state
    end
  end

  def apply_event(state, _), do: state

  defp replace_step(steps, step),
    do: Enum.map(steps, &if(&1.id == step.id, do: step, else: &1))

  defp fail_message(state, id, error) do
    update_message(state, id, fn message ->
      %{message | status: "failed", error: error, steps: finish_steps(message.steps, "failed")}
    end)
  end

  defp update_message(state, id, fun) do
    %{
      state
      | messages:
          Enum.map(state.messages, fn
            %{id: ^id, role: "assistant", status: "running"} = message -> fun.(message)
            message -> message
          end)
    }
  end

  defp finish(%{pending_reply: %{id: id}} = state, id),
    do: %{state | pending_reply: nil, typing: false}

  defp finish(state, _id), do: state

  defp snapshot_steps(previous, %{steps: steps}) do
    tools = Enum.filter(previous, &(&1.kind in ["tool_call", "tool_result"]))
    settled = Map.new(tools, &{&1.id, &1})

    steps =
      Enum.map(steps, fn step ->
        case Map.get(settled, step.id) do
          %{state: state} = old
          when state in ["completed", "failed", "unknown"] and state != step.state ->
            old

          _ ->
            step
        end
      end)

    Enum.reject(previous, &(&1.kind in ["tool_call", "tool_result"])) ++ steps
  end

  defp snapshot_steps(previous, _payload), do: previous

  defp finish_steps(steps, state),
    do:
      Enum.map(steps, fn step ->
        cond do
          step.state not in ["started", "updated"] ->
            step

          step.kind in ["tool_call", "tool_result"] and Map.has_key?(step, :sequence) ->
            %{step | state: "unknown"}

          true ->
            %{step | state: state}
        end
      end)
end
