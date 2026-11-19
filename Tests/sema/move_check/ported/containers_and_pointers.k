// Moving an element out of an array or a container leaves the whole
// container moved-from, because the compiler does not track which index was
// taken. A move through a pointer, `*p` or `p->f`, leaves that path
// moved-from, and the rest of the pointee usable (ownership.mdx, Moving a
// part). Rules for a second pointer to the same object and for indexing a
// raw pointer are not tracked (the page lists them).
// Cases from Rust tests/ui/moves/move-out-of-array-1, move-out-of-slice-1,
// move-into-dead-array-2, move-out-of-shared-ref-deref,
// moves-based-on-type-access-to-field, nll/move-errors.

class Tok {
    pub var id: i32 = 0
    fn Tok(self, id: i32) { self.id = id }
    @move fn Tok(self, other: Self) { self.id = other.id; other.id = 0 }
}

class Pair {
    pub var a: Tok
    pub var b: Tok
    fn Pair(self) { self.a = Tok(1); self.b = Tok(2) }
}

fn eat(t: Tok) -> i32 { return t.id }

fn array_element_moves_whole() -> i32 {
    var arr: [Tok; 2] = [Tok(1), Tok(2)]
    var first = arr[0]
    return arr[1].id + first.id //! SC052E
}

fn array_element_same_index() -> i32 {
    var arr: [Tok; 2] = [Tok(1), Tok(2)]
    var first = arr[0]
    return arr[0].id + first.id //! SC052E
}

fn array_element_then_whole() -> i32 {
    var arr: [Tok; 2] = [Tok(1), Tok(2)]
    var first = arr[1]
    var rest = arr //! SC083E
    return first.id
}

fn array_element_into_call() -> i32 {
    var arr: [Tok; 2] = [Tok(1), Tok(2)]
    var r = eat(arr[1])
    return arr[0].id + r //! SC052E
}

fn array_element_reassigned_whole() -> i32 {
    var arr: [Tok; 2] = [Tok(1), Tok(2)]
    var first = arr[0]
    arr = [Tok(3), Tok(4)] //! SC071E
    return arr[1].id + first.id
}

fn array_element_assigned_after_move_out() -> i32 {
    var arr: [Tok; 2] = [Tok(1), Tok(2)]
    var first = arr[0]
    arr[0] = Tok(5) //! SC052E
    return first.id
}

fn array_variable_index() -> i32 {
    var arr: [Tok; 2] = [Tok(1), Tok(2)]
    var i = 1
    var x = arr[i]
    return arr[0].id + x.id //! SC052E
}

fn array_literal_elements_are_moved_in() -> i32 {
    var a = Tok(1)
    var b = Tok(2)
    var arr: [Tok; 2] = [a, b]
    return arr[0].id + arr[1].id
}

fn array_read_field_does_not_move() -> i32 {
    var arr: [Tok; 2] = [Tok(1), Tok(2)]
    var n = arr[0].id
    return arr[1].id + n
}

fn vector_element_moves_whole() -> i32 {
    var v: [Tok] = [Tok(1), Tok(2)]
    var first = v[0]
    return v[1].id + first.id //! SC052E
}

fn vector_element_into_call() -> i32 {
    var v: [Tok] = [Tok(1), Tok(2)]
    var r = eat(v[0])
    return (v.size() as i32) + r //! SC052E
}

fn vector_after_push_reuse() -> i32 {
    var v: [Tok] = [Tok(1), Tok(2)]
    var t = Tok(3)
    v.push(t)
    return t.id //! SC052E
}

fn vector_push_temporary() -> i32 {
    var v: [Tok] = [Tok(1)]
    v.push(Tok(3))
    return v.size() as i32
}

fn map_value_moves_whole() -> i32 {
    var m: {i32: Tok} = {}
    m[1] = Tok(1)
    var t = m[1]
    return (m.size() as i32) + t.id //! SC052E
}

fn pointer_deref_move() -> i32 {
    var t = Tok(1)
    var p: *Tok = &t
    var x = cxx::std::move(*p)
    return (*p).id + x.id //! SC052E
}

fn pointer_deref_move_reassign() -> i32 {
    var t = Tok(1)
    var p: *Tok = &t
    var x = cxx::std::move(*p)
    *p = Tok(4)
    return (*p).id + x.id
}

fn pointer_field_move_other_ok(q: *Pair) -> i32 {
    var y = cxx::std::move(q->a)
    return q->b.id + y.id
}

fn pointer_field_move_same(q: *Pair) -> i32 {
    var y = cxx::std::move(q->a)
    return q->a.id + y.id //! SC052E
}

fn pointer_field_move_whole_after(q: *Pair) -> i32 {
    var y = cxx::std::move(q->a)
    var w = cxx::std::move(*q) //! SC052E
    return y.id
}

fn pointer_field_reassign(q: *Pair) -> i32 {
    var y = cxx::std::move(q->a)
    q->a = Tok(6)
    return q->a.id + y.id
}

fn pointer_field_move_into_call(q: *Pair) -> i32 {
    var r = eat(cxx::std::move(q->a))
    return q->a.id + r //! SC052E
}

fn pointer_field_move_in_branch(q: *Pair, c: bool) -> i32 {
    if c {
        var y = cxx::std::move(q->a)
    }
    return q->a.id //! SC052E
}

fn pointer_const_field_read(const q: *const Pair) -> i32 {
    return q->a.id + q->b.id
}

fn pointer_to_array_element(q: *[Tok; 2]) -> i32 {
    var f = cxx::std::move((*q)[0])
    return (*q)[1].id + f.id //! SC052E
}

fn pointer_pointee_unrelated_local_unaffected() -> i32 {
    var t = Tok(1)
    var u = Tok(2)
    var p: *Tok = &t
    var x = cxx::std::move(*p)
    return u.id + x.id
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: containers_and_pointers.k:28:{{[0-9]+}}: error [SC052E]:
// CHECK: containers_and_pointers.k:34:{{[0-9]+}}: error [SC052E]:
// CHECK: containers_and_pointers.k:40:{{[0-9]+}}: error [SC083E]:
// CHECK: containers_and_pointers.k:47:{{[0-9]+}}: error [SC052E]:
// CHECK: containers_and_pointers.k:53:{{[0-9]+}}: error [SC071E]:
// CHECK: containers_and_pointers.k:60:{{[0-9]+}}: error [SC052E]:
// CHECK: containers_and_pointers.k:68:{{[0-9]+}}: error [SC052E]:
// CHECK: containers_and_pointers.k:87:{{[0-9]+}}: error [SC052E]:
// CHECK: containers_and_pointers.k:93:{{[0-9]+}}: error [SC052E]:
// CHECK: containers_and_pointers.k:100:{{[0-9]+}}: error [SC052E]:
// CHECK: containers_and_pointers.k:113:{{[0-9]+}}: error [SC052E]:
// CHECK: containers_and_pointers.k:120:{{[0-9]+}}: error [SC052E]:
// CHECK: containers_and_pointers.k:138:{{[0-9]+}}: error [SC052E]:
// CHECK: containers_and_pointers.k:143:{{[0-9]+}}: error [SC052E]:
// CHECK: containers_and_pointers.k:155:{{[0-9]+}}: error [SC052E]:
// CHECK: containers_and_pointers.k:162:{{[0-9]+}}: error [SC052E]:
// CHECK: containers_and_pointers.k:171:{{[0-9]+}}: error [SC052E]:
ffi "c++" import "utility"
