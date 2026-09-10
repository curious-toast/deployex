defmodule Deployer.SelfUpgrade.Executor.Shell do
  @moduledoc """
  Executes a self-upgrade by shelling out to the deployex.sh installer.

  `hot_update/1` runs `deployex.sh --hot-update`; `restart_update/1` runs
  `deployex.sh --update`. Both pass `--set-version` so the target version comes
  from the reconciler, not the on-disk config.
  """

  @behaviour Deployer.SelfUpgrade.Executor.Adapter

  require Logger

  @impl true
  @spec hot_update(String.t()) :: :ok | {:error, any()}
  def hot_update(version), do: run("--hot-update", version)

  @impl true
  @spec restart_update(String.t()) :: :ok | {:error, any()}
  def restart_update(version), do: run("--update", version)

  defp run(op, version) do
    args = [op, config_file(), "--set-version", version] ++ dist_args()

    case System.cmd(script(), args, stderr_to_stdout: true) do
      {out, 0} ->
        Logger.info("Self-upgrade #{op} to #{version} ok: #{out}")
        :ok

      {out, code} ->
        Logger.error("Self-upgrade #{op} to #{version} failed (#{code}): #{out}")
        {:error, {:exit, code}}
    end
  end

  defp opts, do: Application.get_env(:deployer, Deployer.SelfUpgrade, [])
  defp script, do: opts()[:script] || "/opt/deployex_installer/deployex.sh"
  defp config_file, do: opts()[:config_file] || "/home/root/deployex.yaml"

  defp dist_args do
    case opts()[:dist_base_url] do
      nil -> []
      url -> ["--dist", url]
    end
  end
end
