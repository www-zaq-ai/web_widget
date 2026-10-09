defmodule WebWidgetWeb.IntegratedWidgetLiveTest do
  use WebWidgetWeb.ConnCase
  import Phoenix.LiveViewTest
  alias WebWidget.Integration.{BindingStore, ControlProof, RuntimeBuilder, SignedIdentity}
  alias WebWidget.TestIntegration.ChatHost

  setup %{conn: conn} do
    id = System.unique_integer([:positive])
    key = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    hooks = %{
      widget_id: id,
      display_name: "Shared widget",
      allowed_domains: ["http://www.example.com"],
      message: ChatHost,
      command: ChatHost,
      response: ChatHost,
      context: ChatHost,
      delivery: ChatHost,
      sink_mfa: {ChatHost, :receive_request, [self()]}
    }

    {:ok, {spec, []}} =
      RuntimeBuilder.build(
        %{
          id: id,
          provider: "web_widget",
          token: key,
          settings: %{"identity_issuer" => "parent", "identity_audience" => "widget"}
        },
        hooks,
        pubsub_server: WebWidget.PubSub,
        identity_verifier: :connector_key
      )

    start_supervised!(spec)
    reset = await_reset()
    delay = max(0, (reset + 1) * 1_000 - System.system_time(:millisecond))
    if delay > 0, do: Process.sleep(delay)
    {:ok, view, _} = live(conn, "/widget/#{id}")
    assert_push_event(view, "widget.authentication.required", %{reason: "initial_authentication"})
    %{view: view, key: key, id: id, spec: spec, conn: conn}
  end

  test "connected mount authenticates before shared host initialization", ctx do
    proof = token(ctx)

    {:ok, wrong_issuer} =
      SignedIdentity.sign(ctx.key, ctx.id, %{user_id: "visitor"},
        issuer: "wrong",
        audience: "widget"
      )

    {:ok, wrong_audience} =
      SignedIdentity.sign(ctx.key, ctx.id, %{user_id: "visitor"},
        issuer: "parent",
        audience: "wrong"
      )

    {:ok, wrong_widget} =
      SignedIdentity.sign(ctx.key, ctx.id + 1, %{user_id: "visitor"},
        issuer: "parent",
        audience: "widget"
      )

    for rejected_proof <- [wrong_issuer, wrong_audience, wrong_widget, proof <> "x"] do
      rejected_conn = put_connect_params(ctx.conn, %{"identity_token" => rejected_proof})
      {:ok, rejected, _} = live(rejected_conn, "/widget/#{ctx.id}")
      refute has_element?(rejected, "#web-widget")
      refute_receive {:shared_request, %{type: :conversation_init}, _, _}
    end

    conn = put_connect_params(ctx.conn, %{"identity_token" => proof})
    {:ok, view, _} = live(conn, "/widget/#{ctx.id}")

    assert_receive {:shared_request, %{type: :conversation_init}, %{sender_id: "visitor"}, _}
    assert has_element?(view, "#web-widget")

    {:ok, replayed, _} = live(conn, "/widget/#{ctx.id}")
    refute has_element?(replayed, "#web-widget")
    refute_receive {:shared_request, %{type: :conversation_init}, _, _}
  end

  test "connected mount authorizes a selected conversation before restoring history", ctx do
    conn =
      put_connect_params(ctx.conn, %{
        "identity_token" => token(ctx),
        "conversation_id" => "conversation-1"
      })

    {:ok, view, _} = live(conn, "/widget/#{ctx.id}")

    assert_receive {:shared_request,
                    %{type: :conversation_init, conversation_id: "conversation-1"}, _, _}

    assert_receive {:shared_request,
                    %{type: :conversation_history, conversation_id: "conversation-1"}, _, _}

    assert render(view) =~ "Saved answer"

    rejected =
      put_connect_params(ctx.conn, %{
        "identity_token" => token(ctx),
        "conversation_id" => "foreign"
      })

    {:ok, denied, _} = live(rejected, "/widget/#{ctx.id}")
    refute has_element?(denied, "#web-widget")

    assert_receive {:shared_request, %{type: :conversation_init, conversation_id: "foreign"}, _,
                    _}

    refute_receive {:shared_request, %{type: :conversation_history}, _, _}
  end

  test "failed mount retains untrusted selection until authenticated restoration", ctx do
    conn =
      put_connect_params(ctx.conn, %{
        "identity_token" => "expired",
        "conversation_id" => "conversation-1"
      })

    {:ok, view, _} = live(conn, "/widget/#{ctx.id}")
    refute_receive {:shared_request, _, _, _}
    render_event(view, "widget.context", %{identity_token: token(ctx)}, %{ok: true})

    assert_receive {:shared_request,
                    %{type: :conversation_init, conversation_id: "conversation-1"}, _, _}

    assert_receive {:shared_request,
                    %{type: :conversation_history, conversation_id: "conversation-1"}, _, _}

    assert render(view) =~ "Saved answer"
    render_event(view, "widget.submit", %{text: "instant"}, %{ok: true})

    assert_receive {:shared_request, %{content: "instant", conversation_id: "conversation-1"}, _,
                    _}

    assert render(view) =~ "Immediate answer"
  end

  test "repeated recovery keeps response delivery and signed revocation", ctx do
    for _ <- 1..2 do
      {:ok, proof} =
        SignedIdentity.sign(ctx.key, ctx.id, %{user_id: "visitor"},
          issuer: "parent",
          audience: "widget",
          ttl: 1
        )

      render_event(ctx.view, "widget.context", %{identity_token: proof}, %{ok: true})
      assert_push_event(ctx.view, "widget.authentication.required", %{}, 1500)
      init(ctx)
      render_event(ctx.view, "widget.submit", %{text: "instant"}, %{ok: true})
      assert_receive {:shared_request, %{content: "instant"}, _, _}
      assert render(ctx.view) =~ "Immediate answer"
      chat = :sys.get_state(ctx.view.pid).socket.assigns.chat
      assert chat.active == nil

      for {server, topic} <- [chat.subscription, chat.revocation_subscription] do
        assert Enum.count(Registry.lookup(server, topic), fn {pid, _} -> pid == ctx.view.pid end) ==
                 1

        pid = ctx.view.pid
        probe = {:subscription_probe, make_ref()}
        :erlang.trace(pid, true, [:receive])
        Phoenix.PubSub.broadcast(server, topic, probe)
        assert_receive {:trace, ^pid, :receive, ^probe}
        refute_receive {:trace, ^pid, :receive, ^probe}
        :erlang.trace(pid, false, [:receive])
      end
    end

    {:ok, proof} =
      ControlProof.sign(ctx.key, ctx.id, "visitor", issuer: "parent", audience: "widget:control")

    assert %{status: 200} =
             Phoenix.ConnTest.build_conn()
             |> Plug.Conn.put_req_header("authorization", "Bearer " <> proof)
             |> Plug.Conn.put_req_header("content-type", "application/json")
             |> post("/widget-api/#{ctx.id}/disconnect", Jason.encode!(%{user_id: "visitor"}))

    assert_push_event(ctx.view, "widget.authentication.required", %{reason: "backend_revoked"})
    render_event(ctx.view, "widget.submit", %{text: "blocked"}, %{ok: false})
    refute_receive {:shared_request, %{content: "blocked"}, _, _}
  end

  test "replacement initialization and history failures retire the previous owner", ctx do
    initial_monitors = Process.info(ctx.view.pid, :monitors)

    for failure <- [:conversation_init, :conversation_history] do
      init(ctx, %{conversation_id: "conversation-1"})
      old = :sys.get_state(ctx.view.pid).socket.assigns.chat
      send(ctx.view.pid, {:widget_session_expired, old.session.topic, old.auth_generation})
      assert_push_event(ctx.view, "widget.authentication.required", %{reason: "expired"})

      :sys.replace_state(ctx.view.pid, fn state ->
        Process.put(:chat_host_failure, failure)
        state
      end)

      render_event(ctx.view, "widget.context", %{identity_token: token(ctx)}, %{ok: false})
      state = :sys.get_state(ctx.view.pid).socket.assigns
      assert state.authentication_pending
      assert state.chat == nil
      assert state.requested_conversation_id == "conversation-1"
      assert Process.read_timer(old.timer) == false
      assert Process.info(ctx.view.pid, :monitors) == initial_monitors
      assert Registry.keys(WebWidget.PubSub, ctx.view.pid) == []
      render_event(ctx.view, "widget.submit", %{text: "blocked"}, %{ok: false})
      refute_receive {:shared_request, %{content: "blocked"}, _, _}

      :sys.replace_state(ctx.view.pid, fn state ->
        Process.delete(:chat_host_failure)
        state
      end)
    end
  end

  test "failed restoration never substitutes a conversation and releases resources", ctx do
    for requested <- ["foreign", "deleted", "unauthorized", "history-failure"] do
      conn =
        put_connect_params(ctx.conn, %{
          "identity_token" => "expired",
          "conversation_id" => requested
        })

      {:ok, view, _} = live(conn, "/widget/#{ctx.id}")
      {:monitors, before} = Process.info(view.pid, :monitors)
      render_event(view, "widget.context", %{identity_token: token(ctx)}, %{ok: false})

      assert_receive {:shared_request, %{type: :conversation_init, conversation_id: ^requested},
                      context, _}

      if requested == "history-failure" do
        assert_receive {:shared_request,
                        %{type: :conversation_history, conversation_id: ^requested}, _, _}
      else
        refute_receive {:shared_request, %{type: :conversation_history}, _, _}
      end

      refute has_element?(view, "#web-widget")
      render_event(view, "widget.submit", %{text: "blocked"}, %{ok: false})
      refute_receive {:shared_request, %{content: _}, _, _}
      assert :sys.get_state(view.pid).socket.assigns.chat == nil
      assert {:monitors, ^before} = Process.info(view.pid, :monitors)

      refute Enum.any?(Registry.lookup(WebWidget.PubSub, context.delivery.topic), fn {pid, _} ->
               pid == view.pid
             end)

      refute Enum.any?(
               Registry.keys(WebWidget.PubSub, view.pid),
               &String.starts_with?(&1, "web_widget:")
             )
    end
  end

  test "verified init is lazy; queued response precedes receipt without losing the answer", ctx do
    refute_receive {:shared_request, _, _, _}
    init(ctx)

    assert_receive {:shared_request, %{type: :conversation_init, conversation_id: nil}, context,
                    _}

    assert context.sender_id == "visitor"
    refute_receive {:shared_request, %{type: :conversation_history}, _, _}
    render_event(ctx.view, "widget.submit", %{text: "instant"}, %{ok: true})
    assert_receive {:shared_request, %{content: "instant", conversation_id: nil}, _, _}
    assert_push_event(ctx.view, "widget.conversation", %{conversation_id: "conversation-1"})
    assert render(ctx.view) =~ "Immediate answer"
    render_event(ctx.view, "widget.submit", %{text: "instant"}, %{ok: true})

    assert_receive {:shared_request, %{content: "instant", conversation_id: "conversation-1"}, _,
                    _}
  end

  test "rejects absent proof, claimed-user mismatch and foreign resume", ctx do
    render_event(ctx.view, "widget.context", %{user_id: "visitor"}, %{ok: false})

    render_event(
      ctx.view,
      "widget.context",
      %{identity_token: token(ctx), user_id: "attacker"},
      %{ok: false}
    )

    refute has_element?(ctx.view, "#web-widget")
    init(ctx)
    render_event(ctx.view, "widget.context.update", %{conversation_id: "foreign"}, %{ok: false})
    refute_receive {:shared_request, %{type: :conversation_history}, _, _}
  end

  test "identity and parent conversation context remain separate",
       ctx do
    proof = token(ctx)

    for override <- [
          %{user_id: "visitor"},
          %{conversation_id: "conversation-1"},
          %{prompt_context: "Injected"},
          %{settings: %{theme: "dark"}},
          %{params: %{stylesheet_url: "https://example.com/style.css"}},
          %{future: true}
        ] do
      render_event(ctx.view, "widget.context", Map.put(override, :identity_token, proof), %{
        ok: false
      })

      refute_receive {:shared_request, _, _, _}
    end

    render_event(ctx.view, "widget.context", %{identity_token: proof}, %{ok: true})

    render_event(ctx.view, "widget.context.update", %{prompt_context: "Parent context"}, %{
      ok: true
    })

    render_event(ctx.view, "widget.submit", %{text: "instant"}, %{ok: true})

    assert_receive {:shared_request,
                    %{content: "instant", prompt_context: "Parent context", conversation_id: nil},
                    %{sender_id: "visitor"}, _}
  end

  test "resume loads canonical IDs and untimestamped history before sending", ctx do
    init(ctx, %{conversation_id: "conversation-1"})
    assert_receive {:shared_request, %{type: :conversation_history, params: %{limit: 50}}, _, _}
    assert render(ctx.view) =~ "Saved answer"
    assert render(ctx.view) =~ "persisted-assistant"
    render_event(ctx.view, "widget.submit", %{text: "instant"}, %{ok: true})
  end

  test "a restored conversation refreshes authorized history on its terminal event", ctx do
    conn =
      put_connect_params(ctx.conn, %{
        "identity_token" => token(ctx),
        "conversation_id" => "conversation-1"
      })

    {:ok, view, _} = live(conn, "/widget/#{ctx.id}")
    assert_receive {:shared_request, %{type: :conversation_history}, context, _}

    terminal =
      ChatHost.response(%{request_id: "resumed-request"}, :message_complete, "conversation-1", %{
        body: "Untrusted terminal body"
      })

    ChatHost.publish(context, %{terminal | conversation_id: "foreign"})
    ChatHost.publish(context, %{terminal | protocol_version: 2})
    refute_receive {:shared_request, %{type: :conversation_history}, _, _}

    ChatHost.publish(context, terminal)

    assert_receive {:shared_request,
                    %{type: :conversation_history, conversation_id: "conversation-1"}, _, _}

    assert render(view) =~ "Saved answer"
    refute render(view) =~ "Untrusted terminal body"

    ChatHost.publish(context, terminal)
    refute_receive {:shared_request, %{type: :conversation_history}, _, _}
    refute_receive {:shared_request, %{content: _}, _, _}
  end

  test "an authorized context selection announces the conversation for reconnect", ctx do
    init(ctx)

    render_event(ctx.view, "widget.context.update", %{conversation_id: "conversation-1"}, %{
      ok: true
    })

    assert_receive {:shared_request,
                    %{type: :conversation_history, conversation_id: "conversation-1"}, _, _}

    assert_push_event(ctx.view, "widget.conversation", %{conversation_id: "conversation-1"})
    assert render(ctx.view) =~ "Saved answer"
  end

  test "correlates streaming and refuses duplicate, foreign and late terminals", ctx do
    init(ctx)
    render_event(ctx.view, "widget.submit", %{text: "stream"}, %{ok: true})
    assert_receive {:shared_request, %{content: "stream"} = request, context, _}
    receipt = ChatHost.response(request, :message_edit, "conversation-1", %{body: "Snapshot"})
    ChatHost.publish(context, %{receipt | request_id: "foreign", payload: %{body: "INJECTED"}})
    ChatHost.publish(context, receipt)
    assert render(ctx.view) =~ "Snapshot"
    refute render(ctx.view) =~ "INJECTED"
    render_event(ctx.view, "widget.submit", %{text: "second"}, %{ok: false})

    ChatHost.publish(context, %{
      receipt
      | type: :message_complete,
        payload: %{body: "Final snapshot"}
    })

    ChatHost.publish(context, %{receipt | type: :message_edit, payload: %{body: "LATE"}})
    assert render(ctx.view) =~ "Final snapshot"
    refute render(ctx.view) =~ "LATE"
  end

  test "renewal during streaming preserves delivery and rejects a different sender", ctx do
    init(ctx)
    assert_receive {:shared_request, %{type: :conversation_init}, _, _}
    render_event(ctx.view, "widget.submit", %{text: "stream"}, %{ok: true})
    assert_receive {:shared_request, %{content: "stream"} = request, context, _}

    ChatHost.publish(
      context,
      ChatHost.response(request, :message_edit, "conversation-1", %{body: "Before renewal"})
    )

    assert render(ctx.view) =~ "Before renewal"

    render_hook(ctx.view, "widget.auth.renew", %{identity_token: token(ctx)})
    assert_reply(ctx.view, %{ok: true, expires_at: expiry, refresh_at: refresh})
    assert expiry > refresh
    refute_receive {:shared_request, %{type: :conversation_init}, _, _}

    wrong = token(ctx, %{user_id: "another-visitor"})
    render_hook(ctx.view, "widget.auth.renew", %{identity_token: wrong})
    assert_reply(ctx.view, %{ok: false, reason: "invalid_credential"})

    ChatHost.publish(
      context,
      ChatHost.response(request, :message_complete, "conversation-1", %{body: "After renewal"})
    )

    assert render(ctx.view) =~ "After renewal"
    render_event(ctx.view, "widget.submit", %{text: "instant"}, %{ok: true})

    assert_receive {:shared_request, %{content: "instant", conversation_id: "conversation-1"}, _,
                    _}
  end

  test "an old expiry timer cannot expire an accepted renewal", ctx do
    {:ok, short} =
      SignedIdentity.sign(ctx.key, ctx.id, %{user_id: "visitor"},
        issuer: "parent",
        audience: "widget",
        ttl: 2
      )

    render_event(ctx.view, "widget.context", %{identity_token: short}, %{ok: true})
    render_hook(ctx.view, "widget.auth.renew", %{identity_token: token(ctx)})
    assert_reply(ctx.view, %{ok: true})
    Process.sleep(2_100)
    render_event(ctx.view, "widget.submit", %{text: "instant"}, %{ok: true})
    assert_receive {:shared_request, %{content: "instant"}, _, _}
  end

  test "runtime termination clears the session and rejects queued delivery", ctx do
    init(ctx)
    render_event(ctx.view, "widget.submit", %{text: "stream"}, %{ok: true})
    assert_receive {:shared_request, %{content: "stream"} = request, context, _}
    stop_supervised!(ctx.spec.id)

    ChatHost.publish(
      context,
      ChatHost.response(request, :message_complete, "conversation-1", %{body: "REVOKED"})
    )

    assert_push_event(ctx.view, "widget.authentication.required", %{})
    refute has_element?(ctx.view, "#web-widget")
    refute render(ctx.view) =~ "REVOKED"
  end

  test "unknown send outcomes block automatic retry", ctx do
    init(ctx)
    render_event(ctx.view, "widget.submit", %{text: "timeout"}, %{ok: false})
    render_event(ctx.view, "widget.submit", %{text: "instant"}, %{ok: false})
    refute_receive {:shared_request, %{content: "instant"}, _, _}
  end

  test "known-ID timeout recovers through reauthorized history before another send", ctx do
    init(ctx)
    render_event(ctx.view, "widget.submit", %{text: "stream"}, %{ok: true})
    assert_receive {:shared_request, %{content: "stream"} = request, context, _}

    ChatHost.publish(
      context,
      ChatHost.response(request, :error, "conversation-1", %{code: :timeout, outcome: :unknown})
    )

    assert render(ctx.view) =~ "outcome is unknown"
    render_event(ctx.view, "widget.submit", %{text: "blocked"}, %{ok: false})
    refute_receive {:shared_request, %{content: "blocked"}, _, _}
    init(ctx, %{conversation_id: "conversation-1"})
    assert_receive {:shared_request, %{type: :conversation_history}, _, _}
    assert render(ctx.view) =~ "Saved answer"
    render_event(ctx.view, "widget.submit", %{text: "instant"}, %{ok: true})

    assert_receive {:shared_request, %{content: "instant", conversation_id: "conversation-1"}, _,
                    _}
  end

  test "connected expiry preserves the mounted view but blocks sending until renewed", ctx do
    {:ok, proof} =
      SignedIdentity.sign(ctx.key, ctx.id, %{user_id: "visitor"},
        issuer: "parent",
        audience: "widget",
        ttl: 1
      )

    render_event(ctx.view, "widget.context", %{identity_token: proof}, %{ok: true})
    assert_push_event(ctx.view, "widget.authentication.required", %{}, 1500)
    assert has_element?(ctx.view, "#web-widget")
    render_event(ctx.view, "widget.submit", %{text: "after expiry"}, %{ok: false})
    refute_receive {:shared_request, %{content: "after expiry"}, _, _}
    render_event(ctx.view, "widget.context", %{identity_token: "invalid"}, %{ok: false})
    assert has_element?(ctx.view, "#web-widget")
    render_event(ctx.view, "widget.submit", %{text: "still expired"}, %{ok: false})
    refute_receive {:shared_request, %{content: "still expired"}, _, _}
    init(ctx)
    render_event(ctx.view, "widget.submit", %{text: "instant"}, %{ok: true})
    assert_receive {:shared_request, %{content: "instant"}, _, _}
  end

  test "runtime revocation still clears an expired view waiting for renewal", ctx do
    {:ok, proof} =
      SignedIdentity.sign(ctx.key, ctx.id, %{user_id: "visitor"},
        issuer: "parent",
        audience: "widget",
        ttl: 1
      )

    render_event(ctx.view, "widget.context", %{identity_token: proof}, %{ok: true})
    assert_push_event(ctx.view, "widget.authentication.required", %{}, 1500)
    assert has_element?(ctx.view, "#web-widget")
    stop_supervised!(ctx.spec.id)
    assert_push_event(ctx.view, "widget.authentication.required", %{})
    refute has_element?(ctx.view, "#web-widget")
  end

  test "terminal failure releases send guard and never exposes private error details", ctx do
    init(ctx)
    render_event(ctx.view, "widget.submit", %{text: "stream"}, %{ok: true})
    assert_receive {:shared_request, %{content: "stream"} = request, context, _}

    ChatHost.publish(
      context,
      ChatHost.response(request, :message_failed, "conversation-1", %{
        code: :dispatch_error,
        error: "PRIVATE_TRACE"
      })
    )

    refute render(ctx.view) =~ "PRIVATE_TRACE"
    render_event(ctx.view, "widget.submit", %{text: "instant"}, %{ok: true})
    assert_receive {:shared_request, %{content: "instant"}, _, _}
  end

  test "renewal cannot change sender and a fresh proof can restore the same sender", ctx do
    init(ctx)

    {:ok, wrong} =
      SignedIdentity.sign(ctx.key, ctx.id, %{user_id: "another-visitor"},
        issuer: "parent",
        audience: "widget"
      )

    render_event(ctx.view, "widget.context", %{identity_token: wrong}, %{ok: false})

    refute_receive {:shared_request, %{type: :conversation_init}, %{sender_id: "another-visitor"},
                    _}

    init(ctx)
    render_event(ctx.view, "widget.submit", %{text: "instant"}, %{ok: true})
    assert_receive {:shared_request, %{content: "instant"}, %{sender_id: "visitor"}, _}
  end

  test "backend disconnect is scoped, idempotent and terminal for the active widget", ctx do
    init(ctx)
    assert_receive {:shared_request, %{type: :conversation_init}, _, _}

    other_conn =
      put_connect_params(ctx.conn, %{"identity_token" => token(ctx, %{user_id: "other"})})

    {:ok, other, _} = live(other_conn, "/widget/#{ctx.id}")
    assert_receive {:shared_request, %{type: :conversation_init}, %{sender_id: "other"}, _}

    {:ok, control} =
      ControlProof.sign(ctx.key, ctx.id, "visitor",
        issuer: "parent",
        audience: "widget:control"
      )

    endpoint = "/widget-api/#{ctx.id}/disconnect"

    request = fn proof, user ->
      Phoenix.ConnTest.build_conn()
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> proof)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> post(endpoint, Jason.encode!(%{user_id: user}))
    end

    assert %{status: 401} = request.(token(ctx), "visitor")
    assert %{status: 401} = request.(control, "another-visitor")
    assert %{status: 401} = request.(control <> "x", "visitor")
    assert has_element?(ctx.view, "#web-widget")

    assert %{status: 401} =
             Phoenix.ConnTest.build_conn()
             |> Plug.Conn.put_req_header("authorization", "Bearer " <> control)
             |> post(endpoint, %{user_id: "visitor"})

    assert %{status: 401} =
             Phoenix.ConnTest.build_conn()
             |> Plug.Conn.put_req_header("authorization", "Bearer " <> control)
             |> Plug.Conn.put_req_header("content-type", "application/json")
             |> post("/widget-api/#{ctx.id + 1}/disconnect", Jason.encode!(%{user_id: "visitor"}))

    assert %{status: 200, resp_body: body} = request.(control, "visitor")
    cutoff = Jason.decode!(body)["cutoff"]
    assert is_integer(cutoff)
    assert_push_event(ctx.view, "widget.authentication.required", %{reason: "backend_revoked"})
    render_event(ctx.view, "widget.submit", %{text: "blocked"}, %{ok: false})
    refute_receive {:shared_request, %{content: "blocked"}, _, _}
    assert %{status: 200, resp_body: retry_body} = request.(control, "visitor")
    assert Jason.decode!(retry_body)["cutoff"] == cutoff

    [_, payload, _] = String.split(control, ".")

    conflicting_claims =
      payload
      |> Base.url_decode64!(padding: false)
      |> Jason.decode!()
      |> Map.put("user_id", "other")

    {_metadata, conflicting_proof} =
      ctx.key
      |> JOSE.JWK.from_oct()
      |> JOSE.JWT.sign(%{"alg" => "HS256", "typ" => "JWT"}, conflicting_claims)
      |> JOSE.JWS.compact()

    assert %{status: 401} = request.(conflicting_proof, "other")
    render_event(ctx.view, "widget.context", %{identity_token: token(ctx)}, %{ok: false})
    render_event(other, "widget.submit", %{text: "instant"}, %{ok: true})
    assert_receive {:shared_request, %{content: "instant"}, %{sender_id: "other"}, _}
  end

  test "a send after cutoff fails closed before the revocation broadcast", ctx do
    init(ctx)
    assert_receive {:shared_request, %{type: :conversation_init}, _, _}
    now = System.system_time(:second)

    assert {:ok, _, true} =
             BindingStore.revoke_user("parent", ctx.id, "visitor", Ecto.UUID.generate(), now, now)

    render_event(ctx.view, "widget.submit", %{text: "blocked"}, %{ok: false})
    assert_push_event(ctx.view, "widget.authentication.required", %{reason: "backend_revoked"})
    refute_receive {:shared_request, %{content: "blocked"}, _, _}
  end

  defp init(ctx, params \\ %{}) do
    render_event(ctx.view, "widget.context", %{identity_token: token(ctx)}, %{
      ok: true
    })

    if map_size(params) > 0,
      do: render_event(ctx.view, "widget.context.update", params, %{ok: true})
  end

  defp token(ctx, claims \\ %{}),
    do:
      elem(
        SignedIdentity.sign(ctx.key, ctx.id, Map.merge(%{user_id: "visitor"}, claims),
          issuer: "parent",
          audience: "widget"
        ),
        1
      )

  defp render_event(view, event, params, expected) do
    render_hook(view, event, params)

    assert_reply(view, %{ok: ok})
    assert ok == expected.ok

    if expected.ok do
      assert has_element?(view, "#web-widget")
    end
  end

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
