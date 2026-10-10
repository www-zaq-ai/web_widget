defmodule WebWidget.Embedding.SessionTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Plug.Conn

  alias Phoenix.LiveView.Session, as: LiveViewSession
  alias Phoenix.Socket.Transport
  alias Phoenix.Transports.WebSocket
  alias WebWidget.Embedding.Session
  alias WebWidget.Embedding.Socket
  @endpoint WebWidget.TestHost.Endpoint

  defp configure(opts), do: :ets.insert(@endpoint, {:web_widget_session, opts})

  setup do
    previous = Application.get_env(:web_widget, @endpoint)

    Application.put_env(:web_widget, @endpoint,
      secret_key_base: String.duplicate("host", 16),
      live_view: [signing_salt: "host-live"],
      pubsub_server: WebWidget.PubSub,
      check_origin: false,
      server: false,
      web_widget_session: [partitioned: false]
    )

    start_supervised!(@endpoint)
    on_exit(fn -> Application.put_env(:web_widget, @endpoint, previous) end)

    start_supervised!(
      {WebWidget.Runtime,
       %{
         channel_config_id: :cookie_policy_test,
         sink_mfa: {__MODULE__, :unused, []},
         widgets:
           for {id, policy} <- [{"none", "None"}, {"lax", "Lax"}, {"strict", "Strict"}] do
             %{
               widget_id: id,
               same_site: policy,
               display_name: id,
               allowed_domains: ["https://parent.example"]
             }
           end
       }}
    )

    :ok
  end

  test "isolated attributes, custom prefixes, and explicit HTTP behavior" do
    for {id, value} <- [{"none", "None"}, {"lax", "Lax"}, {"strict", "Strict"}],
        prefix <- ["/widget", "/support/chat"] do
      path = prefix <> "/" <> id
      conn = get(build_conn(), "https://www.example.com" <> path)
      refute Map.has_key?(conn.resp_cookies, "_web_widget_session")
      bootstrap = get(build_conn(), "https://www.example.com" <> path <> "/session")
      cookie = bootstrap.resp_cookies["_web_widget_session"]
      assert cookie.path == path
      assert cookie.same_site == value
      assert cookie.secure
      assert cookie.http_only
      refute Map.has_key?(cookie, :domain)
      refute Map.has_key?(conn.resp_cookies, "_host")
      assert html_response(conn, 200) =~ "content=\"#{path}/live\""
      assert html_response(conn, 200) =~ "content=\"#{path}/session\""
    end

    assert response(get(build_conn(), "/widget/none"), 503) == "https_required"
    conn = get(build_conn(), "/widget/lax/session")
    refute conn.resp_cookies["_web_widget_session"].secure
  end

  test "real Phoenix handshake decodes scoped cookie and validates CSRF" do
    for prefix <- ["/widget", "/support/chat"], transport <- ["websocket", "longpoll"] do
      path = prefix <> "/none"
      page = get(build_conn(), "https://www.example.com" <> path <> "/session")
      token = json_response(page, 200)["csrf_token"]

      info = handshake(page, path <> "/live/" <> transport, token)
      assert info.session["web_widget_id"] == "none"
      assert Session.valid_scope?(info.session, "none", info.uri)
      socket = %Phoenix.Socket{endpoint: @endpoint}
      assert {:ok, _} = Socket.connect(%{"widget_id" => "none"}, socket, info)
      assert :error = Socket.connect(%{"widget_id" => "lax"}, socket, info)

      wrong_path = handshake(page, prefix <> "/lax/live/" <> transport, token)
      assert :error = Socket.connect(%{"widget_id" => "lax"}, socket, wrong_path)
      assert :error = Socket.connect(%{"widget_id" => "none"}, socket, wrong_path)
      bad_csrf = handshake(page, path <> "/live/" <> transport, "forged")
      assert is_nil(bad_csrf.session)
      assert :error = Socket.connect(%{"widget_id" => "none"}, socket, bad_csrf)
      assert :error = Socket.connect(%{}, socket, info)
      assert Session.page_scope?(info.session, "none", info.uri)
      refute Session.page_scope?(info.session, "none", wrong_path.uri)
    end
  end

  test "partitioning defaults on for every SameSite policy and requires HTTPS" do
    configure([])

    for id <- ["none", "lax", "strict"] do
      conn = get(build_conn(), "https://www.example.com/widget/#{id}/session")
      cookie = conn.resp_cookies["_web_widget_session"]
      assert cookie.extra == "Partitioned"
      assert cookie.secure
      assert cookie.http_only

      assert get_resp_header(conn, "set-cookie")
             |> Enum.any?(&String.contains?(&1, "; Partitioned"))

      assert response(get(build_conn(), "/widget/#{id}/session"), 503) == "https_required"
    end

    configure(partitioned: true, secure: false)

    assert {:ok, %{secure: true, partitioned: true}} =
             Session.effective(%{same_site: "Lax"}, @endpoint, :https)

    configure(partitioned: "true")

    assert response(get(build_conn(), "https://www.example.com/widget/lax/session"), 503) ==
             "invalid_partitioned_policy"

    configure(partitioned: false)
    conn = get(build_conn(), "/widget/lax/session")
    refute conn.resp_cookies["_web_widget_session"].secure
    refute Map.has_key?(conn.resp_cookies["_web_widget_session"], :extra)
  end

  test "widget pages neither consume nor rewrite the BO cookie" do
    bo = get(build_conn(), "/bo-session")
    assert response(bo, 200) == "admin"
    host_cookie = bo.resp_cookies["_host"]

    widget =
      build_conn()
      |> Plug.Test.put_req_cookie("_host", host_cookie.value)
      |> get("/widget/lax")

    assert html_response(widget, 200)
    refute Map.has_key?(widget.resp_cookies, "_host")
    refute Map.has_key?(get_session(widget), "bo_user")
    refute Map.has_key?(widget.resp_cookies, "_web_widget_session")

    bootstrap =
      build_conn()
      |> Plug.Test.put_req_cookie("_host", host_cookie.value)
      |> get("/widget/lax/session")

    refute Map.has_key?(bootstrap.resp_cookies, "_host")
    refute Map.has_key?(get_session(bootstrap), "bo_user")

    again =
      build_conn()
      |> Plug.Test.put_req_cookie("_host", host_cookie.value)
      |> Plug.Test.put_req_cookie(
        "_web_widget_session",
        bootstrap.resp_cookies["_web_widget_session"].value
      )
      |> get("/bo-session")

    assert response(again, 200) == "admin"
    assert again.resp_cookies["_host"] == host_cookie
    refute Map.has_key?(again.resp_cookies, "_web_widget_session")
  end

  test "independent signed pages accept one shared session established after rendering" do
    first = get(build_conn(), "https://www.example.com/widget/none")
    second = get(build_conn(), "https://www.example.com/widget/none")
    refute Map.has_key?(first.resp_cookies, "_web_widget_session")
    refute Map.has_key?(second.resp_cookies, "_web_widget_session")

    ids =
      for page <- [first, second] do
        root =
          page
          |> html_response(200)
          |> LazyHTML.from_document()
          |> LazyHTML.query("[data-phx-main]")

        [id] = LazyHTML.attribute(root, "id")
        [token] = LazyHTML.attribute(root, "data-phx-session")
        [static] = LazyHTML.attribute(root, "data-phx-static")

        assert {:ok, %{id: ^id}} =
                 LiveViewSession.verify_session(@endpoint, "lv:" <> id, token, static)

        id
      end

    assert Enum.uniq(ids) == ids
    shared = get(build_conn(), "https://www.example.com/widget/none/session")

    reused =
      build_conn()
      |> Plug.Test.put_req_cookie(
        "_web_widget_session",
        shared.resp_cookies["_web_widget_session"].value
      )
      |> get("https://www.example.com/widget/none/session?verify=1")

    refute Map.has_key?(reused.resp_cookies, "_web_widget_session")
    assert get_session(shared, "_csrf_token") == get_session(reused, "_csrf_token")
    socket = %Phoenix.Socket{endpoint: @endpoint}

    for response <- [shared, reused], transport <- ["websocket", "longpoll"] do
      path = "/widget/none/live/" <> transport
      info = handshake(shared, path, json_response(response, 200)["csrf_token"])
      assert {:ok, _} = Socket.connect(%{"widget_id" => "none"}, socket, info)
    end
  end

  test "a manually copied cookie cannot carry session state across widget scopes" do
    first = get(build_conn(), "https://www.example.com/widget/lax/session")

    second =
      build_conn()
      |> Plug.Test.put_req_cookie(
        "_web_widget_session",
        first.resp_cookies["_web_widget_session"].value
      )
      |> get("https://www.example.com/widget/strict/session")

    assert get_session(second, "web_widget_id") == "strict"
    assert get_session(second, "web_widget_path") == "/widget/strict"
    refute get_session(first, "_csrf_token") == get_session(second, "_csrf_token")
    assert second.resp_cookies["_web_widget_session"].path == "/widget/strict"

    info =
      handshake(second, "/widget/strict/live/websocket", json_response(second, 200)["csrf_token"])

    assert {:ok, _} =
             Socket.connect(
               %{"widget_id" => "strict"},
               %Phoenix.Socket{endpoint: @endpoint},
               info
             )

    refute Map.has_key?(info.session, "identity_token")
  end

  test "tampered cookies initialize fresh anonymous state only on bootstrap" do
    for path <- ["/widget/lax/session", "/support/chat/lax/session"] do
      conn =
        build_conn() |> Plug.Test.put_req_cookie("_web_widget_session", "forged") |> get(path)

      assert json_response(conn, 200)["csrf_token"]
      assert get_session(conn, "web_widget_id") == "lax"

      assert Map.keys(get_session(conn)) |> Enum.sort() ==
               Enum.sort([
                 "web_widget_id",
                 "web_widget_path",
                 "web_widget_same_site",
                 "_csrf_token"
               ])

      verified =
        build_conn()
        |> Plug.Test.put_req_cookie("_web_widget_session", "forged")
        |> get(path <> "?verify=1")

      assert response(verified, 409) == "cookie_unavailable"
      refute Map.has_key?(verified.resp_cookies, "_web_widget_session")
    end
  end

  test "duplicate raw cookies reject pages, bootstrap and both socket transports before parsing" do
    initialized = get(build_conn(), "https://www.example.com/widget/none/session")
    valid = initialized.resp_cookies["_web_widget_session"].value
    csrf = json_response(initialized, 200)["csrf_token"]

    for prefix <- ["/widget", "/support/chat"],
        suffix <- ["", "/session", "/session?verify=1", "/live/websocket", "/live/longpoll"],
        values <- [[valid, "forged"], ["forged", valid], [valid, valid]],
        separate <- [false, true] do
      path = prefix <> "/none" <> suffix

      path =
        if String.contains?(suffix, "/live/"),
          do: path <> "?_csrf_token=" <> URI.encode_www_form(csrf),
          else: path

      headers = Enum.map(values, &{"cookie", "_web_widget_session=" <> &1})

      headers =
        if separate, do: headers, else: [{"cookie", Enum.map_join(headers, "; ", &elem(&1, 1))}]

      conn = %{build_conn() | req_headers: headers}
      rejected = get(conn, "https://www.example.com" <> path)
      assert response(rejected, 400) == "ambiguous_widget_cookie"
      refute Map.has_key?(rejected.resp_cookies, "_web_widget_session")
      assert %Plug.Conn.Unfetched{} = rejected.req_cookies
    end
  end

  test "duplicate unrelated cookies and BO paths are not rejected" do
    conn =
      build_conn() |> put_req_header("cookie", "other=a; other=b") |> get("/widget/lax/session")

    assert json_response(conn, 200)["csrf_token"]

    bo =
      build_conn()
      |> put_req_header("cookie", "_web_widget_session=a; _web_widget_session=b")
      |> get("/bo-session")

    assert response(bo, 200) == "admin"
  end

  test "policy validation distinguishes omission from invalid explicit values" do
    assert Session.validate_settings(%{}) == {:error, :missing_cookie_policy}
    assert Session.validate_settings(nil) == {:error, :missing_cookie_policy}

    for value <- ["None", "Lax", "Strict"] do
      assert Session.validate_settings(%{"same_site" => value}) == {:ok, value}
    end

    for value <- [nil, "", "none", " None", false] do
      assert Session.validate_settings(%{"same_site" => value}) ==
               {:error, :invalid_cookie_policy}
    end

    assert {:error, :missing_cookie_policy} = Session.effective(%{}, @endpoint, :http)
  end

  test "endpoint policy cannot supply a missing widget policy" do
    for fallback <- ["None", "Lax", "Strict", "invalid"] do
      endpoint_policy(same_site: fallback, partitioned: false)
      assert {:error, :missing_cookie_policy} = Session.effective(%{}, @endpoint, :https)

      assert {:ok, %{same_site: "None", source: :connector, secure: true}} =
               Session.effective(%{same_site: "None"}, @endpoint, :https)
    end

    assert {:error, :cookie_policy_unsupported} =
             Session.effective(%{same_site: :inherit}, @endpoint, :https)

    endpoint_policy(secure: "true")

    assert {:error, :secure_cookie_required} =
             Session.effective(%{same_site: "Lax"}, @endpoint, :https)
  end

  test "HTTPS always forces Secure even when the endpoint disables it" do
    for partitioned <- [false, true], policy <- ["None", "Lax", "Strict"] do
      configure(partitioned: partitioned, secure: false)
      id = String.downcase(policy)
      conn = get(build_conn(), "https://www.example.com/widget/#{id}/session")
      assert conn.resp_cookies["_web_widget_session"].secure
      assert {:ok, %{secure: true}} = Session.effective(%{same_site: policy}, @endpoint, :https)
    end

    configure(partitioned: false, secure: false)

    for policy <- ["Lax", "Strict"] do
      assert {:ok, %{secure: false}} = Session.effective(%{same_site: policy}, @endpoint, :http)
    end

    assert {:error, :https_required} = Session.effective(%{same_site: "None"}, @endpoint, :http)
  end

  test "a changed policy rejects the old session and reload issues the replacement" do
    page = get(build_conn(), "https://www.example.com/widget/lax/session")
    token = json_response(page, 200)["csrf_token"]

    old_info = handshake(page, "/widget/lax/live/websocket", token)
    socket = %Phoenix.Socket{endpoint: @endpoint}
    assert {:ok, _} = Socket.connect(%{"widget_id" => "lax"}, socket, old_info)

    stop_supervised!({WebWidget.Runtime, :cookie_policy_test})

    start_supervised!(
      {WebWidget.Runtime,
       %{
         channel_config_id: :cookie_policy_test,
         sink_mfa: {__MODULE__, :unused, []},
         widgets: [
           %{
             widget_id: "lax",
             same_site: "Strict",
             display_name: "Changed",
             allowed_domains: ["https://parent.example"]
           }
         ]
       }}
    )

    assert :error = Socket.connect(%{"widget_id" => "lax"}, socket, old_info)
    reloaded = get(build_conn(), "https://www.example.com/widget/lax/session")
    assert reloaded.resp_cookies["_web_widget_session"].same_site == "Strict"
    refute Map.has_key?(reloaded.resp_cookies, "_host")
  end

  test "fetching the BO session before the widget pipeline is rejected" do
    conn = Plug.Test.conn(:get, "/widget/lax") |> Plug.Test.init_test_session(%{bo_user: "admin"})
    assert_raise ArgumentError, ~r/outside pipelines/, fn -> Session.call(conn, []) end
  end

  defp endpoint_policy(opts) do
    config = Application.fetch_env!(:web_widget, @endpoint)
    @endpoint.config_change(%{@endpoint => Keyword.put(config, :web_widget_session, opts)}, [])
  end

  defp handshake(page, path, token) do
    conn =
      Plug.Test.conn(:get, path <> "?_csrf_token=" <> URI.encode_www_form(token))
      |> Plug.Test.put_req_cookie(
        "_web_widget_session",
        page.resp_cookies["_web_widget_session"].value
      )
      |> fetch_query_params()

    conn = %{conn | scheme: :https}

    config =
      Transport.load_config(
        [connect_info: [:uri, session: Session.options()]],
        WebSocket
      )

    Transport.connect_info(conn, @endpoint, config[:connect_info])
  end
end
