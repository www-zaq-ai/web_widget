defmodule WebWidget.Router do
  @moduledoc """
  Mounts the widget with its own isolated browser session and CSRF pipeline.

      import WebWidget.Router
      web_widget("/widget")

  The macro serves the dependency's built assets at `/web_widget/assets/`.
  Do not wrap this macro in a host pipeline that fetches the session.
  Mount the matching scoped socket with `WebWidget.Endpoint.web_widget_socket/1`.
  """

  defmacro web_widget(prefix \\ "/widget") do
    session = String.to_atom("web_widget_#{__CALLER__.line}")

    quote do
      alias Phoenix.LiveView.Router, as: LiveViewRouter
      require LiveViewRouter
      import Phoenix.LiveView.Router, only: [fetch_live_flash: 2]

      unless Module.get_attribute(__MODULE__, :web_widget_assets_registered) do
        Module.put_attribute(__MODULE__, :web_widget_assets_registered, true)

        scope "/", alias: false do
          get "/web_widget/assets/*path", WebWidget.Static, [],
            as: nil,
            private: %{plug_skip_csrf_protection: true}
        end
      end

      pipeline unquote(session) do
        plug :accepts, ["html"]
        plug WebWidget.Embedding.Session
        plug :fetch_live_flash
        plug :protect_from_forgery
        plug :put_secure_browser_headers
        plug WebWidget.Embedding.FramePolicy
      end

      scope unquote(prefix), alias: false do
        pipe_through unquote(session)

        LiveViewRouter.live_session unquote(session),
          layout: false,
          root_layout: {WebWidgetWeb.Layouts, :widget} do
          LiveViewRouter.live("/:widget_id", WebWidgetWeb.WidgetLive)
        end

        get "/", WebWidget.Embedding.Unavailable, []
        get "/*path", WebWidget.Embedding.Unavailable, []
      end
    end
  end

  @doc "Mounts signed backend controls in a separate API pipeline."
  defmacro web_widget_api(prefix \\ "/widget-api") do
    quote do
      scope unquote(prefix), alias: false do
        post "/:widget_id/disconnect", WebWidget.Integration.ControlAPI, :disconnect
      end
    end
  end
end
