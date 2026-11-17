# Ownership

How the compiler decides lifecycle categories, moves and copies, checks use after move, and lowers transfers to C++; and which pointer and `const` guarantees it enforces today. The language rules are in the language reference (`ownership.mdx`, `classes-lifecycle.mdx`, `functions-parameter-modes.mdx`, `pointers.mdx`, `unsafe.mdx`). Tether, the language's static memory-safety analysis, is not implemented; every check below is a Sema pass.

## Copy and move

### Lifecycle facts

`ClassLifecycle` (`Compiler/Sema/Check/ClassLifecycle.k`, CHECK phase) answers five facts per record, each a `LifecycleTri` (Yes, No, Unknown), by the C++ rules the record is lowered under:

| Fact | Yes when |
|---|---|
| copyable | no deleted copy ctor, and no user move ctor without a user copy ctor; every base and by-value field copyable, unless the copy ctor is user-provided |
| movable | no deleted move ctor, and a user move ctor or copyable; every base and by-value field movable, unless the move or copy ctor is user-provided |
| trivial_dtor | no user-provided, deleted or virtual destructor on the type, its bases or its by-value fields |
| trivially_copyable | trivial_dtor, no user-provided or deleted transfer ctor on any of them, no virtual method or base; never for a NON_TRANSFER record |
| destructible | no `op finally = delete` on the type, its bases or its by-value fields |

User-provided means neither `= default` nor `= delete`. An imported record's facts are clang's (`FFILinkage::ForeignLayout`) plus its imported constructors; one that declares both transfers `= default` takes its category from its folded members, as one that declares none does (C++ defines a defaulted copy over a move-only member as deleted), so `std::pair<Mv, i32>` is MOVE; an imported template instance that holds (as `value_type`, field or base) a value that cannot be copied cannot be copied either (`_imported_elements`), while one that only points at its argument (`shared_ptr<Mv>`) keeps clang's COPY.

An enum follows the struct rule over every payload of every variant; a plain enum is an integer. A tuple's facts are its elements' folded.

Folding is Kleene AND: one definite No decides, an Unknown only spoils a Yes. A component whose type is dependent is Unknown; a pointer is trivial whatever it points at. Every rule that diagnoses from a fact, in ClassLifecycle and MoveCheck, skips an Unknown one. Facts are memoized per TU on the representative; a record reached again mid-computation (a by-value cycle) reads as trivial, and TypeCycleCheck reports the cycle.

The owning library containers and `string` are handled by a fixed arm in `facts_of_type`: `trivially_copyable` and `trivial_dtor` are No and every other fact is Yes, because `Lib/builtin` declares their layout without a destructor.

### Categories

A record that writes a transfer constructor has the category it declared: `@copy` is COPY, `@move` is MOVE, a deleted one (either, or both) is NON_TRANSFER. A record that writes neither takes the weakest category its bases and fields allow (`_folded_category`): a class holding a move-only field is MOVE, one holding a `std::mutex` NON_TRANSFER. A class declares at most one transfer constructor (SC057E), so it has exactly one transfer kind: a MOVE class may offer an explicit `.copy()` method, and a COPY class an explicit move-out method, never a second implicit kind.

Accepted transfer constructor shapes; any other constructor whose first parameter is the class itself is an error at the declaration, since C++ would make it a copy or move constructor regardless:

```text
@copy fn X(self, const other: Self)   // X(const X& other)
@copy fn X(self, other: Self)         // X(X& other)
@move fn X(self, other: Self)         // X(X&& other)
```

`op =` is derived from the transfer constructor (`assign_from`, `assign_form`); writing it is an error. ClassLifecycle also writes `implicit_transfer` (None, Move, Open) for a record with a destructor and no transfer constructor; InterfaceEmitter declares from it. Other declaration rules: a defaulted transfer over a part that cannot transfer that way (SC129E, rule 6), a category weaker than a base's (SC061E, rule 5), a custom destructor with an implicit copy (SC060W, rule 4), and the virtual-destructor rule (SC056E: a class with a non-trivial destructor whose polymorphic base has no virtual destructor). A base is polymorphic when it has a vptr (a virtual method, a virtual base or a polymorphic base; `ClassLifecycle` fact `polymorphic`), so a `derives virtual` edge counts, unlike clang's `-Wdelete-non-virtual-dtor`; a base with no vptr is a mixin and is never deleted through.

### What moves

`moves_on_pass(sc, t)` is true when `t` is a record of category MOVE. Overload resolution binds such an lvalue as an xvalue, and MoveCheck counts the move, both from this one answer. A category that depends on a generic parameter is not MOVE here.

`MoveCheck` (`Compiler/Sema/Check/MoveCheck.k`, CHECK phase, after ClassLifecycle) is the only place that decides a move:

