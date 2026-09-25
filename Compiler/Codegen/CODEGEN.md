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

Rule 1 covers the lang records too. Every lang record at concrete arguments
is built through `SemaContext::lang_record`, which registers the instance
(`InstantiationRegistry::instance_for`) and points the `RecordType` at the
INSTANCE node, exactly as a written `Foo<i32>` does. A written `[i32;]`, a
literal that took `[i32;]`, and a spelled-out `Slice<i32>` are therefore one
canonical, and that instance has a home TU for its explicit instantiation.
`TypeResolve::_lang_record` and `TypeUtil::lang_record` both delegate to it;
nothing else builds a lang record. A dependent use keeps the primary.

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

Identifiers are never byte-borrowed. `TokenSink` spells an identifier from
the `IdentifierInfo` and reads the range as caret geometry alone, so
`EmitIR::_name(Token)` always goes through `create_ident` with the spelling
from the imm table of the file that OWNS the body being emitted — for a
foreign template homed here, that is not this TU. Float and char literals
still borrow their bytes (`synth` → `literal`), so a lowering that mints one
must spell it from its value, as `_int_lit` does.

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
in the file's own namespace (§5); `main` is emitted at global scope and
never declared in the interface.

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
  `__kairo_pow`, `__kairo_dotstar`, `__kairo_await`). `===` is not an
  operator a type declares: it is the nullable test, owned by the nullable
  trio, and has no spelling here. An EXTENSION operator is a non-member
  C++ operator taking `X&` / `const X&` (a class-typed parameter is what
  [over.oper]/7 asks for), spelled exactly as a member's is; its body
  binds `self` to the address of that reference
  (`X* self = &__kairo_self;`), so the body emits unchanged. Every Kairo
  use is an explicit call that passes the object, not its address.
- `_type(t)`: canonical → C++; builtins by table (`i32` is
  `::std::int32_t`), records qualified with instance args from the
  registry, pointers, references, arrays through `decl()`. Structural
  containers are gone (builtin records); `T?` and tuples ICE naming their
  lowering.
- `decl(t, name)`: the declarator form, the name folded in. `[T; N]` is a C
  array: it is a local, a field, a literal, a `const`/`@inout` parameter,
  and what a slice views; it is not copied, assigned, passed by value or
  returned, and X rejects all four. A `[...]` literal with no container
  target has type `[T; N]`. A declarator that starts with `*` or `&` is
  parenthesized before the array suffix (`signed int(*)[2]`, not
  `signed int*[2]`).
- `param_type(p)`: modes → `T&` (`@inout`), `T&&` (`@move`), `T`. The
  `const T&` rule for by-value records is DECIDED and not yet applied.
  This is the name-less form, and the right one for everything that is not
  an array.
- `param_decl(p, name)`: the parameter spelling with the name folded into
  the declarator. Arrays are the case it exists for: a `const [T; N]`
  parameter is `const T (&name)[N]`, an `@inout` one is `T (&name)[N]`, and
  by value is an ICE (StmtTyping rejects it). Both emitters spell
  parameters through here.
- `return_spelling(f)`: a method's C++ return type; `_ret` in both
  emitters goes through it. Place operators (`[]`, `.*`, `->*`) are
  declared `-> *T` / `-> *const T` and spelled `T&` / `const T&`, so an
  imported `T&` and a Kairo place are one ABI; `->` stays a pointer (C++'s
  `operator->` returns one). OperatorLowering rewrites the body's `return`
  (`return &x` -> `return x`, `return p` -> `return *p`), and EmitIR's
  `_return` checks the value against the pointee, not the pointer.
- `template_head(d)`: `template <class T, ...>`.

## 5. InterfaceEmitter

Every Preamble — never a Header, which carries no bodies — opens with

    template <class T, decltype(sizeof(0)) N> using __kairo_array = T[N];

(`LowerTargets::array_alias`). It is an alias, so it is never instantiated.

Namespace wrapping: an entry-TU decl lives in `namespace <file stem>`, the
stem sanitized to an identifier (`CXXSpell::entry_stem`); a `priv` or
`internal` decl goes one level deeper, into an unnamed namespace nested
inside it (`CXXSpell::is_anon`); `main` stays at global scope. Qualified
names are unchanged — `::stem::x` reaches into the unnamed namespace through
C++'s implicit using-directive — so `qual_name` knows nothing about any of
it. Library roots still wrap by `module_base` (Piece 1 open).

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
    only), `sizeof`/`alignof`/`delete`, `unsafe` (transparent),
    `InitListExpr`, `StmtExpr`.

