// The runtime ABI the emitter spells from LowerTargets (global_alloc_symbol,
// rt_crash_exit, oom_message, ABORT_EXIT_CODE) and what the runtime and the
// builtin define on their own: a drift check, since neither side can read
// the other. The names: every kairo_global_* symbol the forwarders and the
// C++ operators' helpers write, and the crash entry, are declared by
// Lib/rt/global_alloc.h / crash.h. The out-of-memory crash: the message,
// length and status the C++ operators' hook (`__kairo_cxx_got`, header
// text) passes are what Lib/builtin/alloc_raw.k's default_oom prints and
// exits with when `create` gets null from this file's allocator.
import builtin::base::alloc::*

class NullAlloc {
    static fn alloc(size: usize, align: usize) -> unsafe *u8 { return &null }
    static fn free(ptr: unsafe *u8, size: usize, align: usize) { }
    static fn resize(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> bool { return false }
    static fn realloc(ptr: unsafe *u8, o: usize, n: usize, align: usize) -> unsafe *u8 { return &null }
    static fn alloc_zeroed(size: usize, align: usize) -> unsafe *u8 { return &null }
}

@set_global_allocator(NullAlloc)

pub class Cell {
    var x: i64
    pub fn Cell(self, x: i64) { self.x = x }
}

fn main() -> i32 {
    var *c = create<Cell>(7i64)
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %kairo %s --type-check-only --emit-headers %t.d/h
// RUN: { %kairo %s --print-ir 2>&1 || true; } > %t.d/own.ir
// RUN: cat %t.d/own.ir %t.d/h/runtime_abi_sync.hh | grep -o 'kairo_global_[a-z_]*(' | sort -u > %t.d/names
// RUN: test "$(wc -l < %t.d/names)" -eq 5
// RUN: while read -r n; do grep -qF "$n" %S/../../../Lib/rt/global_alloc.h || { echo "runtime lacks $n"; exit 1; }; done < %t.d/names
// RUN: grep -q 'kairo_rt_crash_exit(' %t.d/h/runtime_abi_sync.hh
// RUN: grep -q 'kairo_rt_crash_exit(' %S/../../../Lib/rt/crash.h
// RUN: grep -o 'kairo_rt_crash_exit(reinterpret_cast<const unsigned char\*>("[^"]*"), [0-9]*, [0-9]*)' %t.d/h/runtime_abi_sync.hh | head -n 1 | sed -E 's/.*\("([^"]*)"\), ([0-9]+), ([0-9]+)\)/\1\n\2\n\3/' > %t.d/hook
// RUN: test "$(wc -l < %t.d/hook)" -eq 3
// RUN: test "$(sed -n 1p %t.d/hook | tr -d '\n' | wc -c)" -eq "$(sed -n 2p %t.d/hook)"
// RUN: %kairo %s -o %t.exe --cache-dir %t.d/c
// RUN: { %t.exe 2> %t.d/err; echo $? > %t.d/status; } || true
// RUN: test "$(cat %t.d/status)" -eq "$(sed -n 3p %t.d/hook)"
// RUN: grep -qxF "$(sed -n 1p %t.d/hook)" %t.d/err
