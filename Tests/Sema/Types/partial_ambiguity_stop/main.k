// A once-per-build report goes to the first file in the one-thread order,
// at any thread count, and stops that file's Sema after T, as a T error
// does.
//
// The eight user files import pair.k and not each other, so their Sema
// fronts run side by side, and each names the ambiguous Pair<i32, i32>
// and has a typed-check error of its own in the body. The front that took
// the SC157E latch first reported it and stopped after T, so which file
// reported, and whose body error went missing, followed pool timing. A
// front records the mention and stops after T; the driver claims it
// at the group's turn (FrontendAction::_settle_once): user0 reports and
// stops, user1 .. user7 report their body errors, on every run.

import self::user0::*
import self::user1::*
import self::user2::*
import self::user3::*
import self::user4::*
import self::user5::*
import self::user6::*
import self::user7::*

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only --threads=1 2>&1 || true; } > %t.one
// RUN: { %kairo %s --type-check-only --threads=16 2>&1 || true; } > %t.p1
// RUN: { %kairo %s --type-check-only --threads=16 2>&1 || true; } > %t.p2
// RUN: { %kairo %s --type-check-only --threads=16 2>&1 || true; } > %t.p3
// RUN: { %kairo %s --type-check-only --threads=16 2>&1 || true; } > %t.p4
// RUN: { %kairo %s --type-check-only --threads=16 2>&1 || true; } > %t.p5
// RUN: { %kairo %s --type-check-only --threads=16 2>&1 || true; } > %t.p6
// RUN: { %kairo %s --type-check-only 2>&1 || true; } > %t.d
// RUN: diff %t.one %t.p1
// RUN: diff %t.one %t.p2
// RUN: diff %t.one %t.p3
// RUN: diff %t.one %t.p4
// RUN: diff %t.one %t.p5
// RUN: diff %t.one %t.p6
// RUN: diff %t.one %t.d
// RUN: %FileCheck %s < %t.one --implicit-check-not=error
// CHECK: user0.k:6:16: error [SC157E]: ambiguous partial specializations of 'Pair' for these arguments
// CHECK-DAG: user1.k:7:22: error [SC028E]
// CHECK-DAG: user2.k:7:22: error [SC028E]
// CHECK-DAG: user3.k:7:22: error [SC028E]
// CHECK-DAG: user4.k:7:22: error [SC028E]
// CHECK-DAG: user5.k:7:22: error [SC028E]
// CHECK-DAG: user6.k:7:22: error [SC028E]
// CHECK-DAG: user7.k:7:22: error [SC028E]
