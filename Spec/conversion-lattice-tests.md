# Conversion lattice: test plan and implementation notes

Internal companion to the normative conversion-lattice section in the language
reference (`kairo-web/src/content/docs/language/primitives.mdx`, "Conversion classes"
onward). The reference states the rules; this file holds the tests that keep them honest
and the implementation shape they are meant to be generated from. Section numbers (§2,
§4.1, §8) refer to that reference; the invariants list below is local to this file.

---

## Differential test for `-fno-implicit-conv`

The reference proves that the flag can only turn a resolved call into an error, never
change which candidate wins. Test it as a differential run: compile the whole suite both
ways, diff the `--dump-type-info` output, and assert every difference is
`resolved → error` and never `resolved(A) → resolved(B)`. If that assertion ever fires, a
ranking has been introduced somewhere inside rank 2, and it should be caught the day it
happens.

## Invariants — property tests

These are the properties that keep the relation a well-formed partial order. Each is a
one-page property test over the full primitive set, and each catches a class of bug that
is otherwise found by users.

1. **Reflexivity.** `class(T, T) == I` for all `T`.
2. **Antisymmetry.** `W(A → B) ∧ W(B → A) ⟹ A == B`. A W-cycle means overload resolution
   can pick either candidate depending on iteration order.
3. **Transitivity.** `W(A → B) ∧ W(B → C) ⟹ W(A → C)`. The rules in §2 are already
   transitively closed; the test guards against a future rule addition that breaks it.
   If this ever fails, conversion becomes chain-length-dependent and results stop being
   stable under refactoring.
4. **Value preservation.** For every W pair and a generated corpus of source values
   (bounds, zero, ±1 around bounds, random), round-tripping through the target and back
   yields the original. Any failure is a mis-classified cell, not a codegen bug.
5. **Target independence.** The full class matrix is byte-identical across every
   supported triple. `usize`/`isize` rows and columns are the ones this is really
   testing. The §4.1 boundary relation is held to the same standard: it is computed from
   the [32, 64] ranges, not the target's width, so it too is identical on every
   32/64-bit triple.
6. **Totality.** Every ordered pair over the full primitive set has exactly one class.
   No `default:` fallthrough in the decision function.

---

## Implementation shape

Generate everything from one table. A single `conversions.def` X-macro or TOML listing
`(source, target, class)` for every pair, and from it emit:

- the `ConversionClass classify(TypeId, TypeId)` function used by sema,
- the docs table in the language reference,
- the property-test corpus for the invariants below,
- the `--dump-type-info` legend.

The alternative — a hand-written `classify` with the docs maintained separately — drifts
within a month, and the drift is invisible because nothing compares them. One source,
three consumers, zero drift.

Order of work: land `classify` and its property tests against the current checker *before*
changing any behavior, so you find out which cells the compiler already disagrees with.
That diff is the actual work item list.