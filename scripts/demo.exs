Application.put_env(:web_widget, WebWidgetWeb.Endpoint,
  Keyword.put(Application.fetch_env!(:web_widget, WebWidgetWeb.Endpoint), :server, true))
{:ok, _} = Application.ensure_all_started(:web_widget)

demo = [
  multiple_conversations: System.get_env("WEB_WIDGET_DEMO_MULTIPLE_CONVERSATIONS") == "true",
  allowed_domains: System.get_env("WEB_WIDGET_DEMO_ALLOWED_DOMAINS", "http://localhost:4000")
    |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
]

{:ok, _} = WebWidget.Standalone.start_link(demo: demo,
  dns_cluster_query: System.get_env("DNS_CLUSTER_QUERY") || :ignore)
