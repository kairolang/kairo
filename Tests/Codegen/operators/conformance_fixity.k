// A type conforms to an interface that requires marked `op l++` / `op r++`
// with its own members of the same fixity, and a generic function bounded
// by the interface calls each through the bound: `++w` reaches the prefix
// member and `w++` the postfix one.

interface Step {
    fn op l++(self) -> Self
    fn op r++(self) -> Self
    fn op l--(self) -> Self
    fn op r--(self) -> Self
}

struct S impl Step {
    var x: i32
    fn op l++(self) -> S { return S{ x: self.x + 1 } }
    fn op r++(self) -> S { return S{ x: self.x + 20 } }
    fn op l--(self) -> S { return S{ x: self.x + 300 } }
    fn op r--(self) -> S { return S{ x: self.x + 4000 } }
}

fn <T impl Step> pre_inc(v: T) -> T { var w = v; return ++w }
fn <T impl Step> post_inc(v: T) -> T { var w = v; return w++ }
fn <T impl Step> pre_dec(v: T) -> T { var w = v; return --w }
fn <T impl Step> post_dec(v: T) -> T { var w = v; return w-- }

fn main() -> i32 {
    var s = S{ x: 0 }
    if pre_inc(s).x != 1 || post_inc(s).x != 20 || pre_dec(s).x != 300 || post_dec(s).x != 4000 {
        return 1
    }

    return 0
}

// --- lit wiring ---
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
