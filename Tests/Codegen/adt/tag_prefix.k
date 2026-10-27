// The tag in the payloads' common prefix (spec ENUMLAYOUT §6). A
// non-generic ADT whose payload fields are all builtins, pointers or plain
// enums puts its tag first in every payload struct, gives the union a
// tag-only member, and reads the tag through that member -- the
// common-initial-sequence rule makes the read defined, since every payload
// struct is standard-layout. The payload's padding absorbs the tag: Pair is
// `{u8, u8, u16} | {u8, u8}`, 4 bytes, where the tag beside the union took 6.
// Anything else (here a string payload) keeps the tag beside the union. The
// tag's spare values are still a niche: `Pair?` is a Pair.

enum Pair { Two { a: u8, b: u16 }, One { c: u8 }, Zero }
enum Named { Called { s: string }, Anon }

fn sum(p: Pair) -> i32 = match p {
    case .Two(var a, var b) => (a as i32) + (b as i32)
    case .One(var c)        => c
    case .Zero              => 0
}

fn named(n: Named) -> i32 = match n {
    case .Called(const s) => s.len as i32
    case .Anon            => -1
}

fn main() -> i32 {
    var r = 0
    if sizeof(Pair) == 4 { r += 1 }
    var x = Pair::Two { a: 1, b: 300 }
    var y = x
    if (sum(y) == 301) && (sum(Pair::One { c: 7 }) == 7) && (sum(.Zero) == 0) { r += 2 }
    if (x == y) && (x != Pair::Zero) { r += 4 }
    var n: Pair? = null
    var m: Pair? = Pair::One { c: 2 }
    if (sizeof(Pair?) == 4) && (!n?) && m? { r += 8 }
    if (named(Named::Called { s: "abc" }) == 3) && (named(.Anon) == -1) { r += 16 }
    return r                                    // 31
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --type-check-only --print-cxx 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-LABEL: CXX PREAMBLE fid {{[0-9]+}}: {{.*}}tag_prefix.k
// CXX:       struct Pair {
// CXX:       struct __kairo_Two_t {
// CXX:       __kairo_Tag __kairo_tag;
// CXX-NEXT:  unsigned char a;
// CXX-NEXT:  unsigned short b;
// CXX:       union {
// CXX-NEXT:  __kairo_t_t __kairo_t;
// CXX-NEXT:  __kairo_Two_t __kairo_Two;
// CXX-NEXT:  __kairo_One_t __kairo_One;
// CXX-NEXT:  };
// CXX-NEXT:  Pair(::__kairo_vt<0>, unsigned char a, unsigned short b) noexcept : __kairo_Two {
// CXX-NEXT:  __kairo_Tag::Two, a, b }
// CXX:       Pair(::__kairo_vt<2>) noexcept : __kairo_t {
// CXX-NEXT:  __kairo_Tag::Zero }
// CXX:       struct Named {
// CXX:       __kairo_Tag __kairo_tag;
// CXX-NEXT:  union {

// RUN: { %kairo %s --print-ir 2>/dev/null || true; } | %FileCheck %s --check-prefix=IR
// IR-LABEL: CODEGEN C++: {{.*}}tag_prefix.k
// IR:       signed int sum(
// IR:       switch(static_cast<unsigned int>(__kairo_m0_s.__kairo_t.__kairo_tag)) {
// IR:       signed int named(
// IR:       switch(static_cast<unsigned int>(__kairo_m0_s.__kairo_tag)) {

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 31
