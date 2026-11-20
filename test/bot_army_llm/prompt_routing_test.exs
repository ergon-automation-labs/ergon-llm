defmodule BotArmyLlm.PromptRoutingTest do
  use ExUnit.Case, async: false
  @moduletag :nats

  alias BotArmyLlm.NATS.Consumer

  @routes ~s({"rpg": {"provider": "local_ollama"}, "pinned": {"provider": "openrouter", "model": "m-route"}})

  setup do
    System.put_env("LLM_ROUTES", @routes)
    on_exit(fn -> System.delete_env("LLM_ROUTES") end)
    :ok
  end

  describe "prompt_payload/2: who sent the prompt, stamped before the work leaves the request's process" do
    test "a stamped sender is the caller bot a route is looked up by, over anything the body claims" do
      Process.put(:llm_sender, %{bot: "rpg", node: "mini"})
      on_exit(fn -> Process.delete(:llm_sender) end)

      payload = Consumer.prompt_payload(%{"text" => "hi", "_caller_bot" => "forged"})

      assert payload["_caller_bot"] == "rpg"
      assert payload["_caller"] == "rpg@mini"
      assert Consumer.prompt_routing_opts(payload)[:providers] == [:local_ollama]
    end

    test "an unstamped bare prompt has no caller bot, and so no route" do
      Process.delete(:llm_sender)
      payload = Consumer.prompt_payload(%{"text" => "hi"})

      refute Map.has_key?(payload, "_caller_bot")
      assert payload["_caller"] == "bare:llm.prompt.submit"
      assert Consumer.prompt_routing_opts(payload)[:providers] == nil
    end

    test "an enveloped prompt is read from its payload and attributed to its envelope's source" do
      Process.delete(:llm_sender)

      envelope = %{
        "event_id" => "e1",
        "source" => "rpg",
        "source_node" => "rpg@mini",
        "payload" => %{"text" => "hi", "source" => "local_ollama"}
      }

      payload = Consumer.prompt_payload(envelope)
      assert payload["text"] == "hi"
      assert payload["_caller_bot"] == "rpg"
      assert Consumer.prompt_routing_opts(payload)[:source] == :local_ollama
    end
  end

  defmodule Client do
    @moduledoc false
    def complete(text, opts) do
      send(Application.get_env(:bot_army_llm, :prompt_test_pid, self()), {:completed, text, opts})
      {:ok, %{completion: "A scene.", model_used: "m", provider: :local_ollama}}
    end
  end

  describe "the door itself: what llm.prompt.submit asks the client for" do
    test "a prompt that names the local source reaches the client on it, and is answered" do
      payload =
        Consumer.prompt_payload(%{"text" => "set a scene", "source" => "local_ollama"})

      reply = Consumer.prompt_response(payload, payload, false, Client)

      assert_received {:completed, "set a scene", opts}
      assert opts[:source] == :local_ollama
      assert opts[:model] == "auto"
      assert reply["completion"] == "A scene."
      assert reply["model"] == "m"
    end

    test "a caller with a route reaches the client on its route, through the real stamp" do
      Process.put(:llm_sender, %{bot: "rpg", node: "mini"})
      on_exit(fn -> Process.delete(:llm_sender) end)

      payload = Consumer.prompt_payload(%{"text" => "set a scene"})
      Consumer.prompt_response(payload, payload, false, Client)

      assert_received {:completed, _, opts}
      assert opts[:providers] == [:local_ollama]
      assert opts[:caller] == "rpg@mini"
    end

    test "a prompt that names nothing is asked for exactly as before" do
      payload = Consumer.prompt_payload(%{"text" => "hi", "model" => "ministral-3:8b"})
      Consumer.prompt_response(payload, payload, true, Client)

      assert_received {:completed, "hi", opts}
      refute Keyword.has_key?(opts, :source)
      refute Keyword.has_key?(opts, :providers)
      assert opts[:model] == "ministral-3:8b"
      assert opts[:allow_cloud_when_sensitive] == true
    end

    test "an empty prompt is refused without asking the client" do
      payload = Consumer.prompt_payload(%{"text" => ""})
      reply = Consumer.prompt_response(payload, payload, false, Client)
      assert reply["error"] == ":empty_prompt"
      refute_received {:completed, _, _}
    end
  end

  describe "the door as the consumer runs it: stamped in the request's process, answered in another" do
    setup do
      Application.put_env(:bot_army_llm, :prompt_test_pid, self())
      on_exit(fn -> Application.delete_env(:bot_army_llm, :prompt_test_pid) end)
    end

    test "a route matches the stamped sender even though the work runs in a spawned process" do
      Process.put(:llm_sender, %{bot: "rpg", node: "mini"})
      on_exit(fn -> Process.delete(:llm_sender) end)
      me = self()

      Consumer.run_prompt_door(%{"text" => "set a scene"}, false, Client, fn reply ->
        send(me, {:published, reply})
      end)

      assert_receive {:completed, "set a scene", opts}, 2_000
      assert opts[:providers] == [:local_ollama]
      assert opts[:caller] == "rpg@mini"
      assert_receive {:published, %{"completion" => "A scene."}}, 2_000
    end
  end

  describe "prompt_routing_opts/1: llm.prompt.submit takes the same routing the chat door does" do
    test "a prompt that names nothing is routed as it always was" do
      assert Consumer.prompt_routing_opts(%{"text" => "hi"}) == []
    end

    test "source: local_ollama pins the local provider" do
      opts = Consumer.prompt_routing_opts(%{"text" => "hi", "source" => "local_ollama"})
      assert opts[:source] == :local_ollama
    end

    test "a named provider, or an ordered list, is the chain" do
      assert Consumer.prompt_routing_opts(%{"provider" => "local_ollama"})[:providers] ==
               [:local_ollama]

      assert Consumer.prompt_routing_opts(%{"provider" => ["ollama", "openrouter"]})[:providers] ==
               [:ollama, :openrouter]
    end

    test "an unknown provider is a refusal, not the default chain" do
      assert Consumer.prompt_routing_opts(%{"provider" => "nope"})[:providers] ==
               {:invalid, "nope"}
    end

    test "the calling bot's route fills in what the prompt did not say" do
      opts = Consumer.prompt_routing_opts(%{"text" => "hi", "_caller_bot" => "rpg"})
      assert opts[:providers] == [:local_ollama]
    end

    test "a prompt's own source or provider wins over its route" do
      opts =
        Consumer.prompt_routing_opts(%{
          "_caller_bot" => "rpg",
          "provider" => "anthropic"
        })

      assert opts[:providers] == [:anthropic]
    end

    test "a route's model fills in only when the prompt names no model" do
      assert Consumer.prompt_routing_opts(%{"_caller_bot" => "pinned"})[:model] == "m-route"

      refute Keyword.has_key?(
               Consumer.prompt_routing_opts(%{"_caller_bot" => "pinned", "model" => "mine"}),
               :model
             )
    end

    test "the caller label rides along for the log lines" do
      assert Consumer.prompt_routing_opts(%{"_caller" => "rpg@rpg_bot"})[:caller] == "rpg@rpg_bot"
    end
  end
end
