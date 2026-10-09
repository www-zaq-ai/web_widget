defmodule WebWidget.TestHost.ReadinessGate do
  @moduledoc false
  def init(opts), do: opts

  def call(conn, _) do
    if pid = conn.private.phoenix_endpoint.config(:readiness_test_gate) do
      send(pid, {:readiness_page, self()})

      receive do
        :release_readiness_page -> :ok
      after
        5_000 -> :ok
      end
    end

    case conn.private.phoenix_endpoint.config(:readiness_test_fault) do
      :csrf -> corrupt_meta(conn, "csrf-token", "forged")
      :socket_path -> corrupt_meta(conn, "web-widget-socket", "/live")
      _ -> conn
    end
  end

  defp corrupt_meta(conn, name, value) do
    Plug.Conn.register_before_send(conn, fn conn ->
      body = IO.iodata_to_binary(conn.resp_body)
      pattern = ~r/(name="#{name}" content=")[^"]+/
      %{conn | resp_body: Regex.replace(pattern, body, "\\1" <> value)}
    end)
  end
end
