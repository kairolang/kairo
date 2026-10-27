// Every member EnumLayoutLowering generates with a body is noexcept, and so
// is the lambda a construction site passes to a variant constructor (spec
// ENUMLAYOUT §2): each is part of a Kairo frame, which is noexcept unless
// -funwind. Without it every construction site was an `invoke` with a
// terminate landing pad, and the enclosing function carried a personality
// and an exception table even at -O0. The defaulted members are left to
// C++, which deduces theirs.

enum Inst {
    Const { value: i32 },
    Binary { op_code: u8, lhs: i32, rhs: i32 },
    Text { s: string },
    Nop,
}

struct Foo { var a: i32 = 0; }

fn make(a: i32) -> Inst = Inst::Binary { op_code: 1, lhs: a, rhs: 3 }
fn text() -> Inst = Inst::Text { s: "abc" }
fn some(p: *Foo) -> (*Foo)? = p
fn num(v: i32) -> i32? = v

fn score(i: Inst) -> i32 = match i {
    case .Const(var value)    => value
    case .Binary(var lhs)     => lhs
    case .Text(const s)       => s.len as i32
    case .Nop                 => 0
}

fn main() -> i32 {
    var f = Foo{}
    var x = make(2)
    var t = text()
    var u = t
    var *o? = some(&f)
    var n? = num(4)
    var r = score(x) + score(u)                 // 2 + 3
    if o? { r += 10 }
    if n? { r += n }
    return r                                    // 19
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --type-check-only --print-cxx 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-LABEL: CXX PREAMBLE fid {{[0-9]+}}: {{.*}}noexcept_members.k
// CXX:       struct Inst {
// CXX:       Inst(::__kairo_vt<0>, F&& f) noexcept : __kairo_tag(
// CXX:       Inst(::__kairo_vt<3>) noexcept : __kairo_tag(
// CXX:       Inst(const Inst& o) noexcept : __kairo_tag(
// CXX:       Inst(Inst&& o) noexcept : __kairo_tag(
// CXX:       Inst& operator=(const Inst& o) noexcept {
// CXX:       Inst& operator=(Inst&& o) noexcept {
// CXX:       ~Inst() noexcept {
// CXX:       void __kairo_destroy() noexcept {
// CXX:       void __kairo_construct_from(O&& o) noexcept {

// RUN: { %kairo %s --type-check-only --print-cxx 2>&1 || true; } | %FileCheck %s --check-prefix=NUL
// NUL-LABEL: CXX PREAMBLE fid {{[0-9]+}}: {{.*}}noexcept_members.k
// NUL:       template<class T> struct Nullable {
// NUL:       Nullable(::__kairo_vt<1>) noexcept : __kairo_tag(
// NUL:       Nullable(const Nullable& o) noexcept requires
// NUL:       Nullable() noexcept : __kairo_tag(
// NUL:       Nullable(::builtin::null_t) noexcept : __kairo_tag(
// NUL:       Nullable(const T& v) noexcept requires __kairo_copyable :
// NUL:       Nullable(T&& v) noexcept requires __kairo_movable :
// NUL:       bool is_null() const noexcept {
// NUL:       T& __value() noexcept {
// NUL:       const T& __value() const noexcept {
// NUL:       bool operator==(const Nullable& o) const noexcept requires

// The construction site's lambda.
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=IR
// IR-LABEL: CODEGEN C++: {{.*}}noexcept_members.k
// IR:        ::Inst( ::__kairo_vt<1> {
// IR:        ,[&]() noexcept-> {{.*}}::Inst::__kairo_Binary_t {

// The TU's object has no exception table and names no personality at -O0,
// where nothing proves the calls nounwind for it.
// REQUIRES: clang
// RUN: rm -rf %t.d %t.o0
// RUN: %kairo %s -c -O0 --cache-dir %t.o0
// RUN: %objdump -h %t.o0/noexcept_members.o > %t.sections
// RUN: { ! grep -q gcc_except_table %t.sections; }
// RUN: %objdump -t %t.o0/noexcept_members.o > %t.syms
// RUN: { ! grep -q personality %t.syms; }
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 19
