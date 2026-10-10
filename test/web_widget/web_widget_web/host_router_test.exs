defmodule WebWidget.HostRouterTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint WebWidget.TestHost.Endpoint

  setup_all do
    Application.put_env(:web_widget, @endpoint,
      secret_key_base: String.duplicate("host", 16),
      live_view: [signing_salt: "host-live"],
      pubsub_server: WebWidget.PubSub,
      server: false,
      web_widget_session: [partitioned: false]
    )

    start_supervised!(@endpoint)
    on_exit(fn -> Application.delete_env(:web_widget, @endpoint) end)
    :ok
  end

  setup do
    config = %{
      channel_config_id: :host_test,
      sink_mfa: {__MODULE__, :unused, []},
      widgets: [
        %{
          widget_id: "support",
          display_name: "Host Support",
          allowed_domains: ["https://customer.com", "http://www.example.com"]
        }
      ]
    }

    start_supervised!({WebWidget.Runtime, config})
    :ok
  end

  test "default and custom scoped prefixes render using the host endpoint" do
    for path <- ["/widget/support", "/support/chat/support"] do
      conn = get(build_conn(), path)
      document = LazyHTML.from_document(html_response(conn, 200))
      assert LazyHTML.query(document, "title") |> LazyHTML.text() == "Host Support"
      assert LazyHTML.query(document, "body.zaq-widget-page") |> Enum.count() == 1

      {:ok, view, _} = live(conn)
      assert has_element?(view, "#widget-context[phx-hook='WidgetContext']")
      render_hook(view, "widget.context", %{user_id: "user"})
      assert has_element?(view, "#web-widget[phx-hook='ReactHook']")
      assert :sys.get_state(view.pid).socket.endpoint == @endpoint
      assert :sys.get_state(view.pid).socket.assigns.config.title == "Host Support"
    end
  end

  test "framing uses only configured origins and preserves unrelated CSP directives" do
    for path <- ["/widget/support", "/support/chat/support"] do
      conn =
        build_conn()
        |> Plug.Conn.put_resp_header(
          "content-security-policy",
          "default-src 'self'; frame-ancestors 'self'"
        )
        |> get(path)

      assert Plug.Conn.get_resp_header(conn, "content-security-policy") ==
               ["default-src 'self'; frame-ancestors https://customer.com http://www.example.com"]

      assert Plug.Conn.get_resp_header(conn, "x-frame-options") == []
    end
  end

  test "missing, null and empty origins disable HTTP and connected widgets" do
    for {widget, index} <-
          Enum.with_index([
            %{widget_id: "disabled", display_name: "Disabled"},
            %{widget_id: "disabled", display_name: "Disabled", allowed_domains: nil},
            %{widget_id: "disabled", display_name: "Disabled", allowed_domains: []}
          ]) do
      id = {:disabled, index}

      start_supervised!(
        {WebWidget.Runtime,
         %{
           channel_config_id: id,
           sink_mfa: {__MODULE__, :unused, []},
           widgets: [widget]
         }}
      )

      conn = get(build_conn(), "/widget/disabled")

      assert Plug.Conn.get_resp_header(conn, "content-security-policy") == [
               "base-uri 'self'; frame-ancestors 'none'"
             ]

      document = LazyHTML.from_document(html_response(conn, 200))
      assert Enum.empty?(LazyHTML.query(document, "[phx-hook]"))
      {:ok, view, _} = live(conn)
      assert has_element?(view, "#widget-unavailable")
      render_hook(view, "widget.context", %{user_id: "user"})
      render_hook(view, "widget.submit", %{text: "hello"})
      refute has_element?(view, "[phx-hook]")
      stop_supervised!({WebWidget.Runtime, id})
    end
  end

  test "connected mount rechecks origins after HTTP rendering" do
    conn = get(build_conn(), "/widget/support")
    stop_supervised!({WebWidget.Runtime, :host_test})

    start_supervised!(
      {WebWidget.Runtime,
       %{
         channel_config_id: :host_test,
         sink_mfa: {__MODULE__, :unused, []},
         widgets: [%{widget_id: "support", display_name: "Support", allowed_domains: []}]
       }}
    )

    {:ok, view, _} = live(conn)
    assert has_element?(view, "#widget-unavailable")
    refute has_element?(view, "[phx-hook]")
  end

  test "unknown widgets have no hooks and reject context and submissions" do
    {:ok, view, _} = live(build_conn(), "/widget/missing")
    assert has_element?(view, "#widget-unavailable")
    refute has_element?(view, "[phx-hook]")
    render_hook(view, "widget.context", %{user_id: "user"})
    render_hook(view, "widget.submit", %{text: "hello"})
    assert has_element?(view, "#widget-unavailable")
  end

  test "incomplete and malformed widget paths return a safe 404" do
    for path <- [
          "/widget",
          "/widget/",
          "/widget/support/extra",
          "/support/chat",
          "/support/chat/support/extra"
        ] do
      conn = get(build_conn(), path)
      body = html_response(conn, 404)
      document = LazyHTML.from_document(body)
      assert LazyHTML.query(document, "#widget-unavailable") |> Enum.count() == 1
      assert Enum.empty?(LazyHTML.query(document, "[phx-hook], script"))
      refute body =~ "NoRouteError"

      assert Plug.Conn.get_resp_header(conn, "content-security-policy") ==
               ["base-uri 'self'; frame-ancestors 'none'"]
    end
  end

  test "connected mount rechecks availability after the HTTP render" do
    conn = get(build_conn(), "/widget/support")
    stop_supervised!({WebWidget.Runtime, :host_test})
    {:ok, view, _} = live(conn)
    assert has_element?(view, "#widget-unavailable")
    refute has_element?(view, "#widget-context")
  end

  test "layout assets are served by the host endpoint" do
    conn = get(build_conn(), "/widget/support")
    document = LazyHTML.from_document(html_response(conn, 200))

    for {selector, attr, content_type} <- [
          {"script[src]", "src", "javascript"},
          {"link[rel='stylesheet']", "href", "text/css"}
        ] do
      [path] = document |> LazyHTML.query(selector) |> LazyHTML.attribute(attr)
      asset = get(build_conn(), path)
      assert byte_size(response(asset, 200)) > 1000

      assert Enum.any?(
               Plug.Conn.get_resp_header(asset, "content-type"),
               &String.contains?(&1, content_type)
             )
    end
  end

  test "the macro serves the complete bundle and revalidates cached assets" do
    for {file, content_type} <- [
          {"embed.js", "text/javascript"},
          {"app.js", "text/javascript"},
          {"app.css", "text/css"},
          {"web-widget.js", "text/javascript"},
          {"web-widget.css", "text/css"},
          {"widget-client.js", "text/javascript"}
        ] do
      conn = get(build_conn(), "/web_widget/assets/#{file}")
      assert byte_size(response(conn, 200)) > 100
      assert [^content_type] = Plug.Conn.get_resp_header(conn, "content-type")

      assert ["public, max-age=0, must-revalidate"] =
               Plug.Conn.get_resp_header(conn, "cache-control")

      [etag] = Plug.Conn.get_resp_header(conn, "etag")

      cached =
        build_conn()
        |> Plug.Conn.put_req_header("if-none-match", etag)
        |> get("/web_widget/assets/#{file}")

      assert response(cached, 304) == ""
    end
  end

  test "missing asset paths return 404" do
    assert response(get(build_conn(), "/web_widget/assets/missing.js"), 404) == "Not found"

    assert response(get(build_conn(), "/web_widget/assets/nested/missing.css"), 404) ==
             "Not found"
  end

  test "asset paths cannot escape the dependency's static directory" do
    conn = Plug.Test.conn(:get, "/web_widget/assets/%2e%2e/robots.txt")

    assert_raise Plug.Static.InvalidPathError, fn ->
      WebWidget.Static.call(conn, WebWidget.Static.init([]))
    end
  end

  test "connected mount uses replacement runtime configuration, not stale HTTP configuration" do
    conn = get(build_conn(), "/widget/support")
    stop_supervised!({WebWidget.Runtime, :host_test})

    start_supervised!(
      {WebWidget.Runtime,
       %{
         channel_config_id: :host_test,
         sink_mfa: {__MODULE__, :unused, []},
         widgets: [
           %{
             widget_id: "support",
             display_name: "Replacement",
             allowed_domains: ["https://customer.com", "http://www.example.com"]
           }
         ]
       }}
    )

    {:ok, view, _} = live(conn)
    render_hook(view, "widget.context", %{user_id: "user"})
    assert :sys.get_state(view.pid).socket.assigns.config.title == "Replacement"
  end

  test "browser context cannot replace the widget selected by the host route" do
    {:ok, view, _} = live(build_conn(), "/support/chat/support")

    render_hook(view, "widget.context", %{
      user_id: "user",
      widget_id: "another-widget",
      display_name: "Browser-supplied title"
    })

    %{socket: %{assigns: assigns}} = :sys.get_state(view.pid)
    assert assigns.widget_id == "support"
    assert assigns.config.title == "Host Support"
  end
end
