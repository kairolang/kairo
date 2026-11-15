// A primitive type's name always denotes the type, so no declaration may
// take it as its name (the parser says the same of a function, S047E, and of
// a parameter): a variable, a field, a record, an enumerator or a generic
// parameter named `u8` could never be referred to. `#u8` is a plain name.

fn locals() -> i32 {
    var u8 = 1
    const #u8 = 2
    return #u8
}

fn param(b: i32) -> i32 { return 0 }

class Holder { var f32: i32 = 0 }
struct char { var v: i32 }
enum Kind { i64, Other }
fn <usize> gen() -> i32 { return 0 }

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: primitive_type_name_decl.k:7:9: error [SC331E]: variable name 'u8' is the name of a primitive type, which it always denotes; choose another name
// CHECK: primitive_type_name_decl.k:14:20: error [SC331E]: field name 'f32'
// CHECK: primitive_type_name_decl.k:15:8: error [SC331E]: struct name 'char'
// CHECK: primitive_type_name_decl.k:16:13: error [SC331E]: enum variant name 'i64'
// CHECK: primitive_type_name_decl.k:17:5: error [SC331E]: generic parameter name 'usize'
// CHECK-NOT: error
