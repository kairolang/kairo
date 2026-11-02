import '../../../styles/math.css';

# Proof Model

## The Dereference Obligation

Every [safe-pointer](/docs/language/pointers/#safe-pointers-t) dereference `*p` where `p: *T` carries a single safety obligation, stated as a conjunction of independent clauses. The access is sound if and only if every clause holds:

$$
\def\arraystretch{1.5}
\begin{array}{l}
\operatorname{deref}(p : {*}T) \ \text{is sound} \iff \\
\begin{array}{lrll}
\htmlClass{k-tag}{\texttt{C1}} & & \operatorname{epoch}(\operatorname{prov}(p)) = \operatorname{live\_epoch}(\operatorname{alloc}(\operatorname{prov}(p)))
  & \enspace \htmlClass{k-note}{\small\text{provenance / use-after-free}} \\
\htmlClass{k-tag}{\texttt{C2}} & \land & 0 \le \operatorname{byte\_offset}(p)
  & \enspace \htmlClass{k-note}{\small\text{no underflow}} \\
\htmlClass{k-tag}{\texttt{C3}} & \land & \operatorname{byte\_offset}(p) + \operatorname{sizeof} T \le \operatorname{size}(\operatorname{alloc}(\operatorname{prov}(p)))
  & \enspace \htmlClass{k-note}{\small\text{no overflow / bounds}} \\
\htmlClass{k-tag}{\texttt{C4}} & \land & p \ne \text{null}
  & \enspace \htmlClass{k-note}{\small\text{nullability}} \\
\htmlClass{k-tag}{\texttt{C5}} & \land & \bigl(\neg \operatorname{shared}(\operatorname{alloc}(\operatorname{prov}(p))) \lor \text{readonly\_extent} \lor \text{synced}\bigr)
  & \enspace \htmlClass{k-note}{\small\text{data-race freedom}} \\
\htmlClass{k-tag}{\texttt{C6}} & \land & \bigl(\neg \operatorname{tainted}(\operatorname{prov}(p)) \lor \operatorname{laundered}(p)\bigr)
  & \enspace \htmlClass{k-note}{\small\text{provenance integrity}}
\end{array}
\end{array}
$$

Where:

- $$\operatorname{prov}(p)$$ is the **provenance** of `p`: which allocation it points into and the epoch at which that pointer value was derived.
- $$\operatorname{alloc}(\operatorname{prov}(p))$$ is the originating allocation; $$\operatorname{size}(\dots)$$ is its byte size; $$\operatorname{live\_epoch}(\dots)$$ is its current generation (see [Provenance and Epochs](/docs/language/tether-bounds/#provenance-and-epochs)).
- $$\operatorname{byte\_offset}(p)$$ is the offset of `p` from the allocation base, in bytes. Stated in bytes so the $$\operatorname{sizeof} T$$ scaling in C3 is explicit and the element-count-times-size multiply cannot silently overflow.

Each clause is a distinct **proof domain** with its own analysis. Tether discharges as many clauses as it can statically. The clauses that remain (the **residual**) determine what is generated. The mapping from a residual clause to a code-generation response is the entire specification of Tether's behavior, and it is given in [The Residual Table](#the-residual-table).

The obligation is split across formation and dereference. Forming a pointer value (`var *q = p + i`) carries one obligation of its own, the **formation range**:

$$
0 \le \operatorname{byte\_offset}(q) \le \operatorname{size}(\operatorname{alloc}(\operatorname{prov}(q)))
$$

that is, `q` lies in the allocation or exactly one past its end. A formation proven in range emits nothing; one statically out of range is a compile error; an unprovable one is a Tier R check at the arithmetic, discharged and hoisted by the same bounds machinery as C3. Because every safe pointer value satisfies the formation range, C2 holds for every formed pointer, and at `*q` only C3's extra `sizeof T` of room (and the other clauses) remain. Tether still carries symbolic offsets through SSA and discharges both obligations as late and as rarely as it can; adjacent formation and dereference checks fuse into one (see [Pointer Arithmetic](/docs/language/tether-bounds/#pointer-arithmetic)).

---

## The Proof Lattice

Tether is a forward dataflow analysis over the program's SSA graph. For each pointer at each program point it computes a **fact tuple**: one element per clause domain, recording how strongly that clause is currently proven.

### Per-clause lattice

Each clause domain has a small lattice of proof states. For the structural clauses (C1, C4, C6) the lattice is height-2:

$$
\def\arraystretch{1.4}
\begin{array}{cl}
\texttt{Proven} & \qquad \htmlClass{k-note}{\small\text{(the clause is statically discharged here)}} \\
\sqsubset & \\
\texttt{Residual} & \qquad \htmlClass{k-note}{\small\text{(the clause must be discharged at runtime, or is a hard error)}}
\end{array}
$$

For the bounds clause (C2/C3) the lattice is height-3, because bounds admits an intermediate state where the property is provable over a region rather than at a single point:

$$
\def\arraystretch{1.4}
\begin{array}{cl}
\texttt{Proven} & \qquad \htmlClass{k-note}{\small\text{(offset statically known in range, no code)}} \\
\sqsubset & \\
\texttt{HoistableResidual} & \qquad \htmlClass{k-note}{\small\text{(provable over a loop/region, one check at region entry)}} \\
\sqsubset & \\
\texttt{DynamicResidual} & \qquad \htmlClass{k-note}{\small\text{(must check at this specific dereference)}}
\end{array}
$$

`Proven` is the strongest (least) element. The order $$\sqsubseteq$$ means "at least as proven as." `Residual` and `DynamicResidual` are the weakest elements of their domains.

### The product lattice

The fact tuple for a pointer is an element of the product lattice

$$
L = L_{\text{C1}} \times L_{\text{C2C3}} \times L_{\text{C4}} \times L_{\text{C5}} \times L_{\text{C6}}
$$

ordered componentwise. The product of finite-height lattices is itself a finite-height lattice; the height of $$L$$ is the sum of the component heights, which is a small constant (independent of program size). The transfer functions for each IR operation are **monotone** with respect to $$\sqsubseteq$$: an operation never increases the proof strength of a clause it has no evidence for, and joining facts at control-flow merge points takes the weaker (less proven) state.

Monotone transfer functions over a finite-height lattice means the Kleene iteration over the classification reaches a fixed point in a bounded number of passes (bounded by the lattice height times the number of program points). (A pass ceiling exists for *interprocedural* recursion, but it degrades precision, never soundness: hitting it demotes clauses to Residual, which is always safe. See [Summaries](/docs/language/tether-internals/#amt-summaries).)

This argument covers the classification lattice only. Deciding *which* state a clause is in needs the numeric facts underneath, and that domain is not finite-height.

### The numeric domain

Proving `0 <= i < 120` from a loop, or `loop_bound == allocation_count` from an allocation site, needs facts about integer values, not only proof states. Underneath the lattice, Tether keeps a relational numeric domain over SSA values:

- **intervals** per integer value (`i ∈ [0, n)`)
- **SSA equalities and symbolic offsets** (`n == count(a)`, `off(q) == off(p) + 4·k`)
- **induction-variable recognition**: loops with a recognizable induction variable (`for i in 0..<n`, a pointer stepped by a constant until it reaches `end`) get their bounds from the loop's structure directly, without fixpoint iteration

Intervals over loops that are *not* recognized structurally do not stabilize on their own, so the numeric domain uses **widening** at loop headers. Widening is sound (it only loses precision), and the result is what guarantees termination: the numeric iteration stabilizes after a bounded number of widening steps, and the classification above is then computed over its stable facts. A fact lost to widening makes the clause residual, never proven.

Every invariant Tether relies on (a range at a loop header, an equality between a bound and an allocation count) must be **inductive**: it holds on loop entry and is preserved by one iteration of the body. Checking that a stated invariant is inductive is decidable and much simpler than inferring it, which is what lets the inference stay heuristic while the soundness claim rests only on the check.

### Classifying a dereference

The four named proof states from Tether's vocabulary (`PROVEN_STATIC`, `PROVEN_RANGE`, `REQUIRES_DYNAMIC`, `UNSAFE`) are not elements of the lattice. They are a **classification of the residual set** at a dereference site, derived from the fact tuple:

| Residual set at `*p`                                  | Classification     | Emitted                          |
|-------------------------------------------------------|--------------------|----------------------------------|
| empty (all clauses `Proven`)                          | `PROVEN_STATIC`    | nothing                          |
| `{bounds}` only, and bounds is `HoistableResidual`    | `PROVEN_RANGE`     | one assertion at region entry    |
| any other non-empty residual                          | `REQUIRES_DYNAMIC` | per-clause runtime code at `*p`  |
| `p` is `unsafe *T`                                    | `UNSAFE`           | nothing (analysis not run)       |

The compiler walks every dereference, reads its residual set, classifies it, and emits accordingly. The overwhelming majority of dereferences in well-structured code classify as `PROVEN_STATIC` and generate a bare `mov`.

---

## The Residual Table

A residual clause does not have a uniform response. Bounds falls back to a runtime check; a lost provenance is a hard error; an unchecked [nullable](/docs/language/nullables/) access is a compile error in every mode. The response is **per-clause**, and the full mapping is the specification of the system:

| Residual clause / condition                                  | Response                                              | Tier |
|--------------------------------------------------------------|-------------------------------------------------------|------|
| **C3 bounds**, range residual                                | hoisted or local bounds check, **both modes**        | R    |
| **Formation range**, unprovable                              | hoisted or local check at the arithmetic, both modes  | R    |
| **Formation range**, statically outside `[base, base+count]` | compile error, both modes                             | N    |
| **Relational compare**, operands not provably same allocation| compile error, both modes                             | N    |
| **C1 epoch (UAF)**, provenance intact                        | epoch comparison at deref, **both modes**            | R    |
| **C1 epoch (UAF)**, provenance lost                          | hard error, both modes                                | N    |
| **C4 nullability**                                           | compile error, both modes: check it in source         | N    |
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

- **Tier R, runtime-check fallback, both debug and release.** The residual is a property that can be established by a cheap, side-effect-free runtime check. The program is unchanged; it pays a comparison. **This is the only tier that emits runtime code in a release build.**
- **Tier P, debug transforms, release hard-errors with the fix.** The residual can be established by *changing the program* (inserting a [smart pointer](/docs/language/tether-promotion/), lifting a stack value to the heap). Debug performs the transformation and warns. Release refuses, because the transformation would be a hidden allocation or hidden control flow in a release binary, and emits a hard error showing the exact source change the programmer must make.
- **Tier N, never allowed, hard error in all modes.** No runtime check and no transformation can establish safety, because the information required to even *form* a check is absent (lost provenance, undeterminable ownership) or the property is genuinely uncheckable (a data race is UB that a single-threaded check cannot rule out).

The organizing principle in one sentence: **debug is allowed to rewrite your code to make it work; release makes you write the code that debug would have written; some things are wrong no matter who writes them.**

### Why bounds is Tier R but nullability is never inserted

Both are access-safety clauses. They differ in the *nature of the fallback*.

A bounds check (`assert(off < count)`) does not change the meaning of the program. `buf[i]` still means `buf[i]`; the access either proceeds or crashes on exactly the inputs that would have been UB (a crash, not a [panic](/docs/language/panic/): it joins no panic set). Emitting it in release costs one predictable branch and is the price of permitting safe pointer arithmetic with runtime indices. That is the entire point of Kairo's pointer model; see [Pointer Arithmetic](/docs/language/tether-bounds/#pointer-arithmetic).

A null fallback (`if (p == null) crash!()`) *introduces a control-flow edge that is not visible in the source*. A release binary that silently crashes on a null dereference the programmer never guarded has hidden control flow, which violates the same guarantee that forbids hidden allocation. So no mode inserts that guard. An access to a nullable the compiler cannot prove non-null is a compile error in debug and release alike: check it (`if x?`), give a fallback (`??`), or force it (`unwrap!()`), each of which writes the null path into the source. See [Nullables](/docs/language/nullables/#null-checking).

## See also

- [Tether](/docs/language/tether/)
- [Bounds and Provenance](/docs/language/tether-bounds/)
- [Ownership and Promotion](/docs/language/tether-promotion/)
- [Threading](/docs/language/tether-threading/)
- [Tether Internals](/docs/language/tether-internals/)
- [Pointers](/docs/language/pointers/)
- [Nullables](/docs/language/nullables/)
- [Unsafe](/docs/language/unsafe/)
