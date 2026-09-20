defmodule BotArmyLlm.Services.LearningAnalyzerTest do
  use ExUnit.Case
  @moduletag :services

  alias BotArmyLlm.Services.LearningAnalyzer

  describe "analyze_voice_performance/1" do
    test "aggregates voice scores" do
      events = [
        %{"voice_key" => "cheerleader", "event_type" => "task_completed"},
        %{"voice_key" => "cheerleader", "event_type" => "task_completed"},
        %{"voice_key" => "drill_sergeant", "event_type" => "narrative_skipped"}
      ]

      performance = LearningAnalyzer.analyze_voice_performance(events)
      assert Map.has_key?(performance, "cheerleader")
      assert Map.has_key?(performance, "drill_sergeant")
    end

    test "returns average score and sample count" do
      events = [
        %{"voice_key" => "cheerleader", "event_type" => "task_completed", "data" => %{}},
        %{"voice_key" => "cheerleader", "event_type" => "narrative_shown", "data" => %{}}
      ]

      performance = LearningAnalyzer.analyze_voice_performance(events)
      {avg_score, count} = performance["cheerleader"]
      assert count == 2
      assert avg_score > 0
    end
  end

  describe "analyze_frame_performance/1" do
    test "aggregates emotional frame scores" do
      events = [
        %{"emotional_frame" => "hopeful", "event_type" => "task_completed", "data" => %{}},
        %{"emotional_frame" => "hopeful", "event_type" => "task_completed", "data" => %{}},
        %{"emotional_frame" => "defiant", "event_type" => "narrative_shown", "data" => %{}}
      ]

      performance = LearningAnalyzer.analyze_frame_performance(events)
      assert Map.has_key?(performance, "hopeful")
      assert Map.has_key?(performance, "defiant")
    end
  end

  describe "analyze_quest_type_performance/1" do
    test "aggregates quest type scores" do
      events = [
        %{"quest_type" => "combat", "event_type" => "task_completed", "data" => %{}},
        %{"quest_type" => "reflection", "event_type" => "narrative_shown", "data" => %{}}
      ]

      performance = LearningAnalyzer.analyze_quest_type_performance(events)
      assert Map.has_key?(performance, "combat")
      assert Map.has_key?(performance, "reflection")
    end
  end

  describe "completion_rate_for_voice/2" do
    test "calculates completion rate" do
      events = [
        %{"voice_key" => "cheerleader", "event_type" => "narrative_shown"},
        %{"voice_key" => "cheerleader", "event_type" => "task_completed"},
        %{"voice_key" => "cheerleader", "event_type" => "narrative_shown"}
      ]

      rate = LearningAnalyzer.completion_rate_for_voice(events, "cheerleader")
      assert rate == 0.5
    end

    test "returns 0 for no events" do
      events = []
      rate = LearningAnalyzer.completion_rate_for_voice(events, "cheerleader")
      assert rate == 0.0
    end
  end

  describe "recommend_voice/2" do
    test "returns voice with highest score" do
      events = [
        %{"voice_key" => "cheerleader", "event_type" => "task_completed", "data" => %{}},
        %{"voice_key" => "cheerleader", "event_type" => "task_completed", "data" => %{}},
        %{"voice_key" => "cheerleader", "event_type" => "task_completed", "data" => %{}},
        %{"voice_key" => "drill_sergeant", "event_type" => "narrative_skipped", "data" => %{}},
        %{"voice_key" => "drill_sergeant", "event_type" => "narrative_skipped", "data" => %{}},
        %{"voice_key" => "drill_sergeant", "event_type" => "narrative_skipped", "data" => %{}}
      ]

      recommendation = LearningAnalyzer.recommend_voice(events, 3)
      assert recommendation == :cheerleader
    end

    test "returns nil if no voice has enough samples" do
      events = [
        %{"voice_key" => "cheerleader", "event_type" => "task_completed", "data" => %{}}
      ]

      recommendation = LearningAnalyzer.recommend_voice(events, 5)
      assert is_nil(recommendation)
    end
  end

  describe "trending_frame/2" do
    test "returns frame with highest recent engagement" do
      events = [
        %{
          "emotional_frame" => "hopeful",
          "event_type" => "task_completed",
          "data" => %{},
          "timestamp" => "2026-09-20T00:00:00Z"
        },
        %{
          "emotional_frame" => "hopeful",
          "event_type" => "task_completed",
          "data" => %{},
          "timestamp" => "2026-09-20T00:01:00Z"
        },
        %{
          "emotional_frame" => "defiant",
          "event_type" => "narrative_skipped",
          "data" => %{},
          "timestamp" => "2026-09-20T00:02:00Z"
        }
      ]

      trending = LearningAnalyzer.trending_frame(events, 3)
      assert trending == "hopeful"
    end
  end

  describe "learning_summary/1" do
    test "returns insufficient data for empty events" do
      summary = LearningAnalyzer.learning_summary([])
      assert summary["status"] == "insufficient_data"
    end

    test "returns learning status for early data" do
      events = [
        %{"voice_key" => "cheerleader", "event_type" => "task_completed", "data" => %{}}
      ]

      summary = LearningAnalyzer.learning_summary(events)
      assert summary["status"] == "learning"
      assert summary["events_recorded"] == 1
    end

    test "returns comprehensive summary with enough data" do
      events =
        Enum.map(1..10, fn i ->
          %{
            "voice_key" => if(rem(i, 2) == 0, do: "cheerleader", else: "drill_sergeant"),
            "emotional_frame" => if(rem(i, 3) == 0, do: "hopeful", else: "defiant"),
            "quest_type" => "combat",
            "event_type" => "task_completed",
            "data" => %{},
            "timestamp" => DateTime.utc_now()
          }
        end)

      summary = LearningAnalyzer.learning_summary(events)
      assert summary["status"] == "learning"
      assert summary["events_recorded"] == 10
      assert Map.has_key?(summary, "best_voice")
      assert Map.has_key?(summary, "insight")
    end
  end
end
