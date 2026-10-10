import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :web_widget, WebWidget.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "web_widget_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :web_widget, WebWidgetWeb.Endpoint,
  web_widget_session: [partitioned: false],
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "hItqrDpSbn8YcVdlF3NUYNNEzMovPEE/ziM0eSAIxf4ZDDX8SSCztM/ifXQ9iq5H",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

config :web_widget, :demo_allowed_domains, ["http://www.example.com"]

config :web_widget, :mock_host, true
