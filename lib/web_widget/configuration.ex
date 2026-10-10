defmodule WebWidget.Configuration do
  @moduledoc false
  use GenServer

  alias WebWidget.Integration.Installation

  @authentication [
    token_ttl_seconds: 604_800,
    refresh_lead_seconds: 300,
    first_binding_window_seconds: 5,
    control_proof_ttl_seconds: 30
  ]
  @options [
    :pubsub_server,
    :identity_verifier,
    :authentication,
    :transport,
    :public_url,
    :token_url,
    :response_diagnostics
  ]

  defstruct [
    :owner,
    :generation,
    :authentication,
    :integration,
    :transport,
    :response_diagnostics
  ]

  def normalize(opts) do
    with :ok <- keywords(opts, @options, :options),
         :ok <- valid_server(opts[:pubsub_server]),
         :ok <- valid_verifier(Keyword.get(opts, :identity_verifier, :connector_key)),
         {:ok, authentication} <- normalize_authentication(Keyword.get(opts, :authentication, [])),
         {:ok, transport} <- transport(Keyword.get(opts, :transport, [])),
         :ok <- installation(opts, transport.prefix),
         true <- is_boolean(Keyword.get(opts, :response_diagnostics, false)) do
      integration =
        [
          pubsub_server: opts[:pubsub_server],
          identity_verifier: Keyword.get(opts, :identity_verifier, :connector_key),
          widget_path: transport.prefix
        ] ++ Keyword.take(opts, [:public_url, :token_url])

      {:ok,
       %__MODULE__{
         authentication: authentication,
         integration: integration,
         transport: transport,
         response_diagnostics: Keyword.get(opts, :response_diagnostics, false)
       }}
    else
      false -> invalid(:response_diagnostics, "must be a boolean")
      error -> error
    end
  end

  def start_link(config), do: GenServer.start_link(__MODULE__, config, name: __MODULE__)

  def fetch do
    case :ets.lookup(__MODULE__, :configuration) do
      [{:configuration, config}] -> {:ok, config}
      [] -> {:error, :infrastructure_not_started}
    end
  rescue
    ArgumentError -> {:error, :infrastructure_not_started}
  end

  def current?(generation) do
    case fetch() do
      {:ok, %{generation: ^generation}} -> true
      _ -> false
    end
  end

  def authentication(key) do
    case fetch() do
      {:ok, config} -> Keyword.fetch!(config.authentication, key)
      _ -> nil
    end
  end

  @impl true
  def init(config) do
    config = %{config | owner: self(), generation: make_ref()}
    :ets.new(__MODULE__, [:named_table, :protected, read_concurrency: true])
    :ets.insert(__MODULE__, {:configuration, config})
    {:ok, config}
  end

  @impl true
  def format_status(status), do: Map.put(status, :state, :private_widget_configuration)

  defp normalize_authentication(opts) do
    with :ok <- keywords(opts, [:replica_nodes | Keyword.keys(@authentication)], :authentication) do
      nodes =
        Keyword.get(opts, :replica_nodes, if(node() == :nonode@nohost, do: [node()], else: []))

      values = Keyword.merge(@authentication, opts) |> Keyword.put(:replica_nodes, nodes)

      cond do
        not (is_list(nodes) and nodes != [] and node() in nodes and
               Enum.all?(nodes, &(is_atom(&1) and &1 not in [nil, true, false])) and
                 nodes == Enum.uniq(nodes)) ->
          invalid(
            :replica_nodes,
            "must be unique node atoms including the local node; distributed membership is required"
          )

        not Enum.all?(@authentication, fn {key, _} ->
          is_integer(values[key]) and values[key] > 0
        end) ->
          invalid(:authentication, "timings must be positive integer seconds")

        values[:token_ttl_seconds] <= values[:refresh_lead_seconds] ->
          invalid(:token_ttl_seconds, "must exceed refresh_lead_seconds")

        true ->
          {:ok, values}
      end
    end
  end

  defp transport(opts) do
    with :ok <- keywords(opts, [:endpoint, :widget_path, :scheme, :tls_options], :transport),
         :ok <- endpoint(opts[:endpoint]),
         true <- Keyword.get(opts, :scheme, :http) in [:http, :https],
         :ok <- tls(Keyword.get(opts, :tls_options, [])) do
      {:ok,
       %{
         endpoint: opts[:endpoint],
         prefix: Keyword.get(opts, :widget_path, "/widget"),
         scheme: Keyword.get(opts, :scheme, :http),
         tls_options: Keyword.get(opts, :tls_options, [])
       }}
    else
      false -> invalid(:scheme, "must be :http or :https")
      error -> error
    end
  end

  defp installation(opts, prefix) do
    install = Keyword.take(opts, [:public_url, :token_url]) ++ [widget_path: prefix]

    case Installation.script(1, "http://localhost", install) do
      {:ok, _} ->
        :ok

      _ ->
        invalid(
          :installation,
          "public_url must be a root HTTP(S) origin, token_url a local path, and widget_path a valid mount prefix"
        )
    end
  end

  defp valid_server(server) when is_atom(server) and server not in [nil, true, false], do: :ok
  defp valid_server(_), do: invalid(:pubsub_server, "must name the host-owned PubSub server")

  defp valid_verifier(:connector_key), do: :ok

  defp valid_verifier({module, function, args})
       when is_atom(module) and is_atom(function) and is_list(args) do
    if Code.ensure_loaded?(module) and function_exported?(module, function, length(args) + 2),
      do: :ok,
      else:
        invalid(
          :identity_verifier,
          "MFA must export the configured arguments plus proof and scope"
        )
  end

  defp valid_verifier(_),
    do: invalid(:identity_verifier, "must be :connector_key or a trusted MFA")

  defp endpoint(nil), do: :ok

  defp endpoint(module) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :server_info, 1),
      do: :ok,
      else: invalid(:endpoint, "must be a Phoenix endpoint module")
  end

  defp endpoint(_), do: invalid(:endpoint, "must be a Phoenix endpoint module")

  defp tls(opts) do
    with :ok <- keywords(opts, [:cacertfile, :cacerts], :tls_options) do
      if Enum.all?(opts, fn
           {:cacertfile, file} -> is_binary(file) or is_list(file)
           {:cacerts, certs} -> is_list(certs) and Enum.all?(certs, &is_binary/1)
         end), do: :ok, else: invalid(:tls_options, "must contain CA certificates or a CA file")
    end
  end

  defp keywords(opts, allowed, field) do
    if is_list(opts) and Keyword.keyword?(opts) and
         Enum.all?(Keyword.keys(opts), &(&1 in allowed)) and
         length(Keyword.keys(opts)) == length(Enum.uniq(Keyword.keys(opts))),
       do: :ok,
       else: invalid(field, "must be a keyword list with supported, unique keys")
  end

  defp invalid(field, message), do: {:error, {:invalid_widget_configuration, field, message}}
end