| Rule | Behaviour |
|---|---|
| `@move` parameter | the argument moves, whatever its type; its type must be movable (SC051E with the reason, `facts->why_not_movable`, generic parameters included, so `std::move` of a NON_TRANSFER value is that error); a const place (below) cannot be one (SC301E, `_move_arg`), a COPY value and a primitive included |
| transfer of a MOVE value | moves when passed to a by-value parameter or a C++ `T&&`, initializing a variable, assigned, or returned when it is not a bare local (an expression body's value included); a user operator's operands are its arguments |
| borrow | a C++ `T&` or `const T&` parameter, and a `const` parameter; a C++ `T&` / `T*` whose body moves out of its argument leaves it moved-from (C++ bodies, below) |
| const place | a const value is never moved from. A place is const by its type, or by its root (`place_has_const_root`: a `const` binding or parameter, `const self`, a const field on the path, an element of a const array or through a `*const T` place `op []`). A transfer of a MOVE value out of one that copies (not a borrowing slot) is SC182E: it can be neither moved nor copied |
| temporary | C++ moves it on its own; not recorded |
| imported record with a deleted copy | transferring an lvalue of it is SC182E, before clang would reject the copy |
| a Kairo record whose copy needs a non-const source | `@copy fn X(self, other: Self)` is C++ `X(X&)`, and the class has no move; a record that declares no transfer and holds one by value (a base or field) gets `X(X&)` and a deleted move from C++ (`ClassLifecycle::mutable_source_copy`). A copy of it from a const place, an assignment from a temporary, and a returned local or by-value parameter (C++ treats it as an rvalue) are SC302E, with a fix-it inserting `const` before `other`. A temporary that initializes a variable or a by-value parameter is built in place, never copied, and is accepted, as are copies from a non-const lvalue and a `const` parameter bound to a temporary. Where C++ makes the copy inside a template (`std::vector<X>::push_back`) the error comes from the C++ compile, reported at the Kairo use ([Diagnostics.md](Diagnostics.md#clang-diagnostics)) |
| a C++ `T&` to a Kairo record that cannot be copied | `var x = cv[0]`, `cv[0] = cv[1]`: never moved from, so the copy is SC182E |
| `v[i] = v[j]` of a MOVE element | SC182E: a move out of an element into another element is not decided; clang rejected this shape before |
| `yield` of a const place | copied to a frame local (EmitIR `_yield`); SC182E when the type cannot be copied |
| a plain `for` binder | a copy of each element (array, slice, generator, C++ range whose `*it` is an lvalue); SC182E when the element cannot be copied, the note offers `*x` |
| `a + b` through an `op +` derived from `op +=` | copies an lvalue `a`; SC182E when it cannot be copied (a temporary `a` is built in place) |
| a vector, set or map literal | the container copies each element out of the backing array; SC182E ("cannot be built yet") for elements that cannot be copied |

Each transfer is recorded in `SemaContext::move_sites`.

Pending moves. Two transfers move only if the binding is not read again on any path, including a loop's next iteration: a value whose category its generic instance decides (`var y = x` with `x: T`), and an expansion `xs...` of a forwarding pack. Otherwise they stay copies. Neither marks the binding moved-from, and a binding whose address is taken anywhere in the body (`&x`, `&x.f`, a pointer capture, a C++ `T&` or `@inout` argument) never takes one. A pending transfer that a later read demotes is kept on the function (`FunctionDecl::move_reuse_site`, `move_reuse_read`); at each live instance ConformanceChecking substitutes the value's type and, where the instance's type cannot be copied, reports SC052E at the instance's use with its chain (`_check_reuse`), rather than leaving clang a deleted copy constructor.

Use after move (SC052E). A moved local or parameter, `self` included, or a part of one, is moved-from from that point; a later read that touches it in the same body is an error. An assignment to it or to something enclosing it clears it; a `var` declaration starts a new binding. At a join, moved on either path means moved. When the moved expression's type is a record with a public `fn copy(const self) -> Self` (the requirement of std's `CopiesItself`, read off the record by `MoveCheck::_copies_itself` so it holds without `std::utility`), the error carries a note at the end of the moved expression with a fix-it inserting `.copy()`.

What is tracked is a place (`MovePlace`, built by `_place`): a root binding and a path under it.

| Step | Path | Example |
|---|---|---|
| `.field`, `.0` | the field's name or ordinal | `p.a.b`, `self.r` |
| `->field` on a pointer, `*p` | a `*` segment, then the field | `p->r` is `*.r`; `*h.link` is `link.*` |
| `x[i]` on anything but a pointer | ends the path: the place is the container | `v[0]`, `h.items[1].s` |
| `p[i]` on a pointer | not a place | a container's buffer |
| a method, a static, an operator step, a user `op ->` or `op *` | ends the path; the place is what that step reads | `p.a.len()` reads `p.a` |

A read touches a moved part (`read_touches`) when it is the part or inside it, or when it holds the part by value: with `self.r` moved, `self.r.n` and `self.touch()` are errors and `self.s` is not. Storage that only points at the part is not touched: with `p->r` moved, `p` can still be copied or passed, and `p = q` forgets the pointee. A store through a pointer (`p->r = R()`) reads the pointer and clears the part.

A move out of an element leaves the container moved-from, because the index is not tracked: after `var c = v[0]`, any use of `v` is an error until `v` is assigned, so a loop that moves `v[i]` is an error on its second pass. When the container is a field (`h.items[0]`), its siblings stay readable. A subscript on a pointer is pointer arithmetic over storage the program manages element by element (`Vector`'s buffer is moved out of and destroyed this way), so it is not tracked.

The dataflow is intraprocedural and path-insensitive: it does not track the values of conditions, with one exception, the outcome of a call that is itself a condition (conditional moves, below). The walk overrides dispatch for the constructs that fork or end a path (`if`, `match`, `try`, `&&`, `||`, loops, `return`, `break`, `continue`, `panic`, a call typed `!`). A loop body is walked twice, the second time with the back edge joined in; diagnostics are deduplicated by (binding, use). A loop with a condition starts its body from the condition's true state and is left from its false state, taken at the entry, at the second pass's head and once more over the second pass's back edge. A `finally` body is walked at every exit of its block over the state at that exit. The right operand of `&&` moves on one path only, so after `if a && f(x) { return }` `x` is maybe-moved.

What a body leaves behind. Storage a body does not own is `self` (not a destructor's), an `@inout` or C++ `T&` parameter, what any parameter points at, and a closure's `|*x|` capture. A part of it that is still moved-from at an exit (`_exit`: every `return`, the end of the body, and every panic that leaves the body) is recorded on the function when its walk ends (`_record_out`), with the outcome of each exit that leaves it so. A part assigned again before the exit is not recorded.

| Exit | Outcome (`MOVE_ON_*`) |
|---|---|
| `return true` / `return false` in a function returning `bool` | `TRUE` / `FALSE` |
| any other return of a `bool` function | `TRUE` and `FALSE` |
| `return null` in a function returning `T?` | `NULL` |
| a return of a value whose type is not nullable, in a function returning `T?` | `NON_NULL` |
| any other return of a `T?` function (a value that may be null, `&null`) | `NULL` and `NON_NULL` |
| any return of a function of another type, the end of a body, a return in a closure | `OTHER` (a closure: every return outcome) |
| a `panic` statement, or a call that may panic, outside a `try` that catches everything | `PANIC` |
| `return v` in a `bool` function, `v` a condition that splits on a call (below) | `TRUE` from the state `v` is true in, `FALSE` from the one it is false in |
| `return f(x)` in a `T?` function, `f` returning the same `T?` | `NON_NULL` from the state where the call is not null, `NULL` from the one where it is |

A returned value that is a call's outcome is walked as a condition (`_return`): `return q.push(&v)`, `return !q.push(&v)`, `return c && q.push(&v)`, `return find(&v) != null`, or a local holding a call's result (stored results, below). The body then leaves once per outcome, so the function's record carries its callee's: `fn try_push(@inout v: Task) -> bool { return q.push(&v) }` moves `v` only when it returns `true`. An expression body (`= q.push(&v)`) is that `return`. A value that splits on nothing keeps its single exit.

A part moved on the way to a panic is also recorded with the panic's type (`MoveOut::pfirst` / `pcount`), when that type is known statically: the payload of a `panic X`, each type of a call's declared set (`panic(E1, E2)`, or a `fn` type's), and the types in a callee's own record. An inferred set is solved after MoveCheck (at the panic-set barrier), so a call to a bare-`panic` function brings no types of its own; a type that names a type parameter and a rethrow of a bare arm's binding (`catch e { panic e }`) are not known either. A part moved by a panic whose type is not known has an empty range: every type.

A panic inside a `try` is not an exit: it goes to the catch arms (below). It leaves the body only past every enclosing `try`, and a `try` with a bare `catch` arm stops it. The finally bodies of the blocks it leaves run over its state, as at a `return`.

| On `FunctionDecl` | Holds |
|---|---|
| `move_out` | one `MoveOut` per part: `param` (index into `params`), `first` / `count` (its path in `move_out_path`), `at` (where the body moves it), `when` (the `MOVE_ON_*` bits of every exit that leaves it moved-from), `always` (moved-from at every exit, returns and panics alike; false when only at some), `pfirst` / `pcount` (with `PANIC` in `when`: the panic types it is moved on, in `move_out_panic`; none for a panic of any type) |
| `move_out_path` | the paths, flat: a `FieldDecl` per field step, null per pointer followed |
| `move_out_panic` | the panic types, flat, canonical and unqualified |
| `move_out_state` | `None` (not looked at), `Body` (read from the body; an empty list means it leaves nothing), `Assumed` (no body Kairo can read: a call takes every argument it could move as moved-from) |

The record is the function's summary for moves, kept on the declaration so a later analysis reads the same facts a call does. `always` is not used by MoveCheck, which reads `when`; it is recorded because a consumer that tracks paths needs it.

A call applies the record (`_call_leaves`): each part is marked moved-from in the argument it was reached through (a part behind a pointer that an element holds marks nothing: the container only points at it), the bound receiver for `self` (`h.take()`, `p->take()`), the operand of `&x` for an `@inout` or pointer parameter, or a pointer binding. The mark is an ordinary moved part, so the caller's later read is SC052E, an assignment clears it, and when the argument is itself storage the caller does not own, the caller records it in turn. An argument that names no place marks nothing.

Conditional moves. `_call_leaves` returns each part with its `when`, and the context of the call marks it (`_apply`) on a path only when an outcome that reaches the path is in `when`:

| The call is | Marks on the true path | Marks on the false path |
|---|---|---|
| a condition `f(x)` | every return outcome but `FALSE` | every return outcome but `TRUE` |
| `f(x)?`, `f(x) != null`, `null != f(x)` | every return outcome but `NULL` | every return outcome but `NON_NULL` |
| `f(x) == null`, `null == f(x)` | every return outcome but `NON_NULL` | every return outcome but `NULL` |
| a local initialised from the call, tested as one of the above (stored results, below) | as for the call | as for the call |
| returned from a `bool` or `T?` function (exits, above) | the function's own outcome | |
| anywhere else (passed on, compared other than with `null`, a statement) | every return outcome | |

A condition is that of an `if`, an `else if`, the value form `if c => a else => b`, a `while` and a C-style `for`; `!` swaps its two paths, `a && b` walks `b` on `a`'s true path (true: `b`'s true path; false: the join of both false paths) and `a || b` walks `b` on `a`'s false path (`_cond`). A user-defined `!`, `&&`, `||` or `==` is an ordinary call and splits nothing. The path after a call is always one of its returns, so a part the callee moves only when it panics is not marked there.

```kairo
fn push(self, @inout v: Task) -> bool {
    if self.full { return false }   // v untouched
    self.slot = v
    return true                     // v moved
}

if q.push(&t) { /* t is moved-from */ } else { /* t is whole */ }
while !q.push(&t) { pause() }       // t whole in the body, moved-from after the loop
var ok = q.push(&t)                 // t moved-from on every outcome until ok is tested
if !ok { t.run() }                  // whole: ok is false, so push did not move it
```

Stored results. A local initialised from a call, of type `bool` or `T?` (`var ok = q.push(&t)`, `const ok = ...`, `var r? = q.put(&t)`; declared with that type or none, in a function or closure body), holds the call's outcome (`CondLink`, on the flow state). The call marks its parts on every outcome as usual, so a read before a test is SC052E. A test of the local as a condition (`if ok`, `!ok`, `&&`, `||`, `while ok`, `r == null`, `r != null`, `null == r`, `r?`) or a return of it (`return ok`, `return r`) takes back the marks the call made and marks each branch by the outcomes that reach it, as a test of the call would (`_link_cond`). The link records only parts that were whole before the call, and a part counts only while it still carries the call's own mark (the same `at`). The link stays after a test, so the local can be tested again. It is dropped, and the parts stay moved-from on every outcome:

| When | Example |
|---|---|
| the local is used other than as a test or a return | `show(ok)`, `ok = q.full`, `&ok`, `flip(&ok)`, a capture, a method call on it, a compound assignment |
| a part is moved again from anywhere else | `t = Task(); sink(t)` between the call and the test |
| a join whose other side does not hold the same link (same local, same call, same parts) | `if c { ok = false }` |
| a loop head whose back edge does not hold it | `while c { ok = q.full }`; a loop that touches neither keeps it |

A part assigned in between holds a live value on both branches, so taking the mark back is still right.

The panic path of a call. A call that may panic (its callee or its `fn` type is marked `panic`; a call through anything else is taken to) also leaves along its panic path: the state after its arguments, plus the parts whose `when` has `PANIC`, goes to the catch arms of the enclosing `try`s, innermost first, up to one with a bare `catch` or a typed arm of exactly the panic's type, and past them to the caller's own panic exit when the caller (a function or a closure) is marked `panic` (`_panic_path_of`, `_leave_by_panic`). The path carries the panic's type. A call with a declared set takes it once per type of the set, marked with the parts that type moves (a part with no types: every one). A call with no declared set takes it once per type its record's parts name, marked with the parts of that type, and once more as a panic of any type, marked only with the parts moved on any type. A `panic X` takes it once, with `X`'s type when it is known statically. So does a user-defined operator marked `panic` (binary, compound assignment, subscript, unary, cast) and each iteration of a ranged `for` (its `op in`). Each block the panic leaves runs its finally bodies once, before the first `try` outside it takes the state; a panic met while a finally body is walked does not walk the pending bodies again. A catch arm starts from the join of the state before the `try` and every state a panic it can catch brought to it (`_arm_entry_of`): a bare arm takes every state; a typed arm takes those of its filter's type and those of a type not known statically. Arms match exact types, as the panic sets do (§3.1, `pset_has`); a filter that is unresolved, names a type parameter or is a C++ type takes every state. With a C++ exception arm, or when no panic point was met, the state at the end of the `try` body is joined in as well, since C++ code throws where the walk does not look.

```kairo
fn give(@inout v: Task) panic { if bad() { sink(v); panic Full {} } }   // moved when it panics
fn take(@inout v: Task) panic { if bad() { panic Full {} }; sink(v) }   // moved when it returns

try { give(&t) } catch { /* t is moved-from */ }   // and whole after the `try`
try { take(&t) } catch { /* t is whole */ }        // and moved-from after the `try`
try { give(&t) } catch e: Other { /* t is whole: give moves it only on Full */ }
```

Which declaration the call names does not matter: the record is read from the chain's definition (`Redeclarable::definition`), so a method declared in its class and defined out of line, or a function declared before its caller and defined after, is read from its body. A function declared in Kairo with no definition Kairo can read (implemented in C or C++) has nothing to read, and what cannot be read is taken at its worst (`_call_unseen`): after the call a non-const receiver, an `@inout` argument and what a pointer to non-const points at are moved-from, and the declaration is stamped `Assumed`. Only a value of a MOVE type can be left moved-from, so a copyable argument, a `const` receiver or parameter and a pointer to const are untouched. Not under this rule: a function imported from a C or C++ header (its signature and its body decide: a `T&&` parameter moves, and a `T&` / `T*` is read off the body, C++ bodies below), a compiler-generated member, a constructor's object, and an interface method.

The record has to exist before the call is checked. A call into a function of the same TU that is not walked yet walks it first (`_walk_callee`; `_walked` keeps each body to one walk per run, and a same-TU record is read only once this run has written it, so a node walked by an earlier run of the live check is not trusted). An imported function's TU has finished its checks. Limits: a function that calls itself sees nothing from the recursive call (its own exits still record); nested walks stop 64 calls deep; and of TUs that import each other, the one checked first does not see the others' records (`Tests/Sema/Modes/MoveCheck/partial_caller_files.k` pins both directions).

A closure whose body leaves a `|*x|` capture moved-from may run at any time, so the captured binding is moved-from once the closure expression is evaluated.

Not tracked, and each leaves a moved-from value behind with no diagnostic:

- A call the compiler cannot see into: an interface or virtual method, a function pointer or a stored closure. A C++ function whose body cannot be inspected is an unchecked assumption instead (C++ bodies, below).
- A field whose type is a generic parameter, moved out of `self` in a generic body: the move is decided per instance, and the record is written at the pattern.
- A user-defined operator (`a + b` bound to an `op +`) that leaves an operand moved-from: only call expressions apply a record.
- A constructor that leaves part of its own `self` moved-from.
- Files that import each other: the file checked first.
- A by-copy capture moved inside its closure: the closure's own copy is moved-from after the first call.
- A second name for the same object: with `var *p = &h`, a move out of `p->r` does not mark `h.r`.
- `p[i]` on a pointer, and a place reached through a call's result.

Taken as moved on every outcome, because the outcome is not known where the result is read: a call's result passed on (`return pass_on(q.push(&t))`), or tested through a comparison other than with `null` (`q.push(&t) == true`); a stored result whose link was dropped (stored results, above), or stored from anything but the call itself (`var ok = !q.push(&t)`, `var ok = c && q.push(&t)`); a `return` of a `bool` that does not split on a call (`return c`); a `T?` return of a nullable value that is not a call of the function's own `T?` type; and a `match` on the result. On the panic side, a call into a function whose set is inferred brings no types: the state before its own parts goes to every arm.

### C++ bodies

A C++ `T&` or `T*` parameter borrows, but C++ can move out of one with nothing in the signature showing it (`T sink = std::move(b)`). So at a call from Kairo to an imported C or C++ function (`_call_cxx`), each MOVE argument bound to a `T&` / `T*` to non-const, and a MOVE receiver of a non-const method, is checked against the callee's body (`ForeignInstantiate::cxx_moves_out`, the walk in `Compiler/Native/ClangMoveWalk.hh`). A constructor call, an operator, a functor call and a pack parameter are not asked about.

The question is whether an expression that refers to the argument's object reaches a `T&&` parameter of a call or a constructor call, in the body or in what the body passes it to. It is not flow sensitive: any path counts, and a move followed by an assignment still counts.

| Refers to the object (granularity: the whole object) | Example |
|---|---|
| the `T&` parameter, `*p` / `p->m` / `p[i]` of the `T*`, `*this` / `this->m` | `std::move(b)`, `std::move(*p)`, `std::move(*this)` |
| a member of any of those | `std::move(b.name)`, `std::move(b.*pd)` move `b` |
| a local reference or pointer initialised from one | `T& r = b; T s = std::move(r);` |
| a cast to a reference of one, a call returning a reference that takes one by reference | `static_cast<T&&>(b)`, `std::move(b)`, `std::forward<T>(b)`, `b.front()` |

Such an expression bound to a parameter whose type, in the instantiated callee, is an rvalue reference to non-const moves it. `std::move(b)` on an lvalue instantiates `move<T&>(T&)`, so it is not the move itself; the constructor whose `T&&` its result binds is. The walk reads instances, never patterns, so `std::forward<T>(x)` moves only when `T` is not a reference. A method qualified `&&` called on it moves it. Bound to a `U&` / `U*` (`U` not const), or as the object of a non-const method, it is followed into that callee, up to 8 calls deep (`CXX_MOVE_DEPTH`), each (function, parameter) answered once per build (`CxxMoveCache`). Unevaluated operands (`noexcept(...)`, `sizeof`, `requires`) are skipped; a builtin (`std::move`, `memcpy`) moves nothing of its own, and a defaulted or deleted member moves nothing out of the parameter asked about. A lambda's body is read where the lambda is written, since calls of the closure are not followed: a capture by reference is the object, a capture by copy of the object is the closure's own, and a copied pointer still points at the object. A recursive call answers None for the pair being answered; the pairs between the two calls are not cached, since their answers wait on it, so each (function, parameter) gets the same answer whichever is asked first.

A virtual call and a call through a pointer run code the walk cannot pick, but every override, and every function the pointer can hold, has the parameter types the call names. So the object bound there by value or by reference or pointer to const is not moved, and bound to a `T&&` it is moved, with no body read; only a `U&` / `U*` to non-const, or the object of a non-final virtual method, makes the call Unknown. A call through a pointer to member function on the object (`(o.*pm)()`) is Unknown.

The answer is Moves, None, Unknown, or Assumed, and Moves wins over Unknown, which wins over Assumed, which wins over None:

| Unknown because | Assumption text ends |
|---|---|
| the function, or a callee it passes the object to, has no visible body | `its body is not visible`, `it passes it to 'g', whose body is not visible` |
| a virtual method that is not final, called on the object or given it by `U&` / `U*` to non-const | `it is virtual, so an override may run instead`, `it passes it to 'g', a virtual call` |
| a call through a pointer (to function or to member function) given it by `U&` / `U*` to non-const, or a call through a pointer to member function on it | `'f' passes it to a call through a pointer` |
| the depth limit | `the inspection stops 8 calls deep, in 'f'` |
| a template body that does not instantiate for these arguments (a Kairo record's stand-in has no methods) | `its body does not compile for this argument` |
| a template call whose instance was not deduced (a dependent argument, a list literal) | `the template instance it calls is not known` |

Moves marks the argument moved-from through the ordinary machinery, so a later read is SC052E with the note "'h' was moved here, by the call to 'steal'" and a note at the expression in the header that moves it ("'steal' moves it here"; ", called from 'f'" when it is a callee's). Under `-fno-strict-cxx-moves` (below) Unknown borrows, and the call is an unchecked assumption, kept per TU (`SemaContext::unchecked`, once per call and text) and printed by `--print-unchecked-assumptions`:

```
ClangBackend.k:630:26: unchecked assumption: 'ExecuteAction' is assumed not to move out of 'act': its body is not visible
ImportOverlay.k:232:29: unchecked assumption: 'Allocate' is assumed not to move out of 'self._arena': it passes it to 'llvm::AllocatorBase<llvm::BumpPtrAllocatorImpl<>>::Allocate', whose body is not visible
```

Assumed is Unknown whose every unread callee is a function of the toolchain's own library with no visible body: libc++'s out-of-line members and its `extern template` instances (`std::getline`, `basic_istream::seekg`, `__hash_table::find`). A function is the library's when its first declaration lies in a file whose real path is under one of the toolchain's library roots (`ClangBackend::library_roots`, held by the walk as `CxxLibRoots`):

| Root | Counts for |
|---|---|
| the libc++ directories (`cxx_include_dirs`, or `<sysroot>/include/c++/v1`) | any function |
| the sysroot's C library directories, and `<resource-dir>/include` (the clang builtins) | a function with C language linkage |

These are the `-isystem` roots the driver derives from `--sysroot` and `--resource-dir`, never a `-I` directory, an `-idirafter` host directory or a framework directory. With no `--sysroot` (`--native`) the C library is the host's `/usr/include`, which holds third-party headers beside libc, so no C root counts. The test is the file, not clang's system-header bit, which holds for every `-isystem` root and for any header with `#pragma GCC system_header`, and not namespace `std`, which any header can declare into (an explicit specialization of a std template for a user type is the user's). An implicit instance of a std template is declared where its pattern is, so a std member instantiated with a Kairo type counts, and so does a std function that calls back into user code (a comparator, an allocator): the exemption is for the library function's own body, and what it hands the object to was not read either way. Only a missing body is Assumed: a virtual call, a call through a pointer, the depth limit and a body that does not instantiate stay Unknown inside the library too, and a std function whose visible body moves the object (`std::swap`, a constructor taking `T&&`) is Moves. A builtin (`std::move`, `std::forward`, `memcpy`) moves nothing of its own, as above. Because Unknown wins, a body that hands the object to an opaque library function and to an opaque function of any other header is Unknown.

`-fstrict-cxx-moves`, on by default, takes an Unknown call at its worst, as a Kairo function with no body is taken: the argument is moved-from, so a later read is SC052E, and nothing is assumed. The note at the call says why it was not inspected and that `-fno-strict-cxx-moves` borrows it instead:

```
main.k:24:12: error [SC052E]: 'h' is used after being moved
main.k:23:5: note [I900N]: 'h' was moved here, by the call to 'opaque', whose body cannot be inspected and is taken to move it under -fstrict-cxx-moves
moves.h:27:1: note [I900N]: not inspected: its body is not visible; with -fno-strict-cxx-moves the call borrows it, on an unchecked assumption
```

An Assumed call borrows under either setting, on an assumption the TU lists, with the library function named:

```
KTDecompress.k:201:5: unchecked assumption: 'getline' is a C++ standard library function whose body is not visible: assumed not to move out of 'f'
main.k:40:5: unchecked assumption: 'read_line' passes 'f' to 'std::getline', a C++ standard library function whose body is not visible: assumed not to move out of it
```

`-fno-strict-cxx-moves` turns strict moves off: an Unknown call borrows on an unchecked assumption, as above. Like every language flag it applies to the user's files only (Driver.md, dialect flags and the library): `Lib/builtin` and `Lib/std` always borrow on an assumption. The compiler's own targets pass `-fno-strict-cxx-moves` (`build.py`, and so `kairo_compile.json` for the language server): the tree hands MOVE values to clang and LLVM functions defined in their libraries (`CompilerInstance::ExecuteAction`, `BumpPtrAllocator::Allocate`, `StringMapImpl::LookupBucketFor`), which are not the toolchain's standard library.

The strict mark is an ordinary moved part, so a Kairo function that leaves such a part of storage it does not own moved-from records it (What a body leaves behind), with the C++ call (`MoveOut::cxx_at`, carried from callee to caller through every Kairo call). A caller's error then says the callee "calls a C++ function that could not be inspected", and a note at the C++ call names the opt-out:

```
main.k:33:12: error [SC052E]: 'h' is used after being moved
main.k:32:5: note [I900N]: 'h' was moved here, by the call to 'facts_of', which calls a C++ function that could not be inspected
main.k:23:5: note [I900N]: this C++ call could not be inspected and is taken to move it under -fstrict-cxx-moves; with -fno-strict-cxx-moves it borrows, on an unchecked assumption
```

Where bodies come from. A header set is parsed with `SkipFunctionBodies`; its consumer (`HeaderSetConsumer`) keeps the bodies of functions declared in a file whose path is, or ends in `/` and, a header as an `ffi import` spells it (`HeaderSet::body_files`, matched when the file is entered). The match is by path because in the shared set a named header is often entered first from another header, and `#pragma once` keeps the set's own include from entering it again. System headers are not excluded: the driver passes every include directory as `-isystem`, so `ffi "c++" import "string"` keeps the bodies in libc++'s `<string>` itself, though not in the `__string/` files it includes. Every other body is skipped, so a call into a header only included by another is Unknown. A spelling with `..` never matches, and a different file with the same path suffix keeps its bodies too; both only change which calls are Unknown. A template instance is the specialization the call's deduction found (`CallExpr::cxx_spec`, `cxx_spec_set`, from `ForeignInstantiate::deduce_call`); its body, and those of the template instances it calls, are instantiated on demand with the set's diagnostics quiet, under `ForeignInstantiate`'s lock and then the set's `sema_lock()`, the order fills take. A marked `&x` bound to a C++ `T&` is shown to that deduction as the lvalue `x`, which is what the emitted call passes.

### Lowering

`CopyMoveLowering` (`Compiler/Sema/Lower/CopyMoveLowering.k`) rewrites each recorded site to `e as T&&` (an xvalue cast to `cxx_rref`), which EmitIR spells `static_cast<T&&>(e)`. The language has no move operator: the type decides that a transfer moves, and C++ moves an lvalue only when it is cast. `std::move(x)` (`Lib/std/utility.k`) is an ordinary generic function, `pub fn <T> move(@move x: T) -> T { return x }`: the `@move` parameter rule makes its argument a recorded move site, so it has no case of its own in MoveCheck or here. Its argument leaves the place moved-from for every `T`, a COPY class and a primitive included, and its result is built by one move construction from the `T&&` parameter (C++ moves a returned rvalue-reference parameter implicitly). A COPY class has no C++ move constructor, so that construction is its copy constructor. Because MoveCheck is the only decider, the cast and the use-after-move check agree. A COPY value needs nothing: C++ calls the record's copy constructor. It runs before any pass that rebuilds an expression, so each recorded node is still in the tree ([Lowering.md](Lowering.md#pass-order)). WhereDispatchLowering, which runs earlier, records a dispatcher's forwarded by-value MOVE parameter in `move_sites`, so it is moved too. NullableTypeLowering runs after it, because a transfer is decided from the value's lifecycle, which ClassLifecycle answers for `T?` from `T`, and a newly minted `Null<T>` instance has no facts yet. Choosing a `@copy` constructor at a use, and rejecting a copy of a MOVE class in this pass, are not implemented.

### Parameter passing

A by-value COPY record parameter its function never mutates is passed as `const T&`, so a call borrows the caller's value instead of copying it. A MOVE record keeps its value, since taking ownership is the parameter's point. The decision is ParamPassInference's ([Lowering.md](Lowering.md#passes)).

### Destruction and freeing

The destructor is `fn op finally(self)` (0.2.0; `fn op delete(self)` is an error with a rename fix-it). It is the same member a standalone `finally { }` block lowers to ([Lowering](Lowering.md#finallylowering)), and C++ sees it as `~T`. Kairo has no `delete` expression, so destruction and freeing are separate:

| Spelling | Meaning | Lowers to |
|---|---|---|
| (scope end) | run `op finally` of every local, reverse declaration order | the C++ destructor |
| `x.finally()` | run `op finally` of the local `x` now; the scope's end does not run it again; `x` cannot be used until a whole assignment constructs it again (SC303E) | the destructor of `x`'s union storage ([Lowering](Lowering.md#union-storage-locals)) |
| `@create T(args)` | allocate through the allocator in effect and construct | `kairo::std::create<T>(args)` |
| `@destroy p` | run the destructor of `*p`, then return the memory to the allocator | `kairo::std::destroy(p)` (allocator-routed, so the memory cannot go back to a different allocator than the one that gave it) |
| `@cxx::new T(args)`, `@cxx::new [T; n]` | C++ allocation for memory that crosses into C++; result `unsafe *T` | `new T(args)`, `new T[n]` |
| `@cxx::delete p`, `@cxx::delete [] p` | free C++-allocated memory | `delete p`, `delete[] p` |

The `@cxx::` forms reuse `@create` / `@destroy`'s parsing and constructor resolution but are not routed through the allocator; pairing `@create` with `@cxx::delete` (or `@cxx::new` with `@destroy`) is the caller's error. The array spelling `@cxx::delete [] p` is the one place to change if the implementation settles on another. C++ code reaches Kairo types through the class-scope `operator new` / `operator delete` described in [Codegen](Codegen.md#c-allocation-operators).

## Move-only types

A MOVE value is transferred as above; a NON_TRANSFER value is never transferred. A by-value `const` parameter of a MOVE type takes the value, as for any MOVE record.

### Instances of generic records

A pattern's Unknown facts are the pattern's answer only. A concrete instance of a Kairo generic has facts of its own: the same `_compute` / `_compute_enum` over its pattern's (or selected partial's) members, with every field, payload and base type read through a `Substitution` seeded by `bind_from_record(instance)`. A component that does not substitute stays Unknown. So `Opt<i32>` is COPY and `Opt<Mv>` MOVE. The memo is keyed by the instance decl (one per registry entry) and kept per TU: ClassLifecycle is Sema, the registry is AST and cannot hold its type, and the facts are a pure function of pattern and arguments, so every TU computes the same answer. An imported template's instance keeps clang's facts; a dependent one reads its pattern.

Every reader (MoveCheck, `moves_on_pass`, CopyMoveLowering through `move_sites`, assignment's SC071E, `@copy` / `@move` lifecycle requirements, FeatureGateCheck's non-generic-ADT gate, EnumLayoutLowering, PanicEffectChecking) is handed the instance and reads its facts unchanged. A lifecycle requirement also asks whether the instance kept its declared `@copy`: one whose `requires` is false at the instance, a value predicate or a `P impl I` conjunct (`ConformanceChecking::dropped_copy`, `[Mo]` of a move-only `Mo`) is dropped from it in C++, and its one transfer constructor was that copy, so the instance meets neither `@copy` nor `@move` (SC162E, with a note at the constrained constructor).

The declaration rules a generic class skipped on an Unknown (rule 6, rule 5, the virtual-destructor rule) are asked again of each live instance by `ClassLifecycle::instance_failures`, which returns data; ConformanceChecking reports them (`_check_facts`) at the instance's use with label "'X<A>' is instantiated here", the rule's notes, and the instantiation chain ([Generics.md](Generics.md#monomorphization-sync-point)). This happens once per build, when the bounds hold. A failure the pattern already reported is not repeated, and rule 4 (SC060W) is not asked per instance: a warning per instance about a declaration the instance cannot change is noise.

### Library types

`string`, `Vector<T>`, `HashMap<K, V>` and `HashSet<T>` in `Lib/builtin` are COPY (`@copy`, deep copy). The design is MOVE with an explicit `.copy()` (a COPY class may offer `.move_to(&dst)`); a class has one transfer kind. A class is COPY unless it declares otherwise; the design also makes classes MOVE by default, with structs COPY only.

### What MOVE library types need

Declaring the library types `@move` type-checks. Programs that use them then fail, because the places below still copy. Each row is not implemented.

Sema, so that a move is always seen and never silent:

| Gap | Code | Effect today |
|---|---|---|
| The container arm of `facts_of_type` keeps `copyable` / `movable` Yes | `ClassLifecycle.k:558` | a class holding a MOVE `string` would not become MOVE |
| A body reached through an interface, a virtual method, a function pointer or a stored closure is not consulted at the call | `MoveCheck::_call_leaves` (reads the called declaration's `move_out` only) | a conformer's `take(self)` that returns `self.name` leaves the caller's object moved-from with no diagnostic |
| A struct holding a MOVE field is accepted and copied | no rule | `structures.mdx` says structs are `memcpy`-copied |
| A move made through one pointer is not seen through another name for the same object | `MoveCheck` (no alias information) | `var *p = &h`, `var y = p->r`, then `h.r` reads a moved-from value |
| A plain `for` binder is a copy of the element | `IterLowering` ("Binders") | `for s in names` cannot bind a MOVE element; the binder has to be a read-only name for the element |
| `for (k, v) in m` yields a tuple built by copying the key and the value | `Lib/builtin` `op in`, `IterLowering` | fails in the C++ step (CL001E) for MOVE fields |
| A consuming receiver does not exist | no syntax | an adapter cannot take its inner value out of `self` |

Lowering and codegen, so that nothing copies behind the user's back:

| Gap | Effect today |
|---|---|
| A list, set or map literal copies each element in; it has to lower to `with_capacity(n)` plus `push` / `insert`, which moves | `var v: [M] = [M(), M()]` passes Sema and fails in the C++ step (CL001E) |
| `a + b` on a type that declares only `op +=` is derived by copying the left operand, and declaring both halves is SC054E | `"a" + name` on a MOVE `string` fails in the C++ step |
| `op []=` takes its key by value | `m[k] += 1` moves a MOVE key on every write; the key has to be `const`, copied on a miss |
| An argument temporary in a `for` header dies before the loop body | a generator that borrows its argument reads a destroyed value |

Conformance, so that generic library code can name what it needs:

| Gap | Effect today |
|---|---|
| Pointers and imported C++ types get `Eq` and the one-argument `hash` natively; a pointer cannot be extended | no pointer satisfies a library `Hash`, `Clone`, `Ord` or `Default` bound of another shape |
| Tuples, `T?` and `[T]` satisfy no `Eq` bound; builtin `<=>` and `+` satisfy no interface | `[i32].sort()`, `min`, `sum` and a tuple map key have no bound to meet |
| A COPY type has no native `Clone` | every COPY user type writes a one-line `copy()` |

### Destructive, bitwise moves

A moved-from binding cannot be named, so a move may be destructive: the source is not destroyed and the bytes may be relocated. The emitted C++ does not use this today; each move runs a C++ move constructor and the moved-from object is destroyed later. The plumbing for skipping that destructor exists ([disarmed moves](Lowering.md#disarmed-moves): `MoveKind`, `is_real_transfer`, `disarm_local_at`); no provider proves a move definite yet. Using it needs:

- every Kairo class whose fields are all relocatable emitted as trivially relocatable, so it is passed and returned in registers. `@relocatable` does this for one record on request (`trivial_abi`); nothing infers it;
- the builtin containers growing, inserting and erasing with `memcpy` / `realloc` instead of per-element move construction;
- no destructor call on any path where MoveCheck proves the value moved, which needs the element and alias tracking above to be exact;
- a marker and a non-bitwise path for types that hold a pointer into themselves and for imported C++ types that are not relocatable;
- the rule stated for C++ callers: a C++ caller of an emitted header sees ordinary C++ move semantics.

## Safe pointers

`*T` is non-null by construction; `unsafe *T` is the only pointer that holds `&null`; `*T?` is `(*T)?`. What the compiler enforces:

| Rule | Where | Code |
|---|---|---|
| `&null` into `*T` | LiteralTyping, fix-it to `*T?` | SC259E |
| `unsafe *T` to `*T` only by `as *T` in an unsafe context | CastTyping | SC023E |
| `*T` to `unsafe *T` only by `unsafe &x` or `as unsafe *T` in an unsafe context | CastTyping | SC023E |
| implicit conversion between `*T` and `unsafe *T` either way | Conversion | rejected as an ordinary conversion error |
| derived to base | implicit for both kinds | |
| base to derived `*B as *D` | needs a vtable in `B`; the checked form is `as *D?` | SC025E |

Narrowing of `*T?` and the rule that a nullable reached through `->` or a subscript is not narrowed are in [Nullables.md](Nullables.md#passes).

Pointer arithmetic (`p + n`, `p - n`, `++`, `--`) is allowed on a safe pointer as on a raw one ([Operators](ExprTyping.md#expression-typing)); proving the offset stays inside its allocation is Tether's job. Not implemented: provenance. Tether would reject offsetting or dereferencing a safe pointer whose allocation it cannot determine; Sema accepts every `*T` without proof. `*T?` lowers to `::builtin::Null<T>` with a presence flag, so it is twice a pointer's width (`Tests/Codegen/nullable/layout.k` XFAIL). The compiler's own sources use `unsafe *T` throughout and are still to be converted.

## Mechanical guarantees

What the compiler enforces about `const`, receivers and `unsafe` today. The rules themselves (binding versus pointee `const`, `*const T`, `const self`, the rejection of `var x: const T`, unsafe overloads in their own namespace) are the language reference's (`variables.mdx`, `pointers.mdx`, `unsafe.mdx`).

| Guarantee | Enforced by | Code |
|---|---|---|
| a non-`const` method is not called on a `const` object or through `*const T` | OverloadResolution: the candidate is not viable | |
| a `const` field is assigned only by its own record's constructor, once | CtorInitCheck | SC171E |
| a `const` value is never moved from | MoveCheck | |
| a `const fn` reads only its inputs and a `@pure` function writes no memory, allocates and frees nothing and always returns (both become C++ attributes clang optimizes on) | FnPurityCheck | |
| an unsafe cast happens in an unsafe context | CastTyping | SC023E |

Const-correctness is decided while typing, not by a pass of its own. Reassigning a `const` binding and writing through a `*const T` are SC071E (OperatorTyping); calling a method that is not `const` on a `const` object is SC063E with the note "'m' is not const; it cannot be called on a const object" (OverloadResolution, Conversion). A field, tuple element or array element read through a `const` object or through a `*const T` is const at any depth (MemberTyping), so a write to it is SC071E, a method that is not `const` called on it is SC063E, and `&c.v` is a `*const` ([ExprTyping.md](ExprTyping.md#chains)). A `mutable var` field, a static, and what a pointer the object holds points to stay writable.
