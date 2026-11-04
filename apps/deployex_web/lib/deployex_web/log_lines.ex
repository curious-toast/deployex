defmodule DeployexWeb.LogLines do
  @moduledoc """
  Log lines for the Logs page, a dock logs tab and the export: stored messages split into lines, the text
  filter, the color of a line, and the read marks.

  A read can hold a message that also waits in the reader's mailbox, since the log server stores a line before
  it broadcasts it. For each instance and stream, a mark keeps the time of the newest message read and the
  messages at that time, and `read?/4` tells a message the read already has.
  """

  alias Sentinel.Logs

  @type pair :: {String.t(), String.t()}

  @doc """
  Splits stored messages into one line per row of text, each with its source, stream and time, and the
  extra fields.
  """
  @spec from_messages(String.t(), String.t(), [map()], map()) :: [map()]
  def from_messages(sname, type, messages, extra \\ %{}) do
    for %{timestamp: timestamp, log: log} <- messages,
        text <- String.split(log || "", ["\n", "\r"], trim: true) do
      Map.merge(
        %{
          id: System.unique_integer([:positive, :monotonic]),
          timestamp: timestamp,
          at: DateTime.from_unix!(timestamp, :millisecond),
          source: sname,
          type: type,
          text: text
        },
        extra
      )
    end
  end

  @doc """
  Whether a line holds the filter text in its message or its source, in any case.
  """
  @spec holds?(map(), String.t()) :: boolean()
  def holds?(_line, ""), do: true

  def holds?(line, filter) do
    needle = String.downcase(filter)

    String.contains?(String.downcase(line.text), needle) or
      String.contains?(String.downcase(line.source), needle)
  end

  @doc """
  Returns the color of a line's message: stderr and errors red, warnings amber.
  """
  @spec color(map()) :: String.t()
  def color(%{type: "stderr"}), do: "var(--dx-error-text)"

  def color(%{type: "event", tone: tone}) when tone in [:error, :ghost],
    do: "var(--dx-error-text)"

  def color(%{type: "event", tone: :warning}), do: "var(--dx-warning-text)"
  def color(%{type: "event"}), do: "var(--dx-base-content)"

  def color(%{text: text}) do
    cond do
      String.contains?(text, "[error]") -> "var(--dx-error-text)"
      String.contains?(text, "[warning]") -> "var(--dx-warning-text)"
      true -> "var(--dx-base-content)"
    end
  end

  @doc """
  Reads the stored messages of each instance and stream with the log server's options. Returns them, and
  the read marks.
  """
  @spec read([pair()], keyword()) :: {[{pair(), [map()]}], map()}
  def read(pairs, options) do
    reads =
      for {sname, type} = pair <- pairs,
          do: {pair, Logs.list_data_by_sname_log_type(sname, type, options)}

    {reads, Map.new(reads, fn {pair, messages} -> {pair, mark(messages)} end)}
  end

  @doc """
  Whether the read behind the marks already holds the message.
  """
  @spec read?(map(), String.t(), String.t(), map()) :: boolean()
  def read?(marks, sname, type, %{timestamp: timestamp, log: log}) do
    case Map.get(marks, {sname, type}, {0, []}) do
      {newest, _logs} when timestamp < newest -> true
      {newest, logs} when timestamp == newest -> log in logs
      _later -> false
    end
  end

  defp mark([]), do: {0, []}

  defp mark(messages) do
    newest = messages |> Enum.map(& &1.timestamp) |> Enum.max()
    {newest, for(%{timestamp: ^newest, log: log} <- messages, do: log)}
  end
end
