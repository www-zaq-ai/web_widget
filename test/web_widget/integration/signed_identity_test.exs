defmodule WebWidget.Integration.SignedIdentityTest do
  use ExUnit.Case, async: false
  alias WebWidget.Integration.{BindingStore, RuntimeBuilder, SignedIdentity}
  alias WebWidget.Runtime
  alias WebWidget.TestIntegration.Host

  setup do
    {config, hooks, options} = Host.fixture()
    key = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    options =
      Keyword.merge(options,
        identity_verifier: :connector_key
      )

    config =
      Map.merge(config, %{
        token: key,
        settings: %{"identity_issuer" => "parent", "identity_audience" => "widget"}
      })

    {:ok, {spec, []}} = RuntimeBuilder.build(config, hooks, options)
    start_supervised!(spec)
    reset = await_reset()
    delay = max(0, (reset + 1) * 1_000 - System.system_time(:millisecond))
    if delay > 0, do: Process.sleep(delay)

    %{
      config: config,
      hooks: hooks,
      options: options,
      spec: spec,
      key: key,
      id: to_string(config.id),
      page_id: Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
    }
  end

  test "signed proofs bind sender, widget, issuer, audience and expiry", ctx do
    {:ok, proof} = sign(ctx)
    assert {:ok, session} = authenticate(ctx, proof)
    assert session.sender_id == "visitor"
    assert {:ok, _} = authenticate(ctx, proof)

    for bad <- [nil, "visitor", proof <> "x"] do
      assert {:error, :unauthorized} = authenticate(ctx, bad)
    end

    for opts <- [[issuer: "wrong"], [audience: "wrong"]] do
      {:ok, bad} = sign(ctx, opts)
      assert {:error, :unauthorized} = authenticate(ctx, bad)
    end

    {:ok, wrong_widget} =
      SignedIdentity.sign(ctx.key, ctx.config.id + 1, %{user_id: "visitor"},
        issuer: "parent",
        audience: "widget"
      )

    assert {:error, :unauthorized} = authenticate(ctx, wrong_widget)

    expired = jwt(ctx.key, Map.put(claims(ctx), "exp", System.system_time(:second) - 1))

    assert {:error, :unauthorized} = authenticate(ctx, expired)
  end

  test "trusted expired credentials retain revocation classification without binding", ctx do
    now = System.system_time(:second)
    expired = %{claims(ctx) | "iat" => now - 20, "exp" => now - 1}
    assert {:error, :unauthorized} = authenticate(ctx, jwt(ctx.key, expired))

    assert {:ok, _, true} =
             BindingStore.revoke_user(
               "parent",
               ctx.config.id,
               "visitor",
               Ecto.UUID.generate(),
               now,
               now
             )

    assert {:error, :backend_revoked} = authenticate(ctx, jwt(ctx.key, expired))

    assert [] ==
             :mnesia.dirty_read(
               :web_widget_token_bindings,
               {"parent", "widget", ctx.config.id, expired["jti"]}
             )

    for invalid <- [
          Map.put(expired, "iss", "wrong"),
          Map.put(expired, "aud", "wrong"),
          Map.put(expired, "widget_id", ctx.config.id + 1),
          Map.put(expired, "exp", expired["iat"]),
          Map.put(expired, "nbf", now + 1),
          Map.put(expired, "jti", "short"),
          Map.put(expired, "user_id", " "),
          Map.put(expired, "extra", true)
        ] do
      assert {:error, :unauthorized} = authenticate(ctx, jwt(ctx.key, invalid))
    end

    assert {:error, :unauthorized} = authenticate(ctx, jwt(ctx.key <> "wrong", expired))
  end

  test "valid and expired covered credentials report unavailable authority distinctly", ctx do
    now = System.system_time(:second)

    assert {:ok, _, true} =
             BindingStore.revoke_user(
               "parent",
               ctx.config.id,
               "visitor",
               Ecto.UUID.generate(),
               now,
               now
             )

    config = Application.get_env(:web_widget, :authentication, [])
    :sys.suspend(BindingStore)

    try do
      Application.put_env(
        :web_widget,
        :authentication,
        Keyword.put(config, :replica_nodes, [
          node(),
          :unavailable_a@localhost,
          :unavailable_b@localhost
        ])
      )

      for times <- [%{"iat" => now, "exp" => now + 300}, %{"iat" => now - 20, "exp" => now - 1}] do
        proof = jwt(ctx.key, Map.merge(claims(ctx), times))
        assert {:error, :store_unavailable} = authenticate(ctx, proof)
      end

      assert {:error, :unauthorized} = authenticate(ctx, "untrusted")
    after
      Application.put_env(:web_widget, :authentication, config)
      :sys.resume(BindingStore)
    end
  end

  test "same-page reconnect survives process replacement but not runtime ownership", ctx do
    {:ok, proof} = sign(ctx)
    assert {:ok, session} = authenticate(ctx, proof)
    assert session.topic == "web_widget:session:" <> ctx.page_id

    assert {:ok, reconnected} = Task.async(fn -> authenticate(ctx, proof) end) |> Task.await()
    assert reconnected.topic == session.topic
    refute Runtime.authorized?(reconnected)
    assert {:error, :unauthorized} = authenticate(ctx, proof, "other-page")

    {:ok, other_proof} = sign(ctx)
    assert {:ok, other_page} = authenticate(ctx, other_proof, "other-page")
    refute other_page.topic == session.topic

    assert {:ok, ref} = Runtime.monitor(session)
    stop_supervised!(ctx.spec.id)
    assert_receive {:DOWN, ^ref, :process, _, :shutdown}
    start_supervised!(ctx.spec)
    refute Runtime.authorized?(session)

    assert {:ok, _} = authenticate(ctx, proof)
  end

  test "rejected cross-user renewal does not bind the replacement JWT", ctx do
    {:ok, current_proof} = sign(ctx)
    {:ok, current} = authenticate(ctx, current_proof)

    {:ok, replacement_proof} =
      SignedIdentity.sign(ctx.key, ctx.config.id, %{user_id: "another-visitor"},
        issuer: "parent",
        audience: "widget"
      )

    assert {:error, :unauthorized} = Runtime.renew(current, replacement_proof)
    assert Runtime.authorized?(current)

    assert {:ok, %{sender_id: "another-visitor"}} =
             authenticate(ctx, replacement_proof, ctx.page_id <> "-other")
  end

  test "stale first use cannot claim a page and a fresh JWT restores access", ctx do
    reset = BindingStore.reset_cutoff_value()
    delay = max(0, (reset + 6) * 1_000 - System.system_time(:millisecond))
    if delay > 0, do: Process.sleep(delay)
    stale_claims = %{claims(ctx) | "iat" => System.system_time(:second) - 5}
    stale = jwt(ctx.key, stale_claims)

    assert {:error, :unauthorized} = authenticate(ctx, stale)
    assert {:error, :unauthorized} = authenticate(ctx, stale, "other-page")

    fresh =
      jwt(ctx.key, %{
        stale_claims
        | "iat" => System.system_time(:second),
          "jti" => Ecto.UUID.generate()
      })

    assert {:ok, %{sender_id: "visitor"}} = authenticate(ctx, fresh)
    assert {:error, :unauthorized} = authenticate(ctx, fresh, "other-page")
  end

  test "rotation rejects old proofs; keys never appear in public configuration", ctx do
    {:ok, proof} = sign(ctx)
    stop_supervised!(ctx.spec.id)
    config = %{ctx.config | token: Base.url_encode64(:crypto.strong_rand_bytes(32))}
    {:ok, {spec, []}} = RuntimeBuilder.build(config, ctx.hooks, ctx.options)
    start_supervised!(spec)
    assert {:error, :unauthorized} = authenticate(ctx, proof)
    {:ok, public} = Runtime.fetch_widget(ctx.id)
    refute inspect(public) =~ ctx.key

    for key <- [nil, "placeholder", String.duplicate("x", 40)] do
      assert {:error, :invalid_identity_config} =
               RuntimeBuilder.build(%{config | token: key}, ctx.hooks, ctx.options)
    end
  end

  test "simultaneous connectors isolate issuer and audience even with the same key", ctx do
    {config, hooks, _} = Host.fixture()

    config =
      Map.merge(config, %{
        token: ctx.key,
        settings: %{"identity_issuer" => "other-parent", "identity_audience" => "other-widget"}
      })

    {:ok, {spec, []}} = RuntimeBuilder.build(config, hooks, ctx.options)
    start_supervised!(spec)

    for {id, issuer, audience, foreign_issuer, foreign_audience} <- [
          {ctx.config.id, "parent", "widget", "other-parent", "other-widget"},
          {config.id, "other-parent", "other-widget", "parent", "widget"}
        ] do
      {:ok, proof} =
        SignedIdentity.sign(ctx.key, id, %{user_id: "visitor"},
          issuer: issuer,
          audience: audience
        )

      assert {:ok, _} = Runtime.authenticate(to_string(id), proof, ctx.page_id)

      for overrides <- [[issuer: foreign_issuer], [audience: foreign_audience]] do
        {:ok, bad} =
          SignedIdentity.sign(
            ctx.key,
            id,
            %{user_id: "visitor"},
            Keyword.merge([issuer: issuer, audience: audience], overrides)
          )

        assert {:error, :unauthorized} = Runtime.authenticate(to_string(id), bad, ctx.page_id)
      end
    end
  end

  test "rebuilding edited identity settings revokes old sessions and browser/control proofs",
       ctx do
    alias WebWidget.Integration.ControlProof

    for name <- ["identity_issuer", "identity_audience"] do
      {:ok, proof} = sign(ctx)
      assert {:ok, session} = authenticate(ctx, proof)

      {:ok, control} =
        ControlProof.sign(ctx.key, ctx.config.id, "visitor",
          issuer: "parent",
          audience: "widget:control"
        )

      stop_supervised!(ctx.spec.id)
      config = %{ctx.config | settings: Map.put(ctx.config.settings, name, "edited")}

      {:ok, {spec, []}} =
        RuntimeBuilder.build(
          config,
          ctx.hooks,
          Keyword.put(ctx.options, :pubsub_server, WebWidget.PubSub)
        )

      pid = start_supervised!(spec)
      refute Runtime.authorized?(session)
      assert {:error, :unauthorized} = authenticate(ctx, proof)
      assert {:error, :unauthorized} = Runtime.disconnect(ctx.id, "visitor", control)
      issuer = config.settings["identity_issuer"]
      audience = config.settings["identity_audience"]
      {:ok, fresh} = sign(ctx, issuer: issuer, audience: audience)
      assert {:ok, _} = authenticate(ctx, fresh)
      control_user = "control-#{name}"

      {:ok, fresh_control} =
        ControlProof.sign(ctx.key, ctx.config.id, control_user,
          issuer: issuer,
          audience: audience <> ":control"
        )

      assert {:ok, _} = Runtime.disconnect(ctx.id, control_user, fresh_control)
      assert {:ok, public} = Runtime.fetch_widget(ctx.id)
      refute inspect(public) =~ ctx.key
      refute inspect(:sys.get_status(pid)) =~ ctx.key
      stop_supervised!(spec.id)
      start_supervised!(ctx.spec)
    end
  end

  defp sign(ctx, overrides \\ []) do
    SignedIdentity.sign(
      ctx.key,
      ctx.config.id,
      %{user_id: "visitor"},
      Keyword.merge([issuer: "parent", audience: "widget"], overrides)
    )
  end

  test "identity claims are minimal, schema checked and protected against tampering", ctx do
    init = %{user_id: "visitor"}

    {:ok, proof} =
      SignedIdentity.sign(ctx.key, ctx.config.id, init, issuer: "parent", audience: "widget")

    assert {:ok, %{init: %{user_id: "visitor", conversation_id: nil, prompt_context: nil}}} =
             authenticate(ctx, proof)

    [_, payload, _] = String.split(proof, ".")
    claims = payload |> Base.url_decode64!(padding: false) |> Jason.decode!()

    for invalid <- [
          Map.put(claims, "settings", %{theme: "dark"}),
          Map.put(claims, "prompt_context", %{}),
          Map.put(claims, "conversation_id", false),
          Map.delete(claims, "user_id"),
          Map.delete(claims, "jti"),
          Map.put(claims, "aud", ["widget"]),
          Map.put(claims, "iss", " "),
          Map.put(claims, "user_id", " ")
        ] do
      forged_schema = jwt(ctx.key, invalid)
      assert {:error, :unauthorized} = authenticate(ctx, forged_schema)
    end

    for invalid <- [
          "visitor",
          %{user_id: "visitor", settings: %{}},
          %{user_id: "visitor", conversation_id: " "},
          %{user_id: "visitor", prompt_context: String.duplicate("x", 100_001)}
        ] do
      assert {:error, :invalid_identity_config} =
               SignedIdentity.sign(ctx.key, ctx.config.id, invalid,
                 issuer: "parent",
                 audience: "widget"
               )
    end

    [part | rest] = String.split(proof, ".")

    assert {:error, :unauthorized} =
             authenticate(ctx, Enum.join([part <> "x" | rest], "."))
  end

  defp claims(ctx) do
    now = System.system_time(:second)

    %{
      "widget_id" => ctx.config.id,
      "user_id" => "visitor",
      "iss" => "parent",
      "aud" => "widget",
      "iat" => now,
      "exp" => now + 300,
      "jti" => Ecto.UUID.generate()
    }
  end

  test "Node signs tokens accepted here and verifies tokens signed here", ctx do
    claims = claims(ctx)

    {proof, 0} =
      System.cmd("node", ["test/support/integration/jwt_interop.cjs"],
        env: [{"WIDGET_TEST_KEY", ctx.key}, {"WIDGET_TEST_CLAIMS", Jason.encode!(claims)}]
      )

    assert {:ok, %{init: %{user_id: "visitor", conversation_id: nil, prompt_context: nil}}} =
             authenticate(ctx, proof)

    {:ok, proof} = sign(ctx)

    {payload, 0} =
      System.cmd("node", ["test/support/integration/jwt_interop.cjs"],
        env: [{"WIDGET_TEST_KEY", ctx.key}, {"WIDGET_TEST_TOKEN", proof}]
      )

    assert %{
             "user_id" => "visitor",
             "iss" => "parent",
             "aud" => "widget"
           } = Jason.decode!(payload)
  end

  test "rejects algorithm confusion, invalid time claims, wrong key and old Phoenix proofs",
       ctx do
    claims = claims(ctx)

    for header <- [
          %{"alg" => "HS512", "typ" => "JWT"},
          %{"alg" => "HS256", "typ" => "other"},
          %{"alg" => "HS256", "typ" => "JWT", "kid" => "remote-key"}
        ] do
      assert {:error, :unauthorized} = authenticate(ctx, jwt(ctx.key, claims, header))
    end

    unsigned =
      Base.url_encode64(Jason.encode!(%{alg: "none", typ: "JWT"}), padding: false) <>
        "." <> Base.url_encode64(Jason.encode!(claims), padding: false) <> "."

    assert {:error, :unauthorized} = authenticate(ctx, unsigned)

    assert {:error, :unauthorized} =
             authenticate(
               ctx,
               jwt(Base.url_encode64(:crypto.strong_rand_bytes(32)), claims)
             )

    assert {:error, :unauthorized} =
             authenticate(
               ctx,
               Phoenix.Token.sign(ctx.key, "web-widget-init-v2", claims)
             )

    for invalid <- [
          Map.put(claims, "exp", claims["iat"] + 604_801),
          Map.put(claims, "iat", claims["iat"] + 60),
          Map.put(claims, "nbf", claims["iat"] + 60),
          Map.put(claims, "iat", "now"),
          Map.put(claims, "exp", 1.5),
          Map.put(claims, "exp", claims["iat"] - 1),
          Map.put(claims, "jti", "short"),
          Map.delete(claims, "iat"),
          Map.put(claims, "widget_id", to_string(ctx.config.id))
        ] do
      assert {:error, :unauthorized} = authenticate(ctx, jwt(ctx.key, invalid))
    end

    assert {:ok, _} =
             authenticate(ctx, jwt(ctx.key, Map.put(claims, "nbf", claims["iat"])))

    assert {:ok, %{sender_id: "visitor"}} = authenticate(ctx, jwt(ctx.key, claims))
  end

  defp jwt(key, claims, header \\ %{"alg" => "HS256", "typ" => "JWT"}) do
    key |> JOSE.JWK.from_oct() |> JOSE.JWT.sign(header, claims) |> JOSE.JWS.compact() |> elem(1)
  end

  defp authenticate(ctx, proof, page_id \\ nil),
    do: Runtime.authenticate(ctx.id, proof, page_id || ctx.page_id)

  defp await_reset(remaining \\ 50)
  defp await_reset(0), do: flunk("binding store did not become available")

  defp await_reset(remaining) do
    case BindingStore.reset_cutoff_value() do
      reset when is_integer(reset) ->
        reset

      _ ->
        Process.sleep(100)
        await_reset(remaining - 1)
    end
  end
end
