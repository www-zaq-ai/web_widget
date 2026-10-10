defmodule WebWidget.Embedding.SessionBootstrap do
  @moduledoc false
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    csrf_token = Plug.CSRFProtection.get_csrf_token()

    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{csrf_token: csrf_token}))
  end
end
