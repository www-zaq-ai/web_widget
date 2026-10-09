defmodule WebWidget.Integration.RuntimeBuilderTest do
  use ExUnit.Case, async: true

  alias WebWidget.Integration.RuntimeBuilder
  alias WebWidget.Runtime
  alias WebWidget.TestIntegration.Host

  test "unconfigured identity permits runtime installation but never authenticates" do
    {config, hooks, opts} = Host.fixture()

    opts =
      Keyword.put(
        opts,
        :identity_verifier,
        {WebWidget.Integration.UnconfiguredIdentity, :verify, []}
      )

    assert {:ok, {spec, []}} = RuntimeBuilder.build(config, hooks, opts)
    start_supervised!(spec)
    assert {:ok, _widget} = Runtime.fetch_widget(to_string(config.id))

    for proof <- [nil, "user-id", Host.proof(config.id), %{sender_id: "admin"}] do
      assert Runtime.authenticate(to_string(config.id), proof) == {:error, :unauthorized}
    end
  end

  test "returns host-owned state specs with unique IDs and public presentation only" do
    for _ <- 1..2 do
      {config, hooks, opts} = Host.fixture()
      assert {:ok, {spec, []}} = RuntimeBuilder.build(config, hooks, opts)
      assert spec.id == {Runtime, config.id}
      runtime = start_supervised!(spec)
      assert {:ok, public} = Runtime.fetch_widget(to_string(config.id))

      assert public == %{
               widget_id: to_string(config.id),
               same_site: :inherit,
               display_name: hooks.display_name,
               allowed_domains: hooks.allowed_domains,
               stylesheet_url: nil,
               multiple_conversations: false
             }

      refute Map.has_key?(public, :integration)
      assert Runtime.pubsub_server(public.widget_id) == {:ok, opts[:pubsub_server]}

      assert Runtime.dispatch(%{widget_id: public.widget_id, type: "widget.init"}) ==
               {:error, :authentication_required}

      monitor = Process.monitor(runtime)
      stop_supervised!(spec.id)
      assert_receive {:DOWN, ^monitor, :process, ^runtime, :shutdown}
      assert Runtime.fetch_widget(public.widget_id) == {:error, :not_found}
    end
  end

  test "invalid hooks, options and scope fail during construction before registration" do
    {config, hooks, opts} = Host.fixture()

    for key <- [:message, :command, :context, :delivery, :response, :sink_mfa] do
      assert {:error, :invalid_integration_config} =
               RuntimeBuilder.build(config, Map.delete(hooks, key), opts)

      assert {:error, :invalid_integration_config} =
               RuntimeBuilder.build(config, Map.put(hooks, key, String), opts)
    end

    for invalid <- [
          nil,
          %{},
          [],
          [pubsub_server: false],
          Keyword.delete(opts, :identity_verifier)
        ] do
      assert {:error, :invalid_integration_config} = RuntimeBuilder.build(config, hooks, invalid)
    end

    for invalid <- [nil, %{}, %{config | id: 0}, %{config | provider: "web"}] do
      assert {:error, :invalid_integration_config} = RuntimeBuilder.build(invalid, hooks, opts)
    end

    assert {:error, :invalid_integration_config} =
             RuntimeBuilder.build(config, %{hooks | widget_id: config.id + 1}, opts)

    assert Runtime.fetch_widget(to_string(config.id)) == {:error, :not_found}
  end

  test "connector cookie settings are validated and retained without adapter defaults" do
    {config, hooks, opts} = Host.fixture()

    for value <- ["None", "Lax", "Strict"] do
      configured = Map.put(config, :settings, %{"same_site" => value})
      assert {:ok, {spec, []}} = RuntimeBuilder.build(configured, hooks, opts)
      start_supervised!(spec)
      assert {:ok, %{same_site: ^value}} = Runtime.fetch_widget(to_string(config.id))
      stop_supervised!(spec.id)
    end

    for value <- [nil, "", "none", false] do
      configured = Map.put(config, :settings, %{"same_site" => value})
      assert {:error, :invalid_cookie_policy} = RuntimeBuilder.build(configured, hooks, opts)
    end
  end

  test "rejects invalid presentation; empty origins remain denied" do
    {config, hooks, opts} = Host.fixture()

    assert {:error, :invalid_runtime_config} =
             RuntimeBuilder.build(config, %{hooks | allowed_domains: ["*"]}, opts)

    assert {:error, :invalid_runtime_config} =
             RuntimeBuilder.build(config, %{hooks | display_name: nil}, opts)

    assert {:ok, {spec, []}} =
             RuntimeBuilder.build(
               config,
               %{hooks | allowed_domains: []},
               opts
             )

    start_supervised!(spec)

    assert Runtime.authenticate(to_string(config.id), Host.proof(config.id)) ==
             {:error, :unauthorized}

    refute_receive {:verified_scope, _}
  end

  test "legacy stylesheet hooks cannot leak into connector-wide presentation" do
    {config, hooks, opts} = Host.fixture()
    hooks = Map.put(hooks, :stylesheet_url, "https://legacy.example/style.css")
    assert {:ok, {spec, []}} = RuntimeBuilder.build(config, hooks, opts)
    start_supervised!(spec)
    assert {:ok, %{stylesheet_url: nil}} = Runtime.fetch_widget(to_string(config.id))
  end

  test "duplicate connector registration fails without replacing the original runtime" do
    {config, hooks, opts} = Host.fixture()
    {:ok, {spec, []}} = RuntimeBuilder.build(config, hooks, opts)
    original = start_supervised!(spec)
    assert {:error, _} = start_supervised(%{spec | id: :duplicate})
    assert [{^original, _}] = Registry.lookup(WebWidget.RuntimeRegistry, to_string(config.id))
  end
end
