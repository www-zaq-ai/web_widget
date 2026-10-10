# Run from the configured ZAQ root; this file belongs to the widget package.
# MIX_ENV=test mix run ../web_widget/test/support/integration/host_runtime_smoke.exs
# Uses synthetic runtime configs, without writing connectors or changing host config.
ExUnit.start()

defmodule WebWidget.HostRuntimeSmokeTest do
  # credo:disable-for-next-line Credo.Check.Warning.WrongTestFilename
  use ExUnit.Case

  alias WebWidget.Integration.{RuntimeBuilder, UnconfiguredIdentity}
  alias WebWidget.Runtime
  alias Zaq.Channels.{CommunicationBridge, WebBridge}
  alias Zaq.Channels.Supervisor, as: ChannelSupervisor

  test "configured host enables the real package with hooks and owns its lifecycle" do
    assert Application.fetch_env!(:zaq, :channels).web_widget == %{
             bridge: WebBridge,
             runtime_builder: RuntimeBuilder
           }

    assert {:ok, infrastructure} = WebWidget.Configuration.fetch()

    assert Keyword.take(infrastructure.integration, [:pubsub_server, :identity_verifier]) == [
             pubsub_server: Zaq.PubSub,
             identity_verifier: {UnconfiguredIdentity, :verify, []}
           ]

    assert {:ok, %{available?: true}} = Zaq.Channels.Web.Runtime.status(nil)
    assert {:ok, snippet} = Zaq.Channels.Web.Runtime.embed_script(42, "https://zaq.example.test")
    assert snippet =~ ~s(data-widget-id="42")
    assert snippet =~ "/web_widget/assets/embed.js"

    id = 2_000_000_000 + System.unique_integer([:positive])

    disabled = %{
      id: id,
      name: "Package runtime smoke",
      provider: "web_widget",
      enabled: false,
      settings: %{
        "same_site" => "Lax",
        "display_name" => "Support smoke",
        "allowed_domains" => ["http://localhost:4010"]
      }
    }

    enabled = %{disabled | enabled: true}
    other = %{enabled | id: id + 1}
    widget_id = Integer.to_string(id)
    bridge_id = "web_widget_#{id}"

    on_exit(fn ->
      WebBridge.stop_runtime(enabled)
      WebBridge.stop_runtime(other)
    end)

    assert :ok = CommunicationBridge.sync_config_runtime(nil, disabled)
    assert {:error, :not_found} = Runtime.fetch_widget(widget_id)
    assert :ok = CommunicationBridge.sync_config_runtime(disabled, enabled)

    assert {:ok, %{state_pid: pid, listener_pids: []}} =
             ChannelSupervisor.lookup_runtime(bridge_id)

    assert Runtime.fetch_widget(widget_id) ==
             {:ok,
              %{
                widget_id: widget_id,
                same_site: "Lax",
                display_name: "Support smoke",
                allowed_domains: ["http://localhost:4010"],
                stylesheet_url: nil,
                multiple_conversations: false
              }}

    assert Runtime.pubsub_server(widget_id) == {:ok, Zaq.PubSub}
    state = :sys.get_state(pid)
    assert state.channel_config_id == id
    assert state.integration.hooks.widget_id == id
    assert state.integration.hooks.message == Zaq.Channels.Web.Message
    assert state.integration.hooks.command == Zaq.Channels.Web.Command
    assert state.integration.hooks.context == Zaq.Channels.Web.Context
    assert state.integration.hooks.delivery == Zaq.Channels.Web.Delivery
    assert state.integration.hooks.response == Zaq.Channels.Web.Response

    assert state.integration.hooks.sink_mfa ==
             {Zaq.Channels.Web.Runtime, :from_listener, [%{id: id}]}

    assert Runtime.authenticate(widget_id, "unverified") == {:error, :unauthorized}

    assert :ok = CommunicationBridge.sync_config_runtime(enabled, enabled)
    assert {:ok, %{state_pid: ^pid}} = ChannelSupervisor.lookup_runtime(bridge_id)

    changed = put_in(enabled.settings["display_name"], "Updated support")
    monitor = Process.monitor(pid)
    assert :ok = CommunicationBridge.sync_config_runtime(enabled, changed)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :shutdown}
    assert {:ok, %{state_pid: replacement}} = ChannelSupervisor.lookup_runtime(bridge_id)
    refute replacement == pid
    assert {:ok, %{display_name: "Updated support"}} = Runtime.fetch_widget(widget_id)

    assert :ok = CommunicationBridge.sync_config_runtime(nil, other)
    monitor = Process.monitor(replacement)
    assert :ok = CommunicationBridge.sync_config_runtime(changed, %{changed | enabled: false})
    assert_receive {:DOWN, ^monitor, :process, ^replacement, :shutdown}
    assert {:error, :not_found} = Runtime.fetch_widget(widget_id)
    assert {:ok, _} = Runtime.fetch_widget(to_string(other.id))

    assert :ok = CommunicationBridge.sync_config_runtime(disabled, enabled)
    assert {:ok, _} = Runtime.fetch_widget(widget_id)
    assert Process.whereis(WebWidgetWeb.Endpoint) == nil
    assert Process.whereis(WebWidget.Repo) == nil
    assert Process.whereis(WebWidget.PubSub) == nil
  end
end
