// The self-hosting site, reduced (Compiler/Threading/ThreadPool.k, warmup):
// a method declares a local `fn` that takes a pointer to the method's own
// local, and a closure names that function in its capture list beside the
// pointer and a value. The local `fn` captures nothing (it gets the pointer
// as a parameter); the closure captures the function value by copy.

class Pool {
    pub var count: i32 = 3

    fn warmup(self, spins: i32) -> i32 {
        var hits: i32 = 0

        fn heat_task(counter: *i32, rounds: i32) {
            var x: i64 = 1
            for var j: i32 = 0; j < rounds; ++j {
                x = (x * 3 + (j as i64)) % 7919
            }
            (*counter) += 1
        }

        for var i: i32 = 0; i < self.count; ++i {
            var task = fn () |heat_task, *hits, spins| {
                heat_task(hits, spins)
            }
            task()
        }
        return hits
    }
}

fn main() -> i32 {
    var p = Pool()
    return p.warmup(100)                            // 3
}

// --- lit wiring -----------------------------------------------------------

// BEGIN-GENERATED-CHECKS(DIAG) mode=diag -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error [
// DIAG-NOT: warning [
// END-GENERATED-CHECKS(DIAG)

// BEGIN-GENERATED-CHECKS(EXEC) mode=run -- regenerate with Tests/gen_checks.py, do not hand-edit
// REQUIRES: clang
// RUN: rm -rf %t.exec.d
// RUN: %kairo %s -o %t.exec.exe --cache-dir %t.exec.d
// RUN: %t.exec.exe > %t.exec.out; test $? -eq 3
// RUN: test ! -s %t.exec.out
// END-GENERATED-CHECKS(EXEC)
