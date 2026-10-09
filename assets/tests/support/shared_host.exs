Code.require_file("test/support/integration/chat_host.ex")

defmodule WebWidget.E2ESharedHost do
  @moduledoc false
  @requests WebWidget.E2ESharedHost.Requests
  def key, do: "e2e-only-connector-key-never-installed-in-production-420"

  def start do
    {:ok, _} = Supervisor.start_child(WebWidget.Supervisor, %{
      id: @requests,
      start: {Agent, :start_link, [fn -> %{} end, [name: @requests]]}
    })
    host = WebWidget.TestIntegration.ChatHost
    hooks = %{widget_id: 420, display_name: "Shared protocol assistant",
      allowed_domains: ["http://127.0.0.1:4019"], message: host, command: host,
      response: host, context: host, delivery: host,
      sink_mfa: {__MODULE__, :receive_request, [self()]}}
    {:ok, {spec, []}} = WebWidget.Integration.RuntimeBuilder.build(
      %{id: 420, provider: "web_widget", token: key(),
        settings: %{"identity_issuer" => "e2e-parent", "identity_audience" => "e2e-widget"}}, hooks,
      pubsub_server: WebWidget.PubSub, identity_verifier: :connector_key)
    Supervisor.start_child(WebWidget.Supervisor, spec)
  end

  def requests(user), do: Agent.get(@requests, &Map.get(&1, {:requests, user}, []))

  def receive_request(test, request, context: context) do
    Agent.update(@requests, &Map.update(&1, {:requests, context.sender_id}, [request], fn requests -> requests ++ [request] end))
    if Map.has_key?(request, :content) do
      key = {context.sender_id, Map.get(request, :content)}
      Agent.update(@requests, &Map.update(&1, key, 1, fn count -> count + 1 end))
    end
    case request do
      %{content: "reconnect " <> _} ->
        conversation = request.conversation_id || "e2e-" <> Ecto.UUID.generate()
        saved = Agent.get(@requests, &Map.get(&1, {:conversation, context.sender_id}, %{id: conversation, messages: []}))
        answer = "Answer to " <> request.content
        messages = saved.messages ++ [
          %{message_id: Ecto.UUID.generate(), position: length(saved.messages) + 1, role: "user", content: request.content, provider_sent_at: nil},
          %{message_id: Ecto.UUID.generate(), position: length(saved.messages) + 2, role: "assistant", content: answer, provider_sent_at: nil}]
        Agent.update(@requests, &Map.put(&1, {:conversation, context.sender_id}, %{id: conversation, messages: messages}))
        host = WebWidget.TestIntegration.ChatHost
        receipt = host.response(request, if(request.conversation_id, do: :status, else: :conversation_created), conversation,
          %{accepted: true, created: is_nil(request.conversation_id)})
        host.publish(context, %{receipt | type: :message_create, payload: %{body: ""}})
        host.publish(context, %{receipt | type: :message_complete, payload: %{body: answer}})
        {:ok, receipt}

      %{type: type, conversation_id: "e2e-" <> _ = conversation} when type in [:conversation_init, :conversation_history] ->
        saved = Agent.get(@requests, &Map.get(&1, {:conversation, context.sender_id}))
        host = WebWidget.TestIntegration.ChatHost
        case saved do
          %{id: ^conversation, messages: messages} ->
            if type == :conversation_init,
              do: host.response(request, :widget_initialized, conversation, %{created: false}),
              else: host.response(request, :conversation_history, conversation, %{messages: messages})
          _ -> host.response(request, :error, conversation, %{code: :conversation_not_found})
        end

      %{type: :conversation_history} ->
        case Agent.get(@requests, &Map.get(&1, {:held_stream, context.sender_id})) do
          nil -> receive_default(test, request, context)
          status -> held_history(request, status)
        end

      %{content: "held stream"} ->
        start_held_stream(request, context)

      _ ->
        receive_default(test, request, context)
    end
  end

  defp receive_default(test, request, context) do
    result = WebWidget.TestIntegration.ChatHost.receive_request(test, request, context: context)

    case {request, result} do
      {%{content: "delayed error"}, {:ok, receipt}} ->
        schedule_response(context, receipt, 3_000, :message_failed, "The mock failed after three seconds")

      _ ->
        :ok
    end

    result
  end

  defp schedule_response(context, receipt, delay, type, body) do
    # Keep the destination accepted with the request, just as an in-flight host job does.
    {:ok, _timer} = :timer.apply_after(delay, WebWidget.TestIntegration.ChatHost, :publish, [
      context, %{receipt | type: type, payload: %{body: body}}
    ])
  end

  defp start_held_stream(request, context) do
    host = WebWidget.TestIntegration.ChatHost
    conversation = request.conversation_id || "conversation-1"
    created = is_nil(request.conversation_id)
    receipt = host.response(request, if(created, do: :conversation_created, else: :status),
      conversation, %{accepted: true, created: created})
    Agent.update(@requests, &Map.put(&1, {:held_stream, context.sender_id},
      %{status: :running, receipt: receipt, context: context}))
    host.publish(context, %{receipt | type: :typing, payload: %{active: true}})
    host.publish(context, %{receipt | type: :message_create, payload: %{body: ""}})
    host.publish(context, %{receipt | type: :message_edit, payload: %{body: "**Partial**"}})
    {:ok, receipt}
  end

  defp held_history(request, held) do
    WebWidget.TestIntegration.ChatHost.response(request, :conversation_history,
      request.conversation_id, %{messages: [
        %{message_id: "held-user", position: 1, role: "user", content: "held stream", provider_sent_at: nil},
        %{message_id: "held-assistant", position: 2, role: "assistant",
          content: if(held.status == :running, do: "**Partial**", else: "**Finished**"),
          provider_sent_at: nil}
      ]})
  end

  def release_stream(user_id) do
    held = Agent.get_and_update(@requests, fn state ->
      case Map.get(state, {:held_stream, user_id}) do
        %{status: :running} = current ->
          {current, Map.put(state, {:held_stream, user_id}, %{current | status: :finished})}
        _ -> {nil, state}
      end
    end)
    if held do
      WebWidget.TestIntegration.ChatHost.publish(held.context,
        %{held.receipt | type: :message_complete, payload: %{body: "**Finished**"}})
    end
    held != nil
  end

  def stream_details(user_id) do
    Agent.get(@requests, fn state ->
      case Map.get(state, {:held_stream, user_id}) do
        nil -> %{status: :missing}
        held -> %{status: held.status, topic: held.context.delivery.topic,
          request_id: held.receipt.request_id, conversation_id: held.receipt.conversation_id,
          message_id: held.receipt.message_id}
      end
    end)
  end

  # A nonterminal host event leaves canonical history and the held final untouched.
  def probe_stream(user_id) do
    held = Agent.get(@requests, &Map.fetch!(&1, {:held_stream, user_id}))
    WebWidget.TestIntegration.ChatHost.publish(held.context,
      %{held.receipt | type: :message_edit, payload: %{body: "UNAUTHORIZED EXPIRY PROBE"}})
  end

  def request_count(user_id, content) do
    Agent.get(@requests, &Map.get(&1, {user_id, content}, 0))
  end

  def bootstrap(ttl \\ 604_800, user_id \\ "e2e-visitor", issued_offset \\ 0) do
    now = System.system_time(:second)
    claims = %{widget_id: 420, user_id: user_id, iss: "e2e-parent", aud: "e2e-widget",
      iat: now + issued_offset, exp: now + ttl, jti: Ecto.UUID.generate()}
    {token, 0} = System.cmd("node", ["test/support/integration/jwt_interop.cjs"],
      env: [{"WIDGET_TEST_KEY", key()}, {"WIDGET_TEST_CLAIMS", Jason.encode!(claims)}])
    {:ok, script} = WebWidget.Integration.Installation.script(420, "http://127.0.0.1:4020")
    %{identity_token: token, installation_script: script}
  end
end

{:ok, _} = WebWidget.E2ESharedHost.start()
