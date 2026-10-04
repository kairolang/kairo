# Tether

Tether is a compile-time proof engine. For every pointer dereference in the program, it attempts to
prove that the access is safe. When it succeeds, no runtime code is emitted. When it can prove
everything except one residual property, it emits the minimal runtime code required to discharge
exactly that property and nothing else. When it cannot prove the access safe and no runtime check
or code transformation can establish safety, it is a hard compile error.

The system is not a pointer tracker that decides where to insert checks. It is a proof engine that
asks one question at every dereference:

> What is the strongest proof I have that this access is safe?

The answer to that question and only the answer determines what code is generated. Tether never
asks "should I insert a check here." It asks "which proof obligations remain after static analysis,"
and emits code for the residual.

Tether operates on safe pointers (`*T`) only. Raw pointers (`unsafe *T`) carry no obligations and are
never analyzed. The programmer owns their correctness.

> [!WARNING]
> Tether is not yet implemented. The compiler is currently in the **Stage 1** parsing phase.
> Tether development begins at **Stage 2**. The roadmap:
>
> - **Stage 0** (stable): C++ compiler, transpiles Kairo to C++.
> - **Stage 1** (current): self-hosted compiler frontend parser, AST, diagnostics.
> - **Stage 1.5**: Stage 1 migrated to Kairo's standard library, fully self-hosting.
> - **Stage 2**: compiler rewritten using Kairo's extended feature set. **Tether work begins here.**
>
> This page describes the intended design and target semantics. The analysis is the target, not the
> current state. A separate formal paper will carry the full proofs; this page states the model and
> the obligations precisely enough to implement against, but is not itself the proof.

---

## The Dereference Obligation

Every safe-pointer dereference `*p` where `p: *T` carries a single safety obligation, stated as a
conjunction of independent clauses. The access is sound if and only if every clause holds:

```
deref(p: *T) is sound  ⟺
    epoch(prov(p)) = live_epoch(alloc(prov(p)))            (C1) provenance / use-after-free
  ∧ 0 ≤ byte_offset(p)                                      (C2) no underflow
  ∧ byte_offset(p) + sizeof T) ≤ size(alloc(prov(p)))       (C3 no overflow / bounds
  ∧ p ≠ null                                                (C4) nullability
  ∧ (¬shared(alloc(prov(p))) ∨ readonly_extent ∨ synced)    (C5) data-race freedom
  ∧ (¬tainted(prov(p)) ∨ laundered(p))                      (C6) provenance integrity
```

Where:

- `prov(p)` is the **provenance** of `p`: which allocation it points into and the epoch at which
  that pointer value was derived.
