// A record with a private member befriends the functions of its file's
// `module` blocks by their qualified names (EmitPlan::file_friends). The
// friend line's declarator-id is parenthesized, `friend R (::ns::m::f)(...)`:
// written bare after a return type that ends in a name -- a nullable, a
// slice, `usize` -- the qualified name would lex as part of the return
// type's nested-name-specifier and the class would not compile. Each module
// function reads the private member, so the friendship is exercised too.

class Conn {
    priv var fd: i32 = 3
    fn Conn(self) { }
}

module bytes {
    fn digit(c: Conn, b: u8) -> i64? {
        if b >= 48 && b <= 57 {
            return (b - 48) as i64 + c.fd as i64
        }

        return null
    }

    fn until(c: Conn, s: [const u8;]) -> usize {
        return s.size() + c.fd as usize
    }

    fn head(c: Conn, s: [const u8;]) -> [const u8;] {
        return s[0..c.fd as usize]
    }

    fn same(c: Conn, a: i32) -> bool {
        return a == c.fd
    }
}

fn main() -> i32 {
    var c  = Conn()
    var d? = bytes::digit(c, 55)
    if d == null {
        return 1
    }

    var v: [u8] = [9, 8, 7, 6]
    if bytes::until(c, v) != 7 {
        return 2
    }

    if bytes::head(c, v).size() != 3 {
        return 3
    }

    if !bytes::same(c, 3) {
        return 4
    }

    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX: friend{{.*}}Null<signed long>{{ *}}({{ *}}::{{[a-z_]+}}::bytes::digit)(
// CXX: friend decltype(sizeof(0)){{ *}}({{ *}}::{{[a-z_]+}}::bytes::until)(
// CXX: friend{{.*}}Slice<const unsigned char>{{ *}}({{ *}}::{{[a-z_]+}}::bytes::head)(
// CXX: friend bool{{ *}}({{ *}}::{{[a-z_]+}}::bytes::same)(
// RUN: rm -rf %t.d
// RUN: rm -f %t.exe
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
