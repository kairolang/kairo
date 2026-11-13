# Codegen

Codegen turns a lowered, checked tree into C++ tokens for an in-process clang. This document is the contract for everything under `Compiler/Codegen/`. The lowerings that produce its input are specified in [Lowering.md](Lowering.md#passes); calls through interface bounds in [Witnesses.md](Witnesses.md); the instantiation model behind templates in [Generics.md](Generics.md#instantiation-model).

## Model

Kairo lowers to C++ by injecting a token stream into clang. Every emitted TU is a preamble (the declarations a header would have provided, own and foreign), then the bodies the TU defines, then the explicit instantiation definitions it homes. Nothing is `#include`d except ffi headers, and `<new>` where a derived assignment rebuilds a value in place ([Derived comparisons and assignment](#derived-comparisons-and-assignment)).

Three rules govern the layer:

1. Sema decided everything; codegen renders decisions. Every name is spelled from a `*Decl`, every type from a canonical, every call from the promoted callee. Codegen never looks anything up and never asks clang to.
2. No headroom for clang. The emitted C++ leaves clang nothing to choose: names fully qualified, every argument exactly its parameter's type, every compound expression parenthesized, user operators as explicit calls, `extern template` for every instance not homed in this TU.
3. Lowering reduces; codegen emits the core. EmitIR knows the C++-shaped subset of Kairo ([EmitIR](#emitir)). Every other node is an ICE naming the lowering that owns it. Codegen never grows an arm for a node a lowering removes.

Rule 1 covers lang records. Every lang record at concrete arguments is built through `SemaContext::lang_record`, which registers the instance (`InstantiationRegistry::instance_for`) and points the `RecordType` at the instance node, as a written `Foo<i32>` does. A written `[i32;]`, a literal typed `[i32;]` and a spelled-out `Slice<i32>` are one canonical, and that instance has a home TU for its explicit instantiation. `TypeResolve::_lang_record` and `TypeUtil::lang_record` delegate to it; nothing else builds a lang record. A dependent use keeps the primary.

## Pipeline

    FrontendAction::_codegen      per non-foreign fid
      CodegenBackend::run(out)     one CompilerInstance, one .o
        fill(TokenSink)
          EmitPlan(Preamble)                          the plan
          InterfaceEmitter::run                       tiers 0-2, and tier 3 `extern template`
          EmitIR::emit_tu                             own bodies, and foreign bodies visible here
          InterfaceEmitter::emit_home_instantiations  tier 3 home definitions, after every body
          eof

Objects land at `<obj-dir>/<module path>.o` (`--obj-dir`; a single-TU build with `-o x.o` uses that path). `--print-cxx` runs the same plan into a `TextSink`. `--emit-headers <dir>` runs `EmitPlan(Header)` into `<dir>/<module path>.hh` ([Headers](#headers)). Both work under `--type-check-only`. Flag semantics are in [Driver.md](Driver.md#flags).

Codegen refuses a TU (stage `Failed`, no object) when any TU it transitively imports reported a Sema error (`ASTContext::sema_errored`), so clang never sees C++ written from a poisoned tree.

Under the [interface PCH](#the-interface-pch) the interface tiers and the template / inline bodies come from the PCH, and a TU writes the rest.

TUs are filled in parallel; the job split, the worker pool and the thread-safety invariant (an emitter writes only its own TU's state) are specified in [Performance.md](Performance.md#parallel-codegen).

### The merged PCH

Every TU loads its graph's ffi header sets as one implicit PCH (`HeaderSetCache::codegen_pch`; clang loads only one): the sets' replay text inside the FP pragmas, parsed once. It is started on the pool as soon as Sema's phase A joins (`prebuild_codegen_pch`), so it overlaps Sema and the lowerings; `_codegen` joins `CODEGEN_PCH_GROUP` and looks it up by the same list (`_graph_header_sets`). If it fails, each TU loads its biggest set as the PCH and `#include`s the rest through wrappers (`CodegenBackend::run`). Header sets are specified in [Interop.md](Interop.md#clang-integration).

### The interface PCH

A TU's stream is not its whole preamble (every declaration it reaches, own and foreign), every foreign template and inline body visible to it, and its own bodies last. Over the compiler's own 316 TUs a whole-preamble stream is 38 M tokens for 10 MB of Kairo, 90% of it interface that clang would parse again in every TU that imports it. The interface PCH parses it once per build (`Compiler/Codegen/Backend/InterfacePCH.k`, built by `FrontendAction::_codegen` after `CodegenRun::mount`, before the fan-out).

Its stream is the [include stream](#include-streams) model run over every TU of the build, in TU order: each TU's Preamble plan through `IncludeEmitter::emit` in program mode, with one shared `IncludedDecls`, so every plan entry, helper block, body and eval binding is written once, in an order that TU's plan already made valid. Program mode differs from a kcc include in four things: the plan is a Preamble (priv declarations too: the TU's own object names them), no ffi header set lines (the merged header PCH below holds every set), `cxx_exceptions` is off (as in a Kairo TU's own stream), and the plan may come ready-made (`pre`). Like an include it writes no explicit instantiation; tier 3 stays with the TUs. The PCH is chained on the [merged PCH](#the-merged-pch), so a TU still loads one implicit PCH.

Every TU of the flavour then loads it (validation off: this process built it from these files a moment ago) and prunes its own plan by the same keys (`IncludedDecls::has`) and its bodies by the same set (`EmitIR::pch_bodies`, checked in `_free_fn`, `_method` and `_global_var`). The PCH's stream ran this very plan, so what is left is tier 3 (the TU's `extern template`s and homes) and the bodies its object defines; an entry missing from the PCH is counted on the `-v` line and emitted as before. Each TU's plan is run once, on the pool, before the stream (`CodegenJob::make_plan`); the stream and the TU's `fill()` both use it, and `fill()` restores its entries, because a TU fills once per kind and again on the rerun below.

Rules that keep the output a function of the source alone:

- **Flavours.** A declaration must be spelled the same in every TU that shares a PCH. One spelling depends on the TU writing it: a `thread` global's `tls_model` (toolchain TU or not, `CXXSpell::tls_model`). TUs are partitioned by `CXXSpell::interface_flavour` and each flavour gets its own PCH; a new TU-dependent spelling must be folded into that function.
- **Diagnostics.** The PCH moves which TU's bytes a declaration's tokens blame and which TU instantiates a template first, so a clang diagnostic under it can name other bytes. A TU whose clang run says anything is compiled again from its whole stream, and only that run's diagnostics are kept (`CodegenJob::run`). A clean TU is unaffected; a failing one pays twice.
- **Not built** under `--print-cg` / `--print-ir` (they print each TU's whole stream) or `-Wshift-count-unproven` (it reports on own bodies a TU no longer writes). If the build fails, every TU of the flavour takes the whole-stream path.
- **Auto mode.** Only for a flavour of at least two TUs and 1 MiB of Kairo (`IFACE_PCH_MIN_BYTES`): the PCH is one serial parse ahead of a parallel fan-out, and below that the parallel re-parse is cheaper (hello.k: 28 TUs, 180 KB, 0.17 s to 0.24 s). `--interface-pch=off` turns it off, `--interface-pch=on` forces it (a bare `--interface-pch` is `on`), and under `--verbose` a failed build's clang diagnostics are shown.

Why one union rather than a PCH per module: clang loads one implicit PCH per TU and a chained PCH is linear (each layer is built against the one below), so per-module PCHs cannot be combined per TU; a chain of module layers parses the same total as the union and only adds layers. Clang modules would need module maps or `import` declarations, which a token stream injected into one TU has no place for, and C++20 named modules change linkage and mangling. A PCH loads lazily, so a TU pays for what it touches, not for the union's size.

**Incremental compiles** (not implemented; the full design is [Incremental.md](Incremental.md)). The artifact keys this design is meant to carry: the PCH by a hash of its stream's token kinds and spellings, the flavour, the cc1 invocation and the header PCH's key (token locations only under `-g`, where debug info reads them; a diagnostic is re-run from the whole stream anyway), stored under `--cache-dir`; each admitted entry and body with a hash of its own tokens beside its `IncludedDecls` key; and a TU's object by its own stream plus the hashes of the PCH entries and bodies its plan names. Then a body edit changes one TU's key, and an interface edit only the keys of the TUs whose plans name the changed entries.

### Include streams

`#include "foo.k"` from a C++ input ([Interop.md](Interop.md#kcc)) runs `EmitPlan(Include)`, which is a Header's roots (pub decls, and a priv or internal one only when an inline or template body names it) emitted as a Preamble is, then `InterfaceEmitter::run` into a `TokenSink` bound to the host's preprocessor (`Compiler/Codegen/Backend/IncludeEmitter.k`), then EmitIR over `EmitPlan::include_bodies()`: the template and `inline` bodies a C++ consumer compiles itself, foreign and foo's own.

An include stream writes no other body, no eof, and no explicit instantiation of any kind. The host may come from a different run than the homes (`kcc -c x.cc; kcc -c foo.k`), so it instantiates implicitly and the linker folds that with the homes' `weak_odr` definitions.

A token stream cannot carry `#ifndef`, so a second include in one C++ TU drops what an earlier one already put there (`IncludedDecls`: helpers, plan entries keyed by decl and tier, bodies, include lines). Nor can it carry `#include`: the system headers and ffi header set of every module the stream draws on go back to the hook as lines, which it enters in a buffer ahead of the stream (`Compiler/Interop/Clang/KairoInclude.k`). The stream's other properties (`-E` output, include-once) are in [Interop.md](Interop.md#kcc).

### Source layout

Only `Backend/` imports emitters, and only `Backend/` and `Sink/` import clang headers.

| Path | Contents |
|---|---|
| `Compiler/Codegen/CodegenContext.k`, `CodegenICE.k`, `EmitPlan.k` | shared by every file below |
| `Compiler/Codegen/Emit/` | `CXXSpell`, `InterfaceEmitter`, `EmitIR`, `EmitWitness` |
| `Compiler/Codegen/Sink/` | `EmitSink` (interface), `TokenSink`, `TextSink`, `TokenStreamPrinter` |
| `Compiler/Codegen/Backend/` | `CodegenBackend` (an object), `EmitCXXHeader` (a header), `IncludeEmitter` (`#include "foo.k"`), `CodegenAction` |

Lowering spellings that codegen and lowering passes share (helper names, mangled prefixes, inline limits) are `LowerTargets`, in `Compiler/AST/LangItems.k`.

## Sinks

`EmitSink` (`Compiler/Codegen/Sink/EmitSink.k`) is the base: `spell(at, text)` tokenizes a C++ fragment into identifiers, keywords, punctuators and integers, with sugar (`kw_*`, `punct`, `brk`, `directive`). Emitters import `CodegenContext` only; clang types are visible transitively.

| Sink | Output |
|---|---|
| `TokenSink` | located clang tokens. Every token blames a Kairo location through `ClangLocMap::to_clang` (any registered fid), so a foreign declaration's tokens carry the foreign file. |
| `TextSink` | bytes, with spacing rules: tight before `::` `<` `>` `(` `)` `*` `&` `,` `;` `:`, tight after `::` `<` `(` `~`; `::` tight only after a word. |

Identifiers are never byte-borrowed. `TokenSink` spells an identifier from its `IdentifierInfo` and reads the range only as caret geometry, so `EmitIR::_name(Token)` always goes through `create_ident` with the spelling from the imm table of the file that owns the body being emitted (for a foreign template homed here, not this TU's). Float and char literals still borrow their bytes (`synth` to `literal`), so a lowering that mints one must spell it from its value, as `_int_lit` does. A declared name is spelled by `CXXSpell::tok_name`, which reads a macro-wrapped name token through its expansion: its imm is the `MacroExpansionInfo` record, not an identifier, and read as one it named whatever sat at that index (a member `fn get(o: i32)` from a macro was emitted as `mm(signed int main)`).

Token pairs clang checks for adjacency (`(` `{` of a statement expression, `}` `)`) must share one expansion location, or clang warns `-Wcompound-token-split-by-macro`. The warning is not disabled as a backstop, because `_cc1_common` also compiles the program's own C and C++, where it is legitimate.

## EmitPlan

`Compiler/Codegen/EmitPlan.k`. Per TU, the set of declarations the emitted C++ needs, with strengths and order. EmitPlan reads Sema's links and no `ImportDecl` except for ffi imports.

Roots are every own decl (Preamble) or own `pub` decl (Header), plus the canonical redecl link of every foreign decl reached through `NamedIdentExpr::resolved_decl`, `ChainExpr::Step::resolved_decl`, every entry of a `candidate_cell`, and `RecordType::decl` of every canonical. Decls from a C++ header (`is_imported()`) are never emitted; the header declares them.

### Edges

The closure repeats until no growth. An edge is Fwd (the target need only be declared, `class X;`) or Complete (its full body-less definition must precede). A class is emitted whole or not at all ([invariant 24](Pipeline.md#invariants)): if `main` never imports `bar` but `foo::F` holds a `bar::B` by value, `B` lands in main's TU. Import order plays no part.

| From | To | Strength |
|---|---|---|
| function | parameter and return types | Fwd |
| class / struct | bases, by-value field types | Complete |
| class / struct | pointer and nullable field pointees, method signature types | Fwd |
| class / struct at Complete | by-value types of its method signatures, and what its member `type` aliases name | Complete |
| class at Complete | its same-file extension scopes (its friend structs; `friend_scopes_of()`) | touched |
| union | field types | Complete |
| enum | underlying type | none (builtin) |
| type alias | target | Complete |
| instance shell | its primary | Complete |
| instance shell | each argument | the strength the primary's by-value spine gives it (`param_by_value`, memoized, depth-capped) |
| member call | the owner | Complete |
| `sizeof` / `alignof` | the operand | Complete |
| a static member through an instance (`CallExpr::qualifier`, `ChainExpr::Step::through`) | the instance | Complete |
| generic primary | as its kind | interface only |

Nested types are part of their owner's definition. A record at Complete pulls in its method signatures and member aliases because any code in the TU may call a member of a complete class or read `R::promise_type`, including code Kairo never sees (clang's coroutine machinery). That edge sets strength only; definition order still follows layout (bases, by-value fields).

Every body the TU emits is walked at body strengths: its own, and every foreign template and `inline` body visible here ([Templates](#templates)). Anything such a body names is declared in the preamble, priv helpers included. A module's priv function has external linkage, so the call links; a pathless TU's internal decls are never reached, since nothing imports a file outside every search dir and library ([Imports.md](Imports.md#path-resolution)).

### Extension scopes

An extension member is a static member of its extension scope (`ExtScope`, `struct N::__kairo_ext_X`, one per namespace and target; the model is in [MemberLookup.md](MemberLookup.md#extensions)). It never appears twice: a `FunctionDecl` whose `lexical_dc` is an Extension is routed to its scope on admission.

- A scope is filled completely when first touched: every extend block of that `(N, X)` in its file, in source order, priv members included. Its text is therefore the same in every TU. Two targets that spell one struct name in one N are an ICE.
- Every member's signature is expanded at Fwd, priv included: the struct is emitted whole in every TU that touches it, so a type only a priv member names must still be declared.
- A scope's Complete deps are its target, every by-value record its operator forwarders' signatures name (a forwarder is an inline definition), and the outermost owner of every nested type a member signature names (`Other::Inner` is reachable only through a complete `Other`).
- A class may have several same-file scopes (`module Geo { extend Point {...} }` beside a file-scope extend).

Witness pieces sit beside the scopes as plan entries ([Witnesses.md](Witnesses.md#emission)).

### Tiers

| Tier | Contents | Order |
|---|---|---|
| 0 | forward declarations of every type in the set, grouped by namespace; `struct __kairo_ext_X;` for every touched scope; witness primaries and concepts | breaks every pointer cycle up front |
| 1 | type definitions; scopes; witness definitions; early eval items | topologically sorted on Complete edges; each scope after its deps |
| 2 | function declarations (extension members are never listed) | any |
| 3 | instantiations: `extern template` unless this TU is the instance's home, `template class` if it is | after tier 2 for `extern template`; home definitions after every body |

A preamble emits every touched scope; a header only those a root reaches (and always the whole struct). A cycle among Complete edges is a Kairo error owned by TypeCycleCheck ([SemanticChecks.md](SemanticChecks.md#check-passes)); the plan asserts. Within a tier the tie-break is (source fid, source order), so output is deterministic.

A file-scope `main`, in any TU (`CXXSpell::is_main`), is emitted at global scope and never declared in the interface or a header. A `fn main()` with no result is `int main()`. A bare `return` in it is `return 0;`, and so is the early return an `eval for` expansion leaves in it (`EmitIR::_bare_return`), because `return;` is ill-formed in `int main`. A pathless TU's decls go in the file's own namespace ([Namespace wrapping](#namespace-wrapping)).

### Early eval items

A declaration's type may itself compute from an eval item (`[i32; f(3)]` as a field, `Buf<twice(1)>` in a signature, `var g: [i32; f(1)]` at namespace scope), and C++ evaluates it where the declaration stands, in the interface. Those items and everything they read transitively are the plan's early items (`EmitPlan::early`, `_early`):

- every free one is declared at the start of tier 1, except one whose own signature computes from another early item (`eval fn f(a: [i32; g(1)])`): C++ evaluates `g(1)` where f is declared, so f is declared right after the last such item is defined (`InterfaceEmitter::_late_decls`), and every item that calls f is ordered after them (`EmitPlan::sig_items`);
- each is defined by a tier-1 entry of its own (`PlanEntry::eval_item`), which InterfaceEmitter hands to the shared EmitIR (`EmitIR::early`; the backends construct one EmitIR and give it to the interface);
- the toposort places each after the records its definition needs complete (by-value types in its body, a member's class) and, for an eval binding, after every item its value reads; a body only after what it evaluates at its own definition (a computed type inside it, an eval local), so mutual recursion orders freely; a record after every item its own types reach.

EmitIR skips them afterwards (`_eval_done`, `_early_vars`); an include stream marks them as bodies the host has. A cycle among those edges is EvalUsageChecking's error (`_check_order`); reaching the toposort with one is an ICE. The items a generic record's value predicate names are early items of the record too (`EmitPlan::_decl_type_items`; [Witnesses.md](Witnesses.md#the-concept)). Which items are early, and their spellings, are in [Eval.md](Eval.md#codegen).

### Use sites

There is no alias tail: an `import foo as f` or `import foo::add as my_add` produces no `namespace f = foo;` or `using`. Every use is printed fully qualified from `resolved_decl`. An alias would only make the C++ read like the Kairo, at the cost of a second naming mechanism, and an alias is TU-local and never appears in an exported interface ([invariant 23](Pipeline.md#invariants)). Use-site exactness is EmitIR's: every argument whose type differs from the parameter's canonical is cast to it ([No-headroom rules](#no-headroom-rules)), so C++ overload resolution has one exact candidate.

### Plan modes

| Mode | Roots | Consumer |
|---|---|---|
| `PlanMode::Preamble` | every own decl, and foreign decls reached | `CodegenBackend` (object), `--print-cxx` |
| `PlanMode::Header` | own `pub` decls, and foreign decls reached | `EmitCXXHeader` (`--emit-headers`) |
| `PlanMode::Include` | a Header's roots, emitted as a Preamble | `IncludeEmitter` |

The same `InterfaceEmitter` serves all three. A C++ consumer of a header sees canonical namespaced names and nothing else.

## CXXSpell

`Compiler/Codegen/Emit/CXXSpell.k`. Every C++ spelling of a Kairo entity comes from `CXXSpell`, and all emitters use one instance, so a declaration and a body cannot disagree.

`qual_name(d)` : `::` + module segments (root name + path, [invariant 9a](Pipeline.md#invariants)) + owner types + leaf. Module segments resolve `SymbolID`s through the PP table (`ns_segments`).

`leaf(d)` : the identifier, or for an operator `operator_name(f)`: `operator+`, `operator[]`, `operator<=>`, `operator T` for `op as`, `~Owner` for `op finally`. Word operators map to symbols; `l`/`r` on `++`/`--` is fixity (`op_is_postfix`), not name. Operators C++ cannot spell take `LowerTargets` names (`__kairo_contains` / `__kairo_iter` for the two `op in`, `__kairo_pow`, `__kairo_dotstar`, `__kairo_await`). `===` is not a declarable operator: CoalesceLowering expands it before codegen. A hoisted local's leaf is `__kairo_local_<line>_<col>_<name>` ([Local declarations](#local-declarations)). A split subscript's forms (its type declares `op []=`; `OperatorFacts::in_split_subscript`) are the members `__kairo_op_get` (`op []`) and `__kairo_op_set` (`op []=`), `LowerTargets::subscript_get` / `subscript_set`: Sema chose the form, and a call by name is that form whatever the object's constness (clang picking `operator[]` would give every read of a mutable object the place form). C++ users get `operator[]` forwarders (`CXXSpell::subscript_forwarded`): declared in the class by `InterfaceEmitter::_subscript_forwarders`, defined beside the form's own definition by `EmitIR::_subscript_forwarder_def` (out of the class, so a by-value `Slice<T>` / `Range<usize>` in the signature is complete), the place form's non-const and returning `T&`, a read form's `const` when it takes `const self`. A read form C++ would see as the same overload as a place form (one constness, one operand type) gets none: the place form takes `operator[]` and the read form is reached by name. Member-template forms and unnamed operands get none. A type with no `op []=` keeps `operator[]` itself, unchanged.

Extension operators : An extension operator is a non-member C++ operator taking `X&` / `const X&` (a class-typed parameter, as [over.oper]/7 requires), spelled as a member's is. Its body binds `self` to the reference's address (`X* self = &__kairo_self;`), so the body emits unchanged. Every Kairo use is an explicit call passing the object, not its address.

`_type(t)` : canonical to C++. Builtins by table (`i32` is `::std::int32_t`); records qualified, with instance arguments from the registry; pointers, references and arrays through `decl()`. A tuple canonical is an ICE (TypeResolve canonicalizes every tuple to its `TupleN` record). `T?` stays a `NullableType` canonical for Sema and is spelled, and planned (`EmitPlan::_nullable_record`), as the `::builtin::Nullable<T>` record NullableTypeLowering put in its `lowered` slot; with none it is an ICE naming that pass ([Nullables.md](Nullables.md#codegen)). A `null` typed as a nullable arrives as that record's null `VariantInitExpr`.

Function types : A Kairo `fn(A) -> R` is the value type `::__kairo_fn<R(A...)>` (`fn_signature(f)` spells `R(A...)`), never `R(*)(A...)`: a closure has the `fn` type ([closures](README.md#language-reference)), and a capturing lambda has no function pointer ([Closures](#closures)). A raw `unsafe fn(A) -> R` (`is_raw`) is `::__kairo_raw_fn<R(A...)>`, an alias of `R(*)(A...)` that reads as one name in any declarator; so is a C no-prototype pointer (`is_unprototyped`, `R(*)()`).

`decl(t, name)` : the declarator form with the name folded in. `[T; N]` is a C array; the positions it may take are the expression typer's rule ([ExprTyping.md](ExprTyping.md#expression-typing)). A `[...]` literal with no container target has type `[T; N]`. A declarator starting with `*` or `&` is parenthesized before the array suffix (`signed int(*)[2]`). Where a type is spelled as a string that text is then appended to (`*`, `&`, ` const &`, a name), `CXXSpell::type_specifier` spells an array as one type-specifier, `__typeof__(signed int[2])`: an extension's receiver (`ext_receiver`, the operator's `self` rebinding in `EmitIR::_body`), a generic parameter an instance binds to an array (`_gparam`, so an explicit instantiation reads `__typeof__(int[2]) const &`), and a witness of an array conformer, which names Self through its `__kairo_Self` alias as a pointer conformer does.

`f8e4m3` / `f8e5m2` are spelled as their classes (`::kairo::std::rt::Float8::F8E4M3`), complete wherever used (EmitPlan), as f256 / f512 are. A literal is `F8E4M3::from_bits(b)`, `b` the encoding rounded once from the digits at compile time (`EmitIR::_f8_lit`, `kairo::f8_literal_bits` in Native/KShims.hh over APFloat; an E4M3FN overflow saturates to 448, Kairo's rule); a limit is `static_cast<Class>(<exact double>)` (`PrimitiveLimits::float_cxx`); `+=` and the other compounds are `place = place OP v` (`_wide_compound`); `{x}` calls the class's `fmt_put_`.

`param_type(p)` : the name-less form (instantiations, function-pointer parameter lists). `@inout` is `T&`, `@move` is `T&&`, otherwise `T`. A const parameter (`CXXSpell::const_param`: written, or inferred) is `const T&` for a concrete record, `T const&` for a bare type parameter, `const T` otherwise.

`param_decl(p, name)` : the parameter with the name folded into the declarator. The mode's `&` / `&&` and the const marker go through `decl()`, so a raw function pointer is `U (*f)(T)` and an `@inout` one `U (*& f)(T)` (appending the name, `U(*)(T) f`, is a cast-like expression to clang). A Kairo `fn` parameter is `::__kairo_fn<U(T)> f` (`& f` for `@inout`). Arrays keep their own branch: `const [T; N]` is `const T (&name)[N]`, `@inout` is `T (&name)[N]`, and by value is an ICE (StmtTyping rejects it). Every emitter spells parameters through here.

`return_spelling(f)` : a function's C++ return type; every `_ret` goes through it. A panicking function's is its `panic_result` ([Panic.md](Panic.md#codegen)). Place operators (`[]` or `[]=` declared `-> *T` / `-> *const T`; `is_place_operator`, mirroring `OperatorFacts::is_place`) are spelled `T&` / `const T&`, so an imported `T&` and a Kairo place share one ABI; the same operators returning another type are value operators, spelled as declared. `->` stays a pointer. OperatorLowering rewrites the body's `return` (`return &x` to `return x`, `return p` to `return *p`), and EmitIR's `_return` checks the value against the pointee.

`template_params(d)` / `template_head(d)` : `d`'s C++ template parameters as one list: an extension member's extension's (`decl_extension_of`), then its own. A non-member function takes one list, so `extend <T> Vec<T> { fn <U> m }` is `template <class T, class U>`. `template_head` also renders interface-bound concepts ([Witnesses.md](Witnesses.md#the-c-shape)).

`subst_for(g, inst)` : the instance argument a generic parameter stands for, found by the `GenericParamDecl`'s identity in the primary's `template_params` (so an extension's T, a member's own U and a default thunk's borrowed list resolve alike), or null. `_gparam` and EmitIR's `_needs_cast` use it.

`ext_receiver(f, x, inst)` : an extension member's unnamed receiver parameter: `[const ]X*`, or `[const ]X&` for an operator.

`ext_scope_name(x)` : `__kairo_ext_<X>` (`LowerTargets::ext_scope_prefix`): the target's leaf when it is declared in the scope's own namespace, nested owners joined with `__`; otherwise its full path joined with `__` (`__kairo_ext_a__Point`); an imported C++ target's from its spelling; a generic record's primary; a builtin's Kairo spelling. An extension member's `owner_types` is that one name, so `qual_name` is `::N::__kairo_ext_X::m`; `scope_ns(x)` is N.

`ext_op(sym)` : (`LowerTargets`) an extension operator's static-member name, `__kairo_op_<mnemonic>` (`plus`, `eq`, `cmp`, `plus_eq`, `preinc`, `postdec`, ...), which `operator_name` gives an extension member. `ext_forwarder_name(f)` is the `operator<sym>` its forwarder takes, empty for the LowerTargets-named ones (`in`, `^^`, ...). A symbol with no row is an ICE.

`value(e)` : a computed value ([Computed values](#computed-values)).

A `const f: fn(T) -> U` parameter of raw function-pointer type is spelled `const U (*f)(T)`, a pointer to a function returning const U, rather than `U (*const f)(T)`. Top-level const on a by-value parameter is not part of the signature, so the ABI is unaffected, but the definition loses the const.

### Inferred const references

A by-value parameter whose function never mutates it is spelled as if written `const`: `fn f(s: string)` is `f(const ::builtin::string::string & s)`, and a call binds the caller's string instead of deep-copying it. The decision is `ParamDecl::inferred_const`; which parameters qualify is ParamPassInference's rule ([Lowering.md](Lowering.md#passes)). A const function (`[[gnu::const]]`, written or inferred) never gets it: the reference would be memory the attribute says is not read.

Function attributes come from one place, `CXXSpell::fn_attrs`, for the declaration and the definition alike: `@hot_path`, `@no_inline`, `@cold_path`, the calling convention, and `[[gnu::const]]` for `fn f() const` / `[[gnu::pure]]` for `@pure`, or for `FunctionDecl::inferred_purity` 1 / 2 under `-finfer-purity` (the default) ([Lowering.md](Lowering.md#purityinference)); `const` implies the weaker `pure`, so only one is spelled.

Declarations and definitions agree because the decision is a function of the function's own declaration and body only, made after the last lowering of the TU that defines it and stamped on every link of the redeclaration chain, and every spelling of a parameter (EmitIR's definition, InterfaceEmitter's preamble and header, include streams, explicit instantiations) goes through `param_type` / `param_decl`. Taking the function's address elsewhere does not change it: a `fn` value of a function with a by-value `const T&` parameter, inferred or written, is an adapter, `static_cast<W>(::__kairo_fn<R(A)>(+[](A a) noexcept -> R { return f(a); }))` (`EmitIR::_fn_ref_adapter`), so `R(const A&)` never has to convert to `__kairo_fn<R(A)>`.

## InterfaceEmitter

`Compiler/Codegen/Emit/InterfaceEmitter.k` walks plan entries by tier and writes declarations, record definitions and explicit instantiations.

### Preamble helpers

Every Preamble and Header opens with:

    template <class T, decltype(sizeof(0)) N> using __kairo_array = T[N];
    template <class T> auto* __kairo_tmp(T&& t) { return __builtin_addressof(t); }
    template <unsigned int I> struct __kairo_vt { explicit __kairo_vt() = default; };
    template <class T, class... A> inline void __kairo_construct_at(T* p, A&&... a) { new (p) T(static_cast<A&&>(a)...); }
    template <class T> inline void __kairo_destroy_at(T* p) noexcept { p->~T(); }
    template <class B, class T> inline void __kairo_fmt_put(B& b, T&& v, const unsigned char* n, size_t nl, unsigned long long s) { ... }

(`LowerTargets::array_alias`, `tmp_addr`, `adt_variant_tag`, `construct_at`, `destroy_at`, `fmt_dyn`.)

- `__kairo_array` names an array prvalue type and is never instantiated as a template of its own.
- `__kairo_tmp` is the address of a prvalue's materialized temporary, valid to the end of the full-expression: ExtensionLowering's `materialize` of `&` on a prvalue receiver, spelled `::__kairo_tmp(e)`. The preamble is the one place it is defined.
- `__kairo_vt<I>` is the tag argument that selects an ADT's variant-I constructor.
- `__kairo_fmt_put` is the put of a deferred f-string hole (`CallExpr::fmt_dyn`), specified in [FormatStrings.md](FormatStrings.md#lowering). Its builtin rows are spelled from `builtin_info`.

A header wraps these in `#ifndef __KAIRO_LOWER_HELPERS`, since one C++ TU may include several Kairo headers and `__kairo_tmp` is a definition. An include stream is not guarded; `InterfaceEmitter::have_helpers` leaves them out instead.

Further helpers are written only when the plan needs them:

| Helper | Written when | Header guard / include dedupe |
|---|---|---|
| `::__kairo_fn` (`LowerTargets::fn_value`) | the plan admits a Kairo `fn` type anywhere (`EmitPlan::needs_fn_value`) | `__KAIRO_FN_HELPERS` / `have_fn_value` |
| `__kairo_niche<T>` trait | an ADT is defined (`_niche_helpers`) | `__KAIRO_NICHE_HELPERS` |
| `__kairo_pu` (pack union) | a pack-expanded ADT variant is defined | `__KAIRO_PACK_UNION` |
| `__kairo_lref`, `__kairo_slot<T>` | a split constructor or an `eval for` return slot (`needs_ef_slot`) | `__KAIRO_CTOR_SLOT_HELPERS` |
| panic helpers and the C++ view of panic results | the Panic lang item is defined ([Panic.md](Panic.md#codegen)) | `__KAIRO_PANIC_HELPERS`, `__KAIRO_PANIC_API` |
| `__kairo_nopanic` tag | a function under the internal regime (`EmitPlan::needs_nopanic`), or Panic is defined | |
| `__kairo_estr`, big string arrays | a body, eval initializer or value argument spells a compile-time string | per name |

### Namespace wrapping

A decl lives in its TU's module path, `namespace a::b`, from `module_base` (`CXXSpell::ns_segments`). Every input has one: a `.k` on the command line is a module like any import, and `lib/y.k` from the cwd is `lib::y` ([Imports.md](Imports.md#path-resolution)). Each segment, being a file or directory name, is sanitized to an identifier (`CXXSpell::cxx_segment`): a leading `_` before a digit, a trailing `_` after a C++ keyword (`operator.k` is `operator_`).

Only a pathless TU (`CXXSpell::is_entry_tu`: a file outside every search dir and every library) lives in `namespace <file stem>` (`CXXSpell::entry_stem`, sanitized the same way). Only there does a `priv` or `internal` decl go one level deeper, into an unnamed namespace nested inside it (`CXXSpell::is_anon`), and never a function or a record: records befriend them ([Records](#records)) and a friend declaration cannot reach into an unnamed namespace. A module's priv decls keep external linkage. A file-scope `main` stays at global scope in every TU.

Qualified names do not change: `::stem::x` reaches into the unnamed namespace through C++'s implicit using-directive, so `qual_name` knows nothing of it. Reopening a namespace is free in C++, so each decl gets its own wrapper; InterfaceEmitter merges consecutive same-namespace tier-0 entries, and EmitIR does not merge.

#### Top-level namespace collisions

The FIRST segment of a module's namespace sits at C++ global scope, beside whatever the TU's headers declare there and the program's `int main`. `namespace main {` next to `int main()`, or `namespace malloc {` next to `void *malloc(size_t)`, is clang's "redefinition of 'X' as different kind of symbol". Such a segment is renamed by one fixed rule, the same shape as the keyword rule above:

- append `_`: `main` -> `main_`, `malloc` -> `malloc_`, `main/x.k` -> `main_::x` (only the first segment moves; inner segments are not at global scope);
- while the result is still taken, append another: `abort` -> `abort__` when a header also declares `::abort_`.

A name is taken when it is an entry-point name (`main`, `wmain`, `WinMain`, `wWinMain`, `DllMain`, `_start`: fixed, the same on every target), when some header set of the build declares `::name` as anything but a namespace (clang lookup at the translation-unit scope, through `extern "C"`; `HeaderSet::declares_global`), or when it is another module's own top segment or another segment's rename. A header NAMESPACE of that name is not a collision: it is reopened (`std`, `kairo`). The roots of the toolchain's prebuilt objects (`builtin`, `std`, `kairo`) are never renamed. The keyword rule runs first (`class.k` is `class_`, and becomes `class__` only if `::class_` is taken).

The answer is decided once per build, on the driver thread at the header join (`FrontendAction::_sema` -> `CXXSpell::decide_tops`), over the sorted top segments of the graph, and recorded process-wide (`CxxNsTops`); `_ns_from` reads it for every spelling, so every TU, header, kcc include and TypeExport stand-in of the build agrees. A segment decided once is never re-decided by a later input. Without a decision (a tool's bare parse) only the entry-point rule applies, which is what the build decides for a name no header claims.

Consequences: the C++ name depends on the build's header sets, so `printf.k` keeps `printf` unless some imported header declares `::printf`; a module compiled in a differently-shaped graph can get a different name (its importers and it must share the build, as they already do for every other decision). `name__` is a [lex.name]/3 reserved spelling; the rule keeps it anyway, since only a header-declared `name_` forces it. Kairo source and Kairo diagnostics keep the Kairo name (`main::x`); `--print-emit-plan` prints it too (`CXXSpell::kairo_top`). Linker messages (L002E) print the C++ symbol, so they show `malloc_::helper()`. Macros never reach the emitted code (it is token-emitted past the preprocessor), so a macro named like a module (`EOF.k`, `stdin.k`) needs no rename.

### Records

A record is `class` / `struct` with every member at its Kairo access (`priv` is `private:`, `prot` is `protected:`) and every base `public` whatever its edge says. A private base would refuse the upcast Kairo allows through a `derives priv` edge from another file and make the checked downcast null.

Public whatever Kairo says (`CXXSpell::cxx_vis`):

- a transfer constructor and the destructor, because prelude templates and compiler-made aggregates in other namespaces copy and destroy user values, and their probes would silently turn false;
- the instance fields of a struct, a union, or a class with no constructor: a C++ aggregate, built by designated initializers (a struct with a private field is also returned through memory on MSVC, unlike C).

Compiler-made members keep their own access (a `where` group's candidates are `private:`).

Members, in order:

1. `using Base::m;` for every method name the class shares with a base (`_base_usings`): Kairo merges the base's overloads and C++ would hide them. At the narrowest access of those overloads, and none when one is private to another file's base. For a `derives priv B` / `derives prot B` edge, a `private:` / `protected:` `using B::m;` per name inherited through it and not declared by the class (`_edge_narrowing`): the base stays public so the upcast and checked downcast work, and the names are narrowed through the class.
2. Fields. A default is a C++ default member initializer: a constant FieldInitLowering folded as it is (`signed int n = 5;`), anything else a call of the member function it made of the initializer (`T d = __kairo_init_d();`), so the expression is a body like any other. An array field's list literal is one such call per element (`E a[2] = {__kairo_init0_a(), __kairo_init1_a()};`; no function returns an array); an array of arrays one call per leaf, braced per dimension (`int g[2][2] = {{t0(), t1()}, {t2(), t3()}};`, `_elems_braced`), flat when a length is a value parameter, which brace elision reads row-major. A static array field's out-of-line definition is the same list over its static thunks.
3. Zero defaults. A field with no initializer whose type has a default and no constructor of its own (a number, a pointer, a plain enum, a type parameter, a union, an array of those) gets `{}` (`_zero_by_default`), so every constructor leaves it 0 as [variables](README.md#language-reference) requires, rather than C++'s indeterminate default-initialization. A const field, a record, an ADT, an imported C++ type and an ADT payload struct's fields get none. A union's first member gets `{}` instead (C++ allows one initializer there, and it keeps the union default-constructible when a member struct's zeroed fields made that member's default constructor non-trivial).
4. Method declarations, never bodies ([invariant 25](Pipeline.md#invariants)).
5. Derived comparisons, then the derived `op =` ([Derived comparisons and assignment](#derived-comparisons-and-assignment)).
6. Split-constructor members ([Split constructors](#split-constructors)).
7. One `friend struct ::N::__kairo_ext_X;` per same-file scope, in source order, so the text does not depend on which scope a TU touched first.
8. For a record with a non-public member, the rest of its file (`EmitPlan::file_friends` / `FileFriends`, read off the file's declarations only, so the record is one text in its own TU, an importer, a header and an include): every other outermost record and hoisted local record (`friend ::ns::X;`; a generic one `template <...> friend class ::ns::G;` with parameters spelled `__kairo_ft<i>`, `CXXSpell::rename_tparams`, since its own could redeclare the record's); every other-target scope in its namespace (`friend struct __kairo_ext_Y;`); every free function of the file (unqualified in the record's namespace; qualified, after a declaration of its own ahead of tier 1 (`friend_early`), for one in another namespace or one whose first declaration needs `extern "C"` or `[[noreturn]]`); the witness primaries of what the file declares it implements; the `__kairo_ginit_<v>` thunk of each global whose initializer reaches a private member (a variable cannot be a friend, so EmitIR calls the thunk instead); and `main`, declared at global scope first (`friend int ::main()`). The plan admits what those lines name (`_admit_friends`). A function whose signature names a nested type is left out.

Enums: C-like as `enum class`, an ADT as its layout record ([ADT enums](#adt-enums)). Functions: free only.

Extension scopes are written `struct __kairo_ext_X {`, one `static` declaration per member (merged template head, receiver first via `ext_receiver`, the postfix `int` dummy where it applies), `};`, all public and never in the unnamed namespace. Then, per operator member C++ can spell, an inline forwarder `template_head inline RET operator<sym>(X& __kairo_a0, ...) { return ::N::__kairo_ext_X::__kairo_op_<m>(__kairo_a0, ...); }`, each operand forwarded as `static_cast<decltype(a)&&>(a)` and the postfix dummy as is.

A static field is declared in the class (`static [thread_local] T s;`, no initializer, since C++ takes one in-class only on a const static) and defined after the outermost record's `};`, inside its namespace wrapper, as an inline variable (`_static_defs`): `[template <...>] inline [constinit] [thread_local] T R::s = <init>;`. Inline because every TU holding the class can odr-use the static. `constinit` exactly when FieldInitLowering folded the initializer to a literal (a constant expression for every instantiation); a thunk (`= __kairo_init_s()`, by leaf, since a static member's initializer is in its class's scope) is dynamic initialization. No initializer is `{}`. A generic record's static with a thunk initializer is always dynamically initialized; deciding constness per instantiation is an instance fact not yet computed.

### Derived comparisons and assignment

A record with a member `op <=>` gets the comparisons Kairo derives from it written into the class (`_derived_cmps`), after the methods and before the derived `op =`: `bool operator<(<other>) [const] { return static_cast<signed char>(this->operator<=>(static_cast<decltype(o)&&>(o)))
< 0; }` for each of `<` `<=` `>` `>=` `==` `!=`, with the operand, cv and
access of the `<=>`. C++20 cannot find them: its rewrite `(a <=> b) < 0` does not compile against `Ordering`, a scoped enum, and it never derives `==` from a user `<=>`. A comparison the record declares is skipped, as is `!=` beside a declared `==`. A generic `<=>`, an extension `<=>` and an ADT's derive nothing here.

A record's `op =` is derived from its transfer constructor, never written ([classes](README.md#language-reference)). ClassLifecycle decides how (`assign_from`, `assign_form`), and `_derived_assign` writes it after the methods, public, its operand spelled as the constructor's own `other`:

| Transfer constructor | `op =` |
|---|---|
| none written | nothing: C++'s implicit assignment is the derived one, and declaring one would change which constructors C++ generates |
| defaulted | `= default` |
| deleted; a polymorphic record with a body; a part that cannot be assigned | `= delete`; assigning one is SC071E |
| a body | `X& operator=(<other> o) { if (this != &o) { this->X::~X(); ::new (static_cast<void*>(this)) X(o); } return *this; }`, `static_cast<X&&>(o)` from a `@move` one |

Self-assignment does nothing, the destructor is qualified so it is never virtual, and the old value is destroyed before the new one is built since emitted C++ has no exceptions. A generic record whose dependent parts leave the form open declares it twice: the body under `requires (<every dependent field destructible, every dependent base destructible and not polymorphic>)` and `= delete` under the negation, the traits over the parts because the record is incomplete inside its own body.

Both are written in the class (the exception to invariant 12 for synthesized members). The `::new` is the global placement form, so a TU or header that writes one asks for `<new>` before any class: `TextSink` as a line, `TokenSink` through KairoInject, which appends it to the predefines and adds it to `PreprocessorOptions::Includes` (clang reads one or the other, depending on whether the TU loads a PCH). `<new>` is included rather than declared because libc++ declares the operator with an `abi_tag` and, from C++26, `constexpr`, and clang rejects a differing redeclaration in either order.

### C++ allocation operators

In C++-facing text only (plan mode `Header` or `Include`, never `Preamble`), every class, struct and ADT enum (generic or not; not a union, an ADT payload struct or an `ffi` tag declaration) carries class-scope allocation functions, so a C++ `new X` / `delete p` / `new X[n]` / `delete[] p` takes its storage from Kairo's allocator, and a C++ global `operator new` override never reaches a Kairo object (`InterfaceEmitter::_cxx_alloc_ops`). The module's own object has none: no Kairo code writes a C++ new-expression on a record (`create` / `destroy` call the allocator themselves), so the class text in the object and in the header differ by these members only.

- The allocator is the program's global one, the `kairo_global_alloc` / `kairo_global_free` symbols (`Lib/rt/global_alloc.h`) that Kairo's `Global` calls when a program sets one and the runtime defines weakly as `System` when none does. Not the scope stack: a C++ `delete` inside an open `AllocatorScope` still returns a global block to the global heap. Always that pair: a class cannot declare its own allocator (SC149E).
- Forms: `operator new` and `operator new[]`, each plain, `(size, std::align_val_t)`, `(size, const std::nothrow_t&)`, both, and placement `(size, void*)` (a class-scope `operator new` hides the global ones, and `__kairo_construct_at` and C++ users still write `new (p) X(...)`); `operator delete` and `operator delete[]`, each `(void*, size)` and `(void*, size, std::align_val_t)`. Only the sized delete is declared, so C++ always passes the size (and gives every `new X[n]` a cookie), which `System`'s small-block free needs. `std::align_val_t` and `std::nothrow_t` are declared opaque in the helper block (`__KAIRO_CXX_ALLOC` in a header), so a header needs no `<new>`.
- Sizes and alignment: a single object asks for `(sizeof X, alignof X)`, or the `align_val_t` C++ passes for an over-aligned one, which is what `create<X>` asks for and `destroy` frees with, so a C++ `delete` of a `create`d object and a `destroy` of a C++-`new`ed one each free a block as it was made (no scope open). Arrays never cross to Kairo and ask for at least `2 * sizeof(void*)`, so the cookie is aligned. A zero size asks for 1 byte (the allocator contract excludes 0).
- Failure: the throwing forms are not `noexcept` (so the new-expression has no null test), never return null and never throw: `__kairo_cxx_got` crashes with `kairo: out of memory`, exit 134, as the default OOM hook does. It does not run a hook `set_oom_handler` installed, which is Kairo state the header does not reach. The `nothrow_t` forms return null, as `try_create` does.
- Each is `__attribute__((exclude_from_explicit_instantiation))`: a generic record's header declares its instances `extern template`, and the module's explicit instantiation (Preamble text) has no operators, so the C++ TU must instantiate them itself. An allocation function cannot be a member template, which is how `_adt_factories` solve the same problem.
- Limits: a polymorphic record's deleting destructor is emitted beside its vtable, in the module's own object, where the record has no operators, so a C++ `delete` through a base pointer with a virtual destructor frees with the global `::operator delete`. A C++ class deriving from two Kairo records finds two `operator new` and must declare its own. A C++ class deriving from a Kairo record with a stricter alignment that is still not over-aligned gets the base's `alignof` (the allocator usually gives at least 16 anyway).

### ADT enums

An ADT enum is written as the record EnumLayoutLowering built (`EnumDecl::adt_layout`; [Lowering.md](Lowering.md#passes)), under the enum's name and template head, in the record's order:

1. the tag enum (bare enumerators; a tag is a variant's position; its word is the enum's `derives` type, else u8 or u16);
2. each payload struct, with its own placement `operator new` as its first member, so `new (&m) P(...)` finds it whether or not the TU includes `<new>` (a payload never uses `::new`);
3. the tag (public: an ADT's `==` is a tag compare in user code);
4. the anonymous union;
5. a generic ADT's five `static constexpr bool` flags (type traits over the payload structs);
6. the role functions rendered from `adt_role` / `adt_form`: per variant `E(::__kairo_vt<I>, F0 f0, ...)` (the field constructor, every field trivial), `template <class F> E(::__kairo_vt<I>, F&& f)` (the lambda one), or both, constrained, for a generic ADT, and `E(::__kairo_vt<I>)` for a dataless one; the special members; the private `__kairo_destroy` / `__kairo_construct_from`; `__kairo_which()` on a generic ADT;
7. the niche trait members: `__kairo_niche_count` (tag values past its variants), a `(::__kairo_np, i)` constructor storing tag `N + i`, and `__kairo_niche_test`.

In C++-facing text only (plan mode `Header` or `Include`, never `Preamble`), the public C++ factories go between 6 and 7, and into `_niche_record` (the partial specialization included): `template <class __kairo_mk = void> static E V(F0 f0, ...)` per variant, named after it, built through the field constructor (`Fields`) or the lambda one (`Lambda` / `Both`). [Interop.md](Interop.md#constructing-adt-variants-from-c) has the naming rule. The member template is load-bearing, not decoration: a generic instance the header declares `extern template` would otherwise only reference a plain inline factory (undefined at link, -O0), since the module's explicit instantiation was compiled without it; and a non-generic lambda-form factory spells its payload type `__type_pack_element<0, P, __kairo_mk>` so that a payload that cannot move is an error at a call, not in every TU that includes the header. `InterfaceEmitter::_adt_factories`.

Every member with a body is `noexcept` unless `-funwind`, as is the lambda a construction site passes, so a construction is a call, not an invoke. Their bodies are written in the class: they have no Kairo body to put out of line, and the text is a pure function of the decl. A generic ADT declares all three forms of each special member (defaulted, with a body, deleted), constrained on the flags so one is selected; a non-generic one declares the one form its lifecycle facts select. EmitPlan reads an ADT's members, nested types, layout edges and by-value parameters off the record (`EmitPlan::adt_record`, through `layout_decl`), seeing through the anonymous union and payload structs as through ordinary fields. Special members carry C++ constraints rendered from `adt_role` / `adt_form`, as a generic record's derived assignment does from its `assign_form`; they are not Kairo constraints and have no `requires_clause`.

A prefix-tagged ADT writes no tag beside the union: each payload struct's first field is the tag, the union's first member `__kairo_t` (`__kairo_t_t`) holds only it, a variant constructor initializes the payload as `{Tag::V, f0, ...}` or `__kairo_t{Tag::V}`, and the destroy / construct-from helpers are not written. A niche-filled non-generic ADT is written by `_niche_record`: the payload struct as its one member, each dataless variant a `pattern(j)` of the field, defaulted special members, `which()`, its own niche answer past the patterns it uses, then `static_assert(sizeof == the payload struct's && standard-layout)`. A niche-shaped generic ADT gets that record again as a partial specialization constrained on `__kairo_niche<F>::count >= D && trivially copyable && trivially destructible` beside the tagged primary. Which shape an ADT takes is [ADT layout](#adt-layout).

A pack-expanded variant is a member template payload `template <class __kairo_pe> struct __kairo_V_t` (the enum's pack spelled `__kairo_pe` inside, `CXXSpell::pack_alias`), a union member `::__kairo_pu<__kairo_V_t<E>...>`, flags folded over the pack, a `template
<unsigned K, class F>` constructor storing tag `p + K`, and destroy /
construct-from helpers whose `default:` hands a tag past `p` to the union's own, by runtime index. `__kairo_pu` is a head/rest union with `get<K>`, whose special members are trivial exactly when its members' are.

### ADT layout

EnumLayoutLowering (`Compiler/Sema/Lower/EnumLayoutLowering.k`) decides an ADT's layout and builds its record; `EnumLayoutQuery` in the same file is the only surface any pass uses to read or test a value (`tag_read`, `tag_value`, `variant_test`, `payload_ref`, `field_ref`, `same_variant`, `is_exhaustive_dense`, `niche_of`), since the layout is not uniform and a hand-written `x.__kairo_tag` would be right for one shape only. Every answer is for the value's own type: a generic ADT's instances need not share a shape (`EnumLayoutQuery::shape_at`, `AdtShape`).

| Shape | Layout | A variant test |
|---|---|---|
| `Tagged` | a tag field and a payload union | reads the tag |
| `Niche` | no tag and no union: the one payload struct is the record's only member | compares the payload field against the dataless variant's pattern |
| `Opaque` | a generic ADT whose instance C++ lays out (a dependent type, or facts Sema cannot settle) | asks `__kairo_which()`, which both layouts answer |

The tag is the enum's `derives` type, else u8 (u16 past 256 variants). Its values are the variant positions, dense, in declaration order, so the match switch and its jump table index by them.

The tag sits in the common prefix (`EnumDecl::adt_tag_member` / `adt_prefix_tag`) for a non-generic ADT that is not niche-filled and whose payload fields are all builtins, pointers or plain enums (`_prefix_ok`): each payload struct starts with `__kairo_Tag __kairo_tag`, and the tag is read as `x.__kairo_t.__kairo_tag`. Every payload struct is standard-layout, so the common-initial-sequence rule defines that read whichever payload is live, and payload padding absorbs the tag (`{u8, u16} | {u8}` is 4 bytes, not 6). Its fields are trivial, so its special members are the defaulted ones. A generic ADT keeps the external tag, since whether its payloads are standard-layout is per instance.

An ADT is niche-shaped (`EnumDecl::adt_niche_shape`) when it has exactly one payload variant, whose payload is one field, beside at least one dataless variant. It is niche-filled (`niche_verdict`) when that field has at least as many invalid bit patterns as there are dataless variants and is trivially copied and destroyed, so every special member stays defaulted. Dataless variant j, in declaration order, is the field's pattern j: for `Opt<*Foo>` None is `__kairo_Some.v == nullptr`, and `sizeof` is a pointer's. `niche_of(T)` counts the patterns, as the C++ trait does:

| T | Niche count |
|---|---|
| a pointer, a raw or unprototyped function pointer | 1 (null) |
| a closed plain enum with values `0..N-1` at namespace scope | the rest of its word (`enum_niche_count`) |
| a tagged ADT | the tag values past its variants (`adt_tag_niche_count`) |
| a niche-filled ADT, a `T?` | its field's count less the patterns its dataless variants use |
| a dependent type | unknown |
| anything else (a `fn` value, `bool`, a record) | 0 |

A plain enum qualifies only when closed (not `@open`): `as` into a closed enum is checked (CastTyping), while `3 as Color` is a value an `@open` enum may hold, which a niche at 3 would read back as null. An imported enum never qualifies (clang owns it), nor does `Byte`. `Compiler/AST/EnumNiche.k` holds these rules for both Sema and codegen, so the count Sema assumes is the count the trait reports. `bool` would need a storage override (a C++ `bool` cannot hold 2), and a record's first niche-bearing field (`niche_of_record`) is computed but read by no layout, since C++ builds a record holding a pattern only by aggregate initialization.

C++ side: the preamble trait `__kairo_niche<T>` (`_niche_helpers`) answers `count`, `pattern(i)` and `test(v, i)`: 0 by default, one null for any `T*`, and an ADT record's own members (`__kairo_niche_count`, the `(::__kairo_np, i)` constructor, `__kairo_niche_test`). A qualifying plain enum is followed by its explicit specialization (`_enum_niche_trait`).

A non-generic ADT's shape is decided in EnumLayoutLowering (`EnumDecl::adt_niche`). A generic one cannot be, because Sema does not see every instance, so InterfaceEmitter writes the niche-filled record as a constrained partial specialization (above) and C++ picks per instance, the same pick in every TU and C++ host. `EnumLayoutQuery::sweep` records each instance's predicted shape and size (`InstanceEntry::adt_shape` / `adt_size`), and each explicit instantiation is followed by `static_assert`s of them, so a wrong prediction is a compile error.

### Panic and Nullable records

The `Panic` lang item is an ADT with its layout knobs set. Its layout, the panic helpers InterfaceEmitter writes with it (`__kairo_tid`, `__kairo_fwd`, `__kairo_raw`, `__kairo_pcall`, `__kairo_pset`), panic sites, effect-widening `fn` values, dependent panic sets in generic templates and the C++ view of a panic result (`_panic_api`) are specified in [Panic.md](Panic.md#codegen).

Nullable (`Value { v: T }, Null`, in `Lib/builtin/module.k`) carries eight more roles (`AdtRole::NullDefault`, `InterfaceEmitter::_nullable_member`): `Nullable()` and `Nullable(::builtin::null_t)` (null); `Nullable(const T&) requires __kairo_copyable` and `Nullable(T&&) requires __kairo_movable` (present, payload built in place; constrained because an explicit instantiation defines every member whose constraints hold); `is_null() const`; the unchecked `T& __value()` / `const T& __value() const`; and `operator==` when `const T&` compares. None is `explicit`: every implicit `T -> T?` / `null -> T?` is C++ copy-initialization through one of them. `null_t` (`StructDecl::is_null_type`) is followed by `inline constexpr null_t null{};`, which a C++ host spells `::builtin::null`.

### Split constructors

A constructor CtorInitCheck split (`FunctionDecl::ci_split`) declares three private members after the methods, from the same facts in every TU:

    struct __kairo_ciK;                       // defined by EmitIR beside the bodies
    static auto __kairo_ctor_preK(__kairo_ciK&& __kairo_s, __kairo_lref<P> p...) -> __kairo_ciK&;
    R(__kairo_ciK& __kairo_s, __kairo_lref<P> p...);

The slot record is only declared here because the carried locals' types are complete only beside the bodies. The return type trails because a generic owner needs no `typename` out of line that way.

A plan holding such a record writes `template <class T> using __kairo_lref = T&;` and `__kairo_slot<T>`: a T in union storage built on its first assignment through its box's own placement `operator new` (no `<new>`), destroyed only if built, never copied. Its members are `init` (first assignment), `put` (possibly a later one; the only use of T's `op =`), `get`, `take` and `set`. Every member is `constexpr` with an `if consteval` arm for an eval constructor's slots, which live inside one constant evaluation: C++23 allows no placement new there, so that arm keeps the value in a transient heap box (`__p = new __h{...}`) that the destructor deletes before the evaluation ends; `__v()` reads whichever arm holds it.

`__kairo_slot<T[N]>` is an array field's: `init` takes the array by `&&` (a list literal's prvalue, elements moved) or `const&` (copied), building elements from an index pack (`__make_integer_seq`, `LowerTargets::make_index_seq`), and there is no `put` (an array is written once). `init_at(k, T)` builds element k alone, in place in its own box, for an array built element by element; the slot is `set` once all N are. CtorInitCheck guarantees every path builds every element, and S_pre cannot panic or return, so a partly built array is never destroyed.

The same slot is the return slot of an `eval for` / pack `for` ([Eval.md](Eval.md#codegen)): in a function returning a value, the outermost expansion declares `::__kairo_slot<R> __kairo_efv;` (R the Panic result in a panicking function), a copy's `return v` is `__kairo_efv.init(v)` and stops the folds, and the code after the expansion is `return __kairo_efv.take();`. A plain `R __kairo_efv{}` would ask R for a default constructor, which a Panic result lacks. EmitPlan sets `needs_ef_slot` for such a function.

The bodies are EmitIR's ([Split constructor bodies](#split-constructor-bodies)).

### Packs

A one-type pack is spelled as its `Slice<E>` (`ParamDecl::pack_type`). A type pack is `T&&... xs` (`const T... xs` for a `const` pack; a mode on a pack is refused by [PackChecking](SemanticChecks.md#check-passes)), under an instance its elements as `E&&`, and a canonical pack parameter in an argument list as `E...`. A forwarding pack's expansion is `static_cast<T&&>(xs)...`, and an lvalue argument a call puts into one is `static_cast<E>(x)`, the copy a by-value parameter makes (`static_cast<E&&>` for `@move`), so a temporary or moved value crosses every layer uncopied. An expansion the pack is read again after (MoveCheck marks `PackExpansionExpr::reread`) is plain `xs...`, since forwarding would hand the later read moved-from elements. `for x in xs` binds each element as an `auto&` lvalue. A bounded pack's head is a fold, and a witness call on an element names it by its own type, `I_witness<__remove_cvref(decltype(x))>`: clang refuses the bare pack `T` in a declaration's initializer, where a statement-expression lowering puts the call.

### Headers

Header mode adds `#pragma once`, the module's own ffi headers (`#include "h"` as spelled, `ffi "c"` ones inside `extern "C"`), and `#include`s of the headers of its Complete dependencies and of every foreign function it declares (only an inline or template body names one).

Headers carry bodies: after the declarations, EmitCXXHeader runs EmitIR over the plan's `visible_bodies()`, which in Header mode is the module's own inline and template bodies. C++ consumers of a Kairo library need them for the reason Kairo importers do: those bodies are part of the interface. The header plan walks them at body strengths, so the priv helpers and types they name are declared too. A hidden function or global that another file's header body names (e.g. `prot inline fn scope_push` in alloc_raw.k, called from `AllocatorScope`'s template bodies in base/alloc.hh) is declared by its HOME header, which the naming header already `#include`s: before any header is written, `--emit-headers` runs every Header plan and records each foreign function or global one admitted that its home's root rule leaves out (`EmitPlan::note_borrowed`, repeated until nothing is added), and each home plan takes those as roots, so they get one declaration (and an inline body) under the home's `#pragma once`, with the linkage the module's own object gives them. Class definitions stay byte-identical because bodies are emitted outside the class. `--emit-headers` therefore runs EmitIR, needs a lowered tree, and writes nothing after an error.

### Explicit instantiations

Tier 3 writes `extern template class X<A>;` for every registry instance this TU does not home and `template class X<A>;` in the home, after every body ([Templates](#templates)). Explicit instantiations parenthesize the declarator-id, `template R (::ns::f<A>)(...)`: after a class-template return type, `Cell<double> ::ns::` otherwise lexes as one nested-name-specifier. An out-of-line definition is safe while its declarator-id does not start with `::`.

Two Kairo instances can be one C++ entity: where the target makes `size_t` the fixed-width integer (`target.usize_is_fixed`, Linux), `Box<usize>` and `Box<u64>` are one C++ class. Tier 3 keys every instance by its arguments spelled with `usize` / `isize` folded (`CXXSpell::fold_sizes` / `size_fold`) and lists one line per key, the home one when either is; otherwise clang reports a duplicate explicit instantiation. A generic record's interface bounds are pinned by `static_assert` after the home's instantiation ([Witnesses.md](Witnesses.md#the-c-shape)).

### Refusals

Each of these is an ICE naming its owner: a named union, an interface (interfaces are not emitted as types), the initializer of an eval field, and an array-typed field initializer FieldInitLowering did not take element by element (FeatureGateCheck rejects both first with SC116E: no eval constant is emitted yet, and a C++ function cannot return an array).

## EmitIR

`Compiler/Codegen/Emit/EmitIR.k`. Declarations are the plan's; EmitIR writes bodies. It knows the core subset:

    names, chains (`.`/`->` from the base's canonical; `::` collapses to
    the last scope-resolved decl's qualified name), calls, literals,
    primitive operators, casts, `if`/`while`/`for(;;)`/C-style `for`,
    `return`/`break`/`continue` (unlabeled), locals, blocks, named and
    anonymous initializers (designated, declaration order, aggregates
    only), `sizeof`/`alignof`, `unsafe` (transparent),
    `assert` / `static_assert`, `yield` (`co_yield`), `InitListExpr`,
    `StmtExpr`, closures.

A runtime `assert` is `if (!(cond)) ::kairo_rt_crash_exit(<"kairo: assertion failed at file:line:col: text">, len, 134);`.

A constructor's leading `Base::Base(self, args)` statements (BaseInitCheck admits them nowhere else) are its mem-initializers, `: Base(args)`, and are skipped in the body; a split constructor's go on its slot constructor, ahead of the fields'. A qualified method call `Base::m(obj, args)` is `(obj).Base::m(args)`, non-virtual as the qualified name means, with a generic owner spelled through the object's instance or base (`Box<int>::get`).

`InitListExpr` is the C++ braced-init-list, array-typed only. Its spelling is chosen by position: bare `{...}` as a `VariableDecl`'s direct initializer and as an element directly inside another array `InitListExpr` (C++ cannot initialize an array element from an array prvalue); the prvalue `::__kairo_array<T, N>{...}` everywhere else, alive to the end of the full-expression. Both are valid C++17, but GCC rejects the decay of a prvalue array and clang does not. Bodies only go through clang, and this is a hard dependency on clang.

`StmtExpr` is the GNU statement expression `({ s0; s1; e; })`, whose value is its last statement. The parser produces it for source `({ ... })` (the last statement must be an expression), and SequenceLowering mints it to write Kairo's left-to-right argument order into the tree. It is a GNU extension clang implements, the same hard clang dependency.

A TU that writes `@set_global_allocator(A)` gets, after everything else, strong `extern "C"` definitions of the `kairo_global_*` symbols the builtin's `Global` calls (`EmitIR::_global_allocator`), each forwarding to `A`'s static functions with the signatures `Lib/rt/global_alloc.h` declares. The runtime's definitions in `Lib/rt/global_alloc.c` are weak and forward to `System`, so the program's wins the link; a second program file setting one is a duplicate symbol at link, after the parse and same-build checks ([Driver.md](Driver.md#driver-phases), [Linking.md](Linking.md#link-jobs)).

### Local declarations

A `fn`, class, struct, union or enum written in a function body (`CXXSpell::is_hoisted_local`: its semantic scope is a function, block or lambda, and it is not implicit) is hoisted: emitted at namespace scope, in the namespace of the function it is written in, as if it were a `priv` declaration there. C++ has no local functions, and a local class can have no member template, static data member or out-of-line member; at namespace scope the plan, InterfaceEmitter and EmitIR handle it as any file-scope declaration (tiers, ADT layout, explicit instantiation of its own generics).

- Name: `__kairo_local_<line>_<col>_<name>` (`LowerTargets::local_decl`), from the position of its own name, so locals of one name in two functions or two sibling blocks coexist and every TU spells it alike. An ADT's layout record takes its enum's.
- Plan: `HoistedLocals` finds every one in the TU's program, and a Preamble roots each as an own decl. A header or include takes one only through a use from an inline or template body it compiles.
- EmitIR: the `DeclStmt` emits nothing; `emit_tu` emits each one's bodies after the program's.
- Soundness: a named function in a body captures nothing (ClosureCaptures rejects a use of an enclosing local, parameter, `self` or static), so no binding is lost. An enclosing generic parameter is out of scope at namespace level, so a local that names one is SC116E (FeatureGateCheck); one generic in its own right is a namespace-scope template. An `extend` in a body is SC116E.
- FinallyLowering's guard record is implicit and stays in the body (`_local_record`): it holds the body's locals by address.

### Integer arithmetic and evaluation order

Kairo integer arithmetic wraps at the node's type and evaluates left to right; C++ promotes, overflows into UB, and leaves operands unsequenced. Neither is left to clang: the forms are spelled inline, and the order is written into the tree. Imported C++ keeps C++ semantics.

| Form | Spelling |
|---|---|
| pure (`_op_form`): `+ - *`, unary `-` / `~`, `& \| ^` narrower than int | cast through `CXXSpell::wrap_carrier` (unsigned, never narrower than `unsigned int`): `SC<T>(SC<U>(a) + SC<U>(b))`. `-L` on a literal and `no_wrap` nodes (IterLowering's index steps) print C++'s operator. |
| shifts (`_shift_form`) | the count, converted to U, taken modulo R, the register width (`CXXSpell::reg_width`: 32 up to 32 bits, 64, 128); the shift done in R bits and truncated: `SC<T>(SC<U>(a) << (SC<U>(n) & SC<U>(R-1)))`. A signed `>>` shifts `SC<R_T>(a)` (`reg_signed`), so a narrow one fills with the sign. `u8 << 9` is 0; `u8 << 33` is `x << 1`. |
| binding (`_div_form`, `_compound_form`, `_incdec_form`) | `/` and `%` bind their operands and crash through `kairo_rt_div_zero` on zero; `MIN / -1 == MIN`, `MIN % -1 == 0`. A compound assignment or `++` / `--` on a non-local place binds it once with `auto&`, the trailing value omitted in statement position. At namespace scope (`_ns_init`) a binding form is a capture-less lambda called on the spot. |
| unchecked-regime operand (`_dep_binary`, `_dep_update`; [BuildSystem.md](BuildSystem.md#internal-generics-regime)) | both bound; a lambda picks with `if constexpr` between the wrap form on `__make_unsigned(T)` and T's own operator, so a record keeps its `++`. The shift computes R from `sizeof(T)` and sign-extends through `__make_signed(U)`. The forms are `WrapForms::{open, int_arm, native}`, which a builtin's operator witness spells too ([Witnesses.md](Witnesses.md#the-primary)). |

The shift mask is the hardware's own on x86, AArch64 and RISC-V; ARM32 shifts by the count's low byte and pays one instruction (two on ARMv6-M). A `no_wrap` shift (count proven in `[0, W)`: a constant or `e & K` / `e % K` count, OperatorTyping; a range loop's binder, IterLowering) drops the mask. A constant count outside `[0, W)` is SC001E in OperatorTyping. `-Wshift-count-unproven` reports each masked shift on ARM32 as SC241W (`_warn_unproven_shift`), for the user's own code only.

Evaluation order is SequenceLowering's ([Lowering.md](Lowering.md#passes)). Before the last effectful operand, every operand that has an effect or reads state it could change is bound in order: a place as `auto&&` (`VariableDecl::place_ref`), a value copied (`auto` where Kairo cannot spell the type, `VariableDecl::auto_copy`). "Effect" is `LowerSynth::pure_read`: a lang item's pure accessor (`PureAccessors` in `Compiler/AST/LangItems.k`: string's `as_ptr` / `length` / `codepoints` / `capacity`, Nullable's `is_null` / `__value`) has none, though it still reads its object. A record prvalue result is ordered too (guaranteed elision out of the statement expression); a reference result (an imported `T&` / `T&&` return) is not, since it may name a bound argument that dies with the block. `x in xs` through a user `op in` is `xs.op_in(x)`, receiver first in C++: the call is `recv_last` and `x` is bound first.

The invariant is checked twice. SequenceCheck runs right after SequenceLowering and reports I003E on any node C++ evaluates in an unspecified order (a binary operator, an assignment, a call's arguments, an initializer written out of declaration order) left with two effectful operands. Exempt are what C++ already orders as Kairo does (`&&`, `||`, shifts, a builtin subscript, a receiver against its arguments, an in-order braced initializer), the compounds EmitIR orders itself, and reference-result calls. After it `SemaContext::sequenced()` is true (the lowering step is past SequenceCheck, [Lowering.md](Lowering.md#pass-order)), and LowerSynth's call minters (`ctor_call`, `member_call`, `free_call`) ICE on minting a call with two effectful operands unless the caller passes `ordered`. Passes after SequenceLowering mint only ordered forms: ListLiteralLowering (braced lists, `Slice(data, len)` / `Vector(slice)` with at most one effectful operand, casts, a `__kairo_tmp` backing `DeclStmt`), StringLowering (three literal arguments), and EmitIR, which mints no nodes and binds in order in its binding forms.

`Tests/Codegen/OperatorSemantics` proves both: constant-evaluated forms, run values, spellings, and instruction parity at -O1 to -O3 on x86_64 and aarch64; `shift_run.k` runs the shift table on six targets at four levels under QEMU, and its `Inputs/shift_run.py` pins each target's mask cost.

### Closures

A closure is a C++ lambda inside the `fn` value its type is. [closures](README.md#language-reference) gives every closure the type `fn(A) -> R` and lets one that captures be stored, passed and returned as that type, so `fn(A) -> R` is `::__kairo_fn<R(A...)>` everywhere: a preamble helper holding nothing, a plain function pointer, or a heap-allocated lambda with its call, copy and destroy operations.

    captures nothing   ::__kairo_fn<R(A)>(+[](A a) -> R { body })
    captures           ::__kairo_fn<R(A)>::own(new auto([caps](A a) mutable -> R { body }))

- Raw functions. A named function, and a closure that captures nothing (`ControlTyping::type_closure` runs FreeVarScan), are typed as the raw `unsafe fn`; imported C/C++ function pointers are raw (TypeImport), as are an `ffi "c"` function's `fn` parameters and result (`TypeResolve::_ffi_c_raw_fns`). A raw closure is the bare `+[](...){...}` pointer. Raw widens to the `fn` value implicitly (`static_cast<::__kairo_fn<...>>(e)`, `_needs_cast`); a `fn` value never narrows to raw (SC001E). A `var` initialized from a function or a captureless closure is the `fn` value (`StmtTyping::_fn_value_decay`). The canonical's size is one pointer when raw, three (`__f`, `__o`, `__t`) otherwise.
- A named function converts to the value by its function-pointer constructor. That constructor and the default one are `constexpr`, so a global `fn` initialized from a function or captureless closure is constant-initialized (only its destructor's atexit registration runs at startup). A `fn` value converts back to `R(*)(A...)` for a C callee or field, trapping on a capturing closure. C++ does both implicitly, so a foreign call needs no arm here.
- `new auto(lambda)` builds the lambda in its heap slot from the prvalue, so each by-copy capture is copied once and destroyed once.
- Copying a `fn` value copies the lambda, each copy with its own by-copy captures. Copying one that holds a move-only capture traps. Moving never copies.
- A capturing lambda is `mutable`: a by-copy capture is the closure's own variable, assignable in the body, persisting between calls.
- The capture list is ClosureCaptures' decision (`ClosureExpr::cap_decls` / `cap_modes` / `cap_via_ptr`), spelled by `_capture_list`. Init-captures keep the Kairo name so the body emits unchanged: inside a `|*x|` closure Sema types `x` as `*T` (`ExprTyper::_capture_view`) and the capture makes C++'s `x` that pointer. A binding an enclosing closure holds by pointer is already that pointer in the inner lambda: Copy, Ptr and Move copy it, ConstPtr converts it (`static_cast<const T*>(x)`). A script's top-level `var` a closure copies ([SemanticChecks.md](SemanticChecks.md#closurecaptures)) is a global, which C++ does not capture: the outermost closure that holds it init-captures it from the global (`x = ::ns::x`, Move: `x = static_cast<T&&>(::ns::x)`), and inside every closure that holds it the name is bare (`_captures_global`).

  | Mode | Capture | Source |
  |---|---|---|
  | Copy | `x` | |
  | Move | `x = static_cast<T&&>(x)` | a MOVE value |
  | Ptr | `x = &x` | `\|*x\|`, `\|*\|` |
  | ConstPtr | `x = static_cast<const T*>(&x)` | `\|const *x\|` |
  | Self | `this` (`self` in an extension member) | |

- `return` in the body returns from the lambda (`_return` reads the innermost `_closure`'s return type); `_cur_fn` stays the enclosing function, which decides `self`. An expression body arrives as a block (ExprBodyDesugar). A `finally` in the body is FinallyLowering's local record, declared in the lambda.
- A call through a `fn` value (a local, a parameter, a field, `make()(4)`) casts each argument to the type's parameter as `_arg` does (`_fn_value_args`).
- A generic closure (`fn <T>(x: T)`) is not emitted; FeatureGateCheck rejects it with SC116E.

### Split constructor bodies

A split constructor (its body `{ {S_pre} {S_post} }` after CtorInitLowering: one that initializes a const field, a field whose type has no default, or an array field) is four definitions (`_split_ctor`):

1. the slot record: `::__kairo_slot<T>` per field S_pre assigns, in declaration order, then per carried local;
2. the pre-function: S_pre against the slots, then `return static_cast<__kairo_ciK&>(__kairo_s);` (since C++23 a returned `&&` parameter is an xvalue, which the `&` return cannot bind);
3. the slot constructor: mem-initializers `x(__kairo_s.x.take())` for every field S_pre assigns on all paths, in declaration order (an array `a{ __kairo_s.a.take()[0], ..., __kairo_s.a.take()[N-1]}`, since a member array is initialized from elements), then `if (__kairo_s.y.set) { this->y = __kairo_s.y.take(); }` for one assigned on some paths (never an array), then S_post;
4. the declared constructor: `R(P p) : R(__kairo_ctor_preK(__kairo_ciK(), p), p) {}`.

An eval constructor's three functions are all `consteval` (`constexpr` for a constexpr one), at their declarations and every definition. In S_pre (`_ci_pre`) `self.x = e` is `__kairo_s.x.init(e)` (`.put(e)` for a `var` field that is not an array); a write CtorInitCheck marked `ci_elem_init` (`self.a[k] = e`) is `__kairo_s.a.init_at(k, e)`, in place, so `e` runs where it is written; `self.x` and a bare field are `__kairo_s.x.get()`; any other `self` is an ICE. A carried local is `__kairo_s.__kairo_lI_n` in both halves, built at its declaration. The temporary slot record lives to the end of the public constructor's mem-initializer, which encloses the whole slot constructor; parameters reach both halves as the public one's lvalues, so a change S_pre makes to one is visible to S_post.

Only split constructors build fields by mem-initializer. Any other constructor that assigns a defaulted field in its body runs the default first, then the assignment. A fast path for a split constructor (straight-line S_pre lowered into the mem-initializers with statement expressions, no slot record) is designed but not implemented.

### Definitions

EmitIR produces free functions (a namespace wrapper per function); methods out of line (`RET Owner<T>::name(params) const`), including methods declared in the class and defined out of line (`fn C::m`), reached through the in-class declaration's chain; constructors and destructors; extension members as out-of-line definitions of their scope's static members (`RET __kairo_ext_X::m(X* self, ...)` in N, receiver first); Kairo definitions of C++-declared members and namespace functions (`fn W::at`, `fn ns::f`) at global scope in the C++ declaration's signature (`EmitIR::_foreign_def`, [Interop.md](Interop.md#kairo-definitions-of-c-declared-functions)); template and `inline` bodies ([Templates](#templates)); and `int main()` at global scope.

### No-headroom rules

Each rule has one home.

`_name` : locals bare (parameters, body variables, binders, generic parameters); `self` is `this` in a method and `self` in an extension member; anything else `qual_name(resolved_decl)`. A `candidate_cell` here is an expression typing failure.

`_chain_prefix` : separator from the base's canonical; operator steps spell `leaf(resolved_decl)`. A static field named through a generic record's instance (`Box<i32>::count`, `L<i32>::P::k`) is a value chain whose `::` step carries the instance on `ChainExpr::Step::through` (MemberTyping writes it; EmitPlan admits it Complete).

`_call` : callee is the promoted decl; a type as callee is a constructor call, whose parameters are `CallExpr::ctor_decl`'s. An extension member arrives as a plain call, receiver first (ExtensionLowering decided its pointer or object form, and `_arg` emits a `self` argument as it stands); a chain callee ending in an extension member is an ICE. `self` takes an argument unless the callee is bound (a `.` / `->` step, a constructor). A call bound to an interface requirement is spelled through its witness ([Witnesses.md](Witnesses.md#call-sites)). : A generic free function called by a bare name or `::` path spells its instance's arguments (`::m::pow<double, long>(...)`) from `CallExpr::instance`; a generic extension member spells `<ext args..., member args...>`, the order of `template_params`. Clang is never left to deduce: an argument whose C++ type is not its Kairo type (an int literal typed `i64`) would deduce an instance no TU homed. A generic method through `.` still deduces. A static member named through a generic record's instance (`Box<i32>::zero()`, or `Box<U>::zero()` in a generic body) is spelled through `CallExpr::qualifier`, which CallTyping writes (the member's decl is the pattern's and alone spells the bare class template); EmitPlan admits the qualifier Complete. A default-thunk call to a generic type's method goes the same way (`Box<int>::__kairo_default_m_x()`).

`_check_arity` : CallLowering's postcondition, checked in `_call`: every parameter has an argument, and more arguments than parameters only for a C `...` tail. A dependent call is as written and unchecked here: the body was checked once against its bounds, and clang checks each instance of an unbounded call.

Imported defaults : The one headroom: an imported C++ function's trailing defaults are omitted from the call and clang supplies them (`has_default` with no `default_thunk`). A non-trailing omission has no C++ spelling and is SC107E in Sema.

`_arg` / `_value` : `static_cast<P>(a)` whenever the argument's canonical differs from the parameter's (records excluded; they copy-construct). `@inout` emits the operand bare; `@move` emits `static_cast<T&&>(x)` for lvalues. For a generic callee a parameter that is one of its generic parameters is compared, and cast, against the instance's argument for it.

`_binary` / `_unary` / `_assign` / `_subscript` / `_cast` : primitives only, parenthesized; a record operand is an ICE naming OperatorLowering. "Record" is a class, struct, union or ADT enum (`_record_operand`): a plain enum is a `RecordType` too, but `==`, `<` and `as` on an `enum class` are C++'s own. An ADT's `==` arrives as a compare of the two values' variants (OperatorLowering through `EnumLayoutQuery::same_variant`), never as a call to `operator==`. `x as T&&` (a lowering's move) is a `static_cast`. : The checked downcast `p as (*D)?` is `EmitIR::_checked_downcast` ([Nullables.md](Nullables.md#codegen)). The asserting downcast `p as *D` arrives expanded by OperatorLowering, `({ B* s = p; D* d = dynamic_cast<D*>(s); if (s && !d) { unwrap_failed("<msg>", n); } d; })`, its inner cast a `dynamic_only` `TypeCastExpr`. : A raw-pointer cast between a class and its base is `static_cast` (`TypeCastExpr::base_adjust`, written by CastTyping; a C-style cast when it also drops a qualifier), because only a first base sits at offset 0. When the operand or target is typed only per instance (an unchecked-regime call result, a CRTP `(unsafe &self) as unsafe *T`), CastTyping cannot see whether the records are related; such an `as unsafe *R` is a C-style cast, which C++ resolves per instance to `static_cast` (related) or `reinterpret_cast` (unrelated).

`_var_decl` : an inferred type is the shared canonical (no range), spelled at the binding's name; a null type is I011W and `auto` ([Diagnostics](#diagnostics)).

### Unchecked-generic calls

Under the compiler-build internal regime ([BuildSystem.md](BuildSystem.md#internal-generics-regime)) every member call, operator and unbound free call through an unchecked parameter is wrapped in `(::__kairo_nopanic(), ...)` so a discarded panicking call cannot drop its error; the wrapper is specified in [Panic.md](Panic.md#codegen).

### Removed nodes

A node a lowering removes is an ICE naming its owner. The owners named in `EmitIR.k`'s ICE messages:

| Node | Owner |
|---|---|
| `match` | MatchLowering |
| `try`, `try`/`catch`, `panic` | PanicLowering |
| `finally` | FinallyLowering |
| ranged `for` (kinds not yet lowered, and a dependent iterable), a loop iterable range | IterLowering |
| other ranges | RangeLowering |
| `??`, `?.`, `?->`, `unwrap!`, `===` (a `match` on a `T?` is rewritten there into an ordinary match) | CoalesceLowering |
| a `T?` with no `lowered` record (in CXXSpell) | NullableTypeLowering |
| f-strings | FStringLowering |
| list, set and map literals; an untyped init list | ListLiteralLowering |
| tuple literals, tuple index steps, tuple destructuring | TupleLowering |
| a multi-part string literal; a literal typed `string` | StringLowering |
| labeled loops, `break`, `continue` | LabelLowering |
| `typeof`, `impl` and `derives` tests | TypeQueryLowering |
| named arguments; a call short of arguments; a pack parameter with no slice type | CallLowering |
| an extension member through a chain, or used as a value; a requirement call with no witness | ExtensionLowering |
| user operators; `[]`, compound assignment and `as` on a record; an unexpanded asserting downcast | OperatorLowering |
| a plain enum's `VariantInitExpr`; a pack-expanded variant with no element type | VariantInitLowering |
| an uncut split constructor | CtorInitLowering |
| a top-level statement or expression | ScriptLowering |
| `await`, `spawn`, `thread` | the async lowering (not implemented) |
| a context binding | ContextLowering (not implemented) |
| a generic closure; struct destructuring | FeatureGateCheck |

A null test left for NullTestLowering or a read left for NarrowedAccessLowering has no ICE of its own: those two passes are the only guard.

## Templates

Kairo has no monomorphizer ([Generics.md](Generics.md#instantiation-model)): a generic body is emitted once, as a C++ template, and a template's definition is visible in every TU that can instantiate it, the rule C++'s template model already depends on. Wherever its owner is held Complete, a TU emits every member body of a class template (its nested records' too), every member template of any class (`Suspend::await_suspend<H>`), every free function template its plan declares, and every generic extension member.

By the same mechanism it emits every `inline` body, since `inline` puts the body in the interface:

- every `inline` method of a non-template record, in every TU whose plan holds the owner Complete. These are never pruned by Kairo-visible references, because Kairo never sees clang's own calls (`await_ready`, `initial_suspend`, ...). Clang generates nothing for an unused inline definition, so the cost is parse time, and only for what is marked;
- every `inline` free function and extension member, in every TU whose plan declares it, at any strength.

The list is read off the plan's working set, not its roots, so it is transitive: a `priv inline` helper an inline body calls is admitted by the walk and its body joins on the next pass. This matters because clang emits an inline definition only in an object that uses it, and the helper's home object may not. Each body is emitted as C++ `inline`, its own TU's copy included, so the definition is the same text everywhere and the linker keeps one.

Each body sits in its owner's namespace wrapper, once per TU. `EmitPlan::visible_bodies()` is the one list: EmitIR emits exactly it and the plan walks exactly it for dependencies, at body strengths, to a fixed point. That walk makes `Suspend` and `YieldPromise<T>` complete in a consumer whose own code names neither.

Visible bodies are needed because clang instantiates templates Kairo never names: a coroutine's promise (`YieldPromise<int>`, through `Yield<int>::promise_type`), `await_suspend<std::coroutine_handle<...>>`, `std::sort` calling a Kairo comparator, a C++ consumer of a Kairo template. The registry cannot list those. ODR holds because the text is identical in every TU ([invariant 25](Pipeline.md#invariants)).

A default on a call Kairo cannot type (through an unchecked-regime receiver, [BuildSystem.md](BuildSystem.md#internal-generics-regime)) is emitted as a C++ default argument (`= __kairo_default_f_x()`), which deviates from the language's rules: a Kairo default belongs to the whole function and accumulates across declarations, any parameter may default, and defaults evaluate after the explicit arguments. Free function templates get none. The intended shape is forwarding overloads defined out of line.

### Explicit instantiation

`extern template` declarations sit in the preamble for every registry instance this TU does not home, and the home emits the explicit instantiation. `extern template class X<A>;` stops clang from implicitly instantiating X<A>'s non-inline members in that TU, so a known instance is compiled once, in its home; visible bodies are parsed everywhere and instantiated only in the home and for instances Kairo never saw. Explicit instantiation definitions follow every body, because an explicit instantiation only instantiates members defined before it.

A member template of a class template gets no explicit instantiation, named or reached: its registry entry carries only its own arguments, so it is instantiated implicitly from its visible body.

The calls a `<T impl I>` body makes into its bound go through the interface's witness, and the derived concept is the one Kairo-derived `requires` an emitted template may carry ([Witnesses.md](Witnesses.md)).

### Compile-time code

Compile-time code is interface by the same rule as `inline` bodies: a `consteval` or `constexpr` body and every namespace-scope `eval` binding is emitted in every TU that reads it, compile-time bodies and eval bindings first in `EmitIR::emit_tu`. The spellings and that order are specified in [Eval.md](Eval.md#codegen); the plan's early items are in [Early eval items](#early-eval-items).

### Computed values

A computed value (an array extent or generic value argument Sema kept as an expression, a `TypeExpr` with a `ValueOp`) is spelled by `CXXSpell::value`: each operator application parenthesized, value parameters as written or by their instance's value, eval constants and calls by qualified name, an eval class's constructor call by its class (`::m::Pt(2, 3)`, braced when empty), a string as the string record's literal constructor over its bytes (`::builtin::string::string(::__kairo_estr<...>, len, cp)`, the named array past the inline limit; one object per content, so two spellings of one value are template-argument-equivalent). EmitPlan admits what it names.

An instance over a computed value gets no `template class` or `extern template` line: it may be the specialization another spelling names (`Buf<twice(1)>` is `Buf<2>`), and C++ rejects two explicit instantiations of one; it is instantiated implicitly where used.

A template with a value parameter of class type is not forward-declared in tier 0 (C++ needs the class complete at every declaration of the template). Its definition follows the class (`EmitPlan::value_param_record`), tier 1 forward-declares it right after the last such class is defined (`InterfaceEmitter::_vp_fwd_decls`), and a record that names the template anywhere, through a pointer too, is ordered after the class (`EmitPlan::_names_vp_template`).

A string literal C++ reads at compile time is spelled `::__kairo_estr<b...>`, or `::__kairo_estrh_<len>_<hash>` past `LowerTargets::eval_str_inline_max`; both are specified in [Eval.md](Eval.md#codegen). EmitPlan collects the long ones (`big_str_bytes`) and InterfaceEmitter defines them right after the eval helpers, ahead of every type and body.

### Specializations of a generic record

A partial specialization (`class <P> Store<*P>`) is a C++ partial specialization and an explicit one (`class <> Store<bool>`) a C++ explicit specialization; C++ then selects them as Sema did ([Generics.md](Generics.md#instantiation-registry)).

    template<class T> class Store;               // tier 0, primary first
    template<class P> class Store<P *>;
    template<> class Store<bool>;
    template<class P> class Store<P *> { ... };  // tier 1, after the primary
    template<class P> int Store<P *>::tag() const { ... }
    int Store<bool>::tag() const { ... }         // no `template <>`
    template class ::ns::Store<int *>;           // tier 3 names the instance

- Spelling. `CXXSpell::record_head` (`template <>` for an explicit spec, else `template_head`) heads the spec's declaration and definition; `spec_suffix` (the pattern, a partial's parameters by name) follows its leaf there and in every out-of-line member's qualifier (`owner_segment`). Inside a spec, Self is the instance it stands for, spelled through the primary (`Store<P *>`, `Store<bool>`).
- Admission. A primary admits every specialization of it at its own strength (`EmitPlan::_admit_specs`, `InstantiationRegistry::specs_of`): a TU or header that can name `Store<X>` sees each one before any use would instantiate the primary instead, an ODR violation no linker reports. Tier 0 moves a spec written above its primary after it; tier 1 orders a spec after its primary. An instance a partial lays out is `layout_decl`'d to the partial, and its by-value needs are read off the partial's parameters.
- Members. A partial's members are templates (visible bodies); an explicit spec's are ordinary members of a non-template class, defined in the home TU, `inline` only when marked ([temp.expl.spec]/5: no template head out of line).
- Tier 3. An instance whose body is a partial is explicitly instantiated by its own name (`template class Store<int *>;`); an explicit spec is never an instance and gets no line.
- Extensions. Every block on any form of a template (`extend <T> Store<T>`, `extend <P> Store<*P>`, `extend <> Store<bool>`) is one scope struct `__kairo_ext_Store`, keyed by the primary (`ExtScope::key`), each member over its own receiver, befriended by every specialization.

A partial selected by `requires` is emitted with its clause (`template<class P> requires(...) struct Store<P>`), so C++ selects it from the same clause the registry evaluated at mint (`InstantiationRegistry::requires_holds`: literals, `sizeof` / `alignof` of builtins, pointers and arrays of them; anything else is undecided, SC001E at the use). Every body of a template with such a partial carries `static constexpr unsigned __kairo_spec` (0 the primary, 1 + its index a partial), and the home's explicit instantiation is followed by `static_assert(X<A>::__kairo_spec == k)`, k Sema's pick. A conformance in the selecting clause is SC116E. A pack parameter in a partial's pattern never matches, and a qualifier that matches only by subset (`const P` against `const volatile i32`) is a non-match; neither is built.

## Diagnostics

Codegen reports through the TU's `diag_sink`, drained by the driver after the object is written. Codes are defined in [Diagnostics.md](Diagnostics.md#codes).

| Code | Meaning |
|---|---|
| I011W | an unresolved type reached codegen; `auto` is emitted (`_var_decl`) |
| SC241W | `-Wshift-count-unproven`: a masked shift on ARM32 |
| I003E | internal compiler error (`codegen_ice`, `Compiler/Codegen/CodegenICE.k`), with the owning pass in the message |

Every other failure is an ICE naming its owner, and the ICE list is the work list ([Removed nodes](#removed-nodes), [Witnesses.md](Witnesses.md#emission)).

A method defined out of line is declared on its first byte and its definition keeps the name byte (`TokenSink::_claim` gives it to one token), so clang's errors and its "declared here" notes land on the definition, as clang's own lookup does. A class another TU defines, or a header's, keeps the name on the declaration, which is all its includers see.

Tier-3 lines are anchored with `_at(primary)`, every token on the function's name range, and clang's diagnostics on them have been seen rendering over unrelated source bytes; where that range lands for an extension member is untraced.

### Tests

Codegen tests live in `Tests/Codegen/`. Lowering tests carry a `--print-cxx` golden and a link that exits with a computed value.

| Test | Covers |
|---|---|
| `emit_plan_diamond/` | five TUs, foreign definitions per TU, an extension call through a field path, a homed template instance, one `.o` per module, `clang++ -Wodr` link |
| `operators/` | operator lowering |
| `defaults/` | `order` (evaluation order of named arguments and defaults), `defaults` (thunks on free, method and generic functions), `packs`, `ctor`, `redecl` (defaults over a chain), `ffi_defaults` (imported trailing defaults), `ffi_defaults_skip` (SC107E) |
| `slices/sum.k` | an array prvalue argument, an extended backing array behind a `var`, a literal under a conditional. Its `-o` names a directory, so the link takes `%t.d/*.o %t.d/builtin/*.o`: the Slice instance is homed in whichever TU used it. |
| `OperatorSemantics/` | [integer arithmetic](#integer-arithmetic-and-evaluation-order) |
| `mono_reached/` | instances reached through generic bodies |
| `witness/` | [Witnesses.md](Witnesses.md#tests) |

`--print-cg` goldens carry the fid column and preamble offsets.

### Remaining work

- Root naming by `module X;` declaration, making `-I` C++-only.
- Per-TU header reuse across FrontendActions.
- Namespace merging in EmitIR (cosmetic).
- A `ReturnStmt` keyword token.
- `TextSink` spacing of binary operators outside parentheses.
- Emitter consolidation: one `fn_signature` in CXXSpell, one namespace helper, one record-members accessor, `is_ctor` as a decl fact rather than a name comparison. Goldens for every `Tests/Codegen` test come first.
- Mem-initializers for every constructor, and the split-constructor fast path ([Split constructor bodies](#split-constructor-bodies)).
- Per-instance `constinit` for a generic record's static.
- `eval` fields as constants.
- Static promotion of an all-constant `const`-element slice literal.
- Derived comparisons from a generic, extension or ADT `<=>`.
