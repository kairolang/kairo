// A variant whose every field is trivially copied and destroyed gets one
// non-template constructor taking the fields (spec ENUMLAYOUT §3), and a
// construction calls it braced, `E{__kairo_vt<I>{}, a, b}`, instead of
// passing a lambda that returns the payload: each lambda is a distinct type
// and a distinct constructor instantiation. A braced list runs its clauses
// left to right, so a payload written out of order still runs in the order
// it was written. A field with a user move or destructor keeps the lambda
// form, which builds the payload in place: the field constructor would move
// it out of its parameter and destroy the parameter, which that user code
// would see. A generic ADT has both, the field constructor constrained on
// the same facts per instance; a concrete instance that has them calls it,
// a generic body the lambda form.

var trace: i32 = 0
var moves: i32 = 0

fn step(d: i32) -> i32 {
    trace = trace * 10 + d
    return d
}

class Counted {
    pub var n: i32
    pub fn Counted(self, n: i32) { self.n = n; }
    @move fn Counted(self, other: Self) { self.n = other.n; moves = moves + 1; }
}

enum Inst {
    Const { value: i32 },
    Binary { op_code: u8, lhs: i32, rhs: i32 },
    Boxed { c: Counted },
    Nop,
}

enum <T> Opt { Some { v: T }, None }

fn cost(i: Inst) -> i32 = match i {
    case .Const(var value)                 => value
    case .Binary(var op_code, var lhs, var rhs) => (op_code as i32) * 100 + lhs * 10 + rhs
    case .Boxed(const c)                   => c.n
    case .Nop                              => 0
}

fn <T> wrap(x: T) -> Opt<T> = Opt<T>::Some { v: x }

fn get(o: Opt<i32>) -> i32 = match o {
    case .Some(var v) => v
    case .None        => -1
}

fn main() -> i32 {
    var r = 0
    // Written rhs, op_code, lhs: runs in that order, whatever the field order.
    var b = Inst::Binary { rhs: step(3), op_code: step(1) as u8, lhs: step(2) }
    if (cost(b) == 123) && (trace == 312) { r += 1 }
    if cost(Inst::Const { value: 7 }) == 7 { r += 2 }
    moves = 0
    var x = Inst::Boxed { c: Counted(5) }
    var built = moves                               // built in place: no move
    if (built == 0) && (cost(x) == 5) { r += 4 }
    if (get(Opt<i32>::Some { v: 9 }) == 9) && (get(wrap(4)) == 4) { r += 8 }
    return r                                        // 15
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --type-check-only --print-cxx 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-LABEL: CXX PREAMBLE fid {{[0-9]+}}: {{.*}}field_ctor.k
// CXX:       struct Inst {
// CXX-NOT:   template<class F> Inst(::__kairo_vt<0>
// CXX:       Inst(::__kairo_vt<0>, signed int value) noexcept : __kairo_tag(__kairo_Tag::Const), __kairo_Const {
// CXX-NEXT:  value }
// CXX-NOT:   template<class F> Inst(::__kairo_vt<1>
// CXX:       Inst(::__kairo_vt<1>, unsigned char op_code, signed int lhs, signed int rhs) noexcept : __kairo_tag(__kairo_Tag::Binary), __kairo_Binary {
// CXX-NEXT:  op_code, lhs, rhs }
// CXX:       template<class F> Inst(::__kairo_vt<2>, F&& f) noexcept : __kairo_tag(__kairo_Tag::Boxed), __kairo_Boxed(static_cast<F&&>(f)()) {
// CXX:       Inst(::__kairo_vt<3>) noexcept : __kairo_tag(__kairo_Tag::Nop) {
// CXX:       template<class T> struct Opt {
// CXX:       Opt(::__kairo_vt<0>, T v) noexcept requires(__is_constructible(T, T&&)&& __is_trivially_copyable(T)&& __is_trivially_destructible(T)) : __kairo_tag(__kairo_Tag::Some), __kairo_Some {
// CXX-NEXT:  static_cast<T&&>(v) }
// CXX:       template<class F> Opt(::__kairo_vt<0>, F&& f) noexcept : __kairo_tag(__kairo_Tag::Some), __kairo_Some(static_cast<F&&>(f)()) {

// The sites: braced for the field constructor, the lambda for the counted
// payload and inside the generic body; the concrete Opt<i32> braced.
// RUN: { %kairo %s --print-ir 2>/dev/null || true; } | %FileCheck %s --check-prefix=IR
// IR-LABEL: CODEGEN C++: {{.*}}field_ctor.k
// IR:        Opt<T> wrap(T x) noexcept {
// IR-NEXT:   return{{.*}}::Opt<T>( ::__kairo_vt<0> {
// IR-NEXT:   }
// IR-NEXT:   ,[&]() noexcept->
// IR:        int main() noexcept {
// IR:        ::Inst b =({
// IR:        ::Inst {
// IR-NEXT:   ::__kairo_vt<1> {
// IR-NEXT:   }
// IR-NEXT:   , __kairo_arg1, __kairo_arg2, __kairo_arg0
// IR:        ::Inst x ={{.*}}::Inst( ::__kairo_vt<2> {
// IR-NEXT:   }
// IR-NEXT:   ,[&]() noexcept->
// IR:        ::Opt<signed int> {
// IR-NEXT:   ::__kairo_vt<0> {
// IR-NEXT:   }
// IR-NEXT:   , 9

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 15
