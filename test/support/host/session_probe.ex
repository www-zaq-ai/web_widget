defmodule WebWidget.TestHost.SessionProbe do
  @moduledoc false
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    user = get_session(conn, :bo_user) || "admin"
    conn |> put_session(:bo_user, user) |> send_resp(200, user)
  end
end
