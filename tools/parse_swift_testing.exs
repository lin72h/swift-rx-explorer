#!/usr/bin/env elixir
#
# swift-testing native-output parser (swift-testing dimension).
#
# Parses the output of `swift test` for an apple/swift-testing package:
#   ✔  Test "<name>" passed after D seconds.           (or: Test func() passed ...)
#   ✔  Test "<name>" with N test cases passed after ...
#   ✘  Test "<name>" failed after D seconds.
#   ➜  Test "<name>" skipped. | was cancelled after D seconds: "..."
#   ✔  Suite "<name>" passed after D seconds.
#   ✔  Test run with N tests in M suites passed after D seconds.
#
# This is NOT lit output (no PASS:/FAIL:/UNSUPPORTED: markers), so parse_swift_lit.exs
# does not apply. Emits swift-testing-run.v1 with a `tests` map in the same shape
# diff_swift_regression.exs consumes (skipped -> "unsupported"), so the accepted
# regression diff validator is reused unchanged.
#
# Fail-closed invariants (proven in --self-test):
#   - accounting_present: >=1 "Test run with N tests" summary, else do not synthesize.
#   - test_counts_match_accounting: observed(passed+failed+skipped) == accounted_total.
#   - suite_counts_match_accounting: observed(suite passed+failed) == accounted_suites.
#   - result_consistent: aggregate "passed" IFF no ✘ observed (and rc==0 when given).

