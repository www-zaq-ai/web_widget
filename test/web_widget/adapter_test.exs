defmodule WebWidget.AdapterTest do
  use ExUnit.Case, async: false
  alias WebWidget.Adapter
  alias WebWidget.Runtime

  setup do
    id = "adapter-#{System.unique_integer([:positive])}"
    server = Module.concat(__MODULE__, "PubSub#{System.unique_integer([:positive])}")
    start_supervised!({Phoenix.PubSub, name: server})
    WebWidget.TestInfrastructure.setup(pubsub_server: server)

    start_supervised!(
      {Runtime,
       %{
         channel_config_id: id,
         sink_mfa: {__MODULE__, :callback, [self()]},
         pubsub_server: server,
         widgets: [
           %{widget_id: id, same_site: "Lax", display_name: "Adapter", allowed_domains: []}
         ]
       }}
    )

    %{id: id, server: server}
  end

  def callback(event, caller) do
    send(caller, {:callback, event})
    :ok
  end

  def dispatch(_entries, _from, _message), do: exit(:host_dispatcher_unavailable)

  test "stopped PubSub returns unavailable for subscriptions and response delivery", %{
    id: id
  } do
    stop_supervised!(Phoenix.PubSub.Supervisor)

    assert Adapter.subscribe(id, "conversation") == {:error, :unavailable}

    assert Adapter.send_event(%{
             type: "response.typing",
             widget_id: id,
             conversation_id: "conversation",
             payload: %{active: true}
           }) == {:error, :unavailable}
  end

  test "a stopped subscription partition is reported as unavailable", %{id: id, server: server} do
    for {partition, _, _, _} <- Supervisor.which_children(server) do
      :ok = Supervisor.terminate_child(server, partition)
    end

    assert Adapter.subscribe(id, "conversation") == {:error, :unavailable}
  end

  test "host dispatcher exits are reported as unavailable", %{id: id, server: server} do
    stop_supervised!(Phoenix.PubSub.Supervisor)
    start_supervised!({Phoenix.PubSub, name: server, dispatcher: __MODULE__})
    assert {:ok, _subscription} = Adapter.subscribe(id, "conversation")

    assert Adapter.send_event(%{
             type: "response.typing",
             widget_id: id,
             conversation_id: "conversation",
             payload: %{active: true}
           }) == {:error, :unavailable}
  end

  test "uses configured PubSub and isolates widget/conversation topics", %{id: id} do
    {:ok, subscription} = Adapter.subscribe(id, "conversation")

    event = %{
      type: "response.message.create",
      widget_id: id,
      conversation_id: "conversation",
      payload: %{id: "answer", content: "hello", secret: "discard"}
    }

    assert :ok = Adapter.send_event(%{event | conversation_id: "other"})
    refute_receive {:web_widget_response, _}
    assert :ok = Adapter.send_event(event)
    assert_receive {:web_widget_response, %{payload: payload}}
    assert payload == %{id: "answer", content: "hello"}
    Adapter.unsubscribe(subscription)
    assert :ok = Adapter.send_event(event)
    refute_receive {:web_widget_response, _}
    assert :ok = Runtime.dispatch(%{widget_id: id, type: "message.create"})
    assert_receive {:callback, %{widget_id: ^id}}
  end

  test "rejects invalid maps and unknown runtimes", %{id: id} do
    for event <- [
          %{},
          %{
            type: "response.typing",
            widget_id: id,
            conversation_id: nil,
            payload: %{active: true}
          },
          %{
            type: "response.message.step",
            widget_id: id,
            conversation_id: "conv",
            payload: %{id: "s"}
          },
          %{
            type: "message.create",
            widget_id: id,
            conversation_id: "conv",
            payload: %{id: "s", content: "hi"}
          }
        ] do
      assert {:error, :invalid_response} = Adapter.send_event(event)
    end

    assert {:error, :unavailable} =
             Adapter.send_event(%{
               type: "response.typing",
               widget_id: "missing",
               conversation_id: "conv",
               payload: %{active: true}
             })
  end
end
