// A closure's `fn` value is built from the lambda's own function pointer, so
// the lambda's parameters are spelled as its `fn` type spells them
// (type-system.mdx, Function Types): `const` marks the parameter and is not
// part of the type. Covered: a `const` record, scalar, pointer and array
// parameter, `@inout` and `@move`, in a closure that captures nothing and in
// one that captures, stored, passed, returned, as a raw function pointer and
// inside a generic function; and a named function with a `const` array
// parameter as a `fn` value.

class Tag {
    pub var n: i32
    fn Tag(self, n: i32) { self.n = n }
}

fn call(f: fn(string) -> i32) -> i32 { return f("abc") }

fn make() -> fn(string) -> i32 {
    return fn (const s: string) -> i32 { return s.size() as i32 }
}

fn first(const xs: [i32; 3]) -> i32 { return xs[0] }

fn <T> pick(v: T) -> i32 {
    var f = fn (const s: T, n: i32) -> i32 { return n }
    return f(v, 2)
}

fn main() -> i32 {
    var f = fn (const s: string, b: bool) -> i32 { return if b => (s.size() as i32) else => 0 }
    if f("xy", true) != 2 { return 1 }

    var k = 10
    var g = fn (const s: string) -> i32 { return (s.size() as i32) + k }
    if g("xyz") != 13 { return 2 }

    if call(fn (const s: string) -> i32 { return (s.size() as i32) * 2 }) != 6 { return 3 }
    if make()("abcd") != 4 { return 4 }

    var raw: unsafe fn(string) -> i32 = fn (const s: string) -> i32 { return s.size() as i32 }
    if raw("q") != 1 { return 5 }

    // Every form at once. `const q: *string` is a const pointer to a string
    // the closure may still write.
    var a: string = "a"
    var b: string = "bb"
    var c: string = "ccc"
    var m = fn (@inout s: string, @move t: string, p: *string, const q: *string, const n: i32, const u: string) -> i32 {
        s = t
        *q = "zz"
        return (p->size() as i32) + n + (u.size() as i32)
    }
    if m(&a, b, &c, &c, 1, "uuuu") != 7 { return 6 }
    if a.size() != 2 || c.size() != 2 { return 7 }

    var z = 4
    var sc = fn (const n: i32, const p: *i32) -> i32 { return n + *p }
    if sc(1, &z) != 5 { return 8 }

    var t = fn (const t: Tag) -> i32 { return t.n }
    if t(Tag(9)) != 9 { return 9 }

    var arr: [i32; 3] = [7, 8, 9]
    var h = fn (const xs: [i32; 3]) -> i32 { return xs[1] }
    if h(arr) != 8 { return 10 }
    var w = fn (@inout xs: [i32; 3]) -> i32 { xs[2] = 1; return xs[2] }
    if w(&arr) != 1 || arr[2] != 1 { return 11 }
    var nf = first
    if nf(arr) != 7 { return 12 }

    if pick(a) != 2 || pick(3) != 2 { return 13 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// The lambda takes the record by value, as `fn(string, bool) -> i32` does,
// and a const pointer parameter keeps its pointee writable.
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=IR
// IR-LABEL: CODEGEN C++: {{.*}}const_param_run.k
// IR:     +{{ ?}}[{{ ?}}]{{ ?}}({{ ?}}const{{ ?}}::builtin::string::string s{{ ?}},{{ ?}}bool b{{ ?}})
// IR:     ::builtin::string::string{{ ?}}*{{ ?}}const q
// IR:     ({{ ?}}const signed int{{ ?}}({{ ?}}&{{ ?}}xs{{ ?}}){{\[}}3{{\]}}{{ ?}})
// IR-NOT: const{{ ?}}::builtin::string::string{{ ?}}&{{ ?}}s{{[,)]}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
