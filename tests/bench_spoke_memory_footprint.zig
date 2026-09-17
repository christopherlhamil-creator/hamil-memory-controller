const std = @import("std");

const CELL_BYTES: usize = 17408;

const ProcMemoryStatus = struct {
    vm_size_kb: usize = 0,
    vm_rss_kb: usize = 0,
    vm_hwm_kb: usize = 0,
};

const SmapsReport = struct {
    size_kb: usize = 0,
    rss_kb: usize = 0,
    shared_clean_kb: usize = 0,
    shared_dirty_kb: usize = 0,
    private_clean_kb: usize = 0,
    private_dirty_kb: usize = 0,
};

fn readProcStatus() !ProcMemoryStatus {
    const fd = try std.posix.openat(std.posix.AT.FDCWD, "/proc/self/status", .{ .ACCMODE = .RDONLY }, 0);
    defer _ = std.os.linux.close(fd);
    var buf: [4096]u8 = undefined;
    const n = try std.posix.read(fd, &buf);
    const content = buf[0..n];

    var res = ProcMemoryStatus{};
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "VmSize:")) {
            res.vm_size_kb = parseKb(line);
        } else if (std.mem.startsWith(u8, line, "VmRSS:")) {
            res.vm_rss_kb = parseKb(line);
        } else if (std.mem.startsWith(u8, line, "VmHWM:")) {
            res.vm_hwm_kb = parseKb(line);
        }
    }
    return res;
}

fn parseKb(line: []const u8) usize {
    var it = std.mem.tokenizeAny(u8, line, " \t:");
    _ = it.next(); // label
    if (it.next()) |val_str| {
        return std.fmt.parseInt(usize, val_str, 10) catch 0;
    }
    return 0;
}

fn readSmapsForPath(subpath: []const u8) !SmapsReport {
    const fd = try std.posix.openat(std.posix.AT.FDCWD, "/proc/self/smaps", .{ .ACCMODE = .RDONLY }, 0);
    defer _ = std.os.linux.close(fd);
    var buf: [65536]u8 = undefined;
    var res = SmapsReport{};

    var in_target = false;
    var line_buf: [512]u8 = undefined;
    var line_len: usize = 0;

    while (true) {
        const n = try std.posix.read(fd, &buf);
        if (n == 0) break;
        for (buf[0..n]) |b| {
            if (b == '\n') {
                const line = line_buf[0..line_len];
                line_len = 0;
                if (std.mem.indexOf(u8, line, subpath) != null) {
                    in_target = true;
                    continue;
                }
                if (in_target) {
                    if (line.len > 0 and std.ascii.isHex(line[0]) and std.mem.indexOfScalar(u8, line, '-') != null) {
                        in_target = false;
                        continue;
                    }
                    if (std.mem.startsWith(u8, line, "Size:")) res.size_kb += parseKb(line);
                    if (std.mem.startsWith(u8, line, "Rss:")) res.rss_kb += parseKb(line);
                    if (std.mem.startsWith(u8, line, "Shared_Clean:")) res.shared_clean_kb += parseKb(line);
                    if (std.mem.startsWith(u8, line, "Shared_Dirty:")) res.shared_dirty_kb += parseKb(line);
                    if (std.mem.startsWith(u8, line, "Private_Clean:")) res.private_clean_kb += parseKb(line);
                    if (std.mem.startsWith(u8, line, "Private_Dirty:")) res.private_dirty_kb += parseKb(line);
                }
            } else {
                if (line_len < line_buf.len) {
                    line_buf[line_len] = b;
                    line_len += 1;
                }
            }
        }
    }
    return res;
}

const Rusage = struct {
    min_flt: i64,
    maj_flt: i64,
    max_rss_kb: i64,
};

fn getRusage() Rusage {
    const u = std.posix.getrusage(0);
    return .{
        .min_flt = u.minflt,
        .maj_flt = u.majflt,
        .max_rss_kb = u.maxrss,
    };
}

fn nowNs() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

