defmodule WebWidgetWeb.WidgetLiveTest do
  use WebWidgetWeb.ConnCase

  import Phoenix.LiveViewTest

  setup do
    start_supervised!(
      {WebWidget.Runtime,
       %{
         channel_config_id: :live_test,
         sink_mfa: {__MODULE__, :host, [self()]},
         pubsub_server: WebWidget.PubSub,
         widgets: [
           %{
             widget_id: "live-test",
             same_site: "Lax",
             display_name: "Test",
             allowed_domains: ["http://www.example.com"]
           }
         ]
       }}
    )

    :ok
  end

  def host(%{type: "widget.init", user_id: "denied"}, _), do: {:error, :denied}

  def host(%{type: "widget.init"} = event, test) do
    send(test, {:host_event, event})

    {:ok,
     %{
       type: "response.widget.initialized",
       widget_id: event.widget_id,
       conversation_id: event.conversation_id || "accepted-conversation",
       user_id: event.user_id
     }}
  end

  def host(%{type: "conversation.history.request"} = event, test) do
    send(test, {:host_event, event})

    {:ok,
     %{
       type: "response.conversation.history",
       widget_id: event.widget_id,
       conversation_id: event.conversation_id,
       payload: %{
         messages: [
           %{id: "old", role: "assistant", content: "Previous response"}
         ]
       }
     }}
  end

  def host(%{message: %{content: "reject"}}, _), do: {:error, :rejected}

  def host(event, test) do
    send(test, {:host_event, event})

    if event.message.content == "instant" do
      emit("response.message.create", %{id: "instant", content: ""})
      emit("response.message.complete", %{id: "instant", content: "Immediate response"})
    end

    :ok
  end

  defp emit(type, payload, conversation_id \\ "accepted-conversation") do
    assert :ok =
             WebWidget.Adapter.send_event(%{
               type: type,
               widget_id: "live-test",
               conversation_id: conversation_id,
               payload: payload
             })
  end

  defp state(view), do: :sys.get_state(view.pid).socket.assigns

  test "settings default to English and explicit updates select language", %{conn: conn} do
    {:ok, default, _} = live(conn, ~p"/widget/live-test")
    assert state(default).config.locale == "en"

    for {locale, _direction, placeholder} <- [
          {"fr", "ltr", "Posez une question…"},
          {"ar", "rtl", "اطرح سؤالًا…"}
        ] do
      id = "localized-#{locale}"

      start_supervised!(
        {WebWidget.Runtime,
         %{
           channel_config_id: id,
           sink_mfa: {__MODULE__, :host, [self()]},
           pubsub_server: WebWidget.PubSub,
           widgets: [
             %{
               widget_id: id,
               same_site: "Lax",
               display_name: "Host title",
               locale: locale,
               allowed_domains: ["http://www.example.com"]
             }
           ]
         }}
      )

      html = conn |> get("/widget/#{id}") |> html_response(200) |> LazyHTML.from_document()
      assert LazyHTML.attribute(LazyHTML.query(html, "html"), "lang") == ["en"]
      assert LazyHTML.attribute(LazyHTML.query(html, "html"), "dir") == ["ltr"]
      {:ok, view, _} = live(conn, "/widget/#{id}")
      render_hook(view, "widget.settings.update", %{settings: %{language: locale}})
      render_hook(view, "widget.context", %{user_id: "user"})
      assert state(view).config.locale == locale
      assert state(view).config.placeholder == placeholder
      assert state(view).config.title == "Host title"
      refute Map.has_key?(state(view).parent_context, :locale)
    end

    assert state(default).config.strings["Send"] == "Send"
  end

  test "parent context retains only bootstrap fields and accepts identical retries", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/widget/live-test")
    assert has_element?(view, "#widget-state[data-context-received='false']")

    params = %{
      user_id: "user_123",
      prompt_context: "Current page: /billing",
      conversation_id: "conv_123"
    }

    render_hook(view, "widget.context", Map.put(params, :permissions, ["admin"]))
    assert_reply(view, %{ok: false})
    assert state(view).parent_context == nil

    for _ <- 1..2 do
      render_hook(view, "widget.context", params)
      assert has_element?(view, "#widget-state[data-context-received='true']")
      assert has_element?(view, "#web-widget[data-name='WebWidget'][phx-hook='ReactHook']")

      assert %{
               user_id: "user_123",
               conversation_id: "conv_123",
               prompt_context: "Current page: /billing"
             } == :sys.get_state(view.pid).socket.assigns.parent_context
    end

    assert :sys.get_state(view.pid).socket.assigns.messages == []
  end

  test "runtime settings preserve context and repeated init cannot reset them", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/widget/live-test")

    render_hook(view, "widget.context", %{user_id: "user"})
    render_hook(view, "widget.settings.update", %{settings: %{theme: "dark", language: "fr"}})

    before = state(view)
    render_hook(view, "widget.settings.update", %{settings: %{language: "ar"}})
    assert state(view).settings == %{"theme" => "dark", "language" => "ar"}
    assert state(view).parent_context == before.parent_context

    render_hook(view, "widget.context", %{
      user_id: "user",
      settings: %{theme: "light", language: "en"}
    })

    assert state(view).settings == %{"theme" => "dark", "language" => "ar"}

    render_hook(view, "widget.settings.update", %{
      settings: %{theme: "light", user_id: "attacker"}
    })

    assert state(view).settings == %{"theme" => "dark", "language" => "ar"}
    assert state(view).parent_context == before.parent_context
  end

  test "settings in init are rejected and leave context uninitialized", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/widget/live-test")

    render_hook(view, "widget.context", %{
      user_id: "user",
      settings: %{theme: "dark", language: "fr"}
    })

    assert state(view).parent_context == nil
    assert state(view).settings == %{"theme" => "light", "language" => "en"}
  end

  test "optional bootstrap fields support new conversations and string context", %{conn: conn} do
    for params <- [%{user_id: "user_123"}, %{user_id: "user_123", prompt_context: "Billing"}] do
      {:ok, view, _} = live(conn, ~p"/widget/live-test")
      render_hook(view, "widget.context", params)

      assert :sys.get_state(view.pid).socket.assigns.parent_context == %{
               user_id: "user_123",
               prompt_context: Map.get(params, :prompt_context),
               conversation_id: nil
             }
    end
  end

  test "malformed context cannot initialize the widget", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/widget/live-test")

    for params <- [
          %{},
          %{user_id: nil},
          %{user_id: "  "},
          %{user_id: 123},
          %{user_id: "user_123", conversation_id: " "},
          %{user_id: "user_123", conversation_id: 123},
          %{user_id: "user_123", prompt_context: []},
          %{user_id: "user_123", prompt_context: %{}},
          %{user_id: "user_123", prompt_context: true}
        ] do
      render_hook(view, "widget.context", params)
      assert :sys.get_state(view.pid).socket.assigns.parent_context == nil
    end
  end

  test "context cannot be replaced during the LiveView lifetime", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/widget/live-test")
    params = %{user_id: "user_123", conversation_id: "conv_123", prompt_context: nil}
    render_hook(view, "widget.context", params)

    for replacement <- [
          %{params | user_id: "user_456"},
          %{params | conversation_id: "conv_456"},
          %{params | prompt_context: "Changed"}
        ] do
      render_hook(view, "widget.context", replacement)
      assert :sys.get_state(view.pid).socket.assigns.parent_context == params
    end
  end

  test "initial mount hides the chat and rejects submissions until context arrives", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/widget/live-test")
    assert has_element?(view, "#widget-state[data-mode='launcher']")
    refute has_element?(view, "#web-widget")
    render_hook(view, "widget.submit", %{text: "Not initialized"})
    assert :sys.get_state(view.pid).socket.assigns.pending_reply == nil
    assert has_element?(view, "#widget-state[data-mode='launcher']")
    assert view.pid |> :sys.get_state() |> then(& &1.socket.assigns.messages) == []
  end

  test "dispatches real payloads and applies PubSub steps and streaming", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/widget/live-test")
    render_hook(view, "widget.context", %{user_id: "user_123"})
    render_hook(view, "widget.submit", %{text: "  Where can I learn?  "})
    assert_receive {:host_event, %{type: "widget.init", mode: :sync}}

    assert_receive {:host_event,
                    %{
                      type: "message.create",
                      mode: :async,
                      conversation_id: "accepted-conversation",
                      message: %{content: "Where can I learn?"}
                    }}

    assert has_element?(view, "#widget-state[data-mode='conversation']")
    emit("response.message.create", %{id: "answer", content: ""})

    step = %{
      id: "tool",
      message_id: "answer",
      kind: "tool_call",
      state: "started",
      label: "Searching",
      content: nil
    }

    emit("response.message.step", step)
    assert [%{role: "user", content: "Where can I learn?"}, assistant] = state(view).messages
    assert [%{id: "tool", state: "started", kind: "tool_call"}] = assistant.steps
    emit("response.message.step", %{step | state: "completed", label: "Search complete"})
    emit("response.message.edit", %{id: "answer", content: "Partial"})
    assert List.last(state(view).messages).content == "Partial"
    emit("response.message.complete", %{id: "answer", content: "Final answer"})
    assigns = state(view)
    assert assigns.pending_reply == nil

    assert [_, %{content: "Final answer", status: "complete", steps: [%{state: "completed"}]}] =
             assigns.messages
  end

  test "subsequent submissions preserve history and ignore stale terminal events", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/widget/live-test")
    render_hook(view, "widget.context", %{user_id: "user"})
    render_hook(view, "widget.submit", %{text: "First question"})
    emit("response.message.create", %{id: "answer-1", content: ""})
    emit("response.message.complete", %{id: "answer-1", content: "First answer"})
    render(view)
    render_hook(view, "widget.submit", %{text: "Follow-up"})
    emit("response.message.create", %{id: "answer-2", content: ""})
    emit("response.message.complete", %{id: "answer-1", content: "Stale answer"})
    assert state(view).pending_reply.id == "answer-2"
    emit("response.message.complete", %{id: "answer-2", content: "Second answer"})

    assert Enum.map(state(view).messages, & &1.content) == [
             "First question",
             "First answer",
             "Follow-up",
             "Second answer"
           ]

    assert length(Enum.uniq_by(state(view).messages, & &1.id)) == 4
    assert state(view).pending_reply == nil
  end

  test "subscription is active before a callback responds immediately", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/widget/live-test")
    render_hook(view, "widget.context", %{user_id: "user"})
    render_hook(view, "widget.submit", %{text: "instant"})
    assert [_, %{content: "Immediate response", status: "complete"}] = state(view).messages
    assert state(view).pending_reply == nil
  end

  test "resumed context loads history before dispatching the new message", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/widget/live-test")
    render_hook(view, "widget.context", %{user_id: "user", conversation_id: "existing"})
    render_hook(view, "widget.submit", %{text: "Follow-up"})
    assert_receive {:host_event, %{type: "widget.init"}}

    assert_receive {:host_event,
                    %{
                      type: "conversation.history.request",
                      mode: :sync,
                      conversation_id: "existing"
                    }}

    assert_receive {:host_event, %{type: "message.create", conversation_id: "existing"}}
    assert Enum.map(state(view).messages, & &1.content) == ["Previous response", "Follow-up"]
  end

  test "initialization and callback rejection leave the draft retryable", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/widget/live-test")
    render_hook(view, "widget.context", %{user_id: "denied"})
    render_hook(view, "widget.submit", %{text: "hello"})
    assert state(view).accepted_context == nil
    assert state(view).pending_reply == nil
    assert state(view).messages == []
    {:ok, other, _} = live(conn, ~p"/widget/live-test")
    render_hook(other, "widget.context", %{user_id: "user"})
    render_hook(other, "widget.submit", %{text: "reject"})
    assert state(other).messages == []
    assert state(other).pending_reply == nil
  end

  test "closing keeps the subscription and accepts responses while collapsed", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/widget/live-test")
    render_hook(view, "widget.context", %{user_id: "user"})
    render_hook(view, "widget.submit", %{text: "hello"})
    before = state(view)
    render_hook(view, "widget.close", %{})
    assert has_element?(view, "#widget-state[data-mode='launcher']")
    assert state(view).subscription == before.subscription
    assert state(view).accepted_context == before.accepted_context
    emit("response.message.create", %{id: "answer", content: ""})
    emit("response.message.complete", %{id: "answer", content: "Finished while closed"})
    assert state(view).pending_reply == nil
    assert state(view).mode == :launcher
    render_hook(view, "widget.open", %{})
    assert has_element?(view, "#widget-state[data-mode='conversation']")
    assert Enum.map(state(view).messages, & &1.content) == ["hello", "Finished while closed"]
  end

  test "rejects blank, oversized and malformed submissions without expanding", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/widget/live-test")
    render_hook(view, "widget.context", %{user_id: "user_123"})

    for params <- [%{text: "  "}, %{text: String.duplicate("a", 2001)}, %{text: nil}, %{}] do
      render_hook(view, "widget.submit", params)
      assert has_element?(view, "#widget-state[data-mode='launcher']")
    end
  end

  test "rejects concurrent sends and ignores unrelated or malformed responses", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/widget/live-test")
    render_hook(view, "widget.context", %{user_id: "user_123"})
    render_hook(view, "widget.submit", %{text: "First"})
    render_hook(view, "widget.submit", %{text: "Duplicate"})
    emit("response.message.create", %{id: "wrong", content: "Other conversation"}, "other")
    send(view.pid, {:web_widget_response, %{type: "response.message.create"}})

    send(
      view.pid,
      {:web_widget_response,
       %{
         type: "response.message.create",
         widget_id: "another-widget",
         conversation_id: "accepted-conversation",
         payload: %{id: "wrong", content: "Other widget"}
       }}
    )

    assert [%{content: "First"}] = state(view).messages
    assert state(view).pending_reply != nil
    emit("response.message.create", %{id: "answer", content: ""})

    emit("response.message.failed", %{
      message_id: "answer",
      code: "failed",
      message: "Tool failed"
    })

    assert state(view).pending_reply == nil
    assert List.last(state(view).messages).error == "Tool failed"
    render_hook(view, "widget.submit", %{text: "Retry"})
    assert List.last(state(view).messages).content == "Retry"
  end
end
