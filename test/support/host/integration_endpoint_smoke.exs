ExUnit.start()

defmodule WebWidget.IntegrationEndpointSmokeTest do
  # credo:disable-for-next-line Credo.Check.Warning.WrongTestFilename
  use ExUnit.Case
  import Phoenix.ConnTest

  alias WebWidget.Integration.Installation
  alias WebWidget.Integration.RuntimeBuilder
  alias WebWidget.TestIntegration.Host

  @endpoint WebWidgetWeb.Endpoint

  test "configuration starts the package endpoint without a Repo or demo" do
    Application.put_env(:phoenix, :json_library, Jason)
    Application.put_env(:web_widget, :start_integration_server, true)

    Application.put_env(:web_widget, @endpoint,
      adapter: Bandit.PhoenixAdapter,
      url: [host: "127.0.0.1"],
      http: [ip: {127, 0, 0, 1}, port: 0],
      secret_key_base: String.duplicate("isolated-test", 8),
      live_view: [signing_salt: "isolated-test"],
      pubsub_server: WebWidget.PubSub,
      server: true,
      web_widget_session: [partitioned: false]
    )

    {:ok, _} = Application.ensure_all_started(:web_widget)
    assert is_pid(Process.whereis(@endpoint))
    assert is_pid(Process.whereis(WebWidget.PubSub))
    assert Process.whereis(WebWidget.Repo) == nil
    assert Process.whereis(WebWidget.MockHost) == nil
    assert WebWidget.Runtime.fetch_widget("demo") == {:error, :not_found}

    document =
      get(build_conn(), "/widget/missing") |> html_response(404) |> LazyHTML.from_document()

    assert document |> LazyHTML.query("#widget-unavailable") |> Enum.count() == 1
    assert byte_size(response(get(build_conn(), "/web_widget/assets/embed.js"), 200)) > 100

    {:ok, {_ip, port}} = @endpoint.server_info(:http)
    base_url = "http://127.0.0.1:#{port}"
    {config, hooks, opts} = Host.fixture()
    {:ok, {spec, []}} = RuntimeBuilder.build(config, hooks, opts)
    start_supervised!(spec)
    {:ok, snippet} = Installation.script(config.id, base_url)

    [src] =
      snippet |> LazyHTML.from_fragment() |> LazyHTML.query("script") |> LazyHTML.attribute("src")

    assert %{status: 200, body: body} = Req.get!(src)
    assert body =~ "data-widget-id"
    assert %{status: 200, body: body} = Req.get!(base_url <> "/widget/#{config.id}")
    assert body =~ "widget-state"
  end
end
