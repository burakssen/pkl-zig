const std = @import("std");
const pkl = @import("pkl");

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
const references = @import("github.com/burakssen/pkl-zig/codegen/snippet-tests/output/references");
const support_lib = @import("github.com/burakssen/pkl-zig/codegen/snippet-tests/output/support/lib");
const support_lib2 = @import("github.com/burakssen/pkl-zig/codegen/snippet-tests/output/support/lib2");
const support_lib3 = @import("github.com/burakssen/pkl-zig/codegen/snippet-tests/output/support/lib3");
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
    _ = references.References;
    _ = union_pkg.Union;
    _ = unionnamekeyword.UnionNameKeyword;
}

test "generated enum parsers preserve pkl names" {
    try std.testing.expectEqual(.beetle, try bugholder.BugKind.parse("beetle\""));
    try std.testing.expectEqualStrings("beetle one", bugholder.BugKind.beetle_one.pklName());
    try std.testing.expectEqual(.empty, try union_pkg.AccountDisposition.parse(""));
}

test "generated enum parsers roundtrip and reject invalid values" {
    try std.testing.expectEqual(.san_mateo, try union_pkg.County.parse("San Mateo"));
    try std.testing.expectEqualStrings("San Mateo", union_pkg.County.san_mateo.pklName());
    try std.testing.expectEqual(.three, try support_lib.MyEnum.parse("three"));
    try std.testing.expectEqualStrings("three", support_lib.MyEnum.three.pklName());
    try std.testing.expectError(error.InvalidEnumValue, bugholder.BugKind.parse("not-a-bug"));
    try std.testing.expectError(error.InvalidEnumValue, support_lib2.Cities.parse("Berlin"));
}

test "generated field name mapping keeps pkl wire keys stable" {
    try std.testing.expectEqualStrings("myProp", explicitname.ExplicitlyCoolName.pklFieldName("myprop"));
    try std.testing.expectEqualStrings("propC", hiddenproperties.HiddenProperties.pklFieldName("propc"));
    try std.testing.expectEqualStrings("typeArgAliased", pairs.Pairs.pklFieldName("typeargaliased"));
    try std.testing.expectEqualStrings("myStr", moduletype.ModuleType.pklFieldName("mystr"));
    try std.testing.expectEqualStrings("unknown_field", moduletype.ModuleType.pklFieldName("unknown_field"));
}

test "generated types preserve important shape mappings" {
    try std.testing.expect(@TypeOf(@as(moduleusinglib.ModuleUsingLib, undefined).res) == []support_lib.MyClass);
    try std.testing.expect(@TypeOf(@as(moduleusinglib.ModuleUsingLib, undefined).res2) == support_lib.MyEnum);
    try std.testing.expect(@TypeOf(@as(moduleusinglib.ModuleUsingLib, undefined).res4) == support_lib2.Cities);
    try std.testing.expect(@TypeOf(@as(bugholder.Bug, undefined).kind3) == []const u8);
    try std.testing.expect(@TypeOf(@as(bugholder.Bug, undefined).kind4) == []const u8);
    try std.testing.expect(@TypeOf(@as(bugholder.Bug, undefined).holdsbreathfor) == pkl.Duration);
    try std.testing.expect(@TypeOf(@as(bugholder.Bug, undefined).size) == pkl.DataSize);
    try std.testing.expect(@TypeOf(@as(references.References, undefined).reference) == pkl.Reference);
}

test "generated pair and generic mappings are correct" {
    try std.testing.expect(@TypeOf(@as(pairs.Pairs, undefined).typed.first) == []const u8);
    try std.testing.expect(@TypeOf(@as(pairs.Pairs, undefined).typed.second) == i64);
    try std.testing.expect(@TypeOf(@as(pairs.Pairs, undefined).untyped) == pkl.Pair(pkl.Value, pkl.Value));
    try std.testing.expect(@TypeOf(@as(pairs.Pairs, undefined).optional) == ?pkl.Pair(pkl.Value, pkl.Value));
    try std.testing.expect(@TypeOf(@as(pairs.Pairs, undefined).typeargaliased.second) == i64);

    const OverrideFoo = override_pkg.Override(override_pkg.Foo);
    const OverrideBar = override_pkg.Override(override_pkg.Bar);
    try std.testing.expect(@TypeOf(@as(OverrideFoo, undefined).foo) == override_pkg.Foo);
    try std.testing.expect(@TypeOf(@as(OverrideBar, undefined).foo) == override_pkg.Bar);
}

test "generated inheritance flattening and hidden-property filtering stay stable" {
    try std.testing.expect(@hasField(extendopenclass.MyClass, "mystr"));
    try std.testing.expect(@hasField(extendopenclass.MyClass, "myboolean"));

    try std.testing.expect(@hasField(extendabstractclass.C, "b"));
    try std.testing.expect(@hasField(extendabstractclass.C, "c"));
    try std.testing.expect(@hasField(extendabstractclass.C, "e"));
    try std.testing.expect(@hasField(extendabstractclass.C, "d"));
    try std.testing.expect(@TypeOf(@as(extendabstractclass.C, undefined).c) == support_lib3.ZigZigZig);

    try std.testing.expect(@hasField(bugholder.D, "a"));
    try std.testing.expect(@hasField(bugholder.D, "b"));
    try std.testing.expect(@hasField(bugholder.D, "c"));
    try std.testing.expect(@hasField(bugholder.D, "d"));

    try std.testing.expect(@hasField(hiddenproperties.HiddenProperties, "propc"));
    try std.testing.expect(!@hasField(hiddenproperties.HiddenProperties, "propa"));
    try std.testing.expect(!@hasField(hiddenproperties.HiddenProperties, "propb"));
}
