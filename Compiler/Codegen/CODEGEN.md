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
- A record at Complete admits the by-value types of its METHOD signatures
  at Complete, and what its member `type` aliases name: any code in the TU
  may call a member of a complete class or read `R::promise_type`,
  including code Kairo never sees (clang's coroutine machinery). Strength
  only -- definition ORDER still follows layout (bases, by-value fields).
- A `sizeof` / `alignof` operand is Complete.
- Every body this TU emits is walked at body strengths: its own, and every
  foreign template and `inline` body visible here (§7). Anything such a
  body names is declared in the preamble, priv helpers included: a
  library's priv function has external linkage, so the call links, and an
  entry TU's internal ones are never reached (nothing imports an entry TU).
- An extension member is a static member of its EXTENSION SCOPE
  (`ExtScope`: `struct N::__kairo_ext_X`, one per (namespace, target),
  RESOLUTION.md §2b); it never appears twice (a `FunctionDecl` whose
  `lexical_dc` is an Extension is routed to its scope on admission). A
  scope is filled COMPLETELY when first touched -- every extend block of
  that (N, X) in its file, in source order, priv members included -- never
  from the use that touched it, so its text is the same in every TU. Two
  targets that spell one struct name in one N ICE.
- Every member's signature is expanded at Fwd, priv included: the struct is
  emitted whole in every TU that touches it, so a type only a priv member
  names must still be declared in a preamble that never mentions it.
- A scope's Complete deps are its target, every by-value record its
  operator forwarders' signatures name (a forwarder is an inline
  definition), and the outermost owner of every NESTED type any member's
  signature names (`Other::Inner` is named only through a complete
  `Other`).
- A class at Complete touches its SAME-FILE scopes (its friend structs);
  `friend_scopes_of()` returns every one, and a class may have several
  (`module Geo { extend Point {...} }` beside a file-scope extend).

