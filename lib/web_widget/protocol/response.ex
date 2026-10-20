defmodule WebWidget.Protocol.Response do
  @moduledoc "Validates host response maps and discards fields outside the public contract."

  import WebWidget.Protocol.Validation, only: [nonblank?: 1]

  @tool_states %{
    "running" => "started",
    "succeeded" => "completed",
    "failed" => "failed",
    "unknown" => "unknown"
  }

  def normalize(%{type: type, widget_id: widget, conversation_id: conversation} = event) do
    with true <- nonblank?(widget) and nonblank?(conversation),
         {:ok, payload} <- payload(type, Map.get(event, :payload), event) do
      {:ok, Map.merge(%{type: type, widget_id: widget, conversation_id: conversation}, payload)}
    else
      _ -> {:error, :invalid_response}
    end
  end

  def normalize(_), do: {:error, :invalid_response}

  defp payload("response.widget.initialized", _, %{user_id: user}) do
    if nonblank?(user), do: {:ok, %{user_id: user}}, else: :error
  end

  defp payload("response.conversation.created", _, _), do: {:ok, %{}}

  defp payload(type, %{id: id, content: content} = message, _)
       when type in [
              "response.message.create",
              "response.message.edit",
              "response.message.complete"
            ] do
    with true <- nonblank?(id) and is_binary(content),
         {:ok, timestamp} <- timestamp(message),
         {:ok, tools} <- tool_snapshot(message) do
      {:ok, %{payload: %{id: id, content: content} |> Map.merge(timestamp) |> Map.merge(tools)}}
    else
      _ -> :error
    end
  end

  defp payload(
         "response.message.step",
         %{message_id: id, tool_steps: _} = payload,
         _
       ) do
    with true <- nonblank?(id), {:ok, tools} <- tool_snapshot(payload) do
      {:ok, %{payload: Map.put(tools, :message_id, id)}}
    else
      _ -> :error
    end
  end

  defp payload(
         "response.message.step",
         %{id: id, message_id: message_id, kind: kind, state: state, label: label} = step,
         _
       ) do
    content = Map.get(step, :content)
    metadata = Map.get(step, :metadata, %{})

    if nonblank?(id) and nonblank?(message_id) and nonblank?(label) and
         kind in ["reasoning", "tool_call", "tool_result", "status"] and
         state in ["started", "updated", "completed", "failed"] and
         (is_nil(content) or is_binary(content)) and is_map(metadata) do
      {:ok,
       %{
         payload:
           Map.take(step, [:id, :message_id, :kind, :state, :label]) |> Map.put(:content, content)
       }}
    else
      :error
    end
  end

  defp payload(
         "response.message.failed",
         %{message_id: id, code: code, message: message} = payload,
         _
       ) do
    with true <- nonblank?(id) and nonblank?(code) and nonblank?(message),
         {:ok, tools} <- tool_snapshot(payload) do
      {:ok, %{payload: Map.merge(%{message_id: id, code: code, message: message}, tools)}}
    else
      _ -> :error
    end
  end

  defp payload("response.error", %{request_type: request, code: code, message: message}, _) do
    if request in [
         "widget.init",
         "message.create",
         "message.edit",
         "conversation.history.request"
       ] and
         nonblank?(code) and nonblank?(message),
       do: {:ok, %{payload: %{request_type: request, code: code, message: message}}},
       else: :error
  end

  defp payload("response.typing", %{active: active}, _) when is_boolean(active),
    do: {:ok, %{payload: %{active: active}}}

  defp payload("response.conversation.history", %{messages: messages} = payload, _) do
    with {:ok, messages} <- history_messages(messages),
         {:ok, conversations} <- conversations(Map.get(payload, :conversations, [])) do
      {:ok, %{payload: %{messages: messages, conversations: conversations}}}
    else
      _ -> :error
    end
  end

  defp payload(_, _, _), do: :error

  defp history_messages(messages), do: normalize_list(messages, &history_message/1)

  defp history_message(%{id: id, role: role, content: content} = message) do
    with true <- nonblank?(id) and role in ["user", "assistant"] and is_binary(content),
         {:ok, timestamp} <- timestamp(message),
         {:ok, tools} <- tool_snapshot(message) do
      {:ok,
       message |> Map.take([:id, :role, :content]) |> Map.merge(timestamp) |> Map.merge(tools)}
    else
      _ -> :error
    end
  end

  defp history_message(_), do: :error

  defp conversations(conversations), do: normalize_list(conversations, &conversation/1)

  defp conversation(%{id: id, title: title, messages: messages}) do
    with true <- nonblank?(id) and nonblank?(title),
         {:ok, messages} <- history_messages(messages) do
      {:ok, %{id: id, title: title, messages: messages}}
    else
      _ -> :error
    end
  end

  defp conversation(_), do: :error

  defp normalize_list(items, normalize) when is_list(items) do
    result =
      Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
        case normalize.(item) do
          {:ok, item} -> {:cont, {:ok, [item | acc]}}
          :error -> {:halt, :error}
        end
      end)

    case result do
      {:ok, items} -> if unique_ids?(items), do: {:ok, Enum.reverse(items)}, else: :error
      _ -> :error
    end
  end

  defp normalize_list(_, _), do: :error

  defp unique_ids?(items), do: length(Enum.uniq_by(items, & &1.id)) == length(items)

  defp tool_snapshot(%{tool_steps: steps}) do
    case normalize_list(steps, &tool_step/1) do
      {:ok, steps} -> {:ok, %{steps: Enum.sort_by(steps, & &1.sequence)}}
      _ -> :error
    end
  end

  defp tool_snapshot(_), do: {:ok, %{}}

  defp tool_step(
         %{"id" => id, "kind" => "tool", "name" => name, "sequence" => sequence, "state" => state} =
           step
       ) do
    duration = Map.get(step, "duration_ms")
    label = Map.get(step, "label", name)

    with true <- Enum.all?([id, name, label], &public_tool_text?/1),
         true <- is_integer(sequence) and sequence > 0,
         {:ok, state} <- Map.fetch(@tool_states, state),
         true <- valid_duration?(duration) do
      public = %{id: id, kind: "tool_call", label: label, sequence: sequence, state: state}
      {:ok, if(is_nil(duration), do: public, else: Map.put(public, :duration_ms, duration))}
    else
      _ -> :error
    end
  end

  defp tool_step(_), do: :error

  defp public_tool_text?(value),
    do: nonblank?(value) and byte_size(value) <= 256 and String.valid?(value)

  defp valid_duration?(nil), do: true
  defp valid_duration?(value), do: is_integer(value) and value >= 0

  defp timestamp(%{timestamp: %DateTime{} = time}),
    do: {:ok, %{timestamp: DateTime.to_iso8601(time)}}

  defp timestamp(%{timestamp: time}) when is_binary(time) do
    case DateTime.from_iso8601(time) do
      {:ok, parsed, _} -> {:ok, %{timestamp: DateTime.to_iso8601(parsed)}}
      _ -> :error
    end
  end

  defp timestamp(%{timestamp: _}), do: :error
  defp timestamp(_), do: {:ok, %{}}
end
