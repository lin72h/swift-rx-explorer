#!/usr/bin/env elixir

defmodule SwiftGate.ParseLit do
  @subsystems [
    "Reflection/typeref",
    "C++ interop",
    "TSan",
    "Runtime units",
    "Macros",
    "Concurrency/Synchronization",
    "Misc"
  ]

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
    watchdog_path = Map.get(opts, "--watchdog-log")
    out_path = required!(opts, "--out")

    raw = File.read!(raw_path)
    watchdog = if watchdog_path, do: File.read!(watchdog_path), else: ""

    result = build_result(opts, raw_path, raw, watchdog_path, watchdog)
    File.write!(out_path, JSON.encode!(result) <> "\n")
  end

  defp self_test(tmpdir) do
    good_raw = Path.join(tmpdir, "fixture-good.raw.log")
    issue_accounting_raw = Path.join(tmpdir, "fixture-issue-89943-accounting.raw.log")
    missing_accounting_raw = Path.join(tmpdir, "fixture-missing-accounting.raw.log")
    watchdog_log = Path.join(tmpdir, "fixture.watchdog.log")
    rc_file = Path.join(tmpdir, "fixture.rc")

    File.write!(good_raw, """
    -- Testing: 5 tests, 4 workers --
    PASS: Swift(freebsd-x86_64) :: test/Interpreter/basic.swift (1 of 5)
    XFAIL: Swift(freebsd-x86_64) :: validation-test/stdlib/known.swift (2 of 5)
    FAIL: Swift(freebsd-x86_64) :: validation-test/TSan/race.swift (3 of 5)
    UNSUPPORTED: Swift(freebsd-x86_64) :: test/Unsupported/skip.swift (4 of 5)
    XPASS: Swift(freebsd-x86_64) :: validation-test/Macros/now-passing.swift (5 of 5)
    Testing Time: 1.23s
      Unsupported      : 1
      Passed           : 1
      Expectedly Failed: 1
      Failed           : 1
      Unexpectedly Passed : 1
    Total Discovered Tests: 5
    """)

    File.write!(issue_accounting_raw, """
    Testing Time: 8106.19s
    Total Discovered Tests: 21177
      Unsupported        :  3283 (15.50%)
      Passed             : 17813 (84.11%)
      Expectedly Failed  :    53 (0.25%)
      Failed             :    26 (0.12%)
      Unexpectedly Passed :    1 (0.00%)
    """)

    File.write!(missing_accounting_raw, """
    PASS: Swift(freebsd-x86_64) :: test/Interpreter/basic.swift (1 of 1)
    """)

    File.write!(watchdog_log, """
    watchdog-kill pid=123 ppid=10 pgid=10 cpu_seconds=901 budget_seconds=900 command=validation-test/stdlib/Synchronization/lock-free-stress.swift
    watchdog-finish child_pid=10 exit_code=124 killed_count=1
    """)

    File.write!(rc_file, "1\n")

    base_opts = %{
      "--mode" => "gatekeeper",
      "--tier" => "fast",
      "--run-id" => "parser-self-test",
      "--target" => "check-swift-freebsd-x86_64",
      "--lit-jobs" => "4",
      "--watchdog-cpu-seconds" => "900",
      "--rc-file" => rc_file,
      "--repo-path" => File.cwd!(),
      "--source-path" => tmpdir,
      "--source-pin" => "fixture",
      "--swiftc" => "/usr/bin/true"
    }

    good = build_result(base_opts, good_raw, File.read!(good_raw), watchdog_log, File.read!(watchdog_log))
    issue = build_result(base_opts, issue_accounting_raw, File.read!(issue_accounting_raw), nil, "")
    missing = build_result(base_opts, missing_accounting_raw, File.read!(missing_accounting_raw), nil, "")

    cases = [
      %{
        "id" => "accounting_exact",
        "mutation" => "none",
        "expected" => "pass",
        "actual" => if(good["accounting"]["total"] == 5 and good["accounting"]["failed"] == 1, do: "pass", else: "fail"),
        "passed" => good["accounting"]["total"] == 5 and good["accounting"]["failed"] == 1
      },
      %{
        "id" => "unexpectedly_passed_accounting",
        "mutation" => "none",
        "expected" => "pass",
        "actual" => if(good["accounting"]["unexpectedly_passed"] == 1 and length(good["tests"]["unexpectedly_passed"]) == 1, do: "pass", else: "fail"),
        "passed" => good["accounting"]["unexpectedly_passed"] == 1 and length(good["tests"]["unexpectedly_passed"]) == 1
      },
      %{
        "id" => "issue_89943_accounting_format",
        "mutation" => "real-format accounting block from swiftlang/swift#89943",
        "expected" => "pass",
        "actual" => if(issue["accounting"]["total"] == 21177 and issue["accounting"]["unsupported"] == 3283 and issue["accounting"]["unexpectedly_passed"] == 1, do: "pass", else: "fail"),
        "passed" => issue["accounting"]["total"] == 21177 and issue["accounting"]["unsupported"] == 3283 and issue["accounting"]["unexpectedly_passed"] == 1
      },
      %{
        "id" => "tsan_failure_grouped",
        "mutation" => "none",
        "expected" => "pass",
        "actual" => if(length(good["failures_by_subsystem"]["TSan"]) == 1, do: "pass", else: "fail"),
        "passed" => length(good["failures_by_subsystem"]["TSan"]) == 1
      },
      %{
        "id" => "watchdog_hang_recorded",
        "mutation" => "watchdog kill line added",
        "expected" => "pass",
        "actual" => if(length(good["tests"]["hung"]) == 1, do: "pass", else: "fail"),
        "passed" => length(good["tests"]["hung"]) == 1
      },
      %{
        "id" => "missing_accounting_not_synthesized",
        "mutation" => "removed terminal accounting",
        "expected" => "fail_closed",
        "actual" => if(get_in(missing, ["run", "lit_accounting_present"]) == false and missing["accounting"]["total"] == nil, do: "fail_closed", else: "accepted"),
        "passed" => get_in(missing, ["run", "lit_accounting_present"]) == false and missing["accounting"]["total"] == nil
      }
    ]

    %{
      "schema" => "negative-controls.v1",
      "artifact_kind" => "negative_controls",
      "created_at_utc" => utc_now(),
      "mode" => "gatekeeper",
      "validator" => "parse_swift_lit.exs",
      "validator_pin" => sha256_file(__ENV__.file),
      "tmpdir" => tmpdir,
      "cases" => cases,
      "passed" => Enum.all?(cases, & &1["passed"])
    }
  end

  defp build_result(opts, raw_path, raw, watchdog_path, watchdog) do
    status_events = parse_status_events(raw)
    watchdog_hangs = parse_watchdog_hangs(watchdog)
    accounting = parse_accounting(raw)
    rc = read_int(Map.get(opts, "--rc-file"))
    swiftc = Map.get(opts, "--swiftc")

    tests = %{
      "passed" => names_for(status_events, "passed"),
      "failed" => names_for(status_events, "failed"),
      "expectedly_failed" => names_for(status_events, "expectedly_failed"),
      "unexpectedly_passed" => names_for(status_events, "unexpectedly_passed"),
      "unsupported" => names_for(status_events, "unsupported"),
      "hung" => watchdog_hangs ++ names_for(status_events, "hung")
    }

    all_failures =
      Enum.map(tests["failed"], &%{"name" => &1, "status" => "failed"}) ++
        Enum.map(tests["hung"], &%{"name" => &1, "status" => "hung"}) ++
        Enum.map(tests["unexpectedly_passed"], &%{"name" => &1, "status" => "unexpectedly_passed"})

    %{
      "schema" => "swift-lit-run.v1",
      "artifact_kind" => "validation",
      "created_at_utc" => utc_now(),
      "mode" => Map.get(opts, "--mode", "gatekeeper"),
      "tier" => required!(opts, "--tier"),
      "run" => %{
        "id" => required!(opts, "--run-id"),
        "target" => required!(opts, "--target"),
        "invocation" => read_optional(Map.get(opts, "--invocation-file")),
        "lit_jobs" => read_int_value(required!(opts, "--lit-jobs")),
        "watchdog_cpu_budget_seconds" => read_int_value(required!(opts, "--watchdog-cpu-seconds")),
        "return_code" => rc,
        "lit_started" => String.contains?(raw, "-- Testing:") or String.contains?(raw, "Testing Time:"),
        "lit_accounting_present" => accounting_present?(accounting),
        "lit_accounting_complete" => accounting_complete?(accounting),
        "attempt_consumed" => String.contains?(raw, "-- Testing:") or String.contains?(raw, "Testing Time:")
      },
      "repo" => repo_info(Map.get(opts, "--repo-path", File.cwd!())),
      "source" => %{
        "path" => required!(opts, "--source-path"),
        "pin" => required!(opts, "--source-pin")
      },
      "host" => %{
        "os" => command_text("uname", ["-a"]),
        "freebsd_version" => command_text("freebsd-version", [])
      },
      "toolchain" => %{
        "swiftc" => swiftc,
        "swiftc_version" => if(swiftc, do: command_text(swiftc, ["--version"]), else: nil),
        "swiftc_sha256" => if(swiftc, do: sha256_file(swiftc), else: nil)
      },
      "inputs" => input_records(Enum.reject([raw_path, watchdog_path], &is_nil/1)),
      "tool_versions" => tool_versions(),
      "raw_digest" => %{
        "raw_log_sha256" => sha256_file(raw_path),
        "watchdog_log_sha256" => if(watchdog_path, do: sha256_file(watchdog_path), else: nil)
      },
      "accounting" => accounting,
      "status_counts_observed" => observed_counts(tests),
      "status_observation" => status_observation(accounting, tests),
      "tests" => tests,
      "failures_by_subsystem" => group_failures(all_failures),
      "watchdog" => %{
        "kill_lines" => kill_lines(watchdog),
        "finish_lines" => finish_lines(watchdog)
      },
      "deferred" => [
        "Exact flaky TSan/Synchronization waiver list must be derived from raw watchdog evidence."
      ]
    }
  end

  defp parse_status_events(raw) do
    raw
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/^\s*(PASS|FAIL|XFAIL|XPASS|UNSUPPORTED|TIMEOUT):\s+(.+)$/, line) do
        [_, status, rest] ->
          [%{"status" => normalize_status(status), "name" => normalize_name(rest), "raw" => line}]

        _ ->
          []
      end
    end)
  end

  defp parse_accounting(raw) do
    lines = String.split(raw, "\n")

    %{
      "total" => find_count(lines, ~r/^\s*Total Discovered Tests:\s*(\d+)/),
      "unsupported" => find_count(lines, ~r/^\s*Unsupported(?: Tests)?\s*:\s*(\d+)/),
      "passed" => find_count(lines, ~r/^\s*Passed(?: Tests)?\s*:\s*(\d+)/),
      "expectedly_failed" => find_count(lines, ~r/^\s*Expectedly Failed(?: Tests)?\s*:\s*(\d+)/),
      "failed" => find_count(lines, ~r/^\s*Failed(?: Tests)?\s*:\s*(\d+)/),
      "unexpectedly_passed" => find_count(lines, ~r/^\s*Unexpectedly Passed(?: Tests)?\s*:\s*(\d+)/)
    }
  end

  defp parse_watchdog_hangs(""), do: []

  defp parse_watchdog_hangs(text) do
    text
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      if String.contains?(line, "watchdog-kill ") do
        case Regex.run(~r/command=(.*)$/, line) do
          [_, command] -> [String.trim(command)]
          _ -> [String.trim(line)]
        end
      else
        []
      end
    end)
  end

  defp normalize_status("PASS"), do: "passed"
  defp normalize_status("FAIL"), do: "failed"
  defp normalize_status("XFAIL"), do: "expectedly_failed"
  defp normalize_status("XPASS"), do: "unexpectedly_passed"
  defp normalize_status("UNSUPPORTED"), do: "unsupported"
  defp normalize_status("TIMEOUT"), do: "hung"

  defp normalize_name(rest) do
    rest
    |> String.replace(~r/\s+\(\d+\s+of\s+\d+\)\s*$/, "")
    |> String.trim()
  end

  defp names_for(events, status) do
    events
    |> Enum.filter(&(&1["status"] == status))
    |> Enum.map(& &1["name"])
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp group_failures(failures) do
    base = Map.new(@subsystems, &{&1, []})

    Enum.reduce(failures, base, fn failure, acc ->
      subsystem = classify(failure["name"])
      Map.update!(acc, subsystem, fn entries -> entries ++ [failure] end)
    end)
  end

  defp classify(name) do
    cond do
      name =~ ~r/(reflection|reflect|typeref|remote-mirror|swift-reflection|TypeRef)/i -> "Reflection/typeref"
      name =~ ~r/(cxx|c\+\+|cpp|interop)/i -> "C++ interop"
      name =~ ~r/(tsan|threadsanitizer)/i -> "TSan"
      name =~ ~r/(unittests\/runtime|runtime\/|SwiftRuntime|RuntimeUnit)/ -> "Runtime units"
      name =~ ~r/(macro|CompilerPlugin|swift-syntax|plugin)/i -> "Macros"
      name =~ ~r/(concurrency|Synchronization|lock-free|atomics)/i -> "Concurrency/Synchronization"
      true -> "Misc"
    end
  end

  defp find_count(lines, regex) do
    Enum.find_value(lines, fn line ->
      case Regex.run(regex, line) do
        [_, value] -> String.to_integer(value)
        _ -> nil
      end
    end)
  end

  defp accounting_present?(accounting) do
    Enum.any?(accounting, fn {_key, value} -> not is_nil(value) end)
  end

  defp accounting_complete?(accounting) do
    Enum.all?(["total", "unsupported", "passed", "expectedly_failed", "failed", "unexpectedly_passed"], fn key ->
      not is_nil(Map.get(accounting, key))
    end)
  end

  defp observed_counts(tests) do
    Map.new(tests, fn {key, values} -> {key, length(values)} end)
  end

  defp status_observation(accounting, tests) do
    observed_total =
      tests
      |> Map.values()
      |> Enum.map(&length/1)
      |> Enum.sum()

    accounting_total =
      ["unsupported", "passed", "expectedly_failed", "failed", "unexpectedly_passed"]
      |> Enum.map(&Map.get(accounting, &1))
      |> Enum.reject(&is_nil/1)
      |> Enum.sum()

    %{
      "observed_status_lines" => observed_total,
      "accounted_status_total" => accounting_total,
      "status_lines_match_accounting" => accounting_present?(accounting) and observed_total == accounting_total,
      "complete_pass_set_proven" => accounting_present?(accounting) and observed_total == accounting_total
    }
  end

  defp kill_lines(text), do: select_lines(text, "watchdog-kill ")
  defp finish_lines(text), do: select_lines(text, "watchdog-finish")

  defp select_lines(text, needle) do
    text
    |> String.split("\n")
    |> Enum.filter(&String.contains?(&1, needle))
  end

  defp repo_info(path) do
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

  defp input_records(paths) do
    Enum.map(paths, &%{"path" => &1, "sha256" => sha256_file(&1)})
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

  defp sha256_file(path) do
    path
    |> File.stream!(2048, [])
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp read_optional(nil), do: nil
  defp read_optional(path), do: File.read!(path)

  defp read_int(nil), do: nil
  defp read_int(path), do: path |> File.read!() |> String.trim() |> read_int_value()

  defp read_int_value(value) when is_integer(value), do: value
  defp read_int_value(value), do: String.to_integer(value)

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

  defp required!(opts, key) do
    Map.get(opts, key) || raise "missing required argument #{key}"
  end
end

SwiftGate.ParseLit.main(System.argv())
