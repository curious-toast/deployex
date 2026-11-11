defmodule Deployer.HotUpgrade.Progress do
  @moduledoc """
  The hot upgrade that runs now for an application, or its last one, as its progress messages announced it.

  Each step message is sent before its step runs. The outcome message comes last, when the run ends.
  """

  @type t :: %__MODULE__{
          sname: String.t() | nil,
          from_version: String.t() | nil,
          to_version: String.t() | nil,
          state: :running | :success | :error,
          messages: [String.t()],
          updated_at: DateTime.t() | nil
        }

  defstruct sname: nil,
            from_version: nil,
            to_version: nil,
            state: :running,
            messages: [],
            updated_at: nil
end
