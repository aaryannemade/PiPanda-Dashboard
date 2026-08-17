const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Core library: bambu cloud auth, MQTT transport, printer state model.
    // Kept separate from the CLI so the HTTP dashboard and future integrations
    // can embed it without dragging the CLI along.
    const pipanda = b.addModule("pipanda", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "pipanda",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "pipanda", .module = pipanda },
            },
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the pipanda CLI");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run unit tests");
    for ([_]*std.Build.Module{ pipanda, exe.root_module }) |mod| {
        const t = b.addTest(.{ .root_module = mod });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    // `zig build check` is wired for zls: it type-checks without emitting a binary.
    const check_step = b.step("check", "Type-check without emitting a binary");
    const check_exe = b.addExecutable(.{
        .name = "pipanda-check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "pipanda", .module = pipanda },
            },
        }),
    });
    check_step.dependOn(&check_exe.step);
}
