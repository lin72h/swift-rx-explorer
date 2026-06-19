const std = @import("std");

const c = @cImport({
    @cInclude("errno.h");
    @cInclude("signal.h");
    @cInclude("stdlib.h");
    @cInclude("string.h");
    @cInclude("sys/types.h");
    @cInclude("sys/wait.h");
    @cInclude("unistd.h");
});

const ProcessInfo = struct {
    pid: c.pid_t,
    ppid: c.pid_t,
    pgid: c.pid_t,
    cpu_seconds: u64,
    command: []const u8,
};

const Config = struct {
    cpu_budget_seconds: u64 = 900,
    poll_seconds: u64 = 5,
    status_seconds: u64 = 60,
    log_path: []const u8,
    argv: []const []const u8,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    const config = try parseArgs(args);
    if (config.argv.len == 0) return usage();

    var log_file = try std.Io.Dir.createFileAbsolute(init.io, config.log_path, .{ .truncate = true });
    defer log_file.close(init.io);

    const command_text = try joinArgs(allocator, config.argv);
    defer allocator.free(command_text);

    try logLine(log_file, init.io, "watchdog-start cpu_budget_seconds={d} poll_seconds={d} status_seconds={d} command={s}", .{
        config.cpu_budget_seconds,
        config.poll_seconds,
        config.status_seconds,
        command_text,
    });

    const child_pid = try spawnInOwnProcessGroup(config.argv);
    const child_pgid: c.pid_t = child_pid;
    try logLine(log_file, init.io, "watchdog-child pid={d} pgid={d}", .{ child_pid, child_pgid });

    var killed: std.ArrayList(c.pid_t) = .empty;
    defer killed.deinit(allocator);

    var seconds_until_status: u64 = config.status_seconds;
    var status: c_int = 0;

    while (true) {
        const waited = c.waitpid(child_pid, &status, c.WNOHANG);
        if (waited == child_pid) break;
        if (waited == -1) {
            if (c.__error().* == c.EINTR) continue;
            try logLine(log_file, init.io, "watchdog-waitpid-error errno={d}", .{c.__error().*});
            _ = c.kill(-child_pgid, c.SIGTERM);
            break;
        }

        var processes = try snapshotProcesses(allocator, init.io);
        defer {
            for (processes.items) |item| allocator.free(item.command);
            processes.deinit(allocator);
        }

        for (processes.items) |proc| {
            if (proc.pgid != child_pgid or proc.pid == child_pid) continue;
            if (proc.cpu_seconds <= config.cpu_budget_seconds) continue;
            if (containsPid(killed.items, proc.pid)) continue;

            try killed.append(allocator, proc.pid);
            try logLine(log_file, init.io, "watchdog-kill pid={d} ppid={d} pgid={d} cpu_seconds={d} budget_seconds={d} command={s}", .{
                proc.pid,
                proc.ppid,
                proc.pgid,
                proc.cpu_seconds,
                config.cpu_budget_seconds,
                proc.command,
            });
            _ = c.kill(proc.pid, c.SIGTERM);
        }

        if (seconds_until_status <= config.poll_seconds) {
            try logLine(log_file, init.io, "watchdog-status child_pid={d} pgid={d} killed_count={d}", .{
                child_pid,
                child_pgid,
                killed.items.len,
            });
            seconds_until_status = config.status_seconds;
        } else {
            seconds_until_status -= config.poll_seconds;
        }

        _ = c.sleep(@intCast(config.poll_seconds));
    }

    if (killed.items.len > 0) {
        _ = c.kill(-child_pgid, c.SIGTERM);
        _ = c.sleep(2);
        _ = c.kill(-child_pgid, c.SIGKILL);
    }

    const exit_code = normalizeStatus(status, killed.items.len > 0);
    try logLine(log_file, init.io, "watchdog-finish child_pid={d} exit_code={d} killed_count={d}", .{
        child_pid,
        exit_code,
        killed.items.len,
    });

    std.process.exit(exit_code);
}

fn parseArgs(args: []const [:0]const u8) !Config {
    var config = Config{
        .log_path = "",
        .argv = &.{},
    };

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--")) {
            config.argv = args[i + 1 ..];
            break;
        } else if (std.mem.eql(u8, arg, "--cpu-budget-seconds")) {
            i += 1;
            if (i >= args.len) return error.MissingCpuBudget;
            config.cpu_budget_seconds = try std.fmt.parseUnsigned(u64, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--poll-seconds")) {
            i += 1;
            if (i >= args.len) return error.MissingPollSeconds;
            config.poll_seconds = try std.fmt.parseUnsigned(u64, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--status-seconds")) {
            i += 1;
            if (i >= args.len) return error.MissingStatusSeconds;
            config.status_seconds = try std.fmt.parseUnsigned(u64, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--log")) {
            i += 1;
            if (i >= args.len) return error.MissingLogPath;
            config.log_path = args[i];
        } else {
            return usage();
        }
    }

    if (config.log_path.len == 0) return error.MissingLogPath;
    return config;
}

fn usage() error{InvalidArguments} {
    std.debug.print(
        "usage: cpu_watchdog --cpu-budget-seconds N --poll-seconds N --status-seconds N --log PATH -- COMMAND [ARGS...]\n",
        .{},
    );
    return error.InvalidArguments;
}

fn spawnInOwnProcessGroup(argv: []const []const u8) !c.pid_t {
    const pid = c.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        _ = c.setpgid(0, 0);
        var child_argv = try std.heap.c_allocator.alloc([*c]u8, argv.len + 1);
        for (argv, 0..) |arg, idx| {
            child_argv[idx] = (try std.heap.c_allocator.dupeZ(u8, arg)).ptr;
        }
        child_argv[argv.len] = null;
        _ = c.execvp(child_argv[0], child_argv.ptr);
        std.debug.print("execvp failed errno={d} command={s}\n", .{ c.__error().*, argv[0] });
        c._exit(127);
    }

    _ = c.setpgid(pid, pid);
    return pid;
}

