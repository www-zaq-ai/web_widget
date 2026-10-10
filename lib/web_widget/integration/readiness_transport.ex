defmodule WebWidget.Integration.ReadinessTransport do
  @moduledoc false

  alias WebWidget.Embedding.Session
  alias WebWidget.Integration.Readiness

  @websocket_guid "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
  @max_page_bytes 1_048_576

  def check(widget, deadline) do
    with {:ok, deployment} <- deployment(),
         {:ok, target} <- listener(deployment),
         :ok <- socket_mount(target),
         {:ok, policy} <- Session.effective(widget, target.endpoint, target.scheme) do
      probe(widget, target, policy, deadline)
    else
      {:error, reason} -> failure(network_reason(reason))
    end
  rescue
    _ -> failure(:check_failed)
  catch
    :throw, :readiness_deadline -> failure(:check_timeout)
    _, _ -> failure(:check_failed)
  end

  defp deployment do
    with {:ok, config} <- WebWidget.Configuration.fetch(),
         true <- not is_nil(config.transport.endpoint) do
      {:ok, Map.put(config.transport, :generation, config.generation)}
    else
      _ -> {:error, :transport_unverifiable}
    end
  end

  defp listener(deployment) do
    info =
      if Process.whereis(deployment.endpoint),
        do: deployment.endpoint.server_info(deployment.scheme),
        else: {:error, :not_started}

    case info do
      {:ok, {ip, port}} ->
        host = Keyword.get(deployment.endpoint.config(:url, []), :host, "localhost")
        ip = loopback(ip)
        origin = URI.to_string(%URI{scheme: to_string(deployment.scheme), host: host, port: port})

        url =
          URI.to_string(%URI{
            scheme: to_string(deployment.scheme),
            host: to_string(:inet.ntoa(ip)),
            port: port
          })

        {:ok,
         Map.merge(deployment, %{
           ip: ip,
           port: port,
           host: host,
           origin: origin,
           url: url,
           endpoint_pid: Process.whereis(deployment.endpoint)
         })}

      _ ->
        {:error, :transport_not_listening}
    end
  rescue
    _ -> {:error, :transport_unverifiable}
  catch
    :exit, _ -> {:error, :transport_not_listening}
  end

  defp loopback({0, 0, 0, 0}), do: {127, 0, 0, 1}
  defp loopback({0, 0, 0, 0, 0, 0, 0, 0}), do: {0, 0, 0, 0, 0, 0, 0, 1}
  defp loopback(ip), do: ip

  defp socket_mount(target) do
    mounted =
      Enum.any?(target.endpoint.__sockets__(), fn
        {path, WebWidget.Embedding.Socket, opts} ->
          path == target.prefix <> "/:widget_id/live" and Keyword.get(opts, :websocket) != false

        _ ->
          false
      end)

    if mounted, do: :ok, else: {:error, :transport_unverifiable}
  end

  defp probe(widget, target, policy, deadline) do
    path = target.prefix <> "/" <> widget.widget_id

    with {:ok, response} <- page(target, path, deadline),
         :ok <- page_paths(response, path),
         {:ok, cookie, csrf} <- bootstrap(target, path, policy, deadline),
         :ok <- upgrade(target, path, cookie, csrf, deadline),
         :ok <- current_deployment(target),
         :ok <- current_listener(target),
         :ok <- current_policy(widget, target, policy) do
      {Readiness.check(), Readiness.check(), %{value: policy.same_site, source: policy.source}}
    else
      {:error, reason} -> failure(network_reason(reason))
    end
  end

  defp current_deployment(target) do
    case deployment() do
      {:ok, current} ->
        if current == Map.take(target, [:endpoint, :prefix, :scheme, :tls_options, :generation]),
          do: :ok,
          else: {:error, :transport_unverifiable}

      error ->
        error
    end
  end

  defp current_listener(target) do
    with true <- Process.whereis(target.endpoint) == target.endpoint_pid,
         {:ok, {ip, port}} <- target.endpoint.server_info(target.scheme),
         true <- loopback(ip) == target.ip and port == target.port do
      :ok
    else
      _ -> {:error, :transport_not_listening}
    end
  end

  defp current_policy(widget, target, policy) do
    case Session.effective(widget, target.endpoint, target.scheme) do
      {:ok, ^policy} -> :ok
      {:ok, _} -> {:error, :cookie_policy_mismatch}
      error -> error
    end
  end

  defp page(target, path, deadline), do: request(target, path, deadline, [])

  defp request(target, path, deadline, headers) do
    # Stable connection options share Req's pools; the outer worker bounds the whole probe.
    Req.get(target.url <> path,
      headers: [{"host", URI.parse(target.origin).authority || target.host} | headers],
      retry: false,
      redirect: false,
      decode_body: false,
      receive_timeout: Readiness.remaining(deadline),
      connect_options: [
        timeout: 2_000,
        hostname: target.host,
        transport_opts: target.tls_options
      ],
      into: fn {:data, data}, {request, response} ->
        body = (response.body || "") <> data

        if byte_size(body) <= @max_page_bytes,
          do: {:cont, {request, %{response | body: body}}},
          else: {:halt, {request, %{response | status: 413, body: ""}}}
      end
    )
  end

  defp page_paths(%{status: 200, body: body} = response, path) when is_binary(body) do
    with [] <- widget_cookies(response),
         socket_path when socket_path == path <> "/live" <- meta(body, "web-widget-socket"),
         session_path when session_path == path <> "/session" <- meta(body, "web-widget-session") do
      :ok
    else
      _ -> {:error, :transport_unverifiable}
    end
  end

  defp page_paths(%{status: 503, body: "https_required"}, _), do: {:error, :https_required}
  defp page_paths(_, _), do: {:error, :transport_unverifiable}

  defp bootstrap(target, path, policy, deadline) do
    headers = [{"accept", "application/json"}, {"origin", target.origin}]

    with {:ok, response} <- request(target, path <> "/session", deadline, headers),
         {:ok, _csrf} <- session_token(response),
         {:ok, cookie} <- session_cookie(response, path, policy),
         {:ok, verified} <-
           request(target, path <> "/session?verify=1", deadline, [{"cookie", cookie} | headers]),
         [] <- widget_cookies(verified),
         {:ok, csrf} <- session_token(verified) do
      {:ok, cookie, csrf}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :cookie_policy_unsupported}
    end
  end

  defp session_cookie(response, path, policy) do
    case widget_cookies(response) do
      [cookie] ->
        if cookie_matches?(cookie, path, policy),
          do: {:ok, hd(String.split(cookie, ";"))},
          else: {:error, :cookie_policy_mismatch}

      _ ->
        {:error, :cookie_policy_unsupported}
    end
  end

  defp session_token(%{status: 200, body: body} = response) when is_binary(body) do
    with true <- no_store?(response),
         true <- json?(response),
         {:ok, %{"csrf_token" => token}} <- Jason.decode(body),
         true <- is_binary(token) and byte_size(token) in 1..4_096 do
      {:ok, token}
    else
      _ -> {:error, :transport_unverifiable}
    end
  end

  defp session_token(%{status: 409}), do: {:error, :cookie_policy_unsupported}
  defp session_token(%{status: 503, body: "https_required"}), do: {:error, :https_required}
  defp session_token(_), do: {:error, :transport_unverifiable}

  defp widget_cookies(response) do
    response
    |> Req.Response.get_header("set-cookie")
    |> Enum.filter(&String.starts_with?(&1, "_web_widget_session="))
  end

  defp no_store?(response) do
    response
    |> Req.Response.get_header("cache-control")
    |> Enum.any?(fn value -> "no-store" in String.split(String.downcase(value), ~r/\s*,\s*/) end)
  end

  defp json?(response) do
    response
    |> Req.Response.get_header("content-type")
    |> Enum.any?(fn value ->
      value |> String.split(";", parts: 2) |> hd() |> String.trim() |> String.downcase() ==
        "application/json"
    end)
  end

  defp cookie_matches?(cookie, path, policy) do
    attrs = cookie |> String.split(";") |> tl() |> Enum.map(&String.trim/1)

    Enum.member?(attrs, "path=" <> path) and
      Enum.member?(attrs, "SameSite=" <> policy.same_site) and
      Enum.member?(attrs, "HttpOnly") and
      Enum.member?(attrs, "secure") == policy.secure and
      Enum.member?(attrs, "Partitioned") == policy.partitioned and
      not Enum.any?(attrs, &String.starts_with?(String.downcase(&1), "domain="))
  end

  defp meta(body, name) do
    case Regex.run(~r/<meta\s+name="#{Regex.escape(name)}"\s+content="([^"]+)"\s*\/?\s*>/, body) do
      [_, value] -> value
      _ -> nil
    end
  end

  defp upgrade(target, path, cookie, csrf, deadline) do
    opts = [
      mode: :passive,
      protocols: [:http1],
      hostname: target.host,
      transport_opts: Keyword.put(target.tls_options, :timeout, Readiness.remaining(deadline))
    ]

    case Mint.HTTP.connect(target.scheme, target.ip, target.port, opts) do
      {:ok, conn} ->
        try do
          websocket(conn, target, path, cookie, csrf, deadline)
        after
          Mint.HTTP.close(conn)
        end

      {:error, error} ->
        {:error, network_reason(error)}
    end
  end

  defp websocket(conn, target, path, cookie, csrf, deadline) do
    key = Base.encode64(:crypto.strong_rand_bytes(16))
    expected = Base.encode64(:crypto.hash(:sha, key <> @websocket_guid))
    query = URI.encode_query(%{"_csrf_token" => csrf, "vsn" => "2.0.0"})

    headers = [
      {"connection", "Upgrade"},
      {"upgrade", "websocket"},
      {"sec-websocket-version", "13"},
      {"sec-websocket-key", key},
      {"cookie", cookie},
      {"origin", target.origin}
    ]

    case Mint.HTTP.request(conn, "GET", path <> "/live/websocket?" <> query, headers, nil) do
      {:ok, conn, ref} -> receive_upgrade(conn, ref, expected, deadline, nil, [])
      {:error, _conn, error} -> {:error, network_reason(error)}
    end
  end

  defp receive_upgrade(conn, ref, expected, deadline, status, headers) do
    case Mint.HTTP.recv(conn, 0, Readiness.remaining(deadline)) do
      {:ok, conn, responses} ->
        {status, headers} =
          Enum.reduce(responses, {status, headers}, fn
            {:status, ^ref, value}, {_, h} -> {value, h}
            {:headers, ^ref, value}, {s, h} -> {s, h ++ value}
            _, acc -> acc
          end)

        cond do
          status == 101 and headers != [] ->
            verify_upgrade(headers, expected)

          not is_nil(status) and status != 101 ->
            {:error, :transport_unverifiable}

          true ->
            receive_upgrade(conn, ref, expected, deadline, status, headers)
        end

      {:error, _conn, error, _responses} ->
        {:error, network_reason(error)}
    end
  end

  defp verify_upgrade(headers, expected) do
    if valid_upgrade?(headers, expected), do: :ok, else: {:error, :transport_unverifiable}
  end

  defp valid_upgrade?(headers, expected) do
    headers = Map.new(headers)

    headers["sec-websocket-accept"] == expected and
      String.downcase(headers["upgrade"] || "") == "websocket" and
      "upgrade" in String.split(String.downcase(headers["connection"] || ""), ~r/\s*,\s*/)
  end

  defp failure(reason) do
    cookie_reasons = [:cookie_policy_mismatch, :secure_cookie_required, :https_required]

    cond do
      reason in cookie_reasons ->
        {Readiness.check(:unknown, :transport_unverifiable),
         Readiness.check(:unavailable, reason), Readiness.unresolved()}

      reason == :transport_not_listening ->
        {Readiness.check(:unavailable, reason),
         Readiness.check(:unknown, :cookie_policy_unsupported), Readiness.unresolved()}

      reason in [:cookie_policy_unsupported, :missing_cookie_policy, :invalid_partitioned_policy] ->
        {Readiness.check(:unknown, :transport_unverifiable),
         Readiness.check(:unknown, :cookie_policy_unsupported), Readiness.unresolved()}

      true ->
        {Readiness.check(
           :unknown,
           if(reason in [:check_failed, :check_timeout],
             do: reason,
             else: :transport_unverifiable
           )
         ), Readiness.check(:unknown, :cookie_policy_unsupported), Readiness.unresolved()}
    end
  end

  defp network_reason(%{reason: :timeout}), do: :check_timeout
  defp network_reason(%{reason: :econnrefused}), do: :transport_not_listening
  defp network_reason(reason) when is_atom(reason), do: reason
  defp network_reason(_), do: :transport_unverifiable
end
