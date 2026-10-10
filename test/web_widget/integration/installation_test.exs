defmodule WebWidget.Integration.InstallationTest do
  use ExUnit.Case, async: true

  alias WebWidget.Integration.Installation

  test "demo fixtures share the host snippet renderer without relaxing host IDs" do
    assert Installation.widget_script("42", "https://widget.example") ==
             Installation.script(42, "https://widget.example")

    for id <- ["demo", "theme-dark", "locale_ar"] do
      assert {:ok, script} = Installation.widget_script(id, "https://widget.example")
      document = LazyHTML.from_fragment(script)

      assert document |> LazyHTML.query("script[defer]") |> LazyHTML.attribute("data-widget-id") ==
               [id]

      assert {:error, :invalid_widget_installation} =
               Installation.script(id, "https://widget.example")
    end

    for id <- [
          "",
          "../demo",
          "demo/path",
          "demo?x",
          "demo\" onload=\"x",
          String.duplicate("x", 201),
          <<255>>,
          nil
        ] do
      assert {:error, :invalid_widget_installation} =
               Installation.widget_script(id, "https://widget.example")
    end
  end

  test "one script tag selects a connector and uses the proxy origin or explicit endpoint" do
    assert {:ok, snippet} = Installation.script(42, "https://zaq.example/")
    document = LazyHTML.from_fragment(snippet)
    assert LazyHTML.query(document, "iframe") |> Enum.empty?()
    assert LazyHTML.query(document, "script") |> Enum.count() == 1

    assert document |> LazyHTML.query("script") |> LazyHTML.attribute("src") ==
             ["https://zaq.example/web_widget/assets/embed.js"]

    assert document |> LazyHTML.query("script") |> LazyHTML.attribute("data-widget-id") == ["42"]
    assert byte_size(snippet) <= 32_768

    assert {:ok, snippet} =
             Installation.script(7, "https://zaq.example",
               public_url: "http://localhost:4012/",
               identity_verifier: {SecretVerifier, :verify, ["secret-key"]}
             )

    assert snippet =~ "http://localhost:4012/web_widget/assets/embed.js"
    refute snippet =~ "secret-key"
    refute snippet =~ "zaq.example"
    assert {:ok, _} = Installation.script(1, "http://[::1]:4012")
  end

  test "invalid origins, attribute injection and IDs fail without emitting markup" do
    for origin <- [
          nil,
          "",
          "//example.com",
          "javascript:alert(1)",
          "file:///tmp/a",
          "https://user:password@example.com",
          "https://example.com/path",
          "https://example.com?key=secret",
          "https://example.com#fragment",
          "https://example.com:0",
          "https://example.com:65536",
          "https://*.example.com",
          "https://example.com\n",
          "https://example.com\\evil",
          "https://example.com\" onload=\"alert(1)",
          <<255>>,
          String.duplicate("x", 2049)
        ] do
      assert {:error, :invalid_widget_installation} = Installation.script(42, origin)

      assert {:error, :invalid_widget_installation} =
               Installation.script(42, "https://zaq.example", public_url: origin)
    end

    for id <- [0, -1, "42", nil, "42\" onload=\"x"] do
      assert {:error, :invalid_widget_installation} =
               Installation.script(id, "https://zaq.example")
    end

    assert {:error, :invalid_widget_installation} =
             Installation.script(42, "https://zaq.example", nil)
  end

  test "generated widget URL follows the public origin and custom mount prefix" do
    assert {:ok, snippet} =
             Installation.script(42, "https://zaq.example",
               public_url: "https://widget.example",
               widget_path: "/support/chat"
             )

    assert snippet =~ "data-widget-url=\"https://widget.example/support/chat/42\""

    for path <- [nil, "", "/", "//evil", "/widget/", "/../widget", "/widget?x", "/widget\"x"] do
      assert {:error, :invalid_widget_installation} =
               Installation.script(42, "https://zaq.example", widget_path: path)
    end
  end

  test "installation can name a parent same-origin token endpoint without exposing secrets" do
    assert {:ok, snippet} =
             Installation.script(42, "https://widget.example",
               token_url: "/api/widget-token?a=1&b=2"
             )

    assert snippet =~ "data-token-url=\"/api/widget-token?a=1&amp;b=2\""

    for path <- [
          "https://other.example/token",
          "//other.example/token",
          "/token#fragment",
          "/token\n",
          "/token\" onload=\"x"
        ] do
      assert {:error, :invalid_widget_installation} =
               Installation.script(42, "https://widget.example", token_url: path)
    end
  end
end
