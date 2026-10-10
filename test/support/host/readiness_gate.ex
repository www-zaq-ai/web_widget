defmodule WebWidget.TestHost.ReadinessGate do
  @moduledoc false
  def init(opts), do: opts

  def call(conn, _) do
    endpoint = conn.private.phoenix_endpoint
    pid = endpoint.config(:readiness_test_gate)

    if pid && gate?(conn, endpoint.config(:readiness_test_gate_stage, :page)) do
      send(pid, {:readiness_page, self()})

      receive do
        :release_readiness_page -> :ok
      after
        5_000 -> :ok
      end
    end

    conn
    |> fault(endpoint.config(:readiness_test_fault))
    |> observe(endpoint.config(:readiness_test_observer))
  end

  defp gate?(conn, :page), do: not String.ends_with?(conn.request_path, "/session")

  defp gate?(conn, :bootstrap),
    do: String.ends_with?(conn.request_path, "/session") and conn.query_string == ""

  defp gate?(conn, :verification),
    do: String.ends_with?(conn.request_path, "/session") and conn.query_string == "verify=1"

  defp fault(conn, :socket_path), do: corrupt_meta(conn, "web-widget-socket", "/live")
  defp fault(conn, :session_path), do: corrupt_meta(conn, "web-widget-session", "/other/session")
  defp fault(conn, :page_csrf), do: corrupt_meta(conn, "csrf-token", "forged-page-token")

  defp fault(conn, fault) do
    cond do
      gate?(conn, :verification) -> verification_fault(conn, fault)
      gate?(conn, :bootstrap) -> bootstrap_fault(conn, fault)
      true -> conn
    end
  end

  defp verification_fault(conn, :csrf), do: replace_json(conn, %{"csrf_token" => "forged"})

  defp verification_fault(conn, :invalid_session_reply),
    do: replace_json(conn, %{"csrf_token" => nil})

  defp verification_fault(conn, :cookie_unavailable),
    do: conn |> Plug.Conn.send_resp(409, "cookie_unavailable") |> Plug.Conn.halt()

  defp verification_fault(conn, :verification_cookie_write),
    do: Plug.Conn.put_resp_cookie(conn, "_web_widget_session", "unexpected-write")

  defp verification_fault(conn, :cacheable_session) do
    Plug.Conn.register_before_send(
      conn,
      &Plug.Conn.put_resp_header(&1, "cache-control", "public")
    )
  end

  defp verification_fault(conn, :invalid_content_type) do
    Plug.Conn.register_before_send(
      conn,
      &Plug.Conn.put_resp_header(&1, "content-type", "application/jsonp")
    )
  end

  defp verification_fault(conn, _), do: conn

  defp bootstrap_fault(conn, :missing_cookie) do
    Plug.Conn.register_before_send(conn, fn conn ->
      %{conn | resp_cookies: Map.delete(conn.resp_cookies, "_web_widget_session")}
    end)
  end

  defp bootstrap_fault(conn, :partitioned_missing),
    do: cookie_fault(conn, &Map.delete(&1, :extra))

  defp bootstrap_fault(conn, :partitioned_extra),
    do: cookie_fault(conn, &Map.put(&1, :extra, "Partitioned"))

  defp bootstrap_fault(conn, :initial_csrf),
    do: replace_json(conn, %{"csrf_token" => "forged-initial-token"})

  defp bootstrap_fault(conn, _), do: conn

  defp cookie_fault(conn, update) do
    Plug.Conn.register_before_send(conn, fn conn ->
      %{conn | resp_cookies: Map.update!(conn.resp_cookies, "_web_widget_session", update)}
    end)
  end

  defp replace_json(conn, value) do
    Plug.Conn.register_before_send(conn, fn conn -> %{conn | resp_body: Jason.encode!(value)} end)
  end

  defp observe(conn, nil), do: conn

  defp observe(conn, pid) do
    send(
      pid,
      {:readiness_request, conn.request_path, conn.query_string,
       Plug.Conn.get_req_header(conn, "cookie") != []}
    )

    observe_response(conn, pid)
  end

  defp observe_response(%{state: :sent} = conn, _), do: conn

  defp observe_response(conn, pid) do
    Plug.Conn.register_before_send(conn, fn conn ->
      cookie = Map.get(conn.resp_cookies, "_web_widget_session", %{})

      send(
        pid,
        {:readiness_response, conn.request_path, conn.query_string,
         Map.take(cookie, [:path, :same_site, :secure, :http_only, :extra])}
      )

      conn
    end)
  end

  defp corrupt_meta(conn, name, value) do
    Plug.Conn.register_before_send(conn, fn conn ->
      body = IO.iodata_to_binary(conn.resp_body)
      pattern = ~r/(name="#{name}" content=")[^"]+/
      %{conn | resp_body: Regex.replace(pattern, body, "\\1" <> value)}
    end)
  end
end
