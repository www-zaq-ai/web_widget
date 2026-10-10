defmodule WebWidget.Integration.SignedIdentity do
  @moduledoc """
  HS256 JWT parent-backend identity assertions. Never expose the signing key.

  Configure `identity_verifier: :connector_key` in trusted integration options and
  `identity_issuer` / `identity_audience` in connector settings. Mint a fresh proof for each
  iframe connection using `sign/4` on the authenticated parent backend.
  The third argument is a map containing only `:user_id`.
  Standard JWT claims bind issuer, audience, issue/expiry times
  and a random token ID. Use the raw connector key as the HMAC secret, without
  salt or Base64 decoding. Signed tokens provide integrity, not confidentiality.
  """
  alias WebWidget.Integration.{BindingStore, InitClaims}

  @claim_keys ~w(widget_id user_id iss aud iat exp jti nbf)
  @max_proof_bytes 200_000

  def sign(key, widget_id, init, opts) do
    now = System.system_time(:second)

    max_age =
      configured_max_age() || WebWidget.Configuration.authentication_default(:token_ttl_seconds)

    ttl = Keyword.get(opts, :ttl, max_age)

    with true <- is_map(init) and Map.keys(init) == [:user_id],
         {:ok, init} <- InitClaims.normalize(init),
         true <-
           valid_key?(key) and is_integer(widget_id) and widget_id > 0 and
             is_integer(ttl) and ttl in 1..max_age and
             identifier?(opts[:issuer]) and identifier?(opts[:audience]) do
      claims = %{
        "widget_id" => widget_id,
        "user_id" => init.user_id,
        "iss" => opts[:issuer],
        "aud" => opts[:audience],
        "iat" => now,
        "exp" => now + ttl,
        "jti" => Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      }

      {_metadata, token} =
        key
        |> JOSE.JWK.from_oct()
        |> JOSE.JWT.sign(%{"alg" => "HS256", "typ" => "JWT"}, claims)
        |> JOSE.JWS.compact()

      {:ok, token}
    else
      _ -> {:error, :invalid_identity_config}
    end
  end

  def verify(key, issuer, audience, proof, scope) when is_binary(proof) do
    now = System.system_time(:second)

    with {:ok, infrastructure} <- WebWidget.Configuration.fetch(),
         true <- valid_key?(key) and byte_size(proof) <= @max_proof_bytes,
         {true, payload, %JOSE.JWS{fields: header, b64: :undefined}} <-
           JOSE.JWS.verify_strict(JOSE.JWK.from_oct(key), ["HS256"], proof),
         true <- header == %{"typ" => "JWT"},
         {:ok, claims} <- Jason.decode(payload),
         %{
           "widget_id" => id,
           "user_id" => sender,
           "iss" => ^issuer,
           "aud" => ^audience,
           "iat" => issued,
           "exp" => expiry,
           "jti" => nonce
         } <- claims,
         true <- Enum.all?(Map.keys(claims), &(&1 in @claim_keys)),
         {:ok, init} <-
           InitClaims.normalize(%{user_id: sender}),
         true <- Map.get(scope, :expected_sender) in [nil, init.user_id],
         true <- is_integer(id) and id > 0 and id == scope.channel_config_id,
         true <-
           valid_times?(
             issued,
             expiry,
             Map.get(claims, "nbf", issued),
             now,
             infrastructure.authentication[:token_ttl_seconds]
           ),
         true <- identifier?(nonce) and byte_size(nonce) >= 16,
         true <- identifier?(Map.get(scope, :page_id)) do
      binding = %{
        issuer: issuer,
        audience: audience,
        widget_id: id,
        user_id: sender,
        jti: nonce,
        iat: issued,
        exp: expiry
      }

      result =
        if expiry > now,
          do: claim_binding(binding, scope.page_id, now, sender, expiry, init),
          else: revoked_error(binding)

      fenced_result(result, infrastructure.generation)
    else
      _ -> {:error, :unauthorized}
    end
  rescue
    _ -> {:error, :unauthorized}
  end

  def verify(_, _, _, _, _), do: {:error, :unauthorized}

  defp claim_binding(binding, page_id, now, sender, expiry, init) do
    case BindingStore.claim(binding, page_id, now) do
      :ok ->
        {:ok,
         %{
           sender_id: sender,
           expires_at: expiry,
           init: init,
           binding_claims: binding,
           page_id: page_id
         }}

      {:error, :stale_or_revoked} ->
        revoked_error(binding)

      {:error, :unavailable_or_invalid} ->
        {:error, :store_unavailable}

      _ ->
        {:error, :unauthorized}
    end
  end

  defp revoked_error(binding) do
    case BindingStore.revoked?(binding) do
      true -> {:error, :backend_revoked}
      false -> {:error, :unauthorized}
      _ -> {:error, :store_unavailable}
    end
  end

  defp valid_times?(issued, expiry, not_before, now, maximum) do
    is_integer(maximum) and
      is_integer(issued) and is_integer(expiry) and is_integer(not_before) and
      issued <= now and not_before <= now and not_before < expiry and
      expiry > issued and expiry - issued <= maximum
  end

  defp fenced_result(result, generation) do
    if WebWidget.Configuration.current?(generation),
      do: result,
      else: {:error, :store_unavailable}
  end

  defp configured_max_age do
    WebWidget.Configuration.authentication(:token_ttl_seconds)
  end

  def valid_key?(key) when is_binary(key),
    do:
      byte_size(key) >= 32 and String.valid?(key) and
        length(Enum.uniq(String.graphemes(key))) >= 8

  def valid_key?(_), do: false

  @doc false
  def valid_identifier?(value), do: identifier?(value)

  defp identifier?(value),
    do:
      is_binary(value) and String.valid?(value) and String.trim(value) == value and
        byte_size(value) in 1..255
end
