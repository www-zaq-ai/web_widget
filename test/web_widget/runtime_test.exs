defmodule WebWidget.RuntimeTest do
  use ExUnit.Case, async: true

  alias WebWidget.Runtime

  def failing_sink(_event, :raise), do: raise("host callback failed")
  def failing_sink(_event, :throw), do: throw(:host_callback_failed)
  def failing_sink(_event, :exit), do: exit(:host_callback_failed)
  def returning_sink(_event, result), do: result

  defp config do
    id = System.unique_integer([:positive])

    %{
      channel_config_id: id,
      sink_mfa: {__MODULE__, :unused_sink, []},
      widgets: [
        %{
          widget_id: "support-#{id}",
          same_site: "Lax",
          display_name: "Support Assistant",
          allowed_domains: ["https://customer.com"],
          stylesheet_url: "https://customer.com/widget.css"
        },
        %{
          widget_id: "sales-#{id}",
          same_site: "Lax",
          display_name: "Sales Assistant",
          allowed_domains: ["https://shop.customer.com"],
          stylesheet_url: nil
        }
      ]
    }
  end

  test "one supervised runtime resolves multiple widgets and excludes internal fields" do
    config = config()
    widgets = Enum.map(config.widgets, &Map.merge(&1, %{token: "secret", agent_id: 123}))
    start_supervised!({Runtime, Map.merge(config, %{widgets: widgets, credentials: "secret"})})

    for widget <- config.widgets do
      assert Runtime.fetch_widget(widget.widget_id) == {:ok, widget}
    end

    assert Runtime.fetch_widget("missing") == {:error, :not_found}
  end

  test "every direct runtime widget requires an explicit valid policy" do
    config = config()
    [widget | _] = config.widgets

    for invalid <-
          [Map.delete(widget, :same_site)] ++
            Enum.map([nil, :inherit, "", "none", false], &Map.put(widget, :same_site, &1)) do
      assert {:error, :invalid_runtime_config} = Runtime.prepare(%{config | widgets: [invalid]})
    end

    for value <- ["None", "Lax", "Strict"] do
      assert {:ok, _} = Runtime.prepare(%{config | widgets: [Map.put(widget, :same_site, value)]})
    end
  end

  test "discards runtime theme fields and validates stylesheet URLs" do
    config = config()
    [widget | _] = config.widgets

    for theme <- ["light", "dark", "auto", nil, :dark, "system", true] do
      start_supervised!({Runtime, %{config | widgets: [Map.put(widget, :theme, theme)]}})
      assert Runtime.fetch_widget(widget.widget_id) == {:ok, widget}
      stop_supervised!({Runtime, config.channel_config_id})
    end

    for url <- [nil, "/css/theme.css?v=2", "https://cdn.example.com/theme.css"] do
      start_supervised!({Runtime, %{config | widgets: [%{widget | stylesheet_url: url}]}})
      stop_supervised!({Runtime, config.channel_config_id})
    end

    for url <- [
          "",
          "theme.css",
          "//cdn.example.com/theme.css",
          "javascript:alert(1)",
          "data:text/css,body{}",
          "https://",
          "https://user@example.com/theme.css",
          123
        ] do
      assert {:error, :invalid_runtime_config} =
               Runtime.start_link(%{config | widgets: [%{widget | stylesheet_url: url}]})
    end
  end

  test "locale and language are excluded from persisted runtime configuration" do
    config = config()
    [widget | _] = config.widgets

    start_supervised!(
      {Runtime, %{config | widgets: [Map.merge(widget, %{locale: "ar", language: "fr"})]}}
    )

    assert Runtime.fetch_widget(widget.widget_id) == {:ok, widget}
  end

  test "stopping removes widgets and restarting applies replacement configuration" do
    config = config()
    [widget | _] = config.widgets
    pid = start_supervised!({Runtime, config})
    ref = Process.monitor(pid)

    stop_supervised!({Runtime, config.channel_config_id})
    assert_receive {:DOWN, ^ref, :process, ^pid, :shutdown}
    assert Runtime.fetch_widget(widget.widget_id) == {:error, :not_found}

    updated = %{widget | display_name: "Updated assistant"}
    start_supervised!({Runtime, %{config | widgets: [updated]}})
    assert Runtime.fetch_widget(widget.widget_id) == {:ok, updated}
  end

  test "duplicate widget IDs across channel configs fail instead of replacing an owner" do
    config = config()
    start_supervised!({Runtime, config})
    other = %{config | channel_config_id: config.channel_config_id + 1}

    assert {:error, _reason} = start_supervised({Runtime, other})

    for widget <- config.widgets do
      assert Runtime.fetch_widget(widget.widget_id) == {:ok, widget}
    end
  end

  test "normalizes exact origins and rejects unsafe or non-origin entries" do
    config = config()
    [widget | _] = config.widgets
    normalized = %{widget | allowed_domains: ["https://customer.com", "http://localhost:4019"]}

    start_supervised!(
      {Runtime,
       %{
         config
         | widgets: [
             %{
               widget
               | allowed_domains: [
                   "https://customer.com/",
                   "https://customer.com:443",
                   "http://localhost:4019"
                 ]
             }
           ]
       }}
    )

    assert Runtime.fetch_widget(widget.widget_id) == {:ok, normalized}

    for origins <- [
          "https://customer.com",
          [""],
          ["*"],
          ["https://*.customer.com"],
          ["https:"],
          ["null"],
          ["https://customer.com/path"],
          ["https://customer.com?x=1"],
          ["https://customer.com#fragment"],
          ["https://user@customer.com"],
          ["https://customer.com; frame-src *"],
          ["ftp://customer.com"],
          ["https://customer.com:0"],
          ["https://customer.com:65536"],
          ["https://customer.com", "*"]
        ] do
      assert Runtime.start_link(%{config | widgets: [%{widget | allowed_domains: origins}]}) ==
               {:error, :invalid_runtime_config}
    end
  end

  test "malformed public fields and duplicate IDs fail before starting" do
    config = config()
    [widget | _] = config.widgets

    for widgets <- [
          [widget, widget],
          [Map.put(widget, :multiple_conversations, "true")],
          [%{widget | display_name: %{token: "secret"}}],
          [%{widget | allowed_domains: [%{token: "secret"}]}],
          [%{widget | stylesheet_url: %{token: "secret"}}],
          [%{widget | widget_id: ""}]
        ] do
      assert Runtime.start_link(%{config | widgets: widgets}) == {:error, :invalid_runtime_config}
    end
  end

  test "rejects malformed runtime configuration before starting a process" do
    config = config()

    for invalid <- [
          nil,
          %{},
          Map.delete(config, :sink_mfa),
          %{config | channel_config_id: nil},
          %{config | sink_mfa: {__MODULE__, "callback", []}},
          %{config | sink_mfa: {__MODULE__, :callback, %{}}},
          %{config | widgets: %{}}
        ] do
      assert Runtime.start_link(invalid) == {:error, :invalid_runtime_config}
    end
  end

  test "callback exceptions, throws and exits are unavailable without exposing host details" do
    config = config()
    [widget | _] = config.widgets

    for failure <- [:raise, :throw, :exit] do
      start_supervised!({Runtime, %{config | sink_mfa: {__MODULE__, :failing_sink, [failure]}}})

      assert Runtime.dispatch(%{widget_id: widget.widget_id, type: "widget.init"}) ==
               {:error, :unavailable}

      assert {:ok, ^widget} = Runtime.fetch_widget(widget.widget_id)
      stop_supervised!({Runtime, config.channel_config_id})
    end
  end

  test "preserves synchronous replies, acknowledgements and host rejections" do
    config = config()
    [widget | _] = config.widgets

    for result <- [:ok, {:ok, %{conversation_id: "accepted"}}, {:error, :invalid_user}] do
      start_supervised!({Runtime, %{config | sink_mfa: {__MODULE__, :returning_sink, [result]}}})

      assert Runtime.dispatch(%{widget_id: widget.widget_id, type: "widget.init"}) == result
      stop_supervised!({Runtime, config.channel_config_id})
    end
  end

  test "runtime loss during an outstanding lookup or dispatch returns not found" do
    for operation <- [:fetch_widget, :dispatch] do
      config = config()
      [widget | _] = config.widgets

      runtime =
        start_supervised!(Supervisor.child_spec({Runtime, config}, restart: :temporary))

      :ok = :sys.suspend(runtime)
      parent = self()

      caller =
        start_supervised!(
          {Task,
           fn ->
             receive do
               :request ->
                 result =
                   case operation do
                     :fetch_widget -> Runtime.fetch_widget(widget.widget_id)
                     :dispatch -> Runtime.dispatch(%{widget_id: widget.widget_id})
                   end

                 send(parent, {:result, self(), result})
             end
           end},
          id: operation
        )

      :erlang.trace(caller, true, [:send])
      send(caller, :request)
      assert_receive {:trace, ^caller, :send, {:"$gen_call", _, _}, ^runtime}
      :erlang.trace(caller, false, [:send])

      monitor = Process.monitor(runtime)
      Process.exit(runtime, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^runtime, :killed}
      assert_receive {:result, ^caller, {:error, :not_found}}
    end
  end
end
