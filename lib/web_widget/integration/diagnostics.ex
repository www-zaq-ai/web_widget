defmodule WebWidget.Integration.Diagnostics do
  @moduledoc false
  require Logger

  @fields ~w(active body kind state step_id label content messages metadata trace tool_calls tool_call arguments result response)a
  @types ~w(typing message_create message_edit message_step message_complete message_failed error conversation_history)a
  @kinds ~w(activity status reasoning tool_call tool_result)a
  @states ~w(running started updated completed failed)a

  def log(outcome, response) do
    case WebWidget.Configuration.fetch() do
      {:ok, %{response_diagnostics: true}} ->
        Logger.info(fn ->
          "[web_widget.response] " <>
            inspect(%{outcome: outcome, response: response},
              pretty: true,
              limit: :infinity,
              printable_limit: :infinity,
              structs: false
            )
        end)

      {:ok, %{response_diagnostics: :summary}} ->
        Logger.info(fn ->
          "[web_widget.response] " <> inspect(Map.put(summary(response), :outcome, outcome))
        end)

      _ ->
        :ok
    end

    :ok
  end

  def summary(response) do
    payload = value(response, :payload)
    messages = value(payload, :messages)

    %{
      request_ref: reference(value(response, :request_id)),
      type: enum(value(response, :type), @types),
      kind: enum(value(payload, :kind), @kinds),
      state: enum(value(payload, :state), @states),
      active: boolean(value(payload, :active)),
      payload_fields: fields(payload),
      metadata_fields: fields(value(payload, :metadata)),
      tool_call_count: count(value(payload, :tool_calls)),
      trace_count: count(value(payload, :trace)),
      history_count: count(messages),
      history_fields: history_fields(messages)
    }
  end

  defp value(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp value(_, _), do: nil

  defp fields(map) when is_map(map),
    do: Enum.filter(@fields, &(Map.has_key?(map, &1) or Map.has_key?(map, Atom.to_string(&1))))

  defp fields(_), do: []

  defp reference(value) when is_binary(value),
    do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower) |> binary_part(0, 12)

  defp reference(_), do: nil
  defp count(value) when is_list(value), do: length(value)
  defp count(_), do: nil
  defp boolean(value) when is_boolean(value), do: value
  defp boolean(_), do: nil
  defp enum(nil, _), do: nil

  defp enum(value, allowed),
    do: Enum.find(allowed, :unknown, &(value == &1 or value == Atom.to_string(&1)))

  defp history_fields(messages) when is_list(messages),
    do: messages |> Enum.flat_map(&fields/1) |> Enum.uniq() |> Enum.sort()

  defp history_fields(_), do: []
end
