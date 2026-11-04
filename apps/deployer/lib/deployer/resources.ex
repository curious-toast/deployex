defmodule Deployer.Resources do
  @moduledoc """
  CPU and memory of each running instance, for every language.

  `Deployer.Resources.Server` samples them every few seconds, with no change in the monitored app: CPU from
  the runtime counter of the instance's BEAM over RPC, memory from its OS process. The process, port and
  atom counts come from ObserverWeb, through `Sentinel.Watchdog`.
  """

  alias Deployer.Resources.Server

  @type t :: %__MODULE__{
          sname: String.t(),
          cpu: float() | nil,
          cores: pos_integer() | nil,
          memory: non_neg_integer() | nil,
          sampled_at: DateTime.t() | nil
        }

  defstruct [:sname, :cpu, :cores, :memory, :sampled_at]

  @doc """
  Returns the last sample of an instance, or nil when it has none.

  `cpu` is a percentage of all the host's `cores`, `memory` the resident memory in bytes.
  """
  @spec get(sname :: String.t()) :: t() | nil
  def get(sname), do: Server.get(sname)
end
