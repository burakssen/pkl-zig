const std = @import("std");

pub const Options = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    pkl_source_path: ?std.Build.LazyPath = null,
    prebuilt_lib: ?std.Build.LazyPath = null,
    include_dir: ?std.Build.LazyPath = null,
    force_rebuild: bool = false,
};

pub const LibPkl = struct {
    build_step: ?*std.Build.Step = null,
    library: std.Build.LazyPath,
    include_dir: std.Build.LazyPath,

    pub fn link(self: LibPkl, module: *std.Build.Module) void {
        module.addIncludePath(self.include_dir);
        module.addObjectFile(self.library);
        module.link_libc = true;

        const target = module.resolved_target.?.result;
        switch (target.os.tag) {
            .macos => {
                // match upstream libpkl pkg-config macOS requirements
                module.linkSystemLibrary("z", .{});
                module.linkFramework("Foundation", .{});
                module.linkFramework("CoreServices", .{});
            },
            .linux => {
                // match upstream libpkl pkg-config Linux requirements
                module.linkSystemLibrary("z", .{});
                module.linkSystemLibrary("pthread", .{});
                module.linkSystemLibrary("dl", .{});
            },
            else => {},
        }
    }
};

pub fn add(b: *std.Build, options: Options) ?LibPkl {
    // If prebuilt paths were explicitly provided, bypass Gradle invocation
    if (options.prebuilt_lib) |lib| {
        return .{
            .library = lib,
            .include_dir = options.include_dir orelse b.path(""),
        };
    }

    const target = options.target.result;
    const target_name = getTargetName(target);

    // return null if lazy dependency is not yet fetched so Zig can download it and restart build
    const source_root = options.pkl_source_path orelse if (b.lazyDependency("pkl", .{})) |dep|
        dep.path("")
    else
        return null;

    const is_windows = target.os.tag == .windows;
    const ext = if (is_windows) "lib" else "a";
    const lib_rel_path = b.fmt("libpkl/build/native-libs/{s}/lib/libpkl.{s}", .{ target_name, ext });
    const lib_path = source_root.path(b, lib_rel_path);
    const inc_path = source_root.path(b, "libpkl/src/main/c/include");

    // check if libpkl static library already exists to bypass Gradle invocation on consecutive builds
    const abs_lib_path = lib_path.getPath(b);
    const already_built = if (b.build_root.handle.access(b.graph.io, abs_lib_path, .{})) true else |_| false;

    var build_step: ?*std.Build.Step = null;
    if (options.force_rebuild or !already_built) {
        const gradlew_bin = if (is_windows) "gradlew.bat" else "./gradlew";

        // invoke upstream buildStaticLibrary task directly
        const gradle_cmd = b.addSystemCommand(&.{ gradlew_bin, ":libpkl:buildStaticLibrary" });
        gradle_cmd.setCwd(source_root);

        // propagate Zig optimization mode to Gradle properties
        switch (options.optimize) {
            .Debug => {
                // Debug build: Gradle defaults to -O0 and -g
            },
            .ReleaseSafe => {
                gradle_cmd.addArg("-DreleaseBuild=true");
            },
            .ReleaseFast => {
                gradle_cmd.addArg("-DreleaseBuild=true");
                gradle_cmd.addArg("-DnativeArch=true");
            },
            .ReleaseSmall => {
                gradle_cmd.addArg("-DreleaseBuild=true");
            },
        }

        if (target.abi.isMusl()) {
            gradle_cmd.addArg("-Dpkl.musl=true");
        }

        if (target.cpu.arch == .aarch64) {
            gradle_cmd.addArg("-Dpkl.targetArch=aarch64");
        } else if (target.cpu.arch == .x86_64) {
            gradle_cmd.addArg("-Dpkl.targetArch=amd64");
        }

        build_step = &gradle_cmd.step;
    }

    return .{
        .build_step = build_step,
        .library = lib_path,
        .include_dir = inc_path,
    };
}

fn getTargetName(target: std.Target) []const u8 {
    if (target.os.tag == .macos and target.cpu.arch == .aarch64) return "macos-aarch64";
    if (target.os.tag == .linux and target.cpu.arch == .aarch64) return "linux-aarch64";
    if (target.os.tag == .linux and target.cpu.arch == .x86_64) {
        if (target.abi.isMusl()) return "alpine-linux-amd64";
        return "linux-amd64";
    }
    if (target.os.tag == .windows and target.cpu.arch == .x86_64) return "windows-amd64";
    return "macos-aarch64";
}
