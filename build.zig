const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const pie = b.option(bool, "pie", "Build a Position Independent Executable") orelse false;

    const exe = b.addExecutable(.{
        .name = "droidux",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe.pie = pie;

    const clap = b.dependency("clap", .{});
    exe.root_module.addImport("clap", clap.module("clap"));

    // For uinput
    exe.linkLibC();

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run unit tests");

    const lexer_tests = b.addTest(.{
        .root_source_file = b.path("src/getevent/Lexer.zig"),
        .target = target,
    });

    const parser_tests = b.addTest(.{
        .root_source_file = b.path("src/getevent/Parser.zig"),
        .target = target,
    });

    const run_parser_tests = b.addRunArtifact(parser_tests);
    const run_lexer_tests = b.addRunArtifact(lexer_tests);

    test_step.dependOn(&run_parser_tests.step);
    test_step.dependOn(&run_lexer_tests.step);
}
