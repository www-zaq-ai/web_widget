defmodule WebWidget.Embedding.Session do
  @moduledoc """
  Widget-only session installation and effective cookie policy.

  Endpoint `:web_widget_session` options declare the legacy `:same_site` policy
  (default Lax) and optional `:secure` flag. None always requires HTTPS/Secure.
  """
  import Plug.Conn

  @scope_id "web_widget_id"
  @scope_path "web_widget_path"
  @policy "web_widget_same_site"

  def options do
    [store: :cookie, key: "_web_widget_session", signing_salt: "web-widget-session-v1"]
  end

  def validate_settings(settings) when is_map(settings) do
    case Map.fetch(settings, "same_site") do
      :error -> {:ok, :inherit}
      {:ok, value} when value in ["None", "Lax", "Strict"] -> {:ok, value}
      _ -> {:error, :invalid_cookie_policy}
    end
  end

  def validate_settings(nil), do: {:ok, :inherit}
  def validate_settings(_), do: {:error, :invalid_cookie_policy}

  @doc "Resolves the installed widget pipeline's cookie policy; not a transport readiness probe."
  def effective(widget, endpoint, scheme) do
    opts = endpoint.config(:web_widget_session, [])
    desired = Map.get(widget, :same_site, :inherit)
    value = if desired == :inherit, do: Keyword.get(opts, :same_site, "Lax"), else: desired
    secure = value == "None" or Keyword.get(opts, :secure, scheme in [:https, "https"])
    source = if desired == :inherit, do: :endpoint, else: :connector

    cond do
      value not in ["None", "Lax", "Strict"] -> {:error, :cookie_policy_unsupported}
      not is_boolean(secure) -> {:error, :secure_cookie_required}
      secure and scheme not in [:https, "https"] -> {:error, :https_required}
      true -> {:ok, %{same_site: value, secure: secure, source: source}}
    end
  end

  def init(opts), do: opts

  def call(conn, _opts) do
    if conn.private[:plug_session_fetch] == :done do
      raise ArgumentError,
            "mount web_widget outside pipelines that fetch the host session"
    end

    id = conn.path_params["widget_id"] || ""

    widget =
      case WebWidget.Runtime.fetch_widget(id) do
        {:ok, widget} -> widget
        _ -> %{}
      end

    case effective(widget, conn.private.phoenix_endpoint, conn.scheme) do
      {:ok, policy} -> install(conn, id, policy)
      {:error, reason} -> conn |> send_resp(503, Atom.to_string(reason)) |> halt()
    end
  end

  defp install(conn, id, policy) do
    path = conn.request_path

    opts =
      options() ++
        [path: path, same_site: policy.same_site, secure: policy.secure, http_only: true]

    conn
    |> Plug.Session.call(Plug.Session.init(opts))
    |> fetch_session()
    |> isolate_scope(id, path)
    |> put_session(@scope_id, id)
    |> put_session(@scope_path, path)
    |> put_session(@policy, policy.same_site)
    |> assign(:web_widget_socket_path, path <> "/live")
  end

  defp isolate_scope(conn, id, path) do
    if get_session(conn, @scope_id) == id and get_session(conn, @scope_path) == path do
      conn
    else
      Plug.CSRFProtection.delete_csrf_token()
      conn |> clear_session() |> configure_session(renew: true)
    end
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
