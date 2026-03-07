ExUnit.start()

# Start the application for tests
{:ok, _} = Application.ensure_all_started(:bot_army_llm)