Tiers: 0 forward declarations, and `struct __kairo_ext_X;` for every scope
the plan touches; 1 definitions, topo-sorted on Complete, each scope's
after its deps -- every touched scope in a preamble, in a header only
those a root reaches (a header always emits the whole struct); 2 function
declarations (extension members are never listed); 3 instantiations (`extern template` unless this
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
  This is the name-less (abstract) form: instantiations, fn-pointer
  parameter lists.
- `param_decl(p, name)`: the parameter spelling with the name folded into
  the declarator, for every type: the mode's `&`/`&&` and the const marker
  go through `decl()`, so a function pointer is `U (*f)(T)` and `@inout`
  on one is `U (*& f)(T)`. Appending the name (`U(*)(T) f`) is a cast-like
  expression to clang. Arrays keep their own branch: a `const [T; N]`
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
- `template_params(d)`: `d`'s C++ template parameters as one list: an
  extension member's extension's (`decl_extension_of`), then its own. A
  non-member function takes one list, so `extend <T> Vec<T> { fn <U> m }`
  is `template <class T, class U>`.
- `template_head(d)`: `template <class T, ...>` over `template_params(d)`.
- `subst_for(g, inst)`: the instance argument a generic parameter stands
  for, found by the GenericParamDecl's IDENTITY in the primary's
  `template_params` (so an extension's T, a member's own U and a default
  thunk's borrowed list resolve alike), or null. `_gparam` and EmitIR's
  `_needs_cast` both go through it.
- `ext_receiver(f, x, inst)`: an extension member's receiver parameter,
  unnamed: `[const ]X*`, or `[const ]X&` for an operator. Both emitters'
  parameter lists and InterfaceEmitter's explicit instantiations use it.
- `ext_scope_name(x)`: `__kairo_ext_<X>` (`LowerTargets::ext_scope_prefix`):
  the target's leaf when it is declared in the scope's own namespace,
  nested owners joined with `__`; otherwise its full path joined with `__`
  (`__kairo_ext_a__Point`), an imported C++ target's from its spelling; a
  generic record's primary; a builtin's Kairo spelling. `owner_types` of an extension member
  is that one name, so `qual_name` is `::N::__kairo_ext_X::m` unchanged;
  `scope_ns(x)` is N.
- `ext_op(sym)` (`LowerTargets`): an extension operator's static-member name,
  `__kairo_op_<mnemonic>` (`plus`, `eq`, `cmp`, `plus_eq`, `preinc`,
  `postdec`, ...), which `operator_name` spells for an extension member;
  `ext_forwarder_name(f)` is the `operator<sym>` its forwarder takes, ""
  for the LowerTargets-named ones (`in`, `^^`, ...). A symbol with no row
  ICEs.

## 5. InterfaceEmitter

Every Preamble and every Header opens with

    template <class T, decltype(sizeof(0)) N> using __kairo_array = T[N];
    template <class T> auto* __kairo_tmp(T&& t) { return __builtin_addressof(t); }

(`LowerTargets::array_alias`, `LowerTargets::tmp_addr`). The alias is never
instantiated. `__kairo_tmp` is the address of a prvalue's materialized
temporary, valid to the end of the full-expression: ExtensionLowering's
`materialize` `&` on a prvalue receiver, which EmitIR spells as
`::__kairo_tmp(e)`. The preamble is the one place it is spelled. A header
needs them for its bodies and wraps them in `#ifndef __KAIRO_LOWER_HELPERS`,
because one C++ TU may include several Kairo headers and `__kairo_tmp` is a
definition.

Namespace wrapping: an entry-TU decl lives in `namespace <file stem>`, the
stem sanitized to an identifier, with a trailing `_` when it is a C++
keyword (`operator.k` -> `operator_`; `CXXSpell::entry_stem`); a `priv` or
`internal` decl goes one level deeper, into an unnamed namespace nested
inside it (`CXXSpell::is_anon`); `main` stays at global scope. Qualified
names are unchanged — `::stem::x` reaches into the unnamed namespace through
C++'s implicit using-directive — so `qual_name` knows nothing about any of
it. Library roots still wrap by `module_base` (Piece 1 open).

Walks plan entries by tier. Records: `class`/`struct` with access
specifiers, fields, method DECLARATIONS (never bodies in the class —
invariant 12),
one `friend struct ::N::__kairo_ext_X;` per same-file scope, nested
types. Enums: C-like only. Functions: free only. Extension scopes:
`struct __kairo_ext_X {` and one `static` declaration per member (merged
template head, receiver first via `ext_receiver`, the postfix `int` dummy
where it applies), `};`, all public and never in the unnamed namespace;
then, per operator member C++ can spell, an inline forwarder
`template_head inline RET operator<sym>(X& __kairo_a0, ...) { return
::N::__kairo_ext_X::__kairo_op_<m>(__kairo_a0, ...); }`, each operand
forwarded as `static_cast<decltype(a)&&>(a)` and the postfix dummy as is.
Tier 3: `extern template class X<A>;` /
`template class X<A>;`. Header mode adds `#pragma once`, the module's own
ffi headers (`#include "h"` as spelled, `ffi "c"` ones inside `extern "C"`),
and `#include`s of the headers of its Complete dependencies and of every
foreign function it declares (only an inline or template body names one).

Headers carry BODIES too, revising "headers carry no bodies": after the
declarations, EmitCXXHeader runs EmitIR over the plan's `visible_bodies()`,
which in Header mode is the module's OWN inline and template bodies. C++
consumers of a Kairo library need them for the reason Kairo importers do:
those bodies are part of the interface. The header plan walks them at body
strengths, so the priv helpers and types they name are declared there too.
The class definitions stay byte-identical, because the bodies are emitted
outside the class. `--emit-headers` therefore runs EmitIR, needs a lowered
tree, and writes nothing after an error.

V1 refusals (each an ICE naming its owner): ADT enums, unions, interfaces,
field initializers. A pack is spelled as its
`Slice<E>` (`ParamDecl::pack_type`).

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
its last statement. The parser produces it for source `({ ... })` (the last
statement must be an expression, enforced there), and SequenceLowering mints
it to write Kairo's left-to-right argument order into the tree. The block emits as any
block and the parens are what make it a value. Like the array prvalue it is
clang-only -- it is not C++, it is a GNU extension clang implements -- so it
carries the same HARD clang dependency.

Definitions it produces: free functions (namespace wrapper per function),
methods out of line (`RET Owner<T>::name(params) const`), methods defined
out of line (`fn C::m`), reached through the in-class declaration's chain,
constructors and destructors, extension members as out-of-line definitions of their scope's
static members (`RET __kairo_ext_X::m(X* self, ...)` in N, receiver first),
template bodies (own TU always; every other TU where the template is
visible, by `EmitPlan::visible_bodies`, §7), `int main()` at global
scope.

The no-headroom rules, each with one home:
- `_name`: locals bare (params, body vars, binders, generic params);
  `self` → `this` in a method, `self` in an extension member; everything
  else `qual_name(resolved_decl)`. A `candidate_cell` here is an X gate
  failure.
- `_chain_prefix`: separator from the base's canonical; operator steps
  spell `leaf(resolved_decl)`.
- `_call`: callee = promoted decl; a type as callee is a ctor call; an
  extension member arrives as a plain call, receiver first (ExtensionLowering
  decided its pointer or object form in the tree, and `_arg` emits a `self`
  argument as it stands); a chain callee ending in an extension member is
  an ICE. `self` takes an argument unless the callee is bound (a `.`/`->`
  step, a constructor). A GENERIC free function called by a bare name or `::` path
  spells its instance's arguments (`::m::pow<double, long>(...)`) from
  `CallExpr::instance`; a generic EXTENSION member spells
  `<ext args..., member args...>`, the order of `template_params`, never leaving clang to deduce them: an argument
  whose C++ type is not its Kairo type (an int literal typed `i64`) would
  deduce an instance no TU homed. A generic METHOD through `.` still
  deduces (`.template m<...>` is RESOLUTION.md item r). A default-thunk
  call to a generic type's method is spelled through `CallExpr::qualifier`
  (`Box<int>::__kairo_default_m_x()`). A constructor call's parameters are
  `CallExpr::ctor_decl`'s, not the named type's.
- `_check_arity`: CallLowering's postcondition, checked in `_call`. Every
  parameter has an argument; more arguments than parameters only for a C
  `...` tail. A dependent call is as written until M2 and is not checked.
- Decision 6, the one headroom: an imported C++ function's TRAILING
  defaults are omitted from the call and clang supplies them
  (`has_default` with no `default_thunk`). A non-trailing omission has no
  C++ spelling and is rejected in Sema (SC107E).
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
panic/assert → PanicLowering; ranged for → IterLowering, only for the
kinds RESOLUTION.md §2.10 lists as not yet lowered and for a dependent
iterable; ranges → RangeLowering;
`?.`/`??`/`T?` → the nullable trio; f-strings → FStringLowering; yield →
YieldLowering; closures → lambda emission (unwritten); await/spawn/thread
→ async lowering; `ListLiteralExpr` / set / map literals →
ListLiteralLowering (set and map have no lowering yet); labeled
break/continue → label lowering; typeof/impl/derives tests →
TypeQueryLowering; NamedArgExpr → CallLowering; a call short of
arguments → CallLowering; a ChainExpr callee ending in an extension
member → ExtensionLowering; a `TypeCastExpr` with a
record operand and no `resolved_ctor` → OperatorLowering.

## 7. Templates

No monomorphizer (IMPORTS.md §7). **A template's definition is visible in
every TU that can instantiate it**, which is the rule C++'s template model
already depends on. Wherever its owner is held Complete, a TU emits:

- every member body of a class template (its nested records' too);
- every member TEMPLATE of any class (`Suspend::await_suspend<H>`);
- every free function template its plan declares;
- every generic extension member.

And, by the same mechanism, every `inline` body: `inline` puts the body
in the interface, so importers compile it themselves.

- every `inline` method of a non-template record, in every TU whose plan
  holds the owner at Complete -- all of them, never pruned by Kairo-visible
  references, because Kairo never sees clang's own calls (`await_ready`,
  `initial_suspend`, ...). clang generates nothing for an unused inline
  definition, so the cost is parse time, and only for what people marked;
- every `inline` free function and extension member, in every TU whose
  plan declares it, at any strength.

The list is read off the plan's working set, not its roots, so it is
transitive: a `priv inline` helper an inline body calls is admitted by the
walk and its body joins on the next pass. That matters because clang emits
an inline definition only in an object that uses it -- the helper's home
object may not hold one. Each body is emitted as C++ `inline`, its own TU's
copy included, so the definition is the same text everywhere and the linker
keeps one. Template members and member templates were already visible;
marking them `inline` only says so.

Each in its owner's namespace wrapper, once per TU. `EmitPlan::
visible_bodies()` is the one list: EmitIR emits exactly it and the plan
walks exactly it for dependencies, at the body strengths, to a fixed
point -- that walk is what makes `Suspend` and `YieldPromise<T>` complete
in a consumer whose own code names neither.

Why, rather than "the template's own TU plus every TU that homes an
instance": clang instantiates templates Kairo never names -- a coroutine's
promise (`YieldPromise<int>`, reached through `Yield<int>::promise_type`),
`await_suspend<std::coroutine_handle<...>>`, std::sort calling a Kairo
comparator, a C++ consumer of a Kairo template. The registry can never
list those, so "every instance is enumerated and homed" was never going to
be complete; visible bodies cover the instances it cannot see. ODR holds
because the text is identical in every TU (invariant 11).

`extern template` declarations still sit in the preamble for every
registry instance this TU does not home, and the home still emits the
explicit instantiation. They are NOT redundant now: `extern template class
X<A>;` stops clang from implicitly instantiating X<A>'s non-inline members
in that TU, so a known instance is still compiled once, in its home. That
is what keeps visible bodies cheap -- parsed everywhere, instantiated only
in the home TU and for the instances Kairo never saw. Explicit
instantiation DEFINITIONS are emitted after every body, because an
explicit instantiation only instantiates members defined before it. A `<T impl I>`
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
`Tests/Codegen/defaults` holds `order` (evaluation order of named arguments
and defaults), `defaults` (thunks on free, method and generic functions),
`packs`, `ctor` (named and defaulted constructor arguments), `redecl`
(defaults accumulated over a chain), `ffi_defaults` (decision 6) and
`ffi_defaults_skip` (SC107E).
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

`const f: fn(T) -> U` spells `const U (*f)(T)`: a pointer to a function
returning const U, not a const pointer (`U (*const f)(T)`). Top-level
const on a by-value parameter is not part of the signature, so this is
cosmetic at the ABI, but the definition body loses the const.

Tier-3 lines (explicit instantiations) are anchored with `_at(primary)`,
every token on the function's name range, and clang's diagnostics on them
have been seen rendering over unrelated source bytes (a comment line with
`test` spliced in). Trace where that range lands for an extension member.

Explicit instantiations parenthesize the declarator-id: `template R
(::ns::f<A>)(...)`. After a class-template return, `Cell<double> ::ns::`
otherwise lexes as one nested-name-specifier. An out-of-line DEFINITION
is safe while its declarator-id does not start with `::`; parenthesize it
the same way if it ever does.

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