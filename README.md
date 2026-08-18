# pkl-zig

Experimental Zig bindings for [Pkl](https://pkl-lang.org/).

`pkl-zig` provides:

- a low-level codec and transport for Pkl's Message Passing API
- an `Evaluator` helper for loading Pkl modules into Zig types
- runtime decoding for Pkl values
- experimental Pkl-to-Zig code generation

The current baseline is Zig 0.16.0 and Pkl 0.32.1. The APIs are still
experimental. Use the `v0.31` tag when targeting Pkl 0.31.x.

## Prerequisites

- Zig 0.16.0
- Pkl 0.32.1 on `PATH` for integration tests, examples, and code generation

## Install

Add `pkl-zig` to your `build.zig.zon`:

```sh
zig fetch --save=pkl_zig git+https://github.com/burakssen/pkl-zig.git
```

Then import the public `pkl` module from your `build.zig`:

```zig
const pkl_zig = b.dependency("pkl_zig", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("pkl", pkl_zig.module("pkl"));
```

## Typed Config With Codegen

Generated Zig packages expose module structs with helpers such as
`loadFromPath`. This is the simplest path when you want typed Zig access to a
Pkl module.

```zig
const std = @import("std");
const appconfig = @import("appconfig");

pub fn main(init: std.process.Init) !void {
    const config = try appconfig.AppConfig.loadFromPath(
        init.arena.allocator(),
        init.io,
        "example/codegen/AppConfig.pkl",
    );

    std.debug.print("server: {s}:{}\n", .{ config.host, config.port });
}
```

The repository includes a complete typed config example:

```sh
zig build run-codegen-example
```

With the checked-in example config, it prints values such as:

```text
server: 127.0.0.2:8080
database: postgres://app:secret@localhost:5432/app
```

## Evaluator

Use `pkl.Evaluator` directly when you already have a Zig type to decode into or
when you need to keep an evaluator alive across multiple loads.

```zig
const std = @import("std");
const pkl = @import("pkl");

pub fn main(init: std.process.Init) !void {
    var evaluator = try pkl.Evaluator.init(init.io, init.gpa, .{});
    defer evaluator.deinit();

    const config = try evaluator.loadFromPath(MyConfig, "config.pkl");
    std.debug.print("server: {s}:{}\n", .{ config.host, config.port });
}
```

Use `Evaluator.Options` when the `pkl` executable is not on `PATH`, module or
resource permissions need to be restricted, or extra module search paths are
needed:

```zig
var evaluator = try pkl.Evaluator.init(init.io, allocator, .{
    .pkl_argv = &.{ "/usr/local/bin/pkl", "server" },
    .allowed_modules = &.{ "pkl:", "file:" },
    .allowed_resources = &.{ "file:" },
    .module_paths = &.{ "config" },
});
```

### Shared EvaluatorManager

Use `EvaluatorManager` when multiple evaluators should share one long-lived
`pkl server` process. Requests from different evaluators can run concurrently;
calls on a single evaluator remain serialized.

```zig
var manager = try pkl.EvaluatorManager.init(init.io, allocator, .{});
defer manager.deinit();

var first = try manager.newEvaluator(.{});
defer first.deinit();
var second = try manager.newEvaluator(.{});
defer second.deinit();
```

Closing the manager rejects new requests with `error.ManagerClosed`. Existing
evaluator handles retain the shared runtime until they are closed or deinitialized,
so a manager may be closed before its evaluators without leaving dangling
transport pointers.

Evaluator options also accept an optional evaluator-scoped `pkl.Logger` callback
for Pkl evaluation logs. Logger callbacks run on the shared dispatcher and must
not block or synchronously re-enter an evaluator that uses the same runtime.

## Low-Level Transport

Use `pkl.Transport` directly when request IDs, evaluator IDs, response routing,
or custom module/resource reader messages need to be managed by the caller:

```zig
const std = @import("std");
const pkl = @import("pkl");

pub fn main(init: std.process.Init) !void {
    var transport = try pkl.Transport.init(init.io, init.gpa);
    defer transport.deinit();

    try transport.start();

    try transport.send(.{
        .create_evaluator = .{
            .request_id = 1,
            .allowed_modules = &.{ "pkl:", "file:" },
        },
    });

    var envelope = try transport.recv();
    defer envelope.deinit(init.gpa);
}
```

Use `Transport.initWithOptions` when the `pkl` executable is not on `PATH` or
when stderr handling should differ from the default.

The repository's low-level example serves a custom `customfs:` module reader:

```sh
zig build run
```

## Codegen

Import `codegen/src/zig.pkl` from a Pkl module and annotate the module with the
Zig package name to generate:

```pkl
@zig.Package { name = "appconfig" }
module example.codegen.AppConfig

import "../../codegen/src/zig.pkl"

host: String = "127.0.0.2"
port: UInt16 = 8080
```

Generate Zig files with:

```sh
pkl run codegen/src/gen.pkl --output-path zig-cache/codegen example/codegen/AppConfig.pkl
```

Each generated package has:

- an `index.zig`
- generated structs for modules and classes
- generated enums for string-literal unions when possible
- generated tagged unions for named, class-only unions when every class is in the same Zig package and the normalized tags are distinct
- module struct helpers such as `loadFromPath`, `loadFromPathWithEvaluator`, and `load`

Class-union generation is intentionally narrow. Heterogeneous unions, unions that
span generated Zig packages, and unions whose member names collide after Zig tag
normalization continue to use the generic `pkl.Value` fallback.

### Build Integration

In your `build.zig`, generate and import typed config modules using `pkl_zig.addCodegen`:

```zig
const pkl_zig = @import("pkl_zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const pkl_dep = b.dependency("pkl_zig", .{
        .target = target,
        .optimize = optimize,
    });

    const appconfig_mod = pkl_zig.addCodegen(b, pkl_dep, .{
        .target = target,
        .optimize = optimize,
        .package_name = "appconfig",
        .pkl_files = &.{b.path("config/AppConfig.pkl")},
    });

    exe.root_module.addImport("appconfig", appconfig_mod);
}
```

Codegen can also use `@zig.Name`, `@zig.Field`, `--mapping`, and generator
settings for package and field naming. It currently supports a focused subset of
Pkl types and should be treated as experimental.

## Ownership

Decoded incoming messages borrow string and byte slices from their owning
`IncomingEnvelope.payload`. Those fields remain valid until
`IncomingEnvelope.deinit` is called.

Some generic codec paths allocate nested slices or maps with the allocator
passed to `message.codec.fromPayload`. Prefer an arena allocator when decoding
complex payloads directly through the low-level codec.

Outgoing frames queued through `Transport.send` are copied into owned bytes and
freed by the transport after writing, or during `Transport.deinit` if still
queued.

In-process module and resource reader callbacks receive a request-scoped
allocator. Memory returned from `read` or `list_elements` may be allocated with
that allocator and must not be freed by the callback; it is released after the
response has been encoded into the transport's owned frame. Reader and logger
callback contexts remain borrowed and must outlive their evaluator.

## Tests

```sh
zig build test
zig build integration-test
zig build run
zig build run-codegen-example
zig build codegen-snippet-test
```

`zig build test` runs fast unit tests and skips tests that spawn `pkl server`.
`zig build integration-test`, `zig build run`, `zig build run-codegen-example`,
and `zig build codegen-snippet-test` require Pkl 0.32.1 or a compatible `pkl`
binary on `PATH`.

`zig build codegen-snippet-test` regenerates snippet fixtures, compiles the
generated packages, checks expected codegen failures, and exercises generated
class-union decoding and evaluator-reusing load helpers against `pkl server`.

## Status

The evaluator runtime supports shared-process request routing, in-process module
and resource readers, evaluator-scoped logging, and safe manager/evaluator
lifetimes. Calls on one evaluator remain intentionally serialized. Codegen is
experimental and currently supports a focused subset of Pkl types.
