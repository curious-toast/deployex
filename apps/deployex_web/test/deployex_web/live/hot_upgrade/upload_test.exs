defmodule DeployexWeb.HotUpgrade.UploadTest do
  use DeployexWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mox
  import Mock

  setup [
    :set_mox_global,
    :verify_on_exit!,
    :log_in_default_user
  ]

  # The messages of a self-upgrade, each one sent before its step runs
  @announced [
    "Starting upgrade for deployex...",
    "Unpacking release",
    "Creating relup file",
    "Checking release can be installed",
    "Resolving the runtime configuration",
    "Adding the runtime configuration to the relup",
    "Installing release",
    "Making release 1.1.0 permanent"
  ]

  describe "mount and render" do
    @tag :capture_log
    test "GET /hotupgrade renders the hot upgrade manager page", %{conn: conn} do
      Deployer.HotUpgradeMock
      |> expect(:subscribe_events, fn -> :ok end)

      {:ok, _live, html} = live(conn, ~p"/hotupgrade")

      assert html =~ ~s(<h1 class="text-[1.625rem] font-bold tracking-[-0.02em]">Hot Upgrade</h1>)
      assert html =~ "Upgrade DeployEx itself without downtime"

      # The sidebar shows the DeployEx version
      assert html =~
               ~s(<span id="sidebar-version" class="dx-mono">#{Application.spec(:deployex_web, :vsn)}</span>)

      # The page is for DeployEx, and points to the upgrade as code
      assert html =~ "This page upgrades DeployEx itself"
      version = Application.spec(:deployex_web, :vsn)

      assert html =~
               "https://github.com/deployex/deployex/blob/#{version}/guides/docs/hot-upgrades/README.md#method-4-terraform-iac-self-upgrade"

      assert html =~ "Upload Hot Upgrade Release"
      assert html =~ "Drop your .tar.gz file here or"
    end

    @tag :capture_log
    test "initializes with correct default assigns", %{conn: conn} do
      Deployer.HotUpgradeMock
      |> expect(:subscribe_events, fn -> :ok end)

      {:ok, live, _html} = live(conn, ~p"/hotupgrade")

      %{socket: socket} = :sys.get_state(live.pid)

      assert socket.assigns.downloaded_release == nil
      assert socket.assigns.dismissed == nil
      assert socket.assigns.current_path == "/hotupgrade"
    end
  end

  describe "file upload validation" do
    @tag :capture_log
    test "handles validate-upload event", %{conn: conn} do
      Deployer.HotUpgradeMock
      |> expect(:subscribe_events, fn -> :ok end)

      {:ok, live, _html} = live(conn, ~p"/hotupgrade")

      assert live
             |> render_hook("validate-upload", %{})
    end

    @tag :capture_log
    test "cancels file upload", %{conn: conn} do
      Deployer.HotUpgradeMock
      |> expect(:subscribe_events, fn -> :ok end)

      {:ok, live, _html} = live(conn, ~p"/hotupgrade")

      # This would typically be triggered by a user action
      assert live
             |> element("form#upload-form")
             |> render_change(%{})
    end
  end

  describe "release management" do
    @tag :capture_log
    @tag :capture_log
    test "remove-release event clears downloaded release", %{conn: conn} do
      Deployer.HotUpgradeMock
      |> expect(:subscribe_events, fn -> :ok end)

      Host.CommanderMock
      |> expect(:run, fn _command, _options ->
        {:ok, []}
      end)

      {:ok, live, _html} = live(conn, ~p"/hotupgrade")

      download_file(live, "deployex-0.9.0.tar.gz")

      live
      |> element("button", "Remove")
      |> render_click()

      %{socket: socket} = :sys.get_state(live.pid)

      assert socket.assigns.downloaded_release == nil
    end

    @tag :capture_log
    test "the release takes the upload box's place, and Remove brings the box back", %{conn: conn} do
      Deployer.HotUpgradeMock
      |> expect(:subscribe_events, fn -> :ok end)

      check_data = %{
        create_check_data()
        | jellyfish_info: [%{name: "deployer", type: "project", from: "1.0.0", to: "1.1.0"}]
      }

      with_mock Deployer.HotUpgrade, [:passthrough],
        deployex_check: fn _path -> {:ok, check_data} end,
        deployex_progress: fn -> nil end do
        {:ok, live, _html} = live(conn, ~p"/hotupgrade")
        assert has_element?(live, "#upload-form")

        download_file(live, "deployex-2.0.0.tar.gz")

        assert has_element?(live, "#hotupgrade-release", "deployex 1.1.0")
        assert has_element?(live, "details#hotupgrade-release-apps[open]")
        refute has_element?(live, "#upload-form")
        refute has_element?(live, "#hotupgrade-source-file")

        live |> element("button", "Remove") |> render_click()

        assert has_element?(live, "#upload-form")
        assert has_element?(live, "#hotupgrade-source-file")
      end
    end

    @tag :capture_log
    test "displays uploaded release information", %{conn: conn} do
      Deployer.HotUpgradeMock
      |> expect(:subscribe_events, fn -> :ok end)

      check_data = create_check_data()

      with_mock Deployer.HotUpgrade, [:passthrough],
        deployex_check: fn _path -> {:ok, check_data} end do
        {:ok, live, _html} = live(conn, ~p"/hotupgrade")

        filename = "deployex-2.0.0.tar.gz"
        download_file(live, filename)

        html = render(live)

        assert html =~ "Uploaded release"
        assert html =~ check_data.name
        assert html =~ to_string(check_data.to_version)
        assert html =~ filename
      end
    end

    @tag :capture_log
    test "displays error when release has error", %{conn: conn} do
      Deployer.HotUpgradeMock
      |> expect(:subscribe_events, fn -> :ok end)

      {:ok, live, _html} = live(conn, ~p"/hotupgrade")

      download_file(live, "deployex-0.1.0.gz")

      html = render(live)

      assert html =~ "not a .tar.gz file"
      refute html =~ "Apply Hot Upgrade"
    end

    @tag :capture_log
    test "displays error when the release is invalid", %{conn: conn} do
      Deployer.HotUpgradeMock
      |> expect(:subscribe_events, fn -> :ok end)

      with_mock Deployer.HotUpgrade, [:passthrough],
        deployex_check: fn _path -> {:error, :invalid} end do
        {:ok, live, _html} = live(conn, ~p"/hotupgrade")

        download_file(live, "deployex-0.2.0.tar.gz")

        html = render(live)

        assert html =~ "invalid release"
        refute html =~ "Apply Hot Upgrade"
      end
    end

    @tag :capture_log
    test "displays error when the file is not a deployex release", %{conn: conn} do
      Deployer.HotUpgradeMock
      |> expect(:subscribe_events, fn -> :ok end)

      with_mock Deployer.HotUpgrade, [:passthrough],
        deployex_check: fn _path -> {:error, :invalid_release_file} end do
        {:ok, live, _html} = live(conn, ~p"/hotupgrade")

        # A monitored application's package picked by mistake
        download_file(live, "myumbrella-0.3.1.tar.gz")

        html = render(live)

        assert html =~ "not a deployex release"
        refute html =~ "Apply Hot Upgrade"
      end
    end
  end

  describe "hot upgrade execution" do
    @tag :capture_log
    test "navigates to apply action when Apply button clicked", %{conn: conn} do
      Deployer.HotUpgradeMock
      |> expect(:subscribe_events, fn -> :ok end)

      check_data = create_check_data()

      with_mock Deployer.HotUpgrade, [:passthrough],
        deployex_check: fn _path -> {:ok, check_data} end,
        deployex_progress: fn -> nil end do
        {:ok, live, _html} = live(conn, ~p"/hotupgrade")

        filename = "deployex-2.0.0.tar.gz"
        download_file(live, filename)

        live
        |> element("#hotupgrade-apply-deployex", "Apply Hot Upgrade")
        |> render_click()

        assert_patch(live, ~p"/hotupgrade/apply")
      end
    end

    @tag :capture_log
    test "asks to confirm in the page, with no modal", %{conn: conn} do
      Deployer.HotUpgradeMock
      |> expect(:subscribe_events, fn -> :ok end)

      check_data = create_check_data()

      with_mock Deployer.HotUpgrade, [:passthrough],
        deployex_check: fn _path -> {:ok, check_data} end,
        deployex_progress: fn -> nil end do
        {:ok, live, _html} = live(conn, ~p"/hotupgrade")

        download_file(live, "deployex-3.0.0.tar.gz")

        html =
          live |> element("#hotupgrade-apply-deployex", "Apply Hot Upgrade") |> render_click()

        assert has_element?(live, ~s(#hotupgrade-ask[role="group"]))
        assert html =~ "Apply the hot upgrade to 1.1.0?"
        refute has_element?(live, "#hotupgrade-apply-deployex")
        refute html =~ "modal-open"

        # release_handler swaps code in the running VM, so nothing is stopped
        assert html =~ "DeployEx keeps running"
        assert html =~ "does not roll back on its own"
      end
    end

    @tag :capture_log
    test "cancels the confirm", %{conn: conn} do
      Deployer.HotUpgradeMock
      |> expect(:subscribe_events, fn -> :ok end)

      check_data = create_check_data()

      with_mock Deployer.HotUpgrade, [:passthrough],
        deployex_check: fn _path -> {:ok, check_data} end,
        deployex_progress: fn -> nil end do
        {:ok, live, _html} = live(conn, ~p"/hotupgrade")

        download_file(live, "deployex-3.0.0.tar.gz")
        live |> element("#hotupgrade-apply-deployex", "Apply Hot Upgrade") |> render_click()

        live |> element("#hotupgrade-cancel", "Cancel") |> render_click()

        assert_patch(live, ~p"/hotupgrade")
        refute has_element?(live, "#hotupgrade-ask")
        assert has_element?(live, "#hotupgrade-apply-deployex")
      end
    end

    @tag :capture_log
    test "executes, then shows the first step in the page at once", %{conn: conn} do
      test_pid = self()

      Deployer.HotUpgradeMock
      |> expect(:subscribe_events, fn -> :ok end)

      check_data = create_check_data()

      with_mock Deployer.HotUpgrade, [:passthrough],
        deployex_check: fn _path -> {:ok, check_data} end,
        deployex_progress: fn -> nil end,
        deployex_execute: fn _path, _opts ->
          send(test_pid, :upgrade_executed)
          :ok
        end do
        {:ok, live, _html} = live(conn, ~p"/hotupgrade")

        download_file(live, "deployex-3.0.0.tar.gz")
        live |> element("#hotupgrade-apply-deployex", "Apply Hot Upgrade") |> render_click()
        live |> element("#hotupgrade-execute", "Apply hot upgrade") |> render_click()

        assert_receive :upgrade_executed, 1_000
        assert_patch(live, ~p"/hotupgrade")

        html = render(live)
        assert html =~ "Step 1 of 8: Starting the upgrade"
        assert html =~ "1.0.0 → 1.1.0"
        refute has_element?(live, "#hotupgrade-apply-deployex")
        refute html =~ "modal-open"
      end
    end

    @tag :capture_log
    test "reports a release that the check refuses", %{conn: conn} do
      Deployer.HotUpgradeMock
      |> expect(:subscribe_events, fn -> :ok end)

      check_data = create_check_data()

      with_mock Deployer.HotUpgrade, [:passthrough],
        deployex_check: fn _path -> {:ok, check_data} end,
        deployex_progress: fn -> nil end,
        deployex_execute: fn _path, _opts -> {:error, :full_deployment} end do
        {:ok, live, _html} = live(conn, ~p"/hotupgrade")

        download_file(live, "deployex-3.0.0.tar.gz")
        live |> element("#hotupgrade-apply-deployex", "Apply Hot Upgrade") |> render_click()
        live |> element("#hotupgrade-execute", "Apply hot upgrade") |> render_click()

        assert render(live) =~ "Hot upgrade refused: full deployment only"
        refute has_element?(live, "#hotupgrade-progress")
      end
    end
  end

  describe "hot upgrade progress" do
    @tag :capture_log
    test "shows a run that started elsewhere, like deployex.sh, when the page opens", %{
      conn: conn
    } do
      Deployer.HotUpgradeMock
      |> expect(:subscribe_events, fn -> :ok end)

      # The server stamps every step, and a running run shows no ended time
      progress_fixture(%{
        run(:running, Enum.take(@announced, 5))
        | updated_at: ~U[2026-11-10 09:30:00Z]
      })

      with_mock Deployer.HotUpgrade, [:passthrough], deployex_progress: &fixture_progress/0 do
        {:ok, live, html} = live(conn, ~p"/hotupgrade")

        assert html =~ "Step 5 of 8: Resolving the runtime configuration"
        refute has_element?(live, "#hotupgrade-progress-at")

        assert has_element?(
                 live,
                 ~s([aria-label="Step 4, Done: Checking release can be installed"])
               )

        assert has_element?(
                 live,
                 ~s([aria-label="Step 5, In progress: Resolving the runtime configuration"])
               )

        assert has_element?(
                 live,
                 ~s([aria-label="Step 6, Pending: Adding the runtime configuration to the relup"])
               )
      end
    end

    @tag :capture_log
    test "follows each event from this host, and drops the ones from another host", %{
      conn: conn
    } do
      Deployer.HotUpgradeMock
      |> expect(:subscribe_events, fn -> :ok end)

      progress_fixture(run(:running, Enum.take(@announced, 2)))

      with_mock Deployer.HotUpgrade, [:passthrough], deployex_progress: &fixture_progress/0 do
        {:ok, live, _html} = live(conn, ~p"/hotupgrade")
        assert render(live) =~ "Step 2 of 8: Unpacking release"

        progress_fixture(run(:running, Enum.take(@announced, 3)))

        send(
          live.pid,
          {:hot_upgrade_progress, :other_node@localhost, "deployex", "Creating relup file"}
        )

        assert render(live) =~ "Step 2 of 8: Unpacking release"

        send(live.pid, {:hot_upgrade_progress, Node.self(), "deployex", "Creating relup file"})
        assert render(live) =~ "Step 3 of 8: Creating relup file"
      end
    end

    @tag :capture_log
    test "a success shows to the viewer who watched the run, and Done hides it", %{conn: conn} do
      Deployer.HotUpgradeMock
      |> expect(:subscribe_events, fn -> :ok end)

      progress_fixture(run(:running, Enum.take(@announced, 7)))

      with_mock Deployer.HotUpgrade, [:passthrough], deployex_progress: &fixture_progress/0 do
        {:ok, live, _html} = live(conn, ~p"/hotupgrade")

        success = "Hot upgrade applied successfully, 1.0.0 -> 1.1.0"
        progress_fixture(run(:success, @announced ++ [success]))
        send(live.pid, {:hot_upgrade_complete, Node.self(), "deployex", :ok, success})

        assert has_element?(live, ~s(#hotupgrade-progress [role="status"]), success)
        leds = live |> element("#hotupgrade-progress-leds") |> render()
        assert [_, _, _, _, _, _, _, _] = Regex.scan(~r/dx-led dx-led-done/, leds)

        live |> element("#hotupgrade-progress-done", "Done") |> render_click()

        refute has_element?(live, "#hotupgrade-progress")
      end
    end

    @tag :capture_log
    test "a success from before the page opened stays hidden, a failure shows", %{conn: conn} do
      Deployer.HotUpgradeMock
      |> stub(:subscribe_events, fn -> :ok end)

      progress_fixture(run(:success, @announced ++ ["Hot upgrade applied successfully"]))

      with_mock Deployer.HotUpgrade, [:passthrough], deployex_progress: &fixture_progress/0 do
        {:ok, live, _html} = live(conn, ~p"/hotupgrade")
        refute has_element?(live, "#hotupgrade-progress")

        failure = "Hot upgrade 1.0.0 -> 1.1.0 failed: {:error, :bad_relup}"

        progress_fixture(%{
          run(:error, Enum.take(@announced, 4) ++ [failure])
          | updated_at: ~U[2026-11-10 09:30:00Z]
        })

        {:ok, live, _html} = live(conn, ~p"/hotupgrade")

        assert has_element?(live, "#hotupgrade-progress-error", "Failed at step 4 of 8")
        # A finished run shows when it ended, so an old failure does not read as current
        ended_at = DeployexWeb.HostTime.format(~U[2026-11-10 09:30:00Z], "%Y-%m-%d %H:%M")
        assert has_element?(live, "#hotupgrade-progress-at", ended_at)
        assert has_element?(live, "#hotupgrade-progress-error", failure)

        assert has_element?(
                 live,
                 ~s([aria-label="Step 4, Failed: Checking release can be installed"])
               )
      end
    end

    @tag :capture_log
    test "hides the release once this host upgraded to it", %{conn: conn} do
      Deployer.HotUpgradeMock
      |> expect(:subscribe_events, fn -> :ok end)

      check_data = create_check_data()
      progress_fixture(run(:running, Enum.take(@announced, 7)))

      with_mock Deployer.HotUpgrade, [:passthrough],
        deployex_check: fn _path -> {:ok, check_data} end,
        deployex_progress: &fixture_progress/0 do
        {:ok, live, _html} = live(conn, ~p"/hotupgrade")

        download_file(live, "deployex-3.0.0.tar.gz")
        assert has_element?(live, "#hotupgrade-release")

        success = "Hot upgrade applied successfully, 1.0.0 -> 1.1.0"
        progress_fixture(run(:success, @announced ++ [success]))
        send(live.pid, {:hot_upgrade_complete, Node.self(), "deployex", :ok, success})

        refute has_element?(live, "#hotupgrade-release")
        assert has_element?(live, "#upload-form")
        assert has_element?(live, "#hotupgrade-progress")
      end
    end

    @tag :capture_log
    test "Done on a run that this viewer did not start keeps the viewer's release", %{conn: conn} do
      Deployer.HotUpgradeMock
      |> expect(:subscribe_events, fn -> :ok end)

      check_data = create_check_data()
      failure = "Hot upgrade 1.0.0 -> 1.1.0 failed: {:error, :bad_relup}"
      progress_fixture(run(:error, Enum.take(@announced, 4) ++ [failure]))

      with_mock Deployer.HotUpgrade, [:passthrough],
        deployex_check: fn _path -> {:ok, check_data} end,
        deployex_progress: &fixture_progress/0 do
        {:ok, live, _html} = live(conn, ~p"/hotupgrade")

        download_file(live, "deployex-3.0.0.tar.gz")
        live |> element("#hotupgrade-progress-done", "Done") |> render_click()

        refute has_element?(live, "#hotupgrade-progress")
        assert has_element?(live, "#hotupgrade-apply-deployex")
      end
    end

    @tag :capture_log
    test "hides Apply while a run is in progress", %{conn: conn} do
      Deployer.HotUpgradeMock
      |> expect(:subscribe_events, fn -> :ok end)

      check_data = create_check_data()
      progress_fixture(run(:running, Enum.take(@announced, 3)))

      with_mock Deployer.HotUpgrade, [:passthrough],
        deployex_check: fn _path -> {:ok, check_data} end,
        deployex_progress: &fixture_progress/0 do
        {:ok, live, _html} = live(conn, ~p"/hotupgrade")

        download_file(live, "deployex-3.0.0.tar.gz")

        refute has_element?(live, "#hotupgrade-apply-deployex")
      end
    end
  end

  describe "system info updates" do
    @tag :capture_log
    test "handles update_system_info message", %{conn: conn} do
      test_pid = self()

      Deployer.HotUpgradeMock
      |> expect(:subscribe_events, fn ->
        send(test_pid, {:liveview_pid, self()})
        :ok
      end)

      {:ok, live, _html} = live(conn, ~p"/hotupgrade")

      assert_receive {:liveview_pid, liveview_pid}, 1_000

      host_info = %Host.Info{
        source_node: Node.self(),
        host: "Linux",
        description: "Ubuntu 22.04",
        memory_free: 8_000_000_000,
        memory_total: 16_000_000_000,
        cpu: 45.2,
        cpus: 8
      }

      send(liveview_pid, {:update_system_info, host_info})

      html = render(live)

      # The top bar shows the host, and the page has no system bar of its own
      assert html =~ "8 cores"
      refute html =~ "Ubuntu 22.04"
    end
  end

  @tag :capture_log
  test "Try to access /hotupgrade/apply without valid release", %{conn: conn} do
    {:error, {:live_redirect, %{to: "/hotupgrade", flash: %{}}}} =
      live(conn, ~p"/hotupgrade/apply")
  end

  # Helper functions

  defp run(state, messages) do
    %Deployer.HotUpgrade.Progress{
      sname: "deployex",
      from_version: "1.0.0",
      to_version: "1.1.0",
      state: state,
      messages: messages
    }
  end

  # A public table of the test, so the mocked deployex_progress/0 reads it from the LiveView process
  defp progress_fixture(progress) do
    if :ets.whereis(:hot_upgrade_progress_fixture) == :undefined,
      do: :ets.new(:hot_upgrade_progress_fixture, [:public, :named_table])

    :ets.insert(:hot_upgrade_progress_fixture, {:progress, progress})
  end

  defp fixture_progress do
    case :ets.lookup(:hot_upgrade_progress_fixture, :progress) do
      [{:progress, progress}] -> progress
      [] -> nil
    end
  end

  defp create_check_data do
    %Deployer.HotUpgrade.Check{
      sname: "deployex",
      name: "deployex",
      language: "elixir",
      download_path: "/tmp/deployex-1.0.0.tar.gz",
      current_path: "",
      new_path: "",
      # Charlists, as Deployer.HotUpgrade.Application.do_check/1 returns them
      from_version: ~c"1.0.0",
      to_version: ~c"1.1.0"
    }
  end

  defp download_file(liveview, filename) do
    content = <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73>>

    avatar =
      file_input(liveview, "#upload-form", :hotupgrade, [
        %{
          last_modified: 1_594_171_879_000,
          name: filename,
          content: content,
          size: byte_size(content)
        }
      ])

    render_upload(avatar, filename) =~ "100%"
  end
end
