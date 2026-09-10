defmodule Deployer.SelfUpgrade.WorkerTest do
  use ExUnit.Case, async: true
  import Mox

  alias Deployer.SelfUpgrade.Worker

  setup :verify_on_exit!

  defp running, do: Application.spec(:foundation, :vsn) |> to_string()

  defp start(policy) do
    pid = start_supervised!({Worker, name: nil, policy: policy, interval_ms: :never})
    allow(Deployer.SelfUpgrade.SourceMock, self(), pid)
    allow(Deployer.SelfUpgrade.ExecutorMock, self(), pid)
    pid
  end

  test "no drift is a no-op" do
    pid = start(:hot_only)
    expect(Deployer.SelfUpgrade.SourceMock, :desired_version, fn -> {:ok, running()} end)
    assert :noop = Worker.reconcile(pid)
  end

  test "drift triggers a hot upgrade" do
    pid = start(:hot_only)
    expect(Deployer.SelfUpgrade.SourceMock, :desired_version, fn -> {:ok, "99.0.0"} end)
    expect(Deployer.SelfUpgrade.ExecutorMock, :hot_update, fn "99.0.0" -> :ok end)
    assert :ok = Worker.reconcile(pid)
  end

  test "hot_only does not restart when hot fails, and does not retry the failed version" do
    pid = start(:hot_only)
    expect(Deployer.SelfUpgrade.SourceMock, :desired_version, 2, fn -> {:ok, "99.0.0"} end)
    expect(Deployer.SelfUpgrade.ExecutorMock, :hot_update, 1, fn "99.0.0" -> {:error, :nope} end)
    assert {:error, _} = Worker.reconcile(pid)
    assert :noop = Worker.reconcile(pid)
  end

  test "allow_restart falls back to restart when hot fails" do
    pid = start(:allow_restart)
    expect(Deployer.SelfUpgrade.SourceMock, :desired_version, fn -> {:ok, "99.0.0"} end)
    expect(Deployer.SelfUpgrade.ExecutorMock, :hot_update, fn "99.0.0" -> {:error, :nope} end)
    expect(Deployer.SelfUpgrade.ExecutorMock, :restart_update, fn "99.0.0" -> :ok end)
    assert :ok = Worker.reconcile(pid)
  end

  test ":none source is a no-op" do
    pid = start(:hot_only)
    expect(Deployer.SelfUpgrade.SourceMock, :desired_version, fn -> :none end)
    assert :noop = Worker.reconcile(pid)
  end
end
