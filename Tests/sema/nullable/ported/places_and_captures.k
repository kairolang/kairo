// Which nullable places a check narrows, and what ends the check: locals and
// field paths narrow (`a.b.c`), a nullable reached through `->`, a subscript
// or a call result does not; a mutable-self call, an `@inout` argument, a
// write through a pointer and, for a global, any call end a check; closures
// capture a copy in the state the variable had when the closure was made,
// and a pointer capture sees `*x` as maybe null (nullables.mdx, Narrowing,
// "What makes it maybe null again", "Closures and stored pointers",
// "Globals and statics").
// Cases from Kotlin compiler/testData/diagnostics/tests/smartCasts/
// (varnotnull/capturedInClosureModifiedBefore, varCapturedInClosure,
// lambdaDeclaresAndModifies, lambdaUsesOwnerModifies, localFunChanges,
// publicVals, propertyToNotNull, fieldExclExcl, noErrorCheckForPackageLevelVal,
// accessToMemberAfterReceiverReassignment, smartcastOnSameFieldOfDifferentInstances).

class Node { pub var value: i32 = 1 }
class Holder {
    pub var cache: Node? = null
    pub var n: i32? = null
    pub fn Holder(self) { }
    pub fn reset(self) { self.cache = null }
    pub fn peek(const self) -> i32 { return 1 }
}
struct Pair2 { pub var left: Holder = Holder(); pub var right: Holder = Holder() }

static current: Node? = null
var counter: i32? = 4

fn make() -> Node? { return Node() }
fn noop() { }
fn bump(@inout x: i32?) { x = null }
fn take(x: i32) -> i32 { return x }

// local, field, nested field path

fn ok_local(x: Node?) -> i32 {
    if x? { return x.value }
    return 0
}

fn ok_field_of_param(h: Holder) -> i32 {
    if h.cache? { return h.cache.value }
    return 0
}

fn ok_field_of_local() -> i32 {
    var h = Holder()
    if h.n? { return h.n + 1 }
    return 0
}

fn ok_nested_field_path(p: Pair2) -> i32 {
    if p.left.cache? { return p.left.cache.value }
    return 0
}

fn bad_sibling_field_not_narrowed(h: Holder) -> i32 {
    if h.cache? { return h.n + 1 } // expect: SC265E
    return 0
}

fn bad_other_instance_not_narrowed(a: Holder, b: Holder) -> i32 {
    if a.cache? { return b.cache.value } // expect: SC265E
    return 0
}

fn bad_sibling_path_not_narrowed(p: Pair2) -> i32 {
    if p.left.cache? { return p.right.cache.value } // expect: SC265E
    return 0
}

fn ok_field_early_exit(h: Holder) -> i32 {
    if h.cache == null { return 0 }
    return h.cache.value
}

fn ok_field_assigned_nonnull(h: Holder) -> i32 {
    h.cache = Node()
    return h.cache.value
}

fn bad_field_assigned_null(h: Holder) -> i32 {
    h.cache = null
    return h.cache.value // expect: SC265E
}

fn bad_field_unchecked(h: Holder) -> i32 {
    return h.cache.value // expect: SC265E
}

fn ok_owner_reassigned_resets(h: Holder) -> i32 {
    var o = h
    if o.n? {
        o = Holder()
        if o.n? { return o.n }
    }
    return 0
}

// through `->`, subscript, call result

fn bad_arrow_not_narrowed(p: *Holder) -> i32 {
    if p->cache? { return p->cache.value } // expect: SC265E
    return 0
}

fn ok_arrow_copied_to_local(p: *Holder) -> i32 {
    var c? = p->cache
    if c? { return c.value }
    return 0
}

fn bad_subscript_not_narrowed(xs: [Holder], i: usize) -> i32 {
    if xs[i].cache? { return xs[i].cache.value } // expect: SC265E
    return 0
}

fn ok_subscript_copied_to_local(xs: [i32?], i: usize) -> i32 {
    var e? = xs[i]
    if e? { return e + 1 }
    return 0
}

fn bad_call_result_not_narrowed() -> i32 {
    if make()? { return make().value } // expect: R025E
    return 0
}

fn ok_call_result_bound_to_local() -> i32 {
    var n? = make()
    if n? { return n.value }
    return 0
}

// what ends a check on a local

fn bad_inout_call_weakens() -> i32 {
    var x: i32? = 1
    if x? {
        bump(&x)
        return x + 1 // expect: SC265E
    }
    return 0
}

fn ok_inout_call_then_recheck() -> i32 {
    var x: i32? = 1
    bump(&x)
    if x? { return x + 1 }
    return 0
}

fn ok_unrelated_call_keeps_local() -> i32 {
    var x: i32? = 1
    noop()
    return x + 1
}

fn ok_const_pointer_taken(p: *const (i32?)) -> i32 {
    var x: i32? = 1
    noop()
    return x + 1
}

fn bad_write_through_pointer_to_local() -> i32 {
    var x: i32? = 1
    var *p = &x
    if x? {
        *p = null
        return x + 1 // expect: SC265E
    }
    return 0
}

fn ok_pointer_taken_not_written() -> i32 {
    var x: i32? = 1
    var *p = &x
    return x + 1
}

// mutable self versus const self on the owner of a field path

fn bad_mutable_self_call_weakens_field(h: Holder) -> i32 {
    if h.cache? {
        h.reset()
        return h.cache.value // expect: SC265E
    }
    return 0
}

fn ok_const_self_call_keeps_field(h: Holder) -> i32 {
    if h.cache? {
        var k = h.peek()
        return h.cache.value + k
    }
    return 0
}

fn ok_mutable_self_call_keeps_owner_checked(o: Holder?) -> i32 {
    if o? {
        o.reset()
        return o.peek()
    }
    return 0
}

