// An extension operator on a primitive, conforming it to an interface with
// an operator requirement. Its C++ forwarder `operator<(long, long)`
// is not a legal C++ overload ([over.oper]: some operand must be of class
// or enum type), so the extension was CL001E. No forwarder is written for
// such an operator: Kairo calls the extension's static member, and the
// bound generic goes through Less's witness. An extension operator with a
// class operand keeps its forwarder.

pub interface Less { fn op < (const self, const o: Self) -> bool }

extend i64 impl Less {
    fn op < (const self, const o: i64) -> bool { return (self as i64) < (o as i64) }
}

struct Box { var v: i32 }

extend Box {
    fn op + (const self, const o: i32) -> i32 { return self.v + o }
}

fn <T impl Less> smaller(a: T, b: T) -> T { return if a < b => a else => b }

fn main() -> i32 {
    var b = Box { v: 40 }
    if (b + 2) != 42 {
        return 1
    }

    return smaller<i64>(5, 2) as i32
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-ir 2>/dev/null || true; } | %FileCheck %s --check-prefix=IR
// IR-NOT: operator{{ ?}}<(const signed long
// IR: inline signed int operator{{ ?}}+(const{{.*}}Box & __kairo_a0

// REQUIRES: default-sysroot
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 2
