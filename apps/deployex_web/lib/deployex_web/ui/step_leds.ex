defmodule DeployexWeb.UI.StepLeds do
  @moduledoc """
  A row of square LEDs, one per step, read at a glance.

  Each LED names its step and its state in its tooltip and its label, and the done and failed LEDs carry an
  icon, so the color is never the only cue. The compact row is for a place that shows the step as text next
  to it, so screen readers skip it.
  """
  use Phoenix.Component

  alias DeployexWeb.UI.Icons

  @state_text %{pending: "Pending", current: "In progress", done: "Done", failed: "Failed"}

  @doc """
  Renders one LED per `{state, label}` pair, where the state is `:pending`, `:current`, `:done` or `:failed`.
  """
  attr :id, :string, required: true
  attr :label, :string, default: nil, doc: "the name of the row, required unless compact"
  attr :steps, :list, required: true
  attr :compact, :boolean, default: false

  def row(%{compact: true} = assigns) do
    ~H"""
    <span id={@id} class="dx-leds dx-leds-compact" aria-hidden="true">
      <span :for={{state, _label} <- @steps} class={["dx-led", "dx-led-#{state}"]}></span>
    </span>
    """
  end

  def row(assigns) do
    assigns = assign(assigns, :items, Enum.with_index(assigns.steps, 1))

    ~H"""
    <div id={@id} class="dx-leds" role="list" aria-label={@label}>
      <span
        :for={{{state, label}, index} <- @items}
        id={"#{@id}-#{index}"}
        phx-hook="Tip"
        class="dx-led-wrap"
        role="listitem"
      >
        <span
          tabindex="0"
          class={["dx-led", "dx-led-#{state}"]}
          aria-label={"Step #{index}, #{state_text(state)}: #{label}"}
        >
          <Icons.icon :if={state == :done} name="check" stroke="3" class="dx-led-ico" />
          <Icons.icon :if={state == :failed} name="x-mark" stroke="3" class="dx-led-ico" />
        </span>
        <span popover="manual" class="dx-tip" aria-hidden="true">{state_text(state)}: {label}</span>
      </span>
    </div>
    """
  end

  defp state_text(state), do: Map.fetch!(@state_text, state)
end