fn ok_sibling_path_survives_other_instance_call(a: Holder, b: Holder) -> i32 {
    if a.cache? {
        b.reset()
        return a.cache.value
    }
    return 0
}

// globals and statics: narrowed only until the next call

fn ok_global_until_call() -> i32 {
    if counter? { return counter + 1 }
    return 0
}

fn bad_global_after_call() -> i32 {
    if counter? {
        noop()
        return counter + 1 // expect: SC265E
    }
    return 0
}

fn ok_global_call_before_check() -> i32 {
    noop()
    if counter? { return counter + 1 }
    return 0
}

fn ok_global_copied_to_local_survives_call() -> i32 {
    var c? = counter
    if c? {
        noop()
        return c + 1
    }
    return 0
}

fn bad_static_after_call() -> i32 {
    if current? {
        var id = current.value
        noop()
        return id + current.value // expect: SC265E
    }
    return 0
}

fn ok_static_two_reads_without_call() -> i32 {
    if current? { return current.value + current.value }
    return 0
}

fn bad_global_unchecked() -> i32 {
    return counter + 1 // expect: SC265E
}

fn bad_global_early_exit_then_call() -> i32 {
    if counter == null { return 0 }
    noop()
    return counter + 1 // expect: SC265E
}

// closures capturing by copy

fn ok_copy_capture_keeps_state_at_creation(x: Node?) -> i32 {
    if !x? { return 0 }
    var f = fn ()|x| -> i32 { return x.value }
    return f()
}

fn bad_copy_capture_unchecked_at_creation(x: Node?) -> i32 {
    var f = fn ()|x| -> i32 { return x.value } // expect: SC265E
    return f()
}

fn bad_copy_capture_check_after_creation_does_not_hold(x: Node?) -> i32 {
    var f = fn ()|x| -> i32 { return x.value } // expect: SC265E
    if x? { return f() }
    return 0
}

fn ok_copy_capture_checked_inside(x: Node?) -> i32 {
    var f = fn ()|x| -> i32 {
        if x? { return x.value }
        return 0
    }
    return f()
}

fn bad_copy_capture_assigns_its_copy(x: Node?) -> i32 {
    if !x? { return 0 }
    var f = fn ()|x| -> i32 {
        var r = x.value // expect: SC265E
        x = null
        return r
    }
    return f()
}

// closures capturing by pointer

fn ok_pointer_capture_checked_inside() -> i32 {
    var x: Node? = make()
    var f = fn ()|*x| -> i32 {
        if (*x)? { return (*x).value }
        return 0
    }
    return f()
}

fn bad_pointer_capture_unchecked_inside() -> i32 {
    var x: Node? = make()
    var f = fn ()|*x| -> i32 {
        return (*x).value // expect: SC265E
    }
    return f()
}

fn bad_pointer_capture_call_clears_outer() -> i32 {
    var x: Node? = make()
    var clear = fn ()|*x| { *x = null }
    if x? {
        clear()
        return x.value // expect: SC265E
    }
    return 0
}

fn ok_pointer_capture_not_called() -> i32 {
    var x: Node? = make()
    var clear = fn ()|*x| { *x = null }
    if x? { return x.value }
    return 0
}

fn ok_const_pointer_capture_cannot_write() -> i32 {
    var x: Node? = make()
    var peek = fn ()|const *x| -> i32 {
        if (*x)? { return (*x).value }
        return 0
    }
    if x? {
        var p = peek()
        return x.value + p
    }
    return 0
}

fn bad_pointer_capture_call_after_check_inside(g: i32) -> i32 {
    var x: Node? = make()
    var f = fn ()|*x| -> i32 {
        if (*x)? {
            noop()
            return (*x).value // expect: SC265E
        }
        return 0
    }
    return f()
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only --cmax-errors=0 2>&1 || true; } | %FileCheck %s --implicit-check-not='error [' --implicit-check-not='warning ['
// CHECK: places_and_captures.k:57:{{[0-9]+}}: error [SC265E]
// CHECK: places_and_captures.k:62:{{[0-9]+}}: error [SC265E]
// CHECK: places_and_captures.k:67:{{[0-9]+}}: error [SC265E]
// CHECK: places_and_captures.k:83:{{[0-9]+}}: error [SC265E]
// CHECK: places_and_captures.k:87:{{[0-9]+}}: error [SC265E]
// CHECK: places_and_captures.k:102:{{[0-9]+}}: error [SC265E]
// CHECK: places_and_captures.k:113:{{[0-9]+}}: error [SC265E]
// CHECK: places_and_captures.k:124:{{[0-9]+}}: error [R025E]
// CHECK: places_and_captures.k:140:{{[0-9]+}}: error [SC265E]
// CHECK: places_and_captures.k:169:{{[0-9]+}}: error [SC265E]
// CHECK: places_and_captures.k:185:{{[0-9]+}}: error [SC265E]
// CHECK: places_and_captures.k:224:{{[0-9]+}}: error [SC265E]
// CHECK: places_and_captures.k:248:{{[0-9]+}}: error [SC265E]
// CHECK: places_and_captures.k:259:{{[0-9]+}}: error [SC265E]
// CHECK: places_and_captures.k:265:{{[0-9]+}}: error [SC265E]
// CHECK: places_and_captures.k:277:{{[0-9]+}}: error [SC265E]
// CHECK: places_and_captures.k:282:{{[0-9]+}}: error [SC265E]
// CHECK: places_and_captures.k:298:{{[0-9]+}}: error [SC265E]
// CHECK: places_and_captures.k:319:{{[0-9]+}}: error [SC265E]
// CHECK: places_and_captures.k:329:{{[0-9]+}}: error [SC265E]
// CHECK: places_and_captures.k:359:{{[0-9]+}}: error [SC265E]