fn snapshotProcesses(allocator: std.mem.Allocator, io: std.Io) !std.ArrayList(ProcessInfo) {
    const result = try std.process.run(allocator, io, .{
        .argv = &.{ "ps", "-axo", "pid=", "-o", "ppid=", "-o", "pgid=", "-o", "time=", "-o", "command=" },
        .stdout_limit = .limited(16 * 1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    var list: std.ArrayList(ProcessInfo) = .empty;
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        if (std.mem.trim(u8, line, " \t\r").len == 0) continue;
        if (parseProcessLine(allocator, line)) |proc| {
            try list.append(allocator, proc);
        } else |_| {}
    }
    return list;
}

fn parseProcessLine(allocator: std.mem.Allocator, line: []const u8) !ProcessInfo {
    var rest = std.mem.trimStart(u8, line, " \t");
    const pid_text = takeToken(&rest) orelse return error.BadPsLine;
    const ppid_text = takeToken(&rest) orelse return error.BadPsLine;
    const pgid_text = takeToken(&rest) orelse return error.BadPsLine;
    const time_text = takeToken(&rest) orelse return error.BadPsLine;
    const command = std.mem.trim(u8, rest, " \t\r");

    return .{
        .pid = @intCast(try std.fmt.parseInt(i32, pid_text, 10)),
        .ppid = @intCast(try std.fmt.parseInt(i32, ppid_text, 10)),
        .pgid = @intCast(try std.fmt.parseInt(i32, pgid_text, 10)),
        .cpu_seconds = try parseCpuTime(time_text),
        .command = try allocator.dupe(u8, command),
    };
}

fn takeToken(rest: *[]const u8) ?[]const u8 {
    rest.* = std.mem.trimStart(u8, rest.*, " \t");
    if (rest.*.len == 0) return null;
    const idx = std.mem.indexOfAny(u8, rest.*, " \t") orelse {
        const token = rest.*;
        rest.* = "";
        return token;
    };
    const token = rest.*[0..idx];
    rest.* = rest.*[idx..];
    return token;
}

fn parseCpuTime(text: []const u8) !u64 {
    var days: u64 = 0;
    var time_part = text;
    if (std.mem.indexOfScalar(u8, text, '-')) |dash| {
        days = try std.fmt.parseUnsigned(u64, text[0..dash], 10);
        time_part = text[dash + 1 ..];
    }

    var parts: [3][]const u8 = undefined;
    var count: usize = 0;
    var iter = std.mem.splitScalar(u8, time_part, ':');
    while (iter.next()) |part| {
        if (count >= parts.len) return error.BadCpuTime;
        parts[count] = part;
        count += 1;
    }

    var hours: u64 = 0;
    var minutes: u64 = 0;
    var seconds_text: []const u8 = "";
    if (count == 2) {
        minutes = try std.fmt.parseUnsigned(u64, parts[0], 10);
        seconds_text = parts[1];
    } else if (count == 3) {
        hours = try std.fmt.parseUnsigned(u64, parts[0], 10);
        minutes = try std.fmt.parseUnsigned(u64, parts[1], 10);
        seconds_text = parts[2];
    } else {
        return error.BadCpuTime;
    }

    const dot = std.mem.indexOfScalar(u8, seconds_text, '.') orelse seconds_text.len;
    const seconds = try std.fmt.parseUnsigned(u64, seconds_text[0..dot], 10);
    return days * 86400 + hours * 3600 + minutes * 60 + seconds;
}

fn normalizeStatus(status: c_int, killed: bool) u8 {
    if (killed) return 124;
    if (c.WIFEXITED(status)) return @intCast(c.WEXITSTATUS(status));
    if (c.WIFSIGNALED(status)) return @intCast(128 + c.WTERMSIG(status));
    return 125;
}

fn containsPid(pids: []const c.pid_t, pid: c.pid_t) bool {
    for (pids) |item| {
        if (item == pid) return true;
    }
    return false;
}

fn joinArgs(allocator: std.mem.Allocator, argv: []const []const u8) ![]const u8 {
    return std.mem.join(allocator, " ", argv);
}

fn logLine(file: std.Io.File, io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buffer: [4096]u8 = undefined;
    const rendered = try std.fmt.bufPrint(&buffer, fmt, args);
    try file.writeStreamingAll(io, rendered);
    try file.writeStreamingAll(io, "\n");
}
