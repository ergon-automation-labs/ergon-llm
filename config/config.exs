import Config

# Load .env file for local development/testing
if File.exists?(".env") do
  File.stream!(".env")
  |> Stream.map(&String.trim_trailing/1)
  |> Stream.reject(&String.starts_with?(&1, "#"))
  |> Stream.reject(&(&1 == ""))
  |> Enum.each(fn line ->
    case String.split(line, "=", parts: 2) do
      [key, value] -> System.put_env(key, value)
      _ -> nil
    end
  end)
end

# Ecto repositories for migrations
config :bot_army_llm, ecto_repos: [BotArmyLlm.Repo]

# Database configuration
# Priority: BOT_ARMY_LLM_DB_* (set by Salt/Jenkins) > DATABASE_* (from .env for local dev) > defaults
# Anthropic Messages API HTTP proxy (streaming + usage tracking). Enable with
# BOT_ARMY_LLM_HTTP_ENABLED=true — see BotArmyLlm.Http.Router moduledoc.
config :bot_army_llm, :http_proxy,
  enabled: System.get_env("BOT_ARMY_LLM_HTTP_ENABLED") in ~w(1 true yes),
  port: String.to_integer(System.get_env("BOT_ARMY_LLM_HTTP_PORT") || "39891"),
  ip: {0, 0, 0, 0},
  auth_token: System.get_env("BOT_ARMY_LLM_HTTP_TOKEN")

config :bot_army_llm, BotArmyLlm.Repo,
  database: System.get_env("BOT_ARMY_LLM_DB_NAME") || System.get_env("DATABASE_NAME", "ergon_llm_dev"),
  hostname: System.get_env("BOT_ARMY_LLM_DB_HOST") || System.get_env("DATABASE_HOST", "localhost"),
  port: String.to_integer(System.get_env("BOT_ARMY_LLM_DB_PORT") || System.get_env("DATABASE_PORT", "30003")),
  username: System.get_env("BOT_ARMY_LLM_DB_USER") || System.get_env("DATABASE_USER", "postgres"),
  password: System.get_env("BOT_ARMY_LLM_DB_PASSWORD") || System.get_env("DATABASE_PASSWORD", "postgres"),
  pool_size: 10

# Import environment-specific config
if File.exists?("config/#{Mix.env()}.exs") do
  import_config "#{Mix.env()}.exs"
end
