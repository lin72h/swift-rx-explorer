#!/usr/bin/env elixir

defmodule SwiftGate.MakeBaseline do
  def main(argv) do
    opts = parse_args(argv)
    run_json_path = required!(opts, "--run-json")
    out_path = required!(opts, "--out")
    run = run_json_path |> File.read!() |> JSON.decode!()

    baseline =
      run
      |> Map.put("schema", "swift-lit-baseline.v1")
      |> Map.put("artifact_kind", "validation")
      |> Map.put("created_at_utc", utc_now())
      |> Map.put("baseline", %{
        "provisional" => Map.get(opts, "--provisional", "true") == "true",
        "source_run_json" => run_json_path,
        "source_run_json_sha256" => sha256_file(run_json_path),
        "expected_failures" => run["tests"]["failed"] || [],
        "expected_hangs" => run["tests"]["hung"] || [],
        "expected_xfails" => run["tests"]["expectedly_failed"] || [],
        "unsupported" => run["tests"]["unsupported"] || [],
        "waivers" => waiver_paths(opts)
      })

    File.write!(out_path, JSON.encode!(baseline) <> "\n")
  end

  defp waiver_paths(opts) do
    opts
    |> Map.get("--waivers", "")
    |> String.split(",", trim: true)
  end

  defp sha256_file(path) do
    path
    |> File.stream!(2048, [])
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp utc_now do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

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

SwiftGate.MakeBaseline.main(System.argv())
