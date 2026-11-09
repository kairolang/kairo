// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 123
//
// A plain enum's variant as an explicit generic VALUE argument
// (`define<FlagKind::Bool>()`, generics.md "Value parameters": the argument
// is evaluable at compile time, and a variant is). The path parses as a type,
// as `Ring<CAP>` does, and its last segment was R023E "'Bool' does not name
// a type". It is the variant's value now: a function's argument and a
// class's, and two uses of one variant are one instance.

enum FlagKind derives u8 { Bool, String, Int }

class C {
    fn <eval T: FlagKind> define(self) -> i32 {
        eval if T == FlagKind::Bool { return 1 }
        eval if T == FlagKind::String { return 20 }
        return 100
    }
}

class <eval K: FlagKind> Tag {
    fn code(self) -> i32 { eval if K == FlagKind::Int { return 2 } return 0 }
}

fn via_ptr(c: unsafe *C) -> i32 { return c->define<FlagKind::Bool>() }

fn main() -> i32 {
    var c = C()
    var a: Tag<FlagKind::Int>
    var b: Tag<FlagKind::Int> = a
    var n = 0
    unsafe { n = via_ptr(&c as unsafe *C) }
    return n + c.define<FlagKind::String>() + c.define<FlagKind::Int>() + b.code()
}

// DIAG-NOT: error
