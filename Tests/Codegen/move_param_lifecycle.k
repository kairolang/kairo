// move_param_lifecycle.k -- stdout
// A move-only class end to end: a user `@move` transfer constructor that
// leaves its source a recognizable shell, an `op delete` that reports which
// it destroys, a `var b = a` transfer, and the object passed on to a `@move`
// parameter. Each destructor must run exactly once per object: one live
// token, one moved-from shell, never a live token twice.
//
// The destruction ORDER is not pinned. `@move` lowers to `T&&`, so today
// the callee only borrows the rvalue and t2 dies at the end of main, after
// every line main prints. Whether a consumed `@move` argument should die
// at the callee's exit instead is open (Spec/Docs/functions-parameter-
// modes.md says the call consumes it, not where it dies), so the DTOR
// checks are order-free and checked apart from the program's own lines.
import std::io::println

pub class UniqueToken {
    pub var id: i32

    pub fn UniqueToken(self, id: i32) {
        self.id = id
    }

    @move
    pub fn UniqueToken(self, other: Self) {
        self.id = other.id
        other.id = -1
    }

    fn op delete(self) {
        if self.id != -1 {
            println(f"[dtor] live #{self.id}")
        } else {
            println("[dtor] shell")
        }
    }
}

fn consume_token(@move tok: UniqueToken) -> i32 {
    println(f"[consume] #{tok.id}")
    return tok.id * 10
}

fn main() -> i32 {
    var t1 = UniqueToken(7)
    var t2 = t1                    // the transfer: t1 is the shell now
    var score = consume_token(t2)
    println(f"[main] score = {score}")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe > %t.out
// RUN: %FileCheck %s --check-prefix=OUT < %t.out
// RUN: %FileCheck %s --check-prefix=DTOR < %t.out
// OUT-NOT: [dtor]
// OUT: [consume] #7
// OUT: [main] score = 70
// DTOR-DAG: [dtor] live #7
// DTOR-DAG: [dtor] shell
// DTOR-NOT: [dtor]
