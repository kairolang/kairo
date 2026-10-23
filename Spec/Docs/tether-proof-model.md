import '../../../styles/math.css';

# Proof Model

## The Dereference Obligation

Every [safe-pointer](/docs/language/pointers/#safe-pointers-t) dereference `*p` where `p: *T` carries a single safety obligation, stated as a
conjunction of independent clauses. The access is sound if and only if every clause holds:

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

- $$\operatorname{prov}(p)$$ is the **provenance** of `p`: which allocation it points into and the epoch at which
  that pointer value was derived.
- $$\operatorname{alloc}(\operatorname{prov}(p))$$ is the originating allocation; $$\operatorname{size}(\dots)$$ is its byte size; $$\operatorname{live\_epoch}(\dots)$$
  is its current generation (see [Provenance and Epochs](/docs/language/tether-bounds/#provenance-and-epochs)).
- $$\operatorname{byte\_offset}(p)$$ is the offset of `p` from the allocation base, in bytes. Stated in bytes so the
  $$\operatorname{sizeof} T$$ scaling in C3 is explicit and the element-count-times-size multiply cannot silently
  overflow.

Each clause is a distinct **proof domain** with its own analysis. Tether discharges as many clauses as
it can statically. The clauses that remain (the **residual**) determine what is generated. The
mapping from a residual clause to a code-generation response is the entire specification of Tether's
behavior, and it is given in [The Residual Table](#the-residual-table).

The critical design point: the obligation is checked at the **dereference**, never at pointer
arithmetic. Forming a pointer value (`var q = p + i`) computes a new provenance fact and emits no
code. Only `*q` discharges the obligation against that provenance. This lets Tether carry symbolic
offset information through arbitrarily many SSA transformations and discharge or eliminate the
obligation as late as possible (see [Pointer Arithmetic](/docs/language/tether-bounds/#pointer-arithmetic)).

---

## The Proof Lattice

Tether is a forward dataflow analysis over the program's SSA graph. For each pointer at each program
point it computes a **fact tuple**: one element per clause domain, recording how strongly that
clause is currently proven.

### Per-clause lattice

Each clause domain has a small lattice of proof states. For the structural clauses (C1, C4, C6) the
lattice is height-2:

$$
\def\arraystretch{1.4}
\begin{array}{cl}
\texttt{Proven} & \qquad \htmlClass{k-note}{\small\text{(the clause is statically discharged here)}} \\
\sqsubset & \\
\texttt{Residual} & \qquad \htmlClass{k-note}{\small\text{(the clause must be discharged at runtime, or is a hard error)}}
\end{array}
$$

For the bounds clause (C2/C3) the lattice is height-3, because bounds admits an intermediate state
where the property is provable over a region rather than at a single point:

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

`Proven` is the strongest (least) element. The order $$\sqsubseteq$$ means "at least as proven as." `Residual`
and `DynamicResidual` are the weakest elements of their domains.

### The product lattice

The fact tuple for a pointer is an element of the product lattice

$$
L = L_{\text{C1}} \times L_{\text{C2C3}} \times L_{\text{C4}} \times L_{\text{C5}} \times L_{\text{C6}}
$$

ordered componentwise. The product of finite-height lattices is itself a finite-height lattice; the
height of $$L$$ is the sum of the component heights, which is a small constant (independent of program
size). The transfer functions for each IR operation are **monotone** with respect to $$\sqsubseteq$$: an
operation never increases the proof strength of a clause it has no evidence for, and joining facts
at control-flow merge points takes the weaker (less proven) state.

Monotone transfer functions over a finite-height lattice means the Kleene iteration reaches a fixed
point in a bounded number of passes (bounded by the lattice height times the number of program
points). **The analysis always terminates.** This is the only termination argument Tether needs;
there is no widening, no heuristic iteration cap required for soundness. (A pass ceiling exists for
*interprocedural* recursion, but it degrades precision, never soundness: hitting it demotes clauses
to Residual, which is always safe. See [Summaries](/docs/language/tether-internals/#amt-summaries).)

### Classifying a dereference

The four named proof states from Tether's vocabulary (`PROVEN_STATIC`, `PROVEN_RANGE`,
`REQUIRES_DYNAMIC`, `UNSAFE`) are not elements of the lattice. They are a **classification of the
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
provenance is a hard error; a [nullable](/docs/language/nullables/) dereference is a hard error in release but a transform in
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
  by *changing the program* (inserting a [smart pointer](/docs/language/tether-promotion/), lifting a stack value to the heap, inserting
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
arithmetic with runtime indices. That is the entire point of Kairo's pointer model; see
[Pointer Arithmetic](/docs/language/tether-bounds/#pointer-arithmetic).

A null fallback (`if (p == null) panic()`) *introduces a control-flow edge that is not visible in
the source*. A release binary that silently panics on a null dereference the programmer never
guarded has hidden control flow, which violates the same guarantee that forbids hidden allocation.
So nullability is Tier P: debug inserts the guard so you can keep moving, release makes you either
prove non-null or handle the null case explicitly.

## See also

- [Tether](/docs/language/tether/)
- [Bounds and Provenance](/docs/language/tether-bounds/)
- [Ownership and Promotion](/docs/language/tether-promotion/)
- [Threading](/docs/language/tether-threading/)
- [Tether Internals](/docs/language/tether-internals/)
- [Pointers](/docs/language/pointers/)
- [Nullables](/docs/language/nullables/)
- [Unsafe](/docs/language/unsafe/)
