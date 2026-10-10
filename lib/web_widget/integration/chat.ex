defmodule WebWidget.Integration.Chat do
  @moduledoc false
  alias WebWidget.{Adapter, Runtime}
  alias WebWidget.Conversation.State
  alias WebWidget.Integration.{Diagnostics, InitClaims, Response}

  def open(widget_id, params, page_id \\ nil, requested_id \\ nil, expected_sender \\ nil)

  def open(
        widget_id,
        %{"identity_token" => proof} = params,
        page_id,
        requested_id,
        expected_sender
      )
      when map_size(params) == 1 do
    with {:ok, session} <- Runtime.authenticate(widget_id, proof, page_id),
         true <- expected_sender in [nil, session.sender_id],
         {:ok, monitor} <- Runtime.monitor(session) do
      case subscribe_and_initialize(session, requested_id, id(), session.init) do
        {:ok, chat} ->
          {:ok, Map.put(chat, :monitor, monitor)}

        error ->
          Process.demonitor(monitor, [:flush])
          error
      end
    else
      {:error, :store_unavailable} -> {:error, :store_unavailable}
      {:error, :backend_revoked} -> {:error, :backend_revoked}
      _ -> {:error, "Unable to authenticate this widget session."}
    end
  end

  def open(_, _, _, _, _), do: {:error, "Initialization accepts only identity_token."}

  defp subscribe_and_initialize(session, requested, request, params) do
    with {:ok, subscription} <- Runtime.subscribe(session) do
      case Runtime.subscribe_revocation(session) do
        {:ok, revocation} ->
          initialize_subscribed(session, requested, request, params, subscription, revocation)

        _ ->
          Adapter.unsubscribe(subscription)
          {:error, "Unable to subscribe to widget revocation."}
      end
    end
  end

  defp initialize_subscribed(session, requested, request, params, subscription, revocation) do
    response =
      Runtime.dispatch(
        %{
          type: "widget.init",
          request_id: request,
          conversation_id: requested,
          params: %{}
        },
        session
      )

    with true <- Response.correlated?(response, request),
         %{type: :widget_initialized, conversation_id: ^requested, payload: %{created: false}} <-
           response,
         true <- Runtime.authorized?(session),
         {:ok, state, positions} <- history(session, requested),
         true <- Runtime.authorized?(session) do
      generation = make_ref()
      timer = expiration_timer(session, generation)

      {:ok,
       %{
         session: session,
         subscription: subscription,
         revocation_subscription: revocation,
         timer: timer,
         auth_generation: generation,
         conversation_id: requested,
         active: nil,
         restore_on_terminal: not is_nil(requested),
         state: state,
         positions: positions,
         persisted_refs: %{},
         outcome: nil,
         prompt_context: params.prompt_context,
         blocked: false
       }}
    else
      _ ->
        Adapter.unsubscribe(subscription)
        Adapter.unsubscribe(revocation)
        {:error, "Unable to initialize or restore this conversation."}
    end
  end

  def renew(chat, proof) do
    with {:ok, session} <- Runtime.renew(chat.session, proof) do
      generation = make_ref()
      timer = expiration_timer(session, generation)
      Process.cancel_timer(chat.timer)
      {:ok, %{chat | session: session, timer: timer, auth_generation: generation}}
    end
  end

  def update_context(chat, attrs) when is_map(attrs) do
    with {:ok, context} <-
           InitClaims.normalize(Map.put(attrs, :user_id, chat.session.sender_id)),
         true <- is_nil(chat.active),
         true <- Runtime.authorized?(chat.session) do
      requested = context.conversation_id

      cond do
        is_nil(requested) and is_nil(chat.conversation_id) and not chat.blocked ->
          {:ok, %{chat | prompt_context: context.prompt_context}}

        is_binary(requested) and requested == chat.conversation_id and not chat.blocked ->
          {:ok, chat}

        is_binary(requested) ->
          resume(chat, requested)

        true ->
          {:error, :invalid_context}
      end
    else
      _ -> {:error, :invalid_context}
    end
  end

  def update_context(_, _), do: {:error, :invalid_context}

  defp resume(chat, requested) do
    request = id()

    response =
      Runtime.dispatch(
        %{type: "widget.init", request_id: request, conversation_id: requested, params: %{}},
        chat.session
      )

    with true <- Response.correlated?(response, request),
         %{type: :widget_initialized, conversation_id: ^requested, payload: %{created: false}} <-
           response,
         true <- Runtime.authorized?(chat.session),
         {:ok, state, positions} <- history(chat.session, requested),
         true <- Runtime.authorized?(chat.session) do
      {:ok,
       %{
         chat
         | conversation_id: requested,
           state: state,
           positions: positions,
           prompt_context: nil,
           blocked: false,
           outcome: nil,
           persisted_refs: %{}
       }}
    else
      _ -> {:error, :invalid_context}
    end
  end

  def authorization_metadata(chat) do
    expiry = chat.session.expires_at

    lead = chat.session.refresh_lead_seconds

    %{
      expires_at: expiry,
      refresh_at: expiry - lead,
      server_time: System.system_time(:second),
      credential_id: chat.session.binding_claims && chat.session.binding_claims.jti
    }
  end

  defp expiration_timer(session, generation) do
    Process.send_after(
      self(),
      {:widget_session_expired, session.topic, generation},
      max(0, session.expires_at * 1000 - System.system_time(:millisecond))
    )
  end

  def submit(%{active: nil, blocked: false} = chat, text) do
    request = id()
    message = %{id: request, content: text, timestamp: DateTime.to_iso8601(DateTime.utc_now())}

    result =
      Runtime.dispatch(
        %{
          type: "message.create",
          request_id: request,
          conversation_id: chat.conversation_id,
          message: Map.take(message, [:id, :content]),
          timestamp: DateTime.utc_now(),
          channel: "web_widget",
          mode: :async,
          prompt_context: chat.prompt_context
        },
        chat.session
      )

    case result do
      {:ok, receipt} -> accept(chat, receipt, request, message)
      error -> {:error, %{chat | blocked: true, outcome: :unknown}, Response.error_text(error)}
    end
  end

  def submit(chat, _),
    do: {:error, chat, "Wait for the current response or restore the conversation."}

  defp accept(chat, receipt, request, message) do
    with true <- Response.correlated?(receipt, request),
         %{conversation_id: conversation, message_id: transport, payload: %{accepted: true}} <-
           receipt,
         true <- identifier?(conversation) and identifier?(transport),
         true <- valid_receipt?(chat.conversation_id, receipt),
         true <- Runtime.authorized?(chat.session) do
      {:ok,
       %{
         chat
         | conversation_id: conversation,
           prompt_context: nil,
           active: %{request_id: request, message_id: transport, created: false},
           restore_on_terminal: false,
           state: State.submit(chat.state, message)
       }}
    else
      _ ->
        {:error, %{chat | blocked: true, outcome: :unknown},
         "Message outcome is unknown. Restore the conversation before sending again."}
    end
  end

  def receive_response(%{active: active} = chat, event, response) when not is_nil(active) do
    with true <- Runtime.authorized?(chat.session),
         true <- Response.correlated?(response, active.request_id),
         %{conversation_id: conversation, message_id: transport, type: type, payload: payload}
         when is_map(payload) <- response,
         true <- conversation == chat.conversation_id and transport == active.message_id,
         true <- active.created or type in [:typing, :message_create, :error],
         {:ok, encoded} <- Response.encode(event, response, chat.session.widget_id) do
      Diagnostics.log(:applied, response)
      terminal = response.type in [:message_complete, :message_failed, :error]

      active =
        if terminal,
          do: nil,
          else: %{active | created: active.created or response.type == :message_create}

      %{
        chat
        | state: State.apply_event(chat.state, encoded),
          active: active,
          persisted_refs: retain_refs(chat.persisted_refs, response),
          outcome: Map.get(response.payload, :outcome, chat.outcome),
          blocked: chat.blocked or response.type == :error
      }
    else
      _ ->
        Diagnostics.log(:ignored_validation_or_encoding, response)
        chat
    end
  end

  def receive_response(
        %{active: nil, restore_on_terminal: true, conversation_id: conversation} = chat,
        event,
        %{protocol_version: 1, type: :message_complete, conversation_id: conversation} = response
      ) do
    with true <- Runtime.authorized?(chat.session),
         true <- identifier?(response.request_id) and identifier?(response.message_id),
         {:ok, _} <- Response.encode(event, response, chat.session.widget_id),
         {:ok, state, positions} <- history(chat.session, conversation),
         true <- Runtime.authorized?(chat.session) do
      %{chat | state: state, positions: positions, restore_on_terminal: false}
    else
      _ -> chat
    end
  end

  def receive_response(chat, _, response) do
    Diagnostics.log(:ignored_no_active_request, response)
    chat
  end

  defp retain_refs(refs, %{message_id: id, payload: payload}) do
    public = Map.take(payload, [:assistant_message_id, :user_message_id])
    if map_size(public) == 0, do: refs, else: Map.put(refs, id, public)
  end

  def close(chat) do
    Adapter.unsubscribe(chat.subscription)
    Adapter.unsubscribe(chat.revocation_subscription)
    Process.demonitor(chat.monitor, [:flush])
    Process.cancel_timer(chat.timer)
    :ok
  end

  defp history(_session, nil), do: {:ok, State.new(), []}

  defp history(session, conversation) do
    request = id()

    response =
      Runtime.dispatch(
        %{
          type: "conversation.history.request",
          request_id: request,
          conversation_id: conversation,
          params: %{limit: 50}
        },
        session
      )

    with true <- Response.correlated?(response, request),
         %{conversation_id: ^conversation} <- response,
         {:ok, encoded, positions} <- Response.history(response, session.widget_id) do
      {:ok, State.apply_event(State.new(), encoded), positions}
    else
      _ -> {:error, :history_unavailable}
    end
  end

  defp valid_receipt?(nil, %{type: :conversation_created, payload: %{created: true}}), do: true

  defp valid_receipt?(id, %{type: :status, conversation_id: id, payload: %{created: false}})
       when not is_nil(id), do: true

  defp valid_receipt?(_, _), do: false

  defp identifier?(id),
    do:
      is_binary(id) and String.valid?(id) and
        String.trim(id) != "" and byte_size(id) <= 255

  defp id, do: Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
end
