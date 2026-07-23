const std = @import("std");

const appconfig = @import("appconfig");

pub const std_options: std.Options = .{
    .log_level = .err,
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena;
    const allocator = arena.allocator();

    const config = try appconfig.AppConfig.loadFromPath(
        allocator,
        init.io,
        "example/codegen/AppConfig.pkl",
    );

    std.debug.print("server: {s}:{}\n", .{ config.host, config.port });
    std.debug.print("database: {s}\n", .{config.database_url});
    std.debug.print("timeout: {d} {s}\n", .{ config.request_timeout.value, @tagName(config.request_timeout.unit) });

    std.debug.print("typed config: {}\n", .{config.typed_config_enabled});
    std.debug.print("startup load: {}\n", .{config.startup_load_enabled});

    std.debug.print("person: {s} {}\n", .{ config.person.name, config.person.age });

    if (config.debug) {
        std.debug.print("debug mode enabled\n", .{});
    }
}
