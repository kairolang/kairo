// What a body may not do with an associated type it names correctly,
// each a diagnostic at the use (interfaces.md, Generic Bodies: a body uses
// exactly what its bounds declare; MONO.md G5):
//  - build one without a constructor bound (`{ }`, `()`), or with a field
//    list, which no bound can promise;
//  - use a member through the associated type's own bounds (SC116E: not
//    built yet);
//  - fall off the end of a body declared to return one (SC104E), as any
//    value-returning body.
// `type Made impl Default` makes `T::Made{}` and `T::Made()` legal.

interface Display { fn show(const self) -> i32 }
interface Default { fn Default(self) }

interface Store {
    type Item impl Display
    type Made impl Default
    fn get(const self) -> Self::Item
}

fn <T impl Store> built(s: T) -> i32 {
    var a = T::Made{}
    var b = T::Made()
    var c = T::Item{}
    var d = T::Item()
    var e = T::Made{v: 1}
    var x: T::Item = s.get()
    var f = x.show()
    var g = s.get().show()
    return 0
}

fn <T impl Store> noreturn(s: T) -> T::Item { s.get() }

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK-NOT: {{error|warning}}
// CHECK: assoc_type_body_errors.k:24:13: error [SC001E]: cannot construct 'T::Item': no bound of associated type 'Item' requires a constructor taking no arguments
// CHECK-NEXT: assoc_type_body_errors.k:16:5: note [I900N]: 'Item' is declared here; bound it with an interface that declares a constructor requirement
// CHECK-NOT: {{error|warning}}
// CHECK: assoc_type_body_errors.k:25:13: error [SC001E]: cannot construct 'T::Item': no bound of associated type 'Item' requires a constructor taking 0 argument(s)
// CHECK-NEXT: assoc_type_body_errors.k:16:5: note [I900N]: 'Item' is declared here; bound it with an interface that declares a constructor requirement
// CHECK-NOT: {{error|warning}}
// CHECK: assoc_type_body_errors.k:26:13: error [SC088E]: 'T::Made' is an associated type: a generic body knows none of its fields
// CHECK-NEXT: assoc_type_body_errors.k:17:5: note [I900N]: 'Made' is declared here; build it through a constructor bound ('type Made impl ...')
// CHECK-NOT: {{error|warning}}
// CHECK: assoc_type_body_errors.k:28:14: error [SC116E]: a member of associated type 'T::Item' cannot be used yet; lookup through an associated type's bounds is not supported
// CHECK-NEXT: assoc_type_body_errors.k:16:5: note [SC116N]: the associated type is declared here
// CHECK-NOT: {{error|warning}}
// CHECK: assoc_type_body_errors.k:29:20: error [SC116E]: a member of associated type 'T::Item' cannot be used yet; lookup through an associated type's bounds is not supported
// CHECK-NEXT: assoc_type_body_errors.k:16:5: note [SC116N]: the associated type is declared here
// CHECK-NOT: {{error|warning}}
// CHECK: assoc_type_body_errors.k:33:55: error [SC104E]: 'noreturn' does not return a value on all control paths
// CHECK-NEXT: assoc_type_body_errors.k:33:37: note [SC104N]: declared to return 'T::Item' here; every path must end in 'return', 'panic', or a call that does not return
// CHECK-NOT: {{error|warning}}
