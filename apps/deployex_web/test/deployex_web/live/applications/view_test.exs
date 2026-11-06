defmodule DeployexWeb.ApplicationsLive.ViewTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Deployer.Resources
  alias Deployer.Status
  alias DeployexWeb.ApplicationsLive.View
  alias DeployexWeb.HostTime
  alias DeployexWeb.UI.Tags
  alias Foundation.Certificates.PublicKey
  alias Sentinel.Watchdog
  alias Sentinel.Watchdog.Data

  @now ~U[2026-10-28 16:00:00Z]

  defp child(attrs) do
    sname = Map.get(attrs, :sname, "myapp-abc")

    Map.merge(
      %Status{
        name: "myapp",
        sname: sname,
        node: :"#{sname}@host",
        otp: :connected,
        version: "1.0.0",
        status: :running,
        last_deployment: :full_deployment,
        crash_restart_count: 0,
        force_restart_count: 0,
        uptime: "2h ago",
        otp_version: "29",
        elixir_version: "1.20.4",
        certificates: []
      },
      attrs
    )
  end

  defp app(children, attrs \\ %{}) do
    Map.merge(
      %Status{
        name: "myapp",
        language: "elixir",
        replicas: length(children),
        children: children,
        config: %{
          last_ghosted_version: "-/-",
          mode: :automatic,
          manual_version: nil,
          versions: []
        }
      },
      attrs
    )
  end

  # The Watchdog's sample and config of one resource, watched with its defaults unless the config says else
  defp watched(count, limit, config \\ %{}),
    do: {%Data{current: count, limit: limit}, Map.merge(%Watchdog{}, config)}

  # The usage of the first instance, myapp-abc
  defp usage(resources), do: %{:"myapp-abc@host" => resources}

  defp severity(app, usage \\ %{}),
    do: app |> List.wrap() |> View.apps(usage, @now) |> hd() |> Map.fetch!(:severity)

  test "leaves DeployEx out and builds a row for each app" do
    assert [%{name: "myapp", status: %{text: "1/1 running", tone: :success}}] =
             View.apps([%Status{name: "deployex"}, app([child(%{})])], %{}, @now)
  end

  test "sums CPU and memory over the instances, with -- when nothing was read" do
    children = [
      child(%{resources: %Resources{cpu: 3.0, cores: 10, memory: 2_147_483_648}}),
      child(%{
        sname: "myapp-def",
        resources: %Resources{cpu: 4.25, cores: 10, memory: 1_073_741_824}
      })
    ]

    assert [%{cpu: "7%", cpu_tip: "7% of 10 cores", memory: "3.0 GB"}] =
             View.apps([app(children)], %{}, @now)

    assert [%{cpu: "--", cpu_tip: nil, memory: "--", instances: [%{cpu: "--", cpu_tip: nil}]}] =
             View.apps([app([child(%{})])], %{}, @now)
  end

  test "an idle instance's CPU below 1% keeps one decimal, and names its scale" do
    idle = child(%{resources: %Resources{cpu: 0.04, cores: 10, memory: 1_048_576}})

    assert [%{cpu: "<0.1%", instances: [%{cpu: "<0.1%", cpu_tip: "<0.1% of 10 cores"}]}] =
             View.apps([app([idle])], %{}, @now)

    assert View.cpu_text(0.0) == "0%"
    assert View.cpu_text(0.36) == "0.4%"
    assert View.cpu_text(0.96) == "1%"
    assert View.cpu_text(12.4) == "12%"
  end

  test "the status follows the running instances" do
    assert [%{status: %{text: "0/1 running", tone: :error}}] =
             View.apps([app([child(%{status: :idle})])], %{}, @now)

    assert [%{status: %{tone: :warning}, instances: [_, %{status: %{text: "starting"}}]}] =
             View.apps(
               [app([child(%{}), child(%{sname: "myapp-def", status: :starting})])],
               %{},
               @now
             )

    assert [%{status: %{text: "1/2 running", tone: :warning}}] =
             View.apps(
               [app([child(%{}), child(%{sname: "myapp-def", status: :idle})])],
               %{},
               @now
             )
  end

  test "the last deploy is the newest one, hot or full, with its age" do
    children = [
      child(%{deployed_at: ~U[2026-10-28 14:00:00Z]}),
      child(%{
        sname: "myapp-def",
        last_deployment: :hot_upgrade,
        deployed_at: ~U[2026-10-28 15:59:30Z]
      })
    ]

    assert [%{deploy: %{type: :hot, when: "now"}}] = View.apps([app(children)], %{}, @now)

    assert [%{deploy: %{type: :full, when: "2h ago"}}] =
             View.apps([app([hd(children)])], %{}, @now)

    assert [%{deploy: nil}] = View.apps([app([child(%{})])], %{}, @now)
  end

  test "a version ghosted after the last deploy is the alert, and the rest keeps running" do
    config = %{last_ghosted_version: "1.1.0", last_ghosted_at: ~U[2026-10-28 15:00:00Z]}
    ghosted_at = HostTime.format(~U[2026-10-28 15:00:00Z], "%H:%M")
    children = [child(%{deployed_at: ~U[2026-10-28 14:00:00Z]})]

    assert [
             %{
               alert: %{kind: :ghosted, blocking: false, text: text},
               deploy: %{type: :ghosted, when: ^ghosted_at}
             } = row
           ] =
             View.apps([app(children, %{config: config})], %{}, @now)

    assert text == "1.1.0 failed and is ghosted. 1.0.0 keeps running, so the app is up."
    assert %{tone: :warning, title: "1.1.0 failed and is ghosted"} = row.alert
    # It needs attention, and nothing is blocked
    assert View.attention([row]) == %{count: 1, blocking: false}

    # A version ghosted before the last deploy is history, not an alert
    old = %{config | last_ghosted_at: ~U[2026-10-28 13:00:00Z]}
    assert [%{alert: nil}] = View.apps([app(children, %{config: old})], %{}, @now)
  end

  test "the notes list the TLS expiry, the limits near the end and the crashes" do
    usage =
      usage(%{
        process: watched(950, 1_000),
        port: watched(0, 65_536),
        atom: watched(200_000, 1_048_576)
      })

    children = [
      child(%{last_crash_at: ~U[2026-10-28 14:31:00Z]}),
      child(%{sname: "myapp-def"})
    ]

    certificates = [%PublicKey{expires_in_days: 5}, %PublicKey{expires_in_days: 20}]

    assert [%{notes: notes, instances: [first | _], problems: problems}] =
             View.apps([app(children, %{certificates: certificates})], usage, @now)

    assert %{tone: :error, text: "TLS certificate expires in 5 days"} in notes
    assert %{tone: :warning, text: "TLS certificate expires in 20 days"} in notes
    assert %{tone: :warning, text: "myapp-abc processes at 95% of the limit"} in notes
    crashed = HostTime.format(~U[2026-10-28 14:31:00Z], "%H:%M")
    assert %{tone: :warning, text: "myapp-abc crash restart at #{crashed}"} in notes

    # The crash at 14:31 is more than an hour old, so it is a note and no problem
    assert problems == [
             "TLS certificate expires in 5 days",
             "TLS certificate expires in 20 days",
             "myapp-abc processes at 95% of the limit"
           ]

    assert [%{level: 2, percent_text: "95%"}, %{percent_text: "0%"}, %{percent_text: "19%"}] =
             first.limits
  end

  test "an instance below the warning thresholds has no warning" do
    usage =
      usage(%{
        process: watched(100, 1_000),
        port: watched(8, 65_536),
        atom: watched(850, 1_000)
      })

    assert [
             %{
               instances: [
                 %{
                   warnings: ["atoms at 85% of the limit"],
                   limits: [%{level: 0}, %{level: 0, percent_text: "<1%"}, %{level: 1}]
                 }
               ]
             }
           ] =
             View.apps([app([child(%{})])], usage, @now)
  end

  test "restarts count crashes apart from the restarts an operator or the watchdog asked for" do
    children = [
      child(%{
        crash_restart_count: 2,
        force_restart_count: 1,
        watchdog_restart_count: 1,
        restarts: [
          %{at: ~U[2026-10-28 15:40:00Z], cause: :watchdog, detail: "process 91%"},
          %{at: ~U[2026-10-28 14:31:00Z], cause: :crash, detail: nil}
        ]
      }),
      child(%{
        sname: "myapp-def",
        force_restart_count: 1,
        restarts: [%{at: ~U[2026-10-28 15:10:00Z], cause: :operator, detail: nil}]
      }),
      child(%{sname: "myapp-ghi", crash_restart_count: 1, restarts: []})
    ]

    assert [%{restarts: app_restarts, instances: [watched, operated, none]}] =
             View.apps([app(children)], %{}, @now)

    assert %{count: 5, crash: true, totals: "3 crashes, 1 by an operator, 1 by the watchdog"} =
             app_restarts

    # The latest restarts of every instance, newest first, each a link to the logs at its time
    assert [
             %{sname: "myapp-abc", text: "watchdog, process 91%", href: href},
             %{sname: "myapp-def", text: "operator"},
             %{sname: "myapp-abc", text: "crash"}
           ] = app_restarts.latest

    assert href ==
             "/logs/history?" <>
               URI.encode_query(
                 source: "events,myapp-abc",
                 since: DateTime.to_unix(~U[2026-10-28 15:40:00Z])
               )

    assert hd(app_restarts.latest).time == HostTime.format(~U[2026-10-28 15:40:00Z], "%H:%M")

    assert %{count: 3, totals: "2 crashes, 1 by the watchdog", latest: [_, _]} = watched.restarts
    assert %{count: 1, crash: false, totals: "1 by an operator"} = operated.restarts
    assert %{count: 1, totals: "1 crash", latest: []} = none.restarts

    assert [%{restarts: %{count: 0, totals: "No restarts"}}] =
             View.apps([app([child(%{})])], %{}, @now)

    # A restart older than a day shows its date
    old =
      child(%{crash_restart_count: 1, restarts: [%{at: ~U[2026-10-20 09:00:00Z], cause: :crash}]})

    assert [%{restarts: %{latest: [%{time: time}]}}] = View.apps([app([old])], %{}, @now)
    assert time == HostTime.format(~U[2026-10-20 09:00:00Z], "%b %d %H:%M")
  end

  test "the limits follow the Watchdog's config, and a type it does not watch has no restart mark" do
    usage =
      usage(%{
        process:
          watched(600, 1_000, %{warning_threshold_percent: 50, restart_threshold_percent: 65}),
        port:
          watched(70, 100, %{
            enable_restart: false,
            warning_threshold_percent: 60,
            restart_threshold_percent: 80
          }),
        atom: watched(500, 1_000, %{enabled: false})
      })

    assert [%{instances: [%{limits: [process, port, atom], warnings: warnings}]}] =
             View.apps([app([child(%{})])], usage, @now)

    assert %{level: 1, restart_at: 65, watch: "warns at 50%, restarts at 65%"} = process
    assert %{level: 1, restart_at: false, watch: "warns at 60%, restart off"} = port
    assert %{level: 0, restart_at: false, watch: nil} = atom
    assert warnings == ["processes at 60% of the limit", "ports at 70% of the limit"]

    # Nothing acts on a type the watchdog does not watch, so it gets no level, even near its limit
    near = usage(%{atom: watched(950, 1_000, %{enabled: false})})

    assert [%{urgent: [], instances: [%{limits: [%{level: 0}], warnings: []}]}] =
             View.apps([app([child(%{})])], near, @now)
  end

  test "an instance with no sample from the Watchdog shows no limits" do
    assert [%{instances: [%{limits: [], warnings: []}]}] =
             View.apps([app([child(%{})])], usage(%{}), @now)
  end

  test "an instance lists its ports and served URLs, and the app shows its own logo" do
    logo = "data:image/svg+xml;base64,PHN2Zy8+"

    children = [
      child(%{ports: [%{key: "PORT", base: 4000}], urls: ["http://localhost:4000"], logo: logo}),
      child(%{sname: "myapp-def"})
    ]

    assert [
             %{
               logo: ^logo,
               instances: [
                 %{ports: [%{key: "PORT", base: 4000}], urls: ["http://localhost:4000"]},
                 _
               ]
             }
           ] =
             View.apps([app(children)], %{}, @now)

    assert [%{logo: nil}] = View.apps([app([child(%{})])], %{}, @now)
  end

  test "a subtitle leaves out the version when nothing runs" do
    children = [child(%{status: :idle, version: nil})]
    assert [%{sub: "OTP 29 · Elixir 1.20.4"}] = View.apps([app(children)], %{}, @now)
  end

  test "apps sort by name, and a crash in the last hour is a problem" do
    children = [child(%{last_crash_at: ~U[2026-10-28 15:40:00Z]})]

    assert [%{name: "alpha", problems: []}, %{name: "myapp", problems: problems} = crashed] =
             View.apps([app(children), app([child(%{})], %{name: "alpha"})], %{}, @now)

    assert problems == [
             "myapp-abc crashed at #{HostTime.format(~U[2026-10-28 15:40:00Z], "%H:%M")}"
           ]

    assert View.attention?(crashed)
  end

  test "severity ranks down first, then a restart threshold or TLS soon, then failures, then the rest" do
    ghosted = %{last_ghosted_version: "1.1.0", last_ghosted_at: ~U[2026-10-28 15:00:00Z]}
    deployed = ~U[2026-10-28 14:00:00Z]
    at_restart = usage(%{process: watched(95, 100)})
    warning = usage(%{process: watched(80, 100)})

    assert severity(
             app([child(%{status: :idle, version: nil, deployed_at: deployed})], %{
               config: ghosted
             })
           ) == 4

    assert severity(app([child(%{})]), at_restart) == 3
    assert severity(app([child(%{})], %{certificates: [%PublicKey{expires_in_days: 5}]})) == 3
    assert severity(app([child(%{deployed_at: deployed})], %{config: ghosted})) == 2
    assert severity(app([child(%{last_crash_at: ~U[2026-10-28 15:40:00Z]})])) == 2
    assert severity(app([child(%{})]), warning) == 2
    assert severity(app([child(%{})], %{certificates: [%PublicKey{expires_in_days: 20}]})) == 1
    assert severity(app([child(%{status: :pre_commands})])) == 1
    assert severity(app([child(%{})])) == 0

    # A failed pre_command is down when no instance runs, and failing while another one runs
    failed =
      child(%{
        status: :pre_commands,
        otp: :not_connected,
        failed_pre_commands: ["eval Migrator.run()"]
      })

    assert severity(app([failed])) == 4
    assert severity(app([failed, child(%{sname: "myapp-def"})])) == 2
  end

  test "a failed pre_command is an error callout that names the command" do
    failed =
      child(%{
        status: :pre_commands,
        otp: :not_connected,
        failed_pre_commands: ["eval Migrator.run()"]
      })

    assert [%{alert: %{kind: :pre_commands, tone: :error, blocking: true} = alert}] =
             View.apps([app([failed])], %{}, @now)

    assert alert.title == "pre_commands for 1.0.0 failed"
    assert alert.commands == ["eval Migrator.run()"]
    refute alert.detail =~ "Migrator"

    # While they run, it is a note
    assert [
             %{
               alert: %{
                 tone: :info,
                 blocking: false,
                 detail: "myapp-abc starts when they finish."
               }
             }
           ] =
             View.apps([app([child(%{status: :pre_commands, otp: :not_connected})])], %{}, @now)

    # A hot upgrade's pre_commands run while the instance runs, so it counts as running
    assert [%{running: 1, alert: %{title: "Running the hot upgrade's pre_commands"}}] =
             View.apps([app([child(%{status: :pre_commands, otp: :connected})])], %{}, @now)
  end

  test "a TLS certificate within 7 days and an instance at its restart threshold are urgent" do
    at_restart = usage(%{process: watched(95, 100)})

    children = [child(%{}), child(%{sname: "myapp-def"})]
    certificates = [%PublicKey{expires_in_days: 5}, %PublicKey{expires_in_days: 20}]

    assert [%{urgent: [tls, limit]}] =
             View.apps([app(children, %{certificates: certificates})], at_restart, @now)

    assert %{kind: :tls, title: "TLS certificate expires in 5 days"} = tls

    assert %{
             kind: :limit,
             sname: "myapp-abc",
             title: "myapp-abc processes at 95% of the limit",
             detail: "The watchdog restarts the instance at 90%."
           } = limit

    off = usage(%{process: watched(95, 100, %{enable_restart: false})})

    assert [%{urgent: [%{detail: "Restart is off for this limit" <> _}]}] =
             View.apps([app([child(%{})])], off, @now)

    assert [%{urgent: []}] = View.apps([app([child(%{})])], %{}, @now)
  end

  test "the open app shows its config in one line, and its certificates" do
    status =
      app([child(%{}), child(%{sname: "myapp-def"})], %{
        replicas: 2,
        deploy_rollback_timeout_ms: 600_000,
        deploy_schedule_interval_ms: 5_000,
        certificates: [
          %PublicKey{domains: ["myapp.com", "www.myapp.com"], expires_in_days: 54, issuer: "R3"}
        ]
      })

    assert [%{config_line: line, certificates: [certificate]}] = View.apps([status], %{}, @now)
    assert line == "2 replicas · rollback timeout 10 minutes · checks every 5 seconds · automatic"

    assert certificate == %{
             domains: "myapp.com, www.myapp.com",
             expires: "expires in 54 days",
             tone: :muted,
             issuer: "R3"
           }

    pinned = %{
      status
      | config: %{status.config | mode: :manual, manual_version: %{version: "1.4.1"}}
    }

    assert [%{config_line: line}] = View.apps([pinned], %{}, @now)
    assert String.ends_with?(line, " · manual, pinned 1.4.1")

    expired = %{status | certificates: [%PublicKey{expires_in_days: -3}]}

    assert [%{certificates: [%{expires: "expired 3 days ago", tone: :error}]}] =
             View.apps([expired], %{}, @now)
  end

  test "a running instance that DeployEx cannot reach over OTP is a problem under the row" do
    unreachable = child(%{otp: :not_connected})

    assert [
             %{
               problems: [problem],
               urgent: [urgent],
               severity: 2,
               instances: [%{otp: :not_connected}]
             }
           ] =
             View.apps([app([unreachable])], %{}, @now)

    assert problem == "myapp-abc runs, but DeployEx cannot connect to it over OTP"
    assert %{kind: :otp, sname: "myapp-abc", detail: "Check the cookie and the TLS" <> _} = urgent

    # A stopped instance is not connected either, and that is no OTP problem
    assert [%{urgent: []}] =
             View.apps([app([child(%{otp: :not_connected, status: :idle})])], %{}, @now)
  end

  test "DeployEx has its own row, with its limits, the host memory and its certificate" do
    deployex = %Status{
      name: "deployex",
      sname: "deployex",
      node: :deployex@host,
      version: "0.10.0",
      status: :running,
      otp: :not_connected,
      otp_version: "29",
      elixir_version: "1.20.4",
      uptime: "3h ago",
      resources: %Resources{cpu: 0.4, cores: 10, memory: 209_715_200},
      certificates: [%PublicKey{domains: ["deployex"], expires_in_days: 5}]
    }

    usage = %{
      deployex: %{
        process: watched(950, 1_000),
        memory: watched(60_000_000_000, 64_000_000_000)
      }
    }

    assert View.deployex([], usage, @now) == nil

    row = View.deployex([deployex, app([child(%{})])], usage, @now)

    assert %{
             name: "deployex",
             language: "deployex",
             sub: "0.10.0 · OTP 29 · Elixir 1.20.4",
             cpu: "0.4%",
             memory: "200 MB",
             restarts: nil,
             config_line: nil,
             certificates: [%{domains: "deployex", tone: :error}],
             instances: [%{sname: "deployex", restarts: nil, otp: nil, limits: [process, memory]}]
           } = row

    assert %{name: "Processes", level: 2} = process
    assert %{name: "Host memory", count: "55.9 GB", limit: "59.6 GB", level: 2} = memory

    # Its OTP status is no problem of its own, the limits and the certificate are
    assert [
             %{kind: :tls},
             %{kind: :limit, title: "deployex processes at 95% of the limit"},
             %{
               kind: :limit,
               detail: "The watchdog restarts the app that uses the most memory at 90%."
             }
           ] = row.urgent

    assert View.attention?(row)
  end

  test "a duration reads in its largest whole unit" do
    assert View.duration(5_000) == "5 seconds"
    assert View.duration(1_000) == "1 second"
    assert View.duration(600_000) == "10 minutes"
    assert View.duration(3_600_000) == "1 hour"
    assert View.duration(90_000) == "90 seconds"
    assert View.duration(1_500) == "1500 milliseconds"
  end

  test "an Erlang or Gleam instance gets the Erlang shell, and a status with no instance says so" do
    assert [%{language_name: "Erlang", instances: [%{shell: "Erlang shell"}]}] =
             View.apps([app([child(%{})], %{language: "erlang"})], %{}, @now)

    assert [%{language_name: "Gleam", sub: "no version", status: %{text: "0/0 running"}}] =
             View.apps([app([], %{language: "gleam"})], %{}, @now)
  end

  test "the host card shows the system with its architecture, and -- with no reading" do
    assert %{system: "macOS 15.7.4 · " <> _, icon: "macos", up: "3 days"} =
             View.host(%Host.Info{host: "macOS", description: "15.7.4", uptime: "3 days"})

    assert %{system: "Ubuntu 24.04 · " <> _, icon: "linux"} =
             View.host(%Host.Info{host: "Linux", description: "Ubuntu 24.04"})

    assert %{system: "--", up: "--", icon: "linux"} = View.host(nil)
  end

  test "bytes and ages read as short text" do
    assert View.bytes(52_428_800) == "50 MB"
    assert View.age(~U[2026-10-28 15:55:00Z], @now) == "5m ago"
    assert View.age(~U[2026-10-26 16:00:00Z], @now) == "2d ago"
    assert View.age(nil, @now) == nil
  end

  test "Tags render the status, the deploy tags and the icons" do
    assert render_component(&Tags.status/1, text: "running", tone: :success) =~
             "var(--dx-success-text)"

    assert render_component(&Tags.deploy_tag/1, type: :failed) =~ "failed"
    assert render_component(&Tags.deploy_tag/1, type: :ghosted) =~ "dx-dtag-fail"
    assert render_component(&Tags.deploy_tag/1, type: :hot, label: "hot upgrade") =~ "dx-dtag-hot"
    assert render_component(&Tags.lang/1, name: "gleam", small: true) =~ "dx-lang-sm"
    assert render_component(&Tags.lang/1, name: "erlang", label: "Erlang") =~ ~s(role="img")
  end
end
