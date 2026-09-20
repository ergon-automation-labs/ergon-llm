defmodule BotArmyLlm.Services.SceneFramerTest do
  use ExUnit.Case
  @moduletag :services

  alias BotArmyLlm.Services.SceneFramer

  describe "frame_scene/1" do
    test "returns string" do
      context = %{"location" => :bathroom, "time_period" => :morning, "presence" => :alone}
      scene = SceneFramer.frame_scene(context)
      assert is_binary(scene)
    end

    test "returns empty string for unknown location" do
      context = %{"location" => :unknown}
      scene = SceneFramer.frame_scene(context)
      assert scene == ""
    end

    test "includes location vibe" do
      context = %{"location" => :bathroom, "time_period" => :morning, "presence" => :alone}
      scene = SceneFramer.frame_scene(context)
      assert String.contains?(scene, "bathroom")
    end

    test "includes time vibe" do
      context = %{"location" => :bathroom, "time_period" => :morning, "presence" => :alone}
      scene = SceneFramer.frame_scene(context)
      assert String.contains?(scene, "morning") or String.contains?(scene, "possibility")
    end

    test "includes presence vibe" do
      context = %{"location" => :bathroom, "time_period" => :morning, "presence" => :with_partner}
      scene = SceneFramer.frame_scene(context)
      assert String.contains?(scene, "Louiza")
    end
  end

  describe "location_vibe/1" do
    test "bathroom vibe is about sanctuary" do
      vibe = SceneFramer.location_vibe(:bathroom)
      assert String.contains?(vibe, "sanctuary") or String.contains?(vibe, "bathroom")
    end

    test "kitchen vibe is about purpose" do
      vibe = SceneFramer.location_vibe(:kitchen)
      assert String.contains?(vibe, "kitchen") or String.contains?(vibe, "purpose")
    end

    test "gym vibe is about power" do
      vibe = SceneFramer.location_vibe(:gym)
      assert String.contains?(vibe, "gym") or String.contains?(vibe, "charged")
    end

    test "unknown location returns empty string" do
      vibe = SceneFramer.location_vibe(:unknown)
      assert vibe == ""
    end
  end

  describe "time_vibe/1" do
    test "morning vibe mentions possibility" do
      vibe = SceneFramer.time_vibe(:morning)
      assert String.contains?(vibe, "Morning")
    end

    test "evening vibe mentions restoration" do
      vibe = SceneFramer.time_vibe(:evening)
      assert String.contains?(vibe, "evening") or String.contains?(vibe, "earned")
    end

    test "night vibe mentions bravery" do
      vibe = SceneFramer.time_vibe(:night)
      assert String.contains?(vibe, "Night") or String.contains?(vibe, "brave")
    end
  end

  describe "presence_vibe/1" do
    test "alone vibe emphasizes independence" do
      vibe = SceneFramer.presence_vibe(:alone)
      assert String.contains?(vibe, "own")
    end

    test "with_partner mentions Louiza" do
      vibe = SceneFramer.presence_vibe(:with_partner)
      assert String.contains?(vibe, "Louiza")
    end

    test "group vibe mentions together" do
      vibe = SceneFramer.presence_vibe(:group)
      assert String.contains?(vibe, "people") or String.contains?(vibe, "together")
    end
  end
end
