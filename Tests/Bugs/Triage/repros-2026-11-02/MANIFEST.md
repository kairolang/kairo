# Kairo bug repros (2026-11-02)

Found writing idiomatic programs: generic sort, generators, a small
interpreter tour, error-path benchmarks. Every file is standalone and was
checked against `kairo-0.1.1+dev.20261102` (with the allocator patch) on
x86_64-linux-gnu. Each header states expected vs actual.

```fish
for f in 0*.k 1*.k
    echo == $f
    kairo $f -I . -o /tmp/r; and /tmp/r; echo "exit $status"
end
```

| # | File | Kind | Actual | Expected | Workaround today |
|---|---|---|---|---|---|
| 01 | `01_extend_primitive_operator_iface.k` | codegen | CL001E: `extend i64 impl Less { fn op < }` emitted as a C++ `operator<` on `long` | i64 satisfies the interface; exit 2 | wrap the primitive in a struct |
| 02 | `02_generic_deref_no_type.k` | sema | I011W "'m' reached codegen with no inferred type" for `var m = *a`, `a: unsafe *T` in a generic; runs correctly (exit 2) | no diagnostic | `var m: T = *a` |
| 03 | `03_yield_temporary.k` | library/codegen | CL001E: `yield i * i` can't bind a temporary to `yield_value(@inout v: T)` | exit 14 | yield a named variable |
| 04 | `04_generator_perf.k` + `.cc` | perf | 3-stage generator pipeline: 26.5 instr/item vs 13.0 for C++20 coroutines (clang 18); 1.76 s vs 1.33 s at N=1e9. No heap frames; resumes stay indirect | parity with clang CoroElide | none |
| 05 | `05_const_binder_pointer_payload.k` | codegen | CL001E: `case .Add(const l, const r)` on `*Expr` payloads binds `const Expr*` (pointee const) | `Expr* const`; exit 5 | `var` binders |
| 06 | `06_const_slice_index.k` | codegen/library | CL001E: no const `operator[]` on a `const xs: [i64;]` parameter | exit 9 | non-const slice param, or `for x in xs` |
| 07 | `07_noinline_panic_attr_order.k` | codegen | CL001E "'nodiscard' attribute cannot be applied to types": `__attribute__((noinline)) [[nodiscard]]` on a panicking fn | exit 7 | drop `@no_inline` |
| 08 | `08_override_warning_leak.k` | codegen | clang C505W "overrides a member function but is not marked 'override'" reaches the user; runs (exit 6) | no warning: emit `override` | none (warning only) |
| 09 | `09_string_eq.k` | library | SC066E no `op ==` on `string` (declared, not defined) | exit 1 | length + `memcmp` on `as_ptr()` |
| 09b | `09b_string_c_str.k` | library | R025E no `c_str` on a `string` parameter; `as_ptr()` is `*const u8`, not passable as `const char*` | exit 2 | none clean |
| 10 | `10_catch_block_value.k` | language (design call) | S054E: `catch e: Bad => { code = e.code; 10 }` parses `{` as a set literal | exit 11, or a clear "block expressions not supported" error | helper function in the arm |
| 11 | `11_kcc_links_kairo_runtime.cc` | driver | kcc on pure C++ links Kairo's runtime; with the mimalloc runtime the program's malloc silently becomes mimalloc (`nm` shows `T mi_malloc`) | C++-only kcc builds use the target's own runtime, or document it | none |

Notes
- 08 is the only one that builds; 02 and 04 run correctly and are about a
  diagnostic and performance respectively.
- 11 only shows when the program really allocates (an allocation clang can
  elide doesn't pull mimalloc in), hence the escaping pointer.
- Not bugs, but worth a docs line: `finally` runs when the enclosing block
  exits (scope-guard / `defer` semantics), not right after `try`; payload
  binders bind by field name (`case .Add(var l, var r)`).

## Triage (2026-11-02, main at c21e1d2f)

| # | Status |
|---|---|
| 01 | new: |
| 02 | new: (same family as ) |
| 03 | new: |
| 04 | new: (perf) |
| 05 | new: |
| 06 | fixed by d32371d3 (slice subscripts take `const self`); exits 9 now |
| 07 | new: |
| 08 | new: |
| 09 | in progress: string `op <=>` (branch bi-string) |
| 09b | duplicate: the 2026-10-26 c_str ticket; `c_str()` in progress on bi-string |
| 10 | user error (an arm is one `=> expr`; `=> ({ code = e.code; (10); })` works, exit 11), unclear message: |
| 11 | duplicate: |
