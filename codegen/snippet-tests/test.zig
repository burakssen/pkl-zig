const std = @import("std");

const bugholder = @import("github.com/burakssen/pkl-zig/codegen/snippet-tests/output/bugholder");
const cyclicmodule = @import("github.com/burakssen/pkl-zig/codegen/snippet-tests/output/cyclicmodule");
const emptyopenmodule = @import("github.com/burakssen/pkl-zig/codegen/snippet-tests/output/emptyopenmodule");
const explicitname = @import("github.com/burakssen/pkl-zig/codegen/snippet-tests/output/explicitname");
const extendabstractclass = @import("github.com/burakssen/pkl-zig/codegen/snippet-tests/output/extendabstractclass");
const extendmodule = @import("github.com/burakssen/pkl-zig/codegen/snippet-tests/output/extendmodule");
const extendopenclass = @import("github.com/burakssen/pkl-zig/codegen/snippet-tests/output/extendopenclass");
const fieldannotations = @import("github.com/burakssen/pkl-zig/codegen/snippet-tests/output/fieldannotations");
const hiddenproperties = @import("github.com/burakssen/pkl-zig/codegen/snippet-tests/output/hiddenproperties");
const moduletype = @import("github.com/burakssen/pkl-zig/codegen/snippet-tests/output/moduletype");
const moduleusinglib = @import("github.com/burakssen/pkl-zig/codegen/snippet-tests/output/moduleusinglib");
const nomappinghidden = @import("github.com/burakssen/pkl-zig/codegen/snippet-tests/output/nomappinghidden");
const override_pkg = @import("github.com/burakssen/pkl-zig/codegen/snippet-tests/output/override");
const override2 = @import("github.com/burakssen/pkl-zig/codegen/snippet-tests/output/override2");
const import_pkg = @import("github.com/burakssen/pkl-zig/codegen/snippet-tests/output/import");
const pairs = @import("github.com/burakssen/pkl-zig/codegen/snippet-tests/output/pairs");
const union_pkg = @import("github.com/burakssen/pkl-zig/codegen/snippet-tests/output/union");
const unionnamekeyword = @import("github.com/burakssen/pkl-zig/codegen/snippet-tests/output/unionnamekeyword");

test "generated snippet packages compile" {
    _ = bugholder.BugHolder;
    _ = cyclicmodule.CyclicModule;
    _ = emptyopenmodule.EmptyOpenModule;
    _ = explicitname.ExplicitlyCoolName;
    _ = extendabstractclass.ExtendsAbstractClass(extendabstractclass.C);
    _ = extendmodule.ExtendModule;
    _ = extendopenclass.ExtendingOpenClass;
    _ = fieldannotations.FieldAnnotations;
    _ = hiddenproperties.HiddenProperties;
    _ = moduletype.ModuleType;
    _ = moduleusinglib.ModuleUsingLib;
    _ = nomappinghidden.NoMappingHidden;
    _ = override_pkg.Override;
    _ = override2.Override2;
    _ = import_pkg.PackageNameKeyword;
    _ = pairs.Pairs;
    _ = union_pkg.Union;
    _ = unionnamekeyword.UnionNameKeyword;
}

test "generated enum parsers preserve pkl names" {
    try std.testing.expectEqual(.beetle, try bugholder.BugKind.parse("beetle\""));
    try std.testing.expectEqualStrings("beetle one", bugholder.BugKind.beetle_one.pklName());
    try std.testing.expectEqual(.empty, try union_pkg.AccountDisposition.parse(""));
}
