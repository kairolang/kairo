# Interop

How Kairo imports C and C++ declarations, maps their types, drives clang, exposes Kairo declarations to C++, and compiles mixed C/C++ and Kairo programs through `kcc`. The language-level contract is in the language reference ([c-cpp](README.md#language-reference), [c-cpp-abi](README.md#language-reference), [c-cpp-exposing](README.md#language-reference), [c-cpp-toolchain](README.md#language-reference)).

## FFI imports

An `ffi` import imports real declarations. Clang parses the header, `Compiler/Sema/Foreign/` translates what it declares into ordinary Kairo declarations, one TU per header, and phase I folds them exactly as it folds a Kairo file ([import resolution](Imports.md#import-resolution)). No pass after I asks where a declaration came from except through `FFILinkage` (`Compiler/AST/Mixin/FFILinkage.k`: `is_imported()`, the C++ spellings, layout, `ffi_c_variadic`, `ffi_explicit`, `clang_decl`, and the other `ffi_*` facts).

| Form | Binds |
|---|---|
| `ffi "c++" import "h.hh"` | every identifier-keyed name of every header in `h.hh`'s include closure, except `std` |
| `ffi "c++" import "h.hh" as my_h` | `my_h` to one module handle per closure header (each header TU's own `ModuleDecl`) |
| `ffi "c" import ...` | as above, with the header included inside `extern "C"` |

The language word is matched without case by one table, `Statements::ffi_lang_of` (`Compiler/AST/Node/Statements.k`): `"C"` is `"c"`, and `"c++"`, `"cpp"`, `"cxx"` and the C++ source and header extensions (`"hpp"`, `"hh"`, `"cc"`, ...) are C++. The parser, the preprocessor (`PPWalker::_ffi_lang_kind`, which decides the `extern "C"` wrapping) and the `--no-cxx` gate all ask it, so they cannot disagree about a spelling (P914).

### Stages

| Stage | Work | Code |
|---|---|---|
| PP | `PPWalker::_handle_ffi` builds the `ImportDecl` (header, alias, linkage) and appends the unquoted spelling to the file's ordered header list; `_finalize` requests a `HeaderSet` for the list | `Compiler/Preprocessor/Preprocessor.k` |
| after PP | `HeaderSetCache::start_shared` parses the union of every recorded list on the pool (`HEADER_BUILD_GROUP`), overlapping the Kairo parse | `Compiler/Interop/Clang/HeaderSet.k` |
| driver, before sema | `FrontendAction::_sema` waits for the header builds; per TU with a set, `HeaderIndex::index` mints a fid and TU per header clang touched, in touch order, runs `DeclImport` declare then define, and freezes; `_attach_ffi_edges` stamps each ffi `ImportDecl` with `resolved_fid` (the header's own fid) and `ffi_closure_fids` (its transitive include closure, `HeaderSet::closure_of`) | `Compiler/Driver/CompilerInstance.k`, `Compiler/Sema/Foreign/HeaderIndex.k` |
| I | `_resolve_ffi`: aliased, one module handle per closure header under the one alias key (the [reopened-namespace](Imports.md#overlays-and-visibility) shape, so `my_h::f` searches every header's table); bare, `_fold_all_cells` over every closure header, as the `#include` it stands for would | `Compiler/Sema/Resolve/ImportResolution.k` |
| N, T, ChainBinding | nothing special; cross-TU probes spell through `in_scope`; a header TU has an identifier table (`TokenCacheManager::ensure_imm_table`) and no tokens | |
| typing | a C `...` tail ranks Converted, unchecked (`OverloadResolution`); an `explicit` constructor is not a converting constructor; argument-dependent lookup (`MemberLookup::associated_scopes`) finds `std::operator<<` | [Expression typing](ExprTyping.md#overload-resolution) |
| codegen | every TU loads one merged PCH of the build's header sets; a header's declarations are never re-emitted (`EmitPlan::_admit`) | [Codegen](Codegen.md#pipeline) |

### Header sets

A `HeaderSet` is one clang parse (phase A) whose live AST Sema/Foreign walks and that template fills query. The build parses all its header lists as one shared set: `HeaderSetCache::request` records each distinct list as a view, and `start_shared` parses their union, ordered by list key, each header once by resolved path and linkage. Every view's `shared` then points at the union, and each TU's `header_set` becomes the union after indexing. A TU's names stay filtered per ffi import by `closure_of`; its clang-level view (macros for `defined!`, fills, deductions) is the union, which is what codegen compiles against anyway.

It falls back to one parse per list when there is a single list, when one header is imported both as C and as C++ (the language is part of a set's key), when the union fails to parse (the per-list parses then report the errors), or under `-fno-shared-header-set`.

Phase A parses with clang's `SkipFunctionBodies`, so `--type-check-only` does not report an error inside a header function's body; a full build does, when the codegen PCH parses every body.

### Unresolved headers and header diagnostics

A spelling clang cannot find leaves `resolved_fid` 0 and phase I binds nothing, so each use of its names is an ordinary R020E. A set's own clang diagnostics go through a `ClangDiagAdapter` into the Kairo engine (`HeaderSet::begin_diag`), mapping locations through the set's `cfid_to_kfid` table: at build time into the set's `diag_buf`, drained into the driver's engine once the build joins (they predate the header fids, so they carry clang's `file:line:col` in their text); during a fill, into the demanding TU's sink with real spans ([Clang diagnostics](Diagnostics.md#clang-diagnostics)).

### `cxx::std`

Bare `std` is Kairo's (`kairo::std`, [std root](Imports.md#path-resolution)), so C++'s `std` is spelled `cxx::std`. Once per TU with any ffi import, phase I synthesizes a `ModuleDecl` named `cxx` owning one binding: `std` to every top-level `std` `ModuleDecl` in the TU's ffi closure, collected while `_resolve_ffi` folds each closure header (aliased imports included). It folds into the overlay as a module handle under `cxx` (`_bind_cxx`). A TU with no ffi import binds nothing, and `cxx::std` is an ordinary miss.

The alias is transparent: the declarations it reaches are the header TUs' own, with their own paths, and codegen spells them `::std::...`. It adds no lookup arm: `cxx` is a module anchor and `std` under it an all-module cell, so `cxx::std::cout` uses the multi-scope rule. A change needed in ChainBinding or TypeResolve for this would be a bug in reopened-namespace support.

`_fold_all_cells` takes a `skip_std` flag because it has three callers (the bare ffi fold, `import foo::*`, a `*` item in a selective import), and only the first passes true. Every other top-level C++ name folds as before: `cxx` is one alias for one name, not a general prefix. `cxx` used alone as a value or type is R053E. A user module or root named `cxx` shadows it legally. This `SymbolTable` is the one built outside `ASTParse::_build_symbols`; it holds foreign declarations by reference and is frozen before anything reads it.

### Tags and ordinary names

C and C++ keep tags (struct, class, union and enum names) apart from ordinary names, so glibc declares both `struct timezone` and `extern long timezone`, and `struct stat` beside `stat()`. Kairo has one namespace per scope, so the C++ hiding rule ([basic.scope.hiding]) is applied where the two meet, between imported declarations only; a Kairo declaration never hides and is never hidden this way.

| Header shape | The plain name binds | The tag |
|---|---|---|
| `struct T` and an ordinary `T` (variable, function, typedef of something else, enumerator) | the ordinary declaration | bound only under the internal key `struct T` |
| `typedef struct T T` | the tag (one entity) | the typedef is not bound by name |
| `struct T` alone | the tag | |
| two ordinary `T` (inline namespaces) | nothing: R016E at the use | |

The rule is applied in three places:

- `DeclImport::_bind_named`, per header set. Clang's own lookup over the whole set decides (`_hidden_tag_keyword`), so a tag and its hider in different headers are seen together. A hidden tag is bound under `struct timezone`, a spelling no source can produce, and stamped `FFILinkage::ffi_tag_keyword`.
- `ImportResolution::_apply_hiding`, per overlay entry. A header's table is filled by the first set that indexes it, so a later set that also sees the hider marks the target `hidden` (out of `merged` and out of `non_function_count`). Same scope only, read off the qualified C++ spelling: a tag in an inline namespace beside a global variable stays an ambiguity, as in C++. A header cell with several entities folds one target per entity (`_fold_ffi_cell`).
- `ChainBinding::_commit` (`ffi_hide_tags`), for `h::timezone` through an alias.

The type stays reachable through everything that names it, because TypeImport goes by the clang declaration and never by name: `gettimeofday(*timeval, *timezone)` types its parameter as the struct. CXXSpell writes a hidden tag elaborated (`struct ::timezone`).

An overlay entry whose collision is between header entities only (`OverlayEntry::lazy`) is not reported by I, since a header set routinely declares names nobody uses. N (expression heads) and T (type names) report R016E at the use, with one R016N note per candidate (`MemberLookup::report_lazy_ambiguity`). A collision any Kairo import takes part in is reported at the import. `--print-imports` marks a lazy entry `(reported at use)` and a hidden target `hidden`.

### Naming a tag

A bodiless `struct`, `class` or `union` under an `ffi` prefix or in an `ffi { }` block is a foreign forward declaration (`ffi "c" struct T`). Phase I (`_bind_ffi_forwards`) looks the name up in the TU's ffi closure, a hidden tag's internal key first and then a visible tag, and stamps the match as `FFILinkage::ffi_tag_target`. `NameLookup::representative` then answers with the header's declaration, so every type built from the forward declaration is the header's entity and EmitPlan never emits it. No match leaves a Kairo forward declaration.

The declaration sits in the TU's own table and would shadow the imported ordinary name. In a value position N (`_prefer_ordinary_over_ffi_forward`) takes the overlay's ordinary declaration instead, so `timezone` in an expression is the variable and `*timezone` in a type is the struct. The head of an expression that means the type (a struct literal) therefore reaches the variable, as C requires `(struct timezone){...}`. Enums are not covered: a C++ enum forward declaration needs its underlying type.

### Instances of imported templates

`cont<i32>` for an imported `cont` is a registry shell like any instance ([instantiation registry](Generics.md#instantiation-registry)), but clang fills it (`MemberLookup::filled_by_clang`), never Kairo's own instantiation. `MemberLookup::ensure_filled` is the one trigger, called by both readers of a shell's table: member lookup (`c.size`) and TypeResolve's `::` step (`TypeResolve::_scope_of`), so an alias target, a generic argument and a bare `X<A>::Y` in a signature all fill from one place.

`ForeignInstantiate::fill` (`Compiler/Sema/Foreign/ForeignInstantiate.k`) spells the entry's arguments as clang types in the primary's set ([TypeExport](#type-mapping)), has clang declare and complete the specialization (`CheckTemplateIdType` and `RequireCompleteType`, under the set's `sema_lock`), and runs `DeclImport` in fill mode over the `ClassTemplateSpecializationDecl` to import its members into the shell, whose `ForeignFill` (`AST/Mixin/TemplateParams.k`) is then `Filled`. `size()` therefore returns clang's `size_type`, not the pattern's dependent spelling. Members live in the primary's header, but each name token is minted in the header it is written in (`DeclImport::_home_at`), because a token's text is read back through its range's TU.

A specialization clang rejects is sticky (`ForeignFill::FailedSticky`), and lookup walks the pattern. The shell's state is one byte, Shell, then Filled or FailedSticky, both terminal: written only by the fill, under its `_mu`, as its last write (a release store, `decl_publish_fill`), and read on any thread with an acquire load (`decl_instantiated`, `decl_fill_failed`). A fill's verdict (`FillResult`: Filled, Failed, Unspelled) and its reason are returned up the fill's own call chain, so a nested fill (an argument's instance, on the same thread) cannot overwrite the outer one's. A fill holds only that build-wide `_mu` while other Sema threads read the headers' scope tables unlocked, so it writes no table they can reach: only tables it creates (the shell's, those of records it mints), published with the shell. A debug build ICEs if a fill would append to a frozen table, create a namespace, or give a published scope its first table. The one write into a published header scope is the `dc_decls` list of the namespace or TU a minted hidden friend belongs to; during Sema nothing but other fills (serialised by `_mu`) reads a header scope's `dc_decls`. A fill that failed only because the set could not spell an argument is not sticky: it is retried in each other demanding TU's set, and only an answer the first set could not give is taken from the retry. Completing a class-type argument with no definition runs with diagnostics suppressed and leaves the shell unfilled when invalid. A failed fill's clang errors reach the demanding TU's sink, spanned in the header; a Kairo note at the use that demanded the fill is not implemented. A `Foo<Args>::Y` whose `Foo` is imported and whose arguments are concrete steps into the registry instance, and defers as dependent only when the fill failed.

Fills nest (define imports a type that is a path into another shell). `ForeignInstantiate::_mu`, one lock for every fill in the build, and each set's `sema_lock` are recursive and taken in that order; a shell already mid-fill on this thread returns false at once.

Nested records: implicit instantiation declares `holder<alloc>::node` but defines it only on demand. The fill completes every nested record its own walk reached with `RequireCompleteType` and walks it before the define pass (`ForeignInstantiate::_complete_nested`), to any depth (a visited set on clang declarations; ICE past 4096). Records a member signature only mentions are not reached: completing transitively would have the first `<vector>` fill instantiate half of libc++. A record clang cannot complete is left memberless and logged. Each nested record is declared under its own USR, so `holder<alloc>::node` from any TU is one declaration.

### Clang builtins

A name clang knows as a builtin is a foreign function the TU did not import. `BuiltinImport` (`Compiler/Sema/Foreign/BuiltinImport.k`) mints its `FunctionDecl` on first use from the prototype clang gives (`Compiler/Interop/Clang/BuiltinsSet.k`), consulted by N only after every Kairo source missed. A library builtin (`memcpy`, `printf`) is a miss: its header declares it. A builtin with custom type checking, one whose type needs a header (`FILE`, `jmp_buf`), or one whose type Kairo cannot express is an error at the use.

### Macros

Kairo's FFI never expands C or C++ macros, and no macro crosses the Kairo/C++ boundary. A header is imported as declarations; the compiler has no point at which a macro's expansion becomes a Kairo expression. A macro a program needs is wrapped in a header as a real function or `constexpr` value (the compiler's own `kairo::std_out` and `kairo::neon_ld_u8` in `Compiler/Native/` are examples). Testing a macro's existence is supported: `eval if defined!(X)` asks the TU's header set which macros are defined.

### Lifetime

Header TUs live for the build; `CompilerInstance::release` refuses one, since their declarations are shared by every importer through the `ForeignRegistry`. A set that contributed no declaration is released right after indexing (`HeaderSet::release_unused`), keeping its macro names for `defined!`, and is re-parsed only if a fill retry asks for its AST (`_revive`). Other sets' clang instances live until `HeaderSetCache::release_all`. Fills need the instance alive: `ForeignInstantiate` ICEs on a released set rather than read a dangling `clang_decl`. A set's lifecycle is one state byte, `HeaderSetState` (`Interop/Clang/HeaderSet.k`): Minted, Building, Built, Live, Unused, Reviving, Dead, Final. The first build moves Minted to Building to Built on its pool thread; every other transition (publishing Live on the first ask, `release_unused`'s Unused, a revive, `release`'s Final) holds the set's `_revive_mu`; readers do one acquire load. `ok` is the first build's verdict and a revive never rewrites it. `release_unused` is safe by ownership, not by the state: a reader that loaded Live before the release still uses the instance, so the driver frees a set only after its last owning TU's group.

## Type mapping

`TypeImport` (`Compiler/Sema/Foreign/TypeImport.k`) maps a `clang::QualType` to a Kairo canonical type, always through `getCanonicalType()` first, so two spellings of one C++ type are one Kairo canonical. The sugared spelling is kept separately for EmitIR.

| C/C++ | Kairo |
|---|---|
| `T*` | `unsafe *T` (a C pointer carries none of Kairo's pointer guarantees) |
| `const T&` | `cxx_lref(qualified(const, T))` |
| `T&` | `cxx_lref(T)`; a Kairo lvalue binds it as a borrow ([Ownership.md](Ownership.md#copy-and-move)) |
| `T&&` | `cxx_rref(T)` |
| `cv T` | `qualified(cv, T)`, object types only |
| builtin types | by size, sign and float format against the target; `i64` / `u64` are the target's `int64_t` / `uint64_t` (`long long` on Darwin), and a plain `unsigned long` stays the fixed-width `u64` |
| `size_t`, `ptrdiff_t` (and other pointer-sized typedefs) | `usize` / `isize`, read off the typedef sugar before canonicalization (`TypeImport::_pointer_sized`) |
| plain `char` | `c_char`, so a C string is `*const c_char`, spelled `const char*` |
| `wchar_t`, `char16_t`, `char8_t` | `c_wchar`, `c_char16`, `c_char8` (BuiltinKind `CWChar` / `CChar16` / `CChar8`), never their width's integer, so `f(wchar_t)` / `f(int)` are two overloads and `allocator<wchar_t>` / `allocator<u32>` two registry shells whose specialization hint is kept; `c_wchar` is laid out from the target's `wchar_t` width (`Target::wchar_bits`: 32, 16 on Windows) |
| `std::nullptr_t` | one shared opaque; an untyped `&null` deduces it for a template parameter and ranks Converted to a pointer, as in clang |
| `Foo<int>` | the registry shell `instance_for(Foo, [int])` |
| a template parameter | `generic_param(owner, index)` |
| a specialization of the Nullable lang item | `T?` |
| anything else | `opaque(spelling)`: usable as a value, never looked into |

`ForeignRegistry` (`Compiler/Sema/Foreign/ForeignRegistry.k`) maps USR to Kairo declaration build-wide: `struct Foo` reached through two header sets is two clang declarations and one Kairo declaration. Every cross-reference `DeclImport` and `TypeImport` make goes through it. `DeclImport` (`Compiler/Sema/Foreign/DeclImport.k`) does not import friend classes, using-directives, `static_assert`, deduction guides, variable templates, bit-field widths or default-argument expressions (their presence is recorded).

`TypeExport` (`Compiler/Sema/Foreign/TypeExport.k`) is the inverse, against one header set's `ASTContext`, and exists for fills. It returns a null type for what it cannot express, which the fill reads as "cannot instantiate", never as a user error.

### Template arguments

| Argument | Rule |
|---|---|
| value (`array<i32, 4>`) | its canonical is the exact integer (`CanonicalTypeStore::value_arg`) on both sides, so the instance a header names and the one source spells are one registry entry; the parameter's C++ type is not part of the identity, and TypeExport recovers it from the template parameter, refusing a value the parameter cannot hold. A C++ spelling prints every value argument with its type. |
| pointer | `*Node` and `unsafe *Node` are both `Node*` to C++. Inside a fill every pointer level of every argument is recorded against the clang type it spells (`TypeImport::note_pointer_arg`), so a member type naming that clang type reads back as the argument: `vector<*Node>::push_back` takes `const *Node&`. Two flavours of one pointee are two shells over one clang specialization, sharing member declarations registered once by USR. |
| `T?` | the Nullable lang item's instance over `T`, as NullableTypeLowering lowers it: `vector<*Node?>` prints `::std::vector<::builtin::Nullable<::stem::Node *>>` |
| Kairo record | a stand-in, below |
| `fn(A) -> R` | the C pointer `R(*)(A)` it imports from |

### Stand-ins for Kairo types

Phase A's AST has never seen a Kairo record, so `std::vector<S>` makes TypeExport declare a stand-in for `S` there: a complete struct with `S`'s non-static fields in order, under exactly the name EmitIR emits (`CXXSpell::ns_segments` plus leaf, e.g. `::stem::S`). Every spelling the fill records is printed from phase A and compiled in phase B against the real `S`, so the name is what makes it sound. The stand-in's USR is registered to `S`, so `reference` reads back as `S&`, the Kairo record.

| Kairo type | Stand-in |
|---|---|
| record | struct of its fields; layout only (no methods, implicit special members only) |
| generic record instance | explicit specialization of a stand-in template (`::stem::G<int>`) |
| plain enum | scoped enum of its underlying word (`enum_niche_kind`) |
| class with bases | the bases' stand-ins as real C++ bases, a leading `void*` for the vptr when the class is polymorphic, then its fields |
| ADT | struct of its tag word followed by every variant's payload fields in sequence; this mirrors the copy and destruction traits phase A asks about (a union of payloads would get them wrong) and over-states the size, which phase A never asks |

Refused, so the fill fails: records nested in a type, classes with a virtual base (subobject placement is not modelled), generics with a pack or value parameter, an ADT with a pack-expanded variant, a field whose type has no export, and a name a header already owns. A Kairo instance a fill names first (`Nullable<i32>`) is homed in the TU that demanded the fill.

## Clang integration

Kairo links clang in-process. The pieces, all in `Compiler/Interop/Clang/` unless noted:

| Piece | Role |
|---|---|
| `ClangBackend.k` | persistent clang state for the whole batch; startup on the pool |
| `HeaderSet.k` | phase A: header parses for ffi imports ([header sets](#header-sets)); phase B's merged `CodegenPCH` of every set, built on the pool during sema (`prebuild_codegen_pch`), with a textual per-set fallback when it fails |
| `BuiltinsSet.k` | a parse-free clang instance that answers what a builtin's ID, prototype and attributes are |
| `ClangJobs.k` | C, C++, Objective-C and LLVM IR inputs, compiled by clang's driver and frontend in-process ([native inputs](Driver.md#native-inputs)) |
| `ClangLocMap.k` | Kairo to clang source-location translation over a shared clang TU |
| `KairoInclude.k`, `KairoIncludeScan.k` | `#include "foo.k"` ([kcc](#kcc)) |
| `Compiler/Diagnostic/ClangDiagAdapter.k` | clang diagnostics into the Kairo engine ([Clang diagnostics](Diagnostics.md#clang-diagnostics)) |
| `Compiler/Codegen/Backend/CodegenBackend.k` | emits each Kairo TU's token stream into clang ([Codegen](Codegen.md#pipeline)) |

Division of labour: Kairo resolves overloads, ADL, specialization selection and constraints (SFINAE, `requires`) over the imported declarations itself (OverloadResolution, MemberLookup). Clang is asked for two things only: to complete an imported class-template instance (`ForeignInstantiate::fill`, [instances of imported templates](#instances-of-imported-templates)) and to deduce the arguments of an imported function-template candidate. Neither is a choice between candidates. Codegen never asks clang to resolve anything ([Codegen](Codegen.md#pipeline)).

Header locations map to Kairo locations by file identity: `cfid_to_kfid`, built at index time, is the one table where a clang `FileID` meets a Kairo fid. Scratch buffers and `<built-in>` have no row and map to an invalid location.

Threading: a set's `build()` touches only its own clang instance; nothing calls the Kairo SourceManager, token cache or global disambiguation table off the driver thread. Fills and other demand-driven clang work go through the set's `sema_lock`.

## Exposing Kairo to C++

Three consumers read an EmitPlan ([EmitPlan](Codegen.md#emitplan)) through the same `InterfaceEmitter`, differing in plan mode:

| Consumer | `PlanMode` | Roots | Output |
|---|---|---|---|
| `CodegenBackend` | `Preamble` | every own declaration plus foreign declarations reached | the TU's object |
| `EmitCXXHeader` | `Header` | own `pub` declarations plus foreign declarations reached | `<dir>/<module path>.hh`, under `--emit-headers` |
| `IncludeEmitter` | `Include` | `Header` roots plus a visible-body walk, emitted Preamble style | the token stream `#include "foo.k"` splices into a C++ TU |

`EmitCXXHeader` (`Compiler/Codegen/Backend/EmitCXXHeader.k`) is not a clang action: it needs sema's resolved links only, runs per TU after sema into a `TextSink`, and writes nothing for a pathless TU (nothing can import it) or when sema reported errors. A C++ consumer of the header sees canonical namespaced names (the module path, [CXXSpell](Codegen.md#cxxspell)) and no Kairo aliases.

Class `priv` members are C++ `private:`. Top-level `priv` and `internal` declarations are left out of an include stream, except those a `pub` `inline` or template body needs; a pathless file's such helpers stay out of the unnamed namespace (`TranslationUnit::cxx_escaping`) so includers can link against them.

### Allocating Kairo types from C++

In `Header` and `Include` plan modes every class, struct and ADT enum carries class-scope `operator new` / `operator new[]` / `operator delete` / `operator delete[]` bound to the program's global allocator, so `new MyKairoType()` and `delete p` in C++ pair with `@create` / `@destroy`, and a C++ global `operator new` override never reaches a Kairo object. The forms, sizes, failure behaviour and limits are specified in [Codegen](Codegen.md#c-allocation-operators). A module's own object has none.

Memory that must follow C++'s allocator uses `@cxx::new` / `@cxx::delete` ([Ownership](Ownership.md#destruction-and-freeing)).

### Constructing ADT variants from C++

In a header and an include stream (not the module's own object), every ADT enum record carries one public static factory per variant, so C++ writes `packet::Frame<int>::Burst(20, 4)` or `Res::Nothing()` instead of the internal tag form `Frame<int>{::__kairo_vt<0>{}, 20, 4}`:

- the parameters are the variant's fields in declaration order, named after them, typed as the field constructor's (by value; a field whose move is not its copy is moved into the payload); a unit variant's factory takes nothing (a function, not a static data member: the record is incomplete inside its own body);
- each is `template <class __kairo_mk = void> static E V(...)`, inline in the class, so it costs nothing unless called and a generic enum's works at any instance (Codegen.md#adt-enums says why it is a template); taking its address needs `&E::V<>`;
- name clash: a factory is named exactly after its variant unless that name is taken in the record -- the record's own name, a template parameter, or a member the record is written with -- and then gets `_` appended, repeated while taken (the rule of [Codegen.md](Codegen.md#top-level-namespace-collisions)). Variants whose names are free claim them first: in `enum Node { Node {..}, Node_ {..} }` the factories are `Node__` and `Node_`. A payload field named like the record moves only its parameter aside;
- not written: a pack-expanded variant (no single signature), a variant with an array field (a C++ array parameter is a pointer), and the panic result type (its site slot has its own view, Panic.md). Plain enums are unaffected: they are already `E::V`.

Kairo has no tuple-like variants (every payload field is named), so there is no positional form. Tests: `CLI/Kcc/kcc_adt_factories.k`, `CLI/Kcc/kcc_adt_factory_clash.k`, `Codegen/enums/adt_factories_header.k`.

## kcc

`kcc` (`Compiler/Driver/Kcc.k`) is the toolchain's clang/clang++ drop-in, and a C++ TU may `#include "foo.k"`:

```text
kcc main.cc foo.k -o app
  main.cc  -- clang cc1, in-process (ClangJobs) -------------> main.o
     #include "foo.k"  -> hook: foo.k's interface tokens, from the build's
                          analysed tree, into the host preprocessor
  foo.k    -- Kairo pipeline ---------------------------------> foo.o
  main.o + foo.o + builtin/std/runtime objects -- link -------> app
```

### The include hook

The tree's patched clang has `Preprocessor::setFileTokenizer`: when the preprocessor enters a file, the hook may return a prebuilt token array, which the lexer hands to the parser as is and pops the include on exhaustion. So a `.k` include takes clang's normal include path (inside `#if`, mid-function), and every token is located in the `.k` file.

| Step | Code |
|---|---|
| A host action subclass per cc1 action (object, assembly, IR, bitcode, `-fsyntax-only`, `-E`, a header PCH) installs `KairoIncludeHook` in `BeginSourceFileAction`; `execute_with_kairo_includes` picks the subclass from `FrontendOpts.ProgramAction`. Other actions run without the hook. | `Compiler/Interop/Clang/KairoInclude.k` |
| The hook asks `DriverIncludeSource::tokens_for`, which finds foo.k's TU in this build and binds one `ClangLocMap` per host TU | `Compiler/Driver/KairoIncludes.k` |
| `IncludeEmitter::emit` runs an `Include` plan of foo.k, prunes entries the host TU already received (`IncludedDecls`), and emits declarations and visible bodies through a `TokenSink` bound to the host's preprocessor, so identifiers are the host's `IdentifierInfo`s | `Compiler/Codegen/Backend/IncludeEmitter.k` |
| A stream that needs headers (`<new>`, every reached module's ffi headers by resolved path, `ffi "c"` ones inside `extern "C"`) cannot carry `#include` lines: the hook returns the sentinel, enters a `<kairo-include>` buffer with those lines plus `#include "<real path of foo.k>"`, and returns the held tokens on the second entry | `KairoInclude.k` |

Constraints the stream obeys:

- No trailing `tok::eof`: it would end the whole host TU.
- An engaged empty array means "no hook" to the fork, so an include with nothing to declare, or one that failed, yields the sentinel `static_assert(true);` (valid at namespace, class and block scope, silent under `-Wextra-semi` and `-pedantic`). A C host gets `;`. A three-line fork patch (an `IsPrebuilt` flag) would remove the sentinel; it was declined.
- `TokenSink` sets keyword kinds itself, since the prebuilt lexer does not re-kind identifiers.
- No macro expansion: a host `#define add` cannot rewrite a Kairo name.
- No explicit instantiations, not even `extern template`: the host instantiates implicitly, the home objects' explicit instantiations are `weak_odr`, and the linker folds them. This holds across separately compiled objects.
- Under `-E` punctuators are arena tokens (`TokenSink::arena_puncts`) and every token has a leading space, so the preprocessed output is valid C++ that rebuilds the same program.
- The same `.k` twice in one host TU is include-once; `IncludedDecls` is reset per host TU.

An include is refused with one host error at the include location: the file is not part of this build, the host is not C++ or Objective-C++, or the host's dialect is below C++20.

### A `.k` include in a header Kairo imports

`#include "foo.k"` is kcc's, in a C++ TU. A header reached by `ffi import` (directly or through its own includes) that includes a `.k`, and an `ffi import` that names a `.k` itself, are R070E (P954). Clang never reads the Kairo text: `HeaderSetAction` installs `KairoIncludeHook` with `refuse` set, so every `.k` the set's parse enters is the sentinel and include-once, and nothing is reported into clang's engine (the set stays `ok`, and the rest of the header imports). `HeaderSetPPCallbacks::InclusionDirective`, which fires before clang enters the file, records the include (`HeaderSet::record_kairo_include`: the header, the file name's offset, the `ffi import` it was reached from through `_main_locs`; first build only, one entry per include line). `drain_diags` reports each on the driver thread, where the Kairo SourceManager decides the two extra sentences: the `.k` is the importing file, or it is already part of this compilation. The `.k` gets no `HeaderFile` and no `IncludeEdge`. `Tests/Sema/FFI/kairo_include_in_header/`.

### Discovery and outputs

`CompilerInstance::_discover_includes` scans every C++ and Objective-C++ input before the Kairo TUs run (`KairoIncludeScan`: clang's dependency-directives scanner, quoted includes followed recursively, resolved through the includer's directory, then `-iquote`, then `-I`; angled `.k` includes through `-I`). Each `.k` found that the command line does not name joins the inputs as `InputKind::discovered`: built and linked, never written to `-o`. The scan ignores conditions, so a `.k` behind `#if 0` is still built, and misses an include spelled through a macro, which then gets the "not part of this build" refusal.

When an included `.k` is found, every Kairo input runs through sema even if the action stops earlier for C++ (`--preprocess`, `--syntax-only`), because the stream is emitted from the analysed and lowered tree (`kairo_feeds_includes`). C/C++ inputs compile after every Kairo TU.

A Kairo TU whose one-segment module path matches a C/C++ input's stem writes `<stem>.k.o` (`CompilerInstance::kairo_object_stem`); the C/C++ input keeps `<stem>.o`.

An included file's namespace is its module path, the same whoever compiles, imports or includes it ([module pinning](Imports.md#module-pinning)).

### The kcc driver

`kcc` is a build target beside `kairo`, run by the same `CompilerInstance`. `FlagTranslator::from_driver` (`Compiler/Command/FlagTranslator.k`) translates the clang command line into kairo words, and `Kcc.k` adds the output-scope and `-emit-llvm` words:

| Input | Becomes |
|---|---|
| a clang option kairo has a flag for | that flag |
| any other clang option | `--cxx-flags=<w>`: C/C++ compiles only |
| `-Xkairo <word>` | one kairo word, untranslated |
| no `-std=` | `--cxx-std=c++23` |
| `-c`, `-S`, `--emit` | `--emit-scope=inputs` |
| always | `--kairo-lib` |
| `-###` | `--print-jobs`: each cc1 line, then the planned link |
| `-emit-llvm` with `-S`/`-c` | `--emit=llvm-ir` / `--emit=llvm-bc` |

`kcc` answers `--help` and `--version` itself. Target and sysroot are kairo's, not the host's: kcc is part of the toolchain.

Separate compilation works as with clang: `kcc -c x.cc; kcc -c y.k; kcc x.o y.o -o main`.

- `--emit-scope=inputs` writes objects for the command line's own Kairo files only; imports, builtin, std, the runtime and discovered `.k` files are analysed, not emitted. `kcc -c x.cc` that includes `y.k` analyses `y.k` and writes no object for it. The default, `graph`, writes every file the run reaches.
- `--kairo-lib` links builtin, std and the runtime lazily (`LinkJob::lazy_objects`, `--start-lib`/`--end-lib`; `libkairo.a` through `LinkJob::lazy_archive` on MinGW) from a cache under `$KAIRO_CACHE_DIR`, `$XDG_CACHE_HOME/kairo` or `~/.cache/kairo`, keyed by compiler path, target, target/codegen/optimization/debug words and the builtin and std directories. A missing or stale cache (its manifest records every source's mtime, the compiler's included) is built in the same kcc run before the inputs, in a private directory renamed into place. Entries unused for 30 days, and partial builds a day old, are removed.

### Decisions

| # | Question | Decision |
|---|---|---|
| 1 | target and sysroot | kairo decides; kcc is not a host `clang++` |
| 2 | C++ dialect | default C++23; the user may go lower down to the C++20 floor the lowering needs (`constexpr`, `constinit`, `consteval`, `requires`), which the hook enforces |
| 3 | separate compilation | clang style; include streams carry no explicit instantiations; builtin, std and the runtime come from the cached toolchain library |
| 4 | fork patch for empty includes | declined; the sentinel stays |
| 5 | visibility in an include | class `priv` is `private:` (an unmarked member that is `priv` by default too, operators excepted); top-level `priv`/`internal` left out except what a visible inline or template body needs; top-level `prot` (written, or unmarked under a `module.k`) only for a C++ TU under the same `module.k` (`IncludeEmitter::_host_in_module`, `EmitPlan::host_in_module`), never in a `.hh` |
| 6 | sema for Kairo inputs when a C++ input includes a `.k` | yes, only when the scan found an included `.k` |
| 7 | module identity | [module pinning](Imports.md#module-pinning) |

### Unimplemented design intent

These are planned and not built:

- Clang options with no kairo flag (`-pthread`, `-fsanitize=`, `-pie`, `-flto`) reach C/C++ compiles only, never the link; a single-language flag in a mixed TU is meant to be an error.
- `ClangLocMap` registers every Kairo fid in each host TU on its first include (one `rebind` per host TU); the intent is a sparse map of the fids a stream references.
- With two or more `.k` inputs, `PreProcessor::reach` (for `_kairo_order`) scans every input's graph and the real preprocess scans again; the reach graphs are meant to seed the second scan.
- PCH or preamble seeding of `IncludedDecls`; `KairoHostPCH` is wired but untested.
- `-MD`/`-MF` output listing `foo.k` and every file it reaches is untested.
- `#include "foo.k"` inside a C++ namespace or class breaks the stream's `::`-qualified names; it is meant to be diagnosed ("include at file scope").
- `.k` under `-fmodules` or header units diagnosed; Windows case-insensitive `.k` and real-path keys; host `-mllvm` isolation around the hook; a content-hash Kairo cache for `make -j`; ccache and distcc over the `-E` round trip.
- Kairo inputs and host jobs run serially (all Kairo TUs, then the host jobs); a codegen thread with a hook lock waits for a profile that needs it.
