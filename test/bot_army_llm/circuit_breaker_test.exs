defmodule BotArmyLlm.CircuitBreakerTest do
  use ExUnit.Case, async: false
  @moduletag :core

  alias BotArmyLlm.CircuitBreaker

  # The LLM app starts CircuitBreakerRegistry and 4 circuit breakers (:ollama, :blackbox, :openrouter, :anthropic).
  # Tests use unique provider names to avoid interfering with the app's breakers.

  describe "closed state (normal operation)" do
    setup do
      provider = :"test_closed_#{System.unique_integer([:positive])}"
      start_supervised!({CircuitBreaker, provider})
      %{provider: provider}
    end

    test "allow? returns :ok when circuit is closed", %{provider: provider} do
      assert CircuitBreaker.allow?(provider) == :ok
    end

    test "get_state returns closed with 0 failures initially", %{provider: provider} do
      state = CircuitBreaker.get_state(provider)
      assert state.state == :closed
      assert state.failures == 0
    end

    test "recording success resets failure count to 0", %{provider: provider} do
      CircuitBreaker.record_failure(provider)
      CircuitBreaker.record_failure(provider)
      assert CircuitBreaker.get_state(provider).failures == 2

      CircuitBreaker.record_success(provider)
      assert CircuitBreaker.get_state(provider).failures == 0
    end

    test "failures below threshold keep circuit closed", %{provider: provider} do
      for _ <- 1..4, do: CircuitBreaker.record_failure(provider)
      assert CircuitBreaker.get_state(provider).state == :closed
      assert CircuitBreaker.allow?(provider) == :ok
    end
  end

  describe "opening the circuit" do
    setup do
      provider = :"test_open_#{System.unique_integer([:positive])}"
      start_supervised!({CircuitBreaker, provider})
      %{provider: provider}
    end

    test "circuit opens after 5 consecutive failures", %{provider: provider} do
      for _ <- 1..5, do: CircuitBreaker.record_failure(provider)
      assert CircuitBreaker.get_state(provider).state == :open
    end

    test "allow? returns {:open, retry_after} when circuit is open", %{provider: provider} do
      for _ <- 1..5, do: CircuitBreaker.record_failure(provider)

      result = CircuitBreaker.allow?(provider)
      assert match?({:open, _ms}, result)

      {:open, retry_after} = result
      assert is_integer(retry_after)
      assert retry_after > 0
    end

    test "interleaved success resets the failure counter", %{provider: provider} do
      for _ <- 1..4, do: CircuitBreaker.record_failure(provider)
      CircuitBreaker.record_success(provider)

      assert CircuitBreaker.get_state(provider).failures == 0

      for _ <- 1..5, do: CircuitBreaker.record_failure(provider)
      assert CircuitBreaker.get_state(provider).state == :open
    end
  end

  describe "rate limiting (429)" do
    setup do
      provider = :"test_rate_#{System.unique_integer([:positive])}"
      start_supervised!({CircuitBreaker, provider})
      %{provider: provider}
    end

    test "rate_limited failure opens circuit immediately", %{provider: provider} do
      CircuitBreaker.record_failure(provider, :rate_limited)
      assert CircuitBreaker.get_state(provider).state == :open
    end

    test "rate_limited failure increments failure count", %{provider: provider} do
      CircuitBreaker.record_failure(provider, :rate_limited)
      assert CircuitBreaker.get_state(provider).failures == 1
    end
  end

  describe "half-open state" do
    setup do
      provider = :"test_halfopen_#{System.unique_integer([:positive])}"
      start_supervised!({CircuitBreaker, provider})
      %{provider: provider}
    end

    test "circuit transitions to half-open after timeout and allows probe", %{
      provider: provider
    } do
      for _ <- 1..5, do: CircuitBreaker.record_failure(provider)
      assert CircuitBreaker.get_state(provider).state == :open

      # Manually set opened_at to simulate timeout passing
      {:via, Registry, {BotArmyLlm.CircuitBreakerRegistry, provider}}
      |> GenServer.call({:set_opened_at, System.monotonic_time(:millisecond) - 31_000}, 1000)

      assert CircuitBreaker.allow?(provider) == :ok
    end

    test "successful probe closes the circuit", %{provider: provider} do
      for _ <- 1..5, do: CircuitBreaker.record_failure(provider)

      {:via, Registry, {BotArmyLlm.CircuitBreakerRegistry, provider}}
      |> GenServer.call({:set_opened_at, System.monotonic_time(:millisecond) - 31_000}, 1000)

      assert CircuitBreaker.allow?(provider) == :ok
      CircuitBreaker.record_success(provider)

      state = CircuitBreaker.get_state(provider)
      assert state.state == :closed
      assert state.failures == 0
    end

    test "failed probe re-opens the circuit", %{provider: provider} do
      for _ <- 1..5, do: CircuitBreaker.record_failure(provider)

      {:via, Registry, {BotArmyLlm.CircuitBreakerRegistry, provider}}
      |> GenServer.call({:set_opened_at, System.monotonic_time(:millisecond) - 31_000}, 1000)

      CircuitBreaker.allow?(provider)
      CircuitBreaker.record_failure(provider)

      assert CircuitBreaker.get_state(provider).state == :open
    end
  end

  describe "multiple providers are independent" do
    setup do
      provider_a = :"test_multi_a_#{System.unique_integer([:positive])}"
      provider_b = :"test_multi_b_#{System.unique_integer([:positive])}"
      start_supervised!({CircuitBreaker, provider_a})
      start_supervised!({CircuitBreaker, provider_b})
      %{provider_a: provider_a, provider_b: provider_b}
    end

    test "each provider has its own circuit breaker state", %{provider_a: a, provider_b: b} do
      for _ <- 1..5, do: CircuitBreaker.record_failure(a)

      assert CircuitBreaker.get_state(a).state == :open
      assert CircuitBreaker.get_state(b).state == :closed
      assert CircuitBreaker.allow?(b) == :ok
    end
  end

  describe "resilience to missing GenServer" do
    test "allow? returns :ok for unknown provider (fail-open)" do
      assert CircuitBreaker.allow?(:nonexistent_provider_999) == :ok
    end

    test "record_success is a no-op for unknown provider" do
      assert CircuitBreaker.record_success(:nonexistent_provider_999) == :ok
    end

    test "record_failure is a no-op for unknown provider" do
      assert CircuitBreaker.record_failure(:nonexistent_provider_999) == :ok
    end

    test "get_state returns unknown for missing provider" do
      state = CircuitBreaker.get_state(:nonexistent_provider_999)
      assert state.state == :unknown
    end
  end
end
