defmodule WebWidget.TestClusterHost do
  @moduledoc false

  # RPC workers are short-lived; the disposable node owns this fixture supervisor.
  def start(nodes) do
    {:ok, _} = Application.ensure_all_started(:web_widget)

    {:ok, pid} =
      Supervisor.start_link(
        [{WebWidget, pubsub_server: WebWidget.PubSub, authentication: [replica_nodes: nodes]}],
        strategy: :one_for_one,
        name: __MODULE__
      )

    Process.unlink(pid)
    {:ok, pid}
  end
end
