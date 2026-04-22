defmodule BotArmyLlm.TokenAccountingTestRepoMock do
  @moduledoc "Mock Repo for TokenAccounting testing"

  def insert(changeset) do
    case changeset.valid? do
      true ->
        {:ok,
         %{
           changeset.data
           | id: UUID.uuid4(),
             inserted_at: DateTime.utc_now()
         }}

      false ->
        {:error, changeset}
    end
  end

  def all(_query) do
    Process.get({:token_accounting_test, :all_results}, [])
  end
end

defmodule BotArmyLlm.TokenAccountingTest do
  use ExUnit.Case, async: false
  @moduletag :core

  alias BotArmyLlm.TokenAccounting

  setup do
    # Inject mock Repo
    Application.put_env(:bot_army_llm, :repo, BotArmyLlm.TokenAccountingTestRepoMock)

    on_exit(fn ->
      Application.put_env(:bot_army_llm, :repo, BotArmyLlm.Repo)
    end)

    :ok
  end

  describe "record/1" do
    test "records token usage successfully" do
      attrs = %{
        "event_id" => UUID.uuid4(),
        "event_type" => "llm.prompt.submit",
        "source" => "bot_army_gtd",
        "provider" => "anthropic",
        "model" => "claude-haiku",
        "tokens_input" => 100,
        "tokens_output" => 50,
        "latency_ms" => 200
      }

      {:ok, _usage} = TokenAccounting.record(attrs)
    end

    test "validates required fields" do
      attrs = %{
        "event_id" => UUID.uuid4(),
        # missing event_type
        "provider" => "anthropic",
        "model" => "claude-haiku"
      }

      {:error, _reason} = TokenAccounting.record(attrs)
    end

    test "handles nil token counts" do
      attrs = %{
        "event_id" => UUID.uuid4(),
        "event_type" => "llm.prompt.submit",
        "provider" => "ollama",
        "model" => "llama2"
        # tokens_input and tokens_output are nil
      }

      {:ok, _usage} = TokenAccounting.record(attrs)
    end

    test "claude_code source applies well-known tenant and user when omitted" do
      attrs = %{
        "event_id" => UUID.uuid4(),
        "event_type" => "llm.prompt.submit",
        "source" => "claude_code",
        "provider" => "anthropic",
        "model" => "claude-haiku"
      }

      {:ok, _usage} = TokenAccounting.record(attrs)
    end

    test "rejects non-map input" do
      {:error, :invalid_attributes} = TokenAccounting.record(nil)
    end
  end

  describe "estimate_cost/4" do
    test "calculates zero cost for Ollama" do
      cost = TokenAccounting.estimate_cost("ollama", "llama2", 100, 50)

      assert cost == 0.0
    end

    test "calculates correct cost for Anthropic Haiku" do
      # Haiku: $0.80 per 1M input, $4.00 per 1M output
      # 100 input tokens = (100 * 0.80) / 1_000_000 = 0.00008
      # 50 output tokens = (50 * 4.00) / 1_000_000 = 0.0002
      # Total = 0.00028

      cost = TokenAccounting.estimate_cost("anthropic", "claude-haiku", 100, 50)

      assert Float.round(cost, 8) == 0.00028
    end

    test "calculates correct cost for Anthropic Sonnet" do
      # Sonnet: $3.00 per 1M input, $15.00 per 1M output
      cost = TokenAccounting.estimate_cost("anthropic", "claude-sonnet", 1_000_000, 1_000_000)

      assert Float.round(cost, 2) == 18.0
    end

    test "handles nil token counts" do
      cost = TokenAccounting.estimate_cost("anthropic", "claude-haiku", nil, nil)

      assert cost == 0.0
    end

    test "handles partial token counts" do
      # Only input tokens
      cost = TokenAccounting.estimate_cost("anthropic", "claude-haiku", 100, nil)

      assert Float.round(cost, 8) == 0.00008
    end

    test "case-insensitive provider matching" do
      cost1 = TokenAccounting.estimate_cost("anthropic", "claude-haiku", 100, 50)
      cost2 = TokenAccounting.estimate_cost("ANTHROPIC", "claude-haiku", 100, 50)

      assert cost1 == cost2
    end

    test "BOT_ARMY_LLM_PRICING_JSON overlay: provider * matches by model_substring" do
      json =
        Jason.encode!([
          %{
            "provider" => "*",
            "model_substring" => "minimax",
            "input_per_million_usd" => 1.0,
            "output_per_million_usd" => 2.0
          }
        ])

      System.put_env("BOT_ARMY_LLM_PRICING_JSON", json)

      on_exit(fn ->
        System.delete_env("BOT_ARMY_LLM_PRICING_JSON")
      end)

      # Stored provider may still say anthropic while model id is an OpenRouter/Minimax slug
      cost =
        TokenAccounting.estimate_cost("anthropic", "minimax/minimax-m2", 1_000_000, 1_000_000)

      assert Float.round(cost, 2) == 3.0
    end

    test "OpenRouter defaults to zero without overlay" do
      assert TokenAccounting.estimate_cost(
               "openrouter",
               "some/vendor-model",
               1_000_000,
               1_000_000
             ) == 0.0
    end
  end

  describe "query/1" do
    test "aggregates all token usage" do
      mock_rows = [
        %BotArmyLlm.Schemas.TokenUsage{
          event_id: UUID.uuid4(),
          event_type: "llm.prompt.submit",
          source: "bot_army_gtd",
          provider: "anthropic",
          model: "claude-haiku",
          tokens_input: 100,
          tokens_output: 50,
          estimated_cost_usd: 0.00028,
          latency_ms: 200,
          inserted_at: DateTime.utc_now()
        },
        %BotArmyLlm.Schemas.TokenUsage{
          event_id: UUID.uuid4(),
          event_type: "llm.inference.chain",
          source: "bot_army_job",
          provider: "anthropic",
          model: "claude-sonnet",
          tokens_input: 200,
          tokens_output: 100,
          estimated_cost_usd: 0.0018,
          latency_ms: 300,
          inserted_at: DateTime.utc_now()
        }
      ]

      Process.put({:token_accounting_test, :all_results}, mock_rows)

      {:ok, summary} = TokenAccounting.query()

      assert summary.total_calls == 2
      assert summary.total_tokens_in == 300
      assert summary.total_tokens_out == 150
      assert Float.round(summary.total_cost_usd, 5) == 0.00208
    end

    test "filters by source" do
      mock_rows = [
        %BotArmyLlm.Schemas.TokenUsage{
          event_id: UUID.uuid4(),
          event_type: "llm.prompt.submit",
          source: "bot_army_gtd",
          provider: "anthropic",
          model: "claude-haiku",
          tokens_input: 100,
          tokens_output: 50,
          estimated_cost_usd: 0.00028,
          latency_ms: 200,
          inserted_at: DateTime.utc_now()
        }
      ]

      Process.put({:token_accounting_test, :all_results}, mock_rows)

      {:ok, summary} = TokenAccounting.query(source: "bot_army_gtd")

      assert summary.total_calls == 1
      assert Map.has_key?(summary.by_source, "bot_army_gtd")
    end

    test "filters by provider" do
      mock_rows = [
        %BotArmyLlm.Schemas.TokenUsage{
          event_id: UUID.uuid4(),
          event_type: "llm.prompt.submit",
          source: "bot_army_gtd",
          provider: "anthropic",
          model: "claude-haiku",
          tokens_input: 100,
          tokens_output: 50,
          estimated_cost_usd: 0.00028,
          latency_ms: 200,
          inserted_at: DateTime.utc_now()
        }
      ]

      Process.put({:token_accounting_test, :all_results}, mock_rows)

      {:ok, summary} = TokenAccounting.query(provider: "anthropic")

      assert summary.total_calls == 1
      assert Map.has_key?(summary.by_provider, "anthropic")
    end

    test "groups by provider and source" do
      mock_rows = [
        %BotArmyLlm.Schemas.TokenUsage{
          event_id: UUID.uuid4(),
          event_type: "llm.prompt.submit",
          source: "bot_army_gtd",
          provider: "anthropic",
          model: "claude-haiku",
          tokens_input: 100,
          tokens_output: 50,
          estimated_cost_usd: 0.00028,
          latency_ms: 200,
          inserted_at: DateTime.utc_now()
        },
        %BotArmyLlm.Schemas.TokenUsage{
          event_id: UUID.uuid4(),
          event_type: "llm.inference.chain",
          source: "bot_army_job",
          provider: "anthropic",
          model: "claude-sonnet",
          tokens_input: 200,
          tokens_output: 100,
          estimated_cost_usd: 0.0018,
          latency_ms: 300,
          inserted_at: DateTime.utc_now()
        }
      ]

      Process.put({:token_accounting_test, :all_results}, mock_rows)

      {:ok, summary} = TokenAccounting.query()

      assert map_size(summary.by_provider) > 0
      assert map_size(summary.by_source) > 0
    end
  end
end
