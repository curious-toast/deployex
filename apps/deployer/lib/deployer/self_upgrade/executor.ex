defmodule Deployer.SelfUpgrade.Executor do
  @moduledoc """
  Runs a DeployEx self-upgrade through the configured executor adapter.
  """

  @behaviour Deployer.SelfUpgrade.Executor.Adapter

  @impl true
  @spec hot_update(String.t()) :: :ok | {:error, any()}
  def hot_update(version), do: default().hot_update(version)

  @impl true
  @spec restart_update(String.t()) :: :ok | {:error, any()}
  def restart_update(version), do: default().restart_update(version)

  defp default, do: Application.fetch_env!(:deployer, __MODULE__)[:adapter]
end
