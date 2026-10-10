defmodule WebWidget.Integration.RuntimeBuilder do
  @moduledoc """
  Builds a package runtime from host-owned shared-protocol hooks.

  `build/2` reads the validated configuration of the explicitly started `WebWidget`.
  `build/3` is a construction-only compatibility API: the resulting child can only
  be installed when its trusted providers match running infrastructure options.
  Connector-key verification requires string-keyed `identity_issuer` and
  `identity_audience` in `config.settings`, with no fallback or adapter defaults;
  the key is read privately from the resolved host `config.token`.
  The verifier is invoked with its configured arguments followed by proof and
  `%{widget_id: string_id, channel_config_id: integer_id}`. It must verify proof
  and scope and return `{:ok, %{sender_id: external_id, expires_at: unix_seconds,
  init: %{user_id: external_id}}}`.
  Missing configuration fails closed. No endpoint or PubSub server is started.
  """

  alias WebWidget.Embedding.Session
  alias WebWidget.Integration.Installation
  alias WebWidget.Integration.Protocol
  alias WebWidget.Integration.Readiness
  alias WebWidget.Integration.SignedIdentity
  alias WebWidget.Runtime

  def build(config, hooks) do
    with {:ok, infrastructure} <- WebWidget.Configuration.fetch(),
         {:ok, {spec, []}} <- build(config, hooks, infrastructure.integration) do
      {module, function, [runtime]} = spec.start
      runtime = Map.put(runtime, :infrastructure_generation, infrastructure.generation)
      {:ok, {%{spec | start: {module, function, [runtime]}}, []}}
    end
  end

  @doc "Returns version-1 local readiness without authenticating a visitor."
  def status(widget_id, opts), do: Readiness.status(widget_id, opts)

  @doc "Returns secret-free installation markup for the configured public widget origin."
  def embed_script(widget_id, base_url) do
    with {:ok, infrastructure} <- WebWidget.Configuration.fetch() do
      Installation.script(widget_id, base_url, infrastructure.integration)
    end
  end

  def build(%{id: id, provider: provider} = host_config, %{widget_id: id} = hooks, opts)
      when is_integer(id) and id > 0 and provider in [:web_widget, "web_widget"] do
    providers =
      if is_list(opts) and Keyword.keyword?(opts),
        do: Keyword.take(opts, [:pubsub_server, :identity_verifier]),
        else: []

    with {:ok, opts} <- verification_options(host_config, opts),
         {:ok, same_site} <-
           Session.validate_settings(Map.get(host_config, :settings)),
         {:ok, integration} <- Protocol.new(hooks, opts),
         :ok <- display_name(Map.get(hooks, :display_name)),
         {:ok, config} <-
           Runtime.prepare(%{
             channel_config_id: id,
             infrastructure_providers: providers,
             integration: integration,
             pubsub_server: integration.pubsub_server,
             widgets: [
               %{
                 widget_id: Integer.to_string(id),
                 same_site: same_site,
                 display_name: Map.get(hooks, :display_name),
                 allowed_domains: Map.get(hooks, :allowed_domains, []),
                 stylesheet_url: nil,
                 multiple_conversations: false
               }
             ]
           }) do
      {:ok, {Runtime.child_spec(config), []}}
    end
  end

  def build(_, _, _), do: {:error, :invalid_integration_config}

  defp verification_options(config, opts) when is_list(opts) do
    if Keyword.keyword?(opts) and opts[:identity_verifier] == :connector_key do
      key = Map.get(config, :token)
      settings = Map.get(config, :settings)
      issuer = if is_map(settings), do: Map.get(settings, "identity_issuer")
      audience = if is_map(settings), do: Map.get(settings, "identity_audience")

      if SignedIdentity.valid_key?(key) and
           SignedIdentity.valid_identifier?(issuer) and SignedIdentity.valid_identifier?(audience) do
        {:ok,
         opts
         |> Keyword.put(:identity_verifier, {SignedIdentity, :verify, [key, issuer, audience]})
         |> Keyword.put(:identity_source, :connector)
         |> Keyword.put(:control_key, key)
         |> Keyword.put(:control_issuer, issuer)
         |> Keyword.put(:control_audience, audience <> ":control")}
      else
        {:error, :invalid_identity_config}
      end
    else
      {:ok, Keyword.delete(opts, :identity_source)}
    end
  end

  defp verification_options(_, _), do: {:error, :invalid_integration_config}

  defp display_name(name) when is_binary(name) do
    if String.valid?(name) and String.trim(name) != "" and byte_size(name) <= 200,
      do: :ok,
      else: {:error, :invalid_runtime_config}
  end

  defp display_name(_), do: {:error, :invalid_runtime_config}
end
