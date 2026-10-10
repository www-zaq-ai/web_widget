ExUnit.start()

defmodule WebWidget.InfrastructureSmokeTest do
  # credo:disable-for-next-line Credo.Check.Warning.WrongTestFilename
  use ExUnit.Case
  alias WebWidget.Integration.{ControlProof, RuntimeBuilder, SignedIdentity}

  setup do
    {:ok, _} = Application.ensure_all_started(:web_widget)
    :ok
  end

  test "host owns startup and dependency application shutdown cannot stop its child" do
    assert {:ok, %{reason: :runtime_not_registered}} = RuntimeBuilder.status(23, [])
    start_supervised!({Phoenix.PubSub, name: __MODULE__.PubSub})
    supervisor = start_supervised!({WebWidget, pubsub_server: __MODULE__.PubSub})
    assert is_pid(Process.whereis(WebWidget.Configuration))
    assert is_pid(Process.whereis(WebWidget.RuntimeRegistry))
    assert is_pid(Process.whereis(WebWidget.Integration.BindingStore))

    assert {:error, {:already_started, ^supervisor}} =
             WebWidget.start_link(pubsub_server: __MODULE__.PubSub)

    assert :ok = Application.stop(:web_widget)
    assert Process.whereis(WebWidget.Supervisor) == supervisor
    assert Process.whereis(WebWidgetWeb.Endpoint) == nil
    assert Process.whereis(WebWidget.PubSub) == nil
    stop_supervised!(WebWidget)
    assert {:error, :infrastructure_not_started} = WebWidget.Configuration.fetch()

    assert {:ok, %{status: :unavailable, reason: :runtime_not_registered}} =
             RuntimeBuilder.status(23, [])
  end

  test "failed child startup rolls back its own configuration without replacing another registry" do
    registry = start_supervised!({Registry, keys: :unique, name: WebWidget.RuntimeRegistry})
    assert {:error, _} = start_supervised({WebWidget, pubsub_server: __MODULE__.PubSub})
    assert Process.whereis(WebWidget.Supervisor) == nil
    assert Process.whereis(WebWidget.Configuration) == nil
    assert Process.whereis(WebWidget.Integration.BindingStore) == nil
    assert Process.whereis(WebWidget.RuntimeRegistry) == registry
    assert Process.whereis(__MODULE__.PubSub) == nil
  end

  test "offline signing uses package defaults but verification requires explicit infrastructure" do
    key = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    assert {:ok, token} =
             SignedIdentity.sign(key, 23, %{user_id: "visitor"},
               issuer: "host",
               audience: "widget"
             )

    assert {:error, :unauthorized} =
             SignedIdentity.verify(key, "host", "widget", token, %{
               channel_config_id: 23,
               page_id: "page"
             })

    assert {:ok, proof} =
             ControlProof.sign(key, 23, "visitor", issuer: "host", audience: "widget:control")

    assert {:error, :unauthorized} =
             ControlProof.verify(key, "host", "widget:control", proof, 23, "visitor")

    assert Process.whereis(WebWidget.Supervisor) == nil
  end
end
