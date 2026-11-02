// Kairo function-pointer types are noexcept in C++: every Kairo function is,
// so a call through one is a plain call, not an invoke whose landing pad
// calls __clang_call_terminate. A raw `unsafe fn` is `__kairo_raw_fn<R(A...)
// noexcept>`; a `fn` value's plain pointer is `R (*)(A...) noexcept`. A call
// through either kind typed `-> !` is followed by __builtin_unreachable().

static halt: unsafe fn(i32) -> ! = stop

fn stop(code: i32) -> ! {
    loop { }
}

@no_inline fn through_raw(f: unsafe fn(usize) -> usize, n: usize) -> usize {
    unsafe { return f(n) }
}

@no_inline fn never_raw(code: i32) -> ! {
    unsafe { halt(code) }
}

fn twice(n: usize) -> usize { return n * 2 }

fn main() -> i32 { return through_raw(twice, 21) as i32 - 42 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX: using __ptr = R(*)(A ...) noexcept;
// CXX: ::__kairo_raw_fn<void(signed int) noexcept> halt
// CXX: through_raw( ::__kairo_raw_fn<decltype(sizeof(0))(decltype(sizeof(0))) noexcept> f
// CXX: void never_raw(signed int code) noexcept {
// CXX: ( ::{{.*}}::halt(code), __builtin_unreachable());
// REQUIRES: clang, llvm-objdump
// RUN: rm -rf %t.d
// RUN: %kairo %s --target=x86_64-linux-musl -O2 -o %t.exe --cache-dir %t.d
// RUN: %t.exe
// RUN: %objdump -d --no-show-raw-insn %t.exe | awk '/through_raw.*>:/,/^$/' > %t.asm
// RUN: %FileCheck %s --check-prefix=ASM < %t.asm
// ASM: through_raw
// ASM-NOT: __clang_call_terminate
// ASM: jmpq *%rax
// ASM-NOT: __clang_call_terminate
