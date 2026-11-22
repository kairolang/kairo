// An interface may require a marked `op l++` / `op r++`. The two share one
// member name and differ by fixity, so a type meets each requirement with
// the member of the same fixity, and only with that one: a prefix operator
// does not stand in for a required postfix one, nor the reverse. A bound
// that requires only the prefix form does not grant `w++`.

interface Step {
    fn op l++(self) -> Self
    fn op r++(self) -> Self
}

interface Pre {
    fn op l++(self) -> Self
}

interface Post {
    fn op r--(self) -> Self
}

struct Both impl Step {
    var x: i32
    fn op l++(self) -> Both { return Both{ x: self.x + 1 } }
    fn op r++(self) -> Both { return Both{ x: self.x + 2 } }
}

struct OnlyPre impl Pre {
    var x: i32
    fn op l++(self) -> OnlyPre { return OnlyPre{ x: self.x + 1 } }
}

struct OnlyPost impl Post {
    var x: i32
    fn op r--(self) -> OnlyPost { return OnlyPost{ x: self.x - 1 } }
}

struct MissingPost impl Step {
    var x: i32
    fn op l++(self) -> MissingPost { return MissingPost{ x: self.x + 1 } }
}

struct WrongFixity impl Pre {
    var x: i32
    fn op r++(self) -> WrongFixity { return WrongFixity{ x: self.x + 1 } }
}

fn <T impl Step> bump(v: T) -> T {
    var w = v
    var a = ++w
    var b = w++
    return b
}

fn <T impl Pre> pre(v: T) -> T {
    var w = v
    return ++w
}

fn <T impl Pre> pre_only(v: T) -> T {
    var w = v
    var a = w++
    return a
}

fn main() -> i32 {
    var r = bump(Both{ x: 0 })
    var p = pre(OnlyPre{ x: 0 })
    var m = bump(MissingPost{ x: 0 })
    var f = pre(WrongFixity{ x: 0 })
    return 0
}

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: {{.*}}:36:25: error [SC162E]: 'MissingPost' declares 'impl Step' but does not conform to it: it has no 'op r++' with the requirement's signature
// CHECK: {{.*}}:41:25: error [SC162E]: 'WrongFixity' declares 'impl Pre' but does not conform to it: it has no 'op l++' with the requirement's signature
// CHECK: {{.*}}:60:13: error [R025E]: '++' on 'T' needs a bound that declares 'op ++'; none of the bounds of 'T' does
// CHECK: {{.*}}:67:13: error [SC162E]: 'MissingPost' does not conform to 'Step': no member 'op r++' with the requirement's signature
// CHECK: {{.*}}:9:5: note [I900N]: 'op r++' is required here
// CHECK: {{.*}}:68:13: error [SC162E]: 'WrongFixity' does not conform to 'Pre': no member 'op l++' with the requirement's signature
// CHECK: {{.*}}:13:5: note [I900N]: 'op l++' is required here
