# pkl-zig

Experimental Zig bindings for Pkl's Message Passing API.

The library currently exposes a low-level message codec and a transport that
spawns `pkl server` and communicates with it over MessagePack. The supported
baseline is Zig 0.16.0 and Pkl 0.31.1.

## Install

Add this package as a dependency, then import the public `pkl` module from your
`build.zig`:

```zig
const pkl = b.dependency("pkl_zig", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("pkl", pkl.module("pkl"));
```

## Use

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
when stderr handling should differ from the default:

```zig
var transport = try pkl.Transport.initWithOptions(init.io, init.gpa, .{
    .pkl_argv = &.{ "/usr/local/bin/pkl", "server" },
    .stderr = .inherit,
});
```

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

## Tests

```sh
zig build test
zig build integration-test
zig build run
```

`zig build test` runs fast unit tests and skips tests that spawn `pkl server`.
`zig build integration-test` requires Pkl 0.31.1 or a compatible `pkl` binary on
`PATH`.

## Status

This is not yet a high-level evaluator API. Callers still manage request IDs,
evaluator IDs, response routing, and custom reader request handling directly.
