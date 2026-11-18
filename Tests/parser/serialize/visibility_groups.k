// Visibility groups make the tree a DAG: a member written inside `pub { }`
// is in its record's `fields` / `methods` list AND in the group's
// `members`, and the group itself is in the record's declaration list.
// The format writes each node once, at its first reference, and every
// later reference as its node id, so the reloaded member is ONE object
// again, reachable both ways. --verify-ast-roundtrip checks the rebuilt
// symbol tables name the same nodes.

class Account {
    pub {
        var id: i32
        fn Account(self, id: i32) {
            self.id      = id
            self.balance = 0
        }

        fn deposit(self, amount: i32) {
            self.balance += amount
        }

        fn total(self) -> i32 {
            return self.balance + self.bonus()
        }
    }

    priv {
        var balance: i32
        fn bonus(self) -> i32 {
            return 1
        }
    }

    prot var tag: i32 = 7
}

struct Pair {
    pub {
        var a: i32
        var b: i32
    }

    enum Kind {
        Small,
        Large,
    }
}

module shapes {
    pub {
        fn area(w: i32, h: i32) -> i32 {
            return w * h
        }
    }

    priv fn hidden() -> i32 {
        return 0
    }
}

fn main() -> i32 {
    var acct = Account(1)
    acct.deposit(41)
    return acct.total() - 42 + shapes::area(0, 3)
}

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo %s --type-check-only --verify-ast-roundtrip
// RUN: %kairo %s --syntax-only --print-ast=tree --print-symbols > %t.parsed
// RUN: %kairo %s --syntax-only --print-ast=tree --print-symbols --ast-roundtrip > %t.reloaded
// RUN: diff %t.parsed %t.reloaded
// RUN: %FileCheck %s < %t.reloaded
// CHECK: VisibilityGroupDecl
// CHECK: scope <tu>::Account  (7 names, frozen)
// RUN: { %kairo %s --type-check-only --ast-roundtrip 2>&1 || true; } | %FileCheck %s --check-prefix=CLEAN --allow-empty
// CLEAN-NOT: {{error|fatal}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s --ast-roundtrip -o %t.exe --cache-dir %t.d
// RUN: %t.exe
