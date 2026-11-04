defmodule DeployexWeb.ApplicationsLive.View do
  @moduledoc """
  Turns the status of this host's applications into what the Applications page shows: the This host card,
  one row per application, its instances, their limits, and the problems that need an action.
  """

  alias DeployexWeb.HostTime
  alias DeployexWeb.RecentEvents
  alias Foundation.Certificates.PublicKey

  # Only DeployEx has the host memory, its watchdog restarts the app that uses the most of it
  @limit_types [
    {"Processes", :process},
    {"Ports", :port},
    {"Atoms", :atom},
    {"Host memory", :memory}
  ]
  @tls_warn_days 30

  @doc """
  The This host card: the system and its uptime. The DeployEx row shows the DeployEx and OTP versions.
  """
  @spec host(Host.Info.t() | nil) :: map()
  def host(host_info) do
    %{system: system(host_info), icon: system_icon(host_info), up: up(host_info)}
  end

  @doc """
  The DeployEx row, first in the list: its limits against the watchdog's thresholds, its CPU and memory,
  its certificate and its node. Nil while the statuses have no DeployEx.
  """
  @spec deployex([Deployer.Status.t()], map(), DateTime.t()) :: map() | nil
  def deployex(statuses, usage, now \\ DateTime.utc_now()) do
    case Enum.find(statuses, &(&1.name == "deployex")) do
      nil ->
        nil

      status ->
        # Its OTP status says whether it reaches another node, which is no problem of its own
        child = %{status | language: "elixir", otp: nil}
        status = %{status | children: [child], replicas: 1, config: nil, language: "elixir"}
        row = app(status, %{status.node => Map.get(usage, :deployex, %{})}, now)

        %{
          row
          | language: "deployex",
            language_name: "DeployEx",
            restarts: nil,
            config_line: nil,
            instances: Enum.map(row.instances, &%{&1 | restarts: nil})
        }
    end
  end

  @doc """
  One row for each application, in the order of the status, with DeployEx left out. The usage holds the
  Watchdog's samples and config for each instance node, from `Sentinel.Watchdog.usage/1`.
  """
  @spec apps([Deployer.Status.t()], %{node() => map()}, DateTime.t()) :: [map()]
  def apps(statuses, usage, now \\ DateTime.utc_now()) do
    statuses
    |> Enum.reject(&(&1.name == "deployex"))
    |> Enum.sort_by(& &1.name)
    |> Enum.map(&app(&1, usage, now))
  end

  @doc """
  The Watchdog's samples and config for the node of each instance in the statuses.
  """
  @spec usage([Deployer.Status.t()]) :: %{(node() | :deployex) => map()}
  def usage(statuses) do
    for %{children: children} <- statuses,
        %{node: node} <- children,
        node,
        into: %{deployex: Sentinel.Watchdog.usage(:deployex)} do
      {node, Sentinel.Watchdog.usage(node)}
    end
  end

  @doc """
  Whether an app needs attention: an alert, like a ghosted version, or a problem on its row.
  """
  @spec attention?(map()) :: boolean()
  def attention?(app), do: app.alert != nil or app.problems != []

  @doc """
  The apps that need attention, and whether one of them is blocked, with nothing running.
  """
  @spec attention([map()]) :: %{count: non_neg_integer(), blocking: boolean()}
  def attention(apps) do
    apps = Enum.filter(apps, &attention?/1)
    %{count: length(apps), blocking: Enum.any?(apps, &(&1.alert != nil and &1.alert.blocking))}
  end

  defp app(status, usage, now) do
    instances =
      Enum.map(status.children, &instance(&1, status.language, Map.get(usage, &1.node, %{}), now))

    running = Enum.count(status.children, &running?/1)
    total = max(status.replicas, length(status.children))

    tls = tls(status, @tls_warn_days)
    crashes = recent_crashes(instances, now)
    unreachable = for %{running: true, otp: :not_connected} = instance <- instances, do: instance

    problems =
      Enum.map(tls, & &1.text) ++
        for(
          instance <- instances,
          warning <- instance.warnings,
          do: "#{instance.sname} #{warning}"
        ) ++
        Enum.map(unreachable, &"#{&1.sname} runs, but DeployEx cannot connect to it over OTP") ++
        crashes

    ghosted = ghosted(status, instances)
    alert = alert(status, ghosted, running)

    %{
      name: status.name,
      language: status.language,
      language_name: language_name(status.language),
      logo: Enum.find_value(status.children, & &1.logo),
      sub: sub(status),
      status: app_status(running, total, status.children),
      running: running,
      total: total,
      pinned: pinned(status.config),
      problems: problems,
      cpu: sum_text(instances, :cpu_value, &cpu_text/1),
      cpu_tip: cpu_tip(sum(instances, :cpu_value), Enum.find_value(instances, & &1.cores)),
      memory: sum_text(instances, :memory_value, &bytes/1),
      restarts: restarts(status.children, now),
      deploy: deploy(status, ghosted, now),
      alert: alert,
      urgent: urgent(tls, instances, unreachable),
      severity: severity(alert, instances, tls, crashes ++ unreachable),
      notes: notes(status, instances),
      config_line: config_line(status),
      certificates: certificates(status),
      instances: instances
    }
  end

  defp instance(child, language, usage, now) do
    limits = limits(usage)
    warnings = Enum.flat_map(limits, & &1.warning)

    child.resources
    |> resources()
    |> Map.merge(%{
      sname: child.sname,
      node: child.node && to_string(child.node),
      version: child.version,
      status: instance_status(child.status),
      running: running?(child),
      otp: child.otp,
      restarts: restarts([child], now),
      ports: Enum.map(List.wrap(child.ports), &Map.take(&1, [:key, :base])),
      urls: List.wrap(child.urls),
      deploy: child.last_deployment,
      up: up_text(child.uptime),
      shell: if(language == "elixir", do: "IEx shell", else: "Erlang shell"),
      limits: limits,
      warnings: warnings,
      last_crash_at: child.last_crash_at,
      deployed_at: child.deployed_at,
      age: age(child.deployed_at, now)
    })
  end

  # The CPU and memory of an instance, the values for the app's sums and the texts
  defp resources(nil),
    do: %{cpu_value: nil, cores: nil, memory_value: nil, cpu: "--", cpu_tip: nil, memory: "--"}

  defp resources(resources) do
    %{
      cpu_value: resources.cpu,
      cores: resources.cores,
      memory_value: resources.memory,
      cpu: cpu_text(resources.cpu),
      cpu_tip: cpu_tip(resources.cpu, resources.cores),
      memory: if(resources.memory, do: bytes(resources.memory), else: "--")
    }
  end

  defp limits(usage) do
    for {name, type} <- @limit_types, {:ok, {data, config}} <- [Map.fetch(usage, type)] do
      limit_row(name, type, data, config)
    end
  end

  # The percent and the level use the Watchdog's sample, ratio and thresholds, so the page shows what it checks
  defp limit_row(name, type, %{current: count, limit: limit}, config) do
    percent = trunc(count / limit * 100)
    level = level(percent, config)
    amount = if type == :memory, do: &bytes/1, else: &number/1

    %{
      name: name,
      type: type,
      count: amount.(count),
      limit: amount.(limit),
      percent: percent,
      percent_text: if(count > 0 and percent < 1, do: "<1%", else: "#{percent}%"),
      level: level,
      restart_at: config.enabled && config.enable_restart && config.restart_threshold_percent,
      watch: watch_text(config),
      warning: limit_warning(String.downcase(name), percent, level)
    }
  end

  # A type the watchdog does not watch gets no level, as nothing acts on it
  defp level(_percent, %{enabled: false}), do: 0
  defp level(percent, %{restart_threshold_percent: restart}) when percent >= restart, do: 2
  defp level(percent, %{warning_threshold_percent: warning}) when percent >= warning, do: 1
  defp level(_percent, _config), do: 0

  defp watch_text(%{enabled: false}), do: nil

  defp watch_text(%{enable_restart: true} = config),
    do:
      "warns at #{config.warning_threshold_percent}%, restarts at #{config.restart_threshold_percent}%"

  defp watch_text(config), do: "warns at #{config.warning_threshold_percent}%, restart off"

  defp limit_warning(name, percent, level) when level > 0,
    do: ["#{name} at #{percent}% of the limit"]

  defp limit_warning(_name, _percent, _level), do: []

  # A ghosted version is the latest event of the app when it is newer than the last deploy
  defp ghosted(%{config: %{last_ghosted_version: version} = config}, instances)
       when is_binary(version) and version != "-/-" do
    # A status from before a hot upgrade has no last_ghosted_at until its next update
    at = Map.get(config, :last_ghosted_at)

    last_deploy =
      instances
      |> Enum.map(& &1.deployed_at)
      |> Enum.reject(&is_nil/1)
      |> Enum.max(DateTime, fn -> nil end)

    if is_nil(last_deploy) or (at && DateTime.compare(at, last_deploy) == :gt) do
      %{version: version, at: at}
    end
  end

  defp ghosted(_status, _instances), do: nil

  defp deploy(_status, %{at: at}, _now) do
    %{type: :ghosted, label: "ghosted", when: at && HostTime.format(at, "%H:%M")}
  end

  defp deploy(status, nil, now) do
    latest =
      status.children
      |> Enum.filter(& &1.deployed_at)
      |> Enum.max_by(& &1.deployed_at, DateTime, fn -> nil end)

    case latest do
      nil ->
        nil

      %{last_deployment: :hot_upgrade} = child ->
        %{type: :hot, label: "hot", when: age(child.deployed_at, now)}

      child ->
        %{type: :full, label: "full", when: age(child.deployed_at, now)}
    end
  end

  # A title, a line on what it means for the app, and a tone: red when nothing runs, amber when it still runs
  defp alert(status, %{version: version}, running) do
    detail =
      if running == 0,
        do: "No earlier version runs on this host, so the app is down.",
        else: "#{running_version(status)} keeps running, so the app is up."

    %{
      kind: :ghosted,
      blocking: running == 0,
      tone: if(running == 0, do: :error, else: :warning),
      version: version,
      title: "#{version} failed and is ghosted",
      detail: detail,
      text: "#{version} failed and is ghosted. #{detail}"
    }
  end

  defp alert(status, nil, running) do
    case Enum.find(status.children, &(&1.status == :pre_commands)) do
      nil -> nil
      child -> pre_commands_alert(child, running)
    end
  end

  # A failed pre_command keeps the instance from starting, and the monitor retries it until it passes.
  # The app is down only when no other instance runs, like a previous version kept for its rollback
  defp pre_commands_alert(%{failed_pre_commands: [_ | _] = failed} = child, running) do
    commands = Enum.join(failed, ", ")

    %{
      kind: :pre_commands,
      blocking: running == 0,
      tone: :error,
      version: child.version,
      title: "pre_commands for #{child.version} failed",
      detail: "#{child.sname} waits while DeployEx runs them again.",
      commands: failed,
      text: "#{child.sname} failed its pre_commands for #{child.version}: #{commands}."
    }
  end

  # A running instance runs a hot upgrade's pre_commands, and its version changes after them
  defp pre_commands_alert(%{otp: :connected} = child, _running) do
    %{
      kind: :pre_commands,
      blocking: false,
      tone: :info,
      version: child.version,
      title: "Running the hot upgrade's pre_commands",
      detail: "#{child.sname} keeps running #{child.version} until the upgrade installs.",
      text: "#{child.sname} runs the hot upgrade's pre_commands."
    }
  end

  defp pre_commands_alert(child, _running) do
    %{
      kind: :pre_commands,
      blocking: false,
      tone: :info,
      version: child.version,
      title: "Running pre_commands for #{child.version}",
      detail: "#{child.sname} starts when they finish.",
      text: "#{child.sname} runs its pre_commands for #{child.version}."
    }
  end

  @doc """
  Whether an instance runs. A hot upgrade's pre_commands run while it runs, and the status keeps it
  connected.
  """
  @spec running?(map()) :: boolean()
  def running?(%{status: :running}), do: true
  def running?(%{status: :pre_commands, otp: :connected}), do: true
  def running?(_child), do: false

  # The problems that show under the row, so they need no open app: a TLS certificate within 7 days, an
  # instance at its restart threshold, and a running instance that DeployEx cannot reach over OTP
  defp urgent(tls, instances, unreachable) do
    certificates =
      for %{tone: :error, text: text} <- tls do
        %{
          kind: :tls,
          title: text,
          detail: "Renew it before then. The certificate events are in the events log.",
          sname: nil
        }
      end

    limits =
      for instance <- instances, limit <- instance.limits, limit.level == 2 do
        %{
          kind: :limit,
          title:
            "#{instance.sname} #{String.downcase(limit.name)} at #{limit.percent}% of the limit",
          detail: limit_detail(limit),
          sname: instance.sname
        }
      end

    otp =
      for instance <- unreachable do
        %{
          kind: :otp,
          title: "#{instance.sname} runs, but DeployEx cannot connect to it over OTP",
          detail:
            "Check the cookie and the TLS distribution settings. Until then the watchdog cannot watch it, " <>
              "and the shell and hot upgrades do not work.",
          sname: instance.sname
        }
      end

    certificates ++ limits ++ otp
  end

  defp limit_detail(%{type: :memory, restart_at: restart}) when is_integer(restart),
    do: "The watchdog restarts the app that uses the most memory at #{restart}%."

  defp limit_detail(%{restart_at: restart}) when is_integer(restart),
    do: "The watchdog restarts the instance at #{restart}%."

  defp limit_detail(_limit),
    do: "Restart is off for this limit, so nothing stops the instance at the limit."

  # How bad an app's state is, for the attention list: 4 down, 3 at a restart threshold or a TLS
  # certificate within 7 days, 2 a failed version, a crash, no OTP connection or a limit warning, 1 the
  # rest, 0 nothing
  defp severity(alert, instances, tls, failures) do
    levels = for instance <- instances, limit <- instance.limits, do: limit.level

    cond do
      match?(%{blocking: true}, alert) -> 4
      near_restart?(levels, tls) -> 3
      failing?(alert, failures, levels) -> 2
      any_problem?(alert, tls, instances) -> 1
      true -> 0
    end
  end

  defp near_restart?(levels, tls), do: 2 in levels or Enum.any?(tls, &(&1.tone == :error))

  defp failing?(alert, failures, levels),
    do:
      match?(%{tone: :error}, alert) or match?(%{kind: :ghosted}, alert) or failures != [] or
        1 in levels

  defp any_problem?(nil, [], instances), do: Enum.any?(instances, &(&1.warnings != []))
  defp any_problem?(_alert, _tls, _instances), do: true

  # The TLS certificates of the app that expire within the given days
  defp tls(status, within) do
    for %{expires_in_days: days} <- status.certificates |> List.wrap() |> Enum.uniq(),
        is_integer(days) and days <= within do
      %{
        tone: if(days <= 7, do: :error, else: :warning),
        text: "TLS certificate expires in #{days} days"
      }
    end
  end

  # A crash in the last hour is a problem. An older one stays in the notes and the restart count
  defp recent_crashes(instances, now) do
    for %{last_crash_at: %DateTime{} = at} = instance <- instances,
        DateTime.diff(now, at) < 3_600 do
      "#{instance.sname} crashed at #{HostTime.format(at, "%H:%M")}"
    end
  end

  defp notes(status, instances) do
    tls = tls(status, @tls_warn_days)

    near =
      for instance <- instances, warning <- instance.warnings do
        %{tone: :warning, text: "#{instance.sname} #{warning}"}
      end

    crashes =
      for %{last_crash_at: %DateTime{} = at} = instance <- instances do
        %{
          tone: :warning,
          text: "#{instance.sname} crash restart at #{HostTime.format(at, "%H:%M")}"
        }
      end

    Enum.uniq(tls) ++ near ++ crashes
  end

  # The app's config in one line, like 2 replicas · rollback timeout 10 minutes · checks every 5 seconds
  defp config_line(%{config: nil}), do: nil

  defp config_line(status) do
    [
      count(status.replicas, "replica"),
      status.deploy_rollback_timeout_ms > 0 &&
        "rollback timeout #{duration(status.deploy_rollback_timeout_ms)}",
      status.deploy_schedule_interval_ms > 0 &&
        "checks every #{duration(status.deploy_schedule_interval_ms)}",
      mode(status.config)
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.join(" · ")
  end

  defp mode(%{mode: :manual, manual_version: %{version: version}}),
    do: "manual, pinned #{version}"

  defp mode(%{mode: :manual}), do: "manual"
  defp mode(_config), do: "automatic"

  # The app's TLS certificates: the domains, when each expires, and the issuer
  defp certificates(status) do
    for %PublicKey{expires_in_days: days} = certificate <- List.wrap(status.certificates) do
      %{
        domains: certificate.domains |> List.wrap() |> Enum.join(", "),
        expires: expires(days),
        tone: expiry_tone(days),
        issuer: certificate.issuer
      }
    end
  end

  defp expires(days) when is_integer(days) and days < 0, do: "expired #{count(-days, "day")} ago"
  defp expires(0), do: "expires today"
  defp expires(days) when is_integer(days), do: "expires in #{count(days, "day")}"
  defp expires(_days), do: "no expiry date"

  defp expiry_tone(days) when is_integer(days) and days <= 7, do: :error
  defp expiry_tone(days) when is_integer(days) and days <= @tls_warn_days, do: :warning
  defp expiry_tone(_days), do: :muted

  defp app_status(running, total, children) do
    cond do
      total > 0 and running == total ->
        %{text: "#{running}/#{total} running", tone: :success}

      Enum.any?(children, &(&1.status in [:starting, :pre_commands])) ->
        %{text: "#{running}/#{total} running", tone: :warning}

      running == 0 ->
        %{text: "0/#{total} running", tone: :error}

      true ->
        %{text: "#{running}/#{total} running", tone: :warning}
    end
  end

  defp instance_status(:running), do: %{text: "running", tone: :success}
  defp instance_status(:starting), do: %{text: "starting", tone: :warning}
  defp instance_status(:pre_commands), do: %{text: "pre_commands", tone: :warning}
  defp instance_status(_status), do: %{text: "stopped", tone: :error}

  defp sub(status) do
    child = Enum.find(status.children, &running?/1) || List.first(status.children)

    parts =
      case child do
        nil ->
          ["no version"]

        # With nothing running there is no version, and the status already says so
        child ->
          [
            child.version,
            child.otp_version && "OTP #{child.otp_version}",
            status.language == "elixir" && child.elixir_version &&
              "Elixir #{child.elixir_version}"
          ]
      end

    case Enum.filter(parts, &is_binary/1) do
      [] -> "no version"
      parts -> Enum.join(parts, " · ")
    end
  end

  defp pinned(%{mode: :manual, manual_version: %{version: version}}), do: version
  defp pinned(_config), do: nil

  defp running_version(status) do
    case Enum.find(status.children, &running?/1) do
      %{version: version} when is_binary(version) -> version
      _ -> "The current version"
    end
  end

  # One count for the board, amber only for crashes. The tooltip tells crashes, operator and watchdog
  # restarts apart, and lists the latest ones newest first, each a link to the logs at its time
  defp restarts(children, now) do
    crash = Enum.reduce(children, 0, &(&1.crash_restart_count + &2))
    forced = Enum.reduce(children, 0, &(&1.force_restart_count + &2))
    watchdog = Enum.reduce(children, 0, &(Map.get(&1, :watchdog_restart_count, 0) + &2))

    totals =
      [
        crash > 0 && crashes(crash),
        forced > watchdog && "#{forced - watchdog} by an operator",
        watchdog > 0 && "#{watchdog} by the watchdog"
      ]
      |> Enum.filter(& &1)

    latest =
      children
      |> Enum.flat_map(fn child -> Enum.map(List.wrap(child.restarts), &{child.sname, &1}) end)
      |> Enum.sort_by(fn {_sname, restart} -> restart.at end, {:desc, DateTime})
      |> Enum.take(10)
      |> Enum.map(&latest_restart(&1, now))

    totals = if totals == [], do: "No restarts", else: Enum.join(totals, ", ")

    %{
      count: crash + forced,
      crash: crash > 0,
      totals: totals,
      label: "#{count(crash + forced, "restart")}: #{totals}",
      latest: latest
    }
  end

  defp latest_restart({sname, %{at: at, cause: cause} = restart}, now) do
    format = if DateTime.diff(now, at) < 86_400, do: "%H:%M", else: "%b %d %H:%M"

    %{
      id: "#{sname}-#{DateTime.to_unix(at)}",
      time: HostTime.format(at, format),
      sname: sname,
      text: Enum.join(Enum.filter([to_string(cause), restart[:detail]], & &1), ", "),
      href: RecentEvents.history_href(sname, at)
    }
  end

  defp crashes(1), do: "1 crash"
  defp crashes(n), do: "#{n} crashes"

  defp count(1, noun), do: "1 #{noun}"
  defp count(n, noun), do: "#{n} #{noun}s"

  defp sum_text(instances, key, format) do
    case sum(instances, key) do
      nil -> "--"
      sum -> format.(sum)
    end
  end

  defp sum(instances, key) do
    case instances |> Enum.map(&Map.get(&1, key)) |> Enum.reject(&is_nil/1) do
      [] -> nil
      values -> Enum.sum(values)
    end
  end

  @doc """
  A CPU share as text. Below 1% it has one decimal, so an idle instance does not read as 0%.
  """
  @spec cpu_text(number() | nil) :: String.t()
  def cpu_text(nil), do: "--"

  def cpu_text(cpu) do
    tenths = Float.round(cpu / 1, 1)

    cond do
      cpu == 0 -> "0%"
      tenths == 0 -> "<0.1%"
      tenths < 1 -> "#{tenths}%"
      true -> "#{round(cpu)}%"
    end
  end

  # The scale of the share, since top and Activity Monitor count 100% for each core
  defp cpu_tip(cpu, cores) when is_number(cpu) and is_integer(cores),
    do: "#{cpu_text(cpu)} of #{count(cores, "core")}"

  defp cpu_tip(_cpu, _cores), do: nil

  @doc """
  A time in milliseconds in words, in the largest whole unit, like "5 seconds" or "10 minutes".
  """
  @spec duration(pos_integer()) :: String.t()
  def duration(ms) when rem(ms, 3_600_000) == 0, do: count(div(ms, 3_600_000), "hour")
  def duration(ms) when rem(ms, 60_000) == 0, do: count(div(ms, 60_000), "minute")
  def duration(ms) when rem(ms, 1_000) == 0, do: count(div(ms, 1_000), "second")
  def duration(ms), do: count(ms, "millisecond")

  @doc false
  def bytes(bytes) when bytes >= 1_073_741_824,
    do: "#{:erlang.float_to_binary(bytes / 1_073_741_824, decimals: 1)} GB"

  def bytes(bytes), do: "#{div(bytes, 1_048_576)} MB"

  @doc false
  def age(nil, _now), do: nil

  def age(at, now) do
    seconds = max(DateTime.diff(now, at), 0)

    cond do
      seconds < 60 -> "now"
      seconds < 3_600 -> "#{div(seconds, 60)}m ago"
      seconds < 86_400 -> "#{div(seconds, 3_600)}h ago"
      true -> "#{div(seconds, 86_400)}d ago"
    end
  end

  defp up_text(nil), do: nil
  defp up_text(uptime), do: String.replace_suffix(uptime, " ago", "")

  defp number(value),
    do: value |> Integer.to_string() |> String.replace(~r/\B(?=(\d{3})+(?!\d))/, ",")

  defp language_name("elixir"), do: "Elixir"
  defp language_name("erlang"), do: "Erlang"
  defp language_name("gleam"), do: "Gleam"
  defp language_name(other), do: to_string(other)

  defp system(%Host.Info{host: host, description: description})
       when is_binary(host) and host != "" do
    arch = :erlang.system_info(:system_architecture) |> to_string() |> String.split("-") |> hd()

    # macOS reports only its version, like 15.7.4, so the name goes in front of it
    os =
      case description do
        <<digit, _rest::binary>> when digit in ?0..?9 -> "#{host} #{description}"
        description when description in [nil, ""] -> host
        description -> description
      end

    "#{os} · #{arch}"
  end

  defp system(_host_info), do: "--"

  defp system_icon(%Host.Info{host: host}) when is_binary(host) do
    if String.contains?(String.downcase(host), "mac"), do: "macos", else: "linux"
  end

  defp system_icon(_host_info), do: "linux"

  defp up(%Host.Info{uptime: uptime}) when is_binary(uptime), do: uptime
  defp up(_host_info), do: "--"
end
