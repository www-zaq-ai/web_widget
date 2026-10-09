defmodule WebWidget.Endpoint do
  @moduledoc "Endpoint integration for the widget's single scoped LiveView connection."
  alias WebWidget.Embedding.{Session, Socket}

  defmacro web_widget_socket(prefix \\ "/widget") do
    quote do
      socket unquote(prefix) <> "/:widget_id/live", Socket,
        websocket: [connect_info: [:uri, session: Session.options()]],
        longpoll: [connect_info: [:uri, session: Session.options()]]
    end
  end
end
