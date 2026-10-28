// The member types a `vector<*Node?>` fill reads back are the Kairo
// nullable, so the nullable rules apply to them: a `string` is not an
// element, an element is not a `*Node` until it is checked, and `var *p? =
// v[0]` -- the shorthand over a C++ reference -- is the element's own
// `*Node?`, which still needs its check before `->`. The candidate notes
// spell the parameter as `const *Node?&`, not as the C++ record
// `Nullable<Node*>`. One function per case: a function reports its first
// maybe-null use only.

ffi "c++" import "vector"

class Node {
    pub var id: i32
    fn Node(self, id: i32) { self.id = id }
}

fn take(p: *Node) -> i32 { return p->id }

fn wrong_element(v: cxx::std::vector<*Node?>) {
    v.push_back("no")
}

fn unchecked_element(v: cxx::std::vector<*Node?>) -> i32 {
    return take(v[0])
}

fn unchecked_local(v: cxx::std::vector<*Node?>) -> i32 {
    var *p? = v[0]
    return p->id
}

fn unchecked_int(v: cxx::std::vector<i32?>) -> i32 {
    var x? = v.back()
    return x + 1
}

fn main() -> i32 {
    var a = Node(3)
    var v: cxx::std::vector<*Node?>
    v.push_back(&a)
    return unchecked_element(v) + unchecked_local(v)
}

// --- lit wiring -----------------------------------------------------------

// BEGIN-GENERATED-CHECKS(DIAG) mode=diag -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// DIAG: {{.*}}:20:5: error [SC063E]: no matching overload for call to 'push_back'
// DIAG-NEXT: {{.*}}/vector.h:462:3: note [I900N]: candidate not viable: cannot convert argument of type 'string' to parameter '__x' of type 'const *Node?&'
// DIAG-NEXT: {{.*}}/vector.h:464:3: note [I900N]: candidate not viable: cannot convert argument of type 'string' to parameter '__x' of type '*Node?&&'
// DIAG: {{.*}}:24:12: error [SC063E]: no matching overload for call to 'take'
// DIAG-NEXT: {{.*}}:17:1: note [I900N]: candidate not viable: cannot convert argument of type '*Node?&' to parameter 'p' of type '*Node'
// DIAG: {{.*}}:29:12: error [SC001E]: 'p' may be null here; check it with 'if p?' first
// DIAG-NEXT: {{.*}}:28:5: note [I900N]: 'p' is given a value that may be null here
// DIAG: {{.*}}:34:12: error [SC001E]: 'x' may be null here; check it with 'if x?' first
// DIAG-NEXT: {{.*}}:33:5: note [I900N]: 'x' is given a value that may be null here
// END-GENERATED-CHECKS(DIAG)
