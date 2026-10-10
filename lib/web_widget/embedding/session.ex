defmodule WebWidget.Embedding.Session do
  @moduledoc """
  Widget-only session installation and effective cookie policy.

  Every widget explicitly supplies its SameSite policy. Endpoint options control
  partitioning and optional Secure requirements for HTTP development. HTTPS always
  forces Secure. Partitioning is enabled by default and, like None, requires HTTPS.
  """
  import Plug.Conn
  alias WebWidget.Embedding.{CookieGuard, FramePolicy, Unavailable}

  @scope_id "web_widget_id"
  @scope_path "web_widget_path"
  @policy "web_widget_same_site"

  def options do
    [store: :cookie, key: "_web_widget_session", signing_salt: "web-widget-session-v1"]
  end

  def validate_settings(settings) when is_map(settings) do
    case Map.fetch(settings, "same_site") do
      :error -> {:error, :missing_cookie_policy}
      {:ok, value} when value in ["None", "Lax", "Strict"] -> {:ok, value}
      _ -> {:error, :invalid_cookie_policy}
    end
  end

  def validate_settings(nil), do: {:error, :missing_cookie_policy}
  def validate_settings(_), do: {:error, :invalid_cookie_policy}

  @doc "Resolves the installed widget pipeline's cookie policy; not a transport readiness probe."
  def effective(widget, endpoint, scheme) do
    opts = endpoint.config(:web_widget_session, [])
    value = Map.get(widget, :same_site)
    secure = Keyword.get(opts, :secure, false)
    partitioned = Keyword.get(opts, :partitioned, true)

    resolve_policy(value, secure, partitioned, :connector, scheme)
  end

  defp resolve_policy(value, secure, partitioned, source, scheme) do
    cond do
      is_nil(value) ->
        {:error, :missing_cookie_policy}

      value not in ["None", "Lax", "Strict"] ->
        {:error, :cookie_policy_unsupported}

      not is_boolean(partitioned) ->
        {:error, :invalid_partitioned_policy}

      not is_boolean(secure) ->
        {:error, :secure_cookie_required}

      https_required?(value, secure, partitioned) and scheme not in [:https, "https"] ->
        {:error, :https_required}

      true ->
        {:ok,
         %{
           same_site: value,
           secure: secure_cookie?(secure, partitioned, scheme),
           partitioned: partitioned,
           source: source
         }}
    end
  end

  defp https_required?(value, secure, partitioned), do: secure or partitioned or value == "None"

  defp secure_cookie?(secure, partitioned, scheme),
    do: secure or partitioned or scheme in [:https, "https"]

  def init(opts), do: opts

  def call(conn, _opts) do
    conn = CookieGuard.call(conn)

    if conn.halted, do: conn, else: install_request(conn)
  end

  defp install_request(conn) do
    if conn.private[:plug_session_fetch] == :done do
      raise ArgumentError,
            "mount web_widget outside pipelines that fetch the host session"
    end

    id = conn.path_params["widget_id"] || ""
    bootstrap? = conn.private[:web_widget_session_bootstrap] == true
    conn = put_resp_header(conn, "cache-control", "no-store")

    case WebWidget.Runtime.fetch_widget(id) do
      {:ok, widget} ->
        install_widget(conn, widget, id, bootstrap?)

      _ ->
        conn
        |> Phoenix.Controller.put_secure_browser_headers()
        |> FramePolicy.call([])
        |> Unavailable.call([])
        |> halt()
    end
  end

  defp install_widget(conn, widget, id, bootstrap?) do
    cond do
      bootstrap? and not same_origin?(conn) ->
        conn |> send_resp(403, "session_bootstrap_forbidden") |> halt()

      bootstrap? and Map.get(widget, :allowed_domains, []) == [] ->
        conn |> send_resp(404, "widget_unavailable") |> halt()

      true ->
        case effective(widget, conn.private.phoenix_endpoint, conn.scheme) do
          {:ok, policy} -> install(conn, id, policy)
          {:error, reason} -> conn |> send_resp(503, Atom.to_string(reason)) |> halt()
        end
    end
  end

  defp same_origin?(conn) do
    origin =
      URI.to_string(%URI{scheme: Atom.to_string(conn.scheme), host: conn.host, port: conn.port})

    get_req_header(conn, "sec-fetch-site") in [[], ["same-origin"]] and
      get_req_header(conn, "origin") in [[], [origin]]
  end

  defp install(conn, id, policy) do
    bootstrap? = conn.private[:web_widget_session_bootstrap] == true
    path = if bootstrap?, do: Path.dirname(conn.request_path), else: conn.request_path

    opts =
      options() ++
        [path: path, same_site: policy.same_site, secure: policy.secure, http_only: true] ++
        if(policy.partitioned, do: [extra: "Partitioned"], else: [])

    conn = conn |> Plug.Session.call(Plug.Session.init(opts)) |> fetch_session()

    established? = established?(conn, id, path, policy)

    if bootstrap? and fetch_query_params(conn).query_params["verify"] == "1" and not established? do
      conn |> send_resp(409, "cookie_unavailable") |> halt()
    else
      conn = if established?, do: conn, else: new_scope(conn, id, path, policy)
      conn = if bootstrap?, do: conn, else: configure_session(conn, ignore: true)

      conn
      |> assign(:web_widget_socket_path, path <> "/live")
      |> assign(:web_widget_session_path, path <> "/session")
    end
  end

  defp established?(conn, id, path, policy) do
    get_session(conn, @scope_id) == id and get_session(conn, @scope_path) == path and
      get_session(conn, @policy) == policy.same_site and
      is_binary(get_session(conn, "_csrf_token"))
  end

  defp new_scope(conn, id, path, policy) do
    Plug.CSRFProtection.delete_csrf_token()

    conn
    |> clear_session()
    |> configure_session(renew: true)
    |> put_session(@scope_id, id)
    |> put_session(@scope_path, path)
    |> put_session(@policy, policy.same_site)
  end

  def valid_scope?(session, id, uri) when is_map(session) and is_struct(uri, URI) do
    path = session[@scope_path]

    is_binary(path) and session[@scope_id] == id and
      uri.path in [path <> "/live/websocket", path <> "/live/longpoll"]
  end

  def valid_scope?(_, _, _), do: false

  def valid_policy?(session, widget, endpoint, scheme) do
    case effective(widget, endpoint, scheme) do
      {:ok, policy} -> session[@policy] == policy.same_site
      _ -> false
    end
  end

  def page_scope?(session, id, %URI{} = uri) do
    session[@scope_id] == id and
      (valid_scope?(session, id, uri) or uri.path == session[@scope_path])
  end

  def page_scope?(_, _, _), do: false
end
