pub const CompileCheck = struct {
    pub const Options = struct {
        name: []const u8,
        target: Build.ResolvedTarget,
        kind: Kind,
        source: LazyPath,
    };

    pub const Kind = enum {
        exe,
        obj,
    };

    pub const Result = enum {
        failure,
        success,
    };

    step: Step,
    name: []const u8,
    target: Build.ResolvedTarget,
    kind: Kind,
    source: LazyPath,
    result: ?Result,

    pub fn create(b: *Build, options: Options) *CompileCheck {
        const step = Step.init(.{
            .id = .custom,
            .name = b.fmt("compile check {s}", .{options.name}),
            .owner = b,
            .makeFn = CompileCheck.make,
        });

        const compile_check = b.allocator.create(CompileCheck) catch @panic("OOM");
        compile_check.* = .{
            .step = step,
            .name = std.ascii.allocLowerString(b.allocator, options.name) catch @panic("OOM"),
            .target = options.target,
            .kind = options.kind,
            .source = options.source,
            .result = null,
        };
        compile_check.source.addStepDependencies(&compile_check.step);

        return compile_check;
    }

    fn make(step: *Step, options: Step.MakeOptions) !void {
        _ = options;
        const compile_check: *CompileCheck = @fieldParentPtr("step", step);
        const b = step.owner;
        const allocator = b.allocator;

        const target_triple = try compile_check.target.query.zigTriple(allocator);
        const src_path = compile_check.source.getPath3(b, step);
        const src = try src_path.root_dir.join(allocator, &.{src_path.sub_path});

        try step.addWatchInput(compile_check.source);

        var man = b.graph.cache.obtain();
        defer man.deinit();
        man.hash.add(@as(u32, 0x4fe6705c));
        man.hash.addBytes(target_triple);
        _ = try man.addFilePath(src_path, null);

        if (try step.cacheHitAndWatch(&man)) {
            const digest = man.final();
            const cache_path = b.pathJoin(&.{ "o", &digest, compile_check.name });
            const cache_path_abs = try b.cache_root.join(allocator, &.{ "o", &digest });

            var file = b.cache_root.handle.openFile(cache_path, .{}) catch |err| {
                return step.fail("unable to open cached result '{s}: {s}", .{
                    cache_path_abs, @errorName(err),
                });
            };
            defer file.close();
            const content = file.readToEndAlloc(allocator, 128) catch |err| {
                return step.fail("unable to read cached result '{s}': {s}", .{
                    cache_path_abs,
                    @errorName(err),
                });
            };
            defer allocator.free(content);

            if (std.mem.eql(u8, content, "success")) {
                compile_check.result = .success;
            } else if (std.mem.eql(u8, content, "failure")) {
                compile_check.result = .failure;
            } else {
                return step.fail("unexpected content of cache '{s}'", .{cache_path});
            }
            return;
        }

        const digest = man.final();

        compile_check.result = result: {
            var args: std.ArrayList([]const u8) = .empty;
            defer args.deinit(allocator);

            try args.append(allocator, b.graph.zig_exe);
            try args.append(allocator, switch (compile_check.kind) {
                .exe => "build-exe",
                .obj => "build-obj",
            });
            try args.append(allocator, "-fno-emit-bin");
            try args.append(allocator, "-lc");
            try args.append(allocator, "-target");
            try args.append(allocator, target_triple);

            try args.append(allocator, src);

            const result = try std.process.Child.run(.{ .allocator = allocator, .argv = args.items });
            switch (result.term) {
                .Exited => |code| {
                    if (code == 0) break :result .success;
                    break :result .failure;
                },
                inline else => return step.fail("failed to compile source file", .{}),
            }
        };

        const cache_path_abs = try b.cache_root.join(allocator, &.{ "o", &digest });

        var cache_dir = b.cache_root.handle.makeOpenPath(b.pathJoin(&.{ "o", &digest }), .{}) catch |err| {
            return step.fail("unable to make path '{s}': {s}", .{
                cache_path_abs, @errorName(err),
            });
        };
        defer cache_dir.close();

        var file = cache_dir.createFile(compile_check.name, .{}) catch |err| {
            return step.fail("unable to create file '{s}{s}': {s}", .{
                cache_path_abs, compile_check.name, @errorName(err),
            });
        };
        defer file.close();

        try file.writeAll(@tagName(compile_check.result.?));
        try step.writeManifestAndWatch(&man);
    }
};

