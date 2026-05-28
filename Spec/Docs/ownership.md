# Ownership

> [!IMPORTANT]
> This page is under development. The ownership model is being finalized alongside AMT. Full
> documentation will be added once the design is complete.

Kairo's ownership model governs how values are created, moved, borrowed, and destroyed. It works in
conjunction with [AMT](/docs/language/amt) to provide memory safety without lifetime annotations.

Key concepts that will be covered on this page:

- Move semantics and when values are moved vs copied
- Borrowing rules for safe pointers (`*T`) and `const` references
- How `const [T]` acts as a non-owning view (cap set to zero, no growth, no deallocation)
- Interaction between ownership and [closures](/docs/language/closures) (capture by copy vs by reference)
- How [classes](/docs/language/classes#the-rule-of-five) implement the rule of five
- How [structs](/docs/language/structures#copy-semantics) are always trivially copyable via `memcpy`
- The `mref!()` intrinsic for rvalue references

See [AMT](/docs/language/amt) for the compile-time analysis that enforces ownership rules, and
[Unsafe](/docs/language/unsafe) for opting out of ownership tracking.
