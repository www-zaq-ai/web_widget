defmodule WebWidget.Standalone do
  @moduledoc """
  Explicit standalone composition. Starts local socket PubSub, widget infrastructure
  and the package endpoint. `mode: :package` excludes Repo, telemetry and demo.
  Endpoint/TLS configuration remains ordinary Phoenix endpoint configuration.
  `infrastructure:` contains the same options accepted by `WebWidget`.
  `demo:` enables the development/test mock runtime with presentation options.
  """
  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    infrastructure =
      Keyword.get(opts, :infrastructure, [])
      |> Keyword.put_new(:pubsub_server, WebWidget.PubSub)
      |> Keyword.put_new(:transport, endpoint: WebWidgetWeb.Endpoint)

    children = [{Phoenix.PubSub, name: WebWidget.PubSub}, {WebWidget, infrastructure}]
    children = children ++ standalone_children(opts) ++ [WebWidgetWeb.Endpoint]
    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp standalone_children(opts) do
    if Keyword.get(opts, :mode, :standalone) == :package do
      []
    else
      [
        WebWidgetWeb.Telemetry,
        WebWidget.Repo,
        {DNSCluster, query: Keyword.get(opts, :dns_cluster_query, :ignore)}
      ] ++ demo_children(opts)
    end
  end

  defp demo_children(opts) do
    case Keyword.get(opts, :demo, false) do
      false ->
        []

      demo when is_list(demo) ->
        server =
          Keyword.get(Keyword.get(opts, :infrastructure, []), :pubsub_server, WebWidget.PubSub)

        [
          WebWidget.MockHost,
          {WebWidget.Runtime, demo_config(Keyword.put(demo, :pubsub_server, server))}
        ]
    end
  end

  @doc false
  def demo_config(opts) do
    %{
      channel_config_id: :standalone_demo,
      sink_mfa: {WebWidget.MockHost, :handle_event, []},
      pubsub_server: Keyword.get(opts, :pubsub_server, WebWidget.PubSub),
      widgets: [
        %{
          widget_id: "demo",
          same_site: "Lax",
          display_name: "Website assistant",
          multiple_conversations: Keyword.get(opts, :multiple_conversations, false),
          allowed_domains: Keyword.get(opts, :allowed_domains, [])
        }
      ]
    }
  end
end
