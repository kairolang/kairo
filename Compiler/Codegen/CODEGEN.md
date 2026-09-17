# Codegen: from a checked tree to C++ tokens

Companion to IMPORTS.md (§6, §7) and RESOLUTION.md. This document is the
contract for everything under `Compiler/Codegen/` and for the Lower/ passes
that feed it. Where it disagrees with either, it is newer and wins.

## 0. The model

Kairo lowers to C++ by injecting a token stream into clang. Every emitted
TU is: a PREAMBLE (the declarations a header would have provided, own and
foreign), the BODIES the TU defines, then the explicit instantiation
definitions it homes. Nothing is `#include`d except ffi headers.

Three rules govern the whole layer:

1. **Sema decided everything; codegen renders decisions.** Every name is
   spelled from a `*Decl`; every type from a canonical; every call from
   the promoted callee. Codegen never looks anything up and never asks
   clang to.
2. **No headroom for clang.** The emitted C++ gives clang nothing to
   choose: names fully qualified, every argument exactly its parameter's
   type, every compound expression parenthesized, user operators as
   explicit calls, `extern template` for every instance not homed here.
3. **Lower/ reduces; codegen emits the core.** EmitIR knows the C++-shaped
   subset of Kairo (§6). Every other node ICEs naming the Lower/ pass that
   owns it. Codegen never grows an arm for a node a lowering removes.

## 1. Pipeline

    FrontendAction::_codegen      per non-foreign fid, DAG order
      CodegenBackend::run(out)     one clang invocation, one .o
        fill(TokenSink)
          EmitPlan(Preamble)       §3
          InterfaceEmitter::run    tiers 0–2 + extern template (tier 3 non-home)
          EmitIR::emit_tu          own bodies; foreign template bodies homed here
          InterfaceEmitter::emit_home_instantiations   tier 3 home (after bodies)
          eof

Objects land at `<obj-dir>/<module path>.o` (`--obj-dir`; a single-TU
build with `-o x.o` uses that). `--print-cxx` runs the same plan into a
TextSink; `--emit-headers <dir>` runs `EmitPlan(Header)` into
`<dir>/<module path>.hh`. Both work under `--type-check-only`.

## 2. Sinks

`EmitSink` (base): `spell(at, text)` tokenizes a C++ fragment into
identifiers/keywords/punctuators/integers; sugar (`kw_*`, `punct`, `brk`,
`directive`). `TokenSink`: located clang tokens; every token blames a Kairo
location through `ClangLocMap::to_clang`, any registered fid, so a foreign
declaration's tokens carry the foreign file. `TextSink`: bytes with the
spacing rules (tight before `::` `<` `>` `(` `)` `*` `&` `,` `;` `:`,
tight after `::` `<` `(` `~`; `::` tight only after a word). Emitters import
`CodegenContext` only; clang types are visible transitively.

## 3. EmitPlan

Per TU, the set of declarations the emitted C++ needs, with strengths and
order. Roots: every own decl (Preamble) or own `pub` decl (Header), plus
every foreign decl reached through `resolved_decl`, candidate cells and
`RecordType::decl`. Decls from a C++ header are never emitted.

Edges (IMPORTS.md §6.2): by-value fields/bases/alias targets Complete;
pointers, signature types Fwd. Refinements decided since:
- An instance shell admits its PRIMARY at Complete and each argument at
  the strength the primary's by-value spine gives it (`param_by_value`,
  memoized, depth-capped).
- A member call admits the OWNER at Complete (C++ cannot call into an
  incomplete class).
- An extension member is a free function; it never appears twice (a
  `FunctionDecl` whose `lexical_dc` is an Extension is routed to the
  extension path on admission).
- A class at Complete admits its SAME-FILE extension members at Fwd before
  it (friends); `friends_of()` filters by fid.

