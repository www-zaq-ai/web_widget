defmodule WebWidget.Integration.Installation do
  @moduledoc "Secret-free installation markup for a root-mounted widget endpoint."

  @doc "Uses the configured public origin, or the host base origin with deployment proxying."
  def script(widget_id, base_url, opts \\ [])

  def script(widget_id, base_url, opts) when is_integer(widget_id) and widget_id > 0 do
    widget_script(Integer.to_string(widget_id), base_url, opts)
  end

  def script(_, _, _), do: {:error, :invalid_widget_installation}

  @doc "Renders the same loader for named standalone widgets and numeric host connectors."
  def widget_script(widget_id, base_url, opts \\ [])

  def widget_script(widget_id, base_url, opts) when is_binary(widget_id) do
    with true <- String.valid?(widget_id) and byte_size(widget_id) in 1..200,
         true <- Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9_-]*\z/, widget_id),
         true <- Keyword.keyword?(opts),
         {:ok, _} <- origin(base_url),
         {:ok, url} <- origin(Keyword.get(opts, :public_url, base_url)),
         {:ok, prefix} <- widget_path(Keyword.get(opts, :widget_path, "/widget")),
         {:ok, token_attribute} <- token_attribute(Keyword.get(opts, :token_url)) do
      src = Phoenix.HTML.html_escape(url <> "/web_widget/assets/embed.js")
      widget_url = Phoenix.HTML.html_escape(url <> prefix <> "/" <> widget_id)

      snippet =
        "<script src=\"#{Phoenix.HTML.safe_to_string(src)}\" data-widget-id=\"#{widget_id}\" data-widget-url=\"#{Phoenix.HTML.safe_to_string(widget_url)}\"#{token_attribute} defer></script>"

      if byte_size(snippet) <= 32_768,
        do: {:ok, snippet},
        else: {:error, :invalid_widget_installation}
    else
      _ -> {:error, :invalid_widget_installation}
    end
  end

  def widget_script(_, _, _), do: {:error, :invalid_widget_installation}

  defp widget_path(path) when is_binary(path) and byte_size(path) <= 1_024 do
    if Regex.match?(~r/\A(?:\/[a-zA-Z0-9][a-zA-Z0-9_-]*)+\z/, path),
      do: {:ok, path},
      else: {:error, :invalid_widget_installation}
  end

  defp widget_path(_), do: {:error, :invalid_widget_installation}

  defp token_attribute(nil), do: {:ok, ""}

  defp token_attribute(path) when is_binary(path) and byte_size(path) <= 2_048 do
    with true <-
           String.valid?(path) and String.starts_with?(path, "/") and
             not String.starts_with?(path, "//") and
             not Regex.match?(~r/[\s\\\x00-\x1f\x7f]/u, path),
         {:ok, uri} <- URI.new(path),
         true <- is_nil(uri.scheme) and is_nil(uri.host) and is_nil(uri.fragment) do
      escaped = path |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
      {:ok, " data-token-url=\"#{escaped}\""}
    else
      _ -> {:error, :invalid_widget_installation}
    end
  end

  defp token_attribute(_), do: {:error, :invalid_widget_installation}

  defp origin(url) when is_binary(url) and byte_size(url) <= 2_048 do
    with true <- String.valid?(url),
         false <- Regex.match?(~r/[\s\\\x00-\x1f\x7f]/u, url),
         {:ok, uri} <- URI.new(url),
         true <- uri.scheme in ["http", "https"],
         true <- valid_host?(uri.host),
         true <- is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment),
         true <- uri.path in [nil, "", "/"],
         true <- is_integer(uri.port) and uri.port in 1..65_535 do
      {:ok, URI.to_string(%{uri | path: nil})}
    else
      _ -> {:error, :invalid_origin}
    end
  end

  defp origin(_), do: {:error, :invalid_origin}

  defp valid_host?(host) when is_binary(host),
    do: Regex.match?(~r/\A(?:[a-zA-Z0-9.-]+|[0-9a-fA-F]*:[0-9a-fA-F:.]+)\z/, host)

  defp valid_host?(_), do: false
end
