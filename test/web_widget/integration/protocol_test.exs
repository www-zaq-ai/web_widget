defmodule WebWidget.Integration.ProtocolTest do
  use ExUnit.Case, async: false

  alias WebWidget.Integration.RuntimeBuilder
  alias WebWidget.Runtime
  alias WebWidget.TestIntegration.Host

  setup do
    {_, _, opts} = Host.fixture()
    WebWidget.TestInfrastructure.setup(opts)
  end

  setup_all do
    start_supervised!({Phoenix.PubSub, name: WebWidget.TestIntegration.PubSub})
    :ok
  end

  defp runtime(reply \\ nil) do
    {config, hooks, opts} = Host.fixture(reply: reply)
    {:ok, {spec, []}} = RuntimeBuilder.build(config, hooks, opts)
    start_supervised!(spec)
    {config, spec}
  end

  defp session(config) do
    {:ok, session} = Runtime.authenticate(to_string(config.id), Host.proof(config.id))
    session
  end

  defp question do
    %{
      type: "message.create",
      request_id: "question-1",
      message: %{id: "user-message-1", content: "Hello"},
      timestamp: DateTime.utc_now(),
      channel: "default",
      mode: :async,
      conversation_id: nil,
      prompt_context: "Page context"
    }
  end

  test "calls the bound sink with constructed payload/context and preserves direct readiness" do
    reply = %{type: :widget_initialized, conversation_id: nil, payload: %{created: false}}
    {config, _} = runtime(reply)
    session = session(config)
    assert session.sender_id == "verified-parent-user"
    assert session.owner == self()
    refute Map.has_key?(session, :proof)
    refute Map.has_key?(session, :hooks)

    assert_receive {:verified_scope, %{widget_id: widget_id, channel_config_id: id}}
    assert widget_id == to_string(config.id)
    assert id == config.id

    assert Runtime.dispatch(%{type: "widget.init", request_id: "init-1"}, session) == reply

    assert_receive {:ingress, ^id, %{type: :conversation_init, request_id: "init-1"}, context,
                    caller}

    assert caller == self()
    assert context.actor == nil
    assert context.options.sender_id == session.sender_id
    assert context.options.consumer == :widget
    assert context.options.channel_config_id == id
    refute Map.has_key?(context.options, :capabilities)

    delivery = context.options.delivery.constructed
    assert delivery.topic == session.topic
    assert delivery.channel_config_id == id
    assert delivery.consumer == :widget

    assert delivery.events == %{
             typing: "response.typing",
             message_create: "response.message.create",
             message_edit: "response.message.edit",
             message_step: "response.message.step",
             message_complete: "response.message.complete",
             message_failed: "response.message.failed",
             error: "response.error"
           }
  end

  test "first-question mapping accepts nil ID, retains context, and preserves acceptance" do
    reply = {:ok, %{type: :conversation_created, conversation_id: "chat-1"}}
    {config, _} = runtime(reply)
    session = session(config)
    event = question()
    assert Runtime.dispatch(event, session) == reply
    assert_receive {:ingress, _, payload, _, _}

    assert payload == %{
             request_id: event.request_id,
             message_id: event.message.id,
             content: "Hello",
             timestamp: event.timestamp,
             channel: "default",
             mode: :async,
             conversation_id: nil,
             prompt_context: "Page context"
           }

    assert Runtime.dispatch(%{event | conversation_id: "chat-1"}, session) == reply
    assert_receive {:ingress, _, resumed, _, _}
    refute Map.has_key?(resumed, :prompt_context)
    assert resumed.conversation_id == "chat-1"
  end

  test "history maps to a shared command with bounded-reader parameters unchanged" do
    reply = %{type: :conversation_history, payload: %{messages: []}}
    {config, _} = runtime(reply)
    session = session(config)
    params = %{limit: 10, after_position: 3, up_to_position: 20}

    assert Runtime.dispatch(
             %{
               type: "conversation.history.request",
               request_id: "history-1",
               conversation_id: "chat-1",
               params: params
             },
             session
           ) == reply

    assert_receive {:ingress, _, %{type: :conversation_history, params: ^params}, _, _}
  end

  test "malformed raw resume IDs never fall through to a new conversation" do
    {config, _} = runtime()
    session = session(config)

    for type <- ["widget.init", "message.create", "conversation.history.request"],
        id <- ["", "   ", false, 1, [], %{}, String.duplicate("x", 256), <<255>>] do
      event = if type == "message.create", do: question(), else: %{type: type, request_id: "r"}

      assert Runtime.dispatch(Map.put(event, :conversation_id, id), session) ==
               {:error, :invalid_conversation_id}
    end

    assert Runtime.dispatch(%{type: "conversation.history.request", request_id: "r"}, session) ==
             {:error, :invalid_conversation_id}

    refute_receive {:ingress, _, _, _, _}
  end

  test "unknown events, edits and identity/routing injection are rejected before host ingress" do
    {config, _} = runtime()
    session = session(config)

    for type <- ["message.edit", "widget.authenticate", "evil", nil] do
      assert Runtime.dispatch(%{type: type}, session) == {:error, :unsupported_event}
    end

    for key <- [
          :sender_id,
          :user_id,
          :widget_id,
          :channel_config_id,
          :topic,
          :context,
          :capabilities,
          :selected_agent_id,
          :hooks,
          :sink_mfa,
          "conversation_id"
        ] do
      assert Runtime.dispatch(Map.put(question(), key, "forged"), session) ==
               {:error, :unknown_fields}
    end

    assert Runtime.dispatch(
             %{question() | message: %{id: "m", content: "x", actor: "forged"}},
             session
           ) ==
             {:error, :unknown_fields}

    refute_receive {:ingress, _, _, _, _}
  end

  test "rejects unverified, expired and foreign proofs without retaining verifier details" do
    {config, _} = runtime()

    for proof <- [
          nil,
          "user-id",
          :raise,
          Host.proof(config.id + 1),
          {:signed, config.id, "sender", 0},
          Host.proof(config.id, " ")
        ] do
      assert Runtime.authenticate(to_string(config.id), proof) == {:error, :unauthorized}
    end

    assert Runtime.dispatch(question(), %{sender_id: "forged"}) == {:error, :unauthorized}
    refute_receive {:ingress, _, _, _, _}
  end

  test "session destinations are isolated and exist before a conversation ID" do
    {config, _} = runtime()
    first = session(config)
    second = session(config)
    refute first.topic == second.topic
    assert {:ok, subscription} = Runtime.subscribe(first)
    Phoenix.PubSub.broadcast(WebWidget.TestIntegration.PubSub, second.topic, :foreign)
    refute_receive :foreign
    Phoenix.PubSub.broadcast(WebWidget.TestIntegration.PubSub, first.topic, :own)
    assert_receive :own
    assert :ok = WebWidget.Adapter.unsubscribe(subscription)
  end

  test "session cannot move processes or outlive expiry or runtime replacement" do
    {config, spec} = runtime()
    session = session(config)
    parent = self()
    event = question()

    start_supervised!(
      {Task, fn -> send(parent, {:other_process, Runtime.dispatch(event, session)}) end}
    )

    assert_receive {:other_process, {:error, :unauthorized}}
    assert Runtime.dispatch(event, %{session | expires_at: 0}) == {:error, :unauthorized}
    assert Runtime.subscribe(%{session | expires_at: 0}) == {:error, :unauthorized}

    stop_supervised!(spec.id)
    assert Runtime.dispatch(event, session) == {:error, :unauthorized}
    start_supervised!(spec)
    assert Runtime.dispatch(event, session) == {:error, :unauthorized}
    refute_receive {:ingress, _, _, _, _}
  end

  test "keeps host rejection and semantic error shapes; contains callback failures" do
    for reply <- [
          {:error, :unauthorized},
          %{type: :error, payload: %{code: :conversation_not_found}},
          %{type: :message_complete, payload: %{body: "Answer"}}
        ] do
      {config, spec} = runtime(reply)
      assert Runtime.dispatch(%{question() | mode: :sync}, session(config)) == reply
      stop_supervised!(spec.id)
    end

    for failure <- [:raise, :throw, :exit] do
      {config, spec} = runtime(failure)
      assert Runtime.dispatch(question(), session(config)) == {:error, :unavailable}
      assert {:ok, _} = Runtime.fetch_widget(to_string(config.id))
      stop_supervised!(spec.id)
    end
  end
end
