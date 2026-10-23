# Tether Internals

## C/C++ Interop

The FFI boundary is where Tether's facts run out, and the cost model has an honest asterisk: pointers crossing the boundary carry no provenance Tether can trust, so accessing them in safe code is not free.

### Inbound pointers are tainted

A pointer that enters Kairo from C++ has **no provenance** Tether does not know its allocation, size, or epoch. Such a pointer is *tainted* (clause C6). Dereferencing a tainted pointer in safe code cannot be `PROVEN_STATIC`. If Tether can recover enough provenance to form a check, the dereference is Tier R; if the provenance is fully opaque, it is Tier N a hard error demanding an [`unsafe` block](/docs/language/unsafe/#unsafe-blocks) or an explicit `assume`/launder that transfers responsibility to the programmer.

A pointer that acquires its provenance *inside* an `unsafe` block carries the same taint when it flows back into safe code: unsafe is allowed to *narrow* where checks vanish, but it does not let an untracked pointer leak into a safe dereference as if it were proven.

### Outbound pointers freeze their epoch

A Kairo pointer handed to C++ has its allocation's epoch frozen pessimistically: Tether must assume C++ may free, relocate, or retain it. On return from the FFI call, all optimistic facts about that allocation are erased unless an annotation says otherwise. This is unavoidable Tether genuinely lacks the proof and it is where the "as fast as unchecked C++" property does not hold: at the interop boundary you pay, because the proof is on the other side of a wall Tether cannot see through.

### Smart-pointer and reference parameters

C++ functions using [smart-pointer or reference types](/docs/language/c-cpp-calling/#pointers-and-references) map automatically and require no `unsafe`:

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

Tether analyzes each monomorphization with full concrete type information [generics](/docs/language/generics/) are not an opaque boundary:

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

If `T` has a `@move` [transfer constructor](/docs/language/classes-lifecycle/#the-transfer-constructor), Tether tracks the transfer through the move; if `T` is
`@copy`, Tether knows both source and destination are live after the copy. Each instantiation is
analyzed as if it were a hand-written concrete function.

---

## .amt Summaries

Whole-program analysis cannot re-walk every callee at every call site. Each translation unit produces a `.amt` summary alongside its object file, and the link pass consumes all summaries to resolve cross-TU pointer flows. The summary is what lets a caller discharge a callee's obligations without re-analyzing its body.

### Summary contents

A function's summary records four sections per pointer parameter and for the function's effect on reachable state:

- **Requires**: preconditions the caller must discharge before the call (e.g. *`ptr` in allocation, access `<=` 16 bytes*).
- **Guarantees**: postconditions the caller may assume after the call (e.g. *`ptr` unchanged*).
- **Preserves**: arguments and state the function provably does not mutate. Hoisting reads this: the `loop_bound == allocation_count` proof requires that an intervening call **Preserves** the size variable.
- **Escapes**: what the function retains beyond its own frame (stores, returns, captures). Lifetime analysis reads this.

`Escapes` defaults to *everything* and `Preserves` to *nothing* when analysis is incomplete: the summary fails **closed**. An incomplete summary costs precision (more residual, more checks or errors), never soundness.

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

## See also

- [Tether](/docs/language/tether/)
- [Proof Model](/docs/language/tether-proof-model/)
- [Bounds and Provenance](/docs/language/tether-bounds/)
- [Ownership and Promotion](/docs/language/tether-promotion/)
- [Threading](/docs/language/tether-threading/)
- [C/C++ Interop](/docs/language/c-cpp/)
- [Generics](/docs/language/generics/)
- [Unsafe](/docs/language/unsafe/)
