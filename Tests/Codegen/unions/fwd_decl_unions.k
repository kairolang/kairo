// A union forward-declared, named through a pointer by a struct, then
// defined: the forward declaration must emit as `union Payload;` so the
// pointer field compiles before the definition.
//
// XFAIL: *
// Waiting on: a bodiless `union U` (and `struct S`) outside `ffi` is S048E
// "expected '{' to begin the type body"; only `class C` may be forward-declared
// today (TICKETS: "A union or struct cannot be forward-declared"). Replace
// the XFAIL with the run check below when it parses.
union Payload    // forward declaration

struct Message {
    var kind: u8
    var data: unsafe *Payload
}

union Payload {
    var as_int: i64
    var as_bytes: [u8; 8]
}

fn main() -> i32 {
    var p = Payload{as_int: 7}
    var m = Message{kind: 1, data: &p}
    return (m.data->as_int as i32) + (m.kind as i32)
}

// --- lit wiring ---
// RUN: rm -rf %t.exec.d
// RUN: %kairo %s -o %t.exec.exe --cache-dir %t.exec.d
// RUN: %t.exec.exe; test $? -eq 8
