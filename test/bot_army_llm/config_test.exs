defmodule BotArmyLlm.ConfigTest do
  # NOT async: this file mutates the global :config_data app env, which
  # BotArmyLibraryRuntime.ConfigLoader reads. async: true would race every other
  # test that resolves a setting.
  use ExUnit.Case, async: false
  @moduletag :core

  alias BotArmyLlm.Config

  setup do
    prev = Application.get_env(:bot_army_library_runtime, :config_data)
    on_exit(fn -> restore(prev) end)
    :ok
  end

  defp restore(nil), do: Application.delete_env(:bot_army_library_runtime, :config_data)
  defp restore(prev), do: Application.put_env(:bot_army_library_runtime, :config_data, prev)

  defp with_config(data), do: Application.put_env(:bot_army_library_runtime, :config_data, data)

  # The bug this module exists to prevent: under launchd the environment is empty
  # and the settings live in the rendered config file. A call site that reads
  # System.get_env/1 directly sees nil there and reports "not configured" while
  # the value sits correctly on disk.
  test "the config file wins over the environment" do
    with_config(%{"BLACKBOX_API_KEY" => "from-config-file"})
    System.put_env("BLACKBOX_API_KEY", "from-environment")

    on_exit(fn -> System.delete_env("BLACKBOX_API_KEY") end)

    assert Config.get("BLACKBOX_API_KEY") == "from-config-file"
  end

  test "falls back to the environment when the config file has no entry" do
    with_config(%{})
    System.put_env("SOME_LLM_TEST_KEY", "from-environment")

    on_exit(fn -> System.delete_env("SOME_LLM_TEST_KEY") end)

    assert Config.get("SOME_LLM_TEST_KEY") == "from-environment"
  end

  test "returns the default when the key is nowhere" do
    with_config(%{})

    assert Config.get("__definitely_unset__") == nil
    assert Config.get("__definitely_unset__", "fallback") == "fallback"
  end

  # The salt template writes "" for a pillar entry nobody set. Blank is truthy in
  # Elixir, so reading it raw would defeat the caller's default and turn
  # "unconfigured" into a bewildering 401 from the provider.
  test "a blank rendered value means unset, not empty string" do
    with_config(%{"OLLAMA_URLS" => ""})

    assert Config.get("OLLAMA_URLS") == nil
    assert Config.get("OLLAMA_URLS", "http://127.0.0.1:11434") == "http://127.0.0.1:11434"
  end

  test "whitespace-only is also unset" do
    with_config(%{"ANTHROPIC_API_KEY" => "   \n"})

    assert Config.get("ANTHROPIC_API_KEY", "fallback") == "fallback"
  end

  test "a real value survives verbatim (no coercion, no trimming)" do
    with_config(%{"BOT_ARMY_LLM_EMBED_MAX_CONCURRENCY" => "0"})

    assert Config.get("BOT_ARMY_LLM_EMBED_MAX_CONCURRENCY") == "0"
  end
end
