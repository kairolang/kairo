// A non-generic payload enum whose payload holds an instance of a generic
// class, `Box<i32>` (enums-adt.mdx): the instance is concrete, so its copy,
// move and destruction are known.
// ClassLifecycle computes them per instance, from Box's fields over its
// argument (MONO.md G6), so the enum is laid out like any other. Was SC116E
// "an enum whose payload's lifecycle is not known until instantiation"
// while an instance read its pattern's facts (GitHub #85).

class <T> Box {
    pub var v: T
    fn Box(self, v: T) { self.v = v }
}

enum W {
    Has { b: Box<i32> },
    Empty,
}

fn main() -> i32 {
    var w = W::Has { b: Box<i32>(4) }
    return match w {
        case .Has(const b) => b.v
        case .Empty => 0
    }
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 4