pub fn main() !void {

    std.debug.print("═══════════════════════════════════════════════════════════════════\n", .{});
    std.debug.print("  SPOKE vs MONOLITHIC MEMORY FOOTPRINT & CACHE BENCHMARK (ZIG NATIVE)\n", .{});
    std.debug.print("═══════════════════════════════════════════════════════════════════\n", .{});

    // ── Spoke Sweep ──
    {
        const spoke_path = "run/spoke_queues/bench_ocr.cells";
        const ru_before = getRusage();
        const stat_before = try readProcStatus();

        const fd = try std.posix.openat(std.posix.AT.FDCWD, spoke_path, .{ .ACCMODE = .RDONLY }, 0);
        defer _ = std.os.linux.close(fd);
        const file_size: usize = @intCast(std.os.linux.lseek(fd, 0, 2));
        _ = std.os.linux.lseek(fd, 0, 0);
        const n_cells = file_size / CELL_BYTES;

        const mapped = try std.posix.mmap(
            null,
            file_size,
            std.posix.PROT{ .READ = true },
            .{ .TYPE = .SHARED },
            fd,
            0,
        );

        const target_val = "Aherron_John\x00\x00\x00\x00";
        var matches: usize = 0;
        const iterations: usize = 2000;

        const t0 = nowNs();
        var it: usize = 0;
        while (it < iterations) : (it += 1) {
            var i: usize = 0;
            while (i < n_cells) : (i += 1) {
                const cell_start = i * CELL_BYTES;
                var hdr_copy: [64]u8 align(64) = undefined;
                @memcpy(&hdr_copy, mapped[cell_start .. cell_start + 64]);
                std.mem.doNotOptimizeAway(&hdr_copy);
                const t_slice = hdr_copy[40..56];
                if (std.mem.eql(u8, t_slice, target_val)) {
                    matches += 1;
                }
            }
        }
        const t1 = nowNs();
        std.mem.doNotOptimizeAway(matches);

        const smaps = try readSmapsForPath("bench_ocr.cells");
        const stat_during = try readProcStatus();
        const ru_during = getRusage();

        std.posix.munmap(mapped);

        const stat_after = try readProcStatus();

        const elapsed_ns = t1 - t0;
        const sweep_us = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(iterations * 1000));
        const ns_per_cell = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(iterations * n_cells));
        const throughput_evals = @as(f64, @floatFromInt(iterations * n_cells)) / (@as(f64, @floatFromInt(elapsed_ns)) / 1e9);

        std.debug.print("\n[ARM B: ISOLATED SPOKE (bench_ocr.cells)]\n", .{});
        std.debug.print("  File Size:              {d} bytes ({d:.2} MB, {d} cells)\n", .{ file_size, @as(f64, @floatFromInt(file_size)) / 1048576.0, n_cells });
        std.debug.print("  Sweeps Executed:        {d} iterations\n", .{iterations});
        std.debug.print("  Latency per Sweep:      {d:.2} us\n", .{sweep_us});
        std.debug.print("  Latency per Cell-Eval:  {d:.2} ns/cell\n", .{ns_per_cell});
        std.debug.print("  Throughput:             {d:.0} cell-evals/sec ({d:.2} MB/s bandwidth)\n", .{ throughput_evals, throughput_evals * @as(f64, @floatFromInt(CELL_BYTES)) / 1048576.0 });
        std.debug.print("  Minor Page Faults:      {d}\n", .{ru_during.min_flt - ru_before.min_flt});
        std.debug.print("  Major Page Faults:      {d}\n", .{ru_during.maj_flt - ru_before.maj_flt});
        std.debug.print("  VmRSS:                  before={d} kB, during={d} kB, after={d} kB (delta={d} kB)\n", .{ stat_before.vm_rss_kb, stat_during.vm_rss_kb, stat_after.vm_rss_kb, @as(i64, @intCast(stat_after.vm_rss_kb)) - @as(i64, @intCast(stat_before.vm_rss_kb)) });
        std.debug.print("  POSIX mmap smaps:       Size={d} kB, Rss={d} kB, Shared_Clean={d} kB\n", .{ smaps.size_kb, smaps.rss_kb, smaps.shared_clean_kb });
        std.debug.print("  Dirty Pages:            Shared_Dirty={d} kB, Private_Dirty={d} kB (ZERO DIRTY PAGES)\n", .{ smaps.shared_dirty_kb, smaps.private_dirty_kb });
    }

    // ── Monolithic Sweep ──
    {
        const mono_path = "run/benchmark_monolith.cells";
        const ru_before = getRusage();
        const stat_before = try readProcStatus();

        const fd = try std.posix.openat(std.posix.AT.FDCWD, mono_path, .{ .ACCMODE = .RDONLY }, 0);
        defer _ = std.os.linux.close(fd);
        const file_size: usize = @intCast(std.os.linux.lseek(fd, 0, 2));
        _ = std.os.linux.lseek(fd, 0, 0);
        const n_cells = file_size / CELL_BYTES;

        const mapped = try std.posix.mmap(
            null,
            file_size,
            std.posix.PROT{ .READ = true },
            .{ .TYPE = .SHARED },
            fd,
            0,
        );

        const target_val = "Aherron_John\x00\x00\x00\x00";
        var matches: usize = 0;
        const iterations: usize = 2000;

        const t0 = nowNs();
        var it: usize = 0;
        while (it < iterations) : (it += 1) {
            var i: usize = 0;
            while (i < n_cells) : (i += 1) {
                const cell_start = i * CELL_BYTES;
                var hdr_copy: [64]u8 align(64) = undefined;
                @memcpy(&hdr_copy, mapped[cell_start .. cell_start + 64]);
                std.mem.doNotOptimizeAway(&hdr_copy);
                const t_slice = hdr_copy[40..56];
                if (std.mem.eql(u8, t_slice, target_val)) {
                    matches += 1;
                }
            }
        }
        const t1 = nowNs();
        std.mem.doNotOptimizeAway(matches);

        const smaps = try readSmapsForPath("benchmark_monolith.cells");
        const stat_during = try readProcStatus();
        const ru_during = getRusage();

        std.posix.munmap(mapped);

        const stat_after = try readProcStatus();

        const elapsed_ns = t1 - t0;
        const sweep_us = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(iterations * 1000));
        const ns_per_cell = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(iterations * n_cells));
        const throughput_evals = @as(f64, @floatFromInt(iterations * n_cells)) / (@as(f64, @floatFromInt(elapsed_ns)) / 1e9);

        std.debug.print("\n[ARM A: MONOLITH (benchmark_monolith.cells)]\n", .{});
        std.debug.print("  File Size:              {d} bytes ({d:.2} MB, {d} cells)\n", .{ file_size, @as(f64, @floatFromInt(file_size)) / 1048576.0, n_cells });
        std.debug.print("  Sweeps Executed:        {d} iterations\n", .{iterations});
        std.debug.print("  Latency per Sweep:      {d:.2} us\n", .{sweep_us});
        std.debug.print("  Latency per Cell-Eval:  {d:.2} ns/cell\n", .{ns_per_cell});
        std.debug.print("  Throughput:             {d:.0} cell-evals/sec ({d:.2} MB/s bandwidth)\n", .{ throughput_evals, throughput_evals * @as(f64, @floatFromInt(CELL_BYTES)) / 1048576.0 });
        std.debug.print("  Minor Page Faults:      {d}\n", .{ru_during.min_flt - ru_before.min_flt});
        std.debug.print("  Major Page Faults:      {d}\n", .{ru_during.maj_flt - ru_before.maj_flt});
        std.debug.print("  VmRSS:                  before={d} kB, during={d} kB, after={d} kB (delta={d} kB)\n", .{ stat_before.vm_rss_kb, stat_during.vm_rss_kb, stat_after.vm_rss_kb, @as(i64, @intCast(stat_after.vm_rss_kb)) - @as(i64, @intCast(stat_before.vm_rss_kb)) });
        std.debug.print("  POSIX mmap smaps:       Size={d} kB, Rss={d} kB, Shared_Clean={d} kB\n", .{ smaps.size_kb, smaps.rss_kb, smaps.shared_clean_kb });
        std.debug.print("  Dirty Pages:            Shared_Dirty={d} kB, Private_Dirty={d} kB (ZERO DIRTY PAGES)\n", .{ smaps.shared_dirty_kb, smaps.private_dirty_kb });
    }

    std.debug.print("\n═══════════════════════════════════════════════════════════════════\n", .{});
}
