// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
//
// G55: a stand-in with a by-value field of an imported instance segfaulted
// the type-check inside clang (Sema::LookupSpecialMember). CS's stand-in
// got its `vector<unsafe *E>` field from template_id, which only DECLARES
// the specialization, so CS was a completed record around an incomplete
// subobject. `pair<u64, CS>` asks whether CS is copy-assignable; declaring
// CS's implicit copy assignment walked into the vector's missing
// definition. Reachable once a derived class (E) has a stand-in (G43).
// A by-value class field is now completed first, and a pointer names its
// pointee by a declaration only.

ffi "c++" import "vector";
ffi "c++" import "utility";
ffi "c++" import "unordered_map";

class Base { var b: i32 = 0 }
class E derives Base { var ctx: unsafe *Ctx = &null }
class Ctx { var m: cxx::std::unordered_map<u64, CS> }
class CS { var v: cxx::std::vector<unsafe *E> }

fn first(p: cxx::std::pair<u64, CS>) -> u64 { return p.first + (p.second.v.size() as u64) }
fn count(c: CS) -> usize { return c.v.size() }

// DIAG-NOT: error [
