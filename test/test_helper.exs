ExUnit.configure(exclude: [:integration, :load, :nats_live])
ExUnit.start()

# Set alternative metrics port for tests to avoid port conflicts
Application.put_env(:bot_army_library_runtime, :metrics_port, 19_090, persist: false)

# Start the application for tests
{:ok, _} = Application.ensure_all_started(:bot_army_llm)
