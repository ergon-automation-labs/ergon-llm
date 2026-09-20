defmodule BotArmyLlm.Services.EngagementTrackerTest do
  use ExUnit.Case
  @moduletag :services

  alias BotArmyLlm.Services.EngagementTracker

  describe "narrative_shown/5" do
    test "creates engagement event for narrative shown" do
      event =
        EngagementTracker.narrative_shown(
          "task-123",
          "user-1",
          :cheerleader,
          "hopeful",
          :combat
        )

      assert event.task_id == "task-123"
      assert event.user_id == "user-1"
      assert event.voice_key == :cheerleader
      assert event.emotional_frame == "hopeful"
      assert event.quest_type == :combat
      assert event.event_type == :narrative_shown
    end
  end

  describe "task_completed/7" do
    test "creates completion event with time data" do
      event =
        EngagementTracker.task_completed(
          "task-123",
          "user-1",
          :drill_sergeant,
          "defiant",
          :combat,
          200
        )

      assert event.event_type == :task_completed
      assert event.data["seconds_to_completion"] == 200
      assert event.data["completion_speed"] == :quick
    end

    test "classifies completion speeds" do
      immediate = EngagementTracker.task_completed("t", "u", :c, "f", :c, 30)
      assert immediate.data["completion_speed"] == :immediate

      quick = EngagementTracker.task_completed("t", "u", :c, "f", :c, 200)
      assert quick.data["completion_speed"] == :quick

      moderate = EngagementTracker.task_completed("t", "u", :c, "f", :c, 500)
      assert moderate.data["completion_speed"] == :moderate

      thoughtful = EngagementTracker.task_completed("t", "u", :c, "f", :c, 1000)
      assert thoughtful.data["completion_speed"] == :thoughtful

      slow = EngagementTracker.task_completed("t", "u", :c, "f", :c, 2000)
      assert slow.data["completion_speed"] == :slow
    end
  end

  describe "narrative_skipped/5" do
    test "creates skip event" do
      event =
        EngagementTracker.narrative_skipped(
          "task-123",
          "user-1",
          :gentle_guide,
          "tender",
          :reflection
        )

      assert event.event_type == :narrative_skipped
      assert event.voice_key == :gentle_guide
    end
  end

  describe "task_abandoned/7" do
    test "creates abandonment event" do
      event =
        EngagementTracker.task_abandoned(
          "task-123",
          "user-1",
          :mythic_oracle,
          "melancholic_resolve",
          :creation,
          600
        )

      assert event.event_type == :task_abandoned
      assert event.data["seconds_active"] == 600
    end
  end

  describe "engagement_score/1" do
    test "scores task completion positively" do
      event =
        EngagementTracker.task_completed("t", "u", :c, "f", :c, 200)

      score = EngagementTracker.engagement_score(event)
      assert score > 0
    end

    test "scores narrative shown positively" do
      event = EngagementTracker.narrative_shown("t", "u", :c, "f", :c)
      score = EngagementTracker.engagement_score(event)
      assert score > 0
    end

    test "scores narrative skip negatively" do
      event = EngagementTracker.narrative_skipped("t", "u", :c, "f", :c)
      score = EngagementTracker.engagement_score(event)
      assert score < 0
    end

    test "scores task abandonment negatively" do
      event = EngagementTracker.task_abandoned("t", "u", :c, "f", :c, 100)
      score = EngagementTracker.engagement_score(event)
      assert score < 0
    end
  end

  describe "encode/1 and decode/1" do
    test "round-trips engagement event through JSON" do
      original =
        EngagementTracker.task_completed(
          "task-123",
          "user-1",
          :cheerleader,
          "playful",
          :combat,
          300
        )

      encoded = EngagementTracker.encode(original)
      {:ok, decoded} = EngagementTracker.decode(encoded)

      assert decoded.task_id == original.task_id
      assert decoded.voice_key == original.voice_key
      assert decoded.event_type == original.event_type
    end

    test "returns error for invalid JSON" do
      result = EngagementTracker.decode("not valid json")
      assert result == :error
    end
  end
end
