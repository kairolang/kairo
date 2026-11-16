// `Feet` converts to `Meters` through an extension's `@implicit op as`.
// Kairo code uses it unwritten; the C++ this file gives a host has no
// conversion function, because the operator is not a member of `Feet`.

pub struct Meters { pub var v: i32 }
pub struct Feet { pub var v: i32 }

extend Feet {
    @implicit pub fn op as (const self) -> Meters { return Meters{v: self.v / 3} }
}

pub fn feet(v: i32) -> Feet { return Feet{v: v} }

pub fn in_meters(f: Feet) -> i32 {
    var m: Meters = f
    return m.v
}
