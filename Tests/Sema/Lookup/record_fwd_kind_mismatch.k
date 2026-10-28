// A forward declaration names the same entity as its definition, so the two
// must agree on the keyword: `class`, `struct` and `union` are different
// kinds of record (defaults, what a body may hold, the C++ tag) and cannot
// share a chain. The error is at the forward declaration, the note at the
// definition (or at the first forward declaration when there is none), and
// the fix-it rewrites the forward declaration's keyword. Uses of the name
// afterwards resolve to the definition without a cascade. A leading
// modifier (`final class`) gets no fix-it: the edit would land on the wrong
// word. Two definitions stay a redefinition whatever their keywords, and a
// record beside a non-record stays a conflict of kinds.

struct A
class A { pub var x: i32 }

union B
struct B { pub var x: i32 }

class C
union C { pub var x: i32 }

struct D
union D                         // disagrees; the other forward one still links
struct D { pub var x: i32 }

struct E
union E                         // no definition: against the first

final class F
struct F { pub var x: i32 }

struct G { pub var x: i32 }
class G { pub var y: i32 }      // two bodies: a redefinition

struct H
var H: i32 = 0                  // not a record

fn main() -> i32 {
    var a: *A = &null
    var b = B{x: 1}
    var d = D{x: 2}
    return b.x + d.x
}

// --- lit wiring ---

// BEGIN-GENERATED-CHECKS(DIAG) mode=diag -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// DIAG: {{.*}}:12:1: error [R001E]: 'A' is forward-declared as a struct but defined as a class
// DIAG-NEXT: fix-it:"{{.*}}":{12:1-12:7}:"class"
// DIAG-NEXT: {{.*}}:13:1: note [R001N]: 'A' is defined here as a class
// DIAG: {{.*}}:15:1: error [R001E]: 'B' is forward-declared as a union but defined as a struct
// DIAG-NEXT: fix-it:"{{.*}}":{15:1-15:6}:"struct"
// DIAG-NEXT: {{.*}}:16:1: note [R001N]: 'B' is defined here as a struct
// DIAG: {{.*}}:18:1: error [R001E]: 'C' is forward-declared as a class but defined as a union
// DIAG-NEXT: fix-it:"{{.*}}":{18:1-18:6}:"union"
// DIAG-NEXT: {{.*}}:19:1: note [R001N]: 'C' is defined here as a union
// DIAG: {{.*}}:22:1: error [R001E]: 'D' is forward-declared as a union but defined as a struct
// DIAG-NEXT: fix-it:"{{.*}}":{22:1-22:6}:"struct"
// DIAG-NEXT: {{.*}}:23:1: note [R001N]: 'D' is defined here as a struct
// DIAG: {{.*}}:26:1: error [R001E]: 'E' is forward-declared as a union here and as a struct before
// DIAG-NEXT: fix-it:"{{.*}}":{26:1-26:6}:"struct"
// DIAG-NEXT: {{.*}}:25:1: note [R001N]: 'E' is first forward-declared here as a struct
// DIAG: {{.*}}:28:1: error [R001E]: 'F' is forward-declared as a class but defined as a struct
// DIAG-NEXT: {{.*}}:29:1: note [R001N]: 'F' is defined here as a struct
// DIAG: {{.*}}:32:1: error [R029E]: 'G' declared with conflicting kinds
// DIAG-NEXT: {{.*}}:31:1: note [R029N]: previous declaration of 'G' is here
// DIAG: {{.*}}:35:1: error [R029E]: 'H' declared with conflicting kinds
// DIAG-NEXT: {{.*}}:34:1: note [R029N]: previous declaration of 'H' is here
// END-GENERATED-CHECKS(DIAG)
