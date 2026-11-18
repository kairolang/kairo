// XFAIL: *
// Defect (compiler): in a generic function, an f-string hole whose value has `repr()` or `op as` declared in an `extend`
// block prints the address form (`T @ 0x...`) at the instance, while the same value in a concrete hole prints its
// conversion (`ER2`, `EA3`). language/generics.mdx (f-strings in a generic body) says the hole is "formatted per
// instance, with the same rules as a concrete value (... `repr()`, an `op as` to `string`)"; the deferred formatter
// does not see conversions that live in an extension. A type with `repr()` in a class body, or `op as` in a struct
// body, formats correctly through the same generic function.
// Smallest reproducer: the three `show` calls below.

import std::io::*

var CODE: i32 = 0

fn ck(const got: string, const want: string, id: i32, const name: string) {
    if !(got == want) {
        println(f"FAIL {name}: got [{got}] want [{want}]")
        if CODE == 0 {
            CODE = id
        }
    }
}

struct ExtRepr {
    var n: i32
}

extend ExtRepr {
    fn repr(self) -> string { return f"ER{self.n}" }
}

struct ExtAs {
    var n: i32
}

extend ExtAs {
    fn op as(self) -> string { return f"EA{self.n}" }
}

struct BodyAsExtRepr {
    var n: i32
    fn op as(self) -> string { return "opas" }
}

extend BodyAsExtRepr {
    fn repr(self) -> string { return "repr" }
}

fn <T> show(x: T) -> string {
    return f"{x}"
}

fn main() -> i32 {
    var b = ExtRepr { n: 2 }
    var c = ExtAs { n: 3 }
    var d = BodyAsExtRepr { n: 1 }
    ck(f"{b}", "ER2", 1, "concrete extension repr")
    ck(f"{c}", "EA3", 1, "concrete extension op as")
    ck(f"{d}", "repr", 1, "concrete: repr is preferred to op as")
    ck(show(b), "ER2", 2, "generic extension repr")
    ck(show(c), "EA3", 3, "generic extension op as")
    ck(show(d), "repr", 4, "generic: repr is preferred to op as")
    if CODE == 0 {
        println("ok")
    }

    return CODE
}

// --- lit wiring ---
// REQUIRES: newlib
// RUN: rm -rf %t.d %t.exe
// RUN: %kairo_new %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s
// CHECK-NOT: FAIL
// CHECK: ok
