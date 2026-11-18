// Nullable pointers against nullable values: `*T` is non-null, `*T?` is
// `(*T)?` (a nullable pointer), `*(T?)` is a pointer to a nullable, and an
// `unsafe *T` alone holds `&null`. A nullable pointer narrows like any
// nullable local; its use needs the check, `?->` and `??` need none
// (nullables.mdx, Pointers and nullability; casting.mdx, Checked downcast).
// Cases from Kotlin compiler/testData/diagnostics/tests/smartCasts/
// (varnotnull/ifVarNotNull, safecalls/receiver, nullabilityAndSmartCasts/
// ReceiverNullability) with pointer receivers.

class Animal { pub virtual fn name(self) -> i32 { return 1 } pub fn Animal(self) { } }
class Dog derives Animal { pub fn fetch(self) -> i32 { return 2 } pub fn Dog(self) { } }
class Node { pub var v: i32 = 1; pub var next: (*Node)? = null; pub fn Node(self) { } }

fn lookup(k: i32) -> (*Node)? { return null }
fn take(p: *Node) -> i32 { return p->v }

fn ok_safe_pointer_needs_no_check(p: *Node) -> i32 {
    return p->v + take(p)
}

fn ok_checked_pointer(p: (*Node)?) -> i32 {
    if p? { return p->v }
    return 0
}

fn ok_early_exit_pointer(p: (*Node)?) -> i32 {
    if p == null { return 0 }
    return take(p)
}

fn bad_unchecked_pointer_member(p: (*Node)?) -> i32 {
    return p->v // expect: SC265E
}

fn bad_unchecked_pointer_deref(p: (*Node)?) -> i32 {
    var q = *p // expect: SC265E
    return 0
}

fn bad_unchecked_pointer_argument(p: (*Node)?) -> i32 {
    return take(p) // expect: SC265E
}

fn ok_pointer_to_nullable_param(p: (*Node)?) -> i32 {
    return if p? => take(p) else => 0
}

fn ok_pointer_coalesce(p: (*Node)?, d: *Node) -> i32 {
    var *r = p ?? d
    return r->v
}

fn ok_safe_arrow(p: (*Node)?) -> i32 {
    var v? = p?->v
    return v ?? -1
}

fn ok_safe_arrow_chain(p: (*Node)?) -> i32 {
    return p?->next?->v ?? -1
}

fn bad_safe_arrow_on_safe_pointer(p: *Node) -> i32 {
    return p?->v ?? 0 // expect: SC260E
}

fn ok_walk_list(head: (*Node)?) -> i32 {
    var r = 0
    var *n? = head
    while n? {
        r += n->v
        n = n->next
    }
    return r
}

fn bad_walk_list_reads_next_unchecked(head: *Node) -> i32 {
    return head->next->v // expect: SC265E
}

fn ok_walk_list_copy_next(head: *Node) -> i32 {
    var *n? = head->next
    if n? { return n->v }
    return 0
}

fn bad_address_null_to_safe_pointer() {
    var p: *Node = &null // expect: SC259E
}

fn ok_nullable_pointer_null() -> bool {
    var p: (*Node)? = null
    return p == null
}

fn ok_unsafe_pointer_null() -> bool {
    var raw: unsafe *i32 = &null
    return raw == &null
}

fn ok_unsafe_pointer_checked_by_hand(raw: unsafe *i32) -> i32 {
    if raw != &null { return *raw }
    return 0
}

fn ok_address_of_local_is_nonnull() -> i32 {
    var k = 3
    var p: (*i32)? = &k
    return *p
}

fn ok_checked_downcast(a: *Animal) -> i32 {
    var *d? = a as *Dog?
    if d? { return d->fetch() }
    return 0
}

fn bad_checked_downcast_unchecked(a: *Animal) -> i32 {
    var *d? = a as *Dog?
    return d->fetch() // expect: SC265E
}

fn ok_checked_downcast_early_exit(a: *Animal) -> i32 {
    var *d? = a as *Dog?
    if !d? { return 0 }
    return d->fetch()
}

fn ok_pointer_to_nullable_value_deref_check(p: *(i32?)) -> bool {
    var v? = *p
    return v?
}

fn bad_pointer_to_nullable_value_unchecked(p: *(i32?)) -> i32 {
    var v? = *p
    return v + 1 // expect: SC265E
}

fn ok_pointer_assign_through(p: *(i32?)) {
    *p = 5
    *p = null
}

fn ok_nullable_pointer_reassigned_address(q: (*Node)?, n: *Node) -> i32 {
    var *p? = q
    p = n
    return p->v
}

fn bad_nullable_pointer_reassigned_call(q: (*Node)?, n: *Node) -> i32 {
    var *p? = n
    p = lookup(1)
    return p->v // expect: SC265E
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only --cmax-errors=0 2>&1 || true; } | %FileCheck %s --implicit-check-not='error [' --implicit-check-not='warning ['
// CHECK: pointers.k:32:{{[0-9]+}}: error [SC265E]
// CHECK: pointers.k:36:{{[0-9]+}}: error [SC265E]
// CHECK: pointers.k:41:{{[0-9]+}}: error [SC265E]
// CHECK: pointers.k:63:{{[0-9]+}}: error [SC260E]
// CHECK: pointers.k:77:{{[0-9]+}}: error [SC265E]
// CHECK: pointers.k:87:{{[0-9]+}}: error [SC259E]
// CHECK: pointers.k:119:{{[0-9]+}}: error [SC265E]
// CHECK: pointers.k:135:{{[0-9]+}}: error [SC265E]
// CHECK: pointers.k:152:{{[0-9]+}}: error [SC265E]
