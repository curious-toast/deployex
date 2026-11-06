defmodule DeployexWeb.RecentEventsTest do
  use DeployexWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias DeployexWeb.RecentEvents
  alias Foundation.Notifications.Recent

  setup :log_in_default_user

  defp recent(event, payload),
    do: %Recent{id: 1, at: ~U[2026-10-28 14:20:00Z], event: event, payload: payload}

  describe "item/1" do
    test "describes each event the bell shows" do
      assert [
               %{
                 tone: :ghost,
                 title: "myerlangapp 0.8.2 ghosted",
                 href: "/logs/history?source=events&since=1793197200"
               }
             ] =
               RecentEvents.item(
                 recent("version_ghosted", %{name: "myerlangapp", version: "0.8.2", reason: nil})
               )

      assert [%{tone: :error, title: "myapp-abc pre_command failed", detail: "eval Migrate.run"}] =
               RecentEvents.item(
                 recent("pre_command_failed", %{
                   sname: "myapp-abc",
                   name: "myapp",
                   command: "eval Migrate.run"
                 })
               )

      assert [%{tone: :warning, title: "myapp-abc crash restart", detail: "2 crash restarts"}] =
               RecentEvents.item(
                 recent("crash_restart", %{sname: "myapp-abc", crash_restart_count: 2})
               )

      # History opens at the event, with the events and the logs of the instance it names
      assert [%{href: "/logs/history?source=events%2Cmyapp-abc&since=1793197200"}] =
               RecentEvents.item(
                 recent("crash_restart", %{sname: "myapp-abc", crash_restart_count: 2})
               )

      assert [%{href: "/logs/history?source=events%2Cmyapp-abc&since=1793197200"}] =
               RecentEvents.item(
                 recent("watchdog_threshold_exceeded", %{
                   node: :"myapp-abc@host",
                   action: :restart
                 })
               )

      assert [%{detail: "1 crash restart"}] =
               RecentEvents.item(
                 recent("crash_restart", %{sname: "myapp-abc", crash_restart_count: 1})
               )

      assert [%{tone: :warning, title: "myapp-abc process at 81% of the limit"}] =
               RecentEvents.item(
                 recent("watchdog_threshold_warning", %{
                   node: :"myapp-abc@host",
                   type: :process,
                   current_percentage: 81,
                   warning_threshold_percent: 80,
                   action: :warning
                 })
               )

      assert [%{tone: :error, detail: "restarted"}] =
               RecentEvents.item(
                 recent("watchdog_threshold_exceeded", %{
                   node: nil,
                   type: :atom,
                   current_percentage: 95,
                   action: :restart
                 })
               )

      assert [%{detail: "restart is off"}] =
               RecentEvents.item(recent("watchdog_threshold_exceeded", %{action: :no_restart}))

      assert [%{tone: :warning, title: "1 config change pending", detail: "replicas"}] =
               RecentEvents.item(
                 recent("config_changed", %{changes_count: 1, fields: [:replicas]})
               )

      assert [%{tone: :info, title: "2 config changes applied", detail: ""}] =
               RecentEvents.item(
                 recent("config_change_applied", %{changes_count: 2, fields: nil})
               )

      assert [%{tone: :error, title: "TLS certificate renewal failed"}] =
               RecentEvents.item(
                 recent("certificate_failed", %{app_name: "myapp", reason: :timeout})
               )

      assert [%{tone: :info, title: "TLS certificate renewed"}] =
               RecentEvents.item(recent("certificate_renewed", %{app_name: "myapp"}))

      assert [%{tone: :error, title: "myapp-abc deployment failed"}] =
               RecentEvents.item(
                 recent("deployment_complete", %{
                   sname: "myapp-abc",
                   status: :error,
                   message: "boom"
                 })
               )

      assert [%{detail: "lost"}] =
               RecentEvents.item(
                 recent("version_ghosted", %{name: "a", version: "1", reason: "lost"})
               )
    end

    test "shows successful deploys, hot upgrades and a warning back under its threshold" do
      assert [%{tone: :info, title: "myapp-abc hot upgraded", detail: "0.4.0 -> 0.4.1"}] =
               RecentEvents.item(
                 recent("deployment_complete", %{
                   sname: "myapp-abc",
                   status: :ok,
                   message: "Hot upgrade applied successfully, 0.4.0 -> 0.4.1",
                   from_version: "0.4.0",
                   to_version: "0.4.1"
                 })
               )

      assert [%{tone: :error, title: "myapp-abc hot upgrade failed", detail: "Hot upgrade " <> _}] =
               RecentEvents.item(
                 recent("deployment_complete", %{
                   sname: "myapp-abc",
                   status: :error,
                   message: "Hot upgrade 0.4.0 -> 0.4.1 failed: :timeout",
                   from_version: "0.4.0",
                   to_version: "0.4.1"
                 })
               )

      assert [%{tone: :info, title: "myapp-abc deployed", detail: "version 0.4.1"}] =
               RecentEvents.item(
                 recent("deployment_complete", %{
                   sname: "myapp-abc",
                   status: :ok,
                   version: "0.4.1"
                 })
               )

      assert [%{tone: :info, title: "myapp-abc process back to 40% of the limit"}] =
               RecentEvents.item(
                 recent("watchdog_threshold_warning", %{
                   node: :"myapp-abc@host",
                   type: :process,
                   current_percentage: 40,
                   warning_threshold_percent: 75,
                   action: :normalized
                 })
               )
    end

    test "skips the routine events, which only the Logs page lists" do
      assert [] = RecentEvents.item(recent("application_ready", %{sname: "myapp-abc"}))
      assert [] = RecentEvents.item(recent("deployment_started", %{sname: "myapp-abc"}))
      assert [] = RecentEvents.item(recent("deployment_shutdown", %{sname: "myapp-abc"}))
      assert [] = RecentEvents.item(recent("certificate_valid", %{app_name: "myapp"}))

      assert [] =
               RecentEvents.item(
                 recent("deployment_complete", %{
                   sname: "deployex",
                   status: :ok,
                   message: "shutdown"
                 })
               )
    end
  end

  describe "line/1" do
    test "gives every event a readable line for the Logs page" do
      lines = [
        {"deployment_started", %{sname: "myapp-abc", version: "0.4.1"},
         "myapp-abc deployment started · version 0.4.1"},
        {"deployment_started", %{sname: "deployex", version: "0.10.0"},
         "DeployEx started · version 0.10.0"},
        {"application_ready", %{sname: "myapp-abc", version: "0.4.1"},
         "myapp-abc ready · version 0.4.1"},
        {"deployment_shutdown", %{sname: "myapp-abc"}, "myapp-abc stopping"},
        {"deployment_shutdown", %{sname: "deployex"}, "DeployEx stopping"},
        {"deployment_complete", %{sname: "deployex", status: :ok, message: "shutdown"},
         "DeployEx stopped"},
        {"certificate_valid", %{app_name: "myapp", domains: ["myapp.com", "www.myapp.com"]},
         "TLS certificate valid · myapp: myapp.com, www.myapp.com"},
        {"deployment_complete",
         %{sname: "myapp-abc", status: :ok, from_version: "0.4.0", to_version: "0.4.1"},
         "myapp-abc hot upgraded · 0.4.0 -> 0.4.1"}
      ]

      for {event, payload, text} <- lines do
        assert {_tone, ^text} = RecentEvents.line(recent(event, payload))
      end

      # An event this version does not know yet still gets its name and its instance
      assert {:info, "some_new_event myapp-abc"} =
               RecentEvents.line(recent("some_new_event", %{sname: "myapp-abc"}))
    end
  end

  @tag :capture_log
  test "the bell on every page follows this host's new events", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/documentation")
    assert html =~ ~s(data-bell="bell")

    send(
      view.pid,
      {:recent_notification,
       recent("crash_restart", %{sname: "myapp-abc", crash_restart_count: 3})}
    )

    html = render(view)
    assert html =~ "myapp-abc crash restart"
    assert html =~ "3 crash restarts"
    assert html =~ ~s(data-bell-item="1")

    # An event the bell does not show changes nothing
    send(view.pid, {:recent_notification, recent("application_ready", %{sname: "myapp-abc"})})
    assert render(view) =~ "myapp-abc crash restart"
  end
end
