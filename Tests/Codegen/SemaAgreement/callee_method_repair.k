// A method call clang bound to another method of the same class, with the
// same type, than the one Kairo chose: I012W, and the call is pointed at
// Kairo's choice (--test-sema-agreement-swap, see callee_free_repair.k).

import std::io::println

class Box {
    var v: i32 = 0
    fn Box(self, v: i32) { self.v = v }
    fn get(self) -> i32 { return self.v }
    fn get_more(self) -> i32 { return self.v + 10 }
}

fn main() -> i32 {
    var b = Box(3)
    println(f"{b.get()}")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -fsema-agreement -o %t.exe --cache-dir %t.d --test-sema-agreement-swap=get:get_more 2>&1 | %FileCheck %s --check-prefix=WARN
// WARN: callee_method_repair.k:16:16: warning [I012W]: internal: clang resolved this call to '{{.*}}Box::get()', but Kairo's Sema chose 'get_more'
// WARN: callee_method_repair.k:11:8: note [I900N]: Kairo's Sema chose this declaration
// WARN: callee_method_repair.k:10:8: note [I900N]: clang resolved the call to this declaration
// WARN-NOT: error
// RUN: %t.exe | %FileCheck %s --check-prefix=FIXED --match-full-lines
// FIXED: 13

// RUN: rm -rf %t.d
// RUN: %kairo %s -fsema-agreement -o %t.exe --cache-dir %t.d --test-sema-agreement-swap=get:get_more -fno-sema-agreement-repair 2>&1 | %FileCheck %s --check-prefix=REPORT
// REPORT: warning [I012W]
// RUN: %t.exe | %FileCheck %s --check-prefix=LEFT --match-full-lines
// LEFT: 3
