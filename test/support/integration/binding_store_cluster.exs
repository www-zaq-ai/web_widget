# Run with: MIX_ENV=test mix run --no-start test/support/integration/binding_store_cluster.exs
defmodule WebWidget.Integration.BindingStoreClusterCheck do
  alias WebWidget.Integration.{BindingStore, RuntimeBuilder, SignedIdentity}
  alias WebWidget.Runtime
  alias WebWidget.TestIntegration.Host

  def run do
    {:ok, _} = :net_kernel.start([:wwroot, :shortnames])
    names = [:wwa, :wwb]
    [{p1, n1}, {p2, n2}] = Enum.map(names, &start_peer/1)
    nodes = [node(), n1, n2]

    configure(node(), nodes)
    configure(n1, nodes)
    configure(n2, nodes)
    await(fn -> Enum.all?(nodes, &(call(&1, BindingStore, :available?, []) == :ok)) end)

    reset = BindingStore.reset_cutoff_value()
    now = max(System.system_time(:second), reset + 1)
    claims = claims(now)

    :ok = BindingStore.claim(claims, "page-a", now)
    :ok = call(n1, BindingStore, :claim, [claims, "page-a", now + 6])
    {:error, :replayed} = call(n2, BindingStore, :claim, [claims, "page-b", now + 6])

    racing = claims(now)

    winners =
      1..12
      |> Task.async_stream(
        fn i ->
          target = if rem(i, 2) == 0, do: n1, else: n2
          call(target, BindingStore, :claim, [racing, "page-#{i}", now])
        end,
        max_concurrency: 12
      )
      |> Enum.map(fn {:ok, result} -> result end)

    1 = Enum.count(winners, &(&1 == :ok))
    11 = Enum.count(winners, &(&1 == {:error, :replayed}))

    independent = %{racing | jti: unique()}
    :ok = call(n1, BindingStore, :claim, [independent, "independent-page", now])
    :ok = call(n2, BindingStore, :authorized?, [independent, "independent-page", now])
    {:error, :replayed} = call(n1, BindingStore, :claim, [racing, "independent-page", now])

    :peer.stop(p2)
    await(fn -> BindingStore.available?() == :ok end)
    {p2, ^n2} = start_peer(Enum.at(names, 1))
    configure(n2, nodes)
    await(fn -> call(n2, BindingStore, :available?, []) == :ok end)
    :ok = call(n2, BindingStore, :claim, [claims, "page-a", now + 7])
    {:error, :replayed} = call(n2, BindingStore, :claim, [claims, "page-b", now + 7])

    request_id = unique()

    {:ok, cutoff, true} =
      call(n1, BindingStore, :revoke_user, [
        claims.issuer,
        claims.widget_id,
        claims.user_id,
        request_id,
        now + 8,
        now + 8
      ])

    {:ok, ^cutoff, false} =
      call(n2, BindingStore, :revoke_user, [
        claims.issuer,
        claims.widget_id,
        claims.user_id,
        request_id,
        now + 8,
        now + 9
      ])

    {:error, :stale_or_revoked} = BindingStore.claim(claims, "page-a", now + 9)

    racing_user = claims(now + 10)

    claim_task =
      Task.async(fn -> call(n1, BindingStore, :claim, [racing_user, "race-page", now + 10]) end)

    revoke_task =
      Task.async(fn ->
        call(n2, BindingStore, :revoke_user, [
          racing_user.issuer,
          racing_user.widget_id,
          racing_user.user_id,
          unique(),
          now + 10,
          now + 10
        ])
      end)

    claim_result = Task.await(claim_task)
    true = claim_result in [:ok, {:error, :stale_or_revoked}]
    {:ok, _, true} = Task.await(revoke_task)

    {:error, :unauthorized} =
      call(n2, BindingStore, :authorized?, [racing_user, "race-page", now + 10])

    await(fn -> System.system_time(:second) > reset end)
    pre_reset = claims(System.system_time(:second))
    :ok = BindingStore.claim(pre_reset, "page-before-reset", pre_reset.iat)

    {config, hooks, options} = Host.fixture()
    key = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    config =
      Map.merge(config, %{
        token: key,
        settings: %{"identity_issuer" => "parent", "identity_audience" => "widget"}
      })

    options =
      Keyword.merge(options,
        pubsub_server: WebWidget.PubSub,
        identity_verifier: :connector_key
      )

    {:ok, {spec, []}} = RuntimeBuilder.build(config, hooks, options)
    {:ok, _} = Supervisor.start_child(WebWidget.Supervisor, spec)

    {:ok, current_proof} =
      SignedIdentity.sign(key, config.id, %{user_id: "renewing-user"},
        issuer: "parent",
        audience: "widget",
        ttl: 60
      )

    {:ok, session} = Runtime.authenticate(to_string(config.id), current_proof, "renewing-page")

    {:ok, replacement_proof} =
      SignedIdentity.sign(key, config.id, %{user_id: "renewing-user"},
        issuer: "parent",
        audience: "widget",
        ttl: 60
      )

    :peer.stop(p1)
    :peer.stop(p2)
    await(fn -> BindingStore.available?() == {:error, :unavailable} end)
    {:error, :store_unavailable} = Runtime.renew(session, replacement_proof)
    {:error, :unavailable_or_invalid} = BindingStore.claim(claims(now + 10), "page-x", now + 10)

    {:error, :unavailable_or_invalid} =
      BindingStore.revoke_user(
        claims.issuer,
        claims.widget_id,
        claims.user_id,
        unique(),
        now + 10,
        now + 10
      )

    :ok = Application.stop(:web_widget)
    :ok = Application.stop(:mnesia)
    {:ok, _} = Application.ensure_all_started(:web_widget)
    [{p1, ^n1}, {p2, ^n2}] = Enum.map(names, &start_peer/1)
    configure(n1, nodes)
    configure(n2, nodes)
    await(fn -> BindingStore.available?() == :ok end)
    new_reset = BindingStore.reset_cutoff_value()
    true = new_reset >= reset
    {:error, :stale_or_revoked} = BindingStore.claim(claims, "page-a", now)
    true = new_reset >= pre_reset.iat

    {:error, :stale_or_revoked} =
      BindingStore.claim(pre_reset, "page-before-reset", pre_reset.iat + 1)

    {:error, :stale_control_request} =
      BindingStore.revoke_user(
        pre_reset.issuer,
        pre_reset.widget_id,
        pre_reset.user_id,
        unique(),
        pre_reset.iat,
        pre_reset.iat + 1
      )

    await(fn -> System.system_time(:second) > new_reset end)
    fresh = claims(System.system_time(:second))
    :ok = BindingStore.claim(fresh, "page-fresh", fresh.iat)
    :ok = call(n1, BindingStore, :claim, [fresh, "page-fresh", fresh.iat])
    {:error, :replayed} = call(n2, BindingStore, :claim, [fresh, "other-page", fresh.iat])

    :peer.stop(p1)
    :peer.stop(p2)
    IO.puts("distributed binding store checks passed")
  end

  defp start_peer(name) do
    {:ok, peer, peer_node} = :peer.start_link(%{name: name, connection: :standard_io})
    :ok = :rpc.call(peer_node, :code, :add_paths, [:code.get_path()])
    {peer, peer_node}
  end

  defp configure(target, nodes) do
    :ok =
      call(target, Application, :put_env, [:web_widget, :authentication, [replica_nodes: nodes]])

    :ok = call(target, Application, :put_env, [:web_widget, :start_web_server, false])
    {:ok, _} = call(target, Application, :ensure_all_started, [:web_widget])
  end

  defp claims(now) do
    %{
      issuer: "parent",
      audience: "widget",
      widget_id: 99_999,
      user_id: "visitor-#{unique()}",
      jti: unique(),
      iat: now,
      exp: now + 60
    }
  end

  defp unique, do: Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)

  defp call(target, module, function, args) when target == node(),
    do: apply(module, function, args)

  defp call(target, module, function, args),
    do: :rpc.call(target, module, function, args, 10_000)

  defp await(fun, remaining \\ 100)
  defp await(fun, 0), do: raise("cluster did not become ready: #{inspect(fun.())}")

  defp await(fun, remaining) do
    if fun.() do
      :ok
    else
      Process.sleep(100)
      await(fun, remaining - 1)
    end
  end
end

WebWidget.Integration.BindingStoreClusterCheck.run()
