defmodule WebWidget.Supervisor do
  @moduledoc false
  use Supervisor

  def start_link(opts) do
    with {:ok, config} <- WebWidget.Configuration.normalize(opts) do
      Supervisor.start_link(__MODULE__, config, name: __MODULE__)
    end
  end

  @impl true
  def init(config) do
    children = [
      {WebWidget.Configuration, config},
      {Registry, keys: :unique, name: WebWidget.RuntimeRegistry},
      {WebWidget.Integration.BindingStore, config.authentication}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
