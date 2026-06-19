#!/usr/bin/env elixir

defmodule SwiftGate.DiffRegression do
  def main(["--self-test", tmpdir]) do
    File.mkdir_p!(tmpdir)
    result = self_test(tmpdir)
    out = Path.join(tmpdir, "negative-controls.json")
    File.write!(out, JSON.encode!(result) <> "\n")
    if result["passed"], do: System.halt(0), else: System.halt(1)
  end

  def main([]) do
    IO.puts(:stderr, "usage: diff_swift_regression.exs --baseline-json PATH --run-json PATH --out PATH | --self-test TMPDIR")
    System.halt(2)
  end

  def main(argv) do
    opts = parse_args(argv)
    baseline_path = required!(opts, "--baseline-json")
    run_path = required!(opts, "--run-json")
    out_path = required!(opts, "--out")

    baseline = baseline_path |> File.read!() |> JSON.decode!()
    run = run_path |> File.read!() |> JSON.decode!()

    result = diff_artifact(baseline, run, baseline_path, run_path, opts)
    File.write!(out_path, JSON.encode!(result) <> "\n")

    if result["result"] == "pass", do: System.halt(0), else: System.halt(1)
  end

  defp diff_artifact(baseline, run, baseline_path, run_path, opts) do
    regressions = diff(baseline, run)

    %{
      "schema" => "swift-regression-diff.v1",
      "artifact_kind" => "validation",
      "created_at_utc" => utc_now(),
      "mode" => Map.get(opts, "--mode", "gatekeeper"),
      "baseline" => %{
        "path" => baseline_path,
        "sha256" => sha256_file(baseline_path),
        "tier" => baseline["tier"],
        "run_id" => get_in(baseline, ["run", "id"])
      },
      "run" => %{
        "path" => run_path,
        "sha256" => sha256_file(run_path),
        "tier" => run["tier"],
        "run_id" => get_in(run, ["run", "id"])
      },
      "result" => if(regressions == [], do: "pass", else: "fail"),
      "regressions" => regressions,
      "semantics" => semantics(),
      "deferred_semantics" => [
        "Optimize-mode matrix policy is deferred.",
        "Corelibs suites are deferred."
      ],
      "observations" => %{
        "unsupported_count_delta" => count(run, "unsupported") - count(baseline, "unsupported"),
        "baseline_complete_pass_set_proven" => get_in(baseline, ["status_observation", "complete_pass_set_proven"]),
        "run_complete_pass_set_proven" => get_in(run, ["status_observation", "complete_pass_set_proven"])
      }
    }
  end

  defp diff(baseline, run) do
    baseline_status = status_map(baseline)
    run_status = status_map(run)

    transition_regressions =
      run_status
      |> Enum.flat_map(fn {name, status} ->
        previous = Map.get(baseline_status, name)
        transition_regressions(name, previous, status)
      end)

    missing_regressions =
      baseline_status
      |> Enum.reject(fn {name, _status} -> Map.has_key?(run_status, name) end)
      |> Enum.map(fn {name, previous} -> regression("missing_test", name, previous, nil) end)

    (transition_regressions ++ missing_regressions)
    |> Enum.sort_by(&{&1["class"], &1["test"]})
  end

  defp transition_regressions(_name, status, status), do: []

  defp transition_regressions(name, nil, status) do
    case status do
      "failed" -> [regression("new_failed", name, nil, status)]
      "hung" -> [regression("new_hung", name, nil, status)]
      "expectedly_failed" -> [regression("new_xfail", name, nil, status)]
      "unexpectedly_passed" -> [regression("new_unexpectedly_passed", name, nil, status)]
      _ -> []
    end
  end

  defp transition_regressions(name, previous, status) do
    cond do
      previous == "passed" and status == "failed" ->
        [regression("passed_to_failed", name, previous, status)]

      previous == "passed" and status == "hung" ->
        [regression("passed_to_hung", name, previous, status)]

      previous == "passed" and status == "expectedly_failed" ->
        [regression("passed_to_xfail", name, previous, status)]

      previous == "passed" and status == "unsupported" ->
        [regression("passed_to_unsupported", name, previous, status)]

      previous == "passed" and status == "unexpectedly_passed" ->
        [regression("passed_to_unexpectedly_passed", name, previous, status)]

      previous == "failed" and status == "hung" ->
        [regression("failed_to_hung", name, previous, status)]

      previous == "failed" and status == "expectedly_failed" ->
        [regression("failed_to_xfail", name, previous, status)]

      previous == "failed" and status == "unsupported" ->
        [regression("failed_to_unsupported", name, previous, status)]

      previous == "failed" and status == "unexpectedly_passed" ->
        [regression("failed_to_unexpectedly_passed", name, previous, status)]

      previous == "hung" and status == "unsupported" ->
        [regression("hung_to_unsupported", name, previous, status)]

      previous == "hung" and status == "expectedly_failed" ->
        [regression("hung_to_xfail", name, previous, status)]

      previous == "hung" and status == "unexpectedly_passed" ->
        [regression("hung_to_unexpectedly_passed", name, previous, status)]

      previous == "expectedly_failed" and status == "passed" ->
        [regression("xfail_to_pass", name, previous, status)]

      previous == "expectedly_failed" and status == "failed" ->
        [regression("xfail_to_failed", name, previous, status)]

      previous == "expectedly_failed" and status == "hung" ->
        [regression("xfail_to_hung", name, previous, status)]

      previous == "expectedly_failed" and status == "unsupported" ->
        [regression("xfail_to_unsupported", name, previous, status)]

      previous == "expectedly_failed" and status == "unexpectedly_passed" ->
        [regression("xfail_to_unexpectedly_passed", name, previous, status)]

      previous == "unsupported" and status == "failed" ->
        [regression("unsupported_to_failed", name, previous, status)]

      previous == "unsupported" and status == "hung" ->
        [regression("unsupported_to_hung", name, previous, status)]

      previous == "unsupported" and status == "expectedly_failed" ->
        [regression("unsupported_to_xfail", name, previous, status)]

      previous == "unsupported" and status == "unexpectedly_passed" ->
        [regression("unsupported_to_unexpectedly_passed", name, previous, status)]

      previous == "unexpectedly_passed" and status == "failed" ->
        [regression("unexpectedly_passed_to_failed", name, previous, status)]

      previous == "unexpectedly_passed" and status == "hung" ->
        [regression("unexpectedly_passed_to_hung", name, previous, status)]

      previous == "unexpectedly_passed" and status == "expectedly_failed" ->
        [regression("unexpectedly_passed_to_xfail", name, previous, status)]

      previous == "unexpectedly_passed" and status == "unsupported" ->
        [regression("unexpectedly_passed_to_unsupported", name, previous, status)]

      true ->
        []
    end
  end

  defp semantics do
    %{
      "failed_statuses" => ["failed", "hung"],
      "xpass_policy" => "New XPASS or XFAIL-to-XPASS fails closed; baseline XPASS may remain only if still listed in the accepted baseline.",
      "xfail_policy" => "Any XFAIL-set change fails closed: new XFAIL, XFAIL disappearing to PASS, XFAIL becoming FAIL/HUNG/UNSUPPORTED, or non-XFAIL becoming XFAIL.",
      "unsupported_policy" => "Newly unsupported previously-discovered tests fail as coverage loss; unsupported tests becoming PASS are non-regressing; unsupported tests becoming FAIL/HUNG/XPASS/XFAIL fail closed.",
      "inventory_policy" => "A baseline test absent from the run JSON is a missing_test regression."
    }
  end

  defp regression(class, name, previous, current) do
    %{
      "class" => class,
      "test" => name,
      "baseline_status" => previous,
      "run_status" => current
    }
  end

  defp status_map(artifact) do
    tests = artifact["tests"] || %{}

    %{}
    |> put_statuses(tests["passed"] || [], "passed")
    |> put_statuses(tests["failed"] || [], "failed")
    |> put_statuses(tests["hung"] || [], "hung")
    |> put_statuses(tests["expectedly_failed"] || [], "expectedly_failed")
    |> put_statuses(tests["unexpectedly_passed"] || [], "unexpectedly_passed")
    |> put_statuses(tests["unsupported"] || [], "unsupported")
  end

  defp put_statuses(map, names, status) do
    Enum.reduce(names, map, fn name, acc -> Map.put(acc, name, status) end)
  end

  defp count(artifact, status) do
    artifact
    |> get_in(["tests", status])
    |> case do
      list when is_list(list) -> length(list)
      _ -> 0
    end
  end

  defp self_test(tmpdir) do
    baseline = fixture(%{
      "passed" => ["test/pass.swift"],
      "expectedly_failed" => ["test/xfail.swift"],
      "failed" => ["test/known-fail.swift"],
      "hung" => [],
      "unsupported" => [],
      "unexpectedly_passed" => []
    })

    cases = [
      red_case("passed_to_failed", baseline, fixture(%{"passed" => [], "failed" => ["test/pass.swift"]})),
      red_case("new_failed", baseline, fixture(%{"failed" => ["test/new.swift"]})),
      red_case("hung_test", baseline, fixture(%{"hung" => ["test/hang.swift"]})),
      red_case("xfail_to_pass", baseline, fixture(%{"passed" => ["test/xfail.swift"]})),
      red_case("new_xfail", baseline, fixture(%{"expectedly_failed" => ["test/new-xfail.swift"]})),
      red_case("passed_to_unsupported", baseline, fixture(%{"unsupported" => ["test/pass.swift"]})),
      red_case("unsupported_to_failed", fixture(%{"unsupported" => ["test/unsupported.swift"]}), fixture(%{"failed" => ["test/unsupported.swift"]})),
      red_case("new_unexpectedly_passed", baseline, fixture(%{"unexpectedly_passed" => ["test/new-xpass.swift"]})),
      red_case("xfail_to_unexpectedly_passed", baseline, fixture(%{"unexpectedly_passed" => ["test/xfail.swift"]})),
      red_case("missing_test", baseline, fixture(%{})),
      green_case("identical_baseline", baseline, baseline),
      green_case("unsupported_to_passed", fixture(%{"unsupported" => ["test/unsupported.swift"]}), fixture(%{"passed" => ["test/unsupported.swift"]})),
      green_case("baseline_xpass_still_xpass", fixture(%{"unexpectedly_passed" => ["test/xpass.swift"]}), fixture(%{"unexpectedly_passed" => ["test/xpass.swift"]}))
    ]

    %{
      "schema" => "negative-controls.v1",
      "artifact_kind" => "negative_controls",
      "created_at_utc" => utc_now(),
      "mode" => "gatekeeper",
      "validator" => "diff_swift_regression.exs",
      "validator_pin" => validator_pin(),
      "tmpdir" => tmpdir,
      "cases" => cases,
      "passed" => Enum.all?(cases, & &1["passed"])
    }
  end

  defp red_case(id, baseline, run) do
    actual = if diff(baseline, run) == [], do: "pass", else: "fail"

    %{
      "id" => id,
      "mutation" => id,
      "expected" => "fail",
      "actual" => actual,
      "passed" => actual == "fail"
    }
  end

  defp green_case(id, baseline, run) do
    actual = if diff(baseline, run) == [], do: "pass", else: "fail"

    %{
      "id" => id,
      "mutation" => "none",
      "expected" => "pass",
      "actual" => actual,
      "passed" => actual == "pass"
    }
  end

  defp fixture(statuses) do
    empty = %{
      "passed" => [],
      "failed" => [],
      "hung" => [],
      "expectedly_failed" => [],
      "unexpectedly_passed" => [],
      "unsupported" => []
    }

    %{
      "tier" => "fast",
      "run" => %{"id" => "fixture"},
      "status_observation" => %{"complete_pass_set_proven" => true},
      "tests" => Map.merge(empty, statuses)
    }
  end

  defp validator_pin do
    __ENV__.file
    |> sha256_file()
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

SwiftGate.DiffRegression.main(System.argv())
