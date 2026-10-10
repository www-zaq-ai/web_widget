defmodule WebWidget.Runtime do
  @moduledoc """
  Supervised, server-side configuration for one channel's widgets.

  Start with `{WebWidget.Runtime, config}`. The config contains
  `:channel_config_id`, `:widgets` and either mock `:sink_mfa` configuration or
  private `:integration` configuration supplied by the integration builder.
  Widget IDs are unique across running runtimes. The shared integration uses
  the owning connector ID's string form as its single widget ID.
  Replace the child to apply configuration changes. Stopping it removes its
  widget registrations. `fetch_widget/1` exposes presentation configuration only.
  Callbacks are invoked in the caller, outside the configuration process.
  """

  use GenServer

  alias WebWidget.Embedding.Origins
  alias WebWidget.Configuration
  alias WebWidget.Integration.{BindingStore, ControlProof, Protocol, Session}

  @widget_fields [
    :widget_id,
    :same_site,
    :display_name,
    :allowed_domains,
    :stylesheet_url,
    :multiple_conversations
  ]

  def child_spec(config) do
    %{id: {__MODULE__, config.channel_config_id}, start: {__MODULE__, :start_link, [config]}}
  end

  def start_link(config) do
    with {:ok, infrastructure} <- Configuration.fetch(),
         :ok <- infrastructure_matches(config, infrastructure),
         {:ok, config} <- prepare(config) do
      GenServer.start_link(__MODULE__, {config, infrastructure})
    end
  end

  @doc "Looks up a running widget without exposing its channel ID or sink callback."
  def fetch_widget(widget_id) when is_binary(widget_id) do
    call_widget(widget_id, {:fetch_widget, widget_id})
  end

  @doc false
  def readiness_snapshot(widget_id, timeout)
      when is_binary(widget_id) and is_integer(timeout) and timeout > 0 do
    with {:ok, infrastructure} <- Configuration.fetch(),
         [{pid, _}] <- Registry.lookup(WebWidget.RuntimeRegistry, widget_id),
         {:ok, snapshot} <- GenServer.call(pid, {:readiness_snapshot, widget_id}, timeout),
         true <-
           snapshot.infrastructure_generation == infrastructure.generation and
             Configuration.current?(infrastructure.generation) do
      {:ok, snapshot}
    else
      _ -> {:error, :runtime_not_registered}
    end
  rescue
    _ -> {:error, :runtime_not_registered}
  catch
    :exit, {:timeout, _} -> {:error, :runtime_unresponsive}
    :exit, _ -> {:error, :runtime_not_registered}
  end

  @doc "Resolves the host-owned PubSub server for a registered widget."
  def pubsub_server(widget_id) do
    with {:ok, config} <- delivery_config(widget_id),
         server when is_atom(server) and not is_nil(server) <- Map.get(config, :pubsub_server) do
      {:ok, server}
    else
      _ -> {:error, :unavailable}
    end
  end

  @doc "Verifies a backend disconnect proof, commits the cutoff, then notifies matching sessions."
  def disconnect(widget_id, user_id, proof) when is_binary(widget_id) and is_binary(user_id) do
    with {id, ""} <- Integer.parse(widget_id),
         true <- id > 0 and Integer.to_string(id) == widget_id,
         {:ok, %{integration: %Protocol{} = integration, pubsub_server: pubsub}} <-
           delivery_config(widget_id),
         true <- is_binary(integration.control_key),
         {:ok, %{jti: nonce, iat: issued}} <-
           ControlProof.verify(
             integration.control_key,
             integration.control_issuer,
             integration.control_audience,
             proof,
             id,
             user_id
           ),
         {:ok, cutoff, _created} <-
           BindingStore.revoke_user(
             integration.control_issuer,
             id,
             user_id,
             nonce,
             issued,
             System.system_time(:second)
           ),
         :ok <-
           Phoenix.PubSub.broadcast(
             pubsub,
             revocation_topic(widget_id, user_id),
             {:widget_backend_revoked, widget_id, user_id, cutoff}
           ) do
      {:ok, cutoff}
    else
      {:error, :unavailable_or_invalid} -> {:error, :unavailable}
      {:error, :stale_control_request} -> {:error, :unauthorized}
      {:error, :unavailable} -> {:error, :unavailable}
      _ -> {:error, :unauthorized}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  def disconnect(_, _, _), do: {:error, :unauthorized}

  def backend_revoked?(%Session{binding_claims: claims}) when is_map(claims),
    do: BindingStore.revoked?(claims) == true

  def backend_revoked?(_), do: false

  def revocation_topic(widget_id, user_id),
    do: "web_widget:revocation:" <> widget_id <> ":" <> user_id

  def subscribe_revocation(session) do
    with {:ok, config} <- session_config(session),
         topic = revocation_topic(session.widget_id, session.sender_id),
         :ok <- Phoenix.PubSub.subscribe(config.pubsub_server, topic) do
      {:ok, {config.pubsub_server, topic}}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  @doc "Invokes a legacy/mock callback; integrated runtimes require dispatch/2 with a session."
  def dispatch(%{widget_id: widget_id} = event) do
    case delivery_config(widget_id) do
      {:ok, %{integration: %Protocol{}}} -> {:error, :authentication_required}
      {:ok, %{sink_mfa: {module, function, args}}} -> apply(module, function, [event | args])
      error -> error
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  @doc "Verifies identity through the runtime's configured verifier; never trusts a browser ID."
  def authenticate(widget_id, proof, page_id \\ nil) do
    authenticate_with_sender(widget_id, proof, page_id, nil)
  end

  defp authenticate_with_sender(widget_id, proof, page_id, expected_sender) do
    with {:ok, %{allowed_domains: [_ | _]}} <- fetch_widget(widget_id),
         {:ok, %{integration: integration, runtime_ref: runtime_ref}} <-
           delivery_config(widget_id),
         {:ok, session} <-
           Protocol.authenticate(integration, proof, runtime_ref, page_id, expected_sender),
         {:ok, _config} <- session_config(session) do
      {:ok, session}
    else
      {:error, :store_unavailable} -> {:error, :store_unavailable}
      {:error, :backend_revoked} -> {:error, :backend_revoked}
      _ -> {:error, :unauthorized}
    end
  end

  @doc "Replaces authorization for the same process, verified page, widget and sender."
  def renew(%Session{} = current, proof) do
    with true <- is_binary(current.page_id) and is_map(current.binding_claims),
         :ok <- BindingStore.available?(),
         {:ok, _} <- session_config(current),
         {:ok, replacement} <-
           authenticate_with_sender(current.widget_id, proof, current.page_id, current.sender_id),
         true <-
           replacement.sender_id == current.sender_id and
             replacement.channel_config_id == current.channel_config_id and
             replacement.runtime_ref == current.runtime_ref and
             replacement.page_id == current.page_id do
      {:ok,
       %{
         current
         | expires_at: replacement.expires_at,
           binding_claims: replacement.binding_claims
       }}
    else
      {:error, :unavailable} -> {:error, :store_unavailable}
      {:error, :store_unavailable} -> {:error, :store_unavailable}
      _ -> {:error, :unauthorized}
    end
  end

  def renew(_, _), do: {:error, :unauthorized}

  @doc "Dispatches an internal request using a verified, process-bound session."
  def dispatch(event, session) do
    with {:ok, config} <- session_config(session) do
      Protocol.dispatch(config.integration, event, session)
    end
  end

  @doc "Subscribes the verified caller before its first question; no conversation ID is needed."
  def subscribe(session) do
    with {:ok, config} <- session_config(session),
         :ok <- Phoenix.PubSub.subscribe(config.pubsub_server, session.topic) do
      {:ok, {config.pubsub_server, session.topic}}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @doc "Checks expiry and current runtime generation before consuming a response."
  def authorized?(session), do: match?({:ok, _}, session_config(session))

  @doc "Identifies shared-protocol runtimes without exposing their private config."
  def integrated?(widget_id),
    do: match?({:ok, %{integration: %Protocol{}}}, delivery_config(widget_id))

  @doc "Monitors the exact runtime generation to revoke connected iframe sessions."
  def monitor(session) do
    with {:ok, _} <- session_config(session),
         [{pid, _}] <- Registry.lookup(WebWidget.RuntimeRegistry, session.widget_id) do
      ref = Process.monitor(pid)
      if authorized?(session), do: {:ok, ref}, else: demonitor_session(ref)
    else
      _ -> {:error, :unauthorized}
    end
  end

  defp demonitor_session(ref) do
    Process.demonitor(ref, [:flush])
    {:error, :unauthorized}
  end

  defp session_config(%Session{} = session) do
    with {:ok, %{integration: %Protocol{}, runtime_ref: runtime_ref} = config} <-
           delivery_config(session.widget_id),
         true <- Session.valid?(session, runtime_ref, config.channel_config_id) do
      {:ok, config}
    else
      _ -> {:error, :unauthorized}
    end
  end

  defp session_config(_), do: {:error, :unauthorized}

  defp delivery_config(widget_id), do: call_widget(widget_id, :delivery_config)

  defp call_widget(widget_id, request) do
    with {:ok, infrastructure} <- Configuration.fetch(),
         [{pid, generation}] <- Registry.lookup(WebWidget.RuntimeRegistry, widget_id),
         true <- generation == infrastructure.generation,
         result <- GenServer.call(pid, request),
         true <- Configuration.current?(generation) do
      result
    else
      _ -> {:error, :not_found}
    end
  rescue
    ArgumentError -> {:error, :not_found}
  catch
    :exit, _ -> {:error, :not_found}
  end

  @impl true
  def init({config, infrastructure}) do
    config =
      config
      |> Map.put(:runtime_ref, make_ref())
      |> Map.put(:infrastructure_generation, infrastructure.generation)
      |> Map.put(:infrastructure_monitor, Process.monitor(infrastructure.owner))

    Enum.reduce_while(config.widgets, {:ok, config}, fn widget, acc ->
      case Registry.register(
             WebWidget.RuntimeRegistry,
             widget.widget_id,
             infrastructure.generation
           ) do
        {:ok, _} -> {:cont, acc}
        {:error, {:already_registered, _}} -> {:halt, {:stop, :widget_id_already_registered}}
      end
    end)
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{infrastructure_monitor: ref} = config),
    do: {:stop, :shutdown, config}

  defp infrastructure_matches(config, infrastructure) do
    generation = Map.get(config, :infrastructure_generation, infrastructure.generation)
    providers = Map.get(config, :infrastructure_providers, [])
    pubsub = Map.get(config, :pubsub_server, infrastructure.integration[:pubsub_server])

    if generation == infrastructure.generation and
         pubsub == infrastructure.integration[:pubsub_server] and
         Enum.all?(providers, fn {key, value} -> infrastructure.integration[key] == value end),
       do: :ok,
       else: {:error, :infrastructure_configuration_mismatch}
  end

  @impl true
  def format_status(status), do: Map.put(status, :state, :private_widget_runtime)

  @impl true
  def handle_call(:delivery_config, _from, config) do
    fields = [:channel_config_id, :sink_mfa, :pubsub_server, :integration, :runtime_ref]
    {:reply, {:ok, Map.take(config, fields)}, config}
  end

  def handle_call({:fetch_widget, widget_id}, _from, config) do
    widget = Enum.find(config.widgets, &(&1.widget_id == widget_id))
    {:reply, if(widget, do: {:ok, widget}, else: {:error, :not_found}), config}
  end

  def handle_call({:readiness_snapshot, widget_id}, _from, config) do
    widget = Enum.find(config.widgets, &(&1.widget_id == widget_id))
    identity = readiness_identity(Map.get(config, :integration))

    snapshot = %{
      widget: widget,
      runtime_ref: config.runtime_ref,
      infrastructure_generation: config.infrastructure_generation,
      pubsub_server: Map.get(config, :pubsub_server),
      identity: identity
    }

    {:reply, {:ok, snapshot}, config}
  end

  defp readiness_identity(%Protocol{
         identity_source: :connector,
         identity_verifier:
           {WebWidget.Integration.SignedIdentity, :verify, [key, issuer, audience]},
         control_key: key,
         control_issuer: issuer
       })
       when is_binary(key) do
    %{issuer: issuer, audience: audience}
  end

  defp readiness_identity(_), do: nil

  @doc false
  def prepare(%{integration: %Protocol{} = integration, channel_config_id: id} = config) do
    if integration.hooks.widget_id == id do
      config
      |> Map.put(:sink_mfa, integration.hooks.sink_mfa)
      |> normalize_config()
      |> case do
        {:ok, normalized} ->
          {:ok, normalized |> Map.delete(:sink_mfa) |> Map.put(:integration, integration)}

        error ->
          error
      end
    else
      {:error, :invalid_runtime_config}
    end
  end

  def prepare(%{integration: _}), do: {:error, :invalid_runtime_config}
  def prepare(config), do: normalize_config(config)

  defp normalize_config(
         %{
           channel_config_id: id,
           sink_mfa: {module, function, args},
           widgets: widgets
         } = config
       )
       when not is_nil(id) and is_atom(module) and is_atom(function) and is_list(args) and
              is_list(widgets) do
    normalized = Enum.map(widgets, &normalize_widget/1)

    if Enum.all?(normalized, &match?({:ok, _}, &1)) and
         length(Enum.uniq_by(widgets, & &1.widget_id)) == length(widgets) do
      {:ok,
       config
       |> Map.take([
         :channel_config_id,
         :sink_mfa,
         :pubsub_server,
         :infrastructure_generation,
         :infrastructure_providers
       ])
       |> Map.put(:widgets, Enum.map(normalized, &elem(&1, 1)))}
    else
      {:error, :invalid_runtime_config}
    end
  end

  defp normalize_config(_), do: {:error, :invalid_runtime_config}

  defp normalize_widget(%{widget_id: id, display_name: name} = widget)
       when is_binary(id) and id != "" and is_binary(name) do
    with true <- is_boolean(Map.get(widget, :multiple_conversations, false)),
         true <- Map.get(widget, :same_site) in ["None", "Lax", "Strict"],
         {:ok, origins} <- Origins.normalize(Map.get(widget, :allowed_domains)),
         true <- valid_stylesheet_url?(Map.get(widget, :stylesheet_url)) do
      {:ok, widget |> Map.take(@widget_fields) |> Map.put(:allowed_domains, origins)}
    else
      _ -> :error
    end
  end

  defp normalize_widget(_), do: :error

  defp valid_stylesheet_url?(nil), do: true

  defp valid_stylesheet_url?(url) when is_binary(url) do
    with false <- String.contains?(url, ["\\", " ", "\t", "\n", "\r"]),
         {:ok, uri} <- URI.new(url) do
      (uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" and
         is_nil(uri.userinfo)) or
        (is_nil(uri.scheme) and is_nil(uri.host) and String.starts_with?(url, "/") and
           not String.starts_with?(url, "//"))
    else
      _ -> false
    end
  end

  defp valid_stylesheet_url?(_), do: false
end
