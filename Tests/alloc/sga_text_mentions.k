// The driver decides before parsing whether a program sets the global
// allocator, and with it whether every file is compiled with
// __KAIRO_GLOBAL_ALLOCATOR_SET. Only `@set_global_allocator(A)` written at
// file scope, where the parser takes it, counts. A block comment and a
// string literal holding the same text at the start of a line do not, so
// Global stays System inlined and nothing calls the kairo_global_* symbols.

/*
@set_global_allocator(Nothing)
*/

var NOTE: string = "a string literal over two lines
@set_global_allocator(Nothing)
"

fn main() -> i32 {
    var s: string = NOTE
    s += "!"
    return (s.size() as i32)
}

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo %s --print-ir -o %t.exe > %t.ir 2>&1
// RUN: not grep -q kairo_global_alloc %t.ir
// RUN: grep -q 'int main' %t.ir
