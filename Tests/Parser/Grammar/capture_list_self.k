// `self` in a closure's capture list names the receiver. It was S047E
// "expected capture name or '*' in capture list". A closure already captures
// the receiver it uses, list or no list (ClosureCaptures, CaptureMode::
// Receiver), so naming it changes nothing for `self` -- but it is what lets
// a named list such as `|n, self|` be written, where every other name the
// body uses must be listed. `self` is a pointer: the capture is a pointer
// capture of the receiver, which Tether tracks as any other (closures.mdx,
// Tether and Lifetime Safety). Stage 1 has no escape analysis for closures,
// so a closure that outlives the receiver is not diagnosed yet.
// Self-host sites: Location/SourceManager.k, Driver/CompilerInstance.k.

class Counter {
    var n: i32

    fn bump(self) -> i32 {
        var step = 2
        var only_self = fn () |self| -> i32 { return self.n }
        var named = fn () |step, self| -> i32 { return self.n + step }
        var by_ptr = fn () |*step, self| -> i32 { return self.n + *step }
        return only_self() + named() + by_ptr()
    }
}

// 5 + 7 + 7: each closure read the receiver's field.
fn main() -> i32 {
    var c = Counter()
    c.n = 5
    return c.bump()
}

// --- lit wiring ---

// BEGIN-GENERATED-CHECKS(DIAG) mode=diag -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error [
// DIAG-NOT: warning [
// END-GENERATED-CHECKS(DIAG)

// BEGIN-GENERATED-CHECKS(EXEC) mode=run -- regenerate with Tests/gen_checks.py, do not hand-edit
// REQUIRES: clang
// RUN: rm -rf %t.exec.d
// RUN: %kairo %s -o %t.exec.exe --cache-dir %t.exec.d
// RUN: %t.exec.exe > %t.exec.out; test $? -eq 19
// RUN: test ! -s %t.exec.out
// END-GENERATED-CHECKS(EXEC)
