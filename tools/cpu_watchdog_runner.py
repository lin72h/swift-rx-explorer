#!/usr/bin/env python3
import argparse
import collections
import datetime as dt
import os
import signal
import subprocess
import sys
import threading
import time


ORCHESTRATOR_NAMES = {
    "sh",
    "zsh",
    "bash",
    "env",
    "cmake",
    "ninja",
    "python",
    "python3",
    "python3.11",
}


def utc_now():
    return dt.datetime.now(dt.timezone.utc).isoformat()


def parse_cpu_seconds(value):
    # FreeBSD ps(1) time is usually [[dd-]hh:]mm:ss.frac.
    days = 0
    if "-" in value:
        day_part, value = value.split("-", 1)
        days = int(day_part)
    parts = value.split(":")
    if len(parts) == 3:
        hours, minutes, seconds = parts
    elif len(parts) == 2:
        hours = "0"
        minutes, seconds = parts
    elif len(parts) == 1:
        hours = "0"
        minutes = "0"
        seconds = parts[0]
    else:
        raise ValueError(f"unrecognized cpu time: {value!r}")
    return days * 86400 + int(hours) * 3600 + int(minutes) * 60 + float(seconds)


def read_process_table():
    proc = subprocess.run(
        ["ps", "axww", "-o", "pid=", "-o", "ppid=", "-o", "time=", "-o", "comm=", "-o", "command="],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    rows = {}
    children = collections.defaultdict(list)
    for line in proc.stdout.splitlines():
        parts = line.split(None, 4)
        if len(parts) < 4:
            continue
        pid_s, ppid_s, cpu_s, comm = parts[:4]
        command = parts[4] if len(parts) > 4 else comm
        try:
            pid = int(pid_s)
            ppid = int(ppid_s)
            cpu_seconds = parse_cpu_seconds(cpu_s)
        except ValueError:
            continue
        rows[pid] = {
            "pid": pid,
            "ppid": ppid,
            "cpu": cpu_seconds,
            "comm": os.path.basename(comm),
            "command": command,
        }
        children[ppid].append(pid)
    return rows, children


def descendants_of(root_pid, rows, children):
    out = set()
    stack = list(children.get(root_pid, []))
    while stack:
        pid = stack.pop()
        if pid in out:
            continue
        out.add(pid)
        stack.extend(children.get(pid, []))
    return out


def kill_tree(pid, rows, children, log, reason, term_grace):
    tree = descendants_of(pid, rows, children)
    tree.add(pid)
    ordered = sorted(tree, reverse=True)
    log.write(f"{utc_now()} kill-start reason={reason} pids={ordered}\n")
    log.flush()
    for sig in (signal.SIGTERM, signal.SIGKILL):
        for child in ordered:
            try:
                os.kill(child, sig)
                log.write(f"{utc_now()} sent signal={sig.name} pid={child}\n")
            except ProcessLookupError:
                pass
            except PermissionError as exc:
                log.write(f"{utc_now()} signal-failed pid={child} signal={sig.name} error={exc}\n")
        log.flush()
        if sig == signal.SIGTERM:
            time.sleep(term_grace)


def stream_output(proc, raw_log_path, echo):
    with open(raw_log_path, "w", encoding="utf-8", errors="replace") as raw:
        for line in proc.stdout:
            raw.write(line)
            if echo:
                sys.stdout.write(line)
                sys.stdout.flush()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--raw-log", required=True)
    parser.add_argument("--kill-log", required=True)
    parser.add_argument("--cpu-budget-seconds", required=True, type=float)
    parser.add_argument("--poll-seconds", type=float, default=5.0)
    parser.add_argument("--term-grace-seconds", type=float, default=5.0)
    parser.add_argument("--status-seconds", type=float, default=60.0)
    parser.add_argument("--echo", action="store_true")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()

    command = args.command
    if command and command[0] == "--":
        command = command[1:]
    if not command:
        parser.error("missing command")

    os.makedirs(os.path.dirname(args.raw_log), exist_ok=True)
    os.makedirs(os.path.dirname(args.kill_log), exist_ok=True)

    with open(args.kill_log, "w", encoding="utf-8") as kill_log:
        kill_log.write(f"{utc_now()} watchdog-start cpu_budget_seconds={args.cpu_budget_seconds}\n")
        kill_log.write(f"{utc_now()} command={' '.join(command)}\n")
        kill_log.flush()

        proc = subprocess.Popen(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            encoding="utf-8",
            errors="replace",
            bufsize=1,
            start_new_session=True,
        )

        reader = threading.Thread(
            target=stream_output,
            args=(proc, args.raw_log, args.echo),
            daemon=True,
        )
        reader.start()

        print(f"[watchdog] started pid={proc.pid} cpu_budget_seconds={args.cpu_budget_seconds}")
        print(f"[watchdog] raw_log={args.raw_log}")
        print(f"[watchdog] kill_log={args.kill_log}")
        sys.stdout.flush()

        killed = set()
        last_status = 0.0
        try:
            while proc.poll() is None:
                rows, children = read_process_table()
                descendants = descendants_of(proc.pid, rows, children)
                now = time.monotonic()
                if now - last_status >= args.status_seconds:
                    print(f"[watchdog] {utc_now()} alive_descendants={len(descendants)} killed={len(killed)}")
                    sys.stdout.flush()
                    last_status = now

                for pid in sorted(descendants):
                    if pid in killed:
                        continue
                    row = rows.get(pid)
                    if not row:
                        continue
                    if row["comm"] in ORCHESTRATOR_NAMES:
                        continue
                    if row["cpu"] <= args.cpu_budget_seconds:
                        continue
                    reason = (
                        f"cpu>{args.cpu_budget_seconds}s pid={pid} "
                        f"cpu={row['cpu']:.2f}s comm={row['comm']} command={row['command']!r}"
                    )
                    kill_log.write(f"{utc_now()} over-budget {reason}\n")
                    kill_log.flush()
                    kill_tree(pid, rows, children, kill_log, reason, args.term_grace_seconds)
                    killed.add(pid)

                time.sleep(args.poll_seconds)
        except BaseException:
            try:
                os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
                time.sleep(args.term_grace_seconds)
                os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
            except ProcessLookupError:
                pass
            raise

        rc = proc.wait()
        reader.join(timeout=30)
        kill_log.write(f"{utc_now()} watchdog-finish returncode={rc} killed={sorted(killed)}\n")
        kill_log.flush()
        print(f"[watchdog] finished returncode={rc} killed={len(killed)}")
        sys.stdout.flush()
        return rc


if __name__ == "__main__":
    raise SystemExit(main())
