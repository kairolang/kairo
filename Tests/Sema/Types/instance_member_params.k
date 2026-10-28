// A member of a generic record, reached through a concrete instance, takes
// the instance's arguments for the record's parameters before any call
// argument is ranked (MONO.md G4): on `Box<i32>`, `fn set(self, v: T)` is
// `set(v: i32)`. Deduced from the arguments instead, T became whatever was
// passed -- `b.set(NullT {})` was accepted as T := NullT, and a constructor
// taking `T` tied an exact one (Tests/Codegen/generic_ctor_overload.k).

struct NullT { }

class <T> Box {
    pub var v: T
    fn Box(self, v: T) { self.v = v }
    fn set(self, v: T) { self.v = v }
    static fn of(v: T) -> Box<T> { return Box<T>(v) }
}

fn main() -> i32 {
    var b = Box<i32>(1)
    b.set(NullT { })
    var c = Box<i32>(NullT { })
    var d = Box<i32>::of(NullT { })
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG:      instance_member_params.k:19:5: error [SC063E]: no matching overload for call to 'set'
// DIAG-NEXT: instance_member_params.k:13:5: note [I900N]: candidate not viable: cannot convert argument of type 'NullT' to parameter 'v' of type 'i32'
// DIAG:      instance_member_params.k:20:13: error [SC063E]: no matching overload for call to 'Box'
// DIAG-NEXT: instance_member_params.k:12:5: note [I900N]: candidate not viable: cannot convert argument of type 'NullT' to parameter 'v' of type 'i32'
// DIAG:      instance_member_params.k:21:13: error [SC063E]: no matching overload for call to 'of'
// DIAG-NEXT: instance_member_params.k:14:5: note [I900N]: candidate not viable: cannot convert argument of type 'NullT' to parameter 'v' of type 'i32'
// DIAG-NOT:  error
