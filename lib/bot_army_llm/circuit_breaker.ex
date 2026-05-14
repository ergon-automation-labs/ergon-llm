defmodule BotArmyLlm.CircuitBreaker do
  @moduledoc """
  Per-provider circuit breaker for LLM external calls.

  Tracks consecutive failures per provider and opens the circuit after
  a threshold is reached. Open circuits skip the provider entirely,
  allowing the fallback chain to try the next one.

  States:
  - `:closed` — normal operation, requests pass through
  - `:open` — too many failures, requests are rejected immediately
  - `:half_open` — timeout expired, allowing a single probe request

  Rate-limited (429) responses trigger a longer cooldown than regular failures.

  ## Configuration

  - `:failure_threshold` — consecutive failures before opening (default: 5)
  - `:half_open_timeout_ms` — time before trying a probe (default: 30_000)
  - `:rate_limit_cooldown_ms` — cooldown after 429 (default: 60_000)
  """

  use GenServer

  require Logger

  @env Mix.env()
  @failure_threshold 5

  def child_spec(provider) do
    %{
      id: {__MODULE__, provider},
      start: {__MODULE__, :start_link, [provider]},
      type: :worker,
      restart: :permanent
    }
  end

  @half_open_timeout_ms 30_000
  @rate_limit_cooldown_ms 60_000

  def start_link(provider) do
    GenServer.start_link(__MODULE__, provider, name: via(provider))
  end

  defp via(provider) do
    {:via, Registry, {BotArmyLlm.CircuitBreakerRegistry, provider}}
  end

  @doc """
  Check if requests are allowed for a provider.

  Returns:
  - `:ok` — circuit is closed or half-open (probe allowed)
  - `{:open, retry_after_ms}` — circuit is open, try next provider
  """
  def allow?(provider) do
    try do
      GenServer.call(via(provider), :check, 1000)
    catch
      :exit, _ -> :ok
    end
  end

  @doc """
  Record a successful call. Closes the circuit if it was half-open.
  """
  def record_success(provider) do
    try do
      GenServer.cast(via(provider), :success)
    catch
      :exit, _ -> :ok
    end
  end

  @doc """
  Record a failure. Opens the circuit if threshold is reached.

  Pass `:rate_limited` as reason for longer cooldown.
  """
  def record_failure(provider, reason \\ :error) do
    try do
      GenServer.cast(via(provider), {:failure, reason})
    catch
      :exit, _ -> :ok
    end
  end

  @doc """
  Get the current state of a provider's circuit breaker.
  """
  def get_state(provider) do
    try do
      GenServer.call(via(provider), :get_state, 1000)
    catch
      :exit, _ -> %{state: :unknown, failures: 0}
    end
  end

  # GenServer callbacks

  @impl true
  def init(provider) do
    {:ok,
     %{
       provider: provider,
       circuit_state: :closed,
       failures: 0,
       opened_at: nil,
       cooldown_until: nil
     }}
  end

  @impl true
  def handle_call(:check, _from, state) do
    now = System.monotonic_time(:millisecond)

    case state.circuit_state do
      :closed ->
        {:reply, :ok, state}

      :open ->
        # Check if half-open timeout has passed
        elapsed = now - state.opened_at

        if elapsed >= @half_open_timeout_ms do
          # Transition to half-open, allow one probe
          {:reply, :ok, %{state | circuit_state: :half_open}}
        else
          retry_after = @half_open_timeout_ms - elapsed
          {:reply, {:open, retry_after}, state}
        end

      :half_open ->
        # Allow the probe
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, %{state: state.circuit_state, failures: state.failures}, state}
  end

  # Test-only: simulate time passing for half-open timeout
  if @env == :test do
    @impl true
    def handle_call({:set_opened_at, timestamp}, _from, state) do
      {:reply, :ok, %{state | opened_at: timestamp}}
    end
  end

  @impl true
  def handle_cast(:success, state) do
    case state.circuit_state do
      :half_open ->
        Logger.info("[CircuitBreaker] #{state.provider}: closed after successful probe")

        {:noreply,
         %{state | circuit_state: :closed, failures: 0, opened_at: nil, cooldown_until: nil}}

      _ ->
        {:noreply, %{state | failures: 0}}
    end
  end

  @impl true
  def handle_cast({:failure, :rate_limited}, state) do
    now = System.monotonic_time(:millisecond)
    cooldown_until = now + @rate_limit_cooldown_ms

    Logger.warning(
      "[CircuitBreaker] #{state.provider}: rate limited, cooldown #{@rate_limit_cooldown_ms}ms"
    )

    {:noreply,
     %{
       state
       | circuit_state: :open,
         failures: state.failures + 1,
         opened_at: now,
         cooldown_until: cooldown_until
     }}
  end

  @impl true
  def handle_cast({:failure, _reason}, state) do
    new_failures = state.failures + 1

    if new_failures >= @failure_threshold do
      now = System.monotonic_time(:millisecond)

      Logger.warning("[CircuitBreaker] #{state.provider}: opened after #{new_failures} failures")

      {:noreply, %{state | circuit_state: :open, failures: new_failures, opened_at: now}}
    else
      {:noreply, %{state | failures: new_failures}}
    end
  end
end
