defmodule WebWidget.Integration.RuntimeBuilder do
  @moduledoc """
  Builds a package runtime from host-owned shared-protocol hooks.

  `build/2` reads `config :web_widget, :integration` with `:pubsub_server` and
  `:identity_verifier` (an MFA or `:connector_key`). `build/3` accepts the same options explicitly.
  Connector-key verification requires string-keyed `identity_issuer` and
  `identity_audience` in `config.settings`, with no fallback or adapter defaults;
  the key is read privately from the resolved host `config.token`.
  The verifier is invoked with its configured arguments followed by proof and
  `%{widget_id: string_id, channel_config_id: integer_id}`. It must verify proof
  and scope and return `{:ok, %{sender_id: external_id, expires_at: unix_seconds,
  init: %{user_id: external_id}}}`.
  Missing configuration fails closed. No endpoint or PubSub server is started.
  """

  alias WebWidget.Integration.Installation
  alias WebWidget.Integration.Protocol
  alias WebWidget.Integration.SignedIdentity
  alias WebWidget.Runtime

  def build(config, hooks),
    do: build(config, hooks, Application.get_env(:web_widget, :integration, []))

  @doc "Returns secret-free installation markup for the configured public widget origin."
  def embed_script(widget_id, base_url),
    do:
      Installation.script(widget_id, base_url, Application.get_env(:web_widget, :integration, []))

  def build(%{id: id, provider: provider} = host_config, %{widget_id: id} = hooks, opts)
      when is_integer(id) and id > 0 and provider in [:web_widget, "web_widget"] do
    with {:ok, opts} <- verification_options(host_config, opts),
         {:ok, integration} <- Protocol.new(hooks, opts),
         :ok <- display_name(Map.get(hooks, :display_name)),
         {:ok, config} <-
           Runtime.prepare(%{
             channel_config_id: id,
             integration: integration,
             pubsub_server: integration.pubsub_server,
             widgets: [
               %{
                 widget_id: Integer.to_string(id),
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
         |> Keyword.put(:control_key, key)
         |> Keyword.put(:control_issuer, issuer)
         |> Keyword.put(:control_audience, audience <> ":control")}
      else
        {:error, :invalid_identity_config}
      end
    else
      {:ok, opts}
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