`InitListExpr` is the C++ braced-init-list, and array-typed only. Its two
spellings are chosen by POSITION: the bare `{...}` as a `VariableDecl`'s
direct initializer and as an element sitting directly inside another array
`InitListExpr` (C++ cannot initialize an array element from an array
prvalue); the prvalue `::__kairo_array<T, N>{...}` everywhere else, alive to
the end of the full-expression. Both are valid C++17, but GCC rejects the
decay of a prvalue array ("taking address of temporary array") and clang
does not — bodies only ever go through clang, and that is a HARD dependency
of this layer, not a preference.

`StmtExpr` is the GNU statement expression `({ s0; s1; e; })`, whose value is
its last statement. SequenceLowering mints it to write Kairo's left-to-right
argument order into the tree; nothing parses into it. The block emits as any
block and the parens are what make it a value. Like the array prvalue it is
clang-only -- it is not C++, it is a GNU extension clang implements -- so it
carries the same HARD clang dependency.

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
  say it). A GENERIC free function called by a bare name or `::` path
  spells its instance's arguments (`::m::pow<double, long>(...)`) from
  `CallExpr::instance`, never leaving clang to deduce them: an argument
  whose C++ type is not its Kairo type (an int literal typed `i64`) would
  deduce an instance no TU homed. A generic METHOD through `.` still
  deduces (`.template m<...>` is RESOLUTION.md item r).
- `_arg`/`_value`: `static_cast<P>(a)` whenever the argument's canonical
  differs from the parameter's (records excluded; they copy-construct);
  `@inout` emits the operand bare; `@move` emits `static_cast<T&&>(x)`
  for lvalues. For a generic callee a parameter that IS one of its generic
  parameters is compared, and cast, against the instance's argument for it.
- `_binary`/`_unary`/`_assign`/`_subscript`/`_cast`: primitives only,
  parenthesized; a record operand is an ICE naming OperatorLowering.
  "Record" is a class, struct, union or ADT enum (`_record_operand`): a
  plain enum is a RecordType too, but `==`, `<` and `as` on an `enum class`
  are C++'s own. `===` in `_binary` is an ICE naming the nullable
  lowering; `x as T&&` (a lowering's move, never user-written) is a
  `static_cast`.
- `_var_decl`: an inferred type is the shared canonical (no range) and is
  spelled at the binding's name; a null type is `I011W` + `auto` — the
  only diagnostic codegen emits.

ICE map (node → owner): match/MatchExpr → MatchLowering; try/finally/
panic/assert → PanicLowering; ranged for/ranges/slices → IterLowering;
`?.`/`??`/`T?` → the nullable trio; f-strings → FStringLowering; yield →
YieldLowering; closures → lambda emission (unwritten); await/spawn/thread
→ async lowering; `ListLiteralExpr` / set / map literals →
ListLiteralLowering (set and map have no lowering yet); labeled
break/continue → label lowering; typeof/impl/derives tests →
TypeQueryLowering; NamedArgExpr → CallLowering; a `TypeCastExpr` with a
record operand and no `resolved_ctor` → OperatorLowering.

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
`Tests/Codegen/slices/sum.k` is the list-literal link test: an array
prvalue as an argument, an Extended backing array behind a `var`, a literal
under a conditional, exit 38. Its `-o` names a DIRECTORY, so the link takes
the entry TU's object and one per builtin TU it pulled in — `%t.d/*.o
%t.d/builtin/*.o` — because the Slice instance is homed in whichever of
them used it. `--print-cg` goldens carry the fid column and preamble
offsets.

## 10. Open

Piece 1 (root naming by `module X;` declaration; `-I` becomes C++-only);
`const T&` for by-value records; witnesses/concepts; per-TU header reuse
across FrontendActions; namespace merging in EmitIR (cosmetic);
`ReturnStmt` keyword token; `TextSink` binary spacing outside parens.

Emitter consolidation: one `fn_signature` in CXXSpell, one namespace
helper, one record-members accessor, `is_ctor` as a decl fact rather than a
name comparison — goldens for every `Tests/Codegen` test go in FIRST, or
the refactor has nothing to hold it.

Constructor initializer lists: `FunctionDecl::initializers`, mem-init
emission, and the const-field init-once rule. AccessCheck. Vector/HashSet/
HashMap constructor bodies in `Lib/builtin` — vector literals type-check
and emit today, but do not LINK. Set and map literal lowering, which needs
`Pair<K, V>` and the Slice constructors on HashSet/HashMap. Static
promotion of an all-constant `const`-element slice literal.