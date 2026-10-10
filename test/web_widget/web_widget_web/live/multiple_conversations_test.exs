defmodule WebWidgetWeb.MultipleConversationsTest do
  use WebWidgetWeb.ConnCase
  import Phoenix.LiveViewTest
  alias WebWidget.Adapter
  alias WebWidget.MockHost
  alias WebWidget.Runtime

  setup do
    mock = start_supervised!({MockHost, name: :multiple_conversations_test_host, delay: 50})

    start_supervised!(
      {Runtime,
       %{
         channel_config_id: :multi_test,
         pubsub_server: WebWidget.PubSub,
         sink_mfa: {MockHost, :handle_event, [mock]},
         widgets: [
           %{
             widget_id: "multi-test",
             same_site: "Lax",
             display_name: "Multiple",
             allowed_domains: ["http://www.example.com"],
             multiple_conversations: true
           },
           %{
             widget_id: "single-test",
             same_site: "Lax",
             display_name: "Single",
             allowed_domains: ["http://www.example.com"]
           }
         ]
       }}
    )

    :ok
  end

  defp state(view), do: :sys.get_state(view.pid).socket.assigns

  defp bootstrap(conn, id) do
    {:ok, view, _} = live(conn, "/widget/#{id}")
    render_hook(view, "widget.context", %{user_id: "user"})
    view
  end

  test "runtime flag defaults off and cannot be enabled by browser context", %{conn: conn} do
    view = bootstrap(conn, "single-test")
    render_hook(view, "widget.context", %{user_id: "user", multiple_conversations: true})
    assert_reply(view, %{ok: true})
    assert_reply(view, %{ok: false})
    refute state(view).config.multiple_conversations
    assert state(view).conversations == []
    render_hook(view, "widget.conversation.select", %{id: "mock-weekend"})
    render_hook(view, "widget.conversation.new", %{})
    assert state(view).mode == :launcher
    assert state(view).accepted_context == nil
  end

  test "bootstrap loads three histories and switching preserves original bootstrap", %{conn: conn} do
    view = bootstrap(conn, "multi-test")
    assert state(view).mode == :launcher
    refute state(view).conversation_opened
    render_hook(view, "widget.open", %{})
    assert state(view).mode == :launcher
    assert length(state(view).conversations) == 3
    assert state(view).messages == []
    parent = state(view).parent_context

    for {id, count} <- [{"mock-weekend", 4}, {"mock-billing", 6}, {"mock-research", 7}] do
      render_hook(view, "widget.conversation.select", %{id: id})
      assigns = state(view)
      assert assigns.accepted_context.conversation_id == id
      assert assigns.parent_context == parent
      assert length(assigns.messages) == count
      assert Enum.all?(assigns.messages, &Map.has_key?(&1, :timestamp))
    end

    before = state(view)
    render_hook(view, "widget.conversation.select", %{})
    render_hook(view, "widget.conversation.select", %{id: "unlisted"})
    assert state(view).accepted_context == before.accepted_context
    assert state(view).messages == before.messages

    assert :ok =
             Adapter.send_event(%{
               type: "response.message.create",
               widget_id: "multi-test",
               conversation_id: "mock-weekend",
               payload: %{id: "late", content: "Wrong chat"}
             })

    assert state(view).messages == before.messages
  end

  test "new chat creates a separate conversation and keeps completed session updates", %{
    conn: conn
  } do
    view = bootstrap(conn, "multi-test")
    render_hook(view, "widget.conversation.select", %{id: "mock-weekend"})
    {:ok, _} = Adapter.subscribe("multi-test", "mock-weekend")
    render_hook(view, "widget.submit", %{text: "hello"})
    render_hook(view, "widget.conversation.select", %{id: "mock-billing"})
    render_hook(view, "widget.conversation.new", %{})
    assert state(view).accepted_context.conversation_id == "mock-weekend"
    assert_receive {:web_widget_response, %{type: "response.message.complete"}}, 2000
    assert length(state(view).messages) == 6
    render_hook(view, "widget.conversation.new", %{})
    assert state(view).messages == []
    assert state(view).accepted_context == nil
    assert state(view).subscription == nil
    render_hook(view, "widget.submit", %{text: "hello"})
    new_id = state(view).accepted_context.conversation_id
    refute new_id == "mock-weekend"
    {:ok, _} = Adapter.subscribe("multi-test", new_id)

    assert_receive {:web_widget_response,
                    %{type: "response.message.complete", conversation_id: ^new_id}},
                   2000

    assert length(state(view).conversations) == 4
    assert length(state(view).messages) == 2
    render_hook(view, "widget.conversation.select", %{id: "mock-weekend"})
    assert length(state(view).messages) == 6
    assert List.last(state(view).messages).content == "Hello! How can I help you today?"
    render_hook(view, "widget.conversation.select", %{id: new_id})
    assert length(state(view).messages) == 2
  end
end
