defmodule WebWidget.TestHost.UnscopedEndpoint do
  @moduledoc false
  use Phoenix.Endpoint, otp_app: :web_widget

  @session_options [store: :cookie, key: "_host", signing_salt: "host-salt"]
  socket "/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]]

  socket "/widget/:widget_id/live", WebWidget.Embedding.Socket,
    websocket: false,
    longpoll: [connect_info: [:uri, session: WebWidget.Embedding.Session.options()]]

  plug Plug.Session, @session_options
  plug WebWidget.TestHost.Router
end
