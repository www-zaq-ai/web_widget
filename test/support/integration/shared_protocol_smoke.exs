# Optional package-only smoke against the actual host constructors, without
# installing a reverse dependency or starting/modifying the ZAQ application.
# MIX_ENV=test mix run --no-start test/support/integration/shared_protocol_smoke.exs ../zaq
[host_root] = System.argv()

for file <- ~w(validation stylesheet message command response delivery context) do
  Code.require_file(Path.join([host_root, "lib/zaq/channels/web", file <> ".ex"]))
end

{:ok, _} = Application.ensure_all_started(:web_widget)
ExUnit.start()

defmodule WebWidget.SharedProtocolSmokeTest do
  # credo:disable-for-next-line Credo.Check.Warning.WrongTestFilename
  use ExUnit.Case

  alias WebWidget.Integration.Chat
  alias WebWidget.Integration.RuntimeBuilder
  alias WebWidget.Runtime
  alias Zaq.Channels.Web.{Command, Context, Delivery, Message, Response}

  setup do
    start_supervised!(
      {WebWidget, pubsub_server: __MODULE__.PubSub, identity_verifier: {__MODULE__, :verify, []}}
    )

    :ok
  end

  def verify(:fixture_session, %{channel_config_id: 42}),
    do:
      {:ok,
       %{
         sender_id: "verified-parent-user",
         expires_at: System.system_time(:second) + 60
       }}

  def verify(_, _), do: {:error, :unauthorized}

  def ingress(%{id: 42}, %Command{} = command, context: %Context{} = context) do
    assert context.consumer == :widget
    assert context.sender_id == "verified-parent-user"
    assert context.channel_config_id == 42

    {:ok, response} =
      Response.new(%{
        request_id: command.request_id,
        type: :widget_initialized,
        payload: %{created: false}
      })

    response
  end

  def ingress(%{id: 42}, %Message{} = message,
        context: %Context{delivery: %Delivery{} = delivery}
      ) do
    assert message.conversation_id == nil
    assert message.prompt_context == "Parent context"
    assert delivery.consumer == :widget
    assert delivery.channel_config_id == 42
    assert map_size(delivery.events) == 7

    {:ok, response} =
      Response.new(%{
        request_id: message.request_id,
        type: :conversation_created,
        conversation_id: "fixture-chat",
        message_id: "transport-assistant",
        payload: %{created: true, accepted: true}
      })

    {:ok, terminal} =
      Response.new(%{
        request_id: message.request_id,
        type: :message_complete,
        conversation_id: "fixture-chat",
        message_id: "transport-assistant",
        payload: %{body: "Fixture answer"}
      })

    Phoenix.PubSub.broadcast(
      __MODULE__.PubSub,
      delivery.topic,
      {:web_response, delivery.events.message_create,
       %{terminal | type: :message_create, payload: %{body: ""}}}
    )

    Phoenix.PubSub.broadcast(
      __MODULE__.PubSub,
      delivery.topic,
      {:web_response, delivery.events.message_complete, terminal}
    )

    {:ok, response}
  end

  test "chat lifecycle accepts actual semantic receipts and queued shared responses" do
    start_supervised!({Phoenix.PubSub, name: __MODULE__.PubSub})
    config = %{id: 42, provider: "web_widget"}

    hooks = %{
      widget_id: 42,
      display_name: "Chat smoke",
      allowed_domains: ["https://parent.example"],
      message: Message,
      command: Command,
      response: Response,
      context: Context,
      delivery: Delivery,
      sink_mfa: {__MODULE__, :ingress, [config]}
    }

    {:ok, {spec, []}} =
      RuntimeBuilder.build(config, hooks,
        pubsub_server: __MODULE__.PubSub,
        identity_verifier: {__MODULE__, :verify, []}
      )

    start_supervised!(spec)

    assert {:ok, chat} =
             Chat.open("42", %{
               "identity_token" => :fixture_session
             })

    assert chat.conversation_id == nil
    assert {:ok, chat} = Chat.update_context(chat, %{prompt_context: "Parent context"})
    assert {:ok, chat} = Chat.submit(chat, "Question")
    assert chat.conversation_id == "fixture-chat"
    assert_receive {:web_response, event, create}
    chat = Chat.receive_response(chat, event, create)
    assert_receive {:web_response, event, terminal}
    chat = Chat.receive_response(chat, event, terminal)
    assert chat.active == nil
    assert List.last(chat.state.messages).content == "Fixture answer"
    Chat.close(chat)
  end

  test "package builder and session use actual shared constructors and prefix-bound ingress" do
    start_supervised!({Phoenix.PubSub, name: __MODULE__.PubSub})
    config = %{id: 42, provider: "web_widget"}

    hooks = %{
      widget_id: 42,
      display_name: "Shared constructor smoke",
      allowed_domains: ["https://parent.example"],
      message: Message,
      command: Command,
      response: Response,
      context: Context,
      delivery: Delivery,
      sink_mfa: {__MODULE__, :ingress, [config]}
    }

    {:ok, {spec, []}} =
      RuntimeBuilder.build(config, hooks,
        pubsub_server: __MODULE__.PubSub,
        identity_verifier: {__MODULE__, :verify, []}
      )

    start_supervised!(spec)
    assert {:ok, session} = Runtime.authenticate("42", :fixture_session)

    assert %Response{type: :widget_initialized, conversation_id: nil} =
             Runtime.dispatch(%{type: "widget.init", request_id: "init"}, session)

    for params <- [
          %{},
          %{stylesheet_url: "https://site.example/widget.css"},
          %{stylesheet_url: "http://localhost:4010/widget.css"}
        ] do
      assert %Response{type: :widget_initialized} =
               Runtime.dispatch(
                 %{type: "widget.init", request_id: "style-init", params: params},
                 session
               )
    end

    for url <- ["/style.css", "//site.example/style.css", "zaq://style", "javascript:alert(1)"] do
      assert {:error, {:invalid_field, :stylesheet_url}} =
               Runtime.dispatch(
                 %{type: "widget.init", request_id: "bad-style", params: %{stylesheet_url: url}},
                 session
               )
    end

    assert {:ok, %{stylesheet_url: nil}} = Runtime.fetch_widget("42")

    assert {:ok, subscription} = Runtime.subscribe(session)

    event = %{
      type: "message.create",
      request_id: "question",
      message: %{id: "user-transport", content: "Hello"},
      timestamp: DateTime.utc_now(),
      channel: "default",
      mode: :async,
      conversation_id: nil,
      prompt_context: "Parent context"
    }

    assert {:ok, %Response{type: :conversation_created, conversation_id: "fixture-chat"}} =
             Runtime.dispatch(event, session)

    assert_receive {:web_response, "response.message.complete",
                    %Response{request_id: "question", payload: %{body: "Fixture answer"}}}

    assert {:error, {:invalid_field, :timestamp}} =
             Runtime.dispatch(%{event | timestamp: "not-a-DateTime"}, session)

    assert {:error, :invalid_conversation_id} =
             Runtime.dispatch(%{event | conversation_id: false}, session)

    assert {:error, {:forbidden_params, ["actor"]}} =
             Runtime.dispatch(
               %{
                 type: "conversation.history.request",
                 request_id: "history",
                 conversation_id: "chat",
                 params: %{nested: %{actor: "forged"}}
               },
               session
             )

    assert :ok = WebWidget.Adapter.unsubscribe(subscription)
    assert Process.whereis(WebWidgetWeb.Endpoint) == nil
    assert Process.whereis(WebWidget.Repo) == nil
    assert Process.whereis(WebWidget.PubSub) == nil
  end
end
