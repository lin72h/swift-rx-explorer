#!/usr/bin/env elixir
#
# Derives a Lane A regression baseline (swift-r64z.lane-a-baseline.v1) from a
# lane-a-vectors.v1 produced by parse_swift_probe_vectors.exs. The baseline
# carries the same probes/vectors shape so diff_lane_a_vectors.exs diffs it
# unchanged. provisional=false / accept_grade_eligible=true only when the caller
# supplies negative-control evidence (--nc) whose `passed` is true. Explorer marks
# accept_grade_eligible; gatekeeper disposes acceptance.

defmodule SwiftGate.MakeLaneABaseline do
  def main(argv) do
    opts = parse_args(argv)
    vectors_path = required!(opts, "--vectors-json")
    out_path = required!(opts, "--out")
    vectors = vectors_path |> File.read!() |> JSON.decode!()

    nc_files = opts |> Map.get("--nc", "") |> String.split(",", trim: true)
    nc_proven = nc_files != [] && Enum.all?(nc_files, &nc_passed?/1)

    waivers = opts |> Map.get("--waivers", "") |> String.split(",", trim: true)

    probe_ids =
      (vectors["probes"] || [])
      |> Enum.filter(& &1["valid"])
      |> Enum.map(& &1["probe_id"])

    baseline =
      vectors
      |> Map.put("schema", "swift-r64z.lane-a-baseline.v1")
      |> Map.put("disposition_authority", "none — explorer marks accept_grade_eligible; gatekeeper disposes acceptance")
      |> Map.put("created_at_utc", utc_now())
      |> Map.put("baseline", %{
        "provisional" => false,
        "accept_grade_eligible" => nc_proven,
        "negative_control_proven" => nc_proven,
        "negative_control_evidence" => nc_files,
        "source_vectors_json" => vectors_path,
        "source_vectors_json_sha256" => sha256_file(vectors_path),
        "expected_probe_ids" => probe_ids,
        "expected_total_vectors" => get_in(vectors, ["aggregate", "total_vectors"]),
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
    path |> File.stream!(2048, []) |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final() |> Base.encode16(case: :lower)
  end

  defp utc_now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp parse_args(argv) do
    argv |> Enum.chunk_every(2) |> Enum.reduce(%{}, fn
      [k, v], acc -> Map.put(acc, k, v)
      [k], _ -> raise "missing value for #{k}"
    end)
  end

  defp required!(opts, k), do: Map.get(opts, k) || raise "missing required argument #{k}"
end

SwiftGate.MakeLaneABaseline.main(System.argv())
