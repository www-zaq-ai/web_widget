defmodule WebWidget.Integration.ControlProof do
  @moduledoc """
  Short-lived, operation-specific backend proof for widget disconnect.
  The connector key stays on the parent backend and the widget server.
  """

  alias WebWidget.Integration.SignedIdentity

  @keys ~w(iss aud op widget_id user_id iat exp jti)
  @max_bytes 4_096

  def sign(key, widget_id, user_id, opts) do
    now = System.system_time(:second)

    max_age =
      lifetime() || WebWidget.Configuration.authentication_default(:control_proof_ttl_seconds)

    ttl = Keyword.get(opts, :ttl, max_age)

    with true <- SignedIdentity.valid_key?(key),
         true <- is_integer(widget_id) and widget_id > 0,
         true <-
           identifier?(user_id) and identifier?(opts[:issuer]) and
             control_audience?(opts[:audience]),
         true <- is_integer(ttl) and ttl in 1..max_age do
      claims = %{
        "iss" => opts[:issuer],
        "aud" => opts[:audience],
        "op" => "disconnect",
        "widget_id" => widget_id,
        "user_id" => user_id,
        "iat" => now,
        "exp" => now + ttl,
        "jti" => Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      }

      {_metadata, proof} =
        key
        |> JOSE.JWK.from_oct()
        |> JOSE.JWT.sign(%{"alg" => "HS256", "typ" => "JWT"}, claims)
        |> JOSE.JWS.compact()

      {:ok, proof}
    else
      _ -> {:error, :invalid_control_config}
    end
  end

  def verify(key, issuer, audience, proof, widget_id, user_id) when is_binary(proof) do
    now = System.system_time(:second)

    with true <- SignedIdentity.valid_key?(key) and byte_size(proof) <= @max_bytes,
         {true, payload, %JOSE.JWS{fields: header, b64: :undefined}} <-
           JOSE.JWS.verify_strict(JOSE.JWK.from_oct(key), ["HS256"], proof),
         true <- header == %{"typ" => "JWT"},
         {:ok, claims} <- Jason.decode(payload),
         true <- is_map(claims) and Enum.sort(Map.keys(claims)) == Enum.sort(@keys),
         %{
           "iss" => ^issuer,
           "aud" => ^audience,
           "op" => "disconnect",
           "widget_id" => ^widget_id,
           "user_id" => ^user_id,
           "iat" => issued,
           "exp" => expiry,
           "jti" => nonce
         } <- claims,
         true <- identifier?(user_id) and identifier?(nonce) and byte_size(nonce) >= 16,
         true <- is_integer(issued) and is_integer(expiry) and issued <= now and expiry > now,
         true <- valid_lifetime?(issued, expiry) do
      {:ok, %{jti: nonce, iat: issued}}
    else
      _ -> {:error, :unauthorized}
    end
  rescue
    _ -> {:error, :unauthorized}
  end

  def verify(_, _, _, _, _, _), do: {:error, :unauthorized}

  defp valid_lifetime?(issued, expiry) do
    maximum = lifetime()
    is_integer(maximum) and expiry > issued and expiry - issued <= maximum
  end

  defp control_audience?(value) when is_binary(value) do
    suffix = ":control"

    if String.valid?(value) and String.ends_with?(value, suffix) do
      value
      |> binary_part(0, byte_size(value) - byte_size(suffix))
      |> SignedIdentity.valid_identifier?()
    else
      false
    end
  end

  defp control_audience?(_), do: false

  defp identifier?(value),
    do:
      is_binary(value) and String.valid?(value) and String.trim(value) == value and
        byte_size(value) in 1..255

  defp lifetime do
    WebWidget.Configuration.authentication(:control_proof_ttl_seconds)
  end
end
