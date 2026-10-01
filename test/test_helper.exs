ExUnit.configure(exclude: [:integration, :load, :nats_live])
ExUnit.start()

# Set alternative metrics port for tests to avoid port conflicts
Application.put_env(:bot_army_library_runtime, :metrics_port, 19_090, persist: false)

# No test reaches a broker it does not have: job bells are collected instead of
# published. A test that wants to assert on one names itself as the sink.
Application.put_env(:bot_army_llm, :nats_publisher, BotArmyLlm.Test.JobBellPublisher)

# Start the application for tests
{:ok, _} = Application.ensure_all_started(:bot_army_llm)
