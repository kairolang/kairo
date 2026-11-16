// Inheritance visibility is one rule for a member reached through a value
// and for one named through the class (classes-inheritance.mdx): with
// `class Der derives priv Base`, `Der::make()`, `Der::count`, the nested
// type `Der::Inner` and the enumerator `Der::Color::Red` are as private to
// Der's file as `d.x` is. Through a `prot` edge they are protected: a class
// deriving the edge's class names them, nothing else outside the module
// does. An alias of the deriving class and a class deriving it further
// carry the same edge. Named through `Base` itself, or through a class
// deriving it plainly, they stay public. Inputs/access_static_edge_lib.k
// names them all through every class in its own file.

import Inputs::access_static_edge_lib::*

fn through_value() -> i32 {
    var d = Der()
    return d.x
}

fn statics() -> i32 {
    return Der::make() + Der::count
}

fn nested_type() -> i32 {
    var i = Der::Inner{}
    return i.k
}

fn enumerator() -> bool {
    var c = Der::Color::Red
    return c == Base::Color::Red
}

fn prot_edge() -> i32 {
    return Pro::make() + Pro::count
}

fn alias_and_further() -> i32 {
    return DerAlias::make() + Far::make()
}

fn clean() -> i32 {
    var i = Open::Inner{}
    var c = Open::Color::Green
    return Base::make() + Base::count + Open::make() + Open::count + i.k + Der::own()
}

class Sub derives Pro {
    fn Sub(self) { }
    fn reach(self) -> i32 { return Pro::make() + Pro::count + Sub::make() }
    fn base_call(self) -> i32 { return Base::twice(self) }
}

class Sub2 derives Der {
    fn Sub2(self) { }
    fn reach(self) -> i32 { return Der::make() }
}

fn main() -> i32 {
    return clean() + lib_reads()
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [" --implicit-check-not="warning ["
// CHECK: {{.*}}access_static_through_edge.k:16:13: error [SC242E]: 'x' is inaccessible through 'Der': 'Der' derives 'Base' as private
// CHECK-NEXT: {{.*}}Inputs/access_static_edge_lib.k:16:23: note [SC242N]: 'Der' declares its base 'Base' 'priv' here, so the members of 'Base' are private to 'Der' and its file
// CHECK: {{.*}}access_static_through_edge.k:20:15: error [SC242E]: 'make' is inaccessible through 'Der': 'Der' derives 'Base' as private
// CHECK-NEXT: {{.*}}Inputs/access_static_edge_lib.k:16:23: note [SC242N]: 'Der' declares its base 'Base' 'priv' here, so the members of 'Base' are private to 'Der' and its file
// CHECK: {{.*}}access_static_through_edge.k:20:29: error [SC242E]: 'count' is inaccessible through 'Der': 'Der' derives 'Base' as private
// CHECK-NEXT: {{.*}}Inputs/access_static_edge_lib.k:16:23: note [SC242N]: 'Der' declares its base 'Base' 'priv' here, so the members of 'Base' are private to 'Der' and its file
// CHECK: {{.*}}access_static_through_edge.k:24:16: error [SC242E]: 'Inner' is inaccessible through 'Der': 'Der' derives 'Base' as private
// CHECK-NEXT: {{.*}}Inputs/access_static_edge_lib.k:16:23: note [SC242N]: 'Der' declares its base 'Base' 'priv' here, so the members of 'Base' are private to 'Der' and its file
// CHECK: {{.*}}access_static_through_edge.k:29:16: error [SC242E]: 'Color' is inaccessible through 'Der': 'Der' derives 'Base' as private
// CHECK-NEXT: {{.*}}Inputs/access_static_edge_lib.k:16:23: note [SC242N]: 'Der' declares its base 'Base' 'priv' here, so the members of 'Base' are private to 'Der' and its file
// CHECK: {{.*}}access_static_through_edge.k:34:15: error [SC242E]: 'make' is inaccessible through 'Pro': 'Pro' derives 'Base' as protected
// CHECK-NEXT: {{.*}}Inputs/access_static_edge_lib.k:22:23: note [SC242N]: 'Pro' declares its base 'Base' 'prot' here, so the members of 'Base' are protected to 'Pro' and its file
// CHECK: {{.*}}access_static_through_edge.k:34:29: error [SC242E]: 'count' is inaccessible through 'Pro': 'Pro' derives 'Base' as protected
// CHECK-NEXT: {{.*}}Inputs/access_static_edge_lib.k:22:23: note [SC242N]: 'Pro' declares its base 'Base' 'prot' here, so the members of 'Base' are protected to 'Pro' and its file
// CHECK: {{.*}}access_static_through_edge.k:38:20: error [SC242E]: 'make' is inaccessible through 'Der': 'Der' derives 'Base' as private
// CHECK-NEXT: {{.*}}Inputs/access_static_edge_lib.k:16:23: note [SC242N]: 'Der' declares its base 'Base' 'priv' here, so the members of 'Base' are private to 'Der' and its file
// CHECK: {{.*}}access_static_through_edge.k:38:34: error [SC242E]: 'make' is inaccessible through 'Der': 'Der' derives 'Base' as private
// CHECK-NEXT: {{.*}}Inputs/access_static_edge_lib.k:16:23: note [SC242N]: 'Der' declares its base 'Base' 'priv' here, so the members of 'Base' are private to 'Der' and its file
// CHECK: {{.*}}access_static_through_edge.k:55:39: error [SC242E]: 'make' is inaccessible through 'Der': 'Der' derives 'Base' as private
// CHECK-NEXT: {{.*}}Inputs/access_static_edge_lib.k:16:23: note [SC242N]: 'Der' declares its base 'Base' 'priv' here, so the members of 'Base' are private to 'Der' and its file
