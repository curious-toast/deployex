defmodule DeployexWeb.Applications.IndexTest do
  use DeployexWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mox

  alias Deployer.Resources
  alias DeployexWeb.Fixture.Status, as: FixtureStatus
  alias DeployexWeb.HostTime

  setup [
    :set_mox_global,
    :verify_on_exit!,
    :log_in_default_user
  ]

  # An instance's details read its OTP distribution, which a test node does not answer
  setup do
    stub(Foundation.RpcMock, :call, fn _node, _module, _function, _args, _timeout ->
      {:badrpc, :nodedown}
    end)

    :ok
  end

  @ghosted_config %{
    last_ghosted_version: "4.6.0",
    last_ghosted_at: ~U[2026-10-28 14:20:00Z],
    mode: :automatic,
    manual_version: nil,
    versions: []
  }

  defp resources,
    do: %Resources{sname: "myphoenixapp-abc123", cpu: 12.0, cores: 10, memory: 849_346_560}

  # The Watchdog's samples of an app's instance, with its processes at 81% by default
  defp usage(name, samples \\ %{}) do
    FixtureStatus.watchdog_usage(
      FixtureStatus.node("#{name}-abc123"),
      Map.merge(
        %{process: {212_377, 262_144}, port: {40, 65_536}, atom: {61_204, 1_048_576}},
        samples
      )
    )
  end

  defp stub_monitoring(apps) do
    test_pid = self()

    Deployer.StatusMock
    |> expect(:monitoring, fn -> {:ok, [FixtureStatus.deployex() | apps]} end)
    |> expect(:subscribe, fn ->
      send(test_pid, {:liveview_pid, self()})
      :ok
    end)
    |> stub(:history_version_list, fn _name, _options -> FixtureStatus.versions() end)
  end

  @tag :capture_log
  test "GET /applications shows the host card and one row per app", %{conn: conn} do
    usage("myphoenixapp")

    stub_monitoring([
      FixtureStatus.application(%{
        name: "myphoenixapp",
        deployed_at: DateTime.add(DateTime.utc_now(), -2, :hour),
        resources: resources()
      })
    ])

    {:ok, view, html} = live(conn, ~p"/applications")

    assert html =~ "<h1"
    assert html =~ "Applications"
    assert html =~ "DeployEx"
    assert html =~ "1.2.3"
    assert has_element?(view, "#app-deployex", "1.2.3")
    assert html =~ "myphoenixapp"
    assert html =~ "4.5.6 · OTP 27 · Elixir 1.20"
    assert html =~ "1/1 running"
    assert html =~ "12%"
    assert html =~ "12% of 10 cores"
    assert html =~ "810 MB"
    assert html =~ "2h ago"
    assert html =~ "dx-dtag-full"
    # An instance near its process limit is a problem, so the app needs attention
    assert html =~ "1 app needs attention"

    # The problems of the instances show as a count on the row, which opens the instances
    assert html =~ "myphoenixapp-abc123 processes at 81% of the limit"
    assert html =~ ~s(aria-label="1 problem: myphoenixapp-abc123 processes)

    view |> element("#app-myphoenixapp-problems") |> render_click()
    assert has_element?(view, "#instance-myphoenixapp-abc123")
    view |> element("#app-myphoenixapp-problems") |> render_click()
    assert has_element?(view, "#instance-myphoenixapp-abc123")
    view |> element("#app-myphoenixapp-toggle") |> render_click()

    # The instances open with the chevron, each with its limits closed, also near a limit
    html = view |> element("#app-myphoenixapp-toggle") |> render_click()
    assert html =~ "myphoenixapp-abc123"
    assert html =~ "IEx shell"
    assert html =~ "myphoenixapp-abc123 processes at 81% of the limit"
    refute html =~ "212,377 of 262,144"

    html = view |> element("#instance-myphoenixapp-abc123-limits") |> render_click()
    assert html =~ "212,377 of 262,144"
    assert html =~ ~r/>Port<\/dt>\s*<dd class="dx-mono">\s*PORT 5678\s*</
    assert html =~ ~s(href="http://localhost:5678")
    assert html =~ ~s(data-copy="http://localhost:5678")
    assert html =~ ~r/data-copy="myphoenixapp-abc123@[^"]+"/
    assert html =~ "Copy the node name"
    assert html =~ "No restarts"

    html = view |> element("#instance-myphoenixapp-abc123-limits") |> render_click()
    refute html =~ "212,377 of 262,144"

    view |> element("#app-myphoenixapp-toggle") |> render_click()
    refute has_element?(view, "#instance-myphoenixapp-abc123-limits")
  end

  @tag :capture_log
  test "the attention chip adds the status tag, and Clear brings every app back", %{conn: conn} do
    usage("myphoenixapp")

    stub_monitoring([
      FixtureStatus.application(%{name: "calmapp"}),
      FixtureStatus.application(%{name: "myphoenixapp", resources: resources()})
    ])

    {:ok, view, html} = live(conn, ~p"/applications")
    assert html =~ "1 app needs attention"
    assert has_element?(view, "#app-calmapp")

    view |> element("#apps-attention") |> render_click()
    assert_patch(view, "/applications?filter=status%3Aattention")
    html = render(view)
    assert html =~ ~r/id="apps-attention"[^>]*aria-pressed="true"/
    assert html =~ "status: needs attention"
    refute has_element?(view, "#app-calmapp")
    # DeployEx counts as a row of the list
    assert html =~ "1 of 3 apps match."

    view |> element("#apps-show-all") |> render_click()
    assert_patch(view, ~p"/applications")
    assert has_element?(view, "#app-calmapp")
  end

  @tag :capture_log
  test "an instance at its restart threshold shows under the collapsed row, and opens", %{
    conn: conn
  } do
    usage("myphoenixapp", %{process: {95, 100}})
    stub_monitoring([FixtureStatus.application(%{name: "myphoenixapp", resources: resources()})])

    {:ok, view, html} = live(conn, ~p"/applications")
    assert html =~ "myphoenixapp-abc123 processes at 95% of the limit"
    refute has_element?(view, "#instance-myphoenixapp-abc123")

    view |> element("#app-myphoenixapp-urgent-0 button", "Show instance") |> render_click()
    assert has_element?(view, ~s(#instance-myphoenixapp-abc123-limits[aria-expanded="true"]))
  end

  @tag :capture_log
  test "the apps that need attention come worst first", %{conn: conn} do
    usage("anear")

    stub_monitoring([
      FixtureStatus.application(%{name: "anear", resources: resources()}),
      FixtureStatus.application(
        %{name: "zdown", language: "erlang", status: :idle},
        @ghosted_config
      )
    ])

    {:ok, view, _html} = live(conn, ~p"/applications?filter=status:attention")
    html = render(view)
    {down, _} = :binary.match(html, ~s(id="app-zdown"))
    {near, _} = :binary.match(html, ~s(id="app-anear"))
    assert down < near
  end

  @tag :capture_log
  test "tags in the URL filter the apps, and an older app link is an app tag", %{conn: conn} do
    apps = [
      FixtureStatus.application(%{name: "calmapp", language: "erlang"}),
      FixtureStatus.application(%{name: "myphoenixapp"})
    ]

    stub_monitoring(apps)
    {:ok, view, html} = live(conn, ~p"/applications?app=myphoenixapp")
    assert has_element?(view, "#app-myphoenixapp")
    refute has_element?(view, "#app-calmapp")
    assert html =~ "app: myphoenixapp"
    assert html =~ ~s(aria-label="Remove the filter app: myphoenixapp")
    assert has_element?(view, ~s(#app-myphoenixapp-toggle[aria-expanded="true"]))

    # Clear shows every app, collapsed
    view |> element("#apps-show-all") |> render_click()
    assert has_element?(view, "#app-calmapp")
    assert has_element?(view, ~s(#app-myphoenixapp-toggle[aria-expanded="false"]))

    stub_monitoring(apps)
    {:ok, view, html} = live(conn, ~p"/applications?filter=runtime:erlang,runtime:gleam")
    assert has_element?(view, "#app-calmapp")
    refute has_element?(view, "#app-myphoenixapp")
    assert html =~ "1 of 3 apps match."

    stub_monitoring(apps)
    {:ok, _view, html} = live(conn, ~p"/applications?filter=runtime:gleam")
    assert html =~ "No app matches these filters."
    refute html =~ "apps-empty"
  end

  @tag :capture_log
  test "GET /applications shows a ghosted version under its app, and clears it after a confirmation",
       %{conn: conn} do
    test_pid = self()

    stub_monitoring([
      FixtureStatus.application(
        %{name: "myerlangapp", language: "erlang", status: :idle},
        @ghosted_config
      )
    ])

    Deployer.StatusMock
    |> stub(:remove_ghosted_version, fn "myerlangapp", "4.6.0" ->
      send(test_pid, :removed)
      {:ok, []}
    end)

    {:ok, view, html} = live(conn, ~p"/applications")

    assert html =~ "1 app needs attention"
    assert html =~ "4.6.0 failed and is ghosted"
    assert html =~ "No earlier version runs on this host, so the app is down."
    assert html =~ "dx-callout-error"
    assert html =~ "0/1 running"
    assert html =~ "dx-dtag-fail"
    assert html =~ HostTime.format(~U[2026-10-28 14:20:00Z], "%H:%M")

    # It asks first, and Cancel clears nothing
    html = view |> element("#app-myerlangapp-clear-ghosted") |> render_click()
    assert html =~ "Clear ghosted 4.6.0?"
    view |> element("#app-myerlangapp-clear-ghosted-cancel") |> render_click()
    refute_received :removed
    assert render(view) =~ "4.6.0 failed and is ghosted"

    # The confirmation clears it at once, so a page that closes next does not lose it
    view |> element("#app-myerlangapp-clear-ghosted") |> render_click()
    html = view |> element("#app-myerlangapp-clear-ghosted-confirm") |> render_click()
    assert_received :removed
    assert html =~ "Cleared ghosted 4.6.0"

    send(view.pid, {:clear_shown, "myerlangapp"})
    assert render(view) =~ "4.6.0 failed and is ghosted"
  end

  @tag :capture_log
  test "DeployEx comes first and opens like an app, and an app filter hides it", %{conn: conn} do
    stub_monitoring([FixtureStatus.application(%{name: "myphoenixapp"})])

    {:ok, view, html} = live(conn, ~p"/applications")
    {deployex, _} = :binary.match(html, ~s(id="app-deployex"))
    {app, _} = :binary.match(html, ~s(id="app-myphoenixapp"))
    assert deployex < app

    html = view |> element("#app-deployex-toggle") |> render_click()
    assert html =~ ~s(id="instance-deployex")
    refute has_element?(view, "#instance-deployex-restart")
    refute html =~ "Restart all…"
    assert has_element?(view, "#app-deployex-config", "issued by")

    stub_monitoring([FixtureStatus.application(%{name: "myphoenixapp"})])
    {:ok, view, _html} = live(conn, ~p"/applications?filter=app:myphoenixapp")
    refute has_element?(view, "#app-deployex")
    assert has_element?(view, "#app-myphoenixapp")

    stub_monitoring([FixtureStatus.application(%{name: "myphoenixapp"})])
    {:ok, view, html} = live(conn, ~p"/applications?filter=app:deployex")
    assert has_element?(view, "#app-deployex")
    assert html =~ "1 of 2 apps match."
  end

  @tag :capture_log
  test "an instance's OTP distribution opens under its details, with the nodes it is connected to",
       %{
         conn: conn
       } do
    node = FixtureStatus.node("myphoenixapp-abc123")

    stub(Foundation.RpcMock, :call, fn
      ^node, :init, :get_arguments, [], _timeout ->
        [proto_dist: [[~c"inet_tls"]]]

      ^node, :erlang, :nodes, _args, _timeout ->
        [{Node.self(), %{node_type: :visible}}]
    end)

    stub_monitoring([FixtureStatus.application(%{name: "myphoenixapp"})])
    {:ok, view, _html} = live(conn, ~p"/applications?app=myphoenixapp")

    html = view |> element("#instance-myphoenixapp-abc123-limits") |> render_click()
    refute html =~ "TLS, visible node"
    assert has_element?(view, ~s(#instance-myphoenixapp-abc123-otp [aria-label="OTP connected"]))

    html = view |> element("#instance-myphoenixapp-abc123-distribution") |> render_click()
    assert html =~ "TLS, visible node"
    assert html =~ ~r/DeployEx:<\/span>\s*<span class="dx-mono">/

    html = view |> element("#instance-myphoenixapp-abc123-distribution") |> render_click()
    refute html =~ "TLS, visible node"
  end

  @tag :capture_log
  test "an instance's details read no distribution until its section opens", %{conn: conn} do
    test_pid = self()

    stub(Foundation.RpcMock, :call, fn _node, :init, :get_arguments, [], _timeout ->
      send(test_pid, :distribution_read)
      {:badrpc, :nodedown}
    end)

    stub_monitoring([FixtureStatus.application(%{name: "myphoenixapp"})])
    {:ok, view, _html} = live(conn, ~p"/applications?filter=instance:myphoenixapp-abc123")
    render_patch(view, ~p"/applications?filter=instance:myphoenixapp-abc123,runtime:elixir")
    refute_received :distribution_read

    html = view |> element("#instance-myphoenixapp-abc123-distribution") |> render_click()
    assert_received :distribution_read
    assert html =~ "The node did not answer."
  end

  @tag :capture_log
  test "a running instance that DeployEx cannot reach shows under the row, and opens", %{
    conn: conn
  } do
    stub_monitoring([FixtureStatus.application(%{name: "myphoenixapp", otp: :not_connected})])

    {:ok, view, html} = live(conn, ~p"/applications")
    assert html =~ "myphoenixapp-abc123 runs, but DeployEx cannot connect to it over OTP"
    assert html =~ "Check the cookie and the TLS distribution settings."

    view |> element("#app-myphoenixapp-urgent-0 button", "Show instance") |> render_click()
    assert has_element?(view, ~s(#instance-myphoenixapp-abc123-limits[aria-expanded="true"]))

    # The instance row shows the OTP state at a glance
    assert has_element?(
             view,
             ~s(#instance-myphoenixapp-abc123-otp [aria-label^="OTP not connected"])
           )
  end

  @tag :capture_log
  test "a restart count lists the latest restarts, each a link to the logs at its time", %{
    conn: conn
  } do
    at = ~U[2026-10-28 15:40:00Z]

    stub_monitoring([
      FixtureStatus.application(%{
        name: "myphoenixapp",
        force_restart_count: 1,
        watchdog_restart_count: 1,
        restarts: [%{at: at, cause: :watchdog, detail: "process 91%"}]
      })
    ])

    {:ok, view, html} = live(conn, ~p"/applications")

    assert html =~ ~s(aria-label="1 restart: 1 by the watchdog")
    assert html =~ "watchdog, process 91%"

    href =
      "/logs/history?" <>
        URI.encode_query(source: "events,myphoenixapp-abc123", since: DateTime.to_unix(at))

    view
    |> element(~s(#app-myphoenixapp-restarts a[href="#{href}"]))
    |> render_click()

    assert_redirect(view, href)
  end

  @tag :capture_log
  test "GET /applications restarts an instance after an inline confirmation", %{conn: conn} do
    test_pid = self()
    stub_monitoring([FixtureStatus.application(%{name: "myphoenixapp"})])

    Deployer.MonitorMock
    |> expect(:restart, fn "myphoenixapp-abc123", [cause: :operator] ->
      send(test_pid, :restarted)
      :ok
    end)

    {:ok, view, _html} = live(conn, ~p"/applications")
    view |> element("#app-myphoenixapp-toggle") |> render_click()

    html = view |> element("#instance-myphoenixapp-abc123-restart") |> render_click()
    assert html =~ "Restart myphoenixapp-abc123?"

    html = view |> element("button", "Cancel") |> render_click()
    refute html =~ "Restart myphoenixapp-abc123?"

    view |> element("#instance-myphoenixapp-abc123-restart") |> render_click()
    html = view |> element("#instance-myphoenixapp-abc123-restart-confirm") |> render_click()

    assert_receive :restarted
    assert html =~ "Restart sent"

    # The note goes after a few seconds
    send(view.pid, {:clear_sent, "myphoenixapp-abc123"})
    refute render(view) =~ "Restart sent"
  end

  @tag :capture_log
  test "GET /applications restarts every instance of an app after an inline confirmation", %{
    conn: conn
  } do
    stub_monitoring([FixtureStatus.application(%{name: "myphoenixapp"})])

    {:ok, view, _html} = live(conn, ~p"/applications")
    view |> element("#app-myphoenixapp-toggle") |> render_click()

    html = view |> element("#app-myphoenixapp-restart-all") |> render_click()
    assert html =~ "Restart every instance of myphoenixapp?"

    html = view |> element("#app-myphoenixapp-restart-all-confirm") |> render_click()
    assert html =~ "Restarting every instance of myphoenixapp"
  end

  @tag :capture_log
  test "GET /applications shows placeholder rows until it reads the apps, not the empty state", %{
    conn: conn
  } do
    stub_monitoring([])

    # The first render, before the page connects, has not read the apps yet
    html = conn |> get(~p"/applications") |> html_response(200)
    assert html =~ ~s(id="apps-loading")
    refute html =~ "No applications on this host"

    {:ok, _view, html} = live(conn, ~p"/applications")
    refute html =~ ~s(id="apps-loading")
    assert html =~ "No applications on this host"
  end

  @tag :capture_log
  test "GET /applications restarts DeployEx after an inline confirmation", %{conn: conn} do
    stub_monitoring([])

    {:ok, view, html} = live(conn, ~p"/applications")
    assert html =~ "No applications on this host"
    version = Application.spec(:deployex_web, :vsn)
    guides = "https://github.com/deployex/deployex/blob/#{version}/guides/docs"
    assert html =~ ~s(href="#{guides}/local-elixir/README.md")
    assert html =~ ~s(href="#{guides}/yaml/README.md")

    html = view |> element("#host-restart") |> render_click()
    assert html =~ "Restart DeployEx?"

    # The DeployEx process this test runs in is not the one the kill looks for
    stub(Host.CommanderMock, :run, fn _command, _options -> {:ok, []} end)

    assert ExUnit.CaptureLog.capture_log(fn ->
             view |> element("#host-restart-confirm") |> render_click()
           end) =~ "Deployex was requested to terminate"

    refute render(view) =~ "Restart DeployEx?"
  end

  @tag :capture_log
  test "GET /applications follows this host's status updates only", %{conn: conn} do
    stub_monitoring([FixtureStatus.application(%{name: "myphoenixapp"})])

    {:ok, view, _html} = live(conn, ~p"/applications")
    assert_receive {:liveview_pid, pid}

    send(pid, {:monitoring_app_updated, :other@host, []})
    assert render(view) =~ "myphoenixapp"

    send(pid, {:monitoring_app_updated, Node.self(), [FixtureStatus.deployex()]})
    refute render(view) =~ "myphoenixapp"
  end

  @tag :capture_log
  test "GET /applications?app opens the app, and the instance's limits", %{conn: conn} do
    FixtureStatus.watchdog_usage(FixtureStatus.node("myphoenixapp-abc123"), %{port: {40, 65_536}})
    stub_monitoring([FixtureStatus.application(%{name: "myphoenixapp", resources: resources()})])

    {:ok, _view, html} =
      live(conn, ~p"/applications?app=myphoenixapp&instance=myphoenixapp-abc123")

    assert html =~ "myphoenixapp-abc123"
    assert html =~ "40 of 65,536"
  end

  @tag :capture_log
  test "GET /applications shows each failed pre_command as code", %{conn: conn} do
    stub_monitoring([
      FixtureStatus.application(%{
        name: "myphoenixapp",
        status: :pre_commands,
        otp: :not_connected,
        version: "4.7.0",
        failed_pre_commands: ["eval Migrate.run()", "eval Seed.run()"]
      })
    ])

    {:ok, view, html} = live(conn, ~p"/applications")

    assert html =~ "pre_commands for 4.7.0 failed"
    assert has_element?(view, ".dx-callout-cmds code.dx-cmd", "eval Migrate.run()")
    assert has_element?(view, ".dx-callout-cmds code.dx-cmd", "eval Seed.run()")
  end

  @tag :capture_log
  test "GET /applications shows the starting and pre_commands states", %{conn: conn} do
    stub_monitoring([
      FixtureStatus.application(%{name: "myphoenixapp", status: :pre_commands, version: "4.7.0"})
    ])

    {:ok, view, html} = live(conn, ~p"/applications")

    # A connected instance runs a hot upgrade's pre_commands, and still counts as running
    assert html =~ "Running the hot upgrade&#39;s pre_commands"
    assert html =~ "myphoenixapp-abc123 keeps running 4.7.0 until the upgrade installs."
    assert html =~ "1/1 running"
    html = view |> element("#app-myphoenixapp-toggle") |> render_click()
    assert html =~ "pre_commands 4.7.0"

    html = view |> element("#instance-myphoenixapp-abc123-limits") |> render_click()
    assert html =~ "No reading yet."
  end
end
