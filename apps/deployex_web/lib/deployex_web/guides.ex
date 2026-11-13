defmodule DeployexWeb.Guides do
  @moduledoc """
  Links to the guides on GitHub, at the tag of the running version.
  """

  alias DeployexWeb.Helper

  @doc """
  Returns the link to a guide folder's README, and to one of its sections when given. A pre-release has no
  tag, so its links go to main.
  """
  @spec url(guide :: String.t(), section :: String.t() | nil) :: String.t()
  def url(guide, section \\ nil) do
    version = Helper.deployex_version()
    ref = if String.contains?(version, "-"), do: "main", else: version
    page = "https://github.com/deployex/deployex/blob/#{ref}/guides/docs/#{guide}/README.md"
    if section, do: "#{page}##{section}", else: page
  end
end
