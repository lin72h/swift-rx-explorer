#!/usr/bin/env elixir
#
# Lane A probe-vector validator (swift-r64z). Reads the per-probe *.raw.json outputs
# captured by run_lane_a_probes.zsh, validates each vector set's structure, and
# emits a single provenance-enveloped swift-r64z artifact (proper JSON assembly —
# shell only orchestrates). Fail-closed: a probe whose output is missing, not
# JSON, has a vector_count mismatch, lacks a required key, or has an unknown
# probe_id is marked valid=false; the aggregate all_valid reflects any failure.
#
# Proven in --self-test.

defmodule SwiftGate.ParseProbeVectors do
  @required %{
    "lane-a.type-layout.v1" =>
      MapSet.new(["probe_id", "type", "kind", "size", "stride", "alignment"]),
    "lane-a.integer-overflow.v1" =>
      MapSet.new(["probe_id", "expr", "checked_value", "checked_overflow", "wrapped_value"]),
    "lane-a.runtime-metadata.v1" =>
      MapSet.new(["probe_id", "type", "mirror_display_style", "is_class", "conforms_to_describable", "witness_desc_result", "size", "alignment"]),
    "lane-a.string-internals.v1" =>
      MapSet.new(["probe_id", "label", "char_count", "utf8_count", "utf16_count", "scalar_count", "is_empty", "is_ascii", "estimated_small_string"])
  }

  def main(["--self-test", tmpdir]) do
    File.mkdir_p!(tmpdir)
    result = self_test(tmpdir)
    File.write!(Path.join(tmpdir, "negative-controls.json"), JSON.encode!(result) <> "\n")
    if result["passed"], do: System.halt(0), else: System.halt(1)
  end

  def main(argv) do
    opts = parse_args(argv)
    run_dir = required!(opts, "--run-dir")
    out_path = required!(opts, "--out")

    result = build_result(run_dir, opts)
    File.write!(out_path, JSON.encode!(result) <> "\n")
  end

  defp build_result(run_dir, opts) do
    raw_files =
      Path.wildcard(Path.join(run_dir, "*.raw.json"))
      |> Enum.reject(&String.ends_with?(&1, ".raw.json.raw.json"))
      |> Enum.sort()

    probes =
      Enum.map(raw_files, fn path ->
        name = Path.basename(path, ".raw.json")
        rc = read_rc(Path.join(run_dir, name <> ".rc"))
        src_sha = read_invocation_sha(Path.join(run_dir, "invocation.txt"), name)
        validate_probe(name, path, rc, src_sha)
      end)

    total_vectors =
      probes |> Enum.filter(& &1["valid"]) |> Enum.map(& &1["vector_count"]) |> Enum.sum()

    %{
      "schema" => "swift-r64z.lane-a-vectors.v1",
      "artifact_kind" => "validation",
      "disposition_authority" => "none — raw-fact producer output; not a gatekeeper disposition",
      "created_at_utc" => utc_now(),
      "mode" => Map.get(opts, "--mode", "explorer"),
      "namespace" => "swift-r64z / mx-a64z",
      "lane" => "A",
      "run_dir" => run_dir,
      "repo" => repo_info(),
      "host" => %{
        "os" => command_text("uname", ["-a"]),
        "macos" => command_text("sw_vers", ["-productVersion"])
      },
      "toolchain" => read_toolchain(Path.join(run_dir, "invocation.txt")),
      "tool_versions" => tool_versions(),
      "probes" => probes,
      "aggregate" => %{
        "probes_run" => length(probes),
        "probes_valid" => Enum.count(probes, & &1["valid"]),
        "probes_failed" => Enum.count(probes, &(!&1["valid"])),
        "all_valid" => probes != [] && Enum.all?(probes, & &1["valid"]),
        "total_vectors" => total_vectors
      }
    }
  end

  defp validate_probe(name, path, rc, src_sha) do
    text = File.read!(path)

    cond do
      rc != nil and rc != 0 ->
        probe_record(name, nil, src_sha, rc, false, 0, 0, [], ["nonzero_return_code"])

      String.trim(text) == "" ->
        probe_record(name, nil, src_sha, rc, false, 0, 0, [], ["empty_output"])

      true ->
        case JSON.decode(text) do
          {:ok, data} ->
            validate_shape(name, data, src_sha, rc)

          {:error, reason} ->
            probe_record(name, nil, src_sha, rc, false, 0, 0, [], ["json_parse_error: #{inspect(reason)}"])
        end
    end
  end

  defp validate_shape(name, data, src_sha, rc) do
    probe_id = data["probe_id"]
    vectors = data["vectors"]
    declared_count = data["vector_count"]
    observed = if is_list(vectors), do: length(vectors), else: nil

    issues =
      []
      |> then(fn acc ->
        if not is_binary(probe_id), do: ["missing_probe_id" | acc], else: acc
      end)
      |> then(fn acc ->
        if not (is_integer(declared_count) and is_list(vectors) and declared_count == observed),
          do: ["vector_count_mismatch" | acc],
          else: acc
      end)
      |> then(fn acc ->
        if probe_id != nil and not Map.has_key?(@required, probe_id),
          do: ["unknown_probe_id" | acc],
          else: acc
      end)
      |> then(fn acc ->
        case missing_required_keys(probe_id, vectors) do
          [] -> acc
          keys -> ["missing_required_keys:#{Enum.join(keys, ",")}" | acc]
        end
      end)

    valid = issues == []
    probe_record(name, probe_id, src_sha, rc, valid, declared_count, observed, vectors || [], issues)
  end

  defp missing_required_keys(nil, _), do: ["probe_id"]

  defp missing_required_keys(_probe_id, vectors) when not is_list(vectors), do: ["vectors_not_list"]

  defp missing_required_keys(probe_id, vectors) do
    required = Map.get(@required, probe_id, MapSet.new(["probe_id"]))

    Enum.flat_map(vectors, fn v ->
      present = v |> Map.keys() |> MapSet.new()
      MapSet.difference(required, present) |> MapSet.to_list()
    end)
    |> Enum.uniq()
  end

  defp probe_record(name, probe_id, src_sha, rc, valid, declared, observed, vectors, issues) do
    %{
      "name" => name,
      "probe_id" => probe_id,
      "source_sha256" => src_sha,
      "return_code" => rc,
      "valid" => valid,
      "vector_count" => declared,
      "observed_vector_count" => observed,
      "issues" => issues,
      "vectors" => vectors
    }
  end

  defp read_rc(path) do
    case File.read(path) do
      {:ok, text} -> text |> String.trim() |> Integer.parse() |> case do
        {n, _} -> n
        _ -> nil
      end
      _ -> nil
    end
  end

  defp read_invocation_sha(path, name) do
    case File.read(path) do
      {:ok, text} ->
        Regex.run(~r/probe=#{name} src_sha256=([0-9a-f]+)/, text)

      _ ->
        nil
    end
    |> case do
      [_, sha] -> sha
      _ -> nil
    end
  end

  defp read_toolchain(path) do
    case File.read(path) do
      {:ok, text} ->
        %{
          "swift_version" => field(text, "swift_version="),
          "swift_bin" => field(text, "swift_bin="),
          "swift_sha256" => field(text, "swift_sha256="),
          "macos" => field(text, "macos=")
        }

      _ ->
        %{}
    end
  end

  defp field(text, prefix) do
    case Regex.run(~r/#{Regex.escape(prefix)}(.+)/, text) do
      [_, v] -> String.trim(v)
      _ -> nil
    end
  end

  defp repo_info do
    path = File.cwd!()

    %{
      "path" => path,
      "head" => git(path, ["rev-parse", "HEAD"]),
      "dirty" => git_dirty?(path)
    }
  end

  defp git_dirty?(path) do
    case System.cmd("git", ["-C", path, "status", "--short"], stderr_to_stdout: true) do
      {text, 0} -> String.trim(text) != ""
      _ -> false
    end
  end

  defp git(path, args) do
    case System.cmd("git", ["-C", path] ++ args, stderr_to_stdout: true) do
      {text, 0} -> String.trim(text)
      _ -> nil
    end
  end

  defp tool_versions do
    %{
      "elixir" => command_text("elixir", ["--version"]),
      "otp" => otp_release(),
      "zig" => command_text("zig", ["version"])
    }
  end

  defp otp_release, do: :erlang.system_info(:otp_release) |> to_string()

  defp command_text(command, args) do
    case System.cmd(command, args, stderr_to_stdout: true) do
      {text, 0} -> String.trim(text)
      {text, rc} -> "rc=#{rc}: #{String.trim(text)}"
    end
  rescue
    _ -> nil
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

  # --- self-test ---
  defp self_test(tmpdir) do
    good = Path.join(tmpdir, "type_layout.raw.json")
    mismatch = Path.join(tmpdir, "mismatch.raw.json")
    missing_key = Path.join(tmpdir, "missing_key.raw.json")
    bogus = Path.join(tmpdir, "bogus.raw.json")
    broken = Path.join(tmpdir, "broken.raw.json")

    write_probe(good, "lane-a.type-layout.v1", [
      %{"probe_id" => "lane-a.type-layout.v1", "type" => "Int", "kind" => "builtin",
        "size" => 8, "stride" => 8, "alignment" => 8}
    ])

    write_probe(mismatch, "lane-a.type-layout.v1", [
      %{"probe_id" => "lane-a.type-layout.v1", "type" => "Int", "kind" => "builtin",
        "size" => 8, "stride" => 8, "alignment" => 8},
      %{"probe_id" => "lane-a.type-layout.v1", "type" => "Int8", "kind" => "builtin",
        "size" => 1, "stride" => 1, "alignment" => 1}
    ], 3)

    write_probe(missing_key, "lane-a.type-layout.v1", [
      # missing "stride"
      %{"probe_id" => "lane-a.type-layout.v1", "type" => "Int", "kind" => "builtin",
        "size" => 8, "alignment" => 8}
    ])

    write_probe(bogus, "lane-a.bogus.v1", [
      %{"probe_id" => "lane-a.bogus.v1", "whatever" => 1}
    ])

    File.write!(broken, "this is not json {{{")

    # rc files: good probes rc=0
    Enum.each(["type_layout", "mismatch", "missing_key", "bogus", "broken"], fn n ->
      File.write!(Path.join(tmpdir, n <> ".rc"), "0\n")
    end)

    File.write!(Path.join(tmpdir, "invocation.txt"), "probe=type_layout src_sha256=fixed\n")

    cases =
      [{good, "good_well_formed", true},
       {mismatch, "vector_count_mismatch_fails_closed", false},
       {missing_key, "missing_required_key_fails_closed", false},
       {bogus, "unknown_probe_id_fails_closed", false},
       {broken, "json_parse_error_fails_closed", false}]
      |> Enum.map(fn {path, id, expected_valid} ->
        rec = validate_probe(Path.basename(path, ".raw.json"), path, 0, "fixed")
        actual = rec["valid"]
        %{"id" => id, "expected" => if(expected_valid, do: "pass", else: "fail_closed"),
          "actual" => if(actual, do: "pass", else: "fail_closed"),
          "passed" => actual == expected_valid}
      end)

    %{
      "schema" => "negative-controls.v1",
      "artifact_kind" => "negative_controls",
      "created_at_utc" => utc_now(),
      "mode" => "explorer",
      "validator" => "parse_swift_probe_vectors.exs",
      "validator_pin" => sha256_file(__ENV__.file),
      "cases" => cases,
      "passed" => Enum.all?(cases, & &1["passed"])
    }
  end

  defp write_probe(path, probe_id, vectors, count \\ nil) do
    out = %{"probe_id" => probe_id, "vector_count" => count || length(vectors), "vectors" => vectors}
    File.write!(path, JSON.encode!(out))
  end

  defp sha256_file(path) do
    path
    |> File.stream!(2048, [])
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end
end

SwiftGate.ParseProbeVectors.main(System.argv())