Tiers: 0 forward declarations; 1 definitions, topo-sorted on Complete;
2 function declarations; 3 instantiations (`extern template` unless this
TU is the instance's home, `template class` if it is). Entry-TU decls go
in the unnamed namespace; `main` is emitted at global scope and never
declared in the interface.

## 4. CXXSpell — the one speller

Every C++ spelling of a Kairo entity comes from `CXXSpell`, and both
emitters use the same instance; a declaration and a body cannot disagree.
- `qual_name(d)`: `::` + module segments (root name + path, RESOLUTION
  invariant 9a) + owner types + leaf. Module segments resolve `SymbolID`s
  through the PP table.
- `leaf(d)`: identifier, or for an operator `operator_name(f)`: `operator+`,
  `operator[]`, `operator<=>`, `operator T` for `op as`, `~Owner` for
  `op delete`; word operators map to symbols; `l`/`r` on `++`/`--` is
  fixity (`op_is_postfix`), not name. Operators C++ cannot spell come from
  `LowerTargets` (`__kairo_contains`/`__kairo_iter` for the two `op in`,
  `__kairo_pow`, `__kairo_deep_eq`, `__kairo_dotstar`, `__kairo_await`).
- `_type(t)`: canonical → C++; builtins by table (`i32` is
  `::std::int32_t`), records qualified with instance args from the
  registry, pointers, references, C arrays in `decl()` form. Structural
  containers are gone (builtin records); `T?` and tuples ICE naming their
  lowering.
- `param_type(p)`: modes → `T&` (`@inout`), `T&&` (`@move`), `T`. The
  `const T&` rule for by-value records is DECIDED and not yet applied.
- `template_head(d)`: `template <class T, ...>`.

## 5. InterfaceEmitter

Walks plan entries by tier. Records: `class`/`struct` with access
specifiers, fields, method DECLARATIONS (never bodies — invariant 12),
friend lines, nested types. Enums: C-like only. Functions: free and
extension (receiver first). Tier 3: `extern template class X<A>;` /
`template class X<A>;`. Header mode adds `#pragma once` and `#include`s of
the Complete dependencies' headers.

V1 refusals (each an ICE naming its owner): ADT enums, unions, interfaces,
parameter defaults (CallLowering removes the need), field initializers,
packs, method bodies in headers.

## 6. EmitIR — the core

Declarations are the plan's; EmitIR writes bodies. What it knows:

    names, chains (`.`/`->` from the base's canonical; `::` collapses to
    the last scope-resolved decl's qualified name), calls, literals,
    primitive operators, casts, `if`/`while`/`for(;;)`/C-style `for`,
    `return`/`break`/`continue` (unlabeled), locals, blocks, named and
    anonymous initializers (designated, declaration order, aggregates
    only), `sizeof`/`alignof`/`delete`, `unsafe` (transparent), array
    brace lists as variable initializers.

Definitions it produces: free functions (namespace wrapper per function),
methods out of line (`RET Owner<T>::name(params) const`), constructors and
destructors, extension members as free functions with the receiver first,
template member bodies (own TU always; homing TUs via the plan), `int
main()` at global scope.

The no-headroom rules, each with one home:
- `_name`: locals bare (params, body vars, binders, generic params);
  `self` → `this` in a method, `self` in an extension member; everything
  else `qual_name(resolved_decl)`. A `candidate_cell` here is an X gate
  failure.
- `_chain_prefix`: separator from the base's canonical; operator steps
  spell `leaf(resolved_decl)`.
- `_call`: callee = promoted decl; a type as callee is a ctor call; a UFCS
  step is `::ns::m(&recv, args)` (until ExtensionLowering makes the tree
  say it).
- `_arg`/`_value`: `static_cast<P>(a)` whenever the argument's canonical
  differs from the parameter's (records excluded; they copy-construct);
  `@inout` emits the operand bare; `@move` emits `static_cast<T&&>(x)`
  for lvalues.
- `_binary`/`_unary`/`_assign`/`_subscript`/`_cast`: primitives only,
  parenthesized; a record operand is an ICE naming OperatorLowering.
- `_var_decl`: an inferred type is the shared canonical (no range) and is
  spelled at the binding's name; a null type is `I011W` + `auto` — the
  only diagnostic codegen emits.

ICE map (node → owner): match/MatchExpr → MatchLowering; try/finally/
panic/assert → PanicLowering; ranged for/ranges/slices → IterLowering;
`?.`/`??`/`T?` → the nullable trio; f-strings → FStringLowering; yield →
YieldLowering; closures → lambda emission (unwritten); await/spawn/thread
→ async lowering; list/set/map literals → ListLiteralLowering; labeled
break/continue → label lowering; typeof/impl/derives tests →
TypeQueryLowering; NamedArgExpr → CallLowering.

## 7. Templates

No monomorphizer (IMPORTS.md §7). Bodies are emitted as C++ templates in
the template's own TU and in every TU that homes an instance; `extern
template` declarations sit in the preamble; explicit instantiation
DEFINITIONS are emitted after every body, because an explicit
instantiation only instantiates members defined before it. A `<T impl I>`
body's call into the bound goes through the interface's witness
(`I_witness<T>::m(&x, ...)`), emitted by `EmitWitness` from
ConformanceChecking's table: the primary forwards structurally
(`requires requires { s->m(); }`), specializations exist only for
extension and builtin conformances, and the derived concept `I_c<T>` is
the one `requires` an emitted template may carry (revising invariant 13).
Until EmitWitness lands, a callee owned by an `InterfaceDecl` is an ICE.

## 8. Diagnostics

Codegen reports through the TU's `diag_sink`, drained by the driver after
the object is written. One code: `I011W` (unresolved type reached codegen;
`auto` emitted). Everything else is an ICE with the owning pass in the
message; an ICE list is the work list.

## 9. Tests

`Tests/Codegen/emit_plan_diamond`: five TUs, foreign definitions per TU,
extension call through a field path, homed template instance, one `.o`
per module, `clang++ -Wodr` link, exit 9. `Tests/Codegen/operators`,
`Tests/Codegen/defaults`, `Tests/Codegen/slices`: one per lowering, each
with a `--print-cxx` golden and a link that exits with a computed value.
`--print-cg` goldens carry the fid column and preamble offsets.

## 10. Open

Piece 1 (root naming by `module X;` declaration; `-I` becomes C++-only);
`const T&` for by-value records; witnesses/concepts; per-TU header reuse
across FrontendActions; namespace merging in EmitIR (cosmetic);
`ReturnStmt` keyword token; `TextSink` binary spacing outside parens.