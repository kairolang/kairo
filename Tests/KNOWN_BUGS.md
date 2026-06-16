# Known Parser Bugs, guarded by failing regression tests

Each bug below has a regression test that FAILS on purpose until fixed.
When the test flips to PASS, the bug is resolved, update/remove the entry.

## 1. ChainExpr produces wrong shape

- **Test:** `chain_trailing_access_after_call_BUG.k` (FAIL)
- **Repro:** `a.b().c`
- **Symptom:** a trailing access after a call/subscript is dropped as a node
  and survives only in the ChainExpr label string. `.c` has no node; the outer
  `ChainExpr 'a.b().c'` directly wraps only the CallExpr.
- **Impact:** sema cannot resolve the trailing access, there is no node to
  attach field resolution to. Label and structure disagree.
- **Related:** `named_init_qualified_path.k` (FAIL), `geo::Shape::Circle { .. }`
  attaches the brace-init to the head segment `geo` instead of the full path,
  wrapping the initializer in a bogus ChainExpr. Same chain/segment family.
- **Fix direction:** make ChainExpr a flat ordered list of segment nodes
  (access / call / subscript), label derived from segments. Every access
  becomes a walkable node; label always agrees with structure.

## 2. Nondeterministic segmentation faults

- **Test:** none (not reproducible on demand)
- **Symptom:** rare segfault, no backtrace (corrupted stack -> unwinder has
  nothing to walk). Vanishes for long stretches. Surfaced once on the ERR pass
  of `alignof_err_integer.k` under lit (fd-redirection shifted timing).
- **Suspects, in order:** (a) uninitialized arena memory, recycled blocks carry
  stale bytes; a usually-zeroed pointer occasionally holds garbage. (b) data
  race in ThreadPool / WaveExecutor, timing/load dependent, classic Heisenbug.
- **No-backtrace clue:** leans toward memory corruption over null deref.
- **Hunt plan:** ASan build first (`-fsanitize=address -fno-omit-frame-pointer
  -g`), run suite + tight loop on the repro until it trips. If clean across many
  runs, switch to TSan (`-fsanitize=thread`) for the race angle.
- **Priority:** MUST fix before Stage 1 self-host. A parser that miscompiles
  0.1% of the time from a race is worse than one that fails loudly every time.

## 3. `lex_slice` OOB panic in fstring expression emission

- **Test:** `test_import.k` with `--print-tokens` (FAIL hard abort)
- **Repro:** Run `kairo Tests/Manual/test_import.k --print-tokens`; panics in `TokenBuffer::operator[]` with index out of bounds
- **Symptom:** `emit_fstring_exprs` calls `lex_slice<16>`, which allocates a `TokenBuffer<16>` (16-slot capacity). If the interpolated expression inside the fstring tokenizes to more than 16 tokens, the fixed-capacity buffer is overrun and the bounds check panics.
- **Call chain:** `lex_name -> lex_text -> emit_fstring_exprs -> lex_slice<16> -> TokenBuffer<16>::operator[]`
- **Root cause candidates:** (a) `lex_slice` template parameter is hardcoded to 16, which is too small for non-trivial expressions; (b) `emit_fstring_exprs` doesn't validate that the expression token count fits the buffer before indexing into it; (c) slice start/end bounds passed to `lex_slice` may be wrong (pointing past end of source range)
- **Fix direction:** Either make `lex_slice` dynamically sized / heap-backed once the expression exceeds a threshold, or audit `emit_fstring_exprs` to correctly bound the slice and assert/grow before indexing. The `<16>` template parameter being that small is a red flag expressions like `f"{some_fn(a, b, c)}"` will easily exceed it.
- **Priority:** Blocks any file that uses fstrings with non-trivial interpolated expressions. Fix before fstring support is considered stable.
