# Kairo compiler specification

This directory specifies how the Kairo compiler implements the language: its pipeline, the contract of each pass, the invariants that hold between them, and the known limitations. What a Kairo program means is defined by the [language reference](#language-reference); where the two disagree, the language reference states the intended behaviour and the disagreement is a defect.

The directory layout of the sources is in `Compiler/README.txt`.

## Pipeline

```text
source (.k)
  -> Lexing and preprocessing       Lexing.md
  -> Parsing                        Parsing.md
  -> Sema
       import resolution            Imports.md
       expansion, verification,
       name resolution              NameResolution.md
       type resolution, chain
       binding                      TypeResolution.md
       expression typing            ExprTyping.md
       semantic checks              SemanticChecks.md
       lowering                     Lowering.md
       monomorphization             Generics.md
  -> Codegen to C++ tokens          Codegen.md
  -> clang (in process)             Interop.md
  -> link (lld)                     Linking.md
```

The authoritative pass order and the cross-pass invariants are in [Pipeline.md](Pipeline.md).

## Documents

### Front end

| Document | Contents |
|---|---|
| [Pipeline.md](Pipeline.md) | Compilation phases, Sema pass order, phase barriers, invariants |
| [Lexing.md](Lexing.md) | Source files, tokens, keywords, literals, preprocessor, macros |
| [Parsing.md](Parsing.md) | Parser structure, disambiguation, error recovery, AST |
| [Grammar.ebnf](Grammar.ebnf) | The grammar in EBNF, generated from the tree-sitter grammar (the parser is the authority) |

### Semantic analysis

| Document | Contents |
|---|---|
| [Imports.md](Imports.md) | Import forms, path resolution, overlays, re-exports, module pinning |
| [NameResolution.md](NameResolution.md) | Expansion, verification, name resolution, lookup rules |
| [MemberLookup.md](MemberLookup.md) | Member lookup, extensions, inheritance |
| [TypeResolution.md](TypeResolution.md) | Type resolution, redeclaration merging, late eval-if folding, chain binding |
| [ExprTyping.md](ExprTyping.md) | Expression typing, conversions, overload resolution |
| [SemanticChecks.md](SemanticChecks.md) | The check passes and effect propagation |
| [Ownership.md](Ownership.md) | Copy and move, move-only types, safe pointers |
| [Generics.md](Generics.md) | Instantiation model and registry, the monomorphization sync point |
| [Interfaces.md](Interfaces.md) | Conformance, interface algebra, associated types |

### Lowering

| Document | Contents |
|---|---|
| [Lowering.md](Lowering.md) | Lowering pass order and each pass |
| [Nullables.md](Nullables.md) | `T?` from representation to C++ |
| [Panic.md](Panic.md) | Panic model, effect sets, lowering, C++ exceptions |
| [Eval.md](Eval.md) | Compile-time evaluation |
| [ScriptMode.md](ScriptMode.md) | Top-level statements and their desugaring |
| [FormatStrings.md](FormatStrings.md) | f-string lowering and the runtime writer |

### Back end

| Document | Contents |
|---|---|
| [Codegen.md](Codegen.md) | EmitPlan, CXXSpell, InterfaceEmitter, EmitIR, templates |
| [Witnesses.md](Witnesses.md) | Calls through an interface bound |
| [Interop.md](Interop.md) | FFI imports, type mapping, clang integration, kcc |
| [Linking.md](Linking.md) | The linker driver, link jobs, sysroots |
| [LibraryFormat.md](LibraryFormat.md) | The `.klib` library format |
| [ArchiveFormat.md](ArchiveFormat.md) | The KaTAR archive format |

### Driver, tooling and infrastructure

| Document | Contents |
|---|---|
| [Driver.md](Driver.md) | Driver phases, flags, toolchain discovery, native inputs |
| [IncrementalSema.md](IncrementalSema.md) | Design: module records, declaration identity, dependency logging, the four Sema changes, phases and gate for incremental AST/Sema |
| [LanguageServer.md](LanguageServer.md) | kals: server and worker processes, `kairo_compile.json`, the snapshot format, the compiler hooks it uses |
| [Diagnostics.md](Diagnostics.md) | Diagnostic codes, the registry, rendering, clang diagnostics, fix-its |
| [BuildSystem.md](BuildSystem.md) | `build.py`, staged trees, LLVM, release packaging |
| [SelfHosting.md](SelfHosting.md) | Stages, bootstrap and the fixed-point proof, the migration rules |
| [Portability.md](Portability.md) | Targets, standards compliance, platform specifics |
| [Performance.md](Performance.md) | Benchmarks, parallel codegen, compile-time optimizations |
| [TodoMarkers.md](TodoMarkers.md) | The `TODO(<CATEGORY>)` marker kinds in the source and what resolving each means |
| [Incremental.md](Incremental.md) | Incremental compilation: interface vs object keys, global invalidation, the cache record in each object (phase 2 not implemented) |
| [Serialization.md](Serialization.md) | The serialized AST: one file's parsed tree as bytes, the format, what is rebuilt on read, the round-trip test flags |

## Language reference

The language reference is maintained on the website (https://www.kairolang.org/docs/language/) and mirrored read-only in `Docs/`. Spec documents refer to its pages by name; this table is the single place that maps a name to its file.

| Page | File |
|---|---|
| primitives, conversion classes | `primitives.mdx`, `conversion-lattice.mdx` |
| variables | `variables.mdx` |
| pointers | `pointers.mdx` |
| unsafe | `unsafe.mdx` |
| structures | `structures.mdx` |
| classes, lifecycle | `classes.mdx`, `classes-lifecycle.mdx` |
| extends | `extends.mdx` |
| closures | `closures.mdx` |
| functions, parameter modes | `functions-parameter-modes.mdx` |
| requires, where | `requires.mdx`, `where.mdx` |
| nullables | `nullables.mdx` |
| panic | `panic.mdx` |
| C++ exceptions | `c-cpp-exceptions.mdx` |
| eval | `eval.mdx` |
| imports, modules, scripts | `imports.mdx`, `modules.mdx` (Scripts) |
| interfaces | `interfaces.mdx`, `interfaces-requirements.mdx` |
| generics | `generics.mdx` |
| ownership | `ownership.mdx` |
| C and C++ interop | `c-cpp.mdx`, `c-cpp-*.mdx` |
| C and C++ ABI | `c-cpp-abi.mdx` |
| diagnostics | `diagnostics.mdx` |
| macros | `macros.mdx`, `macros-builtin.mdx` |

## Former documents

Older text (tests, commit messages) cites the design notes this directory replaced. Their content now lives here:

| Former document | Now |
|---|---|
| `Compiler/Sema/RESOLUTION.md` | [Pipeline.md](Pipeline.md), with each pass in its own document; invariant numbers 1-19 are unchanged |
| `Compiler/Sema/IMPORTS.md` | [Imports.md](Imports.md), [Interop.md](Interop.md); its invariants 9-13 are [Pipeline.md](Pipeline.md#invariants) 20-26 |
| `Compiler/Codegen/CODEGEN.md` | [Codegen.md](Codegen.md), [Witnesses.md](Witnesses.md) |
| `Spec/lexer.md`, `Spec/keywords.md`, `Spec/errors.md`, `Spec/kairo.ebnf` | [Lexing.md](Lexing.md), [Diagnostics.md](Diagnostics.md#codes), [Grammar.ebnf](Grammar.ebnf) |
| `Spec/KLIB.md`, `Extras/KaTAR/KatarDoc.md` | [LibraryFormat.md](LibraryFormat.md), [ArchiveFormat.md](ArchiveFormat.md) |

## Conventions

- Paths are relative to the repository root.
- A section states what the code does today. Behaviour that is designed but not built is marked unimplemented in the sentence that describes it.
- Every fact has one home; other documents link to it.
