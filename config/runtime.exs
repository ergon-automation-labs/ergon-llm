import Config

# This file is loaded at runtime (not at compile time).
# It reads environment variables and configures the application.

# Database configuration is now in config/config.exs
# This allows environment variables to be read at application startup, not at compile time

# NATS configuration for bot_army_runtime
# Parses NATS_HOST and NATS_PORT from environment variables (set by Salt)
nats_host = System.get_env("NATS_HOST") || "localhost"
nats_port = String.to_integer(System.get_env("NATS_PORT") || "4222")

config :bot_army_runtime, :nats,
  servers: [{nats_host, nats_port}],
  ping_interval: 30_000,
  max_reconnect_attempts: 10,
  reconnect_delay_ms: 1000
