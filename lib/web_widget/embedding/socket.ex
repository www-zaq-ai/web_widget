defmodule WebWidget.Embedding.Socket do
  @moduledoc "Widget-scoped LiveView socket with standard Phoenix session/CSRF verification."
  use Phoenix.LiveView.Socket

  alias WebWidget.Embedding.Session

  @impl Phoenix.Socket
  defdelegate id(socket), to: Phoenix.LiveView.Socket

  @impl Phoenix.Socket
  def connect(%{"widget_id" => id}, socket, %{session: session, uri: uri}) do
    with true <- Session.valid_scope?(session, id, uri),
         {:ok, widget} <- WebWidget.Runtime.fetch_widget(id),
         true <- Session.valid_policy?(session, widget, socket.endpoint, uri.scheme) do
      {:ok, socket}
    else
      _ -> :error
    end
  end

  def connect(_, _, _), do: :error
end
