#!/usr/bin/env elixir
#
# Derives a swift-testing regression baseline (swift-testing-baseline.v1) from a
# swift-testing-run.v1 produced by parse_swift_testing.exs. The baseline carries
# the same `tests` shape so diff_swift_regression.exs diffs it unchanged.
#
# provisional=false and accept_grade_eligible=true only when the caller supplies
# negative-control evidence (--nc JSON files) whose `passed` is true. Explorer
# emits accept_grade_eligible; it does NOT dispose acceptance (gatekeeper does).

defmodule SwiftGate.MakeSwiftTestingBaseline do
  def main(argv) do
    opts = parse_args(argv)
    run_json_path = required!(opts, "--run-json")
    out_path = required!(opts, "--out")
    run = run_json_path |> File.read!() |> JSON.decode!()

    nc_files = opts |> Map.get("--nc", "") |> String.split(",", trim: true)
    nc_proven = nc_files != [] && Enum.all?(nc_files, &nc_passed?/1)

    waivers = opts |> Map.get("--waivers", "") |> String.split(",", trim: true)

    baseline =
      run
      |> Map.put("schema", "swift-testing-baseline.v1")
      |> Map.put("artifact_kind", "validation")
      |> Map.put("disposition_authority", "none — explorer marks accept_grade_eligible; gatekeeper disposes acceptance")
      |> Map.put("created_at_utc", utc_now())
      |> Map.put("baseline", %{
        "provisional" => false,
        "accept_grade_eligible" => nc_proven,
        "negative_control_proven" => nc_proven,
        "negative_control_evidence" => nc_files,
        "source_run_json" => run_json_path,
        "source_run_json_sha256" => sha256_file(run_json_path),
        "expected_failures" => get_in(run, ["tests", "failed"]) || [],
        "expected_skipped" => get_in(run, ["tests", "unsupported"]) || [],
        "expected_passed_count" => length(get_in(run, ["tests", "passed"]) || []),
        "waivers" => waivers
      })

    File.write!(out_path, JSON.encode!(baseline) <> "\n")

    if nc_proven, do: System.halt(0), else: System.halt(1)
  end

  defp nc_passed?(path) do
    case File.read(path) do
      {:ok, text} ->
        case JSON.decode(text) do
          {:ok, %{"passed" => passed}} -> passed == true
          _ -> false
        end

      _ ->
        false
    end
  end

  defp sha256_file(path) do
    path
    |> File.stream!(2048, [])
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp utc_now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp parse_args(argv) do
    argv
    |> Enum.chunk_every(2)
    |> Enum.reduce(%{}, fn
      [key, value], acc -> Map.put(acc, key, value)
      [key], _acc -> raise "missing value for #{key}"
    end)
  end

  defp required!(opts, key), do: Map.get(opts, key) || raise "missing required argument #{key}"
end

SwiftGate.MakeSwiftTestingBaseline.main(System.argv())
