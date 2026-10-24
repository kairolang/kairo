# Threading

Kairo owns its threading runtime. All [concurrency](/docs/language/concurrency/) flows through `thread` and `spawn`, and **only functions marked `async` may be threaded or spawned**. `await` operates on the result of a `thread` or `spawn` call and is the join point.

This is what makes static race-freedom tractable. Every concurrent edge in the program is a syntactic `thread`/`spawn` call site there are no hidden threads, no callbacks invoked from another thread, no library spawning work behind your back. Tether knows exactly where every thread boundary is, which is the precondition for proving the absence of races rather than checking for them at runtime.

> [!NOTE]
> The precise distinction between `thread` and `spawn`, and the synchronization primitives that establish happens-before, depend on Kairo's concurrency runtime, which is not yet finalized. The
> **analysis shape below is fixed**; the runtime seam is marked where it occurs. A synchronization primitive, when it lands, is anything that injects a happens-before edge Tether can observe; crossing one re-permits an otherwise-forbidden access.

## Strict mode

Between a `thread`/`spawn` and its corresponding `await` (the task's **extent**), Tether enters a stricter analysis mode. Any allocation reachable by a pointer captured into the task is a **shared allocation** for that extent, and every access to it is analyzed under the rules below instead of the single-threaded rules.

The defining rule of strict mode: **Tier R collapses into Tier N for shared mutable allocations.** A runtime check reads metadata the allocation's size, its epoch tag and in a threaded extent that metadata can be mutated by another thread, so the check *itself* races. You cannot check your way to safety across threads. A clause that would fall back to a runtime check in single-threaded code must instead be proven statically for a shared mutable allocation, or it is a hard error.

The one exception: if a shared allocation is provably **read-only** for the entire extent (no task holds a mutating pointer to it), its metadata is stable, no thread writes it, and ordinary Tier-R checks on it are sound again. Tier R survives only on read-only shared state.

## The rule set

1. **Single writer per shared allocation.** Within an extent, at most one task may hold a *mutating* (`*T`, non-`const`) pointer to a given allocation. The second live writer main+task or task+task with no synchronization between them is a hard error. This is write-exclusivity, not Rust's full write-xor-read: you may have one writer and nothing else, or many readers.

2. **Many readers OR one writer, across the boundary.** This is the single point where Kairo adopts exclusivity and it applies **only inside a threaded extent**. Single-threaded code retains arbitrary mutable aliasing. A shared allocation in an extent is either all-readers (every capture `*const T`, no check, free shared reads) or exactly one writer and no other accessor. A reader and a writer to the same allocation with no synchronization is a read/write race a hard error. The asymmetry with single-threaded aliasing is deliberate: a data race is UB that no runtime check can rule out, so the rule tightens precisely at the boundary where optimism becomes unsound.

3. **No Tier-R fallback for shared mutable state.** Bounds, epoch/UAF, and nullability must be proven statically for any shared mutable allocation, or the access hard-errors. On a read-only shared allocation, normal Tier-R checks apply (rule 2 makes the metadata stable).

4. **Captured-stack escape from a task Tier N always.** A pointer to the spawning frame's stack, captured into a task that can outlive the frame (detached, or awaited after the frame returns), is a hard error. Heap-lifting the value does not fix a cross-thread lifetime, so this is never promotable. The fix is capture-by-transfer (the task owns its copy) or an explicit heap allocation moved into the task.

5. **What may cross the boundary.** A value captured by transfer has its ownership *fully* transferred the parent cannot touch it after the spawn. A value captured by address makes its allocation shared, subject to rules 1-3. A pointer into a [**scoped allocator**](/docs/language/tether/#scoped-allocator) cannot be captured into a task that outlives the allocator scope (Tier N the arena frees it, and the free also races the task). A [`NON_TRANSFER`](/docs/language/ownership/#non_transfer-types) type cannot be transfer-captured into a task at all (nothing to transfer); it may only be shared read-only by address.

6. **`await` re-establishes facts.** `await` is a happens-before edge. After it, the joined task's writes are visible and ordered, its captured pointers are released, and the allocations it touched return to single-threaded analysis. An allocation that was demoted to "shared, read-only" inside the extent may be a normal mutable `*T` again after the `await` that joins its only other accessor. Strict mode is scoped to the extent, not sticky for the rest of the program.

7. **Detached tasks (never awaited).** With no join there is no happens-before edge, so the task's captured allocations are shared for the rest of the program (or until the task provably ends, which Tether usually cannot prove). Any allocation a detached task captures by pointer and that anyone writes after the spawn is a hard error. The clean pattern detached tasks capture by value only, owning everything they touch is recommended explicitly.

## Sharing syntax

For [**closures and lambdas**](/docs/language/closures/#capture-modes), read-only sharing across a thread boundary is expressed by capturing with `const *` and nothing else. A `const *` capture is a `*const T` into the captured allocation; it cannot mutate the target, which is exactly what rule 2 requires for free shared reads. A plain `*` (mutating) capture into a task makes the allocation a shared *mutable* allocation and triggers the single-writer analysis.

For **functions marked `async`**, the read-only guarantee is carried in the parameter type. The pointer parameter is pointer-to-const, so the threaded body cannot mutate the caller's value through it:

```kairo
fn foo(a: *const i32) async -> i32 {
    // reads through `a`; *a = ... would not compile
    return *a + 1
}

var fut = thread foo(&x)    // begins executing immediately
var res = await fut         // join point, happens-before edge; x is read-only over the extent
```

Here `x`'s allocation is shared read-only for the extent of `fut` (because `foo`'s parameter is `*const i32`), so the parent reading `x` during the extent is sound. Had `foo` taken `a: *i32` and written through it, `x` would be a shared *mutable* allocation and the parent touching `x` before the `await` would be a hard error under rule 2.

The borrow is live from the `thread`/`spawn` call to the matching `await`. Parent access to a shared-*written* allocation inside that window is a hard error this is the core threading rule, and the single-writer and reader/writer rules are its consequences.

## See also

- [Tether](/docs/language/tether/)
- [Proof Model](/docs/language/tether-proof-model/)
- [Bounds and Provenance](/docs/language/tether-bounds/)
- [Ownership and Promotion](/docs/language/tether-promotion/)
- [Tether Internals](/docs/language/tether-internals/)
- [Concurrency](/docs/language/concurrency/)
- [Closures](/docs/language/closures/)
- [Ownership](/docs/language/ownership/)
