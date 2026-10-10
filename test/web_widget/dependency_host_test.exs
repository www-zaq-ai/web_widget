defmodule WebWidget.DependencyHostTest do
  use ExUnit.Case, async: true

  @tag timeout: 60_000
  test "isolated infrastructure lifecycle rolls back failed startup and remains host-owned" do
    paths = Enum.flat_map(:code.get_path(), &["-pa", List.to_string(&1)])
    script = Path.expand("../support/host/infrastructure_smoke.exs", __DIR__)

    {output, status} =
      System.cmd(System.find_executable("elixir"), paths ++ [script], stderr_to_stdout: true)

    assert status == 0, output
    assert output =~ "3 tests, 0 failures"
  end

  @tag timeout: 60_000
  test "configuration-only integration endpoint excludes standalone database and demo" do
    paths = Enum.flat_map(:code.get_path(), &["-pa", List.to_string(&1)])
    script = Path.expand("../support/host/integration_endpoint_smoke.exs", __DIR__)

    {output, status} =
      System.cmd(System.find_executable("elixir"), paths ++ [script], stderr_to_stdout: true)

    assert status == 0, output
    assert output =~ "1 test, 0 failures"
  end

  @tag timeout: 60_000
  test "dependency startup creates no widget services even with legacy automatic-start flags" do
    paths = Enum.flat_map(:code.get_path(), &["-pa", List.to_string(&1)])

    {output, status} =
      System.cmd(
        System.find_executable("elixir"),
        paths ++
          [
            "-e",
            """
            Application.put_env(:web_widget, :start_web_server, true)
            Application.put_env(:web_widget, :start_integration_server, true)
            {:ok, _} = Application.ensure_all_started(:web_widget)
            for name <- [WebWidget.Supervisor, WebWidget.Configuration, WebWidget.RuntimeRegistry,
                         WebWidget.Integration.BindingStore, WebWidgetWeb.Endpoint,
                         WebWidget.PubSub, WebWidget.Repo, WebWidget.MockHost] do
              nil = Process.whereis(name)
            end
            {:ok, %{status: :unavailable, reason: :runtime_not_registered}} =
              WebWidget.Integration.RuntimeBuilder.status(23, [])
            {:error, {:invalid_widget_configuration, _, _}} = WebWidget.start_link([])
            nil = Process.whereis(WebWidget.Supervisor)
            """
          ],
        stderr_to_stdout: true
      )

    assert status == 0, output
  end

  @tag timeout: 60_000
  test "host rendering works without mail configuration or standalone services" do
    # A subprocess cannot inherit the standalone endpoint, PubSub, Repo, demo
    # runtime, or application environment started by this project's test suite.
    paths = Enum.flat_map(:code.get_path(), &["-pa", List.to_string(&1)])
    script = Path.expand("../support/host/dependency_smoke.exs", __DIR__)

    {output, status} =
      System.cmd(System.find_executable("elixir"), paths ++ [script], stderr_to_stdout: true)

    assert status == 0, output
    assert output =~ "1 test, 0 failures"
  end
end
