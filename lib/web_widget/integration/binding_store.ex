defmodule WebWidget.Integration.BindingStore do
  @moduledoc """
  RAM-only, majority-protected JWT page bindings and revocation cutoffs.

  Replica membership is explicit. The service may start before a quorum exists,
  but every operation fails closed until the tables are available on a quorum.
  """

  use GenServer

  alias WebWidget.Configuration

  @bindings :web_widget_token_bindings
  @revocations :web_widget_user_revocations
  @controls :web_widget_control_requests
  @metadata :web_widget_auth_metadata
  @tables [@bindings, @revocations, @controls, @metadata]
  @tick_ms 1_000
  @prune_limit 100

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def claim(claims, page_id, now \\ System.system_time(:second)) do
    with true <- valid_claim?(claims) and valid_page?(page_id) and is_integer(now),
         :ok <- available?() do
      transaction(fn -> claim_transaction(claims, page_id, now) end)
    else
      _ -> {:error, :unavailable_or_invalid}
    end
  end

  defp claim_transaction(claims, page_id, now) do
    reset = reset_cutoff()
    revoked = revocation_cutoff(claims.issuer, claims.widget_id, claims.user_id)
    key = {claims.issuer, claims.audience, claims.widget_id, claims.jti}

    case :mnesia.read(@bindings, key, :write) do
      [] ->
        claim_new(claims, page_id, key, now, reset, revoked)

      [{@bindings, ^key, ^page_id, user_id, iat, exp}]
      when user_id == claims.user_id and iat == claims.iat and exp == claims.exp ->
        if valid_binding_time?(iat, exp, now, reset, revoked),
          do: :ok,
          else: :mnesia.abort(:stale_or_revoked)

      _ ->
        :mnesia.abort(:replayed)
    end
  end

  defp claim_new(claims, page_id, key, now, reset, revoked) do
    if now >= claims.iat and now - claims.iat < binding_window() and
         valid_binding_time?(claims.iat, claims.exp, now, reset, revoked) do
      :mnesia.write({@bindings, key, page_id, claims.user_id, claims.iat, claims.exp})
      :ok
    else
      :mnesia.abort(:stale_or_revoked)
    end
  end

  defp valid_binding_time?(iat, exp, now, reset, revoked),
    do: iat > reset and iat > revoked and now < exp

  def authorized?(claims, page_id, now \\ System.system_time(:second)) do
    with true <- valid_claim?(claims) and valid_page?(page_id) and is_integer(now),
         :ok <- available?() do
      transaction(fn -> authorized_transaction(claims, page_id, now) end)
    else
      _ -> {:error, :unavailable_or_invalid}
    end
  end

  defp authorized_transaction(claims, page_id, now) do
    reset = reset_cutoff()
    revoked = revocation_cutoff(claims.issuer, claims.widget_id, claims.user_id)
    key = {claims.issuer, claims.audience, claims.widget_id, claims.jti}

    case :mnesia.read(@bindings, key, :write) do
      [{@bindings, ^key, ^page_id, user_id, iat, exp}]
      when user_id == claims.user_id and iat == claims.iat and exp == claims.exp ->
        if valid_binding_time?(iat, exp, now, reset, revoked),
          do: :ok,
          else: :mnesia.abort(:unauthorized)

      _ ->
        :mnesia.abort(:unauthorized)
    end
  end

  def revoked?(claims) do
    with true <- valid_claim?(claims),
         :ok <- available?() do
      transaction(fn ->
        revocation_cutoff(claims.issuer, claims.widget_id, claims.user_id) >= claims.iat
      end)
    else
      _ -> {:error, :unavailable_or_invalid}
    end
  end

  def revoke_user(issuer, widget_id, user_id, request_id, issued_at, now) do
    with true <-
           valid_identifier?(issuer) and is_integer(widget_id) and widget_id > 0 and
             valid_identifier?(user_id) and valid_identifier?(request_id) and
             is_integer(issued_at) and is_integer(now) and issued_at <= now and
             now - issued_at < control_ttl(),
         :ok <- available?() do
      transaction(fn ->
        revoke_transaction(issuer, widget_id, user_id, request_id, issued_at, now)
      end)
    else
      _ -> {:error, :unavailable_or_invalid}
    end
  end

  defp revoke_transaction(issuer, widget_id, user_id, request_id, issued_at, now) do
    request_key = {issuer, widget_id, request_id}

    case :mnesia.read(@controls, request_key, :write) do
      [{@controls, ^request_key, ^user_id, ^issued_at, cutoff, _expiry}] ->
        {:ok, cutoff, false}

      [] ->
        create_revocation(issuer, widget_id, user_id, request_key, issued_at, now)

      _ ->
        :mnesia.abort(:request_conflict)
    end
  end

  defp create_revocation(issuer, widget_id, user_id, request_key, issued_at, now) do
    if issued_at <= reset_cutoff(), do: :mnesia.abort(:stale_control_request)
    user_key = {issuer, widget_id, user_id}
    cutoff = max(revocation_cutoff(issuer, widget_id, user_id), now)
    :mnesia.write({@revocations, user_key, cutoff})
    :mnesia.write({@controls, request_key, user_id, issued_at, cutoff, issued_at + control_ttl()})
    {:ok, cutoff, true}
  end

  def reset_cutoff_value do
    with :ok <- available?(), do: transaction(&reset_cutoff/0)
  end

  def available? do
    nodes = replica_nodes()
    quorum = div(length(nodes), 2) + 1

    try do
      running = :mnesia.system_info(:running_db_nodes)

      if is_pid(Process.whereis(__MODULE__)) and nodes != [] and
           length(Enum.filter(nodes, &(&1 in running))) >= quorum and
           Enum.all?(@tables, &table_ready?(&1, nodes, running, quorum)) do
        :ok
      else
        {:error, :unavailable}
      end
    rescue
      _ -> {:error, :unavailable}
    catch
      _, _ -> {:error, :unavailable}
    end
  end

  @impl true
  def init(opts) do
    case Application.ensure_all_started(:mnesia) do
      {:ok, _} ->
        send(self(), :reconcile)
        {:ok, %{cursors: %{}, nodes: Keyword.fetch!(opts, :replica_nodes)}}

      error ->
        {:stop, error}
    end
  end

  @impl true
  def handle_info(:reconcile, state) do
    reconcile(state.nodes)
    state = if available?() == :ok, do: prune(state), else: state
    Process.send_after(self(), :reconcile, @tick_ms)
    {:noreply, state}
  end

  defp reconcile(nodes) do
    peers = Enum.filter(nodes -- [node()], &(Node.ping(&1) == :pong))
    :mnesia.change_config(:extra_db_nodes, peers)
    running = :mnesia.system_info(:running_db_nodes)
    active = Enum.filter(nodes, &(&1 in running))

    cond do
      length(active) < div(length(nodes), 2) + 1 ->
        :ok

      Enum.all?(@tables, &(&1 in :mnesia.system_info(:tables))) ->
        Enum.each(@tables, &ensure_copy/1)
        ensure_metadata()

      node() == Enum.min(active) ->
        create_tables(active)

      true ->
        :ok
    end
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp create_tables(active) do
    definitions = [
      {@bindings, [:key, :page_id, :user_id, :iat, :exp]},
      {@revocations, [:key, :cutoff]},
      {@controls, [:key, :user_id, :issued_at, :cutoff, :expires_at]},
      {@metadata, [:key, :value]}
    ]

    Enum.each(definitions, fn {table, attrs} ->
      :mnesia.create_table(table,
        attributes: attrs,
        ram_copies: active,
        majority: true,
        type: :ordered_set
      )
    end)

    :mnesia.wait_for_tables(@tables, 5_000)
    ensure_metadata()
  end

  defp ensure_copy(table) do
    if node() not in :mnesia.table_info(table, :ram_copies) do
      :mnesia.add_table_copy(table, node(), :ram_copies)
    end
  end

  defp ensure_metadata do
    transaction(fn ->
      case :mnesia.read(@metadata, :reset_cutoff, :write) do
        [] -> :mnesia.write({@metadata, :reset_cutoff, System.system_time(:second)})
        _ -> :ok
      end
    end)
  end

  defp table_ready?(table, nodes, running, quorum) do
    replicas = :mnesia.table_info(table, :ram_copies)

    node() in replicas and length(replicas) >= quorum and
      Enum.all?(replicas, &(&1 in nodes)) and
      length(Enum.filter(replicas, &(&1 in running))) >= quorum and
      :mnesia.table_info(table, :majority) and
      :mnesia.wait_for_tables([table], 0) == :ok
  end

  defp reset_cutoff do
    case :mnesia.read(@metadata, :reset_cutoff, :read) do
      [{@metadata, :reset_cutoff, cutoff}] when is_integer(cutoff) -> cutoff
      _ -> :mnesia.abort(:missing_reset_cutoff)
    end
  end

  defp revocation_cutoff(issuer, widget_id, user_id) do
    case :mnesia.read(@revocations, {issuer, widget_id, user_id}, :write) do
      [{@revocations, _, cutoff}] -> cutoff
      [] -> -1
    end
  end

  defp transaction(fun) do
    with {:ok, config} <- Configuration.fetch() do
      case :mnesia.transaction(fn ->
             if Configuration.current?(config.generation),
               do: fun.(),
               else: :mnesia.abort(:unavailable)
           end) do
        {:atomic, result} ->
          if Configuration.current?(config.generation), do: result, else: {:error, :unavailable}

        {:aborted, reason} ->
          {:error, reason}
      end
    end
  end

  defp prune(state) do
    cursors =
      Enum.reduce([@bindings, @controls], state.cursors, fn table, cursors ->
        cursor = Map.get(cursors, table, :start)
        Map.put(cursors, table, prune_table(table, cursor, @prune_limit))
      end)

    %{state | cursors: cursors}
  end

  defp prune_table(_table, cursor, 0), do: cursor

  defp prune_table(table, cursor, remaining) do
    key =
      if cursor == :start, do: :mnesia.dirty_first(table), else: :mnesia.dirty_next(table, cursor)

    if key == :"$end_of_table" do
      :start
    else
      transaction(fn -> prune_key(table, key) end)

      prune_table(table, key, remaining - 1)
    end
  end

  defp prune_key(table, key) do
    case :mnesia.read(table, key, :write) do
      [{^table, ^key, _, _, _, exp}] when table in [@bindings, @controls] ->
        if exp <= System.system_time(:second), do: :mnesia.delete({table, key})

      _ ->
        :ok
    end
  end

  defp valid_claim?(%{
         issuer: issuer,
         audience: audience,
         widget_id: widget_id,
         user_id: user_id,
         jti: jti,
         iat: iat,
         exp: exp
       }) do
    Enum.all?([issuer, audience, user_id, jti], &valid_identifier?/1) and
      is_integer(widget_id) and widget_id > 0 and is_integer(iat) and
      is_integer(exp) and exp > iat
  end

  defp valid_claim?(_), do: false
  defp valid_page?(page_id), do: valid_identifier?(page_id)
  defp valid_identifier?(value), do: is_binary(value) and byte_size(value) in 1..255

  defp replica_nodes, do: Configuration.authentication(:replica_nodes) || []
  defp binding_window, do: Configuration.authentication(:first_binding_window_seconds)
  defp control_ttl, do: Configuration.authentication(:control_proof_ttl_seconds)
end
