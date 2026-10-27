# Codegen: from a checked tree to C++ tokens

Companion to IMPORTS.md (§6, §7) and RESOLUTION.md. This document is the
contract for everything under `Compiler/Codegen/` and for the Lower/ passes
that feed it. Where it disagrees with either, it is newer and wins.

## 0. The model

Kairo lowers to C++ by injecting a token stream into clang. Every emitted
TU is: a PREAMBLE (the declarations a header would have provided, own and
foreign), the BODIES the TU defines, then the explicit instantiation
definitions it homes. Nothing is `#include`d except ffi headers, and
`<new>` where a derived assignment rebuilds a value in place (§5).

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
`#include "foo.k"` from a C++ input runs `EmitPlan(Include)` -- a
Header's roots (pub decls, and a priv or internal one only when an inline
or template body names it) emitted as a Preamble is -- and
`InterfaceEmitter::run` into a TokenSink bound to the host's preprocessor
(`IncludeEmitter`), then EmitIR over `EmitPlan::include_bodies()`: the
template and `inline` bodies a C++ consumer compiles itself, foreign and
foo's own. No other body and no eof, and no explicit instantiation of
any kind: the host may come from a different run than the homes (`kcc -c
x.cc; kcc -c foo.k`), so it instantiates implicitly and the linker folds
that with the homes' weak_odr definitions. A stream cannot carry
`#ifndef`, so a second include in the same C++ TU drops what an earlier
one already put there (`IncludedDecls`: the helpers, plan entries keyed by
decl and tier, bodies, include lines). Nor can it carry `#include`: the
system headers and the ffi header set of every module the stream draws on
go back to the hook as lines, which it enters in a buffer ahead of the
stream (Interop/Clang/KairoInclude.k). Under `-E` the punctuators are arena
tokens (`TokenSink::arena_puncts`) and every token has a leading space, so
the printed stream is C++ that compiles on its own.

Layout. Only `Backend/` imports emitters, and only `Backend/` and `Sink/`
import clang headers:

    CodegenContext.k  CodegenICE.k  EmitPlan.k   shared by every file below
    Emit/      CXXSpell, InterfaceEmitter, EmitIR      the emitters
    Sink/      EmitSink (interface), TokenSink, TextSink, TokenStreamPrinter
    Backend/   the plan's consumers and their clang glue:
               CodegenBackend (an object), EmitCXXHeader (a header),
               IncludeEmitter (`#include "foo.k"`), CodegenAction

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
  module's priv function has external linkage, so the call links, and a
  pathless TU's internal ones are never reached (nothing imports a file
  outside every search dir and library; every input with a path is a module, IMPORTS.md
  §2.1 "Inputs are modules").
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
TU is the instance's home, `template class` if it is). A pathless TU's
decls go in the file's own namespace (§5); a file-scope `main`, in any TU
(`CXXSpell::is_main`), is emitted at global scope and never declared in
the interface or a header.

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
  operator a type declares: CoalesceLowering expands it (NULLABLE.md 2.3)
  before codegen, and it has no spelling here. An EXTENSION operator is a
  non-member C++ operator taking `X&` / `const X&` (a class-typed parameter is what
  [over.oper]/7 asks for), spelled exactly as a member's is; its body
  binds `self` to the address of that reference
  (`X* self = &__kairo_self;`), so the body emits unchanged. Every Kairo
  use is an explicit call that passes the object, not its address.
- `_type(t)`: canonical → C++; builtins by table (`i32` is
  `::std::int32_t`), records qualified with instance args from the
  registry, pointers, references, arrays through `decl()`. A Kairo
  `fn(A) -> R` is the value type `::__kairo_fn<R(A...)>` (§5, §6
  Closures; `fn_signature(f)` spells `R(A...)`), never `R(*)(A...)`:
  closures.md gives a closure the `fn` type, and a lambda that captures
  has no function pointer. Only a C no-prototype pointer
  (`is_unprototyped`) stays raw. Structural
  containers are gone (builtin records); a tuple canonical ICEs naming
  TypeResolve. `T?` stays a NullableType canonical (Sema's later passes
  ask it), and is spelled -- and planned, EmitPlan `_nullable_record` --
  as the `::builtin::Nullable<T>` record NullableTypeLowering put in its
  `lowered` slot; with none, it ICEs naming that pass. A `null` typed as a
  nullable arrives as that record's null VariantInitExpr.
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
  go through `decl()`, so a raw function pointer (a C no-prototype one) is
  `U (*f)(T)` and `@inout` on one is `U (*& f)(T)`; appending the name
  (`U(*)(T) f`) is a cast-like expression to clang. A Kairo `fn` parameter
  is the value type, `::__kairo_fn<U(T)> f` (`& f` for `@inout`). Arrays keep their own branch: a `const [T; N]`
  parameter is `const T (&name)[N]`, an `@inout` one is `T (&name)[N]`, and
  by value is an ICE (StmtTyping rejects it). Both emitters spell
  parameters through here.