step: Step,
config_header: *ConfigHeaderStep,
wf: *WriteFileStep,
target: Build.ResolvedTarget,
values: StringArrayHashMap(*CompileCheck).Unmanaged,

pub fn create(b: *Build, target: Build.ResolvedTarget, options: ConfigHeaderStep.Options) *AutoConfigHeaderStep {
    const name = if (options.style.getPath()) |s|
        b.fmt("auto configure {s} header {s}", .{
            @tagName(options.style), s.getDisplayName(),
        })
    else
        b.fmt("auto configure {s} header", .{@tagName(options.style)});

    const step = Step.init(.{
        .id = .custom,
        .name = name,
        .owner = b,
        .makeFn = make,
    });
    const auto_config_header = b.allocator.create(AutoConfigHeaderStep) catch @panic("OOM");
    const config_header = ConfigHeaderStep.create(b, options);

    auto_config_header.* = .{
        .step = step,
        .config_header = config_header,
        .wf = WriteFileStep.create(b),
        .target = target,
        .values = .empty,
    };
    config_header.step.dependOn(&auto_config_header.step);

    return auto_config_header;
}

pub fn addHaveHeader(auto_config_header: *AutoConfigHeaderStep, name: []const u8, header: []const u8) void {
    const b = auto_config_header.step.owner;
    const allocator = b.allocator;

    const source = auto_config_header.wf.add(
        b.fmt("check_{s}.c", .{std.ascii.allocLowerString(allocator, name) catch @panic("OOM")}),
        b.fmt("#include <{s}>", .{header}),
    );

    const compile_check = CompileCheck.create(b, .{
        .name = name,
        .target = auto_config_header.target,
        .kind = .obj,
        .source = source,
    });
    auto_config_header.step.dependOn(&compile_check.step);
    auto_config_header.values.put(allocator, name, compile_check) catch @panic("OOM");
}

pub fn addHaveFunction(auto_config_header: *AutoConfigHeaderStep, name: []const u8, function: []const u8, includes: []const []const u8) void {
    const b = auto_config_header.step.owner;
    const allocator = b.allocator;

    var builder: std.ArrayList(u8) = .empty;
    defer builder.deinit(allocator);

    for (includes) |header| {
        builder.appendSlice(allocator, b.fmt("#include <{s}>\n", .{header})) catch @panic("OOM");
    }
    builder.appendSlice(allocator, "int main() {\n\t(void)") catch @panic("OOM");
    builder.appendSlice(allocator, function) catch @panic("OOM");
    builder.appendSlice(allocator, ";\n\treturn 0;\n}") catch @panic("OOM");

    const source = auto_config_header.wf.add(
        b.fmt("check_{s}.c", .{std.ascii.allocLowerString(allocator, name) catch @panic("OOM")}),
        builder.items,
    );

    const compile_check = CompileCheck.create(b, .{
        .name = name,
        .target = auto_config_header.target,
        .kind = .exe,
        .source = source,
    });
    auto_config_header.step.dependOn(&compile_check.step);
    auto_config_header.values.put(allocator, name, compile_check) catch @panic("OOM");
}

fn make(step: *std.Build.Step, options: std.Build.Step.MakeOptions) !void {
    _ = options;
    const auto_config_header: *AutoConfigHeaderStep = @fieldParentPtr("step", step);
    var it = auto_config_header.values.iterator();
    while (it.next()) |v| {
        switch (v.value_ptr.*.result.?) {
            .failure => try auto_config_header.config_header.values.put(v.key_ptr.*, .undef),
            .success => try auto_config_header.config_header.values.put(v.key_ptr.*, .defined),
        }
    }
}

const AutoConfigHeaderStep = @This();
const std = @import("std");
const Build = std.Build;
const LazyPath = Build.LazyPath;
const Step = Build.Step;
const ConfigHeaderStep = Step.ConfigHeader;
const WriteFileStep = Step.WriteFile;
const StringArrayHashMap = std.StringArrayHashMap;
