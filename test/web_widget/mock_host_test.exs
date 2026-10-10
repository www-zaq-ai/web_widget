defmodule WebWidget.MockHostTest do
  use ExUnit.Case, async: true
  alias WebWidget.Adapter
  alias WebWidget.Conversation.State, as: Conversation
  alias WebWidget.MockHost
  alias WebWidget.Protocol.Events
  alias WebWidget.Runtime

  setup do
    id = "mock-test-#{System.unique_integer([:positive])}"
    mock = start_supervised!({MockHost, name: {:global, {__MODULE__, id}}, delay: 0})

    start_supervised!(
      {Runtime,
       %{
         channel_config_id: id,
         sink_mfa: {MockHost, :handle_event, [mock]},
         pubsub_server: WebWidget.PubSub,
         widgets: [%{widget_id: id, same_site: "Lax", display_name: "Mock", allowed_domains: []}]
       }}
    )

    %{id: id}
  end

  for scenario <- ["hello", "search", "research", "fail", "slow", "other text"] do
    test "#{scenario} goes through the configured callback, PubSub and shared reducer", %{id: id} do
      {:ok, init} = Events.init(id, %{user_id: "user"})
      {:ok, response} = Runtime.dispatch(init)
      {:ok, _} = Adapter.subscribe(id, response.conversation_id)
      message = %{id: "input", content: unquote(scenario)}
      {:ok, event} = Events.create(id, response, message)
      assert :ok = Runtime.dispatch(event)
      state = collect(Conversation.submit(Conversation.new(), message))
      assert state.pending_reply == nil
      assert state.typing == false
      assert [_, assistant] = state.messages

      case unquote(scenario) do
        "hello" ->
          assert assistant.content == "Hello! How can I help you today?"
          assert assistant.steps == []

        "research" ->
          assert length(assistant.steps) == 2
          assert Enum.all?(assistant.steps, &(&1.state == "completed"))

        "fail" ->
          assert assistant.status == "failed"
          assert [%{state: "failed"}] = assistant.steps
          assert assistant.error =~ "Unable to complete"

        _ ->
          assert assistant.content =~ "prototype response"

          assert [
                   %{kind: "tool_call", state: "completed"},
                   %{kind: "tool_result", state: "completed"}
                 ] = assistant.steps
      end
    end
  end

  test "mock history is a deterministic fixture", %{id: id} do
    {:ok, event} = Events.history(id, %{user_id: "user", conversation_id: "mock-history"})

    assert {:ok,
            %{
              type: "response.conversation.history",
              payload: %{messages: messages, conversations: conversations}
            }} = Runtime.dispatch(event)

    assert length(messages) == 4
    assert Enum.map(conversations, &length(&1.messages)) == [4, 6, 7]

    for conversation <- conversations do
      dates =
        Enum.map(conversation.messages, fn message ->
          assert {:ok, time, 0} = DateTime.from_iso8601(message.timestamp)
          DateTime.to_date(time)
        end)

      assert Enum.uniq(dates) == [Date.add(Date.utc_today(), -1), Date.utc_today()]
    end
  end

  defp collect(state) do
    assert_receive {:web_widget_response, event}, 1000
    state = Conversation.apply_event(state, event)

    if event.type in ["response.message.complete", "response.message.failed"],
      do: state,
      else: collect(state)
  end
end
