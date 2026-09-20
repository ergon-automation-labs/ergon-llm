defmodule BotArmyLlm.Services.AdaptivePreferencesTest do
  use ExUnit.Case
  @moduletag :services

  alias BotArmyLlm.Services.AdaptivePreferences
  alias BotArmyLlm.Services.UserPreferences

  describe "suggest_updates/2" do
    test "returns nil for insufficient data" do
      events = [
        %{"voice_key" => "cheerleader", "event_type" => "task_completed", "data" => %{}}
      ]

      prefs = UserPreferences.default()
      suggestion = AdaptivePreferences.suggest_updates(events, prefs)
      assert is_nil(suggestion)
    end

    test "suggests voice change when clear winner exists" do
      events =
        Enum.map(1..15, fn i ->
          voice_key = if rem(i, 2) == 0, do: "cheerleader", else: "disappointed_narrator"

          event_type =
            if voice_key == "cheerleader", do: "task_completed", else: "narrative_skipped"

          %{
            "voice_key" => voice_key,
            "event_type" => event_type,
            "data" => %{"completion_speed" => "quick"},
            "timestamp" => DateTime.utc_now()
          }
        end)

      prefs = UserPreferences.default()
      suggestion = AdaptivePreferences.suggest_updates(events, prefs)
      assert suggestion != nil
      assert suggestion["confidence"] > 0
    end

    test "includes reason in suggestion" do
      events =
        Enum.map(1..15, fn i ->
          %{
            "voice_key" => "cheerleader",
            "event_type" => "task_completed",
            "data" => %{"completion_speed" => "quick"},
            "timestamp" => DateTime.utc_now()
          }
        end)

      prefs = UserPreferences.default()
      suggestion = AdaptivePreferences.suggest_updates(events, prefs)
      assert Map.has_key?(suggestion, "reason")
      assert is_binary(suggestion["reason"])
    end
  end

  describe "apply_adaptive_update/3" do
    test "updates voice if confidence high and improvement significant" do
      current_prefs = UserPreferences.default()

      suggestion = %{
        "new_voice_key" => :cheerleader,
        "confidence" => 0.8,
        "data" => %{"improvement_percent" => 35}
      }

      updated = AdaptivePreferences.apply_adaptive_update(current_prefs, suggestion)
      assert updated.voice_key == :cheerleader
    end

    test "does not update if confidence too low" do
      current_prefs = UserPreferences.default()

      suggestion = %{
        "new_voice_key" => :cheerleader,
        "confidence" => 0.5,
        "data" => %{"improvement_percent" => 35}
      }

      updated = AdaptivePreferences.apply_adaptive_update(current_prefs, suggestion)
      assert updated.voice_key == :disappointed_narrator
    end

    test "does not update if improvement too small" do
      current_prefs = UserPreferences.default()

      suggestion = %{
        "new_voice_key" => :cheerleader,
        "confidence" => 0.9,
        "data" => %{"improvement_percent" => 10}
      }

      updated = AdaptivePreferences.apply_adaptive_update(current_prefs, suggestion)
      assert updated.voice_key == :disappointed_narrator
    end
  end

  describe "learning_message/2" do
    test "shows ready message for no events" do
      message = AdaptivePreferences.learning_message([])
      assert String.contains?(message, "ready")
    end

    test "shows learning progress" do
      events = [%{"voice_key" => "cheerleader", "event_type" => "task_completed", "data" => %{}}]
      message = AdaptivePreferences.learning_message(events, 10)
      assert String.contains?(message, "9")
    end

    test "shows completion message" do
      events = Enum.map(1..10, fn _i -> %{"voice_key" => "cheerleader"} end)
      message = AdaptivePreferences.learning_message(events, 10)
      assert String.contains?(message, "10")
    end
  end

  describe "engagement_trend/2" do
    test "returns stable for insufficient history" do
      events = [%{"event_type" => "task_completed", "data" => %{}}]
      trend = AdaptivePreferences.engagement_trend(events, 5)
      assert trend == :stable
    end

    test "returns atom for sufficient history" do
      events =
        Enum.map(1..15, fn i ->
          %{"event_type" => "task_completed", "data" => %{"completion_speed" => "quick"}}
        end)

      trend = AdaptivePreferences.engagement_trend(events, 5)
      assert trend in [:improving, :stable, :declining]
    end
  end

  describe "insights/1" do
    test "returns no_data for empty events" do
      insights = AdaptivePreferences.insights([])
      assert insights["status"] == "no_data"
    end

    test "returns early_learning for few events" do
      events = [%{"voice_key" => "cheerleader", "event_type" => "task_completed", "data" => %{}}]
      insights = AdaptivePreferences.insights(events)
      assert insights["status"] == "early_learning"
    end

    test "returns learning status with insights" do
      events =
        Enum.map(1..10, fn i ->
          %{
            "voice_key" => "cheerleader",
            "event_type" => "task_completed",
            "data" => %{"completion_speed" => "quick"}
          }
        end)

      insights = AdaptivePreferences.insights(events)
      assert insights["status"] == "learning"
      assert insights["events_count"] == 10
      assert Map.has_key?(insights, "trend")
      assert Map.has_key?(insights, "message")
    end
  end
end
