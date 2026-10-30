#!/usr/bin/env elixir
#
# op-236: summarizes the raw logs written by probes/op-236/build_run.zsh
# (macOS reference run of every upstream libdispatch 6.4.0 test) into
# op236-summary.v1 JSON and a Markdown table with the briefed rmxOS result
# beside each file. Reads raw logs only; never edits them. A run counts as
# pass only with exit 0 and no [FAIL] line; anything not recorded stays null.
#
#   elixir summarize_op236.exs --logs <dir> --json <out> --md <out>
#   elixir summarize_op236.exs --self-test <tmpdir>

defmodule SwiftGate.SummarizeOp236 do
  # rmxOS as briefed (swift-sdk op-224 run 5, adx01, 36 registered)
  @rmx_pass ~w(after api apply c99 cascade context_for_key data debug drift group
               io_muxed io_net io_pipe overcommit pingpong plusplus priority priority2
               queue_finalizer read read2 select sema starfish suspend_timer timer
               timer_bit31 timer_bit63 timer_set_time timer_short timer_timeout)
             |> Enum.map(&("dispatch_" <> &1))
  @rmx_fail %{
    "dispatch_io" => "fail: does not build (struct rlimit without <sys/resource.h>)",
    "dispatch_io_pipe_close" => "fail",
    "dispatch_concur" => "fail",
    "dispatch_readsync" => "fail",
    "dispatch_thread_name" => "fail"
  }
  @support ~w(bsdtests dispatch_test func generic_win_port bsdtestharness bsdtestsummarize)

  # zsh reports death by signal n as 128+n; 255 is a plain exit(-1) (bsdtests'
  # _exit(_test_exit_code)), so only 129..159 decode as signals.
  defguard signal_rc?(rc) when rc > 128 and rc < 160

  def main(["--self-test", dir]), do: self_test(dir)

  def main(argv) do
    opts = argv |> Enum.chunk_every(2) |> Map.new(fn [k, v] -> {k, v} end)
    rows = summarize(Map.fetch!(opts, "--logs"))

    doc = %{
      "schema" => "op236-summary.v1",
      "artifact_kind" => "validation",
      "created_at_utc" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "mode" => "explorer",
      "source" => %{"path" => Map.fetch!(opts, "--logs")},
      "rows" => rows
    }

    File.write!(Map.fetch!(opts, "--json"), JSON.encode!(doc) <> "\n")
    File.write!(Map.fetch!(opts, "--md"), markdown(rows))
  end

  def summarize(logs) do
    logs
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".build.rc"))
    |> Enum.map(&String.replace_suffix(&1, ".build.rc", ""))
    |> Enum.reject(&String.starts_with?(&1, "_"))
    |> Enum.sort()
    |> Enum.map(&row(logs, &1))
  end

  defp row(logs, name) do
    build_rc = read_int(Path.join(logs, name <> ".build.rc"))
    build_log = read(Path.join(logs, name <> ".build.log")) || ""

    runs =
      for i <- 1..5, status = read(Path.join(logs, "#{name}.run#{i}.status")), status != nil do
        run(logs, name, i, status)
      end

    macos = macos_result(name, build_rc, runs)
    rmx = rmx_result(name)

    %{
      "name" => name,
      "built" => build_rc == 0,
      "build_rc" => build_rc,
      "first_error" => first_error(build_log),
      "runs" => runs,
      "macos" => macos,
      "rmxos" => rmx,
      "verdict" => verdict(name, macos, rmx)
    }
  end

  defp run(logs, name, i, status) do
    out = read(Path.join(logs, "#{name}.run#{i}.out")) || ""
    [rc_s | _] = Regex.run(~r/rc=(\d+)/, status, capture: :all_but_first)
    rc = String.to_integer(rc_s)
    elapsed = case Regex.run(~r/elapsed_s=([\d.]+)/, status) do
      [_, e] -> Float.round(String.to_float(e), 3)
      _ -> nil
    end
    fails = Regex.scan(~r/^\[FAIL\].*$/m, out) |> List.flatten()

    %{
      "run" => i,
      "rc" => rc,
      "outcome" => outcome(rc, fails),
      "signal" => if(signal_rc?(rc), do: rc - 128, else: nil),
      "elapsed_s" => elapsed,
      "pass_lines" => length(Regex.scan(~r/^\[PASS\]/m, out)),
      "fail_lines" => length(fails),
      "first_fail" => List.first(fails)
    }
  end

  def outcome(124, _), do: "timeout"
  def outcome(rc, _) when signal_rc?(rc), do: "signal"
  def outcome(0, []), do: "pass"
  def outcome(_, _), do: "fail"

  defp macos_result(name, _rc, _runs) when name in @support, do: "support"
  defp macos_result(_name, rc, _runs) when rc != 0, do: "no_build"
  defp macos_result(_name, _rc, []), do: nil

  defp macos_result(_name, _rc, runs) do
    case runs |> Enum.map(& &1["outcome"]) |> Enum.uniq() do
      ["pass"] -> "pass"
      [o] -> o
      _ -> "mixed"
    end
  end

  def rmx_result(name) do
    cond do
      name in @rmx_pass -> "pass"
      Map.has_key?(@rmx_fail, name) -> "fail"
      true -> "not_registered"
    end
  end

  def verdict(name, _m, _r) when name in @support, do: "harness/support file, not a test"
  def verdict(_n, "no_build", "not_registered"), do: "unsupported on both (macOS: no build; rmxOS: not registered)"
  def verdict(_n, "no_build", _r), do: "no macOS result (does not build against the public SDK)"
  def verdict(_n, "pass", "pass"), do: "same"
  def verdict(_n, "pass", "not_registered"), do: "rmxOS differs (macOS passes; not registered on rmxOS)"
  def verdict(_n, "pass", "fail"), do: "rmxOS differs"
  def verdict(_n, m, "fail") when m in ["fail", "timeout", "signal"], do: "same (fails on both)"
  def verdict(_n, m, "pass") when m in ["fail", "timeout", "signal", "mixed"], do: "rmxOS differs (macOS #{m})"
  def verdict(_n, "mixed", _r), do: "no stable macOS result (mixed over 5 runs)"
  def verdict(_n, m, "not_registered"), do: "unsupported on both (macOS #{m}; rmxOS: not registered)"
  def verdict(_n, m, r), do: "unknown (macOS #{inspect(m)}, rmxOS #{r})"

  defp markdown(rows) do
    head = "| File | macOS build | macOS result (5 runs) | rmxOS | Verdict |\n|---|---|---|---|---|\n"

    body =
      Enum.map_join(rows, "", fn r ->
        build = if r["built"], do: "yes", else: "no: `#{r["first_error"]}`"
        rmx = Map.get(@rmx_fail, r["name"], r["rmxos"])
        "| `#{r["name"]}` | #{build} | #{runs_cell(r)} | #{rmx} | #{r["verdict"]} |\n"
      end)

    head <> body
  end

  defp runs_cell(%{"runs" => []} = r), do: r["macos"] || "not run"

  defp runs_cell(%{"runs" => runs}) do
    outs =
      runs
      |> Enum.map(fn x -> if x["signal"], do: "sig#{x["signal"]}", else: "#{x["outcome"]}(rc #{x["rc"]})" end)
      |> Enum.frequencies()
      |> Enum.map_join(", ", fn {k, v} -> "#{v}× #{k}" end)

    p = runs |> Enum.map(& &1["pass_lines"]) |> Enum.uniq() |> Enum.join("/")
    f = runs |> Enum.map(& &1["fail_lines"]) |> Enum.uniq() |> Enum.join("/")
    first = runs |> Enum.map(& &1["first_fail"]) |> Enum.find(& &1)
    t = runs |> Enum.map(& &1["elapsed_s"]) |> Enum.reject(&is_nil/1)
    time = if t == [], do: "", else: "; #{Enum.min(t)}–#{Enum.max(t)} s"

    "#{outs}; PASS #{p}, FAIL #{f}#{time}" <> if(first, do: "; first `#{first}`", else: "")
  end

  defp first_error(log) do
    case Regex.run(~r/^.*(error:|ld: ).*$/m, log) do
      [line | _] -> line |> String.replace(~r{^.*/tests/}, "") |> String.slice(0, 160)
      _ -> nil
    end
  end

  defp read(path), do: (case File.read(path) do {:ok, s} -> s; _ -> nil end)
  defp read_int(path), do: (case read(path) do nil -> nil; s -> s |> String.trim() |> String.to_integer() end)

  # Negative controls: each load-bearing classification rule must fail closed.
  defp self_test(dir) do
    File.mkdir_p!(dir)
    logs = Path.join(dir, "logs")
    File.rm_rf!(logs)
    File.mkdir_p!(logs)

    mk = fn name, build_rc, runs ->
      File.write!(Path.join(logs, name <> ".build.rc"), "#{build_rc}\n")
      File.write!(Path.join(logs, name <> ".build.log"), if(build_rc == 0, do: "", else: "x/tests/t.c:1:1: fatal error: 'dispatch/private.h' file not found\n"))

      for {{rc, out}, i} <- Enum.with_index(runs, 1) do
        File.write!(Path.join(logs, "#{name}.run#{i}.status"), "rc=#{rc} elapsed_s=0.1\n")
        File.write!(Path.join(logs, "#{name}.run#{i}.out"), out)
      end
    end

    ok = "[PASS] x\n"
    bad = "[PASS] x\n[FAIL] y (t.c:9)\n"
    mk.("dispatch_after", 0, List.duplicate({0, ok}, 5))
    mk.("dispatch_api", 0, List.duplicate({0, bad}, 5))        # rc 0 but a [FAIL] line
    mk.("dispatch_apply", 0, List.duplicate({124, ok}, 5))     # timeout
    mk.("dispatch_c99", 0, [{0, ok}, {0, ok}, {0, ok}, {0, ok}, {134, ok}]) # one abort
    mk.("dispatch_concur", 1, [])
    mk.("dispatch_vm", 1, [])
    mk.("dispatch_proc", 0, List.duplicate({0, ok}, 5))
    mk.("dispatch_cascade", 0, List.duplicate({1, ok}, 5))     # nonzero exit, no [FAIL]
    mk.("dispatch_thread_name", 0, List.duplicate({255, bad}, 5)) # exit(-1) is not a signal

    got = summarize(logs) |> Map.new(&{&1["name"], &1})

    cases = [
      {"pass_requires_clean_runs", got["dispatch_after"]["macos"], "pass"},
      {"fail_line_with_rc0_is_fail", got["dispatch_api"]["macos"], "fail"},
      {"fail_line_counted", hd(got["dispatch_api"]["runs"])["first_fail"], "[FAIL] y (t.c:9)"},
      {"timeout_not_pass", got["dispatch_apply"]["macos"], "timeout"},
      {"one_crash_makes_mixed", got["dispatch_c99"]["macos"], "mixed"},
      {"crash_signal_decoded", List.last(got["dispatch_c99"]["runs"])["signal"], 6},
      {"no_build_verdict", got["dispatch_concur"]["verdict"], "no macOS result (does not build against the public SDK)"},
      {"no_build_unregistered", got["dispatch_vm"]["verdict"], "unsupported on both (macOS: no build; rmxOS: not registered)"},
      {"gap_verdict", got["dispatch_proc"]["verdict"], "rmxOS differs (macOS passes; not registered on rmxOS)"},
      {"nonzero_exit_is_fail", got["dispatch_cascade"]["macos"], "fail"},
      {"rc255_is_exit_not_signal", got["dispatch_thread_name"]["macos"], "fail"},
      {"rc255_no_signal", hd(got["dispatch_thread_name"]["runs"])["signal"], nil},
      {"rmx_fail_vs_mac_fail_same", verdict("x", "fail", "fail"), "same (fails on both)"}
    ]

    results =
      Enum.map(cases, fn {id, actual, expected} ->
        %{"id" => id, "expected" => inspect(expected), "actual" => inspect(actual), "passed" => actual == expected}
      end)

    passed = Enum.all?(results, & &1["passed"])

    nc = %{
      "schema" => "negative-controls.v1",
      "validator" => "summarize_op236.exs",
      "created_at_utc" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "cases" => results,
      "passed" => passed
    }

    File.write!(Path.join(dir, "summarize-op236.negative-controls.v1.json"), JSON.encode!(nc) <> "\n")
    IO.puts(if passed, do: "self-test: pass", else: "self-test: FAIL #{inspect(Enum.reject(results, & &1["passed"]))}")
    System.halt(if passed, do: 0, else: 1)
  end
end

SwiftGate.SummarizeOp236.main(System.argv())
