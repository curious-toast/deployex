defmodule Deployer.SelfUpgrade.WorkerTest do
  use ExUnit.Case, async: false
  import Mox
  import Mock
  import ExUnit.CaptureLog

  alias Deployer.HotUpgrade.Deployex
  alias Deployer.HotUpgrade.Progress
  alias Deployer.SelfUpgrade.Worker

  # The upgrade runs in a Task (a separate process), so the mocks must be callable
  # from any process, not just the test pid.
  setup :set_mox_global
  setup :verify_on_exit!

  defp running, do: Application.spec(:foundation, :vsn) |> to_string()

  # The worker runs the built command with System.cmd, so the tests hand it a real shell.
  defp sh(script), do: {:ok, {"sh", ["-c", script], [stderr_to_stdout: true]}}

  defp wait_until_idle(pid, tries \\ 50) do
    cond do
      is_nil(:sys.get_state(pid).task) ->
        :ok

      tries == 0 ->
        flunk("the upgrade task did not finish")

      true ->
        Process.sleep(20)
        wait_until_idle(pid, tries - 1)
    end
  end

  defp start(opts \\ [interval_ms: :never]) do
    start_supervised!({Task.Supervisor, name: Deployer.SelfUpgrade.TaskSupervisor})
    start_supervised!({Worker, Keyword.put_new(opts, :name, nil)})
  end

  test "no drift is a no-op" do
    pid = start()
    expect(Deployer.SelfUpgrade.SourceMock, :desired_version, fn -> {:ok, running()} end)
    assert :noop = Worker.reconcile(pid)
  end

  test "drift starts a hot upgrade and reports success" do
    Phoenix.PubSub.subscribe(Deployer.PubSub, "self_upgrade")
    pid = start()
    expect(Deployer.SelfUpgrade.SourceMock, :desired_version, fn -> {:ok, "99.0.0"} end)

    expect(Deployer.SelfUpgrade.ExecutorMock, :hot_upgrade_command, fn "99.0.0" ->
      sh("exit 0")
    end)

    assert :started = Worker.reconcile(pid)
    assert_receive {:self_upgrade, :hot_ok, %{version: "99.0.0"}}, 1_000
  end

  test "a second reconcile while upgrading is single-flight" do
    pid = start()
    # desired_version is only asked once: the in-flight guard short-circuits the second call.
    expect(Deployer.SelfUpgrade.SourceMock, :desired_version, fn -> {:ok, "99.0.0"} end)

    expect(Deployer.SelfUpgrade.ExecutorMock, :hot_upgrade_command, fn "99.0.0" ->
      sh("sleep 2")
    end)

    assert :started = Worker.reconcile(pid)
    assert :in_progress = Worker.reconcile(pid)
  end

  test "a self-upgrade from the dashboard is in progress, so the tick waits and latches nothing" do
    pid = start()

    with_mock Deployex, [:passthrough], progress: fn -> %Progress{state: :running} end do
      assert :in_progress = Worker.reconcile(pid)
    end

    expect(Deployer.SelfUpgrade.SourceMock, :desired_version, fn -> {:ok, "99.0.0"} end)

    expect(Deployer.SelfUpgrade.ExecutorMock, :hot_upgrade_command, fn "99.0.0" ->
      sh("exit 0")
    end)

    assert :started = Worker.reconcile(pid)
  end

  test "a run that starts after the tick refuses this one, and the version is not latched" do
    key = {__MODULE__, :other_run}
    on_exit(fn -> :persistent_term.erase(key) end)
    pid = start()

    with_mock Deployex, [:passthrough],
      progress: fn -> if :persistent_term.get(key, false), do: %Progress{state: :running} end do
      expect(Deployer.SelfUpgrade.SourceMock, :desired_version, 2, fn -> {:ok, "99.0.0"} end)

      # The other run starts while deployex.sh downloads, and its check refuses this one
      expect(Deployer.SelfUpgrade.ExecutorMock, :hot_upgrade_command, fn "99.0.0" ->
        :persistent_term.put(key, true)
        sh("echo refused by the run; exit 1")
      end)

      log =
        capture_log(fn ->
          assert :started = Worker.reconcile(pid)
          wait_until_idle(pid)
        end)

      assert log =~ "another hot upgrade is in progress, the next tick tries 99.0.0 again"
      assert log =~ "refused by the run"

      :persistent_term.put(key, false)

      expect(Deployer.SelfUpgrade.ExecutorMock, :hot_upgrade_command, fn "99.0.0" ->
        sh("exit 0")
      end)

      assert :started = Worker.reconcile(pid)
    end
  end

  test "a stuck upgrade is stopped by the backstop timeout" do
    Phoenix.PubSub.subscribe(Deployer.PubSub, "self_upgrade")
    pid = start(interval_ms: :never, upgrade_timeout_ms: 50)
    expect(Deployer.SelfUpgrade.SourceMock, :desired_version, fn -> {:ok, "99.0.0"} end)

    expect(Deployer.SelfUpgrade.ExecutorMock, :hot_upgrade_command, fn "99.0.0" ->
      sh("sleep 5")
    end)

    assert :started = Worker.reconcile(pid)
    assert_receive {:self_upgrade, :hot_failed, %{version: "99.0.0", reason: :timeout}}, 1_000
  end

  test "an executor that cannot build the command reports a failure" do
    Phoenix.PubSub.subscribe(Deployer.PubSub, "self_upgrade")
    pid = start()
    expect(Deployer.SelfUpgrade.SourceMock, :desired_version, fn -> {:ok, "99.0.0"} end)

    expect(Deployer.SelfUpgrade.ExecutorMock, :hot_upgrade_command, fn "99.0.0" ->
      {:error, :installer_outdated}
    end)

    assert :started = Worker.reconcile(pid)

    assert_receive {:self_upgrade, :hot_failed,
                    %{version: "99.0.0", reason: :installer_outdated}},
                   1_000
  end

  test "a failed hot upgrade stays on the current version and does not retry it" do
    Phoenix.PubSub.subscribe(Deployer.PubSub, "self_upgrade")
    pid = start()
    expect(Deployer.SelfUpgrade.SourceMock, :desired_version, 2, fn -> {:ok, "99.0.0"} end)

    expect(Deployer.SelfUpgrade.ExecutorMock, :hot_upgrade_command, 1, fn "99.0.0" ->
      sh("exit 3")
    end)

    assert :started = Worker.reconcile(pid)
    assert_receive {:self_upgrade, :hot_failed, %{version: "99.0.0", reason: {:exit, 3}}}, 1_000
    assert :noop = Worker.reconcile(pid)
  end

  test "force: true retries a latched version" do
    Phoenix.PubSub.subscribe(Deployer.PubSub, "self_upgrade")
    # Registered under the default name, so the documented Worker.reconcile(force: true) works.
    start(interval_ms: :never, name: Worker)
    expect(Deployer.SelfUpgrade.SourceMock, :desired_version, 3, fn -> {:ok, "99.0.0"} end)

    expect(Deployer.SelfUpgrade.ExecutorMock, :hot_upgrade_command, 2, fn "99.0.0" ->
      sh("exit 3")
    end)

    assert :started = Worker.reconcile()
    assert_receive {:self_upgrade, :hot_failed, %{version: "99.0.0"}}, 1_000
    assert :noop = Worker.reconcile()
    assert :started = Worker.reconcile(force: true)
    assert_receive {:self_upgrade, :hot_failed, %{version: "99.0.0"}}, 1_000
  end

  test ":none source is a no-op" do
    pid = start()
    expect(Deployer.SelfUpgrade.SourceMock, :desired_version, fn -> :none end)
    assert :noop = Worker.reconcile(pid)
  end

  test "source error is a no-op" do
    pid = start()
    expect(Deployer.SelfUpgrade.SourceMock, :desired_version, fn -> {:error, :boom} end)
    assert :noop = Worker.reconcile(pid)
  end

  test "tick reconciles and reschedules on a real timer" do
    Phoenix.PubSub.subscribe(Deployer.PubSub, "self_upgrade")
    pid = start(interval_ms: 60_000)
    expect(Deployer.SelfUpgrade.SourceMock, :desired_version, fn -> {:ok, "99.0.0"} end)

    expect(Deployer.SelfUpgrade.ExecutorMock, :hot_upgrade_command, fn "99.0.0" ->
      sh("exit 0")
    end)

    send(pid, :tick)

    assert_receive {:self_upgrade, :hot_ok, %{version: "99.0.0"}}, 1_000
  end
end
