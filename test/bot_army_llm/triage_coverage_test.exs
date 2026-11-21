defmodule BotArmyLlm.TriageCoverageTest do
  @moduledoc """
  Every door that asks a model goes through the triage queue, with a lane and a sender.

  Before this, only `llm.request.chat` was admitted: `llm.prompt.submit` (eleven bots) ran outside
  any ranking, nobody sent `sender`, and almost nobody set a lane. A route (`llm:routes`) now
  carries `priority` and `sender` for a calling bot, and the prompt door is admitted like chat.
  """

  use ExUnit.Case, async: false
  @moduletag :nats

  alias BotArmyLlm.NATS.Consumer
  alias BotArmyLlm.{TriageAdmission, TriageQueue}

  @routes ~s({
    "discord": {"priority": "interactive", "sender": "user"},
    "rss_polling": {"priority": "background", "sender": "automated"},
    "badbot": {"priority": "whenever", "sender": "robot"},
    "synapse": {"priority": "background"}
  })

  setup do
    System.put_env("LLM_ROUTES", @routes)
    on_exit(fn -> System.delete_env("LLM_ROUTES") end)
    :ok
  end

  defmodule Client do
    @moduledoc false
    def complete(text, _opts),
      do: {:ok, %{completion: "re: " <> text, model_used: "m", provider: :local_ollama}}
  end

  describe "route_triage/2: what a calling bot's route says about its lane and sender" do
    test "fills priority and sender when the request set neither" do
      p = Consumer.route_triage(%{"_caller_bot" => "rss_polling"}, nil)
      assert p["priority"] == "background"
      assert p["sender"] == "automated"
    end

    test "a request's own priority and sender win over its route" do
      p =
        Consumer.route_triage(
          %{"_caller_bot" => "rss_polling", "priority" => "urgent", "sender" => "user"},
          nil
        )

      assert p["priority"] == "urgent"
      assert p["sender"] == "user"
    end

    test "a lane named by the subject is not overridden by a route" do
      p = Consumer.route_triage(%{"_caller_bot" => "synapse"}, "pi-go.llm.request.chat.urgent")
      refute Map.has_key?(p, "priority")
    end

    test "a value that is not a lane or a sender is ignored, not carried" do
      p = Consumer.route_triage(%{"_caller_bot" => "badbot"}, nil)
      refute Map.has_key?(p, "priority")
      refute Map.has_key?(p, "sender")
    end

    test "a caller with no route, or none stamped, is left alone" do
      assert Consumer.route_triage(%{"_caller_bot" => "nobody"}, nil) == %{
               "_caller_bot" => "nobody"
             }

      assert Consumer.route_triage(%{"text" => "hi"}, nil) == %{"text" => "hi"}
    end

    test "prompt_payload carries the route through, from the stamped sender" do
      Process.put(:llm_sender, %{bot: "discord", node: "air"})
      on_exit(fn -> Process.delete(:llm_sender) end)

      p = Consumer.prompt_payload(%{"text" => "hi"})
      assert p["priority"] == "interactive"
      assert p["sender"] == "user"
    end

    test "a chat payload does too, and keeps the subject's own lane" do
      Process.put(:llm_sender, %{bot: "synapse", node: "air"})
      on_exit(fn -> Process.delete(:llm_sender) end)

      assert Consumer.stamped_chat_payload(
               %{"prompt_context" => %{"prompt" => "x"}},
               "llm.request.chat"
             )[
               "priority"
             ] == "background"

      refute Map.has_key?(
               Consumer.stamped_chat_payload(
                 %{"prompt_context" => %{}},
                 "pi-go.llm.request.chat.urgent"
               ),
               "priority"
             )
    end
  end

  describe "chat_admission_opts/1: which sync requests may be dropped when they wait too long" do
    test "a plain sync request gets an expiry" do
      assert Consumer.chat_admission_opts(%{})[:expire_after_ms] ==
               TriageAdmission.default_expire_ms()
    end

    test "its caller's shorter deadline is honored" do
      assert Consumer.chat_admission_opts(%{"deadline_ms" => 5_000})[:expire_after_ms] == 5_000
    end

    test "a caller that accepts a queued reply is promised a job, so it is never expired" do
      refute Keyword.has_key?(
               Consumer.chat_admission_opts(%{"accepts_queued" => true}),
               :expire_after_ms
             )
    end
  end

  describe "the prompt door, with triage on" do
    defp queue(slots) do
      name = :"cov_q_#{System.unique_integer([:positive])}"
      {:ok, _} = TriageQueue.start_link(name: name, slots: slots, tick_ms: 0)
      name
    end

    test "waits in the queue in the lane its route names, and is answered when it runs" do
      server = queue(0)
      me = self()
      Process.put(:llm_sender, %{bot: "rss_polling", node: "air"})
      on_exit(fn -> Process.delete(:llm_sender) end)

      Consumer.run_prompt_door(
        %{"text" => "score this"},
        false,
        Client,
        &send(me, {:published, &1}),
        triage?: true,
        server: server
      )

      status = TriageQueue.status(server)
      assert status.depth == 1
      assert status.by_lane["background"] == 1
      refute_receive {:published, _}, 50
    end

    test "a free slot runs it and the reply is the same completion the door always gave" do
      server = queue(2)
      me = self()

      Consumer.run_prompt_door(%{"text" => "hello"}, false, Client, &send(me, {:published, &1}),
        triage?: true,
        server: server
      )

      TriageQueue.tick(server)
      assert_receive {:published, %{"completion" => "re: hello", "model" => "m"}}, 2_000
    end

    test "a prompt still queued past its expiry is dropped with an error, and never asked of the model" do
      {:ok, clock} = Agent.start_link(fn -> 1_700_000_000 end)
      name = :"cov_exp_#{System.unique_integer([:positive])}"

      {:ok, _} =
        TriageQueue.start_link(
          name: name,
          slots: 0,
          tick_ms: 0,
          clock: fn _ -> Agent.get(clock, & &1) end
        )

      me = self()

      defmodule NeverClient do
        @moduledoc false
        def complete(_text, _opts), do: raise("the model was asked for a prompt nobody waits for")
      end

      Consumer.run_prompt_door(
        %{"text" => "hi", "deadline_ms" => 10_000},
        false,
        NeverClient,
        &send(me, {:published, &1}),
        triage?: true,
        server: name
      )

      Agent.update(clock, &(&1 + 11))
      TriageQueue.tick(name)
      assert_receive {:published, %{"ok" => false, "error" => "expired_in_queue"}}, 2_000
    end
  end

  describe "the prompt door, with triage off" do
    test "answers as it always did, without a queue" do
      me = self()

      Consumer.run_prompt_door(%{"text" => "plain"}, false, Client, &send(me, {:published, &1}),
        triage?: false
      )

      assert_receive {:published, %{"completion" => "re: plain"}}, 2_000
    end
  end
end
