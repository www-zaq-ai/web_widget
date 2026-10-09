defmodule WebWidget.Integration.ConfigurationTest do
  use ExUnit.Case, async: false

  alias WebWidget.Integration.ControlProof
  alias WebWidget.Integration.RuntimeBuilder
  alias WebWidget.Integration.SignedIdentity
  alias WebWidget.Runtime
  alias WebWidget.TestIntegration.Host

  test "build/2 reads server configuration and fails closed when it is absent" do
    previous = Application.fetch_env(:web_widget, :integration)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:web_widget, :integration, value)
        :error -> Application.delete_env(:web_widget, :integration)
      end
    end)

    {config, hooks, opts} = Host.fixture()
    Application.delete_env(:web_widget, :integration)
    assert RuntimeBuilder.build(config, hooks) == {:error, :invalid_integration_config}

    Application.put_env(:web_widget, :integration, opts)
    assert RuntimeBuilder.build(config, hooks) == RuntimeBuilder.build(config, hooks, opts)
  end

  test "build/2 binds connector settings rather than application identity options" do
    previous = Application.fetch_env(:web_widget, :integration)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:web_widget, :integration, value)
        :error -> Application.delete_env(:web_widget, :integration)
      end
    end)

    {config, hooks, opts} = Host.fixture()
    key = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    settings = %{"identity_issuer" => "zaq_issuer", "identity_audience" => "zaq_audience"}
    config = Map.merge(config, %{token: key, settings: settings})

    opts =
      Keyword.merge(opts,
        identity_verifier: :connector_key,
        identity_issuer: "ignored",
        identity_audience: "ignored"
      )

    Application.put_env(:web_widget, :integration, opts)

    assert {:ok, {spec, []}} = RuntimeBuilder.build(config, hooks)
    assert RuntimeBuilder.build(config, hooks, opts) == {:ok, {spec, []}}
    integration = integration(spec)

    assert integration.identity_verifier ==
             {SignedIdentity, :verify, [key, "zaq_issuer", "zaq_audience"]}

    assert integration.control_issuer == "zaq_issuer"
    assert integration.control_audience == "zaq_audience:control"
    assert integration.pubsub_server == opts[:pubsub_server]

    for invalid <- [Map.delete(config, :settings), %{config | settings: %{}}] do
      assert {:error, :invalid_identity_config} = RuntimeBuilder.build(invalid, hooks)
    end
  end

  test "connector identity is mandatory and exact; invalid settings never fall back" do
    {config, hooks, opts} = Host.fixture()

    config =
      Map.merge(config, %{
        token: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false),
        settings: %{"identity_issuer" => "parent", "identity_audience" => "widget"}
      })

    opts =
      Keyword.merge(opts,
        identity_verifier: :connector_key,
        identity_issuer: "fallback",
        identity_audience: "fallback"
      )

    for settings <- [
          nil,
          [],
          "invalid",
          %{},
          %{identity_issuer: "parent", identity_audience: "widget"}
        ] do
      assert {:error, :invalid_identity_config} =
               RuntimeBuilder.build(%{config | settings: settings}, hooks, opts)
    end

    for name <- ["identity_issuer", "identity_audience"] do
      assert {:error, :invalid_identity_config} =
               RuntimeBuilder.build(
                 %{config | settings: Map.delete(config.settings, name)},
                 hooks,
                 opts
               )

      for value <- [
            nil,
            "",
            " ",
            " parent",
            "parent\n",
            42,
            false,
            <<255>>,
            String.duplicate("x", 256),
            String.duplicate("é", 128)
          ] do
        assert {:error, :invalid_identity_config} =
                 RuntimeBuilder.build(
                   %{config | settings: Map.put(config.settings, name, value)},
                   hooks,
                   opts
                 )
      end

      for value <- ["zaq", String.duplicate("x", 255), String.duplicate("é", 127) <> "x"] do
        assert {:ok, _} =
                 RuntimeBuilder.build(
                   %{config | settings: Map.put(config.settings, name, value)},
                   hooks,
                   opts
                 )
      end
    end

    assert Runtime.fetch_widget(to_string(config.id)) == {:error, :not_found}
  end

  test "connector settings cannot select PubSub or a verifier" do
    for server <- [WebWidget.TestIntegration.PubSub, WebWidget.PubSub] do
      {config, hooks, opts} = Host.fixture()

      config =
        Map.put(config, :settings, %{
          "pubsub_server" => "attacker",
          "identity_verifier" => "attacker"
        })

      opts = Keyword.put(opts, :pubsub_server, server)
      assert {:ok, {spec, []}} = RuntimeBuilder.build(config, hooks, opts)
      start_supervised!(spec)
      assert Runtime.pubsub_server(to_string(config.id)) == {:ok, server}
      assert {:ok, _} = Runtime.authenticate(to_string(config.id), Host.proof(config.id))
    end
  end

  test "maximum connector audience supports the derived control proof" do
    key = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    audience = String.duplicate("x", 255) <> ":control"

    assert {:ok, proof} =
             ControlProof.sign(key, 42, "visitor", issuer: "parent", audience: audience)

    assert {:ok, _} = ControlProof.verify(key, "parent", audience, proof, 42, "visitor")

    for invalid <- [
          nil,
          "widget",
          ":control",
          " widget:control",
          String.duplicate("x", 256) <> ":control",
          <<255>> <> ":control"
        ] do
      assert {:error, :invalid_control_config} =
               ControlProof.sign(key, 42, "visitor", issuer: "parent", audience: invalid)
    end
  end

  defp integration(%{start: {Runtime, :start_link, [config]}}), do: config.integration
end
