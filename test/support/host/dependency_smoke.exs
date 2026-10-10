ExUnit.start()

# Standalone script executed by the dependency-host test, outside mix test discovery.
defmodule WebWidget.DependencyHostSmokeTest do
  # credo:disable-for-next-line Credo.Check.Warning.WrongTestFilename
  use ExUnit.Case
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint WebWidget.TestHost.Endpoint

  test "only the host endpoint and services are required for connected rendering" do
    assert Application.get_env(:web_widget, :start_web_server) == nil
    Application.put_env(:phoenix, :json_library, Jason)
    {:ok, _} = Application.ensure_all_started(:web_widget)

    start_supervised!({Phoenix.PubSub, name: WebWidget.DependencyHostPubSub})
    start_supervised!({WebWidget, pubsub_server: WebWidget.DependencyHostPubSub})

    Application.put_env(:web_widget, @endpoint,
      secret_key_base: String.duplicate("host", 16),
      live_view: [signing_salt: "host-live"],
      pubsub_server: WebWidget.DependencyHostPubSub,
      server: false,
      web_widget_session: [partitioned: false]
    )

    start_supervised!(@endpoint)
    start_supervised!(WebWidget.MockHost)

    start_supervised!(
      {WebWidget.Runtime,
       %{
         channel_config_id: :isolated_host,
         sink_mfa: {WebWidget.MockHost, :handle_event, []},
         pubsub_server: WebWidget.DependencyHostPubSub,
         widgets: [
           %{
             widget_id: "isolated",
             same_site: "Lax",
             display_name: "Isolated host",
             allowed_domains: ["https://customer.com", "http://www.example.com"]
           }
         ]
       }}
    )

    for path <- ["/widget/isolated", "/support/chat/isolated"] do
      conn = get(build_conn(), path)
      document = LazyHTML.from_document(html_response(conn, 200))
      assert document |> LazyHTML.query("title") |> LazyHTML.text() == "Isolated host"

      for {selector, attr} <- [{"script[src]", "src"}, {"link[rel='stylesheet']", "href"}] do
        [asset_path] = document |> LazyHTML.query(selector) |> LazyHTML.attribute(attr)
        assert byte_size(response(get(build_conn(), asset_path), 200)) > 1000
      end

      {:ok, view, _} = live(conn)
      render_hook(view, "widget.context", %{user_id: "host-user"})
      assert has_element?(view, "#web-widget[phx-hook='ReactHook']")
      render_hook(view, "widget.submit", %{text: "Host question"})
      assert has_element?(view, "#widget-state[data-mode='conversation']")
    end

    for name <- [WebWidgetWeb.Endpoint, WebWidget.Repo, WebWidget.PubSub] do
      assert Process.whereis(name) == nil
    end

    assert WebWidget.Runtime.fetch_widget("demo") == {:error, :not_found}
  end
end
