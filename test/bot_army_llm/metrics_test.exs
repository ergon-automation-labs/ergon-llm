defmodule BotArmyLlm.MetricsTest do
  use ExUnit.Case, async: false
  @moduletag :core

  alias BotArmyLlm.Metrics

  setup do
    # Reset metrics before each test
    Metrics.reset()
    # Allow reset to complete
    Process.sleep(50)
    :ok
  end

  describe "record_request/1" do
    test "increments request counter" do
      Metrics.record_request("llm.prompt.submit")
      # Allow async operation to complete
      Process.sleep(100)

      summary = Metrics.get_summary()

      assert summary.requests["llm.prompt.submit"] == 1
    end

    test "records multiple requests" do
      Metrics.record_request("llm.prompt.submit")
      Metrics.record_request("llm.prompt.submit")
      Metrics.record_request("llm.inference.chain")
      Process.sleep(100)

      summary = Metrics.get_summary()

      assert summary.requests["llm.prompt.submit"] == 2
      assert summary.requests["llm.inference.chain"] == 1
    end
  end

  describe "record_provider_call/2" do
    test "records provider call with latency" do
      Metrics.record_provider_call("anthropic", 150)
      Process.sleep(100)

      summary = Metrics.get_summary()

      assert summary.provider_calls["anthropic"] == 1
      assert is_map(summary.latency_percentiles)
    end

    test "computes latency percentiles" do
      # Record multiple latencies
      Enum.each(1..100, fn i ->
        Metrics.record_provider_call("anthropic", i * 10)
      end)

      Process.sleep(100)

      summary = Metrics.get_summary()

      latencies = summary.latency_percentiles["anthropic"]
      assert latencies.p50 > 0
      assert latencies.p95 > latencies.p50
      assert latencies.p99 > latencies.p95
      assert latencies.min > 0
      assert latencies.max > 0
    end

    test "keeps last 1000 latencies per provider" do
      # Record more than 1000 latencies
      Enum.each(1..1100, fn i ->
        Metrics.record_provider_call("anthropic", i * 10)
      end)

      Process.sleep(200)

      summary = Metrics.get_summary()

      # Should still be able to compute percentiles
      latencies = summary.latency_percentiles["anthropic"]
      assert latencies.p50 > 0
      assert latencies.p99 > 0
    end
  end

  describe "record_error/2" do
    test "records error counts" do
      Metrics.record_error("llm.prompt.submit", "timeout")
      Metrics.record_error("llm.prompt.submit", "rate_limited")
      Metrics.record_error("llm.prompt.submit", "timeout")
      Process.sleep(100)

      summary = Metrics.get_summary()

      assert summary.errors["llm.prompt.submit"]["timeout"] == 2
      assert summary.errors["llm.prompt.submit"]["rate_limited"] == 1
    end
  end

  describe "record_provider_fallback/0" do
    test "increments fallback counter" do
      Metrics.record_provider_fallback()
      Metrics.record_provider_fallback()
      Process.sleep(100)

      summary = Metrics.get_summary()

      assert summary.provider_fallbacks == 2
    end
  end

  describe "RAG metrics" do
    test "records RAG index operations" do
      Metrics.record_rag_index()
      Metrics.record_rag_index()
      Process.sleep(100)

      summary = Metrics.get_summary()

      assert summary.rag_indexed == 2
    end

    test "records RAG search operations" do
      Metrics.record_rag_search()
      Metrics.record_rag_search()
      Metrics.record_rag_search()
      Process.sleep(100)

      summary = Metrics.get_summary()

      assert summary.rag_searched == 3
    end
  end

  describe "get_summary/0" do
    test "returns current state" do
      Metrics.record_request("llm.prompt.submit")
      Metrics.record_provider_call("anthropic", 100)
      Process.sleep(100)

      summary = Metrics.get_summary()

      assert is_map(summary)
      assert Map.has_key?(summary, :uptime_seconds)
      assert Map.has_key?(summary, :requests)
      assert Map.has_key?(summary, :errors)
      assert Map.has_key?(summary, :provider_calls)
      assert Map.has_key?(summary, :latency_percentiles)
      assert Map.has_key?(summary, :rag_indexed)
      assert Map.has_key?(summary, :rag_searched)
    end

    test "computes uptime in seconds" do
      summary1 = Metrics.get_summary()
      Process.sleep(100)
      summary2 = Metrics.get_summary()

      assert summary2.uptime_seconds >= summary1.uptime_seconds
    end
  end
end
