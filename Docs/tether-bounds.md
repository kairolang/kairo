# Bounds and Provenance

## Pointer Arithmetic

Kairo permits [pointer arithmetic](/docs/language/pointers/#pointer-arithmetic) on safe pointers. This is a deliberate departure from Rust's safe subset, and Tether is what makes it sound.

```kairo
var a: *i32 = @create i32(120)
*(a + 10) = 19
```

At this dereference Tether knows the allocation base, element type (`i32`), element size (4 bytes), and element count (120). The offset 10 is a compile-time constant. C3 reduces to `10 < 120`, proven statically. C1, C2, C4, C5, C6 are all proven. Residual set is empty -> `PROVEN_STATIC`:

```
mov [rdi + 40], 19
```

No check. No metadata. Nothing.

### Runtime offset

```kairo
var i = std::input<i32>()
*(a + i) = 19
```

Now C3 cannot be proven (the offset is runtime data) and C2 cannot be proven (`i` is signed and may be negative). Every other clause holds. Residual set is `{bounds}`, not hoistable -> `REQUIRES_DYNAMIC`:

```asm
assert((0 <= i) && (i < 120));
mov [rdi + i*4], 19
```

Note both halves of the check. **`i < 120` alone is unsound** for a signed offset: a negative `i` passes it and reads out of bounds backward. The canonical obligation is `0 <= off AND off + sizeof T <= size`, and Tether emits both comparisons unless it can prove non-negativity separately (e.g. `i` is unsigned, or dominated by an `i >= 0` guard). For an unsigned offset the lower-bound clause C2 is discharged statically and only the upper comparison is emitted.

The check is on the **offset**, computed before the pointer is formed never on the resulting pointer address. Checking `result_ptr < end` after forming the pointer is the bypassable version: if `i * sizeof T` overflowed the address width, the formed pointer can wrap below `end` and pass a post-hoc check. Tether checks the offset in a width that cannot wrap for any in-allocation offset (the valid offset range is bounded by `size`, which is known), then forms the pointer.

### Hoisting

```kairo
for i in 0..<120
    *(a + i) = 0
```

Tether proves `0 <= i < 120` holds for the entire loop body from the loop's induction structure (see [the numeric domain](/docs/language/tether-proof-model/#the-numeric-domain)). The bounds clause is `HoistableResidual` if it is the only residual -> `PROVEN_RANGE`. The per-iteration check is lifted to a single check before the loop:

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

Tether proves `loop_bound == allocation_count` provided `n` and `a` are not mutated between the allocation and the loop (see the immutability requirement under [Threading](/docs/language/tether-threading/#threading) and [Summaries](/docs/language/tether-internals/#amt-summaries)). The entire loop's bounds obligation collapses to one check:

```asm
assert(n <= allocation_count);   ; trivially true here; elided
loop:
    mov [rdi + i*4], 0
```

One branch (or zero), discharging millions of accesses. This is the same class of transformation an optimizing backend already performs; Tether's contribution is proving it is *sound* to do so under the language's safety guarantee, not merely profitable.

### Forming versus dereferencing, and one-past-the-end

The range obligation is split between formation and dereference.

**Formation.** `var *q = a + i` must land in `[base, base + count]`, inclusive of the one-past-the-end address: `0 <= off(q) <= size(alloc)`. One-past is required because idiomatic range loops compare against it (`while p < end`), so it must be formable and comparable. Formation follows the same proof rules as a dereference:

- proven in range: emits nothing
- statically out of range (below `base`, or past one-past): compile error, both modes
- unprovable (runtime `i`): Tier R, one check at the arithmetic, hoisted like any bounds check

No pointer value outside `[base, base + count]` ever exists in a safe program, so there is no "formed but not dereferenceable" state beyond one-past.

**Dereference.** `*q` then needs the room for one element, `off(q) + sizeof T <= size(alloc)` (C3), which excludes one-past itself. When `q` came from a checked formation, the dereference check reduces to `off(q) != size(alloc)` or is proven away.

**Comparison.** `==` and `!=` are defined on any two safe pointers. The relational operators (`<`, `<=`, `>`, `>=`) are defined only when both operands share provenance (point into the same allocation, one-past included). A relational comparison between pointers into different allocations is a compile error; when Tether cannot prove the operands share an allocation, it is a compile error too. Compare addresses through `as usize` if a cross-allocation ordering is genuinely wanted.

This is a larger expressiveness envelope than safe Rust, which routes all of this through slices and iterators. The safety **guarantee** is the same no out-of-bounds access reaches memory but the cost model is pay-only-when-unprovable rather than always-checked-unless-elided, and the surface syntax is C-style arithmetic rather than slice methods.

> Tether does not present an unprovable bounds access as a *warning*. The programmer did nothing questionable; the allocation size is simply runtime data. It is reported as an **optimization remark** when remarks are enabled, naming the fact that blocked the proof: `[amt] runtime bounds check at <loc>: allocation size depends on runtime value 'n'; cost: one check; to eliminate: bound the index by a compile-time constant or hoist the proof.`

---

## Provenance and Epochs

Use-after-free is not a separate debug-only feature. It is clause C1 of the dereference obligation, and it is discharged by the same lattice machinery as bounds.

Every allocation carries a **generation** (an epoch) in its provenance fact. Any operation that can free or relocate the allocation increments its epoch:

- explicit `@destroy` or `@free`
- scope exit of the owning binding
- [ownership transfer](/docs/language/ownership/#transfer-semantics) (move) out of the owning binding
- assignment *into* the binding (copy or move assignment), which replaces the contents a derived pointer was looking at
- reallocation (e.g. a `Vec` growing its backing buffer)
- the close of a [scoped allocator](/docs/language/allocators/#scoped-allocator) that owns the allocation

A pointer value derived at epoch *e* records *e* in its provenance. Clause C1 requires `epoch(prov(p)) == live_epoch(alloc(prov(p)))` at the dereference. Statically, most epochs are provably equal there is no intervening freeing operation between derivation and use so C1 is `Proven` and emits nothing. When Tether cannot prove the epochs equal (a free *might* have happened on some path), C1 is residual:

```kairo
var buf: *i32 = @create i32(64)
var *p = buf + 5
realloc(buf)        // increments buf's epoch
*p = 1              // C1 residual: p was derived at the old epoch
```

If provenance is intact (Tether still knows which allocation and can read the live epoch), C1 residual is **Tier R**: an epoch comparison at the dereference, in both modes. If provenance has been lost entirely (the pointer was laundered through an untracked path and Tether no longer knows the allocation), there is nothing to compare against and it is **Tier N**: a hard error.

Epochs are 64-bit. A generation counter that wraps lets a stale pointer whose epoch has come back around pass the comparison; at 64 bits the wrap is unreachable in practice.

> [!NOTE]
> `PROVEN_STATIC` needs no metadata. A Tier R check does: the bounds check reads `size(alloc)` and the epoch check reads `live_epoch(alloc)` at run time, for a pointer that may have arrived as a parameter with a runtime offset. Where those values come from (pointer representation, allocator lookup, or caller-supplied facts) is not decided yet, and the choice affects the pointer ABI. Whatever is chosen, the epoch word must remain readable after the allocation is freed, since reading it out of freed memory would itself be a use-after-free.

Folding UAF into the same obligation as bounds is what makes the architecture scale: there is one analysis, one lattice, one residual table, and "use-after-free detection" is not a bolted-on sanitizer but a clause that is either proven away or checked like any other.

---

## Field access and interior pointers

`foo.bar.baz` is `PROVEN_STATIC` when `foo` is non-null and the field offsets are static: the access inherits `foo`'s provenance with a constant offset, and its obligation is exactly `foo`'s obligation.

Taking an interior pointer `var *p = &foo.bar` creates a new pointer whose provenance is derived from `foo`'s allocation at `foo`'s current epoch. Dropping `foo`, moving out of it, or assigning a new value into it increments that epoch, so a later `*p` fails C1 by the same mechanism as any other use-after-free. Interior pointers are not special-cased; they reuse the epoch machinery.

## See also

- [Tether](/docs/language/tether/)
- [Proof Model](/docs/language/tether-proof-model/)
- [Ownership and Promotion](/docs/language/tether-promotion/)
- [Threading](/docs/language/tether-threading/)
- [Tether Internals](/docs/language/tether-internals/)
- [Pointers](/docs/language/pointers/)
- [Ownership](/docs/language/ownership/)
- [Collections](/docs/language/collections/)
