# Known Parser Bugs, guarded by failing regression tests

Each bug below has a regression test that FAILS on purpose until fixed.
When the test flips to PASS, the bug is resolved, update/remove the entry.

## 3. `lex_slice` OOB panic in fstring expression emission

- **Test:** `f"hello {name}"` with `--print-tokens` (FAIL hard abort)
- **Repro:** Run `kairo file -print-tokens`; panics in `TokenBuffer::operator[]` with index out of bounds
- **Symptom:** `emit_fstring_exprs` calls `lex_slice<16>`, which allocates a `TokenBuffer<16>` (16-slot capacity). If the interpolated expression inside the fstring tokenizes to more than 16 tokens, the fixed-capacity buffer is overrun and the bounds check panics.
- **Call chain:** `lex_name -> lex_text -> emit_fstring_exprs -> lex_slice<16> -> TokenBuffer<16>::operator[]`
- **Root cause candidates:** (a) `lex_slice` template parameter is hardcoded to 16, which is too small for non-trivial expressions; (b) `emit_fstring_exprs` doesn't validate that the expression token count fits the buffer before indexing into it; (c) slice start/end bounds passed to `lex_slice` may be wrong (pointing past end of source range)
- **Fix direction:** Either make `lex_slice` dynamically sized / heap-backed once the expression exceeds a threshold, or audit `emit_fstring_exprs` to correctly bound the slice and assert/grow before indexing. The `<16>` template parameter being that small is a red flag expressions like `f"{some_fn(a, b, c)}"` will easily exceed it.
- **Priority:** Blocks any file that uses fstrings with non-trivial interpolated expressions. Fix before fstring support is considered stable.

## 4. ClosureExpr parsing drops generics and params

- **Test:** TODO (no guard yet write a `--print-ast` closure case before fixing)
- **Symptom:** Closure parsing does not handle generic parameters or its parameter list cleanly; the `ClosureExpr` node comes out without them. The AST printer already has a standing note on this (`// params + generics not yet stored on the node`), so the gap is on the node/parser side, not the printer.
- **Fix direction:** Decide the closure storage shape (param list + optional generics, mirroring `FunctionDecl`'s `params`/`generic_params`), add the fields to `ClosureExpr`, and wire the closure parser to populate them. Once stored, RAV and the dumper can walk them like any other params.
- **Priority:** Blocks correct closures with parameters; required before closures are usable beyond the no-arg case.

## 5. FnDecl must accept a type-only signature (no param names, no body)

- **Test:** TODO (no guard yet)
- **Repro:** `fn foo(i32, f64) -> i32` a forward/abstract signature whose params are types only, with no names and no body. This is the same shape as an `FnType`/function-pointer signature and is legal.
- **Symptom:** The param-list parser (`_parse_param_list` in `DeclParse.k`) currently requires `name : type` for every non-`self` param it errors on a bare type with "expected parameter name". A type-only signature can't parse.
- **Fix direction:** Allow a param to be a bare type (no `name:` prefix) in `_parse_param_list`, producing a `ParamDecl` with an empty name token and the parsed type. Disambiguate `name: T` vs bare `T` by lookahead on the `:` after the first token. Confirm this only applies where a type-only sig is legal (bodyless `fn` decls / FnType position), and that named and unnamed params aren't mixed in one list (decide and enforce that rule).
- **Priority:** Medium blocks abstract/FFI-style signatures and any place a function-pointer-shaped decl is written with the `fn` keyword.

## 6. `TypeExpr` integration unverified

- **Test:** TODO (no guard yet)
- **Symptom:** Unclear whether `TypeExpr` is fully wired through the pipeline. The AST printer handles it (`src_type` routes `TypeExpr` to `src_expr(expr)`, RAV has `traverse_type_expr`), but whether the parser produces it in all the positions it should, and whether sema consumes it, has not been confirmed end to end.
- **Fix direction:** Audit where `TypeExpr` is meant to appear (type-position expressions, `typeof`-style constructs, dependent names), confirm the parser emits it there, and confirm sema resolves it. Write a `--print-ast` case that forces a `TypeExpr` and check it round-trips.
- **Priority:** Low/unknown until the audit says otherwise; promote if the audit finds a real gap.

## 7. `DeclContext.dc_decls` is not the complete member list it claims to be

- **Test:** TODO (the `--print-ast tree` class-body case in `BUG.k` is the de facto repro; promote to a guarded FileCheck test)
- **Symptom:** `DeclContext.k` documents `dc_decls` as "owned decls, in source order ... the COMPLETE source-ordered member list." For a **type body** (class/struct/union/interface/extension) this is false: the parser puts only **nested type decls** and the **`VisibilityGroupDecl` wrapper** into `dc_decls`. Flat fields and methods live in the node's `fields` / `methods` projection lists instead and are NOT in `dc_decls`. Enums put members in `variants` and never call `add_decl`, so an enum's `dc_decls` is empty. Only **modules** and the **TU** populate `dc_decls` completely.
- **Consequence:** Any consumer that trusts the comment and walks `dc_decls` for a type body silently drops every field/method and double-counts members that are also in a vis-group wrapper. This burned the AST-printer RAV rewrite through two wrong attempts: walking `dc_decls` printed an empty/duplicated class. The working dumper + RAV now use a hybrid walk (fields + methods + nested-types-from-`dc_decls`, skipping `VisibilityGroupDecl`, sorted by `SourceLocation` for the printer).
- **Root cause:** `_parse_member_body` / `_parse_member_vis_group` in `DeclParse.k` push flat members to the `fields_out`/`methods_out` buffers and push only nested types + the group wrapper via `owner->add_decl`. `_parse_enum` never calls `add_decl` at all.
- **Fix direction:** Pick one and make it true:
  - (a) **Make the comment honest:** change it to "nested type decls and visibility-group wrappers only; flat members live in `fields`/`methods` (enums: `variants`)." Cheapest; leaves every consumer on the hybrid walk.
  - (b) **Make `dc_decls` honest:** have the parser push **every** member (fields, methods, variants, nested types) to `dc_decls` in source order, in addition to (or instead of) the projection caches. Then printer + RAV collapse back to a single `dc_decls` walk, no hybrid merge, no source-sort, and the `SourceLocation`-ordering assumption disappears. More work, but it pays back at every future tree consumer (sema, codegen, LSP).
- **Priority:** Medium it didn't crash anything, but it's a latent trap that costs every new AST-walking pass real time. Sema will hit it next.

## 8. Attribute args stored as `*void` (Stage 0 forward-decl limitation), labels via grammar fold

- **Status:** Args and named-arg labels now RENDER correctly in `--print-ast`
  (`@deprecated("use NewThing", since: 2)` dumps faithfully). This entry tracks
  the underlying storage-typing debt, not a render gap.
- **Storage:** `AnnotationEntry.args` is `FrozenList::<*void>`, NOT because the
  data is untyped but because Stage 0 cannot forward-declare `Expr` in
  `Annotation.k` separately from its full definition in `Base.k` (cross-file
  fwd decls land in different generated namespaces -- the same limitation
  behind `class HoistedScope;` in `ASTContext.k`). The grammar guarantees every
  element is an `Expr*` (attr args reuse the call-arg production verbatim), so
  the single `reinterpret_cast::<*Expr>` read site in the AST printer's
  `_dump_one_annotation` is sound.
- **Labels:** Named args (`since: 2`) are NOT lost. `_parse_call_args` folds
  `name: value` onto `AssignOperatorExpr(lhs=name, rhs=value, op_token=<colon>)`
  -- the op_token is a synthesized `OpColon`. The printer discriminates named
  args from genuine positional assignments (`foo(x = 4)`, same node kind) on
  `op_token.kind == OpColon`, not on node type.
- **Fix direction (Stage 1):** When Stage 1 self-hosting removes the cross-file
  fwd-decl limit, change `AnnotationEntry.args` from `FrozenList::<*void>` to
  `FrozenList::<*Expr>` (the STAGE0 comment in `Annotation.k` says exactly this),
  delete the `reinterpret_cast` at the printer read site, and fix the `add_attr`
  signature to take `FrozenList::<*Expr>` (it already RECEIVES one from
  `consume_leading_annotations` -- the `void*` is a storage-side downcast).
- **Downstream note (sema):** A named arg and a positional assignment expression
  are the same `AssignOperatorExpr` node kind, distinguished ONLY by
  `op_token.kind` (`:` vs `=`). Any sema pass validating call/attr args must
  discriminate on the token, not the node type, or it will conflate `f(x: 4)`
  with `f(x = 4)`.
- **Priority:** Low (cosmetic + latent typing debt). The Stage 1 field flip is
  the real resolution; until then the contained cast + token-discriminated
  render is correct.