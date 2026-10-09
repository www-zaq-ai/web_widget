defmodule WebWidget.MixProject do
  use Mix.Project

  def project do
    [
      app: :web_widget,
      version: "0.2.0",
      elixir: "~> 1.16",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader],
      test_coverage: [tool: ExCoveralls]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {WebWidget.Application, []},
      extra_applications: [:logger, :runtime_tools, :mnesia]
    ]
  end

  def cli do
    [
      preferred_envs: [
        precommit: :test,
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.html": :test,
        "coveralls.json": :test,
        "coveralls.post": :test,
        "coveralls.github": :test
      ]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:dev), do: ["lib", "test/support/demo"]
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:credo, "~> 1.7.13", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18.5", only: :test},
      {:phoenix, "~> 1.8.3"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.1"},
      {:live_react, "~> 2.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:req, "~> 0.5"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:jose, "~> 1.11.12"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.setup": ["cmd --cd assets npm ci"],
      "assets.build": ["compile", "cmd --cd assets npm run build"],
      "assets.deploy": [
        "assets.build",
        "phx.digest"
      ],
      coverup: fn args ->
        # call mix coverup [threshold|95] [limit|20]
        {threshold, limit} =
          case args do
            [threshold, limit] -> {threshold, limit}
            [threshold] -> {threshold, "20"}
            [] -> {"95", "20"}
            _ -> Mix.raise("Usage: mix coverup [threshold 0..100] [positive limit]")
          end

        unless Regex.match?(~r/^\d+(\.\d+)?$/, threshold) and
                 String.to_float(
                   if String.contains?(threshold, "."), do: threshold, else: threshold <> ".0"
                 ) <= 100 and
                 Regex.match?(~r/^[1-9]\d*$/, limit) do
          Mix.raise("Usage: mix coverup [threshold 0..100] [positive limit]")
        end

        unless File.regular?("cover/excoveralls.json") do
          Mix.raise("Missing coverage report. Run mix coveralls.json first.")
        end

        command = """
        {
        git --no-pager diff --name-only --diff-filter=AMR main...HEAD
        git --no-pager diff --name-only --diff-filter=AMR
        git --no-pager diff --cached --name-only --diff-filter=AMR
        } |
        grep '^lib/.*\\.ex$' |
        sort -u |
        while read -r file; do
          jq -r \
            --arg file "$file" \
            --argjson threshold "#{threshold}" '
              .source_files[]
              | select(.name == $file)
              | {
                  file: .name,
                  covered: ([.coverage[] | select(. != null and . > 0)] | length),
                  relevant: ([.coverage[] | select(. != null)] | length),
                  missed: [.coverage | to_entries[] | select(.value == 0) | .key + 1]
                }
              | select(.relevant > 0)
              | .percent = ((.covered * 100 / .relevant))
              | select(.percent < $threshold)
              | "\\(.percent) \\(.file) — \\(.percent | floor)% — missed line numbers: \\(.missed | join(", "))"
            ' cover/excoveralls.json
        done |
        sort -n |
        head -n #{limit} |
        cut -d' ' -f2-
        """

        Mix.shell().cmd(command)
      end,
      q: ["quality"],
      quality: [
        "format",
        "credo --strict",
        "compile --warnings-as-errors"
      ],
      precommit: [
        "format --check-formatted",
        "credo --strict",
        "compile --warnings-as-errors",
        "test"
      ]
    ]
  end
end
