// `typeof T` compared with a type in an `eval if` selects a branch for a
// generic parameter instantiated with a class, a primitive, or a type no
// branch names; each type-checks clean with no internal error.
class A { var x: u32 = 0; }
class Tab {
    fn <T> create(self) -> u32 {
        eval if typeof T == A {
            return 1;
        } else if typeof T == i32 {
            return 2;
        }
        return 0;
    }
    fn go(self) -> u32 { return self.create<A>() + self.create<i32>() + self.create<bool>(); }
}

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --allow-empty --implicit-check-not='error [' --implicit-check-not='I003E' --implicit-check-not='internal'
