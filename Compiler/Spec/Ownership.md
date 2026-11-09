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

User-provided means neither `= default` nor `= delete`. An imported record's facts are clang's (`FFILinkage::ForeignLayout`) plus its imported constructors; an imported template instance that holds (as `value_type`, field or base) a value that cannot be copied cannot be copied either (`_imported_elements`), while one that only points at its argument (`shared_ptr<Mv>`) keeps clang's COPY.

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

`op =` is derived from the transfer constructor (`assign_from`, `assign_form`); writing it is an error. Other declaration rules: a defaulted transfer over a part that cannot transfer that way (SC129E, rule 6), a category weaker than a base's (SC061E, rule 5), a custom destructor with an implicit copy (SC060W, rule 4), and the virtual-destructor rule (SC056E: a class with a non-trivial destructor whose polymorphic base has no virtual destructor). A base is polymorphic when it has a vptr (a virtual method, a virtual base or a polymorphic base; `ClassLifecycle` fact `polymorphic`), so a `derives virtual` edge counts, unlike clang's `-Wdelete-non-virtual-dtor`; a base with no vptr is a mixin and is never deleted through.

### What moves

`moves_on_pass(sc, t)` is true when `t` is a record of category MOVE. Overload resolution binds such an lvalue as an xvalue, and MoveCheck counts the move, both from this one answer. A category that depends on a generic parameter is not MOVE here.

`MoveCheck` (`Compiler/Sema/Check/MoveCheck.k`, CHECK phase, after ClassLifecycle) is the only place that decides a move:

