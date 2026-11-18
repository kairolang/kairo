# Known Parser Bugs, guarded by failing regression tests

Each bug below has a regression test that FAILS on purpose until fixed.
When the test flips to PASS, the bug is resolved, update/remove the entry.


## 4. ClosureExpr parsing drops generics and params

- **Test:** TODO (no guard yet write a `--print-ast` closure case before fixing)
- **Symptom:** Closure parsing does not handle generic parameters or its parameter list cleanly; the `ClosureExpr` node comes out without them. The AST printer already has a standing note on this (`// params + generics not yet stored on the node`), so the gap is on the node/parser side, not the printer.
- **Fix direction:** Decide the closure storage shape (param list + optional generics, mirroring `FunctionDecl`'s `params`/`generic_params`), add the fields to `ClosureExpr`, and wire the closure parser to populate them. Once stored, RAV and the dumper can walk them like any other params.
- **Priority:** Blocks correct closures with parameters; required before closures are usable beyond the no-arg case.

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

## 10. Statement separators only recognize newlines, not semicolons

- **Test:** TODO
- **Repro:**
  ```kairo
  var x = 1; var y = 2
  foo(); bar()
  return; foo()
  ```
- **Symptom:** The parser treats physical newlines as statement separators but
  does not yet accept `;` as an equivalent separator.
- **Expected:** Outside of grammar contexts where `;` has structural meaning,
  semicolons should be accepted anywhere a newline currently terminates a
  statement.
- **Must not regress:**
  ```kairo
  [i32; 10]
  ```
  where `;` remains part of the array-type grammar rather than a statement
  separator.
- **Fix direction:** Make semicolon consumption context-sensitive. Expression
  and type parsers must retain ownership of `;` where it belongs (array types,
  future grammar extensions, etc.), while statement parsing should otherwise
  treat it identically to a newline.
- **Priority:** Medium. Improves interoperability and formatting flexibility.

---

## 11. Generic specialization is not fully parsed (functions, classes, and partial specialization split)

- **Test:** TODO

- **Repro:**
  ```kairo
  // Function generic (primary)
  fn <T> sum(items: [T]) -> T

  // Function explicit specialization
  fn <> sum<i32>(items: [i32]) -> i32


  // Class generic (primary)
  class <> Box<T> {
      var value: T;
  }

  // Class explicit specialization
  class <> Box<i32> {
      var value: i32;
  }

  // Class partial specialization
  class <> Box<[T]> {
      var value: [T];
  }
  ```

- **Symptom:** The parser does not currently support generic specialization
  constructs consistently across declaration types. Explicit specialization and
  partial specialization syntax are either rejected or incorrectly parsed,
  especially for class-like declarations.

- **Expected:**
  Generic specialization must be supported for:
  - classes
  - structs
  - unions

  Supported forms:
  - Primary generic declaration
  - Explicit specialization (`<>`)
  - Partial specialization (specializing a subset or pattern of generic params)

  Functions:
  - Only primary generics and explicit specialization are supported
  - Partial specialization is NOT supported for functions

- **Fix direction:**
  - Extend declaration parsing to support specialization suffixes after the
    identifier for class/struct/union declarations
  - Add AST representation for specialization variants (primary / explicit /
    partial)
  - Restrict partial specialization parsing strictly to type-like declarations
    (class/struct/union)
  - Ensure function declaration parsing only accepts primary + explicit
    specialization, rejecting partial specialization patterns

- **Priority:** Medium. Required for a consistent generic system across type
  declarations and function specialization semantics.

---


## 12. Parenthesized expressions are rejected in several valid expression contexts

- **Test:** TODO
- **Repro:**
  ```kairo
  Foo<i32, (N < 3)>
  foo((bar))
  (((x)))
  ```
- **Symptom:** The parser is overly aggressive when handling parenthesized
  expressions. Expressions which parse correctly without redundant parentheses
  fail once wrapped, even though they remain syntactically equivalent.
- **Examples:**
  - `Foo<i32, N < 3>` parses.
  - `Foo<i32, (N < 3)>` does not.
  - `foo(bar)` parses.
  - `foo((bar))` does not.
- **Expected:** Parentheses should behave as transparent grouping operators
  unless a grammar rule explicitly assigns them additional meaning.
- **Fix direction:** Audit expression parsing and generic-argument parsing to
  ensure parenthesized expressions recurse back through the normal expression
  parser rather than introducing context-specific restrictions.
- **Priority:** High. This affects ordinary expression parsing and makes valid
  code unexpectedly fail depending solely on grouping.