defmodule WebWidget.InfrastructureTest do
  use ExUnit.Case, async: false

  alias WebWidget.Configuration
  alias WebWidget.Integration.{BindingStore, Chat, ControlProof, RuntimeBuilder, SignedIdentity}
  alias WebWidget.TestIntegration.Host

  setup do
    WebWidget.TestInfrastructure.setup(
      pubsub_server: WebWidget.PubSub,
      transport: [endpoint: WebWidgetWeb.Endpoint]
    )
  end

  test "defaults are validated once and global edits cannot change running options" do
    {:ok, config} = Configuration.fetch()
    assert config.authentication[:token_ttl_seconds] == 604_800
    assert config.authentication[:refresh_lead_seconds] == 300
    assert config.authentication[:first_binding_window_seconds] == 5
    assert config.authentication[:control_proof_ttl_seconds] == 30
    assert config.authentication[:replica_nodes] == [node()]
    previous = Application.fetch_env(:web_widget, :authentication)
    on_exit(fn -> restore(:authentication, previous) end)
    Application.put_env(:web_widget, :authentication, token_ttl_seconds: 1, replica_nodes: [])
    assert {:ok, ^config} = Configuration.fetch()
    assert Configuration.authentication(:token_ttl_seconds) == 604_800
    assert :ok = BindingStore.available?()
    assert {:error, {:already_started, _}} = WebWidget.start_link(pubsub_server: WebWidget.PubSub)
  end

  test "all authentication consumers apply the same validated timing overrides" do
    {config, hooks, opts} = Host.fixture()

    WebWidget.TestInfrastructure.replace(
      Keyword.put(opts, :authentication,
        token_ttl_seconds: 60,
        refresh_lead_seconds: 10,
        first_binding_window_seconds: 1,
        control_proof_ttl_seconds: 3
      )
    )

    {:ok, {spec, []}} = RuntimeBuilder.build(config, hooks)
    start_supervised!(spec)

    assert {:ok, session} =
             WebWidget.Runtime.authenticate(to_string(config.id), Host.proof(config.id))

    assert Chat.authorization_metadata(%{session: session}).refresh_at == session.expires_at - 10
    key = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    sign_opts = [issuer: "parent", audience: "widget"]

    assert {:error, :invalid_identity_config} =
             SignedIdentity.sign(key, config.id, %{user_id: "visitor"}, sign_opts ++ [ttl: 61])

    assert {:ok, token} = SignedIdentity.sign(key, config.id, %{user_id: "visitor"}, sign_opts)
    fields = JOSE.JWT.peek_payload(token).fields
    assert fields["exp"] - fields["iat"] == 60

    assert {:error, :invalid_control_config} =
             ControlProof.sign(key, config.id, "visitor",
               issuer: "parent",
               audience: "widget:control",
               ttl: 4
             )

    assert {:ok, proof} =
             ControlProof.sign(key, config.id, "visitor",
               issuer: "parent",
               audience: "widget:control"
             )

    assert {:ok, _} =
             ControlProof.verify(key, "parent", "widget:control", proof, config.id, "visitor")

    now = max(System.system_time(:second), BindingStore.reset_cutoff_value() + 1)

    claims = %{
      issuer: "timings",
      audience: "widget",
      widget_id: config.id,
      user_id: "visitor",
      jti: Ecto.UUID.generate(),
      iat: now,
      exp: now + 60
    }

    assert :ok = BindingStore.claim(claims, "bound", now)
    assert :ok = BindingStore.claim(claims, "bound", now + 1)

    assert {:error, :stale_or_revoked} =
             BindingStore.claim(
               %{claims | jti: Ecto.UUID.generate()},
               "too-late",
               now + 1
             )

    assert {:error, :unavailable_or_invalid} =
             BindingStore.revoke_user(
               "timings",
               config.id,
               "visitor",
               "late-control",
               now,
               now + 3
             )

    assert {:ok, _, true} =
             BindingStore.revoke_user(
               "timings",
               config.id,
               "visitor",
               "timely-control",
               now,
               now + 2
             )

    :ok = Supervisor.terminate_child(WebWidget.Standalone, WebWidget)
    # Metadata carries its validated policy, even while shutdown notifications race.
    assert Chat.authorization_metadata(%{session: session}).refresh_at == session.expires_at - 10
    refute WebWidget.Runtime.authorized?(session)
  end

  test "invalid init options fail before starting any children and do not leak values" do
    for opts <- [
          [pubsub_server: nil],
          [pubsub_server: WebWidget.PubSub, unknown: "private-value"],
          [pubsub_server: WebWidget.PubSub, authentication: [token_ttl_seconds: 300]],
          [pubsub_server: WebWidget.PubSub, authentication: [replica_nodes: []]],
          [pubsub_server: WebWidget.PubSub, authentication: [replica_nodes: [node(), node()]]],
          [pubsub_server: WebWidget.PubSub, authentication: [replica_nodes: [:remote@host]]],
          [pubsub_server: WebWidget.PubSub, authentication: [first_binding_window_seconds: 0]],
          [pubsub_server: WebWidget.PubSub, transport: [scheme: :ftp]],
          [pubsub_server: WebWidget.PubSub, transport: [widget_path: "/private-value?"]],
          [pubsub_server: WebWidget.PubSub, transport: [endpoint: String]],
          [pubsub_server: WebWidget.PubSub, transport: [tls_options: [verify: :verify_none]]],
          [pubsub_server: WebWidget.PubSub, identity_verifier: {String, :missing, []}],
          [pubsub_server: WebWidget.PubSub, response_diagnostics: :invalid],
          [pubsub_server: WebWidget.PubSub, pubsub_server: Other],
          %{}
        ] do
      {:ok, before} = Configuration.fetch()
      assert {:error, {:invalid_widget_configuration, _, message}} = WebWidget.start_link(opts)
      refute message =~ "private-value"
      assert {:ok, ^before} = Configuration.fetch()
    end
  end

  test "shutdown fences runtimes and shared authentication survives local restart" do
    reset = BindingStore.reset_cutoff_value()
    now = max(System.system_time(:second), reset + 1)

    claims = %{
      issuer: "restart",
      audience: "widget",
      widget_id: 23,
      user_id: "visitor",
      jti: Ecto.UUID.generate(),
      iat: now,
      exp: now + 120
    }

    assert :ok = BindingStore.claim(claims, "page", now)

    assert {:ok, cutoff, true} =
             BindingStore.revoke_user("restart", 24, "revoked", "request", now, now)

    {:ok, old} = Configuration.fetch()

    runtime =
      start_supervised!(
        {WebWidget.Runtime,
         %{
           channel_config_id: :lifecycle,
           pubsub_server: WebWidget.PubSub,
           sink_mfa: {__MODULE__, :unused, []},
           widgets: [
             %{widget_id: "23", same_site: "Lax", display_name: "Lifecycle", allowed_domains: []}
           ]
         }}
      )

    ref = Process.monitor(runtime)
    :ok = Supervisor.terminate_child(WebWidget.Standalone, WebWidget)
    assert_receive {:DOWN, ^ref, :process, ^runtime, :shutdown}
    assert {:error, :infrastructure_not_started} = Configuration.fetch()
    assert {:error, :unavailable} = BindingStore.available?()
    assert {:error, :unavailable_or_invalid} = BindingStore.claim(claims, "page", now)
    assert {:error, :not_found} = WebWidget.Runtime.fetch_widget("23")

    assert {:ok, %{status: :unavailable, reason: :runtime_not_registered}} =
             RuntimeBuilder.status(23, [])

    assert {:ok, _} = Supervisor.restart_child(WebWidget.Standalone, WebWidget)
    _ = :sys.get_state(BindingStore)
    {:ok, new} = Configuration.fetch()
    refute old.generation == new.generation
    assert BindingStore.reset_cutoff_value() == reset
    assert :ok = BindingStore.claim(claims, "page", now + 6)
    assert {:error, :replayed} = BindingStore.claim(claims, "other", now + 6)

    assert {:ok, ^cutoff, false} =
             BindingStore.revoke_user("restart", 24, "revoked", "request", now, now + 1)

    revoked = %{claims | widget_id: 24, user_id: "revoked", jti: Ecto.UUID.generate()}
    assert {:error, :stale_or_revoked} = BindingStore.claim(revoked, "page", now)

    assert {:error, :unavailable_or_invalid} =
             BindingStore.revoke_user(
               "restart",
               25,
               "new-generation",
               "generation-request",
               now,
               now,
               old.generation
             )

    assert {:ok, ^now, true} =
             BindingStore.revoke_user(
               "restart",
               25,
               "new-generation",
               "generation-request",
               now,
               now,
               new.generation
             )

    assert {:ok, %{reason: :runtime_not_registered}} = RuntimeBuilder.status(23, [])
  end

  test "compatibility construction cannot install competing provider options" do
    {config, hooks, opts} = Host.fixture()
    assert {:ok, {spec, []}} = RuntimeBuilder.build(config, hooks, opts)
    assert {:error, {:infrastructure_configuration_mismatch, _}} = start_supervised(spec)
    assert {:error, :not_found} = WebWidget.Runtime.fetch_widget(to_string(config.id))
  end

  test "restarting infrastructure never starts or reconfigures the referenced endpoint" do
    endpoint = Process.whereis(WebWidgetWeb.Endpoint)
    url = WebWidgetWeb.Endpoint.url()

    WebWidget.TestInfrastructure.replace(
      pubsub_server: WebWidget.PubSub,
      transport: [endpoint: WebWidgetWeb.Endpoint]
    )

    assert Process.whereis(WebWidgetWeb.Endpoint) == endpoint
    assert WebWidgetWeb.Endpoint.url() == url
  end

  test "configuration-owner crash restarts infrastructure, preserves shared state and rejects stale specs" do
    {config, hooks, _} = Host.fixture()

    config =
      Map.merge(config, %{
        token: String.duplicate("lifecycle-test-key", 3),
        settings: %{
          "same_site" => "Lax",
          "identity_issuer" => "host",
          "identity_audience" => "widget"
        }
      })

    {:ok, {spec, []}} = RuntimeBuilder.build(config, hooks)
    runtime = start_supervised!(spec)
    {:ok, old} = Configuration.fetch()
    reset = BindingStore.reset_cutoff_value()
    registry = Process.whereis(WebWidget.RuntimeRegistry)
    registry_ref = Process.monitor(registry)
    runtime_ref = Process.monitor(runtime)
    Process.exit(old.owner, :kill)
    assert_receive {:DOWN, ^registry_ref, :process, ^registry, :shutdown}
    _ = Supervisor.which_children(WebWidget.Supervisor)
    assert_receive {:DOWN, ^runtime_ref, :process, ^runtime, :shutdown}
    {:ok, current} = Configuration.fetch()
    refute old.generation == current.generation
    assert BindingStore.reset_cutoff_value() == reset
    assert {:error, :not_found} = WebWidget.Runtime.fetch_widget(to_string(config.id))
    {:ok, supervisor} = ExUnit.fetch_test_supervisor()
    assert :ok = Supervisor.delete_child(supervisor, spec.id)
    assert {:error, {:infrastructure_configuration_mismatch, _}} = start_supervised(spec)
    assert {:ok, {replacement, []}} = RuntimeBuilder.build(config, hooks)
    start_supervised!(replacement)
    assert {:ok, _} = WebWidget.Runtime.fetch_widget(to_string(config.id))
  end

  def unused(_), do: :ok
  defp restore(key, {:ok, value}), do: Application.put_env(:web_widget, key, value)
  defp restore(key, :error), do: Application.delete_env(:web_widget, key)
end
