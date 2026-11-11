// RUN: %kairo %s --type-check-only -fimplicit-conv
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 21
// One C++ type reached as `nl::json`, as `api::detail::Json` and as a return
// type (an argument, an annotated local, a member of the result) is one
// Kairo type, although its template-template arguments make it opaque: the
// opaque is keyed by the type, not by the spelling it was reached through.
// It is one record, and it can be looked into.
ffi "c++" import "foreign_alias_identity.h"

fn main() -> i32 {
    var j = to_json("x", 1)
    var c = api::completion().create(j)
    var k: api::detail::Json = to_json("x", 1)
    return api::completion().create(j).dump() + c.dump() + k.dump()
}
