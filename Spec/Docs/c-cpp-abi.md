# ABI Contract & Verification

## Link-time ABI Verification

Flag translation only sees a single invocation. Objects compiled at different times, by different people, with
different flags, and linked later are outside its reach. **[`kld`](/docs/toolchain/kld/)** closes that gap.

Every object produced by `kairo` or `kcc` carries an ABI note section recording:

- the set of ABI-affecting settings that were in effect, canonicalized and sorted
- a hash of that set, for fast comparison
- a format version

At link time, `kld` compares hashes. A mismatch is a clean link error naming the specific flag:

```
error: ABI mismatch between input objects
  a.o was compiled with -fno-rtti
  b.o was compiled with -frtti
  note: these settings change type layout and cannot be mixed in one binary
```

The raw setting list is kept alongside the hash precisely so this message is possible. A hash alone can only say
*that* something mismatched, not *what*.

> [!NOTE]
> The hash covers the semantic set of resolved settings, not the command-line string. Flag order and alternate
> spellings of the same setting produce the same hash.

### Objects not built with the Kairo toolchain

`kld` links ordinary C++ objects, including prebuilt system libraries. Those have no ABI note, so nothing can be
verified about them. `kld` reports what it could not check:

```
warning: 3 object(s) were not built with kcc or kairo; ABI compatibility unchecked
  libfoo.a(bar.o), libfoo.a(baz.o), /usr/lib/qux.o
```

If one of those objects was built with mismatched settings, the result is a runtime crash with no diagnostic.
That is unavoidable (the information was never recorded), but the boundary of the guarantee is made visible
rather than left implicit. Suppress with `-Wno-unverified-abi`.

**This is the reason to use `kcc` rather than the system `clang++`.** Every object that goes through the Kairo
toolchain is covered.

## Name mangling

Kairo does not implement Itanium or MSVC mangling itself. Kairo constructs the corresponding Clang declaration
and asks Clang's `MangleContext` for the symbol. Both ABIs come from the same source of truth as the C++ side of
the boundary, and there is no second implementation to drift.

---

## ABI Compatibility

Kairo emits object code conforming to the platform's native C++ ABI:

- **Unix-like systems:** Itanium C++ ABI
- **Windows:** Microsoft C++ ABI

Name mangling, vtable layout, RTTI, and struct layout all follow the platform convention, so Kairo `.o`/`.obj`
files link with object files from any ABI-compliant C++ compiler without shims or translation layers.

[`ffi "c++"` declarations](/docs/language/imports/#ffi-linkage-declarations) use C++ mangling. `ffi "c"` declarations use C mangling (no decoration). This matches
the behavior of `extern "C++"` and `extern "C"` in C++.

Two Kairo-specific guarantees strengthen the baseline:

- **Kairo never throws.** See [above](/docs/language/c-cpp-exceptions/#kairo-to-c-kairo-never-throws).
- **ABI settings are recorded in the object and verified at link.** See
  [Link-time ABI verification](#link-time-abi-verification).

### ABI stability across compiler stages

Later compiler stages emit *more* information, not different information, so the ABI does not change:

| Stage | Emits |
|---|---|
| Stage 1 | Declarations, definitions, ordering, mangling. |
| Stage 2 | The same, plus lifetime, aliasing, and ownership attributes derived from Tether analysis. |

Objects from either stage are ABI-compatible. Stage 2's additions give the C++ side more static checking, not a
different layout.

---

## Declaration Ordering

C++ requires a type to be complete before it is used by value. Kairo does not impose that ordering on the
programmer (declarations may appear in any order in a `.k` file), so the emitter reconstructs a valid order.

Emission proceeds in four phases:

1. Forward declarations for every user type, in any order. This satisfies every pointer and reference edge.
2. Function and method declarations, in any order.
3. Type definitions, in dependency order over **by-value** edges only: value members, bases, fixed-array
   elements, and template arguments that land by value.
4. Function bodies, in source order.

A cycle in the phase-3 graph is a genuine error: a type whose definition requires its own layout has no finite
size. It is diagnosed on the Kairo side with the full cycle path:

```
error: recursive type definition requires infinite size
  `A` contains `B` by value
  `B` contains `A` by value
  note: use `*A` to break the cycle
```

Pointer and reference members do not create this edge, which is why `struct B { *A a; }` is legal alongside
`struct A { B b; }`.

---

## See also

- [C & C++ Interoperability](/docs/language/c-cpp/)
- [kairo, kcc & Cross-compilation](/docs/language/c-cpp-toolchain/)
- [Calling C and C++ from Kairo](/docs/language/c-cpp-calling/)
- [Using Kairo in C++](/docs/language/c-cpp-exposing/)
- [Allocators & Ownership](/docs/language/c-cpp-memory/)
- [Exceptions & Panics](/docs/language/c-cpp-exceptions/)
- [Attributes](/docs/language/attributes/)
- [Classes](/docs/language/classes/)
