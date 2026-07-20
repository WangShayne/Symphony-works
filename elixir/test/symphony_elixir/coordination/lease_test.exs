defmodule SymphonyElixir.Coordination.LeaseTest do
  use SymphonyElixir.DataCase, async: false

  alias SymphonyElixir.Coordination

  test "only one unexpired orchestrator owner can hold the lease" do
    assert {:ok, lease_a} = Coordination.acquire_lease("holder-a", ttl_ms: 5_000)
    assert lease_a.holder_id == "holder-a"

    assert {:error, {:owned_by, "holder-a"}} =
             Coordination.acquire_lease("holder-b", ttl_ms: 5_000)

    assert :ok = Coordination.heartbeat(lease_a)
    assert :ok = Coordination.release_lease(lease_a)
    assert {:error, :lease_lost} = Coordination.heartbeat(lease_a)

    assert {:ok, lease_b} = Coordination.acquire_lease("holder-b", ttl_ms: 5_000)
    assert lease_b.holder_id == "holder-b"
  end

  test "an expired lease is reclaimed and rejects the stale handle" do
    assert {:ok, expired} = Coordination.acquire_lease("holder-a", ttl_ms: 20)
    Process.sleep(40)

    assert {:ok, reclaimed} = Coordination.acquire_lease("holder-b", ttl_ms: 5_000)
    assert reclaimed.holder_id == "holder-b"
    refute reclaimed.token == expired.token
    assert {:error, :lease_lost} = Coordination.heartbeat(expired)
    assert {:error, :lease_lost} = Coordination.release_lease(expired)
  end

  test "heartbeat extends ownership past the original expiry" do
    assert {:ok, lease} = Coordination.acquire_lease("holder-a", ttl_ms: 200)
    Process.sleep(120)
    assert :ok = Coordination.heartbeat(lease)
    Process.sleep(120)

    assert {:error, {:owned_by, "holder-a"}} =
             Coordination.acquire_lease("holder-b", ttl_ms: 5_000)
  end

  test "concurrent contenders observe one active owner" do
    parent = self()

    contenders =
      for holder <- ["holder-a", "holder-b"] do
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :acquire -> Coordination.acquire_lease(holder, ttl_ms: 5_000)
          end
        end)
      end

    contender_pids =
      for _index <- 1..2 do
        assert_receive {:ready, pid}
        pid
      end

    Enum.each(contender_pids, &send(&1, :acquire))
    results = Enum.map(contenders, &Task.await/1)

    assert [{:ok, winner}] = Enum.filter(results, &match?({:ok, _lease}, &1))
    assert [{:error, {:owned_by, owner}}] = Enum.reject(results, &match?({:ok, _lease}, &1))
    assert owner == winner.holder_id
  end

  test "same owner cannot reacquire while its lease is unexpired and malformed handles are rejected" do
    assert {:ok, first} = Coordination.acquire_lease("holder-a", ttl_ms: 5_000)

    assert {:error, {:owned_by, "holder-a"}} =
             Coordination.acquire_lease("holder-a", ttl_ms: 10_000)

    assert {:error, :lease_lost} = Coordination.heartbeat(%{})
    assert {:error, :lease_lost} = Coordination.heartbeat(%{first | name: "other"})
    assert {:error, :lease_lost} = Coordination.release_lease(%{})
    assert {:error, :lease_lost} = Coordination.release_lease(%{first | token: "invalid"})
  end
end
