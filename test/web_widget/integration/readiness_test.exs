defmodule WebWidget.Integration.ReadinessTest do
  use ExUnit.Case, async: false

  alias WebWidget.Integration.{Readiness, RuntimeBuilder}
  alias WebWidget.Runtime
  alias WebWidget.TestIntegration.Host

  @endpoint WebWidget.TestHost.Endpoint
  @pubsub WebWidget.TestIntegration.PubSub

  setup do
    previous = Application.get_env(:web_widget, :integration)
    previous_endpoint = Application.get_env(:web_widget, @endpoint)

    on_exit(fn ->
      restore(:integration, previous)
      restore(@endpoint, previous_endpoint)
    end)

    start_supervised!(Supervisor.child_spec({Phoenix.PubSub, name: @pubsub}, id: @pubsub))
    configure_endpoint()
    start_supervised!(@endpoint)
    integration(readiness: [endpoint: @endpoint])
    :ok
  end

  test "ready proves the actual scoped WebSocket with zero visitors and no protected work" do
    {id, _pid} = install()
    warm(id)
    assert {:ok, result} = RuntimeBuilder.status(id, timeout_ms: 2_000)
    assert result.protocol_version == 1
    assert result.status == :ready
    assert result.reason == nil
    assert Enum.all?(result.checks, fn {_, check} -> check == %{status: :ready, reason: nil} end)

    assert result.effective_settings == %{
             identity_issuer: %{value: "test-issuer", source: :connector},
             identity_audience: %{value: "test-audience", source: :connector},
             same_site: %{value: "Lax", source: :connector}
           }

    refute_receive {:ingress, _, _, _, _}
    refute_receive {:verified_scope, _}
    refute inspect(result) =~ "private-readiness-key"
    refute Map.has_key?(result, :pubsub_server)

    assert Map.keys(result) |> Enum.sort() ==
             Enum.sort([:protocol_version, :status, :reason, :checks, :effective_settings])
  end

  test "uses custom widget_path instead of BO /live" do
    {id, _} = install()
    integration(widget_path: "/support/chat", readiness: [endpoint: @endpoint])
    warm(id, "/support/chat")
    assert {:ok, %{status: :ready}} = RuntimeBuilder.status(id, [])

    integration(widget_path: "/not-mounted", readiness: [endpoint: @endpoint])
    assert {:ok, result} = RuntimeBuilder.status(id, [])
    assert result.checks.transport == %{status: :unknown, reason: :transport_unverifiable}
    assert result.status != :ready
  end

  test "concurrent calls report each connector's installed identity, not application defaults" do
    {first, _} = install()

    {second, _} =
      install(%{"identity_issuer" => "second-issuer", "identity_audience" => "second-audience"})

    warm(first)
    warm(second)

    results =
      Task.async_stream([first, second, first, second], &RuntimeBuilder.status(&1, []),
        max_concurrency: 4,
        timeout: 3_000
      )
      |> Enum.to_list()

    for {{:ok, {:ok, result}}, id} <- Enum.zip(results, [first, second, first, second]) do
      assert result.status == :ready
      expected = if id == first, do: "test-issuer", else: "second-issuer"
      assert result.effective_settings.identity_issuer == %{value: expected, source: :connector}
    end

    assert Enum.all?(results, &match?({:ok, {:ok, _}}, &1))
  end

  test "a running endpoint with serving disabled is unavailable" do
    {id, _} = install()
    stop_supervised!(@endpoint)
    configure_endpoint(server: false)
    start_supervised!(@endpoint)
    assert {:ok, result} = RuntimeBuilder.status(id, [])
    assert result.checks.runtime.status == :ready
    assert result.checks.transport == %{status: :unavailable, reason: :transport_not_listening}
    assert result.status == :unavailable
  end

  test "BO WebSocket and widget longpoll do not substitute for a widget WebSocket" do
    {id, _} = install()
    endpoint = WebWidget.TestHost.UnscopedEndpoint
    previous = Application.get_env(:web_widget, endpoint)
    on_exit(fn -> restore(endpoint, previous) end)
    Application.put_env(:web_widget, endpoint, Application.fetch_env!(:web_widget, @endpoint))
    start_supervised!(endpoint)
    integration(readiness: [endpoint: endpoint])
    assert {:ok, result} = RuntimeBuilder.status(id, [])
    assert result.checks.transport == %{status: :unknown, reason: :transport_unverifiable}
    assert result.status != :ready
  end

  test "endpoint stop and restart recover without retained green" do
    {id, _} = install()
    warm(id)
    assert {:ok, %{status: :ready}} = RuntimeBuilder.status(id, [])
    stop_supervised!(@endpoint)
    assert {:ok, %{status: :unavailable}} = RuntimeBuilder.status(id, [])
    start_supervised!(@endpoint)
    warm(id)
    assert {:ok, %{status: :ready}} = RuntimeBuilder.status(id, [])
  end

  test "stopping only the listener does not mistake its living endpoint for readiness" do
    {id, _} = install()
    warm(id)
    endpoint_pid = Process.whereis(@endpoint)
    :ok = Supervisor.terminate_child(@endpoint, {@endpoint, :http})
    assert Process.whereis(@endpoint) == endpoint_pid

    assert {:ok, %{status: :unavailable, reason: :transport_not_listening}} =
             RuntimeBuilder.status(id, [])

    assert {:ok, _} = Supervisor.restart_child(@endpoint, {@endpoint, :http})
    warm(id)
    assert {:ok, %{status: :ready}} = RuntimeBuilder.status(id, [])
  end

  test "forged CSRF or a BO socket path cannot produce green" do
    {id, _} = install()
    warm(id)
    config = Application.fetch_env!(:web_widget, @endpoint)

    for fault <- [:csrf, :socket_path] do
      @endpoint.config_change(
        %{@endpoint => Keyword.put(config, :readiness_test_fault, fault)},
        []
      )

      assert {:ok, result} = RuntimeBuilder.status(id, [])
      assert result.checks.transport == %{status: :unknown, reason: :transport_unverifiable}
      assert result.status != :ready
      refute inspect(result) =~ "forged"
    end
  end

  test "removing one widget does not change a second widget on the same listener" do
    {first, _} = install()
    {second, _} = install()
    warm(second)
    stop_supervised!({Runtime, first})
    assert {:ok, %{reason: :runtime_not_registered}} = RuntimeBuilder.status(first, [])
    assert {:ok, %{status: :ready}} = RuntimeBuilder.status(second, [])
  end

  test "unresponsive runtime is bounded and resumes cleanly" do
    {id, pid} = install()
    :ok = :sys.suspend(pid)

    try do
      assert {:ok, %{reason: :runtime_unresponsive}} =
               RuntimeBuilder.status(id, timeout_ms: 1_000)

      assert {:error, :check_timeout} = RuntimeBuilder.status(id, timeout_ms: 20)
    after
      :sys.resume(pid)
    end

    warm(id)
    assert {:ok, %{status: :ready}} = RuntimeBuilder.status(id, [])
  end

  test "missing PubSub is unavailable even though socket PubSub and listener are healthy" do
    {id, _} = install()
    warm(id)
    stop_supervised!(@pubsub)
    assert {:ok, result} = RuntimeBuilder.status(id, [])
    assert result.checks.transport.status == :ready
    assert result.checks.delivery == %{status: :unavailable, reason: :pubsub_unavailable}
    assert result.reason == :pubsub_unavailable
    start_supervised!(Supervisor.child_spec({Phoenix.PubSub, name: @pubsub}, id: @pubsub))
    assert {:ok, %{status: :ready}} = RuntimeBuilder.status(id, [])
  end

  test "runtime replacement during the handshake cannot return stale green" do
    {id, _} = install()
    warm(id)
    gate_pages()
    task = Task.async(fn -> RuntimeBuilder.status(id, []) end)
    assert_receive {:readiness_page, page}
    {:ok, public} = Runtime.fetch_widget(to_string(id))
    stop_supervised!({Runtime, id})

    start_supervised!(
      {Runtime,
       %{
         channel_config_id: id,
         sink_mfa: {__MODULE__, :unused, []},
         pubsub_server: @pubsub,
         widgets: [public]
       }}
    )

    send(page, :release_readiness_page)
    assert {:ok, %{status: :unavailable, reason: :runtime_not_registered}} = Task.await(task)
  end

  test "a stalled page request obeys the total budget and leaves no late result" do
    {id, _} = install()
    warm(id)
    gate_pages()

    task =
      Task.async(fn ->
        result = RuntimeBuilder.status(id, timeout_ms: 200)
        send(self(), :mailbox_barrier)
        assert_receive :mailbox_barrier
        refute_receive {_, _}, 20
        result
      end)

    assert_receive {:readiness_page, page}
    assert {:error, :check_timeout} = Task.await(task)
    send(page, :release_readiness_page)
  end

  test "an endpoint policy edit during probing is not reported as applied old policy" do
    {id, _} = install(%{}, false)
    warm(id)
    gate_pages()
    task = Task.async(fn -> RuntimeBuilder.status(id, []) end)
    assert_receive {:readiness_page, page}
    config = Application.fetch_env!(:web_widget, @endpoint)

    @endpoint.config_change(
      %{@endpoint => Keyword.put(config, :web_widget_session, same_site: "Strict")},
      []
    )

    send(page, :release_readiness_page)
    assert {:ok, result} = Task.await(task)
    assert result.checks.cookie_policy == %{status: :unavailable, reason: :cookie_policy_mismatch}
    assert result.status == :unavailable
  end

  test "a serving topology edit cannot return a result for the old deployment" do
    {id, _} = install()
    warm(id)
    gate_pages()
    task = Task.async(fn -> RuntimeBuilder.status(id, []) end)
    assert_receive {:readiness_page, page}
    integration(widget_path: "/support/chat", readiness: [endpoint: @endpoint])
    send(page, :release_readiness_page)
    assert {:ok, result} = Task.await(task)
    assert result.status == :unknown
    assert result.reason == :transport_unverifiable
  end

  test "missing serving configuration is unknown, not the package or BO endpoint" do
    {id, _} = install()
    integration([])
    assert {:ok, result} = RuntimeBuilder.status(id, [])
    assert result.status == :unknown
    assert result.reason == :transport_unverifiable
    assert result.effective_settings.same_site == Readiness.unresolved()
  end

  test "invalid trusted configuration returns fixed failures without private terms" do
    {id, _} = install()
    integration(readiness: %{secret: "private-deployment-value"})
    assert {:ok, result} = RuntimeBuilder.status(id, [])
    assert result.status == :unknown
    assert result.reason == :check_failed
    refute inspect(result) =~ "private-deployment-value"
  end

  test "a suspended response PubSub worker is not ready" do
    {id, _} = install()
    warm(id)
    adapter = Module.concat(@pubsub, Adapter)
    :ok = :sys.suspend(adapter)

    try do
      assert {:ok, result} = RuntimeBuilder.status(id, [])
      assert result.checks.delivery == %{status: :unavailable, reason: :pubsub_unavailable}
    after
      :sys.resume(adapter)
    end
  end

  test "HTTP never silently downgrades None or claims HTTPS from public_url" do
    {id, _} = install(%{"same_site" => "None"})
    integration(public_url: "https://public.example", readiness: [endpoint: @endpoint])
    assert {:ok, result} = RuntimeBuilder.status(id, [])
    assert result.status == :unavailable
    assert result.reason == :https_required
    assert result.checks.cookie_policy == %{status: :unavailable, reason: :https_required}
  end

  @tag :tmp_dir
  test "HTTPS verifies the installed None/Secure policy over a real TLS WebSocket", %{
    tmp_dir: dir
  } do
    keyfile = Path.join(dir, "key.pem")
    certfile = Path.join(dir, "cert.pem")
    ca = Path.join(dir, "ca.pem")
    ca_key = Path.join(dir, "ca-key.pem")
    csr = Path.join(dir, "request.pem")
    extensions = Path.join(dir, "extensions.cnf")
    File.write!(extensions, "subjectAltName=DNS:localhost\n")

    {_, 0} =
      System.cmd(
        "openssl",
        [
          "req",
          "-x509",
          "-newkey",
          "rsa:2048",
          "-nodes",
          "-keyout",
          ca_key,
          "-out",
          ca,
          "-days",
          "1",
          "-subj",
          "/CN=Readiness Test CA"
        ],
        stderr_to_stdout: true
      )

    {_, 0} =
      System.cmd(
        "openssl",
        [
          "req",
          "-new",
          "-newkey",
          "rsa:2048",
          "-nodes",
          "-keyout",
          keyfile,
          "-out",
          csr,
          "-subj",
          "/CN=localhost"
        ],
        stderr_to_stdout: true
      )

    {_, 0} =
      System.cmd(
        "openssl",
        [
          "x509",
          "-req",
          "-in",
          csr,
          "-CA",
          ca,
          "-CAkey",
          ca_key,
          "-CAcreateserial",
          "-out",
          certfile,
          "-days",
          "1",
          "-extfile",
          extensions
        ],
        stderr_to_stdout: true
      )

    stop_supervised!(@endpoint)
    configure_endpoint(https: [ip: {127, 0, 0, 1}, port: 0, keyfile: keyfile, certfile: certfile])
    start_supervised!(@endpoint)
    {id, _} = install(%{"same_site" => "None"})
    integration(readiness: [endpoint: @endpoint, scheme: :https, tls_options: [cacertfile: ca]])
    {:ok, {_ip, port}} = @endpoint.server_info(:https)

    assert %{status: 200} =
             Req.get!("https://127.0.0.1:#{port}/widget/#{id}",
               headers: [host: "localhost"],
               connect_options: [hostname: "localhost", transport_opts: [cacertfile: ca]]
             )

    assert {:ok, result} = RuntimeBuilder.status(id, [])
    assert result.status == :ready
    assert result.effective_settings.same_site == %{value: "None", source: :connector}

    integration(
      readiness: [endpoint: @endpoint, scheme: :https, tls_options: [verify: :verify_none]]
    )

    assert {:ok, %{status: :unknown, reason: :transport_unverifiable}} =
             RuntimeBuilder.status(id, [])
  end

  test "inherited policy comes from the installed serving endpoint" do
    {id, _} = install(%{}, false)
    warm(id)
    assert {:ok, result} = RuntimeBuilder.status(id, [])
    assert result.status == :ready
    assert result.effective_settings.same_site == %{value: "Lax", source: :endpoint}
  end

  test "custom verifier is never invoked or represented as provable connector identity" do
    {config, hooks, opts} = Host.fixture()
    opts = Keyword.put(opts, :identity_source, :connector)
    {:ok, {spec, []}} = RuntimeBuilder.build(config, hooks, opts)
    start_supervised!(spec)
    warm(config.id)
    assert {:ok, result} = RuntimeBuilder.status(config.id, [])

    assert result.checks.authentication == %{
             status: :unavailable,
             reason: :identity_not_configured
           }

    assert result.effective_settings.identity_issuer == Readiness.unresolved()
    refute_receive {:verified_scope, _}
  end

  test "only valid IDs and one bounded timeout option are accepted" do
    for id <- [nil, 0, -1, "42", true], opts <- [[], [timeout_ms: 2_000]] do
      assert {:error, :invalid_request} = RuntimeBuilder.status(id, opts)
    end

    for opts <- [
          nil,
          %{},
          [:bad],
          [timeout_ms: 0],
          [timeout_ms: 2_001],
          [timeout_ms: :infinity],
          [timeout_ms: 10, timeout_ms: 20],
          [endpoint: @endpoint]
        ] do
      assert {:error, :invalid_request} = RuntimeBuilder.status(42, opts)
    end
  end

  defp install(extra_settings \\ %{}, explicit_policy \\ true) do
    {config, hooks, _opts} = Host.fixture()

    settings =
      Map.merge(
        %{"identity_issuer" => "test-issuer", "identity_audience" => "test-audience"},
        extra_settings
      )

    settings = if explicit_policy, do: Map.put_new(settings, "same_site", "Lax"), else: settings

    config =
      Map.merge(config, %{token: String.duplicate("private-readiness-key", 3), settings: settings})

    opts = [pubsub_server: @pubsub, identity_verifier: :connector_key]
    {:ok, {spec, []}} = RuntimeBuilder.build(config, hooks, opts)
    {config.id, start_supervised!(spec)}
  end

  defp configure_endpoint(overrides \\ []) do
    Application.put_env(
      :web_widget,
      @endpoint,
      Keyword.merge(
        [
          adapter: Bandit.PhoenixAdapter,
          url: [host: "localhost"],
          secret_key_base: String.duplicate("host", 16),
          live_view: [signing_salt: "host-live"],
          pubsub_server: WebWidget.PubSub,
          check_origin: ["//localhost"],
          http: [ip: {127, 0, 0, 1}, port: 0],
          server: true
        ],
        overrides
      )
    )
  end

  defp integration(opts), do: Application.put_env(:web_widget, :integration, opts)

  defp gate_pages do
    config = Application.fetch_env!(:web_widget, @endpoint)
    @endpoint.config_change(%{@endpoint => Keyword.put(config, :readiness_test_gate, self())}, [])
  end

  defp warm(id, prefix \\ "/widget") do
    {:ok, {_ip, port}} = @endpoint.server_info(:http)

    assert %{status: 200} =
             Req.get!("http://127.0.0.1:#{port}#{prefix}/#{id}", headers: [host: "localhost"])
  end

  defp restore(key, nil), do: Application.delete_env(:web_widget, key)
  defp restore(key, value), do: Application.put_env(:web_widget, key, value)
end
