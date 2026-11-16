defmodule DeployexWeb.HotUpgrade.Events do
  @moduledoc """
  The hot upgrade events that the self-upgrade views follow.

  Connected DeployEx peers share the PubSub, so an event from another host is dropped. The table holds the run,
  so any event from this host is a reason to read it again.
  """

  @doc "A hot upgrade progress or complete event that this host sent"
  defguard from_this_host?(event)
           when (is_tuple(event) and tuple_size(event) == 4 and
                   elem(event, 0) == :hot_upgrade_progress and
                   elem(event, 1) == node()) or
                  (is_tuple(event) and tuple_size(event) == 5 and
                     elem(event, 0) == :hot_upgrade_complete and
                     elem(event, 1) == node())
end
