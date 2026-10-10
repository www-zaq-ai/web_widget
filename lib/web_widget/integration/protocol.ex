defmodule WebWidget.Integration.Protocol do
  @moduledoc """
  Translates internal widget requests through host-supplied shared constructors.

  Hooks and verifier configuration are server-owned. Request maps never supply
  identity, capabilities, constructors or destinations. Results retain the host's
  command/acceptance/error shapes; browser response encoding belongs to LiveView.
  """

  alias WebWidget.Integration.{InitClaims, Session}

  @enforce_keys [:hooks, :pubsub_server, :identity_verifier]
  defstruct @enforce_keys ++
              [
                control_key: nil,
                control_issuer: nil,
                control_audience: nil,
                identity_source: :unresolved
              ]

  @constructors [message: 1, command: 1, context: 2, delivery: 1, response: 1]
  @events %{
    typing: "response.typing",
    message_create: "response.message.create",
    message_edit: "response.message.edit",
    message_step: "response.message.step",
    message_complete: "response.message.complete",
    message_failed: "response.message.failed",
    error: "response.error"
  }
  @command_fields [:type, :request_id, :conversation_id, :params]
  @message_fields [
    :type,
    :request_id,
    :conversation_id,
    :message,
    :timestamp,
    :channel,
    :mode,
    :prompt_context
  ]

  @doc false
  def new(hooks, opts) when is_map(hooks) and is_list(opts) do
    with true <- Keyword.keyword?(opts),
         server when is_atom(server) and server not in [nil, true, false] <-
           Keyword.get(opts, :pubsub_server),
         verifier <- Keyword.get(opts, :identity_verifier),
         true <- valid_mfa?(verifier, 2),
         true <- valid_mfa?(Map.get(hooks, :sink_mfa), 2),
         true <- Enum.all?(@constructors, &valid_constructor?(hooks, &1)) do
      {:ok,
       %__MODULE__{
         hooks: Map.take(hooks, [:widget_id, :sink_mfa | Keyword.keys(@constructors)]),
         pubsub_server: server,
         identity_verifier: verifier,
         control_key: Keyword.get(opts, :control_key),
         control_issuer: Keyword.get(opts, :control_issuer),
         control_audience: Keyword.get(opts, :control_audience),
         identity_source: Keyword.get(opts, :identity_source, :unresolved)
       }}
    else
      _ -> {:error, :invalid_integration_config}
    end
  end

  def new(_, _), do: {:error, :invalid_integration_config}

  @doc false
  def authenticate(integration, proof, runtime_ref, page_id \\ nil) do
    authenticate(integration, proof, runtime_ref, page_id, nil)
  end

  def authenticate(integration, proof, runtime_ref, page_id, expected_sender) do
    id = integration.hooks.widget_id
    scope = %{widget_id: Integer.to_string(id), channel_config_id: id, page_id: page_id}

    verify_scope =
      if is_binary(expected_sender),
        do: Map.put(scope, :expected_sender, expected_sender),
        else: scope

    with {:ok, infrastructure} <- WebWidget.Configuration.fetch(),
         {:ok, %{sender_id: sender, expires_at: expiry} = verified} <-
           invoke(integration.identity_verifier, [proof, verify_scope]),
         true <- identifier?(sender),
         true <- expected_sender in [nil, sender],
         true <- is_integer(expiry) and expiry > System.system_time(:second),
         {:ok, init} <- InitClaims.normalize(%{user_id: String.trim(sender)}),
         true <- init.user_id == String.trim(sender) do
      {:ok,
       struct!(
         Session,
         Map.merge(scope, %{
           sender_id: String.trim(sender),
           expires_at: expiry,
           refresh_lead_seconds: infrastructure.authentication[:refresh_lead_seconds],
           init: init,
           binding_claims: Map.get(verified, :binding_claims),
           page_id: Map.get(verified, :page_id),
           runtime_ref: runtime_ref,
           owner: self(),
           topic: session_topic(Map.get(verified, :page_id))
         })
       )}
    else
      {:error, :store_unavailable} -> {:error, :store_unavailable}
      {:error, :backend_revoked} -> {:error, :backend_revoked}
      _ -> {:error, :unauthorized}
    end
  rescue
    _ -> {:error, :unauthorized}
  catch
    _, _ -> {:error, :unauthorized}
  end

  defp session_topic(page_id) when is_binary(page_id) and byte_size(page_id) > 0,
    do: "web_widget:session:" <> page_id

  defp session_topic(_),
    do:
      "web_widget:session:" <>
        Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

  @doc false
  def dispatch(integration, event, session) do
    hooks = integration.hooks

    with {:ok, payload} <- payload(hooks, event),
         {:ok, delivery} <-
           hooks.delivery.new(%{
             consumer: :widget,
             channel_config_id: hooks.widget_id,
             topic: session.topic,
             events: @events
           }),
         {:ok, context} <-
           hooks.context.new(nil,
             consumer: :widget,
             channel_config_id: hooks.widget_id,
             sender_id: session.sender_id,
             delivery: delivery
           ) do
      invoke(hooks.sink_mfa, [payload, [context: context]])
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  defp payload(hooks, %{type: type} = event)
       when type in ["widget.init", "conversation.history.request"] do
    with :ok <- fields(event, @command_fields),
         :ok <- conversation_id(event, type == "conversation.history.request") do
      attrs = Map.take(event, [:request_id, :conversation_id, :params])
      command = if type == "widget.init", do: :conversation_init, else: :conversation_history
      hooks.command.new(Map.put(attrs, :type, command))
    end
  end

  defp payload(
         hooks,
         %{type: "message.create", message: %{id: id, content: content} = message} = event
       ) do
    with :ok <- fields(event, @message_fields),
         :ok <- fields(message, [:id, :content]),
         :ok <- conversation_id(event, false) do
      attrs =
        event
        |> Map.take([:request_id, :conversation_id, :timestamp, :channel, :mode])
        |> Map.merge(%{message_id: id, content: content})
        |> first_message_context(event)

      hooks.message.new(attrs)
    end
  end

  defp payload(_, %{type: "message.create"}), do: {:error, :invalid_message}
  defp payload(_, _), do: {:error, :unsupported_event}

  defp first_message_context(attrs, %{conversation_id: id}) when not is_nil(id), do: attrs

  defp first_message_context(attrs, event),
    do: Map.merge(attrs, Map.take(event, [:prompt_context]))

  defp fields(map, allowed) do
    if Enum.all?(Map.keys(map), &(&1 in allowed)),
      do: :ok,
      else: {:error, :unknown_fields}
  end

  defp conversation_id(event, required?) do
    case Map.get(event, :conversation_id) do
      nil when not required? -> :ok
      value -> if identifier?(value), do: :ok, else: {:error, :invalid_conversation_id}
    end
  end

  defp identifier?(value) when is_binary(value),
    do: String.valid?(value) and String.trim(value) != "" and byte_size(String.trim(value)) <= 255

  defp identifier?(_), do: false

  defp valid_constructor?(hooks, {key, arity}) do
    module = Map.get(hooks, key)
    is_atom(module) and Code.ensure_loaded?(module) and function_exported?(module, :new, arity)
  end

  defp valid_mfa?({module, function, args}, extra)
       when is_atom(module) and is_atom(function) and is_list(args),
       do:
         Code.ensure_loaded?(module) and
           function_exported?(module, function, length(args) + extra)

  defp valid_mfa?(_, _), do: false

  defp invoke({module, function, args}, suffix), do: apply(module, function, args ++ suffix)
end
