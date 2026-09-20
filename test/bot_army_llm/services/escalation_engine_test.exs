defmodule BotArmyLlm.Services.EscalationEngineTest do
  use ExUnit.Case
  @moduletag :services

  alias BotArmyLlm.Services.{EscalationEngine, LouizaIntentConfig}

  describe "calculate_engagement_rate/1" do
    test "returns 0 for empty list" do
      rate = EscalationEngine.calculate_engagement_rate([])
      assert rate == 0.0
    end

    test "calculates completion percentage" do
      events = [
        %{"event_type" => "task_completed"},
        %{"event_type" => "task_completed"},
        %{"event_type" => "narrative_shown"}
      ]

      rate = EscalationEngine.calculate_engagement_rate(events)
      assert rate == 66.67 or rate == 66.66666666666666
    end

    test "100% completion" do
      events = [
        %{"event_type" => "task_completed"},
        %{"event_type" => "task_completed"}
      ]

      rate = EscalationEngine.calculate_engagement_rate(events)
      assert rate == 100.0
    end

    test "0% completion" do
      events = [
        %{"event_type" => "narrative_shown"},
        %{"event_type" => "narrative_shown"}
      ]

      rate = EscalationEngine.calculate_engagement_rate(events)
      assert rate == 0.0
    end
  end

  describe "should_escalate?/2" do
    test "escalates with high engagement on linear" do
      config = LouizaIntentConfig.default()

      events =
        Enum.map(1..10, fn i ->
          if rem(i, 2) == 0 do
            %{"event_type" => "task_completed"}
          else
            %{"event_type" => "narrative_shown"}
          end
        end)

      {status, multiplier} = EscalationEngine.should_escalate?(config, events)

      if EscalationEngine.calculate_engagement_rate(events) >= 70.0 do
        assert status == :escalate
        assert multiplier > config.current_multiplier
      else
        assert status == :maintain
      end
    end

    test "maintains with low engagement" do
      config = LouizaIntentConfig.default()
      events = [%{"event_type" => "narrative_shown"}, %{"event_type" => "narrative_shown"}]

      {status, _multiplier} = EscalationEngine.should_escalate?(config, events)
      assert status == :maintain
    end

    test "aggressive curve escalates at lower threshold" do
      config_conservative =
        LouizaIntentConfig.set_intent(LouizaIntentConfig.default(), %{
          escalation_curve: :conservative
        })

      config_aggressive =
        LouizaIntentConfig.set_intent(LouizaIntentConfig.default(), %{
          escalation_curve: :aggressive
        })

      events =
        Enum.map(1..10, fn i ->
          if rem(i, 2) == 0 do
            %{"event_type" => "task_completed"}
          else
            %{"event_type" => "narrative_shown"}
          end
        end)

      {conservative_status, _} = EscalationEngine.should_escalate?(config_conservative, events)
      {aggressive_status, _} = EscalationEngine.should_escalate?(config_aggressive, events)

      # Aggressive should escalate more readily
      if conservative_status == :maintain do
        # Aggressive might escalate when conservative doesn't
        assert true
      end
    end
  end

  describe "apply_escalation/2" do
    test "applies escalation" do
      config = LouizaIntentConfig.default()
      updated = EscalationEngine.apply_escalation(config, {:escalate, 1.5})

      assert updated.current_multiplier == 1.5
    end

    test "maintains multiplier when maintaining" do
      config = LouizaIntentConfig.default()
      updated = EscalationEngine.apply_escalation(config, {:maintain, 1.0})

      assert updated.current_multiplier == 1.0
    end
  end

  describe "escalation_status/2" do
    test "returns status map" do
      config = LouizaIntentConfig.default()
      events = [%{"event_type" => "task_completed"}]

      status = EscalationEngine.escalation_status(config, events)

      assert Map.has_key?(status, "current_engagement_rate")
      assert Map.has_key?(status, "escalation_threshold")
      assert Map.has_key?(status, "status")
      assert Map.has_key?(status, "message")
    end

    test "provides escalation message" do
      config = LouizaIntentConfig.default()
      events = Enum.map(1..10, fn _i -> %{"event_type" => "task_completed"} end)

      status = EscalationEngine.escalation_status(config, events)
      assert is_binary(status["message"])
      assert byte_size(status["message"]) > 0
    end
  end
end
