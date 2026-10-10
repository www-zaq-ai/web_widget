# Run from ZAQ: MIX_ENV=test mix run ../web_widget/test/support/integration/host_mount_smoke.exs
ExUnit.start()

defmodule WebWidget.HostMountSmokeTest do
  # credo:disable-for-next-line Credo.Check.Warning.WrongTestFilename
  use ExUnit.Case
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Zaq.Channels.CommunicationBridge
  alias Zaq.Channels.WebBridge

  @endpoint ZaqWeb.Endpoint

  test "ZAQ serves widget assets and a connected iframe without BO login" do
    config = %{
      id: 2_000_000_000 + System.unique_integer([:positive]),
      name: "Mounted widget smoke",
      provider: "web_widget",
      enabled: true,
      settings: %{"allowed_domains" => ["http://localhost:4010"], "same_site" => "Lax"}
    }

    on_exit(fn -> WebBridge.stop_runtime(config) end)
    assert :ok = CommunicationBridge.sync_config_runtime(nil, config)

    conn = get(build_conn(), "/widget/#{config.id}")
    document = conn |> html_response(200) |> LazyHTML.from_document()
    assert document |> LazyHTML.query("#widget-state") |> Enum.count() == 1
    assert [policy] = Plug.Conn.get_resp_header(conn, "content-security-policy")
    assert policy =~ "frame-ancestors http://localhost:4010"
    assert Plug.Conn.get_resp_header(conn, "x-frame-options") == []
    {:ok, view, _} = live(conn)
    assert has_element?(view, "#widget-state")

    for path <- [
          "/web_widget/assets/embed.js",
          "/web_widget/assets/app.js",
          "/web_widget/assets/app.css"
        ] do
      assert byte_size(response(get(build_conn(), path), 200)) > 100
    end

    assert :ok = WebBridge.stop_runtime(config)
    conn = get(build_conn(), "/widget/#{config.id}")
    document = conn |> html_response(404) |> LazyHTML.from_document()
    assert document |> LazyHTML.query("#widget-unavailable") |> Enum.count() == 1
    assert [policy] = Plug.Conn.get_resp_header(conn, "content-security-policy")
    assert policy =~ "frame-ancestors 'none'"
  end
end
