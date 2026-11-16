// A TU the Sema agreement pass has a finding in is stored in the object
// cache with its findings, and the build that reuses the object says them
// again: the same text at the same places, once.
//
// The hidden --test-sema-agreement-swap=chosen:other tells the pass that
// Kairo bound every call of `chosen` to `other`.

import std::io::println

fn chosen(x: i32) -> i32 { return x + 1 }
fn other(x: i32) -> i32 { return x + 100 }

fn main() -> i32 {
    println(f"{chosen(1)}")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
//
// Cold, then warm: the second build compiles nothing and says the same.
// RUN: rm -rf %t.d
// RUN: %kairo %s -v -fsema-agreement -o %t.exe --cache-dir %t.d --test-sema-agreement-swap=chosen:other 2>&1 | %FileCheck %s --check-prefix=COLD
// COLD: incremental: compiling {{.*}}cache_replay{{.*}} (not cached)
// COLD: cache_replay.k:14:16: warning [I012W]: internal: clang resolved this call to '{{.*}}chosen(int)', but Kairo's Sema chose 'other'; this is a compiler bug
// RUN: %kairo %s -v -fsema-agreement -o %t.exe --cache-dir %t.d --test-sema-agreement-swap=chosen:other 2>&1 | %FileCheck %s --check-prefix=WARM
// WARM-NOT: incremental: compiling {{.*}}cache_replay
// WARM: incremental: reused {{.*}}cache_replay
// WARM-NOT: incremental: compiling {{.*}}cache_replay
// WARM: cache_replay.k:14:16: warning [I012W]: internal: clang resolved this call to '{{.*}}chosen(int)', but Kairo's Sema chose 'other'; this is a compiler bug
// WARM-NEXT: cache_replay.k:11:4: note [I900N]: Kairo's Sema chose this declaration
// WARM-NEXT: cache_replay.k:10:4: note [I900N]: clang resolved the call to this declaration
// WARM-NOT: I012W
// RUN: %t.exe | %FileCheck %s --check-prefix=FIXED --match-full-lines
// FIXED: 101
//
// Byte for byte, in the one-line form and in the rendered one.
// RUN: rm -rf %t.d
// RUN: %kairo %s -fsema-agreement -o %t.exe --cache-dir %t.d --test-sema-agreement-swap=chosen:other 2> %t.cold
// RUN: %kairo %s -fsema-agreement -o %t.exe --cache-dir %t.d --test-sema-agreement-swap=chosen:other 2> %t.warm
// RUN: grep -c I012W %t.cold | %FileCheck %s --check-prefix=ONCE
// RUN: diff %t.cold %t.warm
// RUN: %kairo_bin %s -fsema-agreement -o %t.exe --cache-dir %t.d --test-sema-agreement-swap=chosen:other --force-recompile 2> %t.pcold
// RUN: %kairo_bin %s -fsema-agreement -o %t.exe --cache-dir %t.d --test-sema-agreement-swap=chosen:other 2> %t.pwarm
// RUN: grep -c "the call now goes to the declaration Kairo chose" %t.pwarm | %FileCheck %s --check-prefix=ONCE
// RUN: diff %t.pcold %t.pwarm
// ONCE: {{^1$}}
//
// A run that only counts stores the findings too, and a run that reports
// says them from that object.
// RUN: rm -rf %t.d
// RUN: %kairo %s -v --test-sema-agreement-quiet -o %t.exe --cache-dir %t.d --test-sema-agreement-swap=chosen:other 2>&1 | %FileCheck %s --check-prefix=QUIET
// QUIET-NOT: I012W
// RUN: %kairo %s -v -fsema-agreement -o %t.exe --cache-dir %t.d --test-sema-agreement-swap=chosen:other 2>&1 | %FileCheck %s --check-prefix=WARM
// RUN: %kairo %s -v --test-sema-agreement-quiet -o %t.exe --cache-dir %t.d --test-sema-agreement-swap=chosen:other 2>&1 | %FileCheck %s --check-prefix=QWARM
// QWARM-NOT: I012W
// QWARM: incremental: reused {{.*}}cache_replay
// QWARM-NOT: I012W
//
// An object whose findings are gone is not served: it would pass for one
// the walk had nothing to say about.
// RUN: rm %t.d/kairo-cache-v*/*/objects/*.agree
// RUN: %kairo %s -v -fsema-agreement -o %t.exe --cache-dir %t.d --test-sema-agreement-swap=chosen:other 2>&1 | %FileCheck %s --check-prefix=LOST
// LOST: incremental: compiling {{.*}}cache_replay
// LOST: cache_replay.k:14:16: warning [I012W]
// RUN: %kairo %s -v -fsema-agreement -o %t.exe --cache-dir %t.d --test-sema-agreement-swap=chosen:other 2>&1 | %FileCheck %s --check-prefix=WARM
//
// The findings are placed in the bytes of the files they name. A comment
// above the code moves the call and leaves the stream as it was: the TU
// compiles, and the warning is at the call's line.
// RUN: rm -rf %t.d %t.src && mkdir -p %t.src
// RUN: cp %s %t.src/cache_replay.k
// RUN: %kairo %t.src/cache_replay.k -fsema-agreement -o %t.exe --cache-dir %t.d --test-sema-agreement-swap=chosen:other 2>&1 | %FileCheck %s --check-prefix=LINE14
// LINE14: cache_replay.k:14:16: warning [I012W]
// RUN: (echo "// one line more"; cat %s) > %t.src/cache_replay.k
// RUN: %kairo %t.src/cache_replay.k -v -fsema-agreement -o %t.exe --cache-dir %t.d --test-sema-agreement-swap=chosen:other 2>&1 | %FileCheck %s --check-prefix=MOVED
// MOVED-NOT: cache_replay.k:14:16: warning
// MOVED: incremental: compiling {{.*}}cache_replay (changed: nothing in the object, but a file its Sema agreement findings point into)
// MOVED: cache_replay.k:15:16: warning [I012W]
// MOVED-NEXT: cache_replay.k:12:4: note [I900N]: Kairo's Sema chose this declaration
// MOVED-NEXT: cache_replay.k:11:4: note [I900N]: clang resolved the call to this declaration
// MOVED-NOT: I012W
// RUN: %kairo %t.src/cache_replay.k -v -fsema-agreement -o %t.exe --cache-dir %t.d --test-sema-agreement-swap=chosen:other 2>&1 | %FileCheck %s --check-prefix=MOVEDW
// MOVEDW: incremental: reused {{.*}}cache_replay
// MOVEDW: cache_replay.k:15:16: warning [I012W]
//
// What the pass was told, and whether it repairs, are in the object's key:
// a build without the hook has no finding and runs clang's choice.
// RUN: rm -rf %t.d
// RUN: %kairo %s -fsema-agreement -o %t.exe --cache-dir %t.d 2>&1 | %FileCheck %s --check-prefix=NONE --allow-empty
// NONE-NOT: I012W
// RUN: %kairo %s -fsema-agreement -o %t.exe --cache-dir %t.d --test-sema-agreement-swap=chosen:other 2>&1 | %FileCheck %s --check-prefix=HOOK
// HOOK: cache_replay.k:14:16: warning [I012W]
// RUN: %t.exe | %FileCheck %s --check-prefix=FIXED --match-full-lines
// RUN: %kairo %s -fsema-agreement -o %t.exe --cache-dir %t.d 2>&1 | %FileCheck %s --check-prefix=NONE --allow-empty
// RUN: %t.exe | %FileCheck %s --check-prefix=LEFT --match-full-lines
// LEFT: 2
// RUN: %kairo %s --test-sema-agreement-quiet -o %t.exe --cache-dir %t.d --test-sema-agreement-swap=chosen:other -fno-sema-agreement-repair 2>&1 | %FileCheck %s --check-prefix=NONE --allow-empty
// RUN: %t.exe | %FileCheck %s --check-prefix=LEFT --match-full-lines
//
// -fno-sema-agreement neither says a stored finding nor leaves an object
// a walking build would take for a clean one.
// RUN: %kairo %s -fno-sema-agreement -o %t.exe --cache-dir %t.d --test-sema-agreement-swap=chosen:other 2>&1 | %FileCheck %s --check-prefix=NONE --allow-empty
// RUN: rm -rf %t.d
// RUN: %kairo %s -fno-sema-agreement -o %t.exe --cache-dir %t.d --test-sema-agreement-swap=chosen:other 2>&1 | %FileCheck %s --check-prefix=NONE --allow-empty
// RUN: %kairo %s -fsema-agreement -o %t.exe --cache-dir %t.d --test-sema-agreement-swap=chosen:other 2>&1 | %FileCheck %s --check-prefix=HOOK