- `return_spelling(f)`: a method's C++ return type; `_ret` in both
  emitters goes through it. Place operators (`[]` declared
  `-> *T` / `-> *const T`; `is_place_operator`, which mirrors
  `OperatorFacts::is_place`) are spelled `T&` / `const T&`, so an imported
  `T&` and a Kairo place are one ABI. The same operators returning any
  other type are value operators and are spelled as declared. `->` stays
  a pointer (C++'s `operator->` returns one). OperatorLowering rewrites the body's `return`
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
    template <unsigned int I> struct __kairo_vt { explicit __kairo_vt() = default; };
    template <class T, class... A> inline void __kairo_construct_at(T* p, A&&... a) { new (p) T(static_cast<A&&>(a)...); }
    template <class T> inline void __kairo_destroy_at(T* p) noexcept { p->~T(); }

(`LowerTargets::array_alias`, `LowerTargets::tmp_addr`,
`LowerTargets::adt_variant_tag`, `LowerTargets::construct_at`,
`LowerTargets::destroy_at`). A plan that admits a Kairo `fn` type
anywhere (`EmitPlan::needs_fn_value`, set by `_admit_type`) also writes
`::__kairo_fn` (`LowerTargets::fn_value`, guarded
`__KAIRO_FN_HELPERS` in a header, `have_fn_value` for an include
stream), so a TU that names none keeps its text (§6, Closures). `__kairo_vt<I>` is the tag argument that selects
an ADT's variant-I constructor. The alias is never
instantiated. `__kairo_tmp` is the address of a prvalue's materialized
temporary, valid to the end of the full-expression: ExtensionLowering's
`materialize` `&` on a prvalue receiver, which EmitIR spells as
`::__kairo_tmp(e)`. The preamble is the one place it is spelled. A header
needs them for its bodies and wraps them in `#ifndef __KAIRO_LOWER_HELPERS`,
because one C++ TU may include several Kairo headers and `__kairo_tmp` is a
definition. An include stream is not guarded; `InterfaceEmitter::have_helpers`
leaves them out instead.

Namespace wrapping: a decl lives in its TU's module path,
`namespace a::b`, from `module_base`. Every input has one now -- a `.k` on
the command line is a module like any import, `lib/y.k` from the cwd is
`lib::y` (IMPORTS.md §2.1 "Inputs are modules") -- and each segment, being
a file or directory name, is sanitized to an identifier, with a leading
`_` before a digit and a trailing `_` after a C++ keyword (`operator.k` ->
`operator_`; `CXXSpell::cxx_segment`). Only a PATHLESS TU
(`CXXSpell::is_entry_tu`: a file outside every search dir and every
library) lives in
`namespace <file stem>` (`CXXSpell::entry_stem`, the same sanitizing), and
only there does a `priv` or `internal` decl go one level deeper, into an
unnamed namespace nested inside it (`CXXSpell::is_anon`); a module's priv
decls keep external linkage. A file-scope `main` stays at global scope in
every TU (`CXXSpell::is_main`). Qualified names are unchanged — `::stem::x`
reaches into the unnamed namespace through C++'s implicit using-directive —
so `qual_name` knows nothing about any of it.

Walks plan entries by tier. Records: `class`/`struct` with access
specifiers, fields (a default as a C++ default member initializer: a
constant FieldInitLowering folded as it is, `signed int n = 5;`, anything
else as a call of the member function it made of the initializer,
`T d = __kairo_init_d();`, so the expression is a body like any other),
method DECLARATIONS (never bodies in the class — invariant 12), the
derived `op =` (below),
one `friend struct ::N::__kairo_ext_X;` per same-file scope, nested
types. Enums: C-like as `enum class`, an ADT as its layout record (below).
Functions: free only. Extension scopes:
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

A record with a member `op <=>` gets the comparisons Kairo derives from it
written into the class (`_derived_cmps`), after the methods and before the
derived `op =`: `bool operator<(<other>) [const] { return static_cast<signed
char>(this->operator<=>(static_cast<decltype(o)&&>(o))) < 0; }` for each of
`<` `<=` `>` `>=` `==` `!=`, the operand, cv and access the `<=>`'s own. C++20
cannot find them: its rewrite `(a <=> b) < 0` does not compile against
`Ordering`, a scoped enum, and it never derives `==` from a user `<=>`. A
comparison the record declares is skipped, as is `!=` beside a declared
`==` (C++20 rewrites it as Kairo derives it). In the class, like the derived
`op =` (invariant 12's exception). Not yet: a generic `<=>`, an extension
`<=>`, an ADT's.

A record's `op =` is derived from its transfer constructor, never written
(classes.md); ClassLifecycle decides how (`assign_from`, `assign_form`) and
`_derived_assign` writes it after the methods, public, its operand spelled
as the constructor's own `other`. No transfer constructor written: nothing,
since C++'s implicit assignment is the derived one and declaring one would
change which constructors C++ generates. Defaulted: `= default`. Deleted, a
polymorphic record with a body, or a part that cannot be assigned:
`= delete`, and assigning one is SC071E. A body: `X& operator=(<other> o)
{ if (this != &o) { this->X::~X(); ::new (static_cast<void*>(this)) X(o); }
return *this; }`, `static_cast<X&&>(o)` from a `@move` one -- nothing on
self-assignment, the destructor qualified so it is never virtual, and the
old value destroyed before the new one is built since emitted C++ has no
exceptions. A generic record whose dependent parts leave that open declares
it twice: the body under `requires (<every dependent field destructible,
every dependent base destructible and not polymorphic>)` and `= delete`
under the negation, the traits over the parts because the record is
incomplete inside its own body. The body sits in the class (invariant 12's
exception). Its `::new` is the global placement form, so a TU or header
that writes one asks for `<new>` before any class: TextSink as a line,
TokenSink through KairoInject, which both appends it to the predefines and
adds it to `PreprocessorOptions::Includes` (clang reads the one or the
other, as the TU loads a PCH or not). It is included rather than
declared: libc++ declares the operator with an abi_tag and, from C++26,
constexpr, and clang rejects a redeclaration that differs, in either order.

An ADT enum is written as the record EnumLayoutLowering built
(`EnumDecl::adt_layout`), under the enum's name and template head, in the
record's order: the tag enum (bare enumerators: a tag is a variant's
position; its word is the enum's `derives` type, else u8 or u16), each
payload struct with its own placement `operator new` as its
first member (`new (&m) P(...)` finds it whether or not the TU includes
`<new>`, so for a payload
`::new` is never emitted), the tag (public: an ADT's `==` is a compare of
two values' tags in the user's code), the anonymous union, a generic ADT's
five `static constexpr bool` flags (type traits over the payload structs),
then the role functions rendered from `adt_role` / `adt_form`: per variant
`E(::__kairo_vt<I>, F0 f0, ...)` (the field constructor, every field
trivial), `template <class F> E(::__kairo_vt<I>, F&& f)` (the lambda one),
or both, constrained, for a generic ADT, and `E(::__kairo_vt<I>)` for a
dataless one; the special members; the private `__kairo_destroy` /
`__kairo_construct_from`; and `__kairo_which()` on a generic ADT. Every
member with a body is `noexcept` unless -funwind, as is the lambda a
construction site passes, so a construction is a call, not an invoke.
Every ADT record also answers the niche trait: `__kairo_niche_count` (the
tag values past its variants), a `(::__kairo_np, i)` constructor storing
tag `N + i`, and `__kairo_niche_test`. Their bodies are written in the class, as a
derived assignment's is (invariant 12's exception): they have no Kairo body
to put out of line, and the text is still a pure function of the decl. A
generic ADT declares all
three forms of each special member (defaulted, with a body, deleted),
constrained on the flags so one is selected; a non-generic one declares the
one form its lifecycle facts select, unconstrained. EmitPlan reads an ADT's
members, nested types, layout edges and by-value parameters off the record
(`EmitPlan::adt_record`, through `layout_decl`), and sees through the
anonymous union and the payload structs as through ordinary fields.

Niche layout (EnumLayoutLowering's header). The preamble trait
`__kairo_niche<T>` (`_niche_helpers`, guarded `__KAIRO_NICHE_HELPERS` in a
header) answers `count` / `pattern(i)` / `test(v, i)`: 0 by default, one
null for any `T*`, and an ADT record's own members; a plain enum with
values `0..N-1` at namespace scope is followed by its explicit
specialization (`_enum_niche_trait`; AST/EnumNiche.k decides which, for
both Sema and codegen). A niche-filled non-generic ADT is written by
`_niche_record`: the payload struct as its one member, each dataless
variant a `pattern(j)` of the field, defaulted special members, `which()`,
its own niche answer past the patterns it uses, then `static_assert(sizeof
== the payload struct's && standard-layout)`. A niche-shaped generic ADT
gets that record again as a partial specialization constrained on
`__kairo_niche<F>::count >= D && trivially copyable && trivially
destructible` beside the tagged primary, so C++ picks the layout per
instance in every TU and host alike; each explicit instantiation is
followed by static_asserts of the size and shape Sema predicted
(`InstanceEntry::adt_shape` / `adt_size`).

The `Nullable` lang item (`T?`'s target, Lib/builtin/module.k, NULLABLE.md
1.2) is such an ADT, `Value { v: T }, Null`, and its record alone carries
eight more roles (AdtRole::NullDefault on, `InterfaceEmitter::
_nullable_member`): `Nullable()` and `Nullable(::builtin::null_t)` (null),
`Nullable(const T&) requires __kairo_copyable` and `Nullable(T&&) requires
__kairo_movable` (present, the payload built in place; constrained because
the explicit instantiation defines every member whose constraints hold),
`is_null() const`, the unchecked `T& __value()` / `const T& __value()
const`, and `operator==` when `const T&` compares. None is `explicit`:
every implicit `T -> T?` / `null -> T?` is C++ copy-initialization through
one of them. `null_t` (`StructDecl::is_null_type`) is followed by `inline
constexpr null_t null{};`, the constant a C++ host spells `::builtin::null`.

A static field is declared in the class (`static [thread_local] T s;`, no
initializer: C++ takes one in-class only on a const static) and DEFINED
after the outermost record's `};`, inside its namespace wrapper, as an
inline variable: `[template <...>] inline [constinit] [thread_local] T
R::s = <init>;` (`_static_defs`). Inline because every TU that holds the
class can odr-use the static. `constinit` exactly when FieldInitLowering
folded the initializer to a literal -- a constant expression for every
instantiation, so clang never rejects it; a thunk (`= __kairo_init_s()`,
by leaf: a static member's initializer is in its class's scope) is
dynamic initialization. No initializer is `{}`.

A constructor CtorInitCheck split (`FunctionDecl::ci_split`) declares
three private members after the methods, from the same facts in every
TU: `struct __kairo_ciK;` (declared only; EmitIR defines it beside the
bodies, where the carried locals' types are complete), `static auto
__kairo_ctor_preK(__kairo_ciK&& __kairo_s, __kairo_lref<P> p...) ->
__kairo_ciK&;` (trailing return: no `typename` out of line in a generic
owner) and `R(__kairo_ciK& __kairo_s, __kairo_lref<P> p...);`. A plan
holding such a record writes two more preamble helpers (guarded
`__KAIRO_CTOR_SLOT_HELPERS` in a header): `template <class T> using
__kairo_lref = T&;` and `__kairo_slot<T>`, a T in union storage built on
its first assignment through its box's own placement `operator new` (no
`<new>`), destroyed only if built, never copied: `init` (first
assignment), `put` (may be a later one; the only use of T's `op =`),
`get`, `take`, `set`.

V1 refusals (each an ICE naming its owner): named unions, interfaces, the
initializer of an eval or array-typed field (FeatureGateCheck rejects it
first, SC116E: no eval constant is emitted yet, and a C++ function
cannot return an array). A pack is spelled
as its
`Slice<E>` (`ParamDecl::pack_type`).

## 6. EmitIR — the core

Declarations are the plan's; EmitIR writes bodies. What it knows:

    names, chains (`.`/`->` from the base's canonical; `::` collapses to
    the last scope-resolved decl's qualified name), calls, literals,
    primitive operators, casts, `if`/`while`/`for(;;)`/C-style `for`,
    `return`/`break`/`continue` (unlabeled), locals, blocks, named and
    anonymous initializers (designated, declaration order, aggregates
    only), `sizeof`/`alignof`/`delete`, `unsafe` (transparent),
    `InitListExpr`, `StmtExpr`, closures (Closures, below).

`InitListExpr` is the C++ braced-init-list, and array-typed only. Its two
spellings are chosen by POSITION: the bare `{...}` as a `VariableDecl`'s
direct initializer and as an element sitting directly inside another array
`InitListExpr` (C++ cannot initialize an array element from an array
prvalue); the prvalue `::__kairo_array<T, N>{...}` everywhere else, alive to
the end of the full-expression. Both are valid C++17, but GCC rejects the
decay of a prvalue array ("taking address of temporary array") and clang
does not — bodies only ever go through clang, and that is a HARD dependency
of this layer, not a preference.

### Closures

A closure is a C++ lambda inside the `fn` value its type is. closures.md
gives every closure the type `fn(A) -> R` ("no separate closure type")
and lets one that captures be stored, passed and returned as that type,
so `fn(A) -> R` is spelled `::__kairo_fn<R(A...)>` everywhere (CXXSpell,
§4), a preamble helper (§5): empty, a plain function pointer, or a
heap-allocated lambda with its call / copy / destroy operations.

    captures nothing   ::__kairo_fn<R(A)>(+[](A a) -> R { body })
    captures           ::__kairo_fn<R(A)>::own(new auto([caps](A a) mutable -> R { body }))

- A named function converts to the value by its function-pointer
  constructor; a `fn` value converts back to `R(*)(A...)` for a C callee
  or field, and that conversion traps on a capturing closure (it has no
  function to give). C++ does both implicitly, so a foreign call needs
  no arm here.
- `new auto(lambda)` builds the lambda in its heap slot from the prvalue:
  no temporary lambda, so each by-copy capture is copied once (from the
  variable) and destroyed once (with the last `fn` value holding it).
- Copying a `fn` value copies the lambda: each copy keeps its own
  by-copy captures, as copying a C++ lambda does. A lambda with a
  move-only capture cannot be copied; copying the `fn` value that holds
  one traps. Moving never copies.
- A capturing lambda is `mutable`: a by-copy capture is the closure's
  own variable (closures.md), assignable in the body, and its value
  persists from one call to the next.
- The capture list is ClosureCaptures' decision (`ClosureExpr::
  cap_decls` / `cap_modes` / `cap_via_ptr`, RESOLUTION.md §2.8), spelled
  by `_capture_list`. Init-captures keep the Kairo name, so the body
  emits unchanged: inside a `|*x|` closure Sema types `x` as `*T`
  (ExprTyper::_capture_view), and the capture makes C++'s `x` that
  pointer.

        Copy       x
        Move       x = static_cast<T&&>(x)          a MOVE value, moved in
        Ptr        x = &x                           `|*x|`, `|*|`
        ConstPtr   x = static_cast<const T*>(&x)    `|const *x|`
        Self       this   (an extension member: self)

  A binding an enclosing closure holds by pointer is already that pointer
  in the inner lambda: Copy (and Ptr, Move) copy it, ConstPtr converts it
  (`static_cast<const T*>(x)`).
- `return` in the body returns from the lambda (`_return` reads the
  innermost `_closure`'s return type); `_cur_fn` stays the enclosing
  function, which decides `self`. An expression body arrives as a block
  (ExprBodyDesugar). A `finally` in the body is FinallyLowering's local
  record, declared in the lambda.
- A call through a `fn` value (a local, a parameter, a field, `make()(4)`)
  casts each argument to the type's parameter as `_arg` does
  (`_fn_value_args`).
- Not emitted: a generic closure (`fn <T>(x: T)`; FeatureGateCheck,
  SC116E), whose parameters and calls X does not type.

`StmtExpr` is the GNU statement expression `({ s0; s1; e; })`, whose value is
its last statement. The parser produces it for source `({ ... })` (the last
statement must be an expression, enforced there), and SequenceLowering mints
it to write Kairo's left-to-right argument order into the tree. The block emits as any
block and the parens are what make it a value. Like the array prvalue it is
clang-only -- it is not C++, it is a GNU extension clang implements -- so it
carries the same HARD clang dependency.

A split constructor (its body `{ {S_pre} {S_post} }` after
CtorInitLowering) is four definitions (`_split_ctor`): the slot record
(`::__kairo_slot<T>` per field S_pre assigns, in declaration order, then
per carried local); the pre-function, S_pre against the slots, `return
__kairo_s;`; the slot constructor, mem-initializers `x(__kairo_s.x.take())`
for every field S_pre assigns on all paths, in declaration order, then
`if (__kairo_s.y.set) { this->y = __kairo_s.y.take(); }` for one it
assigns on some, then S_post; and the declared constructor, `R(P p) :
R(__kairo_ctor_preK(__kairo_ciK(), p), p) {}`. In S_pre (`_ci_pre`)
`self.x = e` is `__kairo_s.x.init(e)` (`.put(e)` for a `var` field),
`self.x` and a bare field are `__kairo_s.x.get()`, and any other `self`
ICEs (CtorInitCheck rejected it). A carried local is `__kairo_s.__kairo_lI_n`
in both halves, built at its declaration. The temporary slot record lives
to the end of the public constructor's mem-initializer, which encloses
the whole slot constructor; parameters reach both halves as the public
one's lvalues, so a change S_pre makes to one S_post sees.

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
  are C++'s own; an ADT's `==` arrives that way, as a compare of the two
  values' variants (OperatorLowering through EnumLayoutQuery::same_variant,
  from X's `tag_eq`), never as a call to an `operator==`. `===` in `_binary` is an ICE naming
  CoalesceLowering; `x as T&&` (a lowering's move, never user-written) is a
  `static_cast`. The checked downcast `p as (*D)?` (CastTyping's
  `checked_downcast`) is `dynamic_cast<D*>(p)` inside a lambda called on the
  spot, `[](D* __kairo_dc) -> N { return __kairo_dc ? N(__kairo_dc) : N();
  }(...)` with N the `Nullable<D*>`: with tagged storage a null pointer must
  become the null nullable, not a present one (`_checked_downcast`). The
  asserting downcast `p as *D` is still a plain `static_cast` (PanicLowering).
- `_var_decl`: an inferred type is the shared canonical (no range) and is
  spelled at the binding's name; a null type is `I011W` + `auto` — the
  only diagnostic codegen emits.

ICE map (node → owner): match/MatchExpr → MatchLowering; try/finally/
panic/assert → PanicLowering; ranged for → IterLowering, only for the
kinds RESOLUTION.md §2.10 lists as not yet lowered and for a dependent
iterable; ranges → RangeLowering;
`??`/`?.`/`?->`/`unwrap!`/`===` → CoalesceLowering (a `match` on a `T?`
is rewritten there too, then reaches MatchLowering as an ordinary match);
a `T?` with no `lowered` record → NullableTypeLowering (CXXSpell). A null
test left for NullTestLowering or a read left for NarrowedAccessLowering
has no ICE of its own: those two passes are the only guard; f-strings → FStringLowering; `yield`
is EmitIR's own (`co_yield`, a C++ coroutine); a generic closure → FeatureGateCheck; await/spawn/thread
→ async lowering; `ListLiteralExpr` / set / map literals →
ListLiteralLowering (set and map have no lowering yet); labeled
break/continue → LabelLowering; typeof/impl/derives tests →
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
body's call into a bound goes through the interface's WITNESS, and the
derived concept `I_c<T>` is the one Kairo-derived `requires` an emitted
template may carry; §7b is the contract for both. ADT special members carry C++ constraints rendered by
InterfaceEmitter from adt_role/adt_form, and a generic record's derived
assignment from its assign_form; they are not Kairo constraints and have no
requires_clause.

### 7a. Specializations of a generic record [DONE]

A partial specialization (`class <P> Store<*P>`) is a C++ partial
specialization and an explicit one (`class <> Store<bool>`) a C++ explicit
specialization; C++ then selects them itself, exactly as Sema did
(RESOLUTION.md §2b, Instances):

    template<class T> class Store;               // tier 0, primary first
    template<class P> class Store<P *>;
    template<> class Store<bool>;
    template<class P> class Store<P *> { ... };  // tier 1, after the primary
    template<class P> int Store<P *>::tag() const { ... }
    int Store<bool>::tag() const { ... }         // no `template <>`
    template class ::ns::Store<int *>;           // tier 3 names the instance

- **Spelling.** `CXXSpell::record_head` (`template <>` for an explicit
  spec, else template_head) heads the spec's own declaration and
  definition; `spec_suffix` (the pattern, a partial's parameters by name)
  follows its leaf there and in every out-of-line member's qualifier
  (`owner_segment`). Inside a spec, Self is the instance it stands for,
  spelled through the primary (`Store<P *>`, `Store<bool>`), never the
  spec decl.
- **Admission.** A primary admits every specialization of it at its own
  strength (`EmitPlan::_admit_specs`, `InstantiationRegistry::specs_of`):
  a TU or header that can name `Store<X>` sees each one before any use
  would instantiate the primary instead -- an ODR violation no linker
  reports. Tier 0 moves a spec written above its primary after it; tier 1
  orders a spec after its primary. An instance a partial lays out is
  `layout_decl`'d to the partial, and its by-value needs are read off the
  partial's parameters.
- **Members.** A partial's members are templates (visible bodies, §7); an
  explicit spec's are ordinary members of a non-template class, defined in
  the home TU like any record's, `inline` only when marked
  ([temp.expl.spec]/5: no template head out of line).
- **Tier 3.** An instance whose body is a partial is explicitly
  instantiated by its own name (`template class Store<int *>;`); an
  explicit spec is never an instance and gets no line.
- **Extensions.** Every block on any form of a template -- `extend <T>
  Store<T>`, `extend <P> Store<*P>`, `extend <> Store<bool>` -- is one
  scope struct `__kairo_ext_Store` (keyed by the primary, `ExtScope::key`),
  each member over its own receiver, befriended by every specialization.

Not built: a partial selected by `requires` (SC001E at the declaration,
the primary kept); a pack parameter in a partial's pattern (never
matches); a qualifier that matches only by subset (`const P` against
`const volatile i32` -- a non-match, never a wrong binding).

## 7b. Witnesses: calls through an interface bound [DECIDED, PARTIAL]

`Codegen/Emit/EmitWitness.k`. This section supersedes the
witness paragraph of RESOLUTION.md §2b where the two differ -- every
conformance a specialization, the witness edge in the home TU only -- and
the design memo that sits in `Sema/Mono/WitnessTable.k` (prose in a `.k`
file, no code); the header rule applies, this text is newer. RESOLUTION.md
§2b keeps what Sema must produce: the conformance table, its rows, and the
passes that fill them.

### 7b.1 What exists today

Built, end to end (`Tests/Codegen/witness/`):

- **Sema.** ConformanceChecking (Check stage, after ExprTyper) walks every
  call with a registered instance and, per `P impl I` bound of the
  primary, finds the row `(X, I)`: for each of I's own requirements, the
  decl member lookup on X finds whose signature is the requirement's
  exactly (Self := X, the interface's parameters := the bound's
  arguments). Rows live in the InstantiationRegistry (`ConformanceRow`,
  `row_find` / `row_add`), shared build-wide, and go on the instance as
  `InstanceEntry::rows`, the bound's derives closure included. A miss is
  SC001E at the call, with notes at the bound and the requirement.
- **The call.** ExtensionLowering rewrites `a.m(x)` / `p->m(x)` bound to a
  requirement into `m(recv, x)` with an extension member's receiver rules
  (no upcast), and `T::make(x)` bound to a STATIC requirement into
  `make(x)` with Self the qualifier, and records `CallExpr::witness_iface`
  (the DECLARING interface, found through the parameter's bounds and their
  derives closure) and `witness_self`. A type parameter used as an
  expression denotes its type (ExprTyper), which is how `T::` reaches the
  bound and `-> Self` reads back as T. An operator on a bounded `T` binds
  to the bound's requirement (OperatorTyping gathers candidates from the
  bounds alone), so OperatorLowering mints the call and the same arm takes
  it; an operator the bounds do not declare still defers. EmitIR spells the callee
  `::N::I_witness<Self, A...>::m`. A requirement callee with no recorded
  witness is an ICE naming ExtensionLowering.
- **Emission.** EmitPlan keeps `WitnessPiece`s beside its ExtScopes: an
  interface's primary + concept (tier-0 forward declaration, tier-1
  definition; admitted by a requirement use and by a bounded generic's
  declaration) and a row's specialization (tier 1, admitted from
  `_admit_instance` in every TU holding the instance, after the primary,
  the conformer and the extension scopes it forwards to). EmitWitness
  writes them; the primary-vs-specialization choice is 7b.4's, from
  spellings. A header guards each definition (`__KAIRO_W_<key>`);
  IncludeEmitter dedupes by the same key.
- **The concept** is rendered by `CXXSpell::template_head` on a
  namespace-scope generic FUNCTION only (declaration, body and the
  explicit-instantiation lines need no clause of their own: an explicit
  instantiation has no template head, and clang matches it to the
  constrained template -- checked by hand, and by `witness/diamond`).

Also built: the qualified form `I::m(x)` (Self is the first argument's
type; on a concrete conformer the call carries its own row,
`CallExpr::witness_row`), a generic interface's included
(`Container<i32>::get(x, 0)`: CallTyping keeps the qualifier on
`CallExpr::witness_iface`, overload resolution binds the requirement's
interface parameters from it, and the witness is the declaring instance's,
`Container_witness<X, int>`; on a bounded parameter ConformanceChecking
picks the bound the qualifier names, SC001E when none does); a generic
interface's `Self` (`I<T>` over its own parameters, which CXXSpell spells
as the witness's Self like a bare `I`); compound assignment and every other operator on
a bounded `T`, `op []` included (a static member `__kairo_op_index`,
`[]` having no extension name); generic requirements, named and operator
alike (a member template, gated on the callable form -- `self.template
operator[]<K>(k)` for an operator -- left out of the concept);
constructor requirements (no member in the primary or any
specialization, a concept clause `__kairo_Self(a0, ...)`, and `T(args)`
in the body plain C++ construction); a generic extension's member as
a witness (the row records the extension's arguments); the concept on
every bounded head -- records, methods, extension members -- with the
concepts in tier 0 ahead of the bounded records' forward declarations;
rows for record instances wherever their type is named; DECLARED rows
(`class X impl I`, `extend X impl I`, concrete X and I): ConformanceChecking
builds the row at the declaration and records it on the registry under the
declaring decl (`declare_row`), and EmitPlan admits it wherever that decl
is emitted, the conformer's header included, so a C++ host instantiating
with a declared conformer Kairo never paired finds the specialization
(`witness/header_declared`; a row that does not hold is not recorded, and
the host then fails at the concept); a GENERIC declared conformance
(`extend <E> Wrap<E> impl I`, `class <T> Box impl I`) as ONE partial
specialization, its row's conformer over the declaring decl's own
parameters (`ConformanceRow::declared` names that decl, whose
`template_head` -- bounds included, so a conditional `extend <E impl I>`
gets `requires I_c<E>` -- heads it), and every concrete row it covers
(same witnesses, conformer and interface at the row's arguments:
`ConformanceRow::covered_by`) admitting the partial in place of a full
specialization of its own; and the
instances a generic's body reaches (`outer<T>` calling
`inner(Wrap<T>{...})`): CallTyping keeps a dependent call's deduced
arguments (`CallExpr::dep_args`) and ConformanceChecking substitutes them
per instance, adding the reached rows to the outer instance's. That last
is the slice of M1 witnesses need. A reached instance is registered (so
it has a `home_fid`, the reaching TU's) but no plan admits it, so no
explicit instantiation is written for it anywhere: it links because the
outer instance's explicit instantiation instantiates it implicitly, a
weak symbol in that object. Homing what M1 reaches is M1's.

Not built, each the ICE or diagnostic that names it:

- `T::m(a)` for a METHOD: R027E, by design (use `.`).
- A bare qualified call to a GENERIC interface's requirement
  (`Container::get(c, 0)`): SC001E asking for the arguments, by choice --
  deducing the one instance c conforms to is a second lookup to keep sound.
- Associated types, value-parameter interfaces: EmitWitness ICEs.
- A member template of a class template gets no explicit instantiation:
  its registry entry carries only its own arguments, so it is
  instantiated implicitly from its visible body.

### 7b.2 The problem, and why a witness

A generic body is emitted ONCE, as a C++ template (§7), and Kairo's
conformance is structural and may be supplied by an extension member. An
extension member is a static member of `N::__kairo_ext_X` (§3, RESOLUTION.md
§2b), never a C++ member, and no single C++ spelling inside the template
reaches a different static function per `T`: `a.scale(2)` finds members
only; an unqualified `scale(&a, 2)` finds nothing at definition and ADL at
instantiation searches X's namespace, not the scope struct; qualifying it
hardcodes one conformer. The witness is a class template keyed on the
conforming type, so C++'s own specialization selection does the per-`T`
dispatch, and after inlining it costs nothing.

### 7b.3 The C++ shape

One PRIMARY per interface, one CONCEPT per interface, and a SPECIALIZATION
per conformance whose requirements the primary cannot reach (7b.4). For

    pub interface Scalable { fn scale(const self, factor: i32) -> i32 }
    pub struct Metric { pub var base: i32 }
    extend Metric { pub fn scale(const self, factor: i32) -> i32 = self.base * factor }
    pub fn <T impl Scalable> twice(a: T) -> i32 = a.scale(2)

in module `ring`:

    namespace ring {
        template <class __kairo_Self> struct Scalable_witness {
            static signed int scale(const __kairo_Self* self, signed int factor)
                requires requires { static_cast<signed int (__kairo_Self::*)(signed int) const>(&__kairo_Self::scale); }
            { return self->scale(static_cast<decltype(factor)&&>(factor)); }
        };
        template <class __kairo_Self> concept Scalable_c =
            requires (const __kairo_Self* s, signed int a0) { ::ring::Scalable_witness<__kairo_Self>::scale(s, a0); };
        template <> struct Scalable_witness<::ring::Metric> {
            static signed int scale(const ::ring::Metric* self, signed int factor)
            { return ::ring::__kairo_ext_Metric::scale(self, static_cast<decltype(factor)&&>(factor)); }
        };
        template <class T> requires (::ring::Scalable_c<T>) signed int twice(T a);
    }
    ...                                                  // bodies
    namespace ring {
        template <class T> requires (::ring::Scalable_c<T>) inline signed int twice(T a)
        { return ::ring::Scalable_witness<T>::scale(&a, 2); }
    }

This text, hand-written, compiles and runs under clang `-std=c++20` (the
floor `#include "foo.k"` already demands), and with the specialization
removed `twice(m)` is a constraint failure at the call.

**The primary is structural.** It forwards every requirement to a MEMBER
of `__kairo_Self`, so an own-method conformer -- a Kairo class, an inherited
member, an imported C++ class -- needs no specialization, and a C++ host
that instantiates a Kairo template with its own class (`#include "foo.k"`,
§1) gets a witness Kairo never saw. Each forwarder is constrained on an
EXACT match, the member-pointer cast above, not on "callable": the
specialization a Kairo TU emits must never be replaceable by a primary
that also compiles. Were the constraint `requires { s->scale(0); }`, a
Metric with an own `scale(i64)` and an extension `scale(i32)` would bind
the extension in a TU that sees the specialization and the own member in a
C++ TU that does not -- the same `twice<Metric>` compiled two ways, which
[temp.expl.spec]/7 makes ill-formed with no diagnostic. With the exact
match the primary rejects Metric, so the second TU fails to compile
instead (a constraint failure at its call, through `Scalable_c`). A
member-pointer cast admits a base's member (base-to-derived conversion)
and a `noexcept` one. A GENERIC requirement has no member pointer to cast
without its arguments; its forwarder carries the callable form, and this
one corner keeps the hazard (7b.12, question 6).

**Every witness member is declared as the requirement would be as an
extension member of `__kairo_Self`** -- the signature InterfaceEmitter
already writes into an extension scope, with X := `__kairo_Self` -- so the
call site follows ExtensionLowering's existing receiver rules (7b.5)
verbatim and there is one receiver convention, not two:

    requirement                    witness member                                forwards to (primary / spec)
    fn m(self, p: P) -> R          static R m(__kairo_Self* self, P p)           self->m(p) / ::N::__kairo_ext_X::m(self, p)
    fn m(const self, p: P) -> R    static R m(const __kairo_Self* self, P p)     the same, const
    fn op ==(const self, o: Self)  static bool __kairo_op_eq(const S& s, S o)    s.operator==(o) / __kairo_ext_X::__kairo_op_eq(s, o)
    fn op in(const self, x: T)     static bool __kairo_contains(const S& s, T x) s.__kairo_contains(x) / the scope's
    fn op ++ (self), postfix      static R __kairo_op_postinc(S& s, int)        the postfix dummy forwarded as is
    static fn make() -> Self       static __kairo_Self make()                    __kairo_Self::make() / __kairo_ext_X::make()
    fn <U> m(self, u: U)           template <class U> static void m(S* self, U u) self->template m<U>(u) / __kairo_ext_X::m<U>(self, u)
    fn op [](const self, k: K)     static R __kairo_op_index(const S& s, K k)    s.operator[](k) in both (member-only: no extension form)
    fn <U> op +(const self, u: U)  template <class U> static R __kairo_op_plus(const S& s, U u)  s.template operator+<U>(u) / __kairo_ext_X::__kairo_op_plus<U>(s, u)
    fn I(self, ...)  (constructor) none                                           -- see below
    type Node        (associated)  using Node = ...;                              -- see below

(`S` is `__kairo_Self`, shortened to fit.) The receiver is `self` or
`const self` and nothing else ("the receiver is
never marked", functions-parameter-modes.md), so `[const ]Self*` and, for
an operator, `[const ]Self&` (`CXXSpell::ext_receiver`) are the whole list;
there is no `@inout` or by-value receiver to spell. An operator's member is
named by `LowerTargets::ext_op` (a static member cannot be `operator==`),
or by its LowerTargets name for `in`, `^^`, `await`, `spawn`, `thread`:
the name `CXXSpell::operator_name` gives an extension member. `op []` is
member-only, so it has no extension name; its witness member alone is
`LowerTargets::witness_subscript()`. Parameters
are spelled by `param_decl` and returns by `return_spelling`, each with
`Self` replaced by `__kairo_Self` -- so the DECIDED `const T&` rule for
by-value records, when it lands, lands in the witness too -- and every
argument is forwarded as `static_cast<decltype(p)&&>(p)`, as the operator
forwarders do (§5). A by-value parameter therefore costs one extra move
before inlining, and is never copied.

**Constructors never go through the witness.** An extension cannot add a
constructor to any type (extends.md, "What Extends Can Add"), so every
constructor requirement is met by an own constructor and `T(args)` / `T{}`
is already the right C++ for every conformer; lifecycle requirements
(`@copy` / `@move` constructors) are C++'s implicit special members. The
concept still lists them (`requires { __kairo_Self(a0); }`), so a host's
non-conforming class fails at the call. A PRIMITIVE satisfies none
(question 7, decided): `i32()` is not a call in Kairo (SC037E), so `i32`
has no constructor for a row to name, though C++ `int()` would compile.

**Associated types are not compiled yet** (interfaces.md, Status), and
their witness shape is reserved, not built: a member alias, `using Node =
typename __kairo_Self::Node;` in the primary and the conformer's alias in a
specialization, with `T::Node` in a bounded body spelled `typename
::N::I_witness<T>::Node`, so an extension or builtin conformer can supply
one. Until then a `T::Node` reaching codegen ICEs naming the feature.

**Specializations** are full (`template <>`) for a non-generic conformance
and PARTIAL for a generic DECLARED one: `extend <T> Pair<T> impl
Container<T>` is `template <class T> struct Container_witness<::m::Pair<T>,
T> { ... }`, its head `CXXSpell::template_head` of the extension, and a
generic extension member is called with its arguments spelled, never
deduced (§6, `_call`). A STRUCTURAL generic one (a plain `extend <T>
Pair<T>` meeting I) stays a full specialization per concrete conformer a
Kairo instance reaches (7b.6: a structural row is no host's to find).
A specialization forwards each requirement to the decl its row names
(7b.4), which may be an own member too: one non-structural requirement
makes the whole (X, I) a specialization. Its members are defined IN the
class: they have no Kairo body to put out of line and are a pure function
of the row, which is invariant 12's exception for synthesized members (like
the derived `op =`). In-class means inline, so the text may appear in every
TU, and nothing is ever homed or explicitly instantiated for a witness.

**Generic interfaces** key on `<__kairo_Self, IfaceArgs...>`, the
interface's own `template_params` after `__kairo_Self`: `impl
Container<i32>` and `impl Container<string>` on one type are two
specializations. That is why an interface bound must name every interface
argument (RESOLUTION.md §2b, DECIDED): the call site has to spell them.

### 7b.4 When a conformance needs a specialization

ConformanceChecking's table (RESOLUTION.md §2b) gives, per conformance row
`(X, I<A...>)`, the decl that implements each of I's OWN requirements.
EmitWitness decides per row, from spellings, never by lookup:

- the PRIMARY serves the row iff every requirement's decl is a member
  function of X (own or inherited; Kairo or imported C++; static for a
  static requirement) whose C++ signature, through CXXSpell, is the
  witness member's forwarded-to signature exactly;
- otherwise the row gets a SPECIALIZATION. In practice: any requirement
  met by an extension member (plain `extend X` or `extend X impl I`, the
  ticket's case), every conformance of a BUILTIN (`i32`, `bool`: no
  members at all; spelled by `CXXSpell::_type`, so `i32` is `signed int`
  and `isize` the `decltype` form), and an imported C++ member whose C++
  type is not the requirement's even though Kairo's signature match
  accepted it (7b.12, question 5, covers free functions).

Explicit (`impl`) and structural conformance decide nothing here; the
implementing decls do. The two differ in WHEN the row exists (7b.6).

### 7b.5 The call site

Rule 3 applies: the receiver's form is a lowering's decision, and
ExtensionLowering already owns the table of them -- address of an
addressable receiver, `__kairo_tmp` for a prvalue, the pointer as is, the
object for an operator. A call whose callee is a requirement (its
`semantic_dc` owner is an `InterfaceDecl`, the test `call_result_type`
already makes) is rewritten there into a plain call, receiver first,
exactly as an extension member's is, and the call records its WITNESS: the
canonical interface instance the requirement belongs to (the DECLARING
interface, with its arguments as seen through the bound and any `derives`
edge) and the Self type (the receiver's canonical, a dependent `T`). A
static requirement through `T::make()` takes no receiver; its Self is the
qualifier. An operator on a `T` operand is first turned into a call by
OperatorLowering (observed today: `a == b` on a bounded `T` compiles and
links against an own-member operator, so it reaches C++ as an operator),
then takes the same arm. A generic requirement's own
arguments are `CallExpr::instance`'s, as for any generic callee. That this
lands in ExtensionLowering rather than a sibling pass is an implementation
choice (question 9); one pass owning both receiver tables is the reason.

EmitIR then grows one arm in `_call`, ahead of the qualifier arm: a callee
owned by an `InterfaceDecl` is spelled
`::N::I_witness<Self, A...>::[template ]leaf(` (the `template` keyword
whenever the member is generic: the witness is a dependent type, the
RESOLUTION.md item r case) and the arguments follow as an unbound call's
do, `self` included, each compared and cast against the requirement's
parameter with `Self` replaced by the witness's Self (`through_receiver`'s
substitution). Spelled forms:

    a.scale(2)        ::ring::Scalable_witness<T>::scale(&a, 2)
    p->scale(2)       ::ring::Scalable_witness<T>::scale(p, 2)
    make().scale(2)   ::ring::Scalable_witness<T>::scale(::__kairo_tmp(make()), 2)
    a == b            ::m::Eq_witness<T>::__kairo_op_eq(a, b)
    T::make()         ::m::Eq_witness<T>::make()
    s.push<U>(u)      ::m::Sink_witness<T>::template push<U>(&s, u)
    c.get(0)          ::m::Container_witness<T, U>::get(&c, 0)        T impl Container<U>

A requirement callee that reaches EmitIR WITHOUT a recorded witness, or as
a `::` / member step, ICEs naming ExtensionLowering. Non-generic code never
reaches a witness: a call on a concrete receiver is bound to the
implementing decl, not to the requirement, and stays the qualified call
§6 spells. A `: type` body has no interface to key a witness on and never
uses one (RESOLUTION.md §2b, the `: type` rule). A call through a pointer
to a VIRTUAL interface (`*Allocator`) is runtime dispatch, a different
table (interfaces.md, Virtual Interfaces), not compiled, and stays an ICE.

### 7b.6 Where each piece is emitted

All three are tier-1 plan entries, definitions, emitted inside the
INTERFACE's namespace wrapper (an explicit or partial specialization is
declared in the primary's namespace; for a pathless TU's priv interface
that is the unnamed namespace, and only that TU can reach it).

- **Primary and concept**, keyed on the `InterfaceDecl`: a tier-0 forward
  declaration `template <class __kairo_Self, ...> struct I_witness;`, then
  the primary and the concept in tier 1, after the Complete deps of their
  signatures (a forwarder is an inline definition: by-value records at
  Complete, as for an operator forwarder, §3). Admitted at Complete by
  every generic decl the plan DECLARES whose constraint set bounds by I --
  the concept is in its template head, so a tier-2 declaration needs it,
  not only a body -- by every specialization of I, by the concept of every
  interface deriving I (`Stream_c` conjoins `Readable_c`), and in Header
  and Include modes by every pub interface root. The text is a pure
  function of the interface, the same in every TU and header (invariant
  11's reason).
- **A specialization**, keyed on its ROW, at Complete after the primary,
  X at Complete, every extension scope it forwards to at Complete (a call
  into a static member needs the class), and its signatures' deps. It is
  admitted in EVERY TU whose plan holds an instance that binds the row --
  a tier-3 entry, home or `extern template`, or an instance reached by a
  visible body -- closed over the instances that instance's body reaches
  (M1's transitive registry). Not the home TU alone, as RESOLUTION.md had
  it: visible template bodies are emitted C++ `inline` (§7), an explicit
  instantiation declaration does not suppress the implicit instantiation
  of an inline function, so any TU that calls `twice<Metric>` may compile
  it; a TU that does so without the specialization in sight compiles the
  primary instead, ill-formed NDR ([temp.expl.spec]/7); and the
  `extern template` line itself checks `Scalable_c<Metric>`. The row is
  also admitted, for DECLARED rows only (`class X impl I`, `extend X impl
  I`), in every TU and header that emits the declaring decl -- there X is
  complete and I named, and X's own header is where a host looks: a C++
  host instantiates Kairo templates with types Kairo never paired, and a
  declared conformance is enumerable where a structural one is not. A
  STRUCTURAL row met by extension members reaches only the TUs that hold a
  Kairo instance needing it; a C++ host instantiating with that type
  itself fails `I_c` at its call, never compiles a different witness
  (question 2).
- **Dedupe and ODR.** One entry per (InterfaceDecl) and per row in a plan;
  `IncludedDecls` keys them by the same identity, so a second `#include
  "foo.k"` in one C++ TU drops the witnesses an earlier one wrote. Across
  TUs the text is a function of the interface and the row alone -- each
  specialization written COMPLETELY, every requirement, whatever use
  touched it, as an extension scope is (§3) -- so every TU and header that
  writes one writes the same class, and C++ allows a class definition in
  every TU that writes the same tokens.
- **Header mode** emits the witnesses its roots and bodies reach, exactly
  as a preamble does; the primary and declared specializations are part of
  a module's C++ interface from then on. **Include mode** adds no rule: it
  is a Header's roots emitted as a Preamble is.

### 7b.7 The concept, and invariant 13

Every emitted generic decl with interface bounds carries `requires
::N::I_c<P, A...> && ...` in its template head, one conjunct per `P impl
I<A...>`, in bound order. It is spelled by `CXXSpell::template_head`, the
one speller, so the declaration and the body carry the same clause (an
`extern template` line or explicit instantiation definition has no
template head and carries none; clang matches it to the constrained
template): two
declarations of one function template must have equivalent template heads
([temp.over.link]), and clang mangles the constraint into the symbol
(`_ZN4ring5twiceINS_6MetricEQgssr4ringE10Scalable_cIT_EEEiS2_`, checked by
hand), so a difference is a link failure, not a diagnostic -- and adding or
removing a bound changes a generic's C++ ABI. `derives`, kind
bounds, value predicates and `where` are NOT rendered: Kairo checks them at
the instantiation site and WhereDispatchLowering reduces them (IMPORTS.md
§7), as before.

The concept is `I_c<S, A...> = (base interfaces' concepts) && requires
(<one parameter per requirement argument, typed as the witness member
takes it>) { <a call of each witness member>; <each constructor
requirement>; }`. For an instance Kairo enumerated it is always true --
ConformanceChecking proved the row -- so in a Kairo TU it can only fail on
a compiler bug, and then as clang's constraint failure at the call rather
than an error deep in the witness. Its job is the instantiations invariant
13 cannot enumerate: a C++ host's, and clang's own (§7's visible-bodies
reason). Generic requirements are left out of the concept (no argument to
call them with; question 6).

Invariant 13 (IMPORTS.md §3) needs one sentence revised, which this change
does not make: "Emitted templates carry no `requires`" becomes "emitted
templates carry no `requires` except the interface concepts EmitWitness
derives (CODEGEN.md §7b), one conjunct per interface bound, true for every
instance Kairo enumerated". Its title, "clang never instantiates", is
already qualified by §7 (clang instantiates what Kairo never names) and
should say "Kairo enumerates every instance it can see".

### 7b.8 Monomorphization and explicit instantiation

Witnesses add no registry entry and no tier-3 line: the members are inline,
the primary is instantiated implicitly per Self wherever a body uses it,
and a specialization is complete on its own. The registry feeds them
instead: the instance -> rows map M2 writes (RESOLUTION.md §2b) is the
whole input of the specialization edge. A generic REQUIREMENT called with
arguments registers a CallExpr instance whose primary is the requirement
(CallTyping registers every generic callee); it names no C++ function, and
EmitPlan must never write a tier-3 line for it (today's guard is the
`InterfaceDecl` owner check at admission; keep it when interfaces become
plan entries). A generic RECORD with a bound (`class <T impl I> Box`) and a
bounded generic extension are instances like any other: `Box<Metric>` in a
plan admits the rows its bounds bind, and the witness reference is spelled
inside the class template's member bodies.

### 7b.9 Interfaces, case by case

- **`derives`, and composition.** Every interface is normalized before
  binding into a plain requirement list, its own members and everything its
  `derives` expression yields (`+` union, `-` difference, `&` intersection;
  Sema/Check/InterfaceComposition.k). A witness belongs to the BOUND: a call
  bound to `Readable::read` through `T impl Stream` is
  `Stream_witness<T>::read`, Stream's single row covers every requirement in
  its list, and Stream's concept lists them all rather than conjoining
  Readable's. A requirement inherited through a concrete generic instance
  (`derives Container<i32>`) is spelled at that instance's arguments. One
  inherited through a DEPENDENT instance (`interface <T> F derives
  Container<T>`) is two substitutions deep, Container's E := F's T := the
  row's argument: the primary and concept apply only the first (they are
  written inside F's template, where T is in scope), and a specialization
  spells it through the source Sema substituted at the row's arguments
  (`ConformanceRow::sources`, `Container<i32>`), which is both at once.
- **Multiple bounds.** Each call is bound to one requirement and goes
  through the bound whose list contains it. Two bounds both declaring `m` is
  the typer's ambiguity (RESOLUTION.md §2b, "collide at the use"), never
  codegen's.
- **Default methods** do not exist (interfaces.md, "No Default
  Implementations"); there is no default-body forwarder to emit.
  MemberLookup's "default bodies join the set" comment predates that rule.
- **Bounds on an interface's own parameters** (`interface <T impl
  Comparable> Registry`) are Kairo-checked at the bound's use and are not
  rendered into `Registry_c` (question 6).

### 7b.10 Diagnostics

User errors are Sema's, never codegen's: an instantiation whose argument
does not conform (ConformanceChecking at the instantiation site; no code
exists for it yet, so it is the `SC001` placeholder until one is minted),
a conformance whose implementing decls are outside the instantiating TU's
import set (the extension-visibility rule), an unparameterized bound on a
generic interface, and an extension member reached from a `: type` body
(M2's re-check). Codegen keeps ICEs, each naming its owner: a requirement
callee with no recorded witness (ExtensionLowering); an instance whose
bound binds no table row (ConformanceChecking / M2); a row with no decl for
some requirement (ConformanceChecking); `T::Node` (associated types); a
virtual-interface call.

### 7b.11 Tests

`Tests/Codegen/witness/`, each a `--print-cxx` golden plus a link whose
exit code is computed, as §9's lowering tests are:
- `extension.k`: the ticket's repro (exit 6); the golden shows the full
  specialization and the witness call.
- `own_member.k`: the same with a member `scale`; the golden shows NO
  specialization. `inherited.k`: the member on a base.
- `builtin.k`: `extend i32 impl Scalable`.
- `operator.k`: an own and an extension `op ==`, a postfix `op ++`, `op in`; const
  and non-const; a prvalue operand.
- `static.k`: `T::make()` with `-> Self` (today's I011W case).
- `generic_iface.k`: `impl Container<i32>` and `impl Container<string>` on
  one type; `generic_conformance.k`: `extend <T> Pair<T> impl
  Container<T>` (a partial specialization).
- `generic_requirement.k`: `fn <U> push(self, u: U)` through a bound.
- `derives.k`: a call bound to a base interface's requirement.
- `generic_record.k`: `class <T impl I> Box`; `nested.k`: `f<T>` calling
  `g<T>`, rows reached transitively.
- `diamond/`: interface, type, extension and two instantiating TUs in
  separate modules, both instantiating `twice<Metric>`; one `.o` per
  module, `clang++ -Wodr` link; `nm` shows the constrained template's
  symbol is the same in the declaring and the home object.
- `include/`: a kcc host instantiating with a declared conformer (links),
  with its own C++ class (the primary; links), and with a structural
  extension conformer (expected clang constraint failure, checked as one).
- `header/`: `--emit-headers` golden carrying the primary, concept and
  declared specializations.
- `Tests/Sema/Check/conformance_at_instantiation.k`: the non-conforming
  call is a Sema error; XFAIL, naming ConformanceChecking, until it lands.

### 7b.12 Open questions

1. **Reserved names.** `LowerTargets::witness_suffix` / `concept_suffix`
   give `Scalable_witness` / `Scalable_c`, which a user can also declare
   in the same namespace; CxxNameCheck reserves only the `__kairo_`
   prefix (invariant 9b). Rename to `__kairo_witness_<I>` /
   `__kairo_concept_<I>` (and add `__kairo_Self`), or keep the readable
   names and have CxxNameCheck reject the suffixed forms?
2. **Structural conformance through extension members.** Spec/Docs makes
   conformance structural and decided at the point of use, and the ticket's
   repro relies on a plain `extend Metric { fn scale }` satisfying
   `Scalable` with no `impl`. Such a row cannot reach a C++ host that
   instantiates on its own (7b.6). Is "a C++ host needs `impl`" the
   intended rule, or should structural extension rows be rejected, or
   enumerated (a per-TU search over interfaces x extension scopes)?
3. **Two Kairo builtins, one C++ type.** On x86_64-linux `i64` and
   `isize` both spell `long` (`signed long`, and `ptrdiff_t`'s `decltype`
   form), as do `u64` and `usize`. Conformances of both to one interface
   are two explicit specializations of one class (a clang redefinition),
   and `twice<i64>` / `twice<isize>` are one C++ instantiation. Reject the
   pair in Sema, or require them to forward to one decl?
4. **Overlapping conformances.** `extend <T> Vec<T> impl I` beside `extend
   Vec<i32> impl I`: allowed? If so, M2's partial selection must agree
   with C++ partial ordering of the two specializations.
5. **Free functions as witnesses.** May a free (C++ or ADL-found Kairo)
   operator or function satisfy a requirement? If so, its row is a
   specialization forwarding to it qualified.
6. **What `I_c` checks.** Generic requirements, bounds on the interface's
   own parameters, and associated types are out of it today. Include any?
7. **Primitives and constructor requirements.** DECIDED: `i32` does not
   satisfy `interface Defaultable { fn Defaultable(self) }`, since Kairo
   rejects `i32()` (SC037E) though C++ `int()` would compile. A record
   with no declared constructor meets a zero-parameter one, as `S()`
   types.
8. **Conditional conformance.** Is `extend <T impl Comparable> Pair<T>
   impl Sorted`'s partial specialization constrained with `requires
   Comparable_c<T>`, so a host's `Pair<NotComparable>` fails at the call,
   or left unconstrained?
9. **Which pass routes the call.** ExtensionLowering (recommended above,
   one pass for both receiver tables) or a WitnessLowering beside it.

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
the input's object and one per builtin TU it pulled in — `%t.d/*.o
%t.d/builtin/*.o` — because the Slice instance is homed in whichever of
them used it. `--print-cg` goldens carry the fid column and preamble
offsets.

## 10. Open

Piece 1 (root naming by `module X;` declaration; `-I` becomes C++-only);
`const T&` for by-value records; witnesses/concepts (§7b); per-TU header reuse
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

Constructor initializer lists for every constructor: only a split one
(a const field, §6) builds the fields S_pre assigns by mem-initializer; any
other constructor that assigns a defaulted field in its body still runs
the default first, then the assignment. The fast path the design allows
for a split constructor (straight-line S_pre lowered into the
mem-initializers with statement expressions, no slot record) is not
written; the slot path is always correct. Per-instance `constinit` for a
generic record's static whose initializer is a thunk: deciding constness
per instantiation (and Kairo's own diagnostic when one cannot be
constant) needs the monomorphizer (M1/M2), so today such a static is
always dynamically initialized. `eval` fields as constants. AccessCheck. Vector/HashSet/
HashMap constructor bodies in `Lib/builtin` — vector literals type-check
and emit today, but do not LINK. Set and map literal lowering, which needs
`Pair<K, V>` and the Slice constructors on HashSet/HashMap. Static
promotion of an all-constant `const`-element slice literal.