// A specialization declared after its primary template is accepted, and its
// uses (before or after the declaration) report nothing.

class <T> Box<T> {
    var v: i32 = 0
}

class <> Box<bool> {
    var v: bool = true
}

fn early() {
    var a: Box<bool>
    var b: Box<i32>
}

fn late() {
    var c: Box<bool>
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [" --implicit-check-not="note [" --allow-empty
