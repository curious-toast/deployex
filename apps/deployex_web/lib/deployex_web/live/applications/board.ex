defmodule DeployexWeb.ApplicationsLive.Board do
  @moduledoc """
  The Applications page: the page head, the This host card and the application table, built from
  `DeployexWeb.ApplicationsLive.View`.

  Logs and shell buttons open a tab in the dock through the `dx:dock-open` window event.
  """
  use DeployexWeb, :html

  alias DeployexWeb.Guides
  alias DeployexWeb.UI.Icons
  alias DeployexWeb.UI.Tags

  @columns "minmax(12.5rem,1.5fr) 10.5rem 3.5rem 5.25rem 4.25rem 8rem calc(9.25rem + 13px)"

  attr :host_name, :string, required: true

  attr :attention, :map,
    required: true,
    doc: "the count of apps that need attention, and if one is blocked"

  attr :only_attention, :boolean, required: true, doc: "whether the list shows only those apps"

  def page_head(assigns) do
    ~H"""
    <header class="flex flex-wrap items-end justify-between gap-x-6 gap-y-3">
      <div>
        <h1 class="text-[1.625rem] font-bold tracking-[-0.02em]">Applications</h1>
        <p class="dx-muted dx-mono mt-1.5 text-[0.8125rem]">{@host_name}</p>
      </div>
      <button
        :if={@attention.count > 0}
        id="apps-attention"
        type="button"
        class={["dx-chip dx-chip-btn", if(@attention.blocking, do: "dx-s-ghost", else: "dx-s-start")]}
        aria-pressed={to_string(@only_attention)}
        phx-click="toggle-attention"
      >
        <Icons.icon :if={@only_attention} name="check" stroke="2.4" class="dx-ico size-3.5" />
        <Icons.icon :if={not @only_attention} name="warning" stroke="2" class="dx-ico size-3.5" />
        {if @attention.count == 1,
          do: "1 app needs attention",
          else: "#{@attention.count} apps need attention"}
      </button>
    </header>
    """
  end

  @doc """
  The head of a page about one app: a link back to Applications, the language icon, the name and a line.
  """
  attr :name, :string, required: true
  attr :language, :string, required: true
  attr :logo, :string, default: nil, doc: "the app's own logo, shown instead of the language icon"
  attr :subtitle, :string, required: true
  slot :inner_block, doc: "on the right of the head, like a count chip"

  def app_head(assigns) do
    ~H"""
    <div class="flex flex-col gap-2.5">
      <.link class="dx-back" navigate={~p"/applications"}>
        <Icons.icon name="arrow-left" stroke="2" class="dx-ico size-[15px]" />Applications
      </.link>
      <header class="flex flex-wrap items-center justify-between gap-x-6 gap-y-3">
        <div class="flex items-center gap-3.5">
          <Tags.lang name={@language} label={String.capitalize(@language)} logo={@logo} />
          <div>
            <h1 class="text-[1.625rem] font-bold tracking-[-0.02em]">{@name}</h1>
            <p class="dx-muted dx-mono mt-1 text-[0.8125rem]">{@subtitle}</p>
          </div>
        </div>
        {render_slot(@inner_block)}
      </header>
    </div>
    """
  end

  attr :host, :map, required: true
  attr :pending_changes, :integer, required: true
  attr :asking, :boolean, required: true

  def host_card(assigns) do
    ~H"""
    <section class="dx-card" aria-label="This host">
      <div class="flex flex-wrap items-center justify-between gap-x-6 gap-y-3 px-[18px] py-3">
        <div class="flex flex-wrap items-center gap-x-6 gap-y-2">
          <span class="dx-stat items-center">
            <Tags.lang name={@host.icon} small label={@host.system} />{@host.system}
          </span>
          <span class="dx-stat"><span class="dx-lbl">Up</span><b>{@host.up}</b></span>
        </div>
        <div class="flex flex-wrap items-center gap-2">
          <button
            :if={@pending_changes > 0}
            id="host-config-review"
            type="button"
            class="dx-chip dx-s-start min-h-10 px-3.5"
            phx-click="show-config-changes"
          >
            {if @pending_changes == 1,
              do: "1 config change",
              else: "#{@pending_changes} config changes"} · Review
          </button>
          <button
            type="button"
            class="dx-btn"
            aria-label="Logs of DeployEx"
            phx-click={dock_open("logs", "deployex", "deployex")}
          >
            Logs
          </button>
          <button
            id="host-restart"
            type="button"
            class="dx-btn"
            phx-click="ask"
            phx-value-target="deployex"
          >
            Restart
          </button>
        </div>
      </div>
      <div :if={@asking} class="dx-ask" role="group" aria-label="Confirm the restart of DeployEx">
        <span class="flex-[1_1_320px]">
          <b>Restart DeployEx?</b>
          It stops every monitored application on this host, then starts again and deploys them.
        </span>
        <button
          id="host-restart-confirm"
          type="button"
          class="dx-btn dx-btn-danger"
          phx-click="restart-deployex"
        >
          Restart DeployEx
        </button>
        <button type="button" class="dx-btn" phx-click="cancel-ask">Cancel</button>
      </div>
    </section>
    """
  end

  attr :apps, :list, required: true

  attr :deployex, :map,
    default: nil,
    doc: "the DeployEx row, first in the list, when the filter keeps it"

  attr :distribution, :map,
    default: %{},
    doc:
      "the OTP distribution of each instance whose section is open, by sname, nil with no answer"

  attr :open, :any, required: true, doc: "the names of the expanded apps"

  attr :limits_open, :map,
    required: true,
    doc: "sname => true when its limits are open, closed by default"

  attr :ask, :any, required: true
  attr :sent, :any, required: true, doc: "the snames with a restart sent"
  attr :total, :integer, required: true, doc: "the apps on this host, shown or not"

  attr :rows, :integer,
    default: 0,
    doc: "the rows of the list, shown or not, DeployEx with the apps"

  attr :loaded, :boolean,
    default: true,
    doc: "false in the first render, before the page reads the apps"

  attr :filtered, :boolean, default: false, doc: "whether search tags filter the list"

  attr :cleared, :map,
    required: true,
    doc: "name => version, for a ghosted version cleared a moment ago"

  def app_table(assigns) do
    assigns = assign(assigns, :columns, @columns)

    ~H"""
    <section class="dx-card overflow-hidden" aria-label="Applications on this host">
      <div class="overflow-x-auto">
        <div class="min-w-[61.5rem]">
          <div
            class="grid min-h-10 items-center gap-3 pr-5 pl-[26px]"
            style={"grid-template-columns: #{@columns}"}
          >
            <div class="dx-lbl">Application</div>
            <div class="dx-lbl">Status</div>
            <div class="dx-lbl text-right">CPU</div>
            <div id="apps-memory-head" class="dx-lbl text-right" phx-hook="Tip">
              Memory<span class="sr-only">, the resident memory (RSS) of each OS process</span>
              <span popover="manual" class="dx-tip" aria-hidden="true">
                The resident memory (RSS) of each OS process
              </span>
            </div>
            <div class="dx-lbl text-right">Restarts</div>
            <div class="dx-lbl">Last deploy</div>
            <div></div>
          </div>
          <div :if={!@loaded} id="apps-loading" aria-busy="true" aria-label="Loading the applications">
            <div :for={width <- ["w-36", "w-28", "w-44"]} class="dx-skel-row">
              <span class={["dx-skel", width]}></span>
              <span class="dx-skel w-24"></span>
            </div>
          </div>
          <div :if={@loaded and @total == 0} class="dx-empty" id="apps-empty">
            <Icons.icon name="cube" class="dx-ico dx-muted size-7" />
            <b class="text-base">No applications on this host</b>
            <p class="dx-muted max-w-[460px] text-[0.875rem]">
              Add one under <code class="dx-mono">applications</code>
              in deployex.yaml. DeployEx deploys it when its release bucket has a version.
            </p>
            <div class="flex flex-wrap items-center justify-center gap-2">
              <span class="dx-muted text-[0.8125rem]">How to build and add an app:</span>
              <a
                :for={
                  {label, guide} <- [
                    {"Elixir", "local-elixir"},
                    {"Erlang", "local-erlang"},
                    {"Gleam", "local-gleam"},
                    {"YAML reference", "yaml"}
                  ]
                }
                class="dx-btn"
                href={Guides.url(guide)}
                target="_blank"
                rel="noopener noreferrer"
              >
                {label}<span class="sr-only"> (opens in a new tab)</span>
              </a>
            </div>
          </div>
          <.app_row
            :for={app <- List.wrap(@deployex) ++ @apps}
            app={app}
            open={MapSet.member?(@open, app.name)}
            limits_open={@limits_open}
            distribution={@distribution}
            ask={@ask}
            sent={@sent}
            cleared={@cleared[app.name]}
          />
        </div>
      </div>
      <div
        :if={@filtered and @total > 0}
        class="dx-muted flex flex-wrap items-center justify-between gap-2.5 border-t border-(--dx-base-300) px-5 py-3 text-[0.8125rem]"
        role="status"
      >
        <span>
          {if @deployex == nil and @apps == [],
            do: "No app matches these filters.",
            else: "#{length(List.wrap(@deployex) ++ @apps)} of #{@rows} apps match."}
        </span>
        <.link id="apps-show-all" class="dx-btn no-underline" patch={~p"/applications"}>
          Clear
        </.link>
      </div>
    </section>
    """
  end

  attr :app, :map, required: true
  attr :open, :boolean, required: true
  attr :limits_open, :map, required: true
  attr :distribution, :map, required: true
  attr :ask, :any, required: true
  attr :sent, :any, required: true
  attr :cleared, :any, required: true

  defp app_row(assigns) do
    ~H"""
    <div id={"app-#{@app.name}"} class={@open && "dx-app-open"}>
      <div id={"app-#{@app.name}-head"} class="dx-ahead" phx-hook="RowToggle" data-name={@app.name}>
        <div class="dx-arow">
          <div class="flex min-w-0 items-center gap-3.5">
            <Tags.lang name={@app.language} label={@app.language_name} logo={@app.logo} />
            <div class="min-w-0">
              <div class="text-lg font-bold tracking-[-0.01em]">{@app.name}</div>
              <div class="dx-muted dx-mono mt-0.5 truncate text-[0.8125rem]" title={@app.sub}>
                {@app.sub}
              </div>
            </div>
          </div>
          <div class="flex items-center">
            <Tags.status text={@app.status.text} tone={@app.status.tone} />
            <span
              :if={@app.problems != []}
              id={"app-#{@app.name}-problems-tip"}
              class="dx-badge"
              phx-hook="Tip"
            >
              <button
                id={"app-#{@app.name}-problems"}
                type="button"
                style={"color: #{Tags.tone(:warning)}"}
                aria-label={"#{problems(@app.problems)}: #{Enum.join(@app.problems, ", ")}. Show the instances"}
                phx-click="toggle-app"
                phx-value-name={@app.name}
                phx-value-open="true"
              >
                <Icons.icon name="warning" stroke="2" class="dx-ico size-4" />{length(@app.problems)}
              </button>
              <span popover="manual" class="dx-tip" aria-hidden="true">
                <span :for={problem <- @app.problems} class="block">{problem}</span>
              </span>
            </span>
          </div>
          <.cpu
            id={"app-#{@app.name}-cpu"}
            text={@app.cpu}
            tip={@app.cpu_tip}
            class="text-[0.875rem] font-semibold"
          />
          <div class="dx-num text-[0.875rem] font-semibold">{@app.memory}</div>
          <.restarts
            :if={@app.restarts}
            id={"app-#{@app.name}-restarts"}
            restarts={@app.restarts}
            class="text-[0.875rem] font-semibold"
            color="inherit"
            show_sname
          />
          <div :if={!@app.restarts} class="dx-num dx-muted text-[0.875rem]">--</div>
          <div class="flex items-center gap-2 text-sm">
            <Tags.deploy_tag :if={@app.deploy} type={@app.deploy.type} label={@app.deploy.label} />
            <span :if={@app.deploy} class="dx-muted">{@app.deploy.when}</span>
          </div>
          <button
            id={"app-#{@app.name}-toggle"}
            type="button"
            class="dx-ghost size-10 justify-self-end"
            aria-expanded={to_string(@open)}
            aria-label={
              if @open,
                do: "Hide the instances of #{@app.name}",
                else: "Show the instances of #{@app.name}"
            }
            phx-click="toggle-app"
            phx-value-name={@app.name}
          >
            <Icons.icon
              name="chevron-down"
              stroke="2"
              class={[
                "dx-ico transition-transform motion-reduce:transition-none",
                @open && "rotate-180"
              ]}
            />
          </button>
        </div>

        <.alert
          :if={@app.alert || @cleared}
          app={@app}
          cleared={@cleared}
          asking={@ask == {:ghosted, @app.name}}
        />
        <.urgent
          :for={{item, index} <- Enum.with_index(@app.urgent)}
          app={@app.name}
          item={item}
          index={index}
        />
      </div>

      <div :if={@open} class="dx-inset">
        <div
          :if={@app.config_line || @app.certificates != []}
          id={"app-#{@app.name}-config"}
          class="flex flex-col gap-1 border-b border-(--dx-base-300) px-4 py-2.5 text-[0.8125rem]"
        >
          <span :if={@app.config_line} class="dx-mono">{@app.config_line}</span>
          <span :for={certificate <- @app.certificates} class="flex flex-wrap items-center gap-x-2">
            <Icons.icon name="lock-closed" class="dx-ico dx-muted size-3.5" />
            <span class="dx-mono">{certificate.domains}</span>
            <span style={"color: #{Tags.tone(certificate.tone)}"}>{certificate.expires}</span>
            <span :if={certificate.issuer} class="dx-muted">issued by {certificate.issuer}</span>
          </span>
        </div>
        <div :if={@app.notes != []} class="flex flex-col gap-1 px-4 py-2.5 text-[0.8125rem]">
          <span
            :for={note <- @app.notes}
            class="font-semibold"
            style={"color: #{Tags.tone(note.tone)}"}
          >
            {note.text}
          </span>
        </div>
        <.instance_row
          :for={instance <- @app.instances}
          app={@app.name}
          instance={instance}
          limits_open={Map.get(@limits_open, instance.sname, false)}
          distribution={@distribution[instance.sname]}
          distribution_open={Map.has_key?(@distribution, instance.sname)}
          asking={@ask == instance.sname}
          sent={MapSet.member?(@sent, instance.sname)}
        />
        <div
          :if={@ask == {:app, @app.name}}
          class="dx-ask"
          role="group"
          aria-label={"Confirm the restart of every instance of #{@app.name}"}
        >
          <span class="flex-[1_1_320px]">
            <b>Restart every instance of {@app.name}?</b>
            Each instance stops and starts again, one after the other, and its open connections drop.
          </span>
          <button
            id={"app-#{@app.name}-restart-all-confirm"}
            type="button"
            class="dx-btn dx-btn-danger"
            phx-click="restart-app"
            phx-value-name={@app.name}
          >
            Restart all
          </button>
          <button type="button" class="dx-btn" phx-click="cancel-ask">Cancel</button>
        </div>
        <div
          :if={@app.name != "deployex"}
          class="flex flex-wrap gap-2 border-t border-(--dx-base-300) px-4 py-2.5"
        >
          <button
            type="button"
            class="dx-btn"
            aria-label={"Logs of every instance of #{@app.name}"}
            phx-click={dock_open("logs", @app.name, @app.name)}
          >
            Logs
          </button>
          <.link class="dx-btn" navigate={~p"/applications/#{@app.name}/versions"}>Versions and mode</.link>
          <button
            id={"app-#{@app.name}-restart-all"}
            type="button"
            class="dx-btn"
            phx-click="ask"
            phx-value-target={"app:#{@app.name}"}
          >
            Restart all…
          </button>
        </div>
      </div>
    </div>
    """
  end

  attr :app, :map, required: true
  attr :cleared, :any, required: true
  attr :asking, :boolean, required: true, doc: "whether Clear ghosted waits for its confirmation"

  defp alert(%{cleared: version} = assigns) when is_binary(version) do
    ~H"""
    <div class="dx-callout dx-callout-muted" role="status">
      <Icons.icon name="ghost" class="dx-gh dx-callout-ico" />
      <div class="dx-callout-text">
        <b>Cleared ghosted {@cleared}</b>
        <span>This host can deploy it again.</span>
      </div>
    </div>
    """
  end

  defp alert(assigns) do
    ~H"""
    <div class={"dx-callout dx-callout-#{@app.alert.tone}"}>
      <Icons.icon :if={@app.alert.kind == :ghosted} name="ghost" class="dx-gh dx-callout-ico" />
      <Icons.icon
        :if={@app.alert.kind != :ghosted}
        name="arrow-path"
        stroke="2"
        class="dx-ico dx-callout-ico"
      />
      <div :if={@asking} class="dx-callout-text">
        <b>Clear ghosted {@app.alert.version}?</b>
        <span>This host can deploy it again on its next check.</span>
      </div>
      <div :if={@asking} class="dx-callout-acts">
        <button
          id={"app-#{@app.name}-clear-ghosted-confirm"}
          type="button"
          class="dx-btn dx-btn-danger"
          phx-click="clear-ghosted"
          phx-value-name={@app.name}
          phx-value-version={@app.alert.version}
        >
          Clear ghosted {@app.alert.version}
        </button>
        <button
          id={"app-#{@app.name}-clear-ghosted-cancel"}
          type="button"
          class="dx-btn"
          phx-click="cancel-ask"
        >
          Cancel
        </button>
      </div>
      <div :if={!@asking} class="dx-callout-text">
        <b>{@app.alert.title}</b>
        <span>{@app.alert.detail}</span>
        <span :if={@app.alert[:commands]} class="dx-callout-cmds">
          Failed: <code :for={command <- @app.alert.commands} class="dx-cmd">{command}</code>
        </span>
      </div>
      <div :if={!@asking} class="dx-callout-acts">
        <button
          :if={@app.alert.kind == :ghosted}
          id={"app-#{@app.name}-clear-ghosted"}
          type="button"
          class="dx-btn"
          phx-click="ask"
          phx-value-target={"ghosted:#{@app.name}"}
        >
          Clear ghosted {@app.alert.version}…
        </button>
        <button
          type="button"
          class="dx-btn"
          aria-label={"Logs of #{@app.name}"}
          phx-click={dock_open("logs", @app.name, @app.name)}
        >
          View logs
        </button>
      </div>
    </div>
    """
  end

  attr :app, :string, required: true
  attr :item, :map, required: true
  attr :index, :integer, required: true

  # A problem that needs action now, under the row with the app collapsed
  defp urgent(assigns) do
    ~H"""
    <div id={"app-#{@app}-urgent-#{@index}"} class="dx-callout dx-callout-error">
      <Icons.icon
        name={
          case @item.kind do
            :tls -> "lock-closed"
            :otp -> "signal"
            _limit -> "warning"
          end
        }
        stroke="2"
        class="dx-ico dx-callout-ico"
      />
      <div class="dx-callout-text">
        <b>{@item.title}</b>
        <span>{@item.detail}</span>
      </div>
      <div class="dx-callout-acts">
        <.link
          :if={@item.kind == :tls}
          class="dx-btn no-underline"
          navigate={~p"/logs/history?#{%{source: "events"}}"}
        >
          View events
        </.link>
        <button
          :if={@item.kind in [:limit, :otp]}
          type="button"
          class="dx-btn"
          phx-click="show-instance"
          phx-value-name={@app}
          phx-value-sname={@item.sname}
        >
          Show instance
        </button>
      </div>
    </div>
    """
  end

  attr :app, :string, required: true
  attr :instance, :map, required: true
  attr :limits_open, :boolean, required: true
  attr :distribution, :map, default: nil, doc: "from `DeployexWeb.Instances.distribution/2`"
  attr :distribution_open, :boolean, default: false
  attr :asking, :boolean, required: true
  attr :sent, :boolean, required: true

  defp instance_row(assigns) do
    ~H"""
    <div id={"instance-#{@instance.sname}"}>
      <div class="dx-irow">
        <div class="flex min-w-0 items-center gap-1">
          <button
            id={"instance-#{@instance.sname}-limits"}
            type="button"
            class="dx-iname"
            aria-expanded={to_string(@limits_open)}
            aria-label={"#{if @limits_open, do: "Hide", else: "Show"} the details and limits of #{@instance.sname}"}
            title={@instance.node}
            phx-click="toggle-limits"
            phx-value-sname={@instance.sname}
            phx-value-open={to_string(!@limits_open)}
          >
            <Icons.icon
              name="chevron-right"
              stroke="2.2"
              class={["dx-ico dx-muted size-[13px]", @limits_open && "rotate-90"]}
            />
            <span>{@instance.sname}</span>
          </button>
          <span
            :if={@instance.warnings != []}
            id={"instance-#{@instance.sname}-warnings"}
            class="inline-flex"
            phx-hook="Tip"
          >
            <span
              role="img"
              aria-label={Enum.join(@instance.warnings, ", ")}
              class="inline-flex"
              style={"color: #{Tags.tone(:warning)}"}
            >
              <Icons.icon name="warning" stroke="2" class="dx-ico size-4" />
            </span>
            <span popover="manual" class="dx-tip" aria-hidden="true">
              <span :for={warning <- @instance.warnings} class="block">{warning}</span>
            </span>
          </span>
        </div>
        <div class="flex min-w-0 items-center gap-2">
          <Tags.status
            text={Enum.join(Enum.reject([@instance.status.text, @instance.version], &is_nil/1), " ")}
            tone={@instance.status.tone}
            class="font-medium"
          />
          <.otp
            :if={@instance.running and @instance.otp}
            id={"instance-#{@instance.sname}-otp"}
            otp={@instance.otp}
          />
        </div>
        <.cpu
          id={"instance-#{@instance.sname}-cpu"}
          text={@instance.cpu}
          tip={@instance.cpu_tip}
          class="text-[0.8125rem]"
        />
        <div class="dx-num text-[0.8125rem]">{@instance.memory}</div>
        <.restarts
          :if={@instance.restarts}
          id={"instance-#{@instance.sname}-restarts"}
          restarts={@instance.restarts}
          class="text-[0.8125rem]"
          color={Tags.tone(:muted)}
        />
        <div :if={!@instance.restarts} class="dx-num dx-muted text-[0.8125rem]">--</div>
        <div class="flex items-center gap-1.5">
          <Tags.deploy_tag type={if @instance.deploy == :hot_upgrade, do: :hot, else: :full} />
          <span :if={@instance.up} class="dx-mono dx-muted text-xs">up {@instance.up}</span>
        </div>
        <div class="flex justify-end gap-1">
          <.icon_action
            id={"instance-#{@instance.sname}-logs"}
            icon="lines"
            tip="Logs"
            label={"Logs of #{@instance.sname}"}
            phx-click={dock_open("logs", @instance.sname, @app)}
          />
          <.icon_action
            id={"instance-#{@instance.sname}-shell"}
            icon="command-line"
            tip={@instance.shell}
            label={"#{@instance.shell} on #{@instance.sname}, opens in the dock"}
            phx-click={dock_open("shell", @instance.sname, @app)}
          />
          <span id={"instance-#{@instance.sname}-observer-tip"} class="inline-flex" phx-hook="Tip">
            <.link
              id={"instance-#{@instance.sname}-observer"}
              class="dx-iact dx-iact-icon"
              navigate={~p"/embedded-observer"}
              aria-label={"Open #{@instance.sname} in Observer Web"}
            >
              <Icons.icon name="observer-web" class={nil} gradient={"dx-ow-#{@instance.sname}"} />
            </.link>
            <span popover="manual" class="dx-tip" aria-hidden="true">Observer Web</span>
          </span>
          <.icon_action
            :if={@app != "deployex"}
            id={"instance-#{@instance.sname}-restart"}
            icon={if @sent, do: "check", else: "arrow-path"}
            tip={if @sent, do: "Restart sent", else: "Restart…"}
            label={
              if @sent, do: "Restart sent to #{@instance.sname}", else: "Restart #{@instance.sname}…"
            }
            danger
            phx-click="ask"
            phx-value-target={@instance.sname}
          />
        </div>
      </div>
      <div
        :if={@asking}
        class="dx-ask"
        role="group"
        aria-label={"Confirm the restart of #{@instance.sname}"}
      >
        <span class="flex-[1_1_320px]">
          <b>Restart {@instance.sname}?</b>
          The node stops and starts again, and its open connections drop.
        </span>
        <button
          id={"instance-#{@instance.sname}-restart-confirm"}
          type="button"
          class="dx-btn dx-btn-danger"
          phx-click="restart-instance"
          phx-value-sname={@instance.sname}
        >
          Restart instance
        </button>
        <button type="button" class="dx-btn" phx-click="cancel-ask">Cancel</button>
      </div>
      <div
        :if={@limits_open}
        class="dx-limits"
        role="group"
        aria-label={"Details and limits of #{@instance.sname}"}
      >
        <div class="dx-idetail">
          <dl>
            <div :if={@instance.node} class="dx-drow">
              <dt class="dx-lbl">Node</dt>
              <dd class="dx-mono">
                {@instance.node}<.copy_button
                  id={"instance-#{@instance.sname}-copy-node"}
                  text={@instance.node}
                  label="node name"
                />
              </dd>
            </div>
            <div :if={@instance.urls != []} class="dx-drow">
              <dt class="dx-lbl">{if length(@instance.urls) == 1, do: "URL", else: "URLs"}</dt>
              <dd class="flex flex-wrap gap-x-4">
                <span
                  :for={{url, index} <- Enum.with_index(@instance.urls)}
                  class="inline-flex items-center"
                >
                  <a class="dx-link dx-mono" href={url} target="_blank" rel="noopener noreferrer">
                    {url}<Icons.icon name="external" class="dx-ico ml-1 inline size-3.5" /><span class="sr-only"> (opens in a new tab)</span>
                  </a><.copy_button
                    id={"instance-#{@instance.sname}-copy-url-#{index}"}
                    text={url}
                    label="URL"
                  />
                </span>
              </dd>
            </div>
            <div :if={@instance.ports != []} class="dx-drow">
              <dt class="dx-lbl">{if length(@instance.ports) == 1, do: "Port", else: "Ports"}</dt>
              <dd class="dx-mono">
                {Enum.map_join(@instance.ports, " · ", &"#{&1.key} #{&1.base}")}
              </dd>
            </div>
          </dl>
          <button
            :if={@instance.node}
            id={"instance-#{@instance.sname}-distribution"}
            type="button"
            class="dx-dtoggle"
            aria-expanded={to_string(@distribution_open)}
            aria-controls={"instance-#{@instance.sname}-distribution-rows"}
            phx-click="toggle-distribution"
            phx-value-sname={@instance.sname}
            phx-value-open={to_string(!@distribution_open)}
          >
            <Icons.icon
              name="chevron-right"
              stroke="2.2"
              class={["dx-ico size-[13px]", @distribution_open && "rotate-90"]}
            /> OTP distribution
          </button>
          <dl :if={@distribution_open} id={"instance-#{@instance.sname}-distribution-rows"}>
            <div :if={is_nil(@distribution)} class="dx-drow">
              <dt class="dx-lbl">Distribution</dt>
              <dd class="dx-muted">The node did not answer.</dd>
            </div>
            <div :if={@distribution} class="dx-drow">
              <dt class="dx-lbl">Distribution</dt>
              <dd>
                {@distribution.protocol}, {if @distribution.hidden,
                  do: "hidden node",
                  else: "visible node"}
              </dd>
            </div>
            <div :if={@distribution} class="dx-drow">
              <dt class="dx-lbl">Connected to</dt>
              <dd>
                <span :if={@distribution.groups == []} class="dx-muted">no node</span>
                <span :for={{group, names} <- @distribution.groups} class="block">
                  <span class="dx-muted">{group}:</span>
                  <span class="dx-mono">{Enum.join(names, ", ")}</span>
                </span>
              </dd>
            </div>
          </dl>
        </div>
        <p :if={@instance.limits == []} class="dx-muted col-span-3 text-[0.8125rem]">
          No reading yet. The limits come from the instance's Observer Web metrics, so an app without
          observer_web shows none.
        </p>
        <div :for={limit <- @instance.limits} class="dx-lim">
          <div class="flex items-baseline justify-between gap-2">
            <span class="dx-lbl">{limit.name}</span>
            <span
              class="dx-mono text-[0.8125rem] font-semibold"
              style={"color: #{level_text(limit.level)}"}
            >
              {limit.percent_text}
            </span>
          </div>
          <span
            class="dx-lbar"
            role="meter"
            aria-label={"#{limit.name} at #{limit.percent} percent of the limit"}
            aria-valuemin="0"
            aria-valuemax="100"
            aria-valuenow={limit.percent}
          >
            <i style={"width: #{max(limit.percent, 1.5)}%; background: #{level_fill(limit.level)}"}></i>
            <b :if={limit.restart_at} class="dx-lmark" style={"left: #{limit.restart_at}%"}></b>
          </span>
          <div class="flex flex-wrap justify-between gap-x-2 text-xs">
            <span class="dx-mono dx-muted whitespace-nowrap">{limit.count} of {limit.limit}</span>
            <span :if={limit.watch} class="dx-muted whitespace-nowrap">{limit.watch}</span>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :icon, :string, required: true
  attr :tip, :string, required: true, doc: "the short name in the tooltip"
  attr :label, :string, required: true, doc: "the accessible name"
  attr :danger, :boolean, default: false
  attr :rest, :global

  # An icon button of an instance row, named by a tooltip on hover and keyboard focus
  defp icon_action(assigns) do
    ~H"""
    <span id={"#{@id}-tip"} class="inline-flex" phx-hook="Tip">
      <button
        id={@id}
        type="button"
        class={["dx-iact dx-iact-icon", @danger && "dx-iact-er"]}
        aria-label={@label}
        {@rest}
      >
        <Icons.icon name={@icon} class={nil} />
      </button>
      <span popover="manual" class="dx-tip" aria-hidden="true">{@tip}</span>
    </span>
    """
  end

  attr :id, :string, required: true

  attr :restarts, :map,
    required: true,
    doc: "the count, whether a crash is among them, the totals by cause and the latest restarts"

  attr :class, :string, default: nil
  attr :color, :string, required: true, doc: "the color with no crash"

  attr :show_sname, :boolean,
    default: false,
    doc: "whether the latest restarts name their instance"

  defp restarts(%{restarts: %{count: 0}} = assigns) do
    ~H"""
    <div id={@id} class={["dx-num", @class]} style={"color: #{@color}"} phx-hook="Tip">
      0<span class="sr-only">: No restarts</span>
      <span popover="manual" class="dx-tip" aria-hidden="true">No restarts</span>
    </div>
    """
  end

  # The tooltip holds links to the logs at each restart, so the count is a button that takes the focus
  defp restarts(assigns) do
    ~H"""
    <div id={@id} class={["dx-num", @class]} phx-hook="Tip">
      <button
        type="button"
        class="dx-restarts"
        style={"color: #{if @restarts.crash, do: Tags.tone(:warning), else: @color}"}
        aria-label={@restarts.label}
      >
        {@restarts.count}
      </button>
      <span popover="manual" class="dx-tip">
        <span class="block font-semibold">{@restarts.totals}</span>
        <.link
          :for={restart <- @restarts.latest}
          id={"#{@id}-#{restart.id}"}
          class="dx-tip-link"
          navigate={restart.href}
        >
          <span class="dx-mono">{restart.time}</span>
          <span :if={@show_sname} class="dx-mono">{restart.sname}</span>
          {restart.text}
        </.link>
      </span>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :otp, :atom, required: true, doc: ":connected or :not_connected"

  # Whether DeployEx reaches a running instance over OTP, at a glance next to its status
  defp otp(assigns) do
    assigns =
      assign(
        assigns,
        :text,
        if(assigns.otp == :connected,
          do: "OTP connected",
          else: "OTP not connected. Check the cookie and the TLS distribution settings."
        )
      )

    ~H"""
    <span id={@id} class="inline-flex" phx-hook="Tip">
      <span
        role="img"
        aria-label={@text}
        class="inline-flex"
        style={"color: #{Tags.tone(if @otp == :connected, do: :success, else: :error)}"}
      >
        <Icons.icon name="signal" stroke="2" class="dx-ico size-4" />
      </span>
      <span popover="manual" class="dx-tip" aria-hidden="true">{@text}</span>
    </span>
    """
  end

  attr :id, :string, required: true
  attr :text, :string, required: true
  attr :tip, :string, default: nil, doc: "the share with its scale, like 0.4% of 10 cores"
  attr :class, :string, default: nil

  defp cpu(assigns) do
    ~H"""
    <div :if={!@tip} id={@id} class={["dx-num", @class]}>{@text}</div>
    <div :if={@tip} id={@id} class={["dx-num", @class]} phx-hook="Tip">
      {@text}<span class="sr-only">: {@tip}</span>
      <span popover="manual" class="dx-tip" aria-hidden="true">{@tip}</span>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :text, :string, required: true
  attr :label, :string, required: true, doc: "what it copies, like node name"

  # A small button that copies text, named by its tooltip, which says Copied after a click
  defp copy_button(assigns) do
    ~H"""
    <span id={"#{@id}-tip"} class="inline-flex align-middle" phx-hook="Tip">
      <button
        id={@id}
        type="button"
        class="dx-copy"
        data-copy={@text}
        aria-label={"Copy the #{@label}"}
        phx-click={JS.dispatch("dx:copy")}
      >
        <Icons.icon name="copy" class="size-3.5" />
      </button>
      <span popover="manual" class="dx-tip" aria-hidden="true" data-text={"Copy the #{@label}"}>
        Copy the {@label}
      </span>
    </span>
    """
  end

  defp problems([_problem]), do: "1 problem"
  defp problems(problems), do: "#{length(problems)} problems"

  @doc """
  The window event that opens a dock tab, or focuses it when it is open.
  """
  def dock_open(kind, target, app) do
    JS.dispatch("dx:dock-open", detail: %{kind: kind, target: target, app: app})
  end

  defp level_fill(2), do: "var(--dx-error)"
  defp level_fill(1), do: "var(--dx-warning)"
  defp level_fill(_level), do: "var(--dx-info)"

  defp level_text(2), do: "var(--dx-error-text)"
  defp level_text(1), do: "var(--dx-warning-text)"
  defp level_text(_level), do: "var(--dx-muted)"
end
