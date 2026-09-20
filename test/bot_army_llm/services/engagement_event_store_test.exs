defmodule BotArmyLlm.Services.EngagementEventStoreTest do
  use ExUnit.Case
  @moduletag :services
  @moduletag :integration

  import Ecto.Query
  alias BotArmyLlm.Services.EngagementEventStore
  alias BotArmyLlm.Repo

  setup do
    # Clean up before each test
    Repo.delete_all(BotArmyLlm.Schemas.EngagementEvent)
    :ok
  end

  describe "store_event/1" do
    test "stores engagement event successfully" do
      event = %{
        "task_id" => "task-123",
        "user_id" => "user-1",
        "voice_key" => "cheerleader",
        "emotional_frame" => "hopeful",
        "quest_type" => "combat",
        "event_type" => "narrative_shown",
        "data" => %{}
      }

      {:ok, stored} = EngagementEventStore.store_event(event)

      assert stored.task_id == "task-123"
      assert stored.user_id == "user-1"
      assert stored.voice_key == "cheerleader"
      assert stored.event_type == "narrative_shown"
    end

    test "stores event with completion speed data" do
      event = %{
        "task_id" => "task-456",
        "user_id" => "user-2",
        "voice_key" => "drill_sergeant",
        "emotional_frame" => "defiant",
        "quest_type" => "reflection",
        "event_type" => "task_completed",
        "data" => %{"completion_speed" => "quick", "seconds_to_completion" => 120}
      }

      {:ok, stored} = EngagementEventStore.store_event(event)

      assert stored.data["completion_speed"] == "quick"
      assert stored.data["seconds_to_completion"] == 120
    end

    test "fails when required fields missing" do
      event = %{
        "task_id" => "task-789",
        "user_id" => "user-3"
        # Missing required fields
      }

      {:error, changeset} = EngagementEventStore.store_event(event)
      assert changeset.errors[:voice_key]
      assert changeset.errors[:event_type]
    end
  end

  describe "events_for_user/1" do
    test "returns all events for a user" do
      user_id = "user-1"

      EngagementEventStore.store_event(%{
        "task_id" => "task-1",
        "user_id" => user_id,
        "voice_key" => "cheerleader",
        "emotional_frame" => "hopeful",
        "quest_type" => "combat",
        "event_type" => "narrative_shown"
      })

      EngagementEventStore.store_event(%{
        "task_id" => "task-2",
        "user_id" => user_id,
        "voice_key" => "drill_sergeant",
        "emotional_frame" => "defiant",
        "quest_type" => "reflection",
        "event_type" => "task_completed"
      })

      EngagementEventStore.store_event(%{
        "task_id" => "task-3",
        "user_id" => "other-user",
        "voice_key" => "cheerleader",
        "emotional_frame" => "playful",
        "quest_type" => "maintenance",
        "event_type" => "narrative_shown"
      })

      events = EngagementEventStore.events_for_user(user_id)
      assert length(events) == 2
      assert Enum.all?(events, &(&1.user_id == user_id))
    end

    test "returns empty list for user with no events" do
      events = EngagementEventStore.events_for_user("nonexistent-user")
      assert events == []
    end
  end

  describe "events_for_user_voice/2" do
    test "returns events for specific voice" do
      user_id = "user-1"
      voice_key = "cheerleader"

      EngagementEventStore.store_event(%{
        "task_id" => "task-1",
        "user_id" => user_id,
        "voice_key" => voice_key,
        "emotional_frame" => "hopeful",
        "quest_type" => "combat",
        "event_type" => "narrative_shown"
      })

      EngagementEventStore.store_event(%{
        "task_id" => "task-2",
        "user_id" => user_id,
        "voice_key" => "drill_sergeant",
        "emotional_frame" => "defiant",
        "quest_type" => "reflection",
        "event_type" => "task_completed"
      })

      events = EngagementEventStore.events_for_user_voice(user_id, voice_key)
      assert length(events) == 1
      assert hd(events).voice_key == voice_key
    end
  end

  describe "recent_events_for_user/2" do
    test "returns limited number of recent events" do
      user_id = "user-1"

      Enum.each(1..15, fn i ->
        EngagementEventStore.store_event(%{
          "task_id" => "task-#{i}",
          "user_id" => user_id,
          "voice_key" => "cheerleader",
          "emotional_frame" => "hopeful",
          "quest_type" => "combat",
          "event_type" => "narrative_shown"
        })
      end)

      events = EngagementEventStore.recent_events_for_user(user_id, 5)
      assert length(events) == 5
    end

    test "respects default limit of 100" do
      user_id = "user-1"

      Enum.each(1..50, fn i ->
        EngagementEventStore.store_event(%{
          "task_id" => "task-#{i}",
          "user_id" => user_id,
          "voice_key" => "cheerleader",
          "emotional_frame" => "hopeful",
          "quest_type" => "combat",
          "event_type" => "narrative_shown"
        })
      end)

      events = EngagementEventStore.recent_events_for_user(user_id)
      assert length(events) == 50
    end
  end

  describe "to_learning_format/1" do
    test "converts event to learning analyzer format" do
      {:ok, event} =
        EngagementEventStore.store_event(%{
          "task_id" => "task-123",
          "user_id" => "user-1",
          "voice_key" => "cheerleader",
          "emotional_frame" => "hopeful",
          "quest_type" => "combat",
          "event_type" => "narrative_shown",
          "data" => %{"some_data" => "value"}
        })

      formatted = EngagementEventStore.to_learning_format(event)

      assert formatted["task_id"] == "task-123"
      assert formatted["user_id"] == "user-1"
      assert formatted["voice_key"] == "cheerleader"
      assert formatted["data"]["some_data"] == "value"
      assert formatted["timestamp"] == event.inserted_at
    end
  end

  describe "events_for_analysis/2" do
    test "returns events in learning analyzer format" do
      user_id = "user-1"

      EngagementEventStore.store_event(%{
        "task_id" => "task-1",
        "user_id" => user_id,
        "voice_key" => "cheerleader",
        "emotional_frame" => "hopeful",
        "quest_type" => "combat",
        "event_type" => "narrative_shown"
      })

      EngagementEventStore.store_event(%{
        "task_id" => "task-2",
        "user_id" => user_id,
        "voice_key" => "drill_sergeant",
        "emotional_frame" => "defiant",
        "quest_type" => "reflection",
        "event_type" => "task_completed"
      })

      events = EngagementEventStore.events_for_analysis(user_id)

      assert length(events) == 2
      assert hd(events)["voice_key"] in ["cheerleader", "drill_sergeant"]
      assert all_have_required_fields?(events)
    end
  end

  describe "count_by_voice/1" do
    test "returns count of events per voice" do
      user_id = "user-1"

      EngagementEventStore.store_event(%{
        "task_id" => "task-1",
        "user_id" => user_id,
        "voice_key" => "cheerleader",
        "emotional_frame" => "hopeful",
        "quest_type" => "combat",
        "event_type" => "narrative_shown"
      })

      EngagementEventStore.store_event(%{
        "task_id" => "task-2",
        "user_id" => user_id,
        "voice_key" => "cheerleader",
        "emotional_frame" => "playful",
        "quest_type" => "reflection",
        "event_type" => "narrative_shown"
      })

      EngagementEventStore.store_event(%{
        "task_id" => "task-3",
        "user_id" => user_id,
        "voice_key" => "drill_sergeant",
        "emotional_frame" => "defiant",
        "quest_type" => "maintenance",
        "event_type" => "task_completed"
      })

      counts = EngagementEventStore.count_by_voice(user_id)

      assert counts["cheerleader"] == 2
      assert counts["drill_sergeant"] == 1
    end
  end

  describe "prune_old_events/1" do
    test "removes events older than specified days" do
      user_id = "user-1"

      EngagementEventStore.store_event(%{
        "task_id" => "task-1",
        "user_id" => user_id,
        "voice_key" => "cheerleader",
        "emotional_frame" => "hopeful",
        "quest_type" => "combat",
        "event_type" => "narrative_shown"
      })

      # Simulate old event by directly updating DB
      old_event = Repo.get_by(BotArmyLlm.Schemas.EngagementEvent, task_id: "task-1")

      old_datetime =
        DateTime.utc_now()
        |> DateTime.add(-100 * 86400, :second)

      Repo.update_all(
        from(e in BotArmyLlm.Schemas.EngagementEvent, where: e.id == ^old_event.id),
        set: [inserted_at: old_datetime]
      )

      {deleted_count, _} = EngagementEventStore.prune_old_events(90)
      assert deleted_count == 1

      remaining = EngagementEventStore.events_for_user(user_id)
      assert remaining == []
    end
  end

  defp all_have_required_fields?(events) do
    Enum.all?(events, fn event ->
      Map.has_key?(event, "task_id") && Map.has_key?(event, "voice_key") &&
        Map.has_key?(event, "event_type") && Map.has_key?(event, "timestamp")
    end)
  end
end
