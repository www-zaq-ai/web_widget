defmodule WebWidget.Integration.Response do
  @moduledoc false
  alias WebWidget.Integration.{ContextError, Diagnostics}
  alias WebWidget.Protocol.Response, as: UIResponse

  @events %{
    user_message: "response.user_message",
    typing: "response.typing",
    message_create: "response.message.create",
    message_edit: "response.message.edit",
    message_step: "response.message.step",
    message_complete: "response.message.complete",
    message_failed: "response.message.failed",
    error: "response.error"
  }

  def validate_version(%{protocol_version: 2}), do: :ok

  def validate_version(response) when is_map(response),
    do: {:error, :unsupported_protocol_version}

  def validate_version(_), do: {:error, :invalid_response}

  def correlated?(%{protocol_version: 2, request_id: id}, id)
      when is_binary(id) and byte_size(id) in 1..255,
      do: String.valid?(id) and String.trim(id) != ""

  def correlated?(_, _), do: false

  def saved_user(
        %{
          payload: %{
            accepted: true,
            created: created,
            user_message:
              %{message_id: id, position: position, role: "user", content: content} = row
          }
        } = response,
        widget
      )
      when is_boolean(created) and is_integer(position) and position > 0 and is_binary(id) and
             is_binary(content) do
    with :ok <- validate_version(response),
         true <-
           is_nil(Map.get(response, :message_id)) and String.valid?(id) and
             byte_size(id) in 1..255 and String.valid?(content),
         {:ok, normalized} <-
           UIResponse.normalize(%{
             type: "response.conversation.history",
             widget_id: widget,
             conversation_id: response.conversation_id,
             payload: %{
               messages: [
                 history_message(Map.take(row, [:message_id, :role, :content, :provider_sent_at]))
               ]
             }
           }) do
      {:ok, normalized.payload.messages |> hd() |> Map.put(:position, position)}
    else
      _ -> {:error, :invalid_user_message}
    end
  rescue
    _ -> {:error, :invalid_user_message}
  end

  def saved_user(_, _), do: {:error, :invalid_user_message}

  def validate_command({:error, reason}, _request, _conversation, operation),
    do: ContextError.from_host(reason, operation)

  def validate_command(%{protocol_version: _} = response, request, conversation, operation) do
    with :ok <- validate_version(response),
         true <- correlated?(response, request),
         true <- command_conversation?(response, conversation) do
      command_status(response, operation)
    else
      {:error, :unsupported_protocol_version} = error -> error
      _ -> ContextError.invalid_response(operation)
    end
  end

  def validate_command(_, _request, _conversation, operation),
    do: ContextError.invalid_response(operation)

  defp command_conversation?(%{type: :error} = response, conversation),
    do: Map.get(response, :conversation_id) in [nil, conversation]

  defp command_conversation?(response, conversation),
    do: Map.get(response, :conversation_id) == conversation

  defp command_status(%{type: :error, payload: payload}, operation) when is_map(payload),
    do: ContextError.from_host(Map.get(payload, :code), operation)

  defp command_status(%{type: :error}, operation), do: ContextError.invalid_response(operation)
  defp command_status(_, _), do: :ok

  def encode(
        event,
        %{type: type, payload: payload, conversation_id: conversation} = response,
        widget_id
      )
      when is_map(payload) do
    with :ok <- validate_version(response),
         ^event <- Map.get(@events, type),
         {:ok, payload} <- payload(type, payload, Map.get(response, :message_id)),
         {:ok, normalized} <-
           UIResponse.normalize(%{
             type: event,
             widget_id: widget_id,
             conversation_id: conversation,
             payload: payload
           }) do
      {:ok, normalized}
    else
      {:error, :unsupported_protocol_version} = error -> error
      _ -> {:error, :invalid_response}
    end
  end

  def encode(_, _, _), do: {:error, :invalid_response}

  def history(response, widget_id) do
    Diagnostics.log(:history_received, response)

    with :ok <- validate_version(response),
         %{type: :conversation_history, payload: %{messages: messages}} <- response,
         true <- is_list(messages) and Enum.all?(messages, &is_map/1),
         {:ok, normalized} <-
           UIResponse.normalize(%{
             type: "response.conversation.history",
             widget_id: widget_id,
             conversation_id: response.conversation_id,
             payload: %{messages: Enum.map(messages, &history_message/1)}
           }) do
      {:ok, normalized, Enum.map(messages, &Map.get(&1, :position))}
    else
      {:error, :unsupported_protocol_version} = error -> error
      _ -> {:error, :invalid_history}
    end
  rescue
    _ -> {:error, :invalid_history}
  end

  def error_text(%{payload: %{code: :timeout}}),
    do:
      "The submission acknowledgement timed out. Its outcome is unknown. Reload known conversation history before trying again."

  def error_text(%{payload: %{outcome: :unknown}}),
    do: "Submission outcome is unknown. Restore the conversation before sending again."

  def error_text(%{payload: %{code: :acknowledgement_unavailable}}),
    do: "Submission outcome is unknown. Restore the conversation before sending again."

  def error_text(_), do: "Unable to complete this request."

  defp payload(type, %{body: body} = payload, id)
       when type in [:message_create, :message_edit, :message_complete] and is_binary(body),
       do: {:ok, with_tools(%{id: id, content: body}, payload)}

  defp payload(:typing, %{active: active}, _), do: {:ok, %{active: active}}

  defp payload(
         :message_step,
         %{kind: :activity, state: :running, step_id: step, label: label} = payload,
         id
       ),
       do:
         {:ok,
          with_tools(
            %{id: step, message_id: id, kind: "status", state: "updated", label: label},
            payload
          )}

  defp payload(:message_step, %{tool_steps: _} = payload, id),
    do: {:ok, with_tools(%{message_id: id}, payload)}

  defp payload(:message_failed, payload, id),
    do:
      {:ok,
       with_tools(
         %{message_id: id, code: "response_failed", message: failure_message(payload)},
         payload
       )}

  defp payload(:error, payload, _),
    do:
      {:ok,
       %{
         request_type: "message.create",
         code: "request_failed",
         message: error_text(%{payload: payload})
       }}

  defp payload(_, _, _), do: :error

  defp failure_message(%{body: body}) when is_binary(body) do
    if String.valid?(body) and String.trim(body) != "",
      do: body,
      else: "Unable to complete this response."
  end

  defp failure_message(_), do: "Unable to complete this response."

  defp history_message(message) when is_map(message) do
    message
    |> Map.take([:id, :role, :content, :timestamp])
    |> Map.put(:id, to_string(Map.get(message, :message_id, Map.get(message, :id))))
    |> history_timestamp(Map.get(message, :provider_sent_at))
    |> with_tools(message)
  end

  defp history_message(_), do: %{}

  defp with_tools(output, source), do: Map.merge(output, Map.take(source, [:tool_steps]))

  defp history_timestamp(message, nil), do: message
  defp history_timestamp(message, time), do: Map.put(message, :timestamp, time)
end
