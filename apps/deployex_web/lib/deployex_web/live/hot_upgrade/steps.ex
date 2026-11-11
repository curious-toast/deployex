defmodule DeployexWeb.HotUpgrade.Steps do
  @moduledoc """
  The steps of a DeployEx self-upgrade, for its LEDs, from its progress messages.

  Each step message is sent before its step runs, so the last one names the step in flight. The outcome
  message comes after the step that ended the run.
  """

  alias Deployer.HotUpgrade.Progress

  @names [
    "Starting the upgrade",
    "Unpacking release",
    "Creating relup file",
    "Checking release can be installed",
    "Resolving the runtime configuration",
    "Adding the runtime configuration to the relup",
    "Installing release",
    "Making the release permanent"
  ]

  @type step_state :: :pending | :current | :done | :failed

  @doc """
  The number of steps.
  """
  @spec total() :: pos_integer()
  def total, do: length(@names)

  @doc """
  One `{state, label}` pair per step. A step that was announced has its message as the label.
  """
  @spec states(Progress.t()) :: [{step_state(), String.t()}]
  def states(%Progress{state: state} = progress) do
    at = at(progress)
    announced = announced(progress)

    @names
    |> Enum.with_index(1)
    |> Enum.map(fn {name, step} ->
      {step_state(step, at, state), Enum.at(announced, step - 1, name)}
    end)
  end

  @doc """
  The number of the step in flight, or of the step that failed. After a success it is the last step.
  """
  @spec at(Progress.t()) :: pos_integer()
  def at(%Progress{state: :success}), do: total()

  def at(%Progress{} = progress),
    do: progress |> announced() |> length() |> max(1) |> min(total())

  @doc """
  The line under the LEDs: the step in flight, or the step that failed.
  """
  @spec line(Progress.t()) :: String.t()
  def line(%Progress{state: state} = progress) do
    at = at(progress)
    {_state, label} = progress |> states() |> Enum.at(at - 1)
    prefix = if state == :error, do: "Failed at step", else: "Step"

    "#{prefix} #{at} of #{total()}: #{label}"
  end

  # The messages that announce a step, without the outcome
  defp announced(%Progress{state: :running, messages: messages}), do: messages
  defp announced(%Progress{messages: messages}), do: Enum.drop(messages, -1)

  defp step_state(_step, _at, :success), do: :done
  defp step_state(step, at, _state) when step < at, do: :done
  defp step_state(step, at, :running) when step == at, do: :current
  defp step_state(step, at, :error) when step == at, do: :failed
  defp step_state(_step, _at, _state), do: :pending
end
