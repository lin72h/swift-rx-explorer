defmodule Gatekeeper.ValidationAttempt do
  @lit_markers [
    "-- Testing:",
    "Total Discovered Tests:",
    "Unsupported:",
    "Passed:",
    "Expectedly Failed:",
    "Failed:",
    "Unexpectedly Passed:"
  ]

  def main(argv) do
    {opts, _, invalid} =
      OptionParser.parse(argv,
        strict: [
          raw_log: :string,
          kill_log: :string,
          out: :string
        ]
      )

    if invalid != [] or is_nil(opts[:raw_log]) or is_nil(opts[:kill_log]) or is_nil(opts[:out]) do
      IO.puts(:stderr, "usage: classify_validation_attempt.exs --raw-log PATH --kill-log PATH --out PATH")
      System.halt(2)
    end

    raw = File.read!(opts[:raw_log])
    kill = File.read!(opts[:kill_log])
    raw_lines = String.split(raw, "\n", trim: false)
    kill_lines = String.split(kill, "\n", trim: false)

    lit_started = Enum.any?(raw_lines, &String.contains?(&1, "-- Testing:"))
    lit_accounting = Enum.any?(raw_lines, &String.contains?(&1, "Total Discovered Tests:"))
    watchdog_killed = Enum.any?(kill_lines, &String.contains?(&1, "over-budget"))

    hard_stop_lines =
      raw_lines
      |> Enum.filter(fn line ->
        String.contains?(line, "FAILED: [code=1]") or
          String.contains?(line, "Shared object \"lib_CompilerSwiftIDEUtils.so\" not found") or
          String.contains?(line, "ninja: build stopped: subcommand failed.") or
          String.contains?(line, "terminated with a non-zero exit status 1")
      end)

    status =
      cond do
        lit_accounting ->
          "lit_accounting_present"

        lit_started ->
          "lit_started_without_accounting"

        hard_stop_lines != [] ->
          "setup_prerequisite_failure_before_lit"

        true ->
          "unknown_no_lit_accounting"
      end

    report = %{
      schema_version: "1.0",
      raw_log: opts[:raw_log],
      kill_log: opts[:kill_log],
      status: status,
      lit_started: lit_started,
      lit_accounting_present: lit_accounting,
      watchdog_killed_process: watchdog_killed,
      candidate_markers_present: Enum.filter(@lit_markers, &String.contains?(raw, &1)),
      hard_stop_lines: hard_stop_lines,
      watchdog_finish_lines: Enum.filter(kill_lines, &String.contains?(&1, "watchdog-finish"))
    }

    File.write!(opts[:out], JasonLike.encode(report) <> "\n")
  end
end

defmodule JasonLike do
  def encode(value) when is_map(value) do
    entries =
      value
      |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
      |> Enum.map(fn {key, item} -> encode(to_string(key)) <> ":" <> encode(item) end)

    "{" <> Enum.join(entries, ",") <> "}"
  end

  def encode(value) when is_list(value), do: "[" <> Enum.map_join(value, ",", &encode/1) <> "]"
  def encode(value) when is_binary(value), do: "\"" <> escape(value) <> "\""
  def encode(value) when is_boolean(value), do: Atom.to_string(value)
  def encode(nil), do: "null"

  defp escape(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace("\n", "\\n")
    |> String.replace("\r", "\\r")
    |> String.replace("\t", "\\t")
  end
end

Gatekeeper.ValidationAttempt.main(System.argv())
