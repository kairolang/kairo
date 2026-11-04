// RUN: rm -rf %t.d
// RUN: { %kairo %s -o %t.exe --cache-dir %t.d 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: %t.exe; test $? -eq 6
//
// A record's own operator used on the record inside its generic body
// (`!(self == other)` in `Q<T>::op !=`): both operands are `Q<T>`, so
// OperatorTyping defers the operator to the instance and binds nothing, and
// EmitIR's "user operator; OperatorLowering must rewrite it into a call"
// guard ICEd on it. clang picks the operator member per instantiation, as it
// does for a duck operand. Found compiling the migrated AST/Mixin/TypeQual.k
// to an object (self-host phase 5.3).

// DIAG-NOT: I003E

class <T> Q {
    pub var f: i32 = 0
    fn op == (const self, const other: Q<T>) -> bool { return self.f == other.f }
    fn op != (const self, const other: Q<T>) -> bool { return !(self == other) }
    fn op + (const self, const other: Q<T>) -> Q<T> {
        var r: Q<T>
        r.f = self.f + other.f
        return r
    }
    fn twice(const self) -> Q<T> { return self + self }
}

fn main() -> i32 {
    var a: Q<i32>
    var b: Q<i32>
    b.f = 2
    var r = 0
    if a != b { r += 1 }
    if b == b { r += 1 }
    // b.twice() is 4
    return r + b.twice().f
}
