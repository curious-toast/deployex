defmodule Deployer.Engine.Deployment do
  @moduledoc """
  Structure to handle the deployment structure
  """
  @typedoc """
  `deploying?` says the worker put a version into service and is waiting for the
  application to report it running, which is what completes a deployment. It is set
  together with the rollback timer and cleared by the report that closes it.

  `:stopped` marks an instance that a DeployEx restart in a rollback window kept on an older
  version without starting it.

  `version` is the version the worker put into service on `sname`, so the worker reads it
  without a catalog read.

  `fall_back?` marks a window that a fallback opened, so a failure does not ghost the fallback
  version.
  """
  @type t :: %__MODULE__{
          state: :init | :active | :stopped,
          timer_ref: reference() | nil,
          sname: String.t() | nil,
          version: String.t() | nil,
          ports: list(),
          deploying?: boolean(),
          fall_back?: boolean()
        }

  @derive Jason.Encoder

  defstruct state: :init,
            timer_ref: nil,
            sname: nil,
            version: nil,
            ports: [],
            deploying?: false,
            fall_back?: false
end