- `alloc(prov(p))` is the originating allocation; `size(...)` is its byte size; `live_epoch(...)`
  is its current generation (see [Provenance and Epochs](#provenance-and-epochs)).
- `byte_offset(p)` is the offset of `p` from the allocation base, in bytes. Stated in bytes so the
  `sizeof T` scaling in C3 is explicit and the element-count-times-size multiply cannot silently
  overflow.

Each clause is a distinct **proof domain** with its own analysis. Tether discharges as many clauses as
it can statically. The clauses that remain the **residual** determine what is generated. The
mapping from a residual clause to a code-generation response is the entire specification of Tether's
behavior, and it is given in [The Residual Table](#the-residual-table).

The critical design point: the obligation is checked at the **dereference**, never at pointer
arithmetic. Forming a pointer value (`var q = p + i`) computes a new provenance fact and emits no
code. Only `*q` discharges the obligation against that provenance. This lets Tether carry symbolic
offset information through arbitrarily many SSA transformations and discharge or eliminate the
obligation as late as possible see [Pointer Arithmetic](#pointer-arithmetic).

---

## The Proof Lattice

Tether is a forward dataflow analysis over the program's SSA graph. For each pointer at each program
point it computes a **fact tuple**: one element per clause domain, recording how strongly that
clause is currently proven.

### Per-clause lattice

Each clause domain has a small lattice of proof states. For the structural clauses (C1, C4, C6) the
lattice is height-2:

```
        Proven           (the clause is statically discharged here)
          ⊏
        Residual         (the clause must be discharged at runtime, or is a hard error)
```

For the bounds clause (C2/C3) the lattice is height-3, because bounds admits an intermediate state
where the property is provable over a region rather than at a single point:

```
        Proven                  (offset statically known in range, no code)
          ⊏
        HoistableResidual       (provable over a loop/region, one check at region entry)
          ⊏
        DynamicResidual         (must check at this specific dereference)
```

`Proven` is the strongest (least) element. The order `⊑` means "no more proven than." `Residual`
and `DynamicResidual` are the weakest elements of their domains.

### The product lattice

The fact tuple for a pointer is an element of the product lattice

```
    L  =  L_C1 × L_C2C3 × L_C4 × L_C5 × L_C6
```

ordered componentwise. The product of finite-height lattices is itself a finite-height lattice; the
height of `L` is the sum of the component heights, which is a small constant (independent of program
size). The transfer functions for each IR operation are **monotone** with respect to `⊑`: an
operation never increases the proof strength of a clause it has no evidence for, and joining facts
at control-flow merge points takes the weaker (less proven) state.

Monotone transfer functions over a finite-height lattice means the Kleene iteration reaches a fixed
point in a bounded number of passes (bounded by the lattice height times the number of program
points). **The analysis always terminates.** This is the only termination argument Tether needs;
there is no widening, no heuristic iteration cap required for soundness. (A pass ceiling exists for
*interprocedural* recursion, see [Summaries](#tether-summaries) but it degrades precision, never
soundness: hitting it demotes clauses to Residual, which is always safe.)

### Classifying a dereference

The four named proof states from Tether's vocabulary `PROVEN_STATIC`, `PROVEN_RANGE`,
`REQUIRES_DYNAMIC`, `UNSAFE` are not elements of the lattice. They are a **classification of the
residual set** at a dereference site, derived from the fact tuple:

| Residual set at `*p`                                  | Classification     | Emitted                          |
|-------------------------------------------------------|--------------------|----------------------------------|
| empty (all clauses `Proven`)                          | `PROVEN_STATIC`    | nothing                          |
| `{bounds}` only, and bounds is `HoistableResidual`    | `PROVEN_RANGE`     | one assertion at region entry    |
| any other non-empty residual                          | `REQUIRES_DYNAMIC` | per-clause runtime code at `*p`  |
| `p` is `unsafe *T`                                    | `UNSAFE`           | nothing (analysis not run)       |

The compiler walks every dereference, reads its residual set, classifies it, and emits accordingly.
The overwhelming majority of dereferences in well-structured code classify as `PROVEN_STATIC` and
generate a bare `mov`.

---

## The Residual Table

A residual clause does not have a uniform response. Bounds falls back to a runtime check; a lost
provenance is a hard error; a nullable dereference is a hard error in release but a transform in
debug. The response is **per-clause**, and the full mapping is the specification of the system:

| Residual clause / condition                                  | Response                                              | Tier |
|--------------------------------------------------------------|-------------------------------------------------------|------|
| **C3 bounds**, range residual                                | hoisted or local bounds check, **both modes**        | R    |
| **C1 epoch (UAF)**, provenance intact                        | epoch comparison at deref, **both modes**            | R    |
| **C1 epoch (UAF)**, provenance lost                          | hard error, both modes                                | N    |
| **C4 nullability**                                           | debug: insert null check + panic; release: hard error | P    |
| **Ownership/escape**, value is heap-promotable               | debug: promote to smart pointer; release: hard error  | P    |
| **Stack escape**, value is heap-promotable                   | debug: rewrite to heap alloc + promote; release: error| P    |
| **Stack escape**, value not heap-promotable                  | hard error, both modes                                | N    |
| **Scoped-allocator escape**                                  | hard error, both modes                                | N    |
| **Opaque-container / untraceable escape**                    | hard error, both modes                                | N    |
| **Iterator invalidation** (even when traceable)              | hard error, both modes                                | N    |
| **Moved-from use**                                           | hard error, both modes                                | N    |
| **C5 race**: 2nd writer to a shared allocation               | hard error, both modes                                | N    |
| **C5 race**: any access-clause residual on shared *mutable*  | hard error (strict mode), both modes                  | N    |
| **C5**: residual on shared *read-only* allocation            | normal tier-R check applies                           | R    |
| **C6 taint**, provenance recoverable                         | runtime check                                         | R    |
| **C6 taint**, provenance opaque                              | hard error, demand `unsafe` / launder               | N    |

The three response classes are:

- **Tier R, runtime-check fallback, both debug and release.** The residual is a property that can
  be established by a cheap, side-effect-free runtime check. The program is unchanged; it pays a
  comparison. **This is the only tier that emits runtime code in a release build.**
- **Tier P, debug transforms, release hard-errors with the fix.** The residual can be established
  by *changing the program* (inserting a smart pointer, lifting a stack value to the heap, inserting
  a null guard). Debug performs the transformation and warns. Release refuses, because the
  transformation would be a hidden allocation or hidden control flow in a release binary, and emits
  a hard error showing the exact source change the programmer must make.
- **Tier N, never allowed, hard error in all modes.** No runtime check and no transformation can
  establish safety, because the information required to even *form* a check is absent (lost
  provenance, undeterminable ownership) or the property is genuinely uncheckable (a data race is UB
  that a single-threaded check cannot rule out).

The organizing principle in one sentence: **debug is allowed to rewrite your code to make it work;
release makes you write the code that debug would have written; some things are wrong no matter who
writes them.**

### Why bounds is Tier R but nullability is Tier P

Both are access-safety clauses. They differ in the *nature of the fallback*.

A bounds check (`assert(off < count)`) does not change the meaning of the program. `buf[i]` still
means `buf[i]`; the access either proceeds or panics on exactly the inputs that would have been UB.
Emitting it in release costs one predictable branch and is the price of permitting safe pointer
arithmetic with runtime indices. That is the entire point of Kairo's pointer model see
[Pointer Arithmetic](#pointer-arithmetic).

A null fallback (`if (p == null) panic()`) *introduces a control-flow edge that is not visible in
the source*. A release binary that silently panics on a null dereference the programmer never
guarded has hidden control flow, which violates the same guarantee that forbids hidden allocation.
So nullability is Tier P: debug inserts the guard so you can keep moving, release makes you either
prove non-null or handle the null case explicitly.

---

## Pointer Arithmetic

Kairo permits pointer arithmetic on safe pointers. This is a deliberate departure from Rust's safe
subset, and Tether is what makes it sound.

```kairo
var a: *i32 = @create i32(120)
*(a + 10) = 19
```

At this dereference Tether knows the allocation base, element type (`i32`), element size (4 bytes), and
element count (120). The offset 10 is a compile-time constant. C3 reduces to `10 < 120`, proven
statically. C1, C2, C4, C5, C6 are all proven. Residual set is empty -> `PROVEN_STATIC`:

```
mov [rdi + 40], 19
```

No check. No metadata. Nothing.

### Runtime offset

```kairo
var i = std::input<i32>()
*(a + i) = 19
```

Now C3 cannot be proven (the offset is runtime data) and C2 cannot be proven (`i` is signed and may
be negative). Every other clause holds. Residual set is `{bounds}`, not hoistable -> `REQUIRES_DYNAMIC`:

```asm
assert((0 <= i) && (i < 120));
mov [rdi + i*4], 19
```

Note both halves of the check. **`i < 120` alone is unsound** for a signed offset: a negative `i` passes it and reads out of bounds backward. The canonical obligation is `0 <= off AND off + sizeof T) <= size`, and Tether emits both comparisons unless it can prove non-negativity separately (e.g. `i` is unsigned, or dominated by a `i >= 0` guard. For an unsigned offset the lower-bound clause C2 is discharged statically and only the upper comparison is emitted.

The check is on the **offset**, computed before the pointer is formed never on the resulting
pointer address. Checking `result_ptr < end` after forming the pointer is the bypassable version:
if `i * sizeof T` overflowed the address width, the formed pointer can wrap below `end` and pass a
post-hoc check. Tether checks the offset in a width that cannot wrap for any in-allocation offset
(the valid offset range is bounded by `size`, which is known), then forms the pointer.

### Hoisting

```kairo
for i in 0..<120
    *(a + i) = 0
```

Tether proves `0 <= i < 120` holds for the entire loop body from the loop's induction structure. The
bounds clause is `HoistableResidual` if it is the only residual -> `PROVEN_RANGE`. The per-iteration
check is lifted to a single check before the loop:

```asm
loop:
    mov [rdi + i*4], 0      ; no per-iteration check
```

And when the loop bound and the allocation size derive from the same value:

```kairo
var n = std::input<i32>()
var a: *i32 = @create i32(n)
for i in 0..<n
    *(a + i) = 0
```

Tether proves `loop_bound == allocation_count` provided `n` and `a` are not mutated between the
allocation and the loop (see the immutability requirement under [Threading](#threading) and
[Summaries](#tether-summaries)). The entire loop's bounds obligation collapses to one check:

```asm
assert(n <= allocation_count);   ; trivially true here; elided
loop:
    mov [rdi + i*4], 0
```

One branch (or zero), discharging millions of accesses. This is the same class of transformation an
optimizing backend already performs; Tether's contribution is proving it is *sound* to do so under the
language's safety guarantee, not merely profitable.

### Forming versus dereferencing, and one-past-the-end

`var q = a + i` produces a pointer value and emits no code, regardless of whether `i` is in range.
The obligation attaches to `*q`, not to the formation of `q`.

Forming a pointer anywhere in `[base, base + count]` inclusive of the one-past-the-end address
is legal and emits nothing. This is required: idiomatic range loops compare against a one-past
pointer (`while p < end`), and that pointer must be formable and comparable without being undefined.
Forming a pointer *beyond* one-past carries a "not dereferenceable" mark in its provenance; the
pointer value is defined and may be compared, but any attempt to dereference it fails C3. Comparison
of two pointers is defined when they share provenance, or when both lie in `[base, base + count]`.

This is a larger expressiveness envelope than safe Rust, which routes all of this through slices and
iterators. The safety **guarantee** is the same no out-of-bounds access reaches memory but the
cost model is pay-only-when-unprovable rather than always-checked-unless-elided, and the surface
syntax is C-style arithmetic rather than slice methods.

> Tether does not present an unprovable bounds access as a *warning*. The programmer did nothing
> questionable; the allocation size is simply runtime data. It is reported as an **optimization
> remark** when remarks are enabled, naming the fact that blocked the proof:
> `[amt] runtime bounds check at <loc>: allocation size depends on runtime value 'n'; cost: one
> check; to eliminate: bound the index by a compile-time constant or hoist the proof.`

---

## Provenance and Epochs

Use-after-free is not a separate debug-only feature. It is clause C1 of the dereference obligation,
and it is discharged by the same lattice machinery as bounds.

Every allocation carries a **generation** (an epoch) in its provenance fact. Any operation that can
free or relocate the allocation increments its epoch:

- explicit `@destroy` or `@free`
- scope exit of the owning binding
- ownership transfer (move) out of the owning binding
- reallocation (e.g. a `Vec` growing its backing buffer)
- the close of a scoped allocator that owns the allocation

A pointer value derived at epoch *e* records *e* in its provenance. Clause C1 requires
`epoch(prov(p)) == live_epoch(alloc(prov(p)))` at the dereference. Statically, most epochs are
provably equal there is no intervening freeing operation between derivation and use so C1 is
`Proven` and emits nothing. When Tether cannot prove the epochs equal (a free *might* have happened on
some path), C1 is residual:

```kairo
var buf: *i32 = @create i32(64)
var p = buf + 5
realloc(buf)        // increments buf's epoch
*p = 1              // C1 residual: p was derived at the old epoch
```

If provenance is intact (Tether still knows which allocation and can read the live epoch), C1 residual
is **Tier R**: an epoch comparison at the dereference, in both modes. If provenance has been lost
entirely (the pointer was laundered through an untracked path and Tether no longer knows the
allocation), there is nothing to compare against and it is **Tier N**: a hard error.

Folding UAF into the same obligation as bounds is what makes the architecture scale: there is one
analysis, one lattice, one residual table, and "use-after-free detection" is not a bolted-on
sanitizer but a clause that is either proven away or checked like any other.

---

## Ownership and Promotion

Provenance and epochs govern whether an *access* is safe. A separate analysis governs *where a value
lives and who frees it*. Its residuals are Tier P (transformable) or Tier N (unfixable), never Tier
R there is no runtime check for "who owns this."

When Tether determines that a heap pointer needs ownership semantics, it selects a smart pointer type
from the pointer's whole-program usage. In **debug** it performs the promotion and warns; in
**release** it emits a hard error naming the type to annotate.

### `std::Unique<T>` single owner

Exactly one live binding holds the pointer at any point. Ownership may transfer between scopes; the
count of live owners is always one.

```kairo
fn make_config() -> *Config {
    var cfg = @create Config(8080)
    return cfg
    // debug: promote cfg -> std::Unique<Config>
    // release: error, annotate the return type
}
```

### `std::Shared<T>` multiple owners

Multiple live bindings refer to the same allocation and single ownership cannot be proven. The
allocation is reference-counted; the object is destroyed when the last `Shared` reference's scope
ends.

```kairo
fn share_config(a: *Server, b: *Server) {
    var cfg = @create Config(8080)
    a.config = cfg
    b.config = cfg
    // debug: promote cfg -> std::Shared<Config>
}
```

A short-lived alias that dies before the owner escapes does **not** force `Shared`. The trigger is
not "multiple pointers exist" but "multiple pointers are *live* at a point where shared ownership is
required for safety."

```kairo
var cfg = @create Config(8080)
{
    var tmp: *Config = cfg
    validate(tmp)
}                        // tmp is dead here
return cfg               // single owner at the escape -> Unique
```

### `std::Weak<*T>` back-reference

A pointer that, promoted to `Shared`, would close a reference cycle (A -> B -> A). `Weak` does not
contribute to the count and does not keep the target alive; access requires a liveness check.

```kairo
class Node {
    var child: *Node
    var parent: *Node     // points back at the owner -> Weak
}
```

### No promotion

A pointer whose lifetime is fully contained, or provably bounded by its referent's lifetime, stays a
plain `*T` with no overhead:

```kairo
fn process() {
    var data = @create Buffer(1024)
    fill(data)
    consume(data)
    @destroy data    // fully contained -> plain *T
}
```

### Field access and interior pointers

`foo.bar.baz` is `PROVEN_STATIC` when `foo` is non-null and the field offsets are static: the access
inherits `foo`'s provenance with a constant offset, and its obligation is exactly `foo`'s obligation.

Taking an interior pointer `var p = &foo.bar` creates a new pointer whose provenance is derived from
`foo`'s allocation at `foo`'s current epoch. Dropping or moving `foo` increments that epoch, so a
later `*p` fails C1 by the same mechanism as any other use-after-free. Interior pointers are not
special-cased; they reuse the epoch machinery.

---

## Stack Pointers

A stack value has no heap allocation behind it, so it cannot be promoted to a smart pointer. But the
(B) model splits stack escape into two cases by whether the value is **heap-promotable** that is,
whether Tether can mechanically rewrite the stack allocation into a `@create` call.

**Heap-promotable escape Tier P.** A plain local whose address escapes via return or store, where
the value's type can be heap-allocated:

```kairo
fn make() -> *i32 {
    var x = 42
    return &x
    // debug: rewrite `var x = 42` into `var x = @create i32(); *x = 42`,
    //        then promote the escaping pointer (Unique)
    // release: hard error, heap-allocate explicitly or restructure
}
```

In debug, Tether lifts `x` to the heap and the escape becomes a legal ownership transfer. In release
this is a hard error, because silently turning a stack allocation into a heap allocation in a
release binary is exactly the hidden allocation the language forbids. The diagnostic shows the fix:

```
error[Tether]: address of stack local 'x' escapes its scope
  --> src/m.k:3:12
   3 |     return &x
     |            ^^ 'x' is stack-allocated and destroyed at end of make()
  note: in debug, Tether would heap-promote: var x = @create i32()
  help: allocate on the heap explicitly, or restructure to avoid the escape
```

**Non-promotable escape Tier N.** A borrow with no value to lift (a pointer into a structure Tether
cannot heap-allocate, an escape into an opaque sink where Tether cannot even establish the
heap-allocation pattern) is a hard error in both modes. There is nothing to transform.

Dangling within a function is likewise a hard error in both modes the value is gone, there is no
allocation to lift, and the access is statically known to be invalid:

```kairo
fn also_bad() {
    var p: *i32
    {
        var x = 42
        p = &x
    }                  // x destroyed here (epoch incremented)
    *p = 10            // hard error: p's provenance epoch is stale
}
```

---

## Threading

Kairo owns its threading runtime. All concurrency flows through `thread` and `spawn`, and **only
functions marked `async` may be threaded or spawned**. `await` operates on the result of a `thread`
or `spawn` call and is the join point.

This is what makes static race-freedom tractable. Every concurrent edge in the program is a
syntactic `thread`/`spawn` call site there are no hidden threads, no callbacks invoked from
another thread, no library spawning work behind your back. Tether knows exactly where every thread
boundary is, which is the precondition for proving the absence of races rather than checking for
them at runtime.

> [!NOTE]
> The precise distinction between `thread` and `spawn`, and the synchronization primitives that
> establish happens-before, depend on Kairo's concurrency runtime, which is not yet finalized. The
> **analysis shape below is fixed**; the runtime seam is marked where it occurs. A synchronization
> primitive, when it lands, is anything that injects a happens-before edge Tether can observe; crossing
> one re-permits an otherwise-forbidden access.

### Strict mode

Between a `thread`/`spawn` and its corresponding `await` (the task's **extent**), Tether enters a
stricter analysis mode. Any allocation reachable by a pointer captured into the task is a **shared
allocation** for that extent, and every access to it is analyzed under the rules below instead of
the single-threaded rules.

The defining rule of strict mode: **Tier R collapses into Tier N for shared mutable allocations.** A
runtime check reads metadata the allocation's size, its epoch tag and in a threaded extent that
metadata can be mutated by another thread, so the check *itself* races. You cannot check your way to
safety across threads. A clause that would fall back to a runtime check in single-threaded code must
instead be proven statically for a shared mutable allocation, or it is a hard error.

The one exception: if a shared allocation is provably **read-only** for the entire extent (no task
holds a mutating pointer to it), its metadata is stable, no thread writes it, and ordinary Tier-R
checks on it are sound again. Tier R survives only on read-only shared state.

### The rule set

1. **Single writer per shared allocation.** Within an extent, at most one task may hold a *mutating*
   (`*T`, non-`const`) pointer to a given allocation. The second live writer main+task or
   task+task with no synchronization between them is a hard error. This is write-exclusivity, not
   Rust's full write-xor-read: you may have one writer and nothing else, or many readers.

2. **Many readers OR one writer, across the boundary.** This is the single point where Kairo adopts
   exclusivity and it applies **only inside a threaded extent**. Single-threaded code retains
   arbitrary mutable aliasing. A shared allocation in an extent is either all-readers (every capture
   `*const T`, no check, free shared reads) or exactly one writer and no other accessor. A reader
   and a writer to the same allocation with no synchronization is a read/write race a hard error.
   The asymmetry with single-threaded aliasing is deliberate: a data race is UB that no runtime check
   can rule out, so the rule tightens precisely at the boundary where optimism becomes unsound.

3. **No Tier-R fallback for shared mutable state.** Bounds, epoch/UAF, and nullability must be proven
   statically for any shared mutable allocation, or the access hard-errors. On a read-only shared
   allocation, normal Tier-R checks apply (rule 2 makes the metadata stable).

4. **Captured-stack escape from a task Tier N always.** A pointer to the spawning frame's stack,
   captured into a task that can outlive the frame (detached, or awaited after the frame returns), is
   a hard error. Heap-lifting the value does not fix a cross-thread lifetime, so this is never
   promotable. The fix is capture-by-transfer (the task owns its copy) or an explicit heap allocation
   moved into the task.

5. **What may cross the boundary.** A value captured by transfer has its ownership *fully*
   transferred the parent cannot touch it after the spawn. A value captured by address makes its
   allocation shared, subject to rules 1-3. A pointer into a **scoped allocator** cannot be captured
   into a task that outlives the allocator scope (Tier N the arena frees it, and the free also races
   the task). A `NON_TRANSFER` type cannot be transfer-captured into a task at all (nothing to
   transfer); it may only be shared read-only by address.

6. **`await` re-establishes facts.** `await` is a happens-before edge. After it, the joined task's
   writes are visible and ordered, its captured pointers are released, and the allocations it touched
   return to single-threaded analysis. An allocation that was demoted to "shared, read-only" inside
   the extent may be a normal mutable `*T` again after the `await` that joins its only other
   accessor. Strict mode is scoped to the extent, not sticky for the rest of the program.

7. **Detached tasks (never awaited).** With no join there is no happens-before edge, so the task's
   captured allocations are shared for the rest of the program (or until the task provably ends,
   which Tether usually cannot prove). Any allocation a detached task captures by pointer and that
   anyone writes after the spawn is a hard error. The clean pattern detached tasks capture by
   value only, owning everything they touch is recommended explicitly.

### Sharing syntax

For **closures and lambdas**, read-only sharing across a thread boundary is expressed by capturing
with `const *` and nothing else. A `const *` capture is a `*const T` into the captured allocation;
it cannot mutate the target, which is exactly what rule 2 requires for free shared reads. A plain
`*` (mutating) capture into a task makes the allocation a shared *mutable* allocation and triggers
the single-writer analysis.

For **functions marked `async`**, the read-only guarantee is carried in the parameter type. The
pointer parameter is pointer-to-const, so the threaded body cannot mutate the caller's value through
it:

```kairo
fn foo(a: *const i32) async -> i32 {
    // reads through `a`; *a = ... would not compile
    return *a + 1
}

var fut = thread foo(&x)    // begins executing immediately
var res = await fut         // join point, happens-before edge; x is read-only over the extent
```

Here `x`'s allocation is shared read-only for the extent of `fut` (because `foo`'s parameter is
`*const i32`), so the parent reading `x` during the extent is sound. Had `foo` taken `a: *i32` and
written through it, `x` would be a shared *mutable* allocation and the parent touching `x` before the
`await` would be a hard error under rule 2.

The borrow is live from the `thread`/`spawn` call to the matching `await`. Parent access to a
shared-*written* allocation inside that window is a hard error this is the core threading rule, and
the single-writer and reader/writer rules are its consequences.

---

## Allocators

### Global allocator

The default for `@create T()` and all standard-library heap operations. Overridable with
`@mem::set_allocator(MyAllocator)` at the top of a file.

**Intentional friction**: the override must appear at the top of *every file in the dependency graph* it affects. A library that sets a global allocator forces the annotation onto every transitive dependent. This keeps global-allocator changes visible and pushes library authors toward scoped allocators.

### Scoped allocator

An allocator with RAII semantics it frees everything it allocated when it leaves scope. Set with
`@mem::set_scoped_allocator(MyAllocator)` on a function or block.

```kairo
@mem::set_scoped_allocator(ArenaAllocator)
fn process_frame() {
    var a = @create Mesh(vertices)
    var b = @create Texture(pixels)
    // freed wholesale when process_frame returns
}
```

A pointer allocated through a scoped allocator that escapes the allocator's scope is **Tier N** a hard error in both modes. The arena frees the memory at scope end; no smart pointer and no runtime check rescues a pointer to freed arena memory (and across threads, the free races the access). The escape increments the allocation's epoch at the scope close, so the escaping pointer fails C1 by the same machinery as any other dangling pointer. The only fix is restructuring: allocate through the global allocator, or move the scoped boundary outward.

### Freestanding allocator

A scoped-allocator variant for embedded and bare-metal targets, conforming through `static` functions only no indirection, no vtable. The compiler replaces `@create T()` with a direct static call plus placement construction. Tether treats freestanding allocators identically to scoped allocators for lifetime tracking; the difference is a codegen concern.

---

## Destruction Timing

Where Tether places a value's destruction depends on whether the destructor is observable.

**Trivial destructors** (no observable side effect just memory to reclaim) run at **last use**. Tether places the `@destroy`/`@free` as early as the final use permits, since reclaiming memory after the last use is indistinguishable from reclaiming it at the scope brace:

```kairo
var foo = @create SomeClass()    // trivial destructor
use(foo)
// @destroy foo inserted here
std::println(10)
```

**Non-trivial destructors** (a user-defined `op delete`, or any member with one file close, lock release, flush, disconnect) run at the **end of the owning binding's lexical scope**, in reverse declaration order. Tether does not move these to last use:

```kairo
fn example() {
    var cfg = @create Config(8080)    // side-effecting destructor
    use(cfg)
    std::println(10)
}
// cfg's destructor runs here, at the brace not after use(cfg)
```

This is the "predictable from source" guarantee: any observable destructor side effect fires at the scope brace exactly as written. `finally` blocks, lock guards, and `NON_TRANSFER` scope guards depend on it.

**Shared objects** separate two events. The **refcount decrement** happens at each `Shared` binding's own scope boundary, in reverse declaration order. The **object destructor and deallocation** happen once, when the last live `Shared` reference's scope ends and the count reaches zero which is not necessarily the last-declared binding in any single scope. Reason about shared destruction as "when the final owner goes away," not "reverse declaration order of the binding in front of me." `Weak` scope exit does not touch the count; a `Weak` simply becomes invalid once the target is freed.

## Delete Operation

`delete` in kairo does not free memory. It is a **destruction operation** that runs the destructor and any side effects, but does not reclaim the allocation. Meaning if the class can be re-constructed with a separate function call, the memory is still valid and can be reused. The `delete` operation is used to explicitly clean up resources without deallocating the memory, which is useful in certain scenarios where you want to manage memory manually or reuse it.

```kairo
class MyClass {
    var data: *i32? = null

    fn MyClass(self) = default

    fn init(self) {
        data = std::alloc<i32>(10) // 10 i32's allocated
    }

    fn op delete(self) {
        if (data != null) {
            @destroy data
            data = null
        }
    }
}

var obj = MyClass() // stack allocated the object itself
obj.init() // allocate memory for data
// do something with obj.data
delete obj // runs the destructor for obj and frees data, but does not free obj itself
obj.init() // can re-initialize obj and reuse the memory
```

`delete` is supposed to be designed in a idempotent way, meaning that it can be called multiple times on the same object without causing undefined behavior. The first call to `delete` will run the destructor and free the resources, while subsequent calls will have no effect since the object is already destroyed. This allows for safe cleanup of resources without worrying about double deletion or dangling pointers.

---

## Copy Elision

For COPY types, Tether may emit a move instead of a copy when it proves the source is unused after the transfer **and** the elision is unobservable. Elision means the source's destructor runs at the transfer point instead of at its own scope exit; Tether performs it only when the destructor's observable effects do not depend on that timing trivial destructors, or effects (a `free`, a refcount decrement) that produce identical observable behavior either way.

If the destructor has timing-sensitive side effects a flush, a lock release, a log line Tether does not elide. The copy is preserved and the source is destroyed at its lexical scope exit as written. Elision is silent precisely because it is only applied where it cannot be observed. The programmer neither opts in nor controls it, and it is never applied if the move constructor is deleted.

---

## C/C++ Interop

The FFI boundary is where Tether's facts run out, and the cost model has an honest asterisk: pointers crossing the boundary carry no provenance Tether can trust, so accessing them in safe code is not free.

### Inbound pointers are tainted

A pointer that enters Kairo from C++ has **no provenance** Tether does not know its allocation, size, or epoch. Such a pointer is *tainted* (clause C6). Dereferencing a tainted pointer in safe code cannot be `PROVEN_STATIC`. If Tether can recover enough provenance to form a check, the dereference is Tier R; if the provenance is fully opaque, it is Tier N a hard error demanding an `unsafe` block or an explicit `assume`/launder that transfers responsibility to the programmer.

A pointer that acquires its provenance *inside* an `unsafe` block carries the same taint when it flows back into safe code: unsafe is allowed to *narrow* where checks vanish, but it does not let an untracked pointer leak into a safe dereference as if it were proven.

### Outbound pointers freeze their epoch

A Kairo pointer handed to C++ has its allocation's epoch frozen pessimistically: Tether must assume C++ may free, relocate, or retain it. On return from the FFI call, all optimistic facts about that allocation are erased unless an annotation says otherwise. This is unavoidable Tether genuinely lacks the proof and it is where the "as fast as unchecked C++" property does not hold: at the interop boundary you pay, because the proof is on the other side of a wall Tether cannot see through.

### Smart-pointer and reference parameters

C++ functions using smart-pointer or reference types map automatically and require no `unsafe`:

| C++ type             | Kairo Tether type            | Requires `unsafe` |
|----------------------|---------------------------|-------------------|
| `std::unique_ptr<T>` | `std::Unique<T>`         | No                |
| `std::shared_ptr<T>` | `std::Shared<T>`         | No                |
| `std::weak_ptr<T>`   | `std::Weak<*T>`           | No                |
| `T&`, `const T&`     | `*T`, `*const T`          | No                |
| `T&&` (move ref)     | `*T` (ownership transfer) | No                |

A mismatch between Tether's promotion and the C++ signature is a compile error.

### Raw-pointer parameters and shallow analysis

C++ functions taking raw pointers (`T*`, `void*`) require an `unsafe` block; Tether does not track across the boundary. For raw FFI calls where the C++ source is visible via the imported header, Tether performs a **one-level** heuristic: if the function only dereferences the pointer without aliasing, storing, or forwarding it, the call may be classified safe without `unsafe`. The analysis does not recurse. If the body is not visible (forward-declared, compiled library), all raw-pointer parameters are opaque and `unsafe` is required.

---

## Generic Code

Tether analyzes each monomorphization with full concrete type information generics are not an opaque boundary:

```kairo
fn <T> take_ownership(x: *T) {
    // x is the sole pointer to the allocation after this call
}

fn caller() {
    var cfg = @create Config(8080)
    take_ownership(cfg)
    // ownership transferred; using cfg after this is a compile error
}
```

If `T` has a `@move` transfer constructor, Tether tracks the transfer through the move; if `T` is
`@copy`, Tether knows both source and destination are live after the copy. Each instantiation is
analyzed as if it were a hand-written concrete function.

---

## .amt Summaries

Whole-program analysis cannot re-walk every callee at every call site. Each translation unit produces a `.amt` summary alongside its object file, and the link pass consumes all summaries to resolve cross-TU pointer flows. The summary is what lets a caller discharge a callee's obligations without re-analyzing its body.

### Summary contents

A function's summary records four sections per pointer parameter and for the function's effect on reachable state:

- **Requires** preconditions the caller must discharge before the call (e.g. *`ptr` in allocation, access ≤ 16 bytes*).
- **Guarantees** postconditions the caller may assume after the call (e.g. *`ptr` unchanged*).
- **Preserves** arguments and state the function provably does not mutate. Hoisting reads this: the `loop_bound == allocation_count` proof requires that an intervening call **Preserves** the size variable.
- **Escapes** what the function retains beyond its own frame (stores, returns, captures). Lifetime analysis reads this.

`Escapes` defaults to *everything* and `Preserves` to *nothing* when analysis is incomplete the summary fails **closed**. An incomplete summary costs precision (more residual, more checks or errors), never soundness.

The caller-discharges-obligation model: when a pointer flows into a function, Tether consumes the summary rather than the body. If the caller has already proven the `Requires`, the checks are skipped; if it cannot, Tether emits one assertion before the call to establish the precondition. Tether does not need to look inside the callee.

### Summaries are proof certificates, not caches

A summary is only sound if it is **correct and current**. A stale summary one whose source changed
but whose summary was not regenerated silently disables checks at every call site, which is the
single largest soundness surface in the system.

Summaries are therefore **content-hashed** against the function body's IR. A call site consuming a
summary records the hash; a mismatch at link time is a **hard error**, not a remark and not a
silently-trusted cache. There is no "trust me" mode in release. Treat the summary as a certificate
that must validate, not a file that is probably fine. (`.amt` files are regenerated by the build
system and need not be committed to version control.)

> [!IMPORTANT]
> The `.amt` file format and the link-time resolution pass are still being finalized. The four-section
> schema and the content-hash invariant above are the fixed parts; wire-format specifics may change
> before 1.0.

---

## Soundness and Testing

Tether makes a strong claim `PROVEN_STATIC` means an access is safe with no runtime evidence and a
proof engine cannot ship on inspection alone. Two properties pin it down.

### The soundness property

> If a dereference classifies as `PROVEN_STATIC`, then no clause of its obligation can fail at
> runtime for any execution.

This is what licenses emitting a bare `mov`. The full proof belongs in the Tether paper, not here; the
property to hold against is that the static classification is an under-approximation of safety the
analysis only proves a clause when it is genuinely discharged, and every uncertainty is resolved
toward residual (the monotone "take the weaker state at a merge" rule). Failing closed at every
boundary interop, threads, summary gaps, non-convergent recursion is what keeps the
under-approximation honest: optimism is what would make the property false, and Tether is never
optimistic at a boundary.

### Paranoid mode the empirical falsifier

The contrapositive of the soundness property is directly testable. **Paranoid mode** emits the
runtime check for *every* dereference regardless of its classification including the ones marked
`PROVEN_STATIC`. Then:

> If a check fires in paranoid mode at a site Tether classified `PROVEN_STATIC`, the static proof was
> wrong. That is a soundness bug.

Paranoid mode is the fuzzing oracle. It is cheap to build (the check-emission machinery already
exists for Tier R; paranoid mode just disables the suppression) and it turns "is the lattice sound"
from a question answered by inspection into one answered by running the test suite under
instrumentation. **It is the first thing to build,** before trusting any `PROVEN_STATIC` in anger.

### Optimization-level independence

Tether's proof results are **independent of the LLVM optimization level**. The lattice is computed
before, and separately from, the backend optimization passes. A higher opt level may *lower* a check
more cheaply, but it may never change a dereference's proof *state*. The set of dereferences that
carry a runtime check is **identical at every opt level**.

This is a hard invariant, and it is the kind that belongs in CI: a `FileCheck` assertion that a given
dereference emits (or does not emit) a check, pinned and run at every opt level. Without it,
safety-relevant codegen the presence or absence of a check could drift with optimization
settings, and a check that exists at `-O0` but is "optimized away" at `-O2` would be indistinguishable
from a miscompile. The invariant makes that class of bug impossible by construction and testable by
assertion.

---

## What Tether Does Not Do

- **Garbage collection.** No tracing, no mark-and-sweep, no runtime collector. Reference counting for
  `Shared` is the only runtime ownership cost, and it exists only where multiple ownership is required.
- **Runtime borrow checking.** Aliasing is resolved at compile time. Tether does not insert runtime
  aliasing checks; it inserts bounds, epoch, and (for tainted/nullable residuals) access checks
  those are clause discharges, not borrow checks.
- **Lifetime annotations.** No `'a`-style parameters, no lifetime polymorphism. Whole-program analysis
  infers concrete lifetimes from usage.
- **Reference counting everywhere.** Single-owner pointers promote to `Unique` (no refcount); contained
  lifetimes are not promoted at all. Refcounting appears only under proven multiple ownership.
- **Cross-language analysis.** C++ is opaque beyond the one-level heuristic on a visible body. Across
  the FFI boundary, Tether fails closed (taint inbound, epoch-freeze outbound) rather than guessing.

---

## Summary

The whole system, in one table maps each clause's residual to its response:

| Residual                                         | Response                                     | Tier |
|--------------------------------------------------|----------------------------------------------|------|
| bounds (range)                                   | hoisted/local check, both modes              | R    |
| UAF (provenance intact)                          | epoch compare, both modes                    | R    |
| UAF (provenance lost)                            | hard error                                   | N    |
| nullability                                      | debug check / release error                  | P    |
| ownership escape (heap-promotable)               | debug promote / release error                | P    |
| stack escape (heap-promotable)                   | debug heap-lift / release error              | P    |
| stack escape (non-promotable)                    | hard error                                   | N    |
| scoped-allocator escape                          | hard error                                   | N    |
| opaque-container escape                          | hard error                                   | N    |
| iterator invalidation                            | hard error                                   | N    |
| moved-from use                                   | hard error                                   | N    |
| second writer to shared allocation               | hard error                                   | N    |
| access residual on shared *mutable* allocation   | hard error (strict mode)                     | N    |
| access residual on shared *read-only* allocation | normal Tier-R check                          | R    |
| taint (provenance recoverable)                   | runtime check                                | R    |
| taint (provenance opaque)                        | hard error (demand `unsafe`)                 | N    |

| Type             | Tracked? | Promoted?                 | Escape                                                |
|------------------|----------|---------------------------|-------------------------------------------------------|
| Plain *T (stack) | Yes      | Heap-lift in debug only   | Promotable: debug-lift / release-err; else hard error |
| Plain *T (heap)  | Yes      | Debug: yes / Release: no  | Release: hard error (annotate)                        |
| unsafe *T        | No       | Never                     | Programmer's problem                                  |
| Scoped-alloc ptr | Yes      | Never                     | Always hard error                                     |
| Shared (thread)  | Yes      | n/a                       | One writer, or many `const` readers                   |
| FFI smart ptr    | Yes      | Mapped 1:1                | Type mismatch = error                                 |
| FFI raw ptr      | No       | Never                     | Tainted; requires unsafe/launder                      |

Tether proves every dereference safe statically when it can, and emits nothing. When only a checkable property remains, it emits the minimal check Tier R, the only runtime cost in a release build. When safety needs a program change it transforms in debug and errors in release (Tier P), and when nothing can establish safety it is a hard error in every mode (Tier N).
