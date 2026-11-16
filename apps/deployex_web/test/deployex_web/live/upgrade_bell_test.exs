defmodule DeployexWeb.UpgradeBellLiveTest do
  use DeployexWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mock

  alias Deployer.HotUpgrade.Progress

  @running %Progress{
    sname: "deployex",
    from_version: "0.10.0",
    to_version: "0.10.1",
    state: :running,
    messages: [
      "Starting upgrade for deployex...",
      "Unpacking release",
      "Creating relup file",
      "Checking release can be installed",
      "Resolving the runtime configuration"
    ]
  }

  test "shows nothing when no self-upgrade runs", %{conn: conn} do
    with_mock Deployer.HotUpgrade, [:passthrough], deployex_progress: fn -> nil end do
      {:ok, live, _html} = live_isolated(conn, DeployexWeb.UpgradeBellLive)

      refute has_element?(live, "#upgrade-bell-run")
    end
  end

  test "shows the step of a running self-upgrade, links to its page, and goes when it ends", %{
    conn: conn
  } do
    progress_fixture(@running)

    with_mock Deployer.HotUpgrade, [:passthrough], deployex_progress: &fixture_progress/0 do
      {:ok, live, _html} = live_isolated(conn, DeployexWeb.UpgradeBellLive)

      assert has_element?(live, ~s(a#upgrade-bell-run.dx-nitem-run[href="/hotupgrade"]))
      assert has_element?(live, "#upgrade-bell-run", "DeployEx hot upgrade")
      assert has_element?(live, "#upgrade-bell-run", "0.10.0 → 0.10.1")

      assert has_element?(
               live,
               "#upgrade-bell-run",
               "Step 5 of 8: Resolving the runtime configuration"
             )

      assert has_element?(live, "#upgrade-bell-leds.dx-leds-compact")

      progress_fixture(%{@running | state: :success})

      # Another host shares the PubSub, its events do not change this row
      send(live.pid, {:hot_upgrade_complete, :other@host, "deployex", :ok, "done"})
      assert has_element?(live, "#upgrade-bell-run")

      send(live.pid, {:hot_upgrade_complete, Node.self(), "deployex", :ok, "done"})
      refute has_element?(live, "#upgrade-bell-run")
    end
  end

  test "reads the run again on each step from this host, and ignores other messages", %{
    conn: conn
  } do
    progress_fixture(%{@running | messages: Enum.take(@running.messages, 2)})

    with_mock Deployer.HotUpgrade, [:passthrough], deployex_progress: &fixture_progress/0 do
      {:ok, live, _html} = live_isolated(conn, DeployexWeb.UpgradeBellLive)
      assert has_element?(live, "#upgrade-bell-run", "Step 2 of 8")

      progress_fixture(@running)
      send(live.pid, :unrelated)
      assert has_element?(live, "#upgrade-bell-run", "Step 2 of 8")

      send(
        live.pid,
        {:hot_upgrade_progress, Node.self(), "deployex", "Resolving the runtime configuration"}
      )

      assert has_element?(live, "#upgrade-bell-run", "Step 5 of 8")
    end
  end

  # A public table of the test, so the mocked deployex_progress/0 reads it from the LiveView process
  defp progress_fixture(progress) do
    if :ets.whereis(:upgrade_bell_fixture) == :undefined,
      do: :ets.new(:upgrade_bell_fixture, [:public, :named_table])

    :ets.insert(:upgrade_bell_fixture, {:progress, progress})
  end

  defp fixture_progress do
    case :ets.lookup(:upgrade_bell_fixture, :progress) do
      [{:progress, progress}] -> progress
      [] -> nil
    end
  end
end
