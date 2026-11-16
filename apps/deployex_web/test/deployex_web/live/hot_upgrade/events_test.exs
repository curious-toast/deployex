defmodule DeployexWeb.HotUpgrade.EventsTest do
  use ExUnit.Case, async: true

  import DeployexWeb.HotUpgrade.Events

  test "keeps the progress and complete events of this host" do
    assert from_this_host?({:hot_upgrade_progress, Node.self(), "deployex", "Unpacking release"})
    assert from_this_host?({:hot_upgrade_complete, Node.self(), "deployex", :ok, "done"})
  end

  test "drops the events of another host and any other message" do
    refute from_this_host?({:hot_upgrade_progress, :other@host, "deployex", "Unpacking release"})
    refute from_this_host?({:hot_upgrade_complete, :other@host, "deployex", :ok, "done"})
    refute from_this_host?({:hot_upgrade_complete, Node.self(), "deployex", "done"})
    refute from_this_host?(:unrelated)
  end
end
