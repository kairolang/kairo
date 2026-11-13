// A builtin type meets an interface's operator requirement through its own
// operator when the shapes match: operands Self, and the requirement's
// result with Self substituted. The bounded body calls the bound's witness;
// the witness computes Kairo's operator, so integer arithmetic wraps, a
// shift count is taken modulo the register width, and `MIN / -1` is `MIN`.
// One bounded function takes a primitive and a class that declares the
// operator.

interface Add { fn op + (const self, const o: Self) -> Self }
interface Mul { fn op * (const self, const o: Self) -> Self }
interface Ord { fn op <=> (const self, const o: Self) -> Ordering }
interface Less { fn op < (const self, const o: Self) -> bool }
interface Div { fn op / (const self, const o: Self) -> Self }
interface Rem { fn op % (const self, const o: Self) -> Self }
interface Shl { fn op << (const self, const o: Self) -> Self }
interface Shr { fn op >> (const self, const o: Self) -> Self }
interface Neg { fn op - (const self) -> Self }
interface Inv { fn op ~ (const self) -> Self }
interface BitOr { fn op | (const self, const o: Self) -> Self }
interface AddAssign { fn op += (self, const o: Self) }

fn <T impl Add> twice(const a: T) -> T { return a + a }
fn <T impl Ord> max_of(const a: T, const b: T) -> T {
    if a < b { return b }
    return a
}
fn <T impl Ord> cmp(const a: T, const b: T) -> Ordering { return a <=> b }
fn <T impl Less> lmax(const a: T, const b: T) -> T {
    if a < b { return b }
    return a
}
fn <T impl Div> quo(const a: T, const b: T) -> T { return a / b }
fn <T impl Rem> rem(const a: T, const b: T) -> T { return a % b }
fn <T impl Shl> shl(const a: T, const b: T) -> T { return a << b }
fn <T impl Shr> shr(const a: T, const b: T) -> T { return a >> b }
fn <T impl Neg> neg(const a: T) -> T { return -a }
fn <T impl Inv> inv(const a: T) -> T { return ~a }
fn <T impl BitOr> bor(const a: T, const b: T) -> T { return a | b }
fn <T impl AddAssign> thrice(const a: T) -> T {
    var x = a
    x += a
    x += a
    return x
}
fn <T impl AddAssign> plus(const a: T, const b: T) -> T { return a + b }

class <T> Vec2 requires T impl Mul && T impl Add {
    pub var x: T
    pub var y: T

    fn Vec2(self, x: T, y: T) {
        self.x = x
        self.y = y
    }

    fn dot(const self, const o: Vec2<T>) -> T { return self.x * o.x + self.y * o.y }
}

class Money {
    pub var c: i32 = 0

    fn Money(self) { }
    fn Money(self, c: i32) { self.c = c }
    fn op + (const self, const o: Money) -> Money { return Money(self.c + o.c) }
}

fn main() -> i32 {
    var r = 0
    if twice(2) != 4 { r |= 1 }
    if twice(200 as u8) != (144 as u8) { r |= 2 }
    if twice(1.25) != 2.5 { r |= 4 }
    if twice(2147483647) != -2 { r |= 8 }
    if max_of(3, 9) != 9 { r |= 16 }
    if max_of('a', 'z') != 'z' { r |= 32 }
    if cmp(1, 2) != Ordering::Less || cmp('b', 'a') != Ordering::Greater { r |= 64 }
    if lmax(2.5, 1.0) != 2.5 { r |= 128 }
    var min = -2147483647 - 1
    if quo(min, -1) != min || rem(min, -1) != 0 || quo(7.0, 2.0) != 3.5 { r |= 256 }
    if shl(1, 33) != 2 || shr(-8, 1) != -4 || shl(1 as u8, 9 as u8) != (0 as u8) { r |= 512 }
    if neg(min) != min || neg(2.0) != -2.0 || inv(0 as u32) != (4294967295 as u32) { r |= 1024 }
    if bor(true, false) != true || bor(5, 2) != 7 { r |= 2048 }
    if thrice(5 as i64) != 15 || plus(2.5, 0.5) != 3.0 { r |= 4096 }
    var vi = Vec2<i32>(2, 3)
    var vf = Vec2<f64>(0.5, 2.0)
    if vi.dot(Vec2<i32>(4, 5)) != 23 || vf.dot(Vec2<f64>(2.0, 0.25)) != 1.5 { r |= 8192 }
    if twice(Money(21)).c != 42 { r |= 16384 }
    return r
}

// --- lit wiring ---
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s
// CHECK-LABEL: struct Add_witness {
// CHECK: static __kairo_Self __kairo_op_plus(const __kairo_Self & self, const __kairo_Self & o) noexcept requires((
// CHECK-LABEL: struct Add_witness<signed int> {
// CHECK: static_cast<__kairo_T0>(static_cast<__kairo_U0>(__kairo_a0) + static_cast<__kairo_U0>(__kairo_b0))
