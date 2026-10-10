Application.put_env(:web_widget, :demo_allowed_domains, ["http://127.0.0.1:4019", "http://127.0.0.1:4020", "https://localhost:4023", "https://127.0.0.1:4023"])

# Disposable test-only TLS credentials, never included in the released bundle.
tls_dir = Path.join(System.tmp_dir!(), "web-widget-tls-#{System.pid()}")
File.mkdir_p!(tls_dir)
keyfile = Path.join(tls_dir, "key.pem")
certfile = Path.join(tls_dir, "cert.pem")
{_, 0} = System.cmd("openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes",
  "-keyout", keyfile, "-out", certfile, "-days", "1", "-subj", "/CN=localhost"], stderr_to_stdout: true)

# Serve the built browser assets over the real LiveView WebSocket transport.
Application.delete_env(:live_react, :vite_host)

config =
  :web_widget
  |> Application.fetch_env!(WebWidgetWeb.Endpoint)
  |> Keyword.merge(
    server: true,
    watchers: [],
    live_reload: [patterns: []],
    check_origin: ["//127.0.0.1:4019", "//127.0.0.1:4022"],
    web_widget_session: [partitioned: false],
    http: [ip: {127, 0, 0, 1}, port: 4019]
  )

Application.put_env(:web_widget, WebWidgetWeb.Endpoint, config)
{:ok, _} = Application.ensure_all_started(:web_widget)

# Controls exist only in the Playwright server, never in application routes.
Code.require_file("assets/tests/support/controlled_host.exs")
Code.require_file("assets/tests/support/shared_host.exs")
Code.require_file("assets/tests/support/control.exs")
{:ok, _} = Supervisor.start_child(WebWidget.Supervisor, WebWidget.E2EHost)
{:ok, _} = Supervisor.start_child(WebWidget.Supervisor, {Bandit, plug: WebWidget.E2EControl, ip: {127, 0, 0, 1}, port: 4021})
{:ok, _} = Supervisor.start_child(WebWidget.Supervisor, {WebWidget.Runtime, %{
  channel_config_id: :controlled_e2e,
  sink_mfa: {WebWidget.E2EHost, :handle_event, []},
  pubsub_server: WebWidget.PubSub,
  widgets: Enum.map([false, true], fn multiple ->
    %{widget_id: if(multiple, do: "e2e-multi", else: "e2e"), display_name: "Test assistant",
      multiple_conversations: multiple, allowed_domains: ["http://127.0.0.1:4019"]}
  end)
}})

Code.require_file("test/support/host/session_probe.ex")
Code.require_file("test/support/host/router.ex")
Code.require_file("test/support/host/endpoint.ex")
Code.require_file("assets/tests/support/http_endpoint.exs")

Application.put_env(:web_widget, WebWidget.TestHost.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  secret_key_base: String.duplicate("host", 16),
  live_view: [signing_salt: "host-live"],
  pubsub_server: WebWidget.PubSub,
  check_origin: ["//127.0.0.1:4020", "//127.0.0.1:4023"],
  https: [ip: {127, 0, 0, 1}, port: 4023, keyfile: keyfile, certfile: certfile],
  server: true
)

{:ok, _} = Supervisor.start_child(WebWidget.Supervisor, WebWidget.TestHost.Endpoint)

secret_key_base = WebWidget.TestHost.Endpoint.config(:secret_key_base)
Application.put_env(:web_widget, WebWidget.E2EHttpEndpoint,
  adapter: Bandit.PhoenixAdapter,
  secret_key_base: secret_key_base, live_view: [signing_salt: "host-live"],
  pubsub_server: WebWidget.PubSub, check_origin: ["//127.0.0.1:4020"],
  web_widget_session: [partitioned: false], server: true,
  http: [ip: {127, 0, 0, 1}, port: 4020])
{:ok, _} = Supervisor.start_child(WebWidget.Supervisor, WebWidget.E2EHttpEndpoint)
Application.put_env(:web_widget, WebWidget.E2EHttpsEndpoint,
  adapter: Bandit.PhoenixAdapter,
  secret_key_base: secret_key_base, live_view: [signing_salt: "host-live"],
  pubsub_server: WebWidget.PubSub, check_origin: ["//127.0.0.1:4022"], server: true,
  https: [ip: {127, 0, 0, 1}, port: 4022, keyfile: keyfile, certfile: certfile])
{:ok, _} = Supervisor.start_child(WebWidget.Supervisor, WebWidget.E2EHttpsEndpoint)

{:ok, _} = Supervisor.start_child(WebWidget.Supervisor, {WebWidget.Runtime, %{
  channel_config_id: :cookie_e2e,
  sink_mfa: {WebWidget.MockHost, :handle_event, []},
  pubsub_server: WebWidget.PubSub,
  widgets: Enum.map(["None", "Lax", "Strict"], fn policy ->
    %{widget_id: "cookie-" <> String.downcase(policy), display_name: "Cookie assistant",
      same_site: policy, allowed_domains: ["https://localhost:4023", "https://127.0.0.1:4023", "https://127.0.0.1:4022"]}
  end)
}})

{:ok, _} = Supervisor.start_child(WebWidget.Supervisor, {WebWidget.Runtime, %{
  channel_config_id: :origin_tests,
  sink_mfa: {WebWidget.MockHost, :handle_event, []},
     pubsub_server: WebWidget.PubSub,
  widgets: [
    %{widget_id: "42", display_name: "Installed widget", allowed_domains: ["http://127.0.0.1:4019"]},
    %{widget_id: "theme-light", display_name: "Light assistant", allowed_domains: ["http://127.0.0.1:4019"]},
    %{widget_id: "theme-dark", display_name: "Dark assistant", multiple_conversations: true, allowed_domains: ["http://127.0.0.1:4019"]},
    %{widget_id: "theme-custom", display_name: "Custom assistant", stylesheet_url: "/custom-widget.css", allowed_domains: ["http://127.0.0.1:4019"]},
    %{widget_id: "multi", display_name: "Conversation history", multiple_conversations: true, allowed_domains: ["http://127.0.0.1:4019"]},
    %{widget_id: "cross-origin", display_name: "Cross origin", allowed_domains: ["http://127.0.0.1:4019"]},
    %{widget_id: "no-origins", display_name: "Disabled"},
    %{widget_id: "empty-origins", display_name: "Disabled", allowed_domains: []}
  ]
}})

{:ok, _} = Supervisor.start_child(WebWidget.Supervisor, {WebWidget.Runtime, %{
  channel_config_id: :locale_tests,
  sink_mfa: {WebWidget.MockHost, :handle_event, []},
  pubsub_server: WebWidget.PubSub,
  widgets: Enum.map(["en", "fr", "ar"], fn locale ->
    %{widget_id: "locale-#{locale}", display_name: "Host assistant",
      multiple_conversations: true, allowed_domains: ["http://127.0.0.1:4019"]}
  end)
}})
