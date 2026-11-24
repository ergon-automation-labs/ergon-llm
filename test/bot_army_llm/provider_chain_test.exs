defmodule BotArmyLlm.ProviderChainTest do
  use ExUnit.Case, async: false
  @moduletag :core

  alias BotArmyLlm.LlmClient

  # The chain comes from the BOT_ARMY_LLM_PROVIDER_CHAIN variable (the pillar sets it). The
  # application env key is a list when it is set at all, so the variable is what these tests drive.
  setup do
    previous_env = System.get_env("BOT_ARMY_LLM_PROVIDER_CHAIN")
    previous_app = Application.get_env(:bot_army_llm, :provider_chain)
    Application.delete_env(:bot_army_llm, :provider_chain)

    on_exit(fn ->
      if previous_env,
        do: System.put_env("BOT_ARMY_LLM_PROVIDER_CHAIN", previous_env),
        else: System.delete_env("BOT_ARMY_LLM_PROVIDER_CHAIN")

      if previous_app, do: Application.put_env(:bot_army_llm, :provider_chain, previous_app)
    end)

    :ok
  end

  test "local_ollama in the chain is the local Ollama provider, and a repeat is listed once" do
    System.put_env("BOT_ARMY_LLM_PROVIDER_CHAIN", "ollama,local_ollama")
    assert LlmClient.resolved_provider_chain() == [:ollama]
  end

  test "the chain keeps its order and still refuses a name it does not know" do
    System.put_env("BOT_ARMY_LLM_PROVIDER_CHAIN", "openrouter,local_ollama,anthropic")
    assert LlmClient.resolved_provider_chain() == [:openrouter, :ollama, :anthropic]

    System.put_env("BOT_ARMY_LLM_PROVIDER_CHAIN", "ollama,nonsense")

    assert_raise ArgumentError, ~r/Unknown provider: nonsense/, fn ->
      LlmClient.resolved_provider_chain()
    end
  end
end
