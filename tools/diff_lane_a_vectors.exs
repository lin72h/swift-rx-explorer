#!/usr/bin/env elixir
#
# Lane A vector regression-diff (swift-r64z). Compares a banked lane-a-vectors
# baseline against a fresh run's lane-a-vectors.v1 and flags any change in a
# load-bearing field (size/stride/alignment, overflow semantics, witness result,
# string counts) as a regression, plus any baseline vector absent from the run.
# New vectors in the run are observed but non-regressing (an expansion, not a break).
#
# Fail-closed proven in --self-test (fabricated value delta + missing vector).

defmodule SwiftGate.DiffLaneAVectors do
  @compare %{
    "lane-a.type-layout.v1" =>
      %{"key" => "type", "fields" => ["size", "stride", "alignment"]},
    "lane-a.integer-overflow.v1" =>
      %{"key" => "expr", "fields" => ["checked_value", "checked_overflow", "wrapped_value"]},
    "lane-a.runtime-metadata.v1" =>
      %{"key" => "type",
        "fields" => ["mirror_display_style", "is_class", "conforms_to_describable", "witness_desc_result", "size", "alignment"]},
    "lane-a.string-internals.v1" =>
      %{"key" => "label",
        "fields" => ["char_count", "utf8_count", "utf16_count", "scalar_count", "is_empty", "is_ascii", "estimated_small_string"]}
  }

  def main(["--self-test", tmpdir]) do
    File.mkdir_p!(tmpdir)
    result = self_test(tmpdir)
    File.write!(Path.join(tmpdir, "negative-controls.json"), JSON.encode!(result) <> "\n")
    if result["passed"], do: System.halt(0), else: System.halt(1)
  end

  def main([]) do
    IO.puts(:stderr, "usage: diff_lane_a_vectors.exs --baseline-json PATH --run-json PATH --out PATH | --self-test TMPDIR")
    System.halt(2)
  end

  def main(argv) do
    opts = parse_args(argv)
    baseline_path = required!(opts, "--baseline-json")
    run_path = required!(opts, "--run-json")
    out_path = required!(opts, "--out")

    baseline = baseline_path |> File.read!() |> JSON.decode!()
    run = run_path |> File.read!() |> JSON.decode!()

    regressions = diff(baseline, run)

    result = %{
      "schema" => "swift-r64z.lane-a-diff.v1",
      "artifact_kind" => "validation",
      "disposition_authority" => "none — diff observation; gatekeeper disposes",
      "created_at_utc" => utc_now(),
      "mode" => Map.get(opts, "--mode", "explorer"),
      "namespace" => "swift-r64z / mx-a64z",
      "baseline" => %{"path" => baseline_path, "sha256" => sha256_file(baseline_path)},
      "run" => %{"path" => run_path, "sha256" => sha256_file(run_path)},
      "result" => if(regressions == [], do: "pass", else: "fail"),
      "regressions" => regressions,
      "semantics" => %{
        "value_changed" => "any load-bearing field (size/stride/alignment, overflow semantics, witness result, string counts) differs baseline->run",
        "missing_vector" => "a baseline vector (probe_id+key) absent from the run",
        "new_vector" => "run vector not in baseline; observed, non-regressing (expansion)"
      }
    }

    File.write!(out_path, JSON.encode!(result) <> "\n")
    if result["result"] == "pass", do: System.halt(0), else: System.halt(1)
  end

  defp diff(baseline, run) do
    b = index(baseline)
    r = index(run)

    value_changed =
      Enum.flat_map(b, fn {probe_id, bmap} ->
        fields = compare_fields(probe_id)

        Enum.flat_map(bmap, fn {key, bvec} ->
          case Map.get(r[probe_id] || %{}, key) do
            nil -> []
            rvec -> changed_fields(probe_id, key, bvec, rvec, fields)
          end
        end)
      end)

    missing =
      Enum.flat_map(b, fn {probe_id, bmap} ->
        Enum.flat_map(bmap, fn {key, _bvec} ->
          if Map.has_key?(r[probe_id] || %{}, key), do: [], else: [regression("missing_vector", probe_id, key, nil, nil)]
        end)
      end)

    (value_changed ++ missing) |> Enum.sort_by(&{&1["class"], &1["probe_id"], &1["key"]})
  end

  defp changed_fields(probe_id, key, bvec, rvec, fields) do
    diffs =
      Enum.filter(fields, fn f ->
        normalize(Map.get(bvec, f)) != normalize(Map.get(rvec, f))
      end)
      |> Enum.map(& &1)

    case diffs do
      [] -> []
      changed -> [regression("value_changed", probe_id, key, Map.take(bvec, changed), Map.take(rvec, changed))]
    end
  end

  defp normalize(true), do: 1
  defp normalize(false), do: 0
  defp normalize(v), do: v

  defp index(artifact) do
    (artifact["probes"] || [])
    |> Enum.reduce(%{}, fn probe, acc ->
      probe_id = probe["probe_id"]
      key_field = compare_key(probe_id)

      vecs =
        (probe["vectors"] || [])
        |> Enum.reduce(%{}, fn v, m ->
          case Map.get(v, key_field) do
            nil -> m
            k -> Map.put(m, k, v)
          end
        end)

      Map.update(acc, probe_id, vecs, &Map.merge(&1, vecs))
    end)
  end

  defp compare_key(probe_id), do: get_in(@compare, [probe_id, "key"]) || "type"
  defp compare_fields(probe_id), do: get_in(@compare, [probe_id, "fields"]) || []

  defp regression(class, probe_id, key, baseline, run) do
    %{"class" => class, "probe_id" => probe_id, "key" => key, "baseline" => baseline, "run" => run}
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

  # --- self-test ---
  defp self_test(_tmpdir) do
    baseline = fixture([type_layout("Int", 8), type_layout("Int8", 1)])

    value_changed_run = fixture([type_layout("Int", 4), type_layout("Int8", 1)])
    missing_run = fixture([type_layout("Int", 8)])
    identical_run = fixture([type_layout("Int", 8), type_layout("Int8", 1)])

    cases = [
      red("value_changed_size_delta", baseline, value_changed_run),
      red("missing_vector", baseline, missing_run),
      green("identical_passes", baseline, identical_run)
    ]

    %{
      "schema" => "negative-controls.v1",
      "artifact_kind" => "negative_controls",
      "created_at_utc" => utc_now(),
      "mode" => "explorer",
      "validator" => "diff_lane_a_vectors.exs",
      "validator_pin" => sha256_file(__ENV__.file),
      "cases" => cases,
      "passed" => Enum.all?(cases, & &1["passed"])
    }
  end

  defp red(id, baseline, run) do
    result = if diff(baseline, run) == [], do: "pass", else: "fail"
    %{"id" => id, "expected" => "fail", "actual" => result, "passed" => result == "fail"}
  end

  defp green(id, baseline, run) do
    result = if diff(baseline, run) == [], do: "pass", else: "fail"
    %{"id" => id, "expected" => "pass", "actual" => result, "passed" => result == "pass"}
  end

  defp fixture(vectors) do
    %{"schema" => "swift-r64z.lane-a-vectors.v1",
      "probes" => [%{"probe_id" => "lane-a.type-layout.v1", "vectors" => vectors}]}
  end

  defp type_layout(name, size) do
    %{"probe_id" => "lane-a.type-layout.v1", "type" => name, "kind" => "builtin",
      "size" => size, "stride" => size, "alignment" => size}
  end
end

SwiftGate.DiffLaneAVectors.main(System.argv())
