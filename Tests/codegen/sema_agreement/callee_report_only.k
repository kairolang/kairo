// Disagreements the pass reports and does not repair, because pointing the
// call at Kairo's declaration would change more than the callee
// (--test-sema-agreement-swap, see callee_free_repair.k):
//   - the two declarations have different types: the argument conversions
//     clang computed are for its own choice;
//   - the two are of different kinds: a constructor and a free function, a
//     method and a free function.
// The compile goes on and clang's choice runs.

import std::io::println

fn narrow(x: i32) -> i32 { return 1 }
fn wide(x: i64) -> i32 { return 2 }
fn free_fn(x: i32) -> i32 { return 3 }

class Box {
    var v: i32 = 0
    fn Box(self, v: i32) { self.v = v }
    fn get(self) -> i32 { return self.v }
}

fn main() -> i32 {
    var b = Box(5)
    println(f"{narrow(1)} {b.get()}")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo_bin %s -fsema-agreement -o %t.exe --cache-dir %t.d --test-sema-agreement-swap=narrow:wide 2>&1 | %FileCheck %s --check-prefix=TYPES
// TYPES: [I012W] internal: clang resolved this call to '{{.*}}narrow(int)', but Kairo's Sema chose 'wide'
// TYPES: left as clang resolved it: the two declarations have different types, so the argument conversions would change
// RUN: %t.exe | %FileCheck %s --check-prefix=OUT --match-full-lines

// RUN: rm -rf %t.d
// RUN: %kairo_bin %s -fsema-agreement -o %t.exe --cache-dir %t.d --test-sema-agreement-swap=Box:free_fn 2>&1 | %FileCheck %s --check-prefix=CTOR
// CTOR: [I012W] internal: clang resolved this call to '{{.*}}Box::Box(int)', but Kairo's Sema chose 'free_fn'
// CTOR: left as clang resolved it: the two declarations are of different kinds
// RUN: %t.exe | %FileCheck %s --check-prefix=OUT --match-full-lines

// RUN: rm -rf %t.d
// RUN: %kairo_bin %s -fsema-agreement -o %t.exe --cache-dir %t.d --test-sema-agreement-swap=get:free_fn 2>&1 | %FileCheck %s --check-prefix=METHOD
// METHOD: [I012W] internal: clang resolved this call to '{{.*}}Box::get()', but Kairo's Sema chose 'free_fn'
// METHOD: left as clang resolved it: the two declarations are of different kinds
// RUN: %t.exe | %FileCheck %s --check-prefix=OUT --match-full-lines

// OUT: 1 5
