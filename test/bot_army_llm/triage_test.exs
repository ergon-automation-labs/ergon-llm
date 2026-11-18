defmodule BotArmyLlm.TriageTest do
  use ExUnit.Case, async: true
  @moduletag :core

  alias BotArmyLlm.Triage

  @now 1_700_000_000

  defp item(id, lane, attrs \\ %{}) do
    Map.merge(%{id: id, lane: lane, enqueued_at: @now}, attrs)
  end

  test "lane dominates a fresh arrival" do
    ids =
      [item("bg", "background"), item("int", "interactive"), item("urg", "urgent")]
      |> Triage.rank(@now)
      |> Enum.map(fn {i, _, _} -> i.id end)

    assert ids == ["urg", "int", "bg"]
  end

  test "a background item waiting two hours is promoted and overtakes a fresh interactive one" do
    old_bg = item("bg", "background", %{enqueued_at: @now - 7200})
    fresh_int = item("int", "interactive")

    [{first, _, reasons} | _] = Triage.rank([fresh_int, old_bg], @now)
    assert first.id == "bg"
    assert {:promoted_from, "background"} in reasons
  end

  test "a background item below the promotion age does not overtake interactive" do
    young_bg = item("bg", "background", %{enqueued_at: @now - 3000})
    fresh_int = item("int", "interactive")

    [{first, _, _} | _] = Triage.rank([young_bg, fresh_int], @now)
    assert first.id == "int"
  end

  test "aging never lifts an item past urgent, however long it waits" do
    very_old_bg = item("bg", "background", %{enqueued_at: @now - 10 * 24 * 3600})
    urgent = item("urg", "urgent")

    [{first, _, _} | _] = Triage.rank([very_old_bg, urgent], @now)
    assert first.id == "urg"
  end

  test "user sender beats automated within a lane; smaller requests go first" do
    user = item("user", "interactive", %{sender: :user})
    auto = item("auto", "interactive", %{sender: :automated})
    assert [{%{id: "user"}, _, _}, {%{id: "auto"}, _, _}] = Triage.rank([auto, user], @now)

    big = item("big", "interactive", %{est_tokens: 40_000})
    small = item("small", "interactive", %{est_tokens: 500})
    assert [{%{id: "small"}, _, _}, {%{id: "big"}, _, _}] = Triage.rank([big, small], @now)
  end

  test "score returns the reasons it used" do
    {_score, reasons} = Triage.score(item("x", "interactive", %{sender: :user}), @now + 90)
    assert {:lane, "interactive"} in reasons
    assert {:waited_s, 90} in reasons
    assert {:sender, 20} in reasons
  end

  test "ranking is deterministic on ties" do
    a = item("a", "background")
    b = item("b", "background")
    assert Enum.map(Triage.rank([b, a], @now), fn {i, _, _} -> i.id end) == ["a", "b"]
  end

  test "cloud mode allows everything; triage mode pins to local and holds cloud-only work" do
    assert Triage.route(item("c", "interactive"), :cloud) == :cloud
    assert Triage.route(item("l", "interactive", %{local_only: true}), :cloud) == :local
    assert Triage.route(item("c", "interactive"), :triage) == :local
    assert Triage.route(item("l", "interactive", %{local_only: true}), :triage) == :local
    assert Triage.route(item("k", "interactive", %{cloud_only: true}), :triage) == :waiting_for_cloud
  end

  test "shedding drops only the lowest-ranked background items, with a reason" do
    urgent = item("urg", "urgent")
    interactive = item("int", "interactive")
    bgs = for n <- 1..5, do: item("bg#{n}", "background", %{enqueued_at: @now - n})

    {kept, shed} = Triage.shed([urgent, interactive | bgs], @now, shed_bound: 4)

    # 7 items over a bound of 4: three background items go, the two oldest-waited stay.
    assert length(kept) == 4
    assert Enum.any?(kept, &(&1.id == "urg"))
    assert Enum.any?(kept, &(&1.id == "int"))
    assert length(shed) == 3
    assert Enum.all?(shed, fn {i, reason} -> i.lane == "background" and reason == :shed_background_bound end)
  end

  test "shedding under the bound sheds nothing" do
    assert {[_, _], []} = Triage.shed([item("a", "background"), item("b", "urgent")], @now, shed_bound: 10)
  end
end
