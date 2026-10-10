defmodule WebWidget.Endpoint do
  @moduledoc "Endpoint integration for the widget's single scoped LiveView connection."
  alias WebWidget.Embedding.{CookieGuard, Session, Socket}

  defmacro web_widget_socket(prefix \\ "/widget") do
    quote do
      unless Module.has_attribute?(__MODULE__, :web_widget_prefixes) do
        Module.register_attribute(__MODULE__, :web_widget_prefixes, accumulate: true)
        @before_compile WebWidget.Endpoint

        def call(conn, opts) do
          case CookieGuard.call(conn, __web_widget_prefixes__()) do
            %{halted: true} = rejected -> rejected
            conn -> super(conn, opts)
          end
        end
      end

      @web_widget_prefixes String.trim_trailing(unquote(prefix), "/")

      socket unquote(prefix) <> "/:widget_id/live", Socket,
        websocket: [connect_info: [:uri, session: Session.options()]],
        longpoll: [connect_info: [:uri, session: Session.options()]]
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    prefixes = Module.get_attribute(env.module, :web_widget_prefixes)

    quote do
      @doc false
      def __web_widget_prefixes__, do: unquote(prefixes)
    end
  end
end