defmodule SwiftGate.ParseSwiftTesting do
  @result_re ~r/^(✔|✘)\s+(Test|Suite)\s+(.+?)\s+(?:with\s+\d+\s+test cases\s+)?(passed|failed)\s+after\s+([0-9.]+)\s+seconds\.\s*$/
  @skip_re ~r/^➜\s+Test\s+(.+?)\s+(?:skipped|was cancelled)\b.*$/
  @summary_re ~r/^(?:✔|✘)?\s*Test run with\s+(\d+)\s+tests in\s+(\d+)\s+suites\s+(passed|failed)\s+after\s+([0-9.]+)\s+seconds\.\s*$/
  @libver_re ~r/^\xe2\x86\xb3\s*Testing Library Version:\s*(.+?)\s*$/

  def main(["--self-test", tmpdir]) do
    File.mkdir_p!(tmpdir)
    result = self_test(tmpdir)
    out = Path.join(tmpdir, "negative-controls.json")
    File.write!(out, JSON.encode!(result) <> "\n")
    if result["passed"], do: System.halt(0), else: System.halt(1)
  end

  def main(argv) do
    opts = parse_args(argv)

    raw_path = required!(opts, "--raw-log")
    out_path = required!(opts, "--out")

    raw = File.read!(raw_path)

    result = build_result(opts, raw_path, raw)
    File.write!(out_path, JSON.encode!(result) <> "\n")
  end

  defp self_test(tmpdir) do
    good_raw = Path.join(tmpdir, "fixture-good.raw.log")
    failed_raw = Path.join(tmpdir, "fixture-failed.raw.log")
    inconsistent_raw = Path.join(tmpdir, "fixture-passed-but-failed.raw.log")
    count_delta_raw = Path.join(tmpdir, "fixture-count-delta.raw.log")
    missing_raw = Path.join(tmpdir, "fixture-missing-accounting.raw.log")

    File.write!(good_raw, """
    ◇ Test run started.
    ◇ Suite "Alpha Tests" started.
    ✔ Test alpha() passed after 0.01 seconds.
    ✔ Test "beta with cases" with 3 test cases passed after 0.02 seconds.
    ➜ Test "gamma skipped" skipped: "time-sensitive"
    ✔ Suite "Alpha Tests" passed after 0.05 seconds.
    ✔ Test run with 3 tests in 1 suites passed after 0.05 seconds.
    """)

    File.write!(failed_raw, """
    ◇ Test run started.
    ✘ Test "boom" failed after 0.03 seconds.
    ✔ Test ok() passed after 0.01 seconds.
    ✘ Test run with 2 tests in 1 suites failed after 0.04 seconds.
    """)

    # Summary claims "passed" but a ✘ is observed -> inconsistent.
    File.write!(inconsistent_raw, """
    ✔ Test ok() passed after 0.01 seconds.
    ✘ Test "hidden failure" failed after 0.02 seconds.
    ✔ Test run with 2 tests in 1 suites passed after 0.03 seconds.
    """)

    # Summary claims 3 tests but only 2 observed -> count delta.
    File.write!(count_delta_raw, """
    ✔ Test one() passed after 0.01 seconds.
    ✔ Test two() passed after 0.01 seconds.
    ✔ Test run with 3 tests in 1 suites passed after 0.02 seconds.
    """)

    # No "Test run with" summary at all -> missing accounting, must not synthesize pass.
    File.write!(missing_raw, """
    ✔ Test only() passed after 0.01 seconds.
    """)

    base_opts = %{
      "--mode" => "explorer",
      "--run-id" => "parser-self-test",
      "--source-path" => tmpdir,
      "--source-pin" => "fixture"
    }

    good = build_result(base_opts, good_raw, File.read!(good_raw))
    failed = build_result(base_opts, failed_raw, File.read!(failed_raw))
    inconsistent = build_result(base_opts, inconsistent_raw, File.read!(inconsistent_raw))
    delta = build_result(base_opts, count_delta_raw, File.read!(count_delta_raw))
    missing = build_result(base_opts, missing_raw, File.read!(missing_raw))

    cases = [
      %{
        "id" => "good_accounting_consistent",
        "mutation" => "none",
        "expected" => "pass",
        "actual" => pass_str(get_in(good, ["status_observation", "complete_pass_set_proven"])),
        "passed" => get_in(good, ["status_observation", "complete_pass_set_proven"]) == true
      },
      %{
        "id" => "skipped_mapped_to_unsupported",
        "mutation" => "none",
        "expected" => "pass",
        "actual" => if(length(good["tests"]["unsupported"]) == 1 and good["accounting"]["total"] == 3, do: "pass", else: "fail"),
        "passed" => length(good["tests"]["unsupported"]) == 1 and good["accounting"]["total"] == 3
      },
      %{
        "id" => "failure_recorded_and_summary_failed",
        "mutation" => "one ✘ added",
        "expected" => "pass",
        "actual" => if(length(failed["tests"]["failed"]) == 1 and failed["accounting"]["aggregate_result"] == "failed", do: "pass", else: "fail"),
        "passed" => length(failed["tests"]["failed"]) == 1 and failed["accounting"]["aggregate_result"] == "failed"
      },
      %{
        "id" => "passed_but_failure_observed_fails_closed",
        "mutation" => "summary says passed but a ✘ observed",
        "expected" => "fail_closed",
        "actual" => pass_str(get_in(inconsistent, ["status_observation", "complete_pass_set_proven"])),
        "passed" => get_in(inconsistent, ["status_observation", "complete_pass_set_proven"]) == false
      },
      %{
        "id" => "test_count_delta_fails_closed",
        "mutation" => "accounting 3 tests but 2 observed",
        "expected" => "fail_closed",
        "actual" => pass_str(get_in(delta, ["status_observation", "complete_pass_set_proven"])),
        "passed" => get_in(delta, ["status_observation", "complete_pass_set_proven"]) == false
      },
      %{
        "id" => "missing_accounting_not_synthesized",
        "mutation" => "removed terminal 'Test run with' accounting",
        "expected" => "fail_closed",
        "actual" => if(get_in(missing, ["run", "accounting_present"]) == false and missing["accounting"]["total"] == nil and get_in(missing, ["status_observation", "complete_pass_set_proven"]) == false, do: "fail_closed", else: "accepted"),
        "passed" => get_in(missing, ["run", "accounting_present"]) == false and missing["accounting"]["total"] == nil and get_in(missing, ["status_observation", "complete_pass_set_proven"]) == false
      }
    ]

    %{
      "schema" => "negative-controls.v1",
      "artifact_kind" => "negative_controls",
      "created_at_utc" => utc_now(),
      "mode" => "explorer",
      "validator" => "parse_swift_testing.exs",
      "validator_pin" => sha256_file(__ENV__.file),
      "tmpdir" => tmpdir,
      "cases" => cases,
      "passed" => Enum.all?(cases, & &1["passed"])
    }
  end

  defp build_result(opts, raw_path, raw) do
    events = parse_result_events(raw)
    skips = parse_skips(raw)
    summaries = parse_summaries(raw)
    accounting = build_accounting(summaries)
    rc = read_int(Map.get(opts, "--rc-file"))
    swiftc = Map.get(opts, "--swiftc")

    # Raw event-name lists (with duplicates) drive the count invariant so it matches
    # swift-testing's accounting total (which counts every test instance). The `tests`
    # map lists are deduped+sorted afterwards for stable diff keys.
    passed_raw = for e <- events, e["kind"] == "Test" and e["status"] == "passed", do: e["name"]
    failed_raw = for e <- events, e["kind"] == "Test" and e["status"] == "failed", do: e["name"]
    suite_passed_raw = for e <- events, e["kind"] == "Suite" and e["status"] == "passed", do: e["name"]
    suite_failed_raw = for e <- events, e["kind"] == "Suite" and e["status"] == "failed", do: e["name"]
    skipped_raw = skips

    passed = Enum.uniq(Enum.sort(passed_raw))
    failed = Enum.uniq(Enum.sort(failed_raw))
    skipped = Enum.uniq(Enum.sort(skipped_raw))
    suite_passed = Enum.uniq(Enum.sort(suite_passed_raw))
    suite_failed = Enum.uniq(Enum.sort(suite_failed_raw))

    observed_total = length(passed_raw) + length(failed_raw) + length(skipped_raw)
    observed_suite_total = length(suite_passed_raw) + length(suite_failed_raw)
    accounting_present = accounting["total"] != nil

    test_counts_match =
      accounting_present and observed_total == accounting["total"]

    suite_counts_match =
      accounting_present and observed_suite_total == accounting["suites"]

    aggregate_passed = accounting["aggregate_result"] == "passed"
    no_failures = failed == []
    rc_zero = rc in [nil, 0]
    result_consistent = (aggregate_passed == no_failures) and (rc_zero or not is_nil(rc))

    complete =
      accounting_present and test_counts_match and suite_counts_match and result_consistent

    %{
      "schema" => "swift-testing-run.v1",
      "artifact_kind" => "validation",
      "disposition_authority" => "none — raw-fact producer output; not a gatekeeper disposition",
      "created_at_utc" => utc_now(),
      "mode" => Map.get(opts, "--mode", "explorer"),
      "tier" => "swift-testing",
      "run" => %{
        "id" => Map.get(opts, "--run-id", "unspecified"),
        "accounting_present" => accounting_present,
        "complete_pass_set_proven" => complete,
        "return_code" => rc,
        "attempt_consumed" => true
      },
      "repo" => repo_info(Map.get(opts, "--repo-path", File.cwd!())),
      "source" => %{
        "path" => required!(opts, "--source-path"),
        "pin" => required!(opts, "--source-pin")
      },
      "host" => %{
        "os" => command_text("uname", ["-a"]),
        "sw_vers" => command_text("sw_vers", ["-productVersion"])
      },
      "toolchain" => %{
        "swiftc" => swiftc,
        "swiftc_version" => if(swiftc, do: command_text(swiftc, ["--version"]), else: nil),
        "swiftc_sha256" => if(swiftc, do: sha256_file(swiftc), else: nil),
        "testing_library_version" => parse_library_version(raw)
      },
      "inputs" => input_records([raw_path]),
      "tool_versions" => tool_versions(),
      "raw_digest" => %{"raw_log_sha256" => sha256_file(raw_path)},
      "accounting" => accounting,
      "status_counts_observed" => %{
        "passed" => length(passed_raw),
        "failed" => length(failed_raw),
        "skipped" => length(skipped_raw),
        "unique_passed" => length(passed),
        "suites_passed" => length(suite_passed_raw),
        "suites_failed" => length(suite_failed_raw)
      },
      "status_observation" => %{
        "observed_test_total" => observed_total,
        "accounted_test_total" => accounting["total"],
        "test_counts_match_accounting" => test_counts_match,
        "observed_suite_total" => observed_suite_total,
        "accounted_suite_total" => accounting["suites"],
        "suite_counts_match_accounting" => suite_counts_match,
        "aggregate_passed" => aggregate_passed,
        "no_failures_observed" => no_failures,
        "result_consistent" => result_consistent,
        "complete_pass_set_proven" => complete
      },
      "tests" => %{
        "passed" => passed,
        "failed" => failed,
        "unsupported" => skipped,
        "hung" => [],
        "expectedly_failed" => [],
        "unexpectedly_passed" => []
      },
      "suites" => %{
        "passed" => suite_passed,
        "failed" => suite_failed
      }
    }
  end

  defp parse_result_events(raw) do
    raw
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      if String.contains?(line, "Test run with") do
        []
      else
        case Regex.run(@result_re, line) do
          [_, symbol, kind, name, status, _dur] ->
            [%{"symbol" => symbol, "kind" => kind, "name" => strip_quotes(name), "status" => status}]

          _ ->
            []
        end
      end
    end)
  end

  defp parse_skips(raw) do
    raw
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      case Regex.run(@skip_re, line) do
        [_, name] -> [strip_quotes(name)]
        _ -> []
      end
    end)
  end

  defp parse_summaries(raw) do
    raw
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      case Regex.run(@summary_re, line) do
        [_, tests, suites, result, dur] ->
          [%{"tests" => String.to_integer(tests), "suites" => String.to_integer(suites),
             "result" => result, "duration_seconds" => String.to_float(dur)}]

        _ ->
          []
      end
    end)
  end

  defp build_accounting([]), do: %{"total" => nil, "suites" => nil, "runs" => [], "aggregate_result" => nil}

  defp build_accounting(runs) do
    %{
      "total" => Enum.map(runs, & &1["tests"]) |> Enum.sum(),
      "suites" => Enum.map(runs, & &1["suites"]) |> Enum.sum(),
      "runs" => runs,
      "aggregate_result" => if(Enum.any?(runs, &(&1["result"] == "failed")), do: "failed", else: "passed")
    }
  end

  defp parse_library_version(raw) do
    raw
    |> String.split("\n")
    |> Enum.find_value(fn line ->
      case Regex.run(@libver_re, line) do
        [_, ver] -> String.trim(ver)
        _ -> nil
      end
    end)
  end

  defp strip_quotes(name) do
    name |> String.replace(~r/^"/, "") |> String.replace(~r/"$/, "")
  end

  defp pass_str(true), do: "pass"
  defp pass_str(false), do: "fail_closed"

  defp repo_info(path) do
    %{"path" => path, "head" => git(path, ["rev-parse", "HEAD"]), "dirty" => git_dirty?(path)}
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

  defp input_records(paths), do: Enum.map(paths, &%{"path" => &1, "sha256" => sha256_file(&1)})

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

  defp sha256_file(path) do
    path
    |> File.stream!(2048, [])
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp read_int(nil), do: nil
  defp read_int(path), do: path |> File.read!() |> String.trim() |> String.to_integer()

  defp utc_now do
    DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
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

SwiftGate.ParseSwiftTesting.main(System.argv())
