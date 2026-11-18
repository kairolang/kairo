// `op as` declared in extensions of a struct, a class, an enum, `string`,
// a primitive and a container, used written (`as`) and unwritten
// (`@implicit`) at every kind of site: an initializer, an assignment, an
// argument by value and by `const`, a return. Each use is a call of the
// extension scope's static member, written out in the C++, since C++
// cannot find a conversion that is not a member.

import std::io

struct Meters { var v: i32 }
struct Feet { var v: i32 }

class Yard {
    pub var v: i32
    pub fn Yard(self, v: i32) { self.v = v }
}

enum Unit { Inch, Foot }

extend Feet {
    @implicit fn op as (const self) -> Meters { return Meters{v: self.v / 3} }
    fn op as (const self) -> i64 { return 40 }
}

extend Yard {
    @implicit fn op as (const self) -> Meters { return Meters{v: self.v} }
}

extend Unit {
    @implicit fn op as (const self) -> Meters { return Meters{v: 7} }
}

extend string {
    @implicit fn op as (const self) -> Meters { return Meters{v: self.size() as i32} }
}

extend i32 {
    fn op as (const self) -> Meters { return Meters{v: self} }
}

extend <T> [T] {
    @implicit fn op as (const self) -> Meters { return Meters{v: self.size() as i32} }
}

fn take(m: Meters) -> i32 { return m.v }
fn takec(const m: Meters) -> i32 { return m.v }
fn ret(f: Feet) -> Meters { return f }

fn main() -> i32 {
    var f = Feet{v: 9}
    var m: Meters = f                // 3
    var total = m.v
    m = f
    total += m.v                     // 3
    total += take(f)                 // 3
    total += takec(f)                // 3
    total += ret(f).v                // 3
    total += (f as Meters).v         // 3
    total += (f as i64) as i32       // 40
    var y = Yard(2)
    total += take(y)                 // 2
    total += take(Unit::Inch)        // 7
    var s: string = "abcd"
    total += take(s)                 // 4
    total += (5 as Meters).v         // 5
    var v: [i64] = [1, 2, 3]
    total += take(v)                 // 3
    total += (v as Meters).v         // 3
    io::println(f"{total}")
    return total - 82
}

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo %s -o %t.exe
// RUN: %t.exe | %FileCheck %s --check-prefix=OUT
// OUT: 82
// RUN: %kairo %s --print-ir | %FileCheck %s --check-prefix=CXX
// A static member of the scope struct, named by its result:
// CXX: static{{ ?}}::run::Meters __kairo_op_as___run__Meters(const{{ ?}}::run::Feet &)
// CXX: static signed long __kairo_op_as_signed_long(const{{ ?}}::run::Feet &)
// and every implicit use is the call:
// CXX: ::run::Meters m = ::run::__kairo_ext_Feet::__kairo_op_as___run__Meters(f);
// CXX: ::run::take({{ ?}}::run::__kairo_ext_Feet::__kairo_op_as___run__Meters(f))
