// Two generic derived interfaces each give one inherited associated type a
// default over their own parameter (`A<U>`'s `U`, `B<V>`'s `V`). Which
// default applies is decided on the types they read as for the conformer:
// `A<i32>, B<i32>` agree on i32 (`Same` conforms), `A<i32>, B<i64>` do not
// (`Split` takes neither, interfaces.md, "Associated types and
// inheritance"). Compared as written, U and V would always be two defaults.

interface <T> Source { type Item  fn get(const self) -> Self::Item }
interface <U> A derives Source<U> { type Item = U }
interface <V> B derives Source<V> { type Item = V }

class Same impl A<i32>, B<i32> {
    fn Same(self) { }
    fn get(const self) -> i32 { return 1 }
}
class Split impl A<i32>, B<i64> {
    fn Split(self) { }
    fn get(const self) -> i32 { return 2 }
}

fn <S impl Source<i32>> use(s: S) -> i32 { return 0 }

fn main() -> i32 {
    var a = use(Same())
    var b = use(Split())
    return 0
}

// --- lit wiring -----------------------------------------------------------

// BEGIN-GENERATED-CHECKS(DIAG) mode=diag -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// DIAG: {{.*}}:25:13: error [SC161E]: 'Split' does not conform to 'Source<i32>': its interfaces give associated type 'Item' two defaults, 'i32' from 'A' and 'i64' from 'B'
// DIAG-NEXT: {{.*}}:21:5: note [I900N]: required by this bound
// DIAG-NEXT: {{.*}}:9:49: note [I900N]: 'A' gives it 'i32' here
// DIAG-NEXT: {{.*}}:10:49: note [I900N]: 'B' gives it 'i64' here; declare 'type Item = ...' in 'Split' to choose
// END-GENERATED-CHECKS(DIAG)
