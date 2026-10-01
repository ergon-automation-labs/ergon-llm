defmodule BotArmyLlm.AsyncChatJobTest do
  use ExUnit.Case
  @moduletag :nats

  # A slow local model is a *property* of the local model: an uncensored 27B can
  # take a minute or more per reply. Blocking a NATS request/reply for that long
  # makes every caller invent a wall-clock deadline for unknowable work — and a
  # deadline that is too small loses the answer *silently*, which reads like a
  # model failure rather than a plumbing one.
  #
  # So a caller may background the request and poll instead. These tests pin the
  # job lifecycle (accepted -> pending -> completed | failed) and the reply shapes
  # the poller depends on.
  alias BotArmyLlm.JobBell
  alias BotArmyLlm.JobStore
  alias BotArmyLlm.NATS.Consumer
  alias BotArmyLlm.Test.JobBellPublisher

  defmodule ExplodingPublisher do
    @moduledoc false
    # A bell is a courtesy: a bus that is gone must not turn a finished job into
    # a crashed one.
    def publish(_event), do: raise("the bus is gone")
  end

  # Health checkers for the local-load announcement: the three answers the code
  # must tell apart — loaded, idle, and unable to say.
  defmodule LoadedChecker do
    @moduledoc false
    def load_acceptable?, do: false
  end

  defmodule IdleChecker do
    @moduledoc false
    def load_acceptable?, do: true
  end

  defmodule BrokenChecker do
    @moduledoc false
    def load_acceptable?, do: raise("no health checker")
  end

  @accepted_keys ~w(request_id response_type lane job_id status poll_subject)

  setup do
    if Process.whereis(JobStore) == nil, do: start_supervised!(JobStore)
    :ok
  end

  # Submits one job through the async path with the given health checker and
  # returns whatever it logged. The runner is a stub: this is about the
  # announcement, not about a provider.
  defp submit(model_type, checker) do
    Application.put_env(:bot_army_llm, :ollama_health_checker, checker)

    ExUnit.CaptureLog.capture_log(fn ->
      Consumer.submit_chat_job(%{"model_type" => model_type}, "llm.request.chat", fn _p, _s ->
        %{"content" => "BANANA"}
      end)
    end)
  end

  describe "JobStore" do
    test "a created job reads back as pending" do
      job_id = JobStore.create(UUID.uuid4(), %{subject: "llm.request.chat"})

      assert {:ok, job} = JobStore.get(job_id)
      assert job.status == :pending
      assert job.result == nil
      assert job.error == nil
      assert job.meta.subject == "llm.request.chat"
    end

    test "completion carries the result" do
      job_id = JobStore.create(UUID.uuid4())
      assert :ok = JobStore.complete(job_id, %{"content" => "BANANA"})

      assert {:ok, %{status: :completed, result: %{"content" => "BANANA"}}} = JobStore.get(job_id)
    end

    test "failure carries a readable reason" do
      job_id = JobStore.create(UUID.uuid4())
      assert :ok = JobStore.fail(job_id, :timeout)

      assert {:ok, %{status: :failed, error: ":timeout"}} = JobStore.get(job_id)
    end

    test "an unknown job is not_found, never a lie about completion" do
      assert {:error, :not_found} = JobStore.get(UUID.uuid4())
      assert {:error, :not_found} = JobStore.get(nil)
    end

    test "sweep drops only jobs older than the ttl" do
      fresh = JobStore.create(UUID.uuid4())
      stale = JobStore.create(UUID.uuid4())
      # Age the stale job past a zero-length ttl while leaving the fresh one alone.
      :ets.insert(:llm_job_store, {stale, %{elem(JobStore.get(stale), 1) | inserted_at: 0}})

      assert JobStore.sweep(1) >= 1
      assert {:error, :not_found} = JobStore.get(stale)
      assert {:ok, _} = JobStore.get(fresh)
    end

    test "counts reports by status" do
      before = JobStore.counts()
      pending = JobStore.create(UUID.uuid4())
      done = JobStore.create(UUID.uuid4())
      JobStore.complete(done, %{})

      after_counts = JobStore.counts()
      assert after_counts.pending == before.pending + 1
      assert after_counts.completed == before.completed + 1
      assert is_binary(pending)
    end
  end

  describe "async_requested?/1" do
    test "true and the stringly-typed \"true\" both count" do
      assert Consumer.async_requested?(%{"async" => true})
      assert Consumer.async_requested?(%{"async" => "true"})
    end

    test "anything else does not — a request is synchronous unless it says so" do
      refute Consumer.async_requested?(%{})
      refute Consumer.async_requested?(%{"async" => false})
      refute Consumer.async_requested?(%{"async" => "yes"})
      refute Consumer.async_requested?(%{"async" => 1})
      refute Consumer.async_requested?(nil)
      refute Consumer.async_requested?("junk")
    end
  end

  describe "submit_chat_job/3" do
    test "accepts immediately and lands the runner's result in the job" do
      runner = fn _payload, _subject -> %{"content" => "BANANA", "latency_ms" => 42} end

      accepted =
        Consumer.submit_chat_job(
          %{"prompt_context" => %{"prompt" => "hi"}},
          "llm.request.chat",
          runner
        )

      assert Enum.sort(Map.keys(accepted)) == Enum.sort(@accepted_keys)
      assert accepted["status"] == "accepted"
      assert accepted["poll_subject"] == "llm.job.status"
      assert accepted["lane"] == "interactive"
      assert {:ok, job_id} = Map.fetch(accepted, "job_id")

      assert %{"status" => "completed", "result" => %{"content" => "BANANA"}} =
               wait_for_status(job_id, "completed")
    end

    test "carries the caller's lane and request_id into the job" do
      runner = fn _payload, _subject -> %{"content" => "ok"} end

      accepted =
        Consumer.submit_chat_job(
          %{"request_id" => "req-1", "priority" => "urgent"},
          "llm.request.chat",
          runner
        )

      assert accepted["request_id"] == "req-1"
      assert accepted["lane"] == "urgent"
    end

    test "a raising runner becomes a failed job with a readable reason" do
      runner = fn _payload, _subject -> raise "provider exploded" end

      accepted = Consumer.submit_chat_job(%{}, "llm.request.chat", runner)
      %{"job_id" => job_id} = accepted

      assert %{"status" => "failed", "error" => error} = wait_for_status(job_id, "failed")
      assert error =~ "provider exploded"
    end

    test "a throwing runner also becomes a failed job, not a hung one" do
      runner = fn _payload, _subject -> throw(:provider_gave_up) end

      %{"job_id" => job_id} = Consumer.submit_chat_job(%{}, "llm.request.chat", runner)

      assert %{"status" => "failed", "error" => error} = wait_for_status(job_id, "failed")
      assert error =~ "provider_gave_up"
    end
  end

  describe "a local-only job submitted while local nodes are loaded" do
    # An uncensored job cannot be rerouted to a cloud provider, so under load it
    # waits — and a job that waits with nothing in the log reads as a hung job.
    # Measured 2026-10-01: a three-word uncensored job sat `pending` for over ten
    # minutes while cloud-routed work finished in three seconds.
    setup do
      previous = Application.get_env(:bot_army_llm, :ollama_health_checker)

      on_exit(fn ->
        if previous do
          Application.put_env(:bot_army_llm, :ollama_health_checker, previous)
        else
          Application.delete_env(:bot_army_llm, :ollama_health_checker)
        end
      end)

      :ok
    end

    test "says out loud that it is waiting, not failing" do
      assert submit("uncensored", __MODULE__.LoadedChecker) =~
               "waits for a local node rather than being rerouted to a cloud provider"
    end

    test "a tier that may use the cloud is not waiting for anything" do
      refute submit("light", __MODULE__.LoadedChecker) =~ "waits for a local node"
    end

    test "an idle local node is not a wait" do
      refute submit("uncensored", __MODULE__.IdleChecker) =~ "waits for a local node"
    end

    test "a type nobody asked for is not a local-only type" do
      refute submit(nil, __MODULE__.LoadedChecker) =~ "waits for a local node"
      refute submit("nonsense", __MODULE__.LoadedChecker) =~ "waits for a local node"
    end

    test "a health checker that cannot answer is not a reason to warn" do
      refute submit("uncensored", __MODULE__.BrokenChecker) =~ "waits for a local node"
    end
  end

  describe "job_status_response/1" do
    test "reports pending, then the completed result" do
      job_id = JobStore.create(UUID.uuid4())

      assert %{"ok" => true, "status" => "pending", "result" => nil} =
               Consumer.job_status_response(%{"job_id" => job_id})

      JobStore.complete(job_id, %{"content" => "BANANA"})

      assert %{"ok" => true, "status" => "completed", "result" => %{"content" => "BANANA"}} =
               Consumer.job_status_response(%{"job_id" => job_id})
    end

    test "reads a job_id nested in a decoded envelope" do
      job_id = JobStore.create(UUID.uuid4())

      assert %{"ok" => true, "status" => "pending"} =
               Consumer.job_status_response(%{
                 "event" => "llm.job.status",
                 "payload" => %{"job_id" => job_id}
               })
    end

    test "a missing job_id and an unknown job_id are distinguishable" do
      assert %{"ok" => false, "error" => "missing_job_id"} = Consumer.job_status_response(%{})
      assert %{"ok" => false, "error" => "missing_job_id"} = Consumer.job_status_response("junk")

      assert %{"ok" => false, "error" => "job_not_found"} =
               Consumer.job_status_response(%{"job_id" => UUID.uuid4()})
    end

    test "the timestamp is ISO8601, so a poller can reason about staleness" do
      job_id = JobStore.create(UUID.uuid4())
      %{"timestamp" => timestamp} = Consumer.job_status_response(%{"job_id" => job_id})

      assert {:ok, %DateTime{}, _offset} = DateTime.from_iso8601(timestamp)
    end
  end

  describe "the job bell" do
    # A caller that backgrounded a job should not have to ask for an hour to find
    # out it is done. This is the other half of the async contract: the job rings
    # when it reaches a terminal state, and the words are *not* in the ring.

    setup do
      original = Application.get_env(:bot_army_llm, :job_bell_sink)
      Application.put_env(:bot_army_llm, :job_bell_sink, self())

      on_exit(fn ->
        if original do
          Application.put_env(:bot_army_llm, :job_bell_sink, original)
        else
          Application.delete_env(:bot_army_llm, :job_bell_sink)
        end
      end)

      :ok
    end

    test "a finished job is rung, and carries no words" do
      accepted =
        Consumer.submit_chat_job(%{"async" => true}, "llm.request.chat", fn _payload, _subject ->
          %{"content" => "her private answer", "model_used" => "test"}
        end)

      # The job runs in its own process: the bell arrives, it is not already here.
      assert_receive {:bell_published, event}, 1_000
      assert event["event"] == "llm.job.completed"
      assert event["payload"] == %{"job_id" => accepted["job_id"], "status" => "completed"}

      body = Jason.encode!(event)
      refute body =~ "her private answer"
      refute body =~ "model_used"
    end

    test "a job that raised is rung as failed, without the provider's message" do
      accepted =
        Consumer.submit_chat_job(%{"async" => true}, "llm.request.chat", fn _payload, _subject ->
          raise "the provider said: her private answer"
        end)

      assert_receive {:bell_published, event}, 1_000
      assert event["payload"] == %{"job_id" => accepted["job_id"], "status" => "failed"}
      refute Jason.encode!(event) =~ "her private answer"
    end

    test "the bell rings only once the result is readable" do
      # A woken caller reads JobStore. If the bell could arrive first it would read
      # `pending`, go back to sleep, and wait for a second bell that never comes.
      accepted =
        Consumer.submit_chat_job(%{"async" => true}, "llm.request.chat", fn _payload, _subject ->
          %{"content" => "done"}
        end)

      assert_receive {:bell_published, _event}, 1_000

      assert {:ok, %{status: :completed}} = JobStore.get(accepted["job_id"])
    end

    test "the bell is published on a subject a subscriber can name" do
      assert BotArmyLlm.NATS.Publisher.subject_for(JobBell.event()) ==
               "events.llm.job.completed"
    end

    test "an unknown status is refused rather than rung" do
      assert {:error, {:unknown_status, "pending"}} = JobBell.ring(UUID.uuid4(), "pending")
      refute_received {:bell_published, _event}
    end

    test "a bell that cannot be rung reports the failure instead of raising" do
      Application.put_env(
        :bot_army_llm,
        :nats_publisher,
        __MODULE__.ExplodingPublisher
      )

      on_exit(fn -> Application.put_env(:bot_army_llm, :nats_publisher, JobBellPublisher) end)

      assert {:error, :bell_failed} = JobBell.ring(UUID.uuid4(), "completed")
    end
  end

  describe "the consumer's subscriptions match what it advertises" do
    # This drifted once: `llm.job.status` was advertised to the registry but never
    # subscribed, so a caller could poll a backgrounded job forever and get no
    # answer from a bot that looked, from the registry, like it was listening.
    test "every advertised subject is subscribed (wildcards excepted)" do
      advertised = Consumer.advertised_subjects()
      subscribed = Consumer.subscription_subjects()

      missing =
        advertised
        |> Enum.reject(&(String.contains?(&1, ">") or String.contains?(&1, "*")))
        |> Enum.reject(&(&1 in subscribed))

      assert missing == [], "advertised but not subscribed: #{inspect(missing)}"
    end

    test "the job poll subject is subscribed, not only advertised" do
      assert "llm.job.status" in Consumer.advertised_subjects()
      assert "llm.job.status" in Consumer.subscription_subjects()
    end
  end

  defp wait_for_status(job_id, wanted, attempts \\ 100) do
    response = Consumer.job_status_response(%{"job_id" => job_id})

    cond do
      response["status"] == wanted ->
        response

      attempts <= 1 ->
        flunk("job never reached #{wanted}: #{inspect(response)}")

      true ->
        Process.sleep(10)
        wait_for_status(job_id, wanted, attempts - 1)
    end
  end
end
