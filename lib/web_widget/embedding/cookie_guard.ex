defmodule WebWidget.Embedding.CookieGuard do
  @moduledoc false
  import Plug.Conn

  def duplicate?(conn) do
    conn
    |> get_req_header("cookie")
    |> Enum.flat_map(&String.split(&1, ";"))
    |> Enum.count(fn pair ->
      case String.split(String.trim(pair), "=", parts: 2) do
        ["_web_widget_session", _value] -> true
        _ -> false
      end
    end)
    |> Kernel.>(1)
  end

  def call(conn) do
    if duplicate?(conn) do
      conn |> send_resp(400, "ambiguous_widget_cookie") |> halt()
    else
      conn
    end
  end

  def call(conn, prefixes) do
    if Enum.any?(prefixes, fn prefix ->
         conn.request_path == prefix or String.starts_with?(conn.request_path, prefix <> "/")
       end) do
      call(conn)
    else
      conn
    end
  end
end
