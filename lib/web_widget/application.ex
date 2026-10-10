defmodule WebWidget.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        {Registry, keys: :unique, name: WebWidget.RuntimeRegistry},
        WebWidget.Integration.BindingStore
      ] ++ web_children()

    Supervisor.start_link(children, strategy: :one_for_one, name: WebWidget.Supervisor)
  end

  # Hosts may use the supervised runtime without starting the standalone Phoenix
  # server and database. Runtime children remain owned by the host supervisor.
  defp web_children do
    cond do
      Application.get_env(:web_widget, :start_integration_server, false) ->
        [{Phoenix.PubSub, name: WebWidget.PubSub}, WebWidgetWeb.Endpoint]

      Application.get_env(:web_widget, :start_web_server, false) ->
        standalone_children()

      true ->
        []
    end
  end

  defp standalone_children do
    [
      WebWidgetWeb.Telemetry,
      WebWidget.Repo,
      {DNSCluster, query: Application.get_env(:web_widget, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: WebWidget.PubSub}
    ] ++ demo_children() ++ [WebWidgetWeb.Endpoint]
  end

  defp demo_children do
    if Application.get_env(:web_widget, :mock_host, false) do
      [
        WebWidget.MockHost,
        {WebWidget.Runtime,
         %{
           channel_config_id: :standalone_demo,
           sink_mfa: {WebWidget.MockHost, :handle_event, []},
           pubsub_server: WebWidget.PubSub,
           widgets: [
             %{
               widget_id: "demo",
               same_site: "Lax",
               display_name: "Website assistant",
               multiple_conversations:
                 Application.get_env(:web_widget, :demo_multiple_conversations, false),
               allowed_domains: Application.get_env(:web_widget, :demo_allowed_domains, [])
             }
           ]
         }}
      ]
    else
      []
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    if Process.whereis(WebWidgetWeb.Endpoint) do
      WebWidgetWeb.Endpoint.config_change(changed, removed)
    end

    :ok
  end
end
