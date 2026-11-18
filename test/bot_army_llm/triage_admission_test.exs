defmodule BotArmyLlm.TriageAdmissionTest do
  use ExUnit.Case, async: true
  @moduletag :core

  alias BotArmyLlm.TriageAdmission

  test "build_item reads sender, model type, and the explicit cloud flag" do
    item =
      TriageAdmission.build_item(
        %{"request_id" => "r1", "sender" => "user", "model_type" => "uncensored", "cloud_only" => true},
        "interactive",
        fn -> :ok end
      )

    assert item.id == "r1"
    assert item.lane == "interactive"
    assert item.sender == :user
    assert item.local_only
    assert item.cloud_only
    assert is_function(item.work, 0)
  end

  test "defaults: system sender, no pins, a token estimate from the payload size" do
    item = TriageAdmission.build_item(%{"request_id" => "r2", "query" => "hello"}, "background", fn -> :ok end)

    assert item.sender == :system
    refute item.local_only
    refute item.cloud_only
    assert item.est_tokens > 0
  end

  test "triage is off unless explicitly enabled" do
    refute TriageAdmission.enabled?()
  end
end