| Rule | Behaviour |
|---|---|
| `@move` parameter | the argument moves, whatever its type; its type must be movable |
| transfer of a MOVE value | moves when passed to a by-value parameter or a C++ `T&&`, initializing a variable, assigned, or returned when it is not a bare local (an expression body's value included); a user operator's operands are its arguments |
| borrow | a C++ `T&` or `const T&` parameter, and a `const` parameter |
| const place | a const value is never moved from |
| temporary | C++ moves it on its own; not recorded |
| imported record with a deleted copy | transferring an lvalue of it is SC182E, before clang would reject the copy |

Each transfer is recorded in `SemaContext::move_sites`.

Pending moves. Two transfers move only if the binding is not read again on any path, including a loop's next iteration: a value whose category its generic instance decides (`var y = x` with `x: T`), and an expansion `xs...` of a forwarding pack. Otherwise they stay copies. Neither marks the binding moved-from, and a binding whose address is taken anywhere in the body (`&x`, `&x.f`, a pointer capture, a C++ `T&` or `@inout` argument) never takes one. A pending transfer that a later read demotes is kept on the function (`FunctionDecl::move_reuse_site`, `move_reuse_read`); at each live instance ConformanceChecking substitutes the value's type and, where the instance's type cannot be copied, reports SC052E at the instance's use with its chain (`_check_reuse`), rather than leaving clang a deleted copy constructor.

Use after move (SC052E). A moved bare local or parameter, or a part of one (`p.a`, `p.a.b`), is moved-from from that point; a later read of the part, something inside it, or the whole binding in the same body is an error. An assignment to it or to something enclosing it clears it; a `var` declaration starts a new binding. At a join, moved on either path means moved.

The dataflow is intraprocedural and path-insensitive. The walk overrides dispatch for the constructs that fork or end a path (`if`, `match`, `try`, `&&`, `||`, loops, `return`, `break`, `continue`, `panic`, a call typed `!`). A loop body is walked twice, the second time with the back edge joined in; diagnostics are deduplicated by (binding, use). A `finally` body is walked at every exit of its block over the state at that exit. The right operand of `&&` moves on one path only, so after `if a && f(x) { return }` `x` is maybe-moved.

Not tracked: a move through a pointer, out of `self`, out of a field of a non-binding place, or out of a capture. Such a site is still cast to `T&&`, so the source is emptied at run time with no diagnostic. A MOVE lvalue that is not a bare binding should be an error requiring an explicit copy.

### Lowering

`CopyMoveLowering` (`Compiler/Sema/Lower/CopyMoveLowering.k`) rewrites each recorded site to `e as T&&` (an xvalue cast to `cxx_rref`), which EmitIR spells `static_cast<T&&>(e)`. Kairo has no `std::move`: the type decides that a transfer moves, and C++ moves an lvalue only when it is cast. Because MoveCheck is the only decider, the cast and the use-after-move check agree. A COPY value needs nothing: C++ calls the record's copy constructor. It runs before any pass that rebuilds an expression, so each recorded node is still in the tree ([Lowering.md](Lowering.md#pass-order)). WhereDispatchLowering, which runs earlier, records a dispatcher's forwarded by-value MOVE parameter in `move_sites`, so it is moved too. NullableTypeLowering runs after it, because a transfer is decided from the value's lifecycle, which ClassLifecycle answers for `T?` from `T`, and a newly minted `Nullable<T>` instance has no facts yet. Choosing a `@copy` constructor at a use, and rejecting a copy of a MOVE class in this pass, are not implemented.

### Parameter passing

A by-value COPY record parameter its function never mutates is passed as `const T&`, so a call borrows the caller's value instead of copying it. A MOVE record keeps its value, since taking ownership is the parameter's point. The decision is ParamPassInference's ([Lowering.md](Lowering.md#passes)).

### Destruction and freeing

The destructor is `fn op finally(self)` (0.2.0; `fn op delete(self)` is an error with a rename fix-it). It is the same member a standalone `finally { }` block lowers to ([Lowering](Lowering.md#finallylowering)), and C++ sees it as `~T`. Kairo has no `delete` expression, so destruction and freeing are separate:

| Spelling | Meaning | Lowers to |
|---|---|---|
| (scope end) | run `op finally` of every local, reverse declaration order | the C++ destructor |
| `x.finally()` | NOT implemented before 0.3 (SC116E; the planned 0.3 design for `x.finally()`) | (error) |
| `@create T(args)` | allocate through the allocator in effect and construct | `kairo::std::create<T>(args)` |
| `@destroy p` | run the destructor of `*p`, then return the memory to the allocator | `kairo::std::destroy(p)` (allocator-routed, so the memory cannot go back to a different allocator than the one that gave it) |
| `@cxx::new T(args)`, `@cxx::new [T; n]` | C++ allocation for memory that crosses into C++; result `unsafe *T` | `new T(args)`, `new T[n]` |
| `@cxx::delete p`, `@cxx::delete [] p` | free C++-allocated memory | `delete p`, `delete[] p` |

The `@cxx::` forms reuse `@create` / `@destroy`'s parsing and constructor resolution but are not routed through the allocator; pairing `@create` with `@cxx::delete` (or `@cxx::new` with `@destroy`) is the caller's error. The array spelling `@cxx::delete [] p` is the one place to change if the implementation settles on another. C++ code reaches Kairo types through the class-scope `operator new` / `operator delete` described in [Codegen](Codegen.md#c-allocation-operators).

## Move-only types

A MOVE value is transferred as above; a NON_TRANSFER value is never transferred. A by-value `const` parameter of a MOVE type takes the value, as for any MOVE record.

### Instances of generic records

A pattern's Unknown facts are the pattern's answer only. A concrete instance of a Kairo generic has facts of its own: the same `_compute` / `_compute_enum` over its pattern's (or selected partial's) members, with every field, payload and base type read through a `Substitution` seeded by `bind_from_record(instance)`. A component that does not substitute stays Unknown. So `Opt<i32>` is COPY and `Opt<Mv>` MOVE. The memo is keyed by the instance decl (one per registry entry) and kept per TU: ClassLifecycle is Sema, the registry is AST and cannot hold its type, and the facts are a pure function of pattern and arguments, so every TU computes the same answer. An imported template's instance keeps clang's facts; a dependent one reads its pattern.

Every reader (MoveCheck, `moves_on_pass`, CopyMoveLowering through `move_sites`, assignment's SC071E, `@copy` / `@move` lifecycle requirements, FeatureGateCheck's non-generic-ADT gate, EnumLayoutLowering, PanicEffectChecking) is handed the instance and reads its facts unchanged.

The declaration rules a generic class skipped on an Unknown (rule 6, rule 5, the virtual-destructor rule) are asked again of each live instance by `ClassLifecycle::instance_failures`, which returns data; ConformanceChecking reports them (`_check_facts`) at the instance's use with label "'X<A>' is instantiated here", the rule's notes, and the instantiation chain ([Generics.md](Generics.md#monomorphization-sync-point)). This happens once per build, when the bounds hold. A failure the pattern already reported is not repeated, and rule 4 (SC060W) is not asked per instance: a warning per instance about a declaration the instance cannot change is noise.

### Library types

`string`, `Vector<T>`, `HashMap<K, V>` and `HashSet<T>` in `Lib/builtin` are COPY (`@copy`, deep copy). The design is MOVE with an explicit `.copy()` (a COPY class may offer `.move_to(&dst)`); a class has one transfer kind. The change waits for self-hosting and needs three Sema changes first:

| Gap | Code | Effect today |
|---|---|---|
| The container arm of `facts_of_type` keeps `copyable` / `movable` Yes | `ClassLifecycle.k:558` | a class holding a MOVE `string` would not become MOVE |
| A MOVE lvalue that is not a bare binding is recorded as a move without a diagnostic; a const place returns silently | `MoveCheck::_transfer_checked` | `return self.name` would empty the field; a copy out of a const place reaches clang as a deleted copy |
| A struct holding a MOVE field is accepted and copied | no rule | `structures.mdx` says structs are `memcpy`-copied |

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

Pointer arithmetic (`p + n`, `p - n`, `++`, `--`) is allowed on a safe pointer as on a raw one ([Operators](ExprTyping.md#expression-typing)); proving the offset stays inside its allocation is Tether's job. Not implemented: provenance. Tether would reject offsetting or dereferencing a safe pointer whose allocation it cannot determine; Sema accepts every `*T` without proof. `*T?` lowers to `::builtin::Nullable<T>` with a presence flag, so it is twice a pointer's width (`Tests/Codegen/nullable/layout.k` XFAIL). The compiler's own sources use `unsafe *T` throughout and are still to be converted.

## Mechanical guarantees

What the compiler enforces about `const`, receivers and `unsafe` today. The rules themselves (binding versus pointee `const`, `*const T`, `const self`, the rejection of `var x: const T`, unsafe overloads in their own namespace) are the language reference's (`variables.mdx`, `pointers.mdx`, `unsafe.mdx`).

| Guarantee | Enforced by | Code |
|---|---|---|
| a non-`const` method is not called on a `const` object or through `*const T` | OverloadResolution: the candidate is not viable | |
| a `const` field is assigned only by its own record's constructor, once | CtorInitCheck | SC171E |
| a `const` value is never moved from | MoveCheck | |
| a `const fn` reads only its inputs and a `@pure` function writes no memory, allocates and frees nothing and always returns (both become C++ attributes clang optimizes on) | FnPurityCheck | |
| an unsafe cast happens in an unsafe context | CastTyping | SC023E |

Not implemented: `ConstChecking` (`Compiler/Sema/Check/ConstChecking.k`) is a stub and is not scheduled (`Sema.k`, a TODO before the Typed phase). Reassigning a `const` binding or writing through a `*const T` passes Sema and is rejected by clang at codegen. Every such clang rejection is a semantic-independence failure.
