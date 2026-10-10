defmodule WebWidget do
  @moduledoc """
  Host-supervised widget infrastructure, one instance per BEAM node.

  Start `{WebWidget, pubsub_server: MyHost.PubSub, authentication: [...],
  transport: [endpoint: MyHostWeb.Endpoint]}` before connector runtimes.
  Starting the OTP dependency alone starts no widget services or listeners.
  See `docs/host-integration.md` for defaults, lifecycle and migration.
  """

  def child_spec(opts), do: Supervisor.child_spec({WebWidget.Supervisor, opts}, id: __MODULE__)
  def start_link(opts), do: WebWidget.Supervisor.start_link(opts)
end
