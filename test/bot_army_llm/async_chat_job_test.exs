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
  alias BotArmyLlm.JobStore
  alias BotArmyLlm.NATS.Consumer

  @accepted_keys ~w(request_id response_type lane job_id status poll_subject)

  setup do
    if Process.whereis(JobStore) == nil, do: start_supervised!(JobStore)
    :ok
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
