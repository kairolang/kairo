# Format strings

An f-string (`f"x={x:>4}"`) compiles to straight-line calls on one `FmtBuf`: a capacity computed at compile time, one `text` call per run of literal bytes, one `put_*` call per hole, and one `finish`. Nothing is parsed and nothing is dispatched at run time. The format-spec grammar and what each spec means are in the website reference (strings / formatting); this document covers the lowering and the library type it targets. Where `FStringLowering` runs among the lowerings is [Lowering.md](Lowering.md#pass-order).

| File | Role |
|---|---|
| `Compiler/Sema/Type/LiteralTyping.k` | types each hole and records its facts (`fmt_holes`), binds the `FmtBuf` members |
| `Compiler/Sema/Lower/FStringLowering.k` | the rewrite |
| `Compiler/AST/LangItems.k` | `fmt_pack_spec`, `fmt_put_name`, `LangMembers::fmtbuf_*`, `LowerTargets::fmt_dyn` |
| `Lib/builtin/fmt/fmt_buf.k` | `FmtBuf`, the runtime writer |
| `Lib/rt/fmt*.c`, `Lib/rt/fmt.h` | the integer and float formatters `FmtBuf` calls |

## Lowering

### Hole facts

ExprTyper decides everything; `FStringLowering` only builds nodes. `LiteralTyping::type_string_literal` binds, for every f-string, the `FmtBuf` constructor, `text`, `finish` and the string's `length` accessor (`fmt_ctor`, `fmt_text`, `fmt_finish`, `fmt_len`), and records one `FormatHole` per hole in `fmt_holes`:

| Field | Meaning |
|---|---|
| `kind` | the `FormatKind` row: a builtin, `String`, `Ptr`, or `None` for a record |
| `put` | the `FmtBuf` method (`fmt_put_name`: `put_<kind>`, `put_str`, `put_ptr`) |
| `conv` | a user conversion called first: `repr()` preferred, then `op as` returning `string`; `?` skips `op as` |
| `cast_to` | a cast applied first: a pointer to `usize` (unsafe), a plain enum to its underlying integer |
| `by_addr` | the value's address is printed (a record with no conversion) |
| `spec` | the packed spec word (below) |
| `deferred` | the value's type belongs to a generic body: the instance picks the put |

A proven-non-null nullable place in a hole formats as its value ([Nullables.md](Nullables.md#passes)); an unproven one stays `T?`, which has no formatter (SC081E). An `f80` hole is SC081E (`put_f80` is not in the builtin root). A spec on a deferred hole is SC080E. A bounds-checked generic parameter formats through a `repr` or `op as` requirement of its bounds, called through the witness.

### The rewrite

```kairo
f"x={x:>4} v={v}"        // x: i32, v: Vec2 with a user `repr`
->
({
    var __kairo_arg0 = (v).repr()
    var __kairo_fmt0 = FmtBuf(16 + __kairo_arg0.len)
    __kairo_fmt0.text("x=" as unsafe *const u8, 2, 2)
    __kairo_fmt0.put_i32(x, 0x0400000000000004)
    __kairo_fmt0.text(" v=" as unsafe *const u8, 3, 3)
    __kairo_fmt0.put_str(__kairo_arg0, 0)
    __kairo_fmt0.finish()
})
```

`transform_string_literal_expr` rewrites each f-string, inner f-strings in holes first, into a statement expression in four steps:

1. Bind, in source order. A hole that is impure (not `LowerSynth::pure`), converted, a string, a by-address prvalue or deferred is bound to a `__kairo_argN` local; a pure primitive is read in place. This keeps `f"{a()}{b()}"` calling `a` then `b`, and gives a prvalue record an address to print. A converted or string hole's local also joins the capacity (its length is read at run time). A deferred hole's local is a forwarding reference (`place_ref`).
2. Size the buffer once: `FmtBuf(<bound> + <each string local>.length())`.
3. Emit `text` for each run of literal bytes (with its byte and codepoint counts, both constants) and one `put` per hole, in order. `put_ptr` also receives the pointee's spelling and its length.
4. The value is `finish()`, typed `string`.

An f-string with no holes is retyped as a plain literal and left to StringLowering. Postcondition: no f-string `StringLiteralExpr` reaches StringLowering or codegen.

### Capacity bound

`_max_bytes` gives each hole's widest print, and `_collect_text` adds the literal bytes (an over-estimate, since escapes shrink). The bound must never be smaller than what the matching `put_*` reserves, or the buffer grows mid-format; any shortfall costs a reallocation, never correctness.

| Kind | Bound |
|---|---|
| `bool` | 5 |
| `char` | 6 (quoted and escaped) |
| `byte` | 4 |
| string | 2 (the quotes of `?`); its bytes are added at run time |
| pointer | pointee spelling + 22 |
| integers | `_int_max(bits, base)`: digits, sign and prefix (base 10: 4, 6, 11, 21, 40, 79, 156 for 8 to 512 bits; base 16 `bits/4 + 3`, base 8 `(bits+2)/3 + 3`, base 2 `bits + 3`) |
| floats | `p + 16`, with `p` the precision or 6 |
| deferred | 32 (a guess; a short buffer only grows) |

Width pads in codepoints, so a hole's bound is at least `width` times the fill's UTF-8 length.

The float row is narrower than the library: `put_f32` / `put_f64` with spec 0 reserve 32 bytes, and every other float print goes through `float_open_`, which reserves `width*4 + 8 + 2*(digits)`. A float hole therefore grows its buffer once. Raising the row to match the library is unimplemented.

### Deferred holes

A hole whose type only the instance knows (`FormatHole::deferred`: a `T`, or a member result the compiler cannot type) is put by `::__kairo_fmt_put(buf, arg, name, len, 0)` (`CallExpr::fmt_dyn`, `LowerTargets::fmt_dyn`). That preamble template, written by InterfaceEmitter ([Codegen.md](Codegen.md#interfaceemitter)), picks the put from the value's C++ type in LiteralTyping's order: a builtin's row, a string, a pointer's address, a plain enum's discriminant, a record's `repr()`, its `op as` string, its address. An instance with none of these fails in C++ with a `static_assert`.

### Borrowed views and write lowering

Three lowering changes are designed and not implemented. None changes syntax.

- **Borrowed view.** An f-string passed directly (parentheses allowed) as the argument of a `const s: string` parameter, in a call evaluated unconditionally once per execution of its statement, is built on a statement-level `FmtBuf` inserted before the statement and passed as `__kairo_fmtK.view()`. A `const` string parameter is already a borrow (const parameters pass by reference), so no attribute marks it. "Unconditionally once" excludes operands of `&&` / `||` / `??`, if/match/try expression arms, loop conditions and `for` steps, other f-string holes and closure bodies. Host statements: expression, `DeclStmt` initializer, `return`, and the subject of an `if` / `match`. Arguments before the f-string that are not pure are bound to `__kairo_argN` first; those after it stay in place, preserving source order. A statement expression cannot host it, since its locals die before the call runs. Soundness needs an escape check on `const string` parameters: an error when the parameter (or a local initialized or assigned from it) is returned, stored in a global, static or thread variable, stored through a field, index or pointer whose base is not a local of the function, captured by a closure, passed to a non-`const` string parameter, or moved or passed to `@inout` / `@move`.
- **`buf.write(f"...")`.** A call of `FmtBuf::write` whose argument is an f-string literal lowers onto the receiver: the receiver evaluated once (in place for a pure path, else through `var *__kairo_wK = &(R)`), one `reserve(<bound>)`, then the puts; the result is `void`.
- **Float bound**, as in [Capacity bound](#capacity-bound).

The std export of `FmtBuf` for users (a `std` re-export of `builtin::fmt::fmt_buf::FmtBuf`) is part of the same work and not done.

## Runtime writer

### FmtBuf

`FmtBuf` (`Lib/builtin/fmt/fmt_buf.k`, lang item `WellKnownType::FmtBuf`) holds `data`, `len`, `cp_len`, `cap` and a 128-byte inline array (`FMTBUF_INLINE`). Every writer counts what it writes: a formatter emits ASCII and adds its byte count to `cp_len`, `text` is told its counts, `put_str` copies the source's. No producer scans its output.

| Member | Behaviour |
|---|---|
| `FmtBuf(cap)` | `cap < 128`: on the inline array (`cap = 127`), no heap. Otherwise one heap block of `cap + 1` from `alloc_raw`, taken now |
| `FmtBuf()` | empty, on the inline array |
| `text(p, n, cp)` | appends literal bytes |
| `put_<kind>(v, spec)` | one per builtin kind (`put_bool` ... `put_u512`, `put_f16`, `put_bf16`, `put_f32`, `put_f64`, `put_f128`), `put_str`, `put_ptr` |
| `finish()` | spilled: hands the heap block to the result string; inline: one allocation of exactly `len + 1`. The result owns its block. The buffer is left empty with `data` null |
| `view()` | a borrowed `string` (capacity 0) over the bytes, NUL-terminated, valid until the buffer is written again or destroyed |
| `clear()` | `len = cp_len = 0`, storage kept |
| `reserve(n)` | room for `n` more bytes |
| `write(const s)` | appends `s` as `{s}` would |
| `op finally` | frees a spilled block `finish()` never handed over |
| copy, move | deleted: `data` may point into the object |

Growth (`grow_`) doubles, or takes the need if larger. The first spill copies the inline bytes into a fresh heap block; later growth uses `resize_raw`. Heap blocks go through `alloc_raw` / `resize_raw` / `free_raw`, the allocator in effect, so a block `finish()` hands over is freed correctly by `string`'s destructor.

`put_f32` / `put_f64` with spec 0 reserve 32 bytes and the runtime writes the shortest digits in place (the shortest `f64` text is at most 24 bytes). Every other float print reserves the padded result and a digit slot above it (`float_open_`), so `number_` never moves the buffer after formatting. Integer printing writes digit pairs from a 200-byte table.

### Spec word

One `u64`, packed at compile time by `fmt_pack_spec`; 0 means all defaults, which is what most holes pass.

| Bits | Field |
|---|---|
| 0..15 | width, 0 = none |
| 16..31 | precision + 1, 0 = none |
| 32..52 | fill codepoint, 0 = space |
| 53..54 | align: 0 the kind's default, 1 `<`, 2 `>`, 3 `^` |
| 55..56 | base: 0 = 10, 1 = 16 (or `e` on a float), 2 = 8, 3 = 2 |
| 57..61 | flags: 1 `+`, 2 `#`, 4 `0`, 8 upper, 16 `?` |
