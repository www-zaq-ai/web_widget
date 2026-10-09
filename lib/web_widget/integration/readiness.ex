defmodule WebWidget.Integration.Readiness do
  @moduledoc "Bounded, secret-free version-1 local readiness for installed widgets."

  alias WebWidget.Integration.{ReadinessTransport, SignedIdentity}
  alias WebWidget.Runtime

  @order [:runtime, :transport, :delivery, :authentication, :cookie_policy]
  @precedence [:unavailable, :unknown, :starting, :ready]

  def status(id, opts) when is_integer(id) and id > 0 and is_list(opts) do
    if Keyword.keyword?(opts) and Keyword.keys(opts) in [[], [:timeout_ms]] and
         is_integer(Keyword.get(opts, :timeout_ms, 2_000)) and
         Keyword.get(opts, :timeout_ms, 2_000) in 1..2_000 do
      bounded(id, Keyword.get(opts, :timeout_ms, 2_000))
    else
      {:error, :invalid_request}
    end
  end

  def status(_, _), do: {:error, :invalid_request}

  @doc false
  def remaining(deadline) do
    case deadline - System.monotonic_time(:millisecond) do
      remaining when remaining > 0 -> remaining
      _ -> throw(:readiness_deadline)
    end
  end

  defp bounded(id, timeout) do
    caller = self()
    tag = make_ref()
    deadline = System.monotonic_time(:millisecond) + timeout
    {pid, monitor} = spawn_monitor(fn -> send(caller, {tag, run(id, deadline)}) end)

    receive do
      {^tag, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^pid, _} ->
        {:error, :check_failed}
    after
      timeout ->
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^monitor, :process, ^pid, _} -> :ok
        end

        receive do
          {^tag, _} -> :ok
        after
          0 -> :ok
        end

        {:error, :check_timeout}
    end
  end

  defp run(id, deadline) do
    widget_id = Integer.to_string(id)
    lookup = Runtime.readiness_snapshot(widget_id, min(remaining(deadline), 300))

    case lookup do
      {:ok, snapshot} -> inspect_runtime(widget_id, snapshot, deadline)
      {:error, reason} -> absent(reason)
    end
  rescue
    _ -> {:error, :check_failed}
  catch
    :throw, :readiness_deadline -> {:error, :check_timeout}
    _, _ -> {:error, :check_failed}
  end

  defp inspect_runtime(widget_id, snapshot, deadline) do
    {authentication, identity_settings} = identity(snapshot.identity)
    delivery = delivery(snapshot.pubsub_server, deadline)
    {transport, cookie_policy, same_site} = ReadinessTransport.check(snapshot.widget, deadline)

    runtime =
      case Runtime.readiness_snapshot(widget_id, min(remaining(deadline), 300)) do
        {:ok, %{runtime_ref: ref}} when ref == snapshot.runtime_ref -> check()
        {:ok, _} -> check(:unavailable, :runtime_not_registered)
        {:error, reason} -> check(:unavailable, reason)
      end

    result(
      %{
        runtime: runtime,
        transport: transport,
        delivery: delivery,
        authentication: authentication,
        cookie_policy: cookie_policy
      },
      Map.put(identity_settings, :same_site, same_site)
    )
  end

  defp absent(reason) do
    result(
      %{
        runtime: check(:unavailable, reason),
        transport: check(:unknown, :transport_unverifiable),
        delivery: check(:unavailable, :pubsub_unavailable),
        authentication: check(:unavailable, :identity_not_configured),
        cookie_policy: check(:unknown, :cookie_policy_unsupported)
      },
      Map.new([:identity_issuer, :identity_audience, :same_site], &{&1, unresolved()})
    )
  end

  defp identity(%{issuer: issuer, audience: audience}) do
    if SignedIdentity.valid_identifier?(issuer) and SignedIdentity.valid_identifier?(audience) do
      {check(),
       %{
         identity_issuer: %{value: issuer, source: :connector},
         identity_audience: %{value: audience, source: :connector}
       }}
    else
      identity(nil)
    end
  end

  defp identity(_) do
    {check(:unavailable, :identity_not_configured),
     %{identity_issuer: unresolved(), identity_audience: unresolved()}}
  end

  defp delivery(server, deadline) when is_atom(server) and not is_nil(server) do
    with {:ok, {adapter, name, _dispatcher}} <- Registry.meta(server, :pubsub),
         :ok <- adapter_available(adapter, name),
         :ok <- responsive_tree(Module.concat(server, Supervisor), deadline) do
      check()
    else
      :unsupported -> check(:unknown, :check_failed)
      _ -> check(:unavailable, :pubsub_unavailable)
    end
  rescue
    _ -> check(:unavailable, :pubsub_unavailable)
  catch
    :throw, :readiness_deadline -> check(:unknown, :check_timeout)
    :exit, {:timeout, _} -> check(:unknown, :check_timeout)
    _, _ -> check(:unavailable, :pubsub_unavailable)
  end

  defp delivery(_, _), do: check(:unavailable, :pubsub_unavailable)

  defp adapter_available(Phoenix.PubSub.PG2, name) do
    pid = Process.whereis(name)
    if is_pid(pid) and pid in :pg.get_local_members(Phoenix.PubSub, name), do: :ok, else: :error
  end

  defp adapter_available(_, _), do: :unsupported

  defp responsive_tree(supervisor, deadline) do
    children = GenServer.call(supervisor, :which_children, min(remaining(deadline), 200))

    Enum.reduce_while(children, :ok, fn
      {_, pid, :supervisor, _}, :ok when is_pid(pid) ->
        case responsive_tree(pid, deadline) do
          :ok -> {:cont, :ok}
          _ -> {:halt, :error}
        end

      {_, pid, :worker, _}, :ok when is_pid(pid) ->
        case :sys.get_status(pid, min(remaining(deadline), 200)) do
          {:status, ^pid, _, [_, :running | _]} -> {:cont, :ok}
          _ -> {:halt, :error}
        end

      _, :ok ->
        {:halt, :error}
    end)
  end

  defp result(checks, settings) do
    status =
      Enum.find(@precedence, fn state -> Enum.any?(checks, fn {_, c} -> c.status == state end) end)

    winner = @order |> Enum.map(&Map.fetch!(checks, &1)) |> Enum.find(&(&1.status == status))

    {:ok,
     %{
       protocol_version: 1,
       status: status,
       reason: winner.reason,
       checks: checks,
       effective_settings: settings
     }}
  end

  @doc false
  def check(status \\ :ready, reason \\ nil), do: %{status: status, reason: reason}

  @doc false
  def unresolved, do: %{value: nil, source: :unresolved}
end
