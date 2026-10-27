// A plain enum is closed unless it is `@open` (enums-plain.mdx): `as` into
// it from its underlying type is checked, so it never holds a value no
// variant has, and the values past a dense one's variants are a niche.
// Here the run-time half: a non-constant operand is tested on the integer
// (`v >= N` for a dense enum, plus `v < 0` when signed; one `!=` per variant
// otherwise) and a miss crashes like a failed bounds check -- a message on
// stderr and SIGABRT (status 134), no panic, nothing after it runs. An
// `@open` enum takes any value unchecked and keeps no niche: `Raw?` keeps a
// tag, and `200 as Raw` reads back as 200, not as null.

import std::io::println

enum Color derives u8 { Red, Green, Blue }
enum Spread derives u8 { Lo = 1, Hi = 5 }
enum Sign derives i8 { Neg = -1, Zero = 0, Pos = 1 }
enum Dense derives i8 { A, B }
@open enum Raw derives u8 { X, Y }

fn color(v: u8) -> Color = v as Color
fn spread(v: u8) -> Spread = v as Spread
fn sign(v: i8) -> Sign = v as Sign
fn dense(v: i8) -> Dense = v as Dense
fn raw(v: u8) -> Raw = v as Raw

fn main() -> i32 {
    var r = 0
    if (sizeof(Color?) == 1) && (sizeof((Color?)?) == 1) && (sizeof(Raw?) == 2) { r += 1 }
    if (__builtin_niche_of<Color>() == 253) && (__builtin_niche_of<Raw>() == 0) && (__builtin_niche_of<Spread>() == 0) { r += 2 }
    if (color(2) == .Blue) && (spread(5) == .Hi) && (sign(-1) == .Neg) && (dense(1) == .B) { r += 4 }
    var o: Raw? = raw(200)
    if o? && ((o ?? Raw::X) as u8 == 200) { r += 8 }
    println(f"ok {r}")
    println("before")
    var bad = color(3)
    println(f"not reached {bad as u8}")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// The nested nullable is S055W ("rarely what you want"): wanted here.
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error
// DIAG-NOT: warning [{{[^S]|S[^0]|S0[^5]|S05[^5]}}

// The checks, each on the integer before the plain cast; none for `raw`.
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=IR
// IR-LABEL: CODEGEN C++: {{.*}}closed_enum_cast.k
// IR:       color(
// IR:       if(__kairo_ecast{{[0-9]+}} >= 3) {
// IR-NEXT:  ::builtin::unwrap_failed({{.*}}"v as Color: the value is no variant of the closed enum 'Color' at {{.*}}closed_enum_cast.k:19:28\012"{{.*}}, {{[0-9]+}});
// IR:       spread(
// IR:       if({{.*}}__kairo_ecast{{[0-9]+}} != 1{{.*}}&&{{.*}}__kairo_ecast{{[0-9]+}} != 5{{.*}}) {
// IR:       sign(
// IR:       !=(- 1)
// IR:       dense(
// IR:       __kairo_ecast{{[0-9]+}}{{ ?}}<{{ ?}}0{{.*}}||{{.*}}__kairo_ecast{{[0-9]+}} >= 2
// IR:       raw(
// IR-NOT:   unwrap_failed
// IR:       int main()

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe > %t.out 2> %t.err; test $? -eq 134
// RUN: %FileCheck %s --check-prefix=OUT --match-full-lines < %t.out
// RUN: %FileCheck %s --check-prefix=ERR --match-full-lines < %t.err
// OUT:      ok 15
// OUT-NEXT: before
// OUT-NOT:  not reached
// ERR:      v as Color: the value is no variant of the closed enum 'Color' at {{.*}}closed_enum_cast.k:19:28
// ERR-NOT:  {{.}}
