 Compiler
==========

 Layout
--------
Compiler/
├── Lexer/          source text -> tokens (Lexer.k; scanners: HexParser,
│                   OctalParser, Immediate; BalanceTracker; ImmBig.k: literal
│                   values past 128 bits)
├── Token/          token types, buffers, kind enums, identifier interning,
│                   the immediate-value cache (TokenCacheManager), token text
│                   (TokenText) and printing (TokenPrinter)
├── Preprocessor/   import scanning, expansion driving, scope tracking
│                   (Preprocessor.k batch driver, WaveExecutor.k the wave
│                   loop, PPWalker.k per-fid walk, DepScanner.k import-only
│                   scan, MacroTable.k, FileImportIndex.k, ScopeTracker.k;
│                   TokenSource / StreamCursor / TokenRunCursor feed the
│                   shared grammars)
├── Macro/          macro parameters and builtin sentinels
├── Resolution/     import probing, module path resolution, search roots,
│                   file extensions
├── Parser/         tokens -> AST, two-pass hoisted (ASTParse.k entry; Decl /
│   │               Expr / Stmt / Type / Pattern parse files; LexicalScope)
│   └── Shared/     grammars shared with the preprocessor (ImportGrammar,
│                   MacroHeaderGrammar)
├── Sema/           Compiler/Spec/Pipeline.md (pass spec), Compiler/Spec/Imports.md
│   │               (import/overlay model); Sema.k schedules, SemaContext.k
│   │               carries state, SemaDump.k is --print-sema
│   ├── Resolve/    name, member, type and import resolution, chain binding,
│   │               redeclaration merge, access checks
│   ├── Type/       expression typing, calls, casts, overloads, argument
│   │               deduction, substitution, panic sets
│   ├── Check/      conformance, init/move/const, purity, control flow,
│   │               patterns, effects, layout, feature gates
│   ├── Verify/     post-resolution structural checks (e.g. ModulePinCheck)
│   ├── Expand/     macro expansion, eval folding, requires / alloc desugaring
│   ├── Foreign/    C++ (ffi) decl import/export, header index
│   └── Lower/      Kairo -> core-Kairo rewrites that feed Codegen
├── Codegen/        Compiler/Spec/Codegen.md; checked tree -> tokens -> object
│   │               (EmitPlan.k, PlanVisitors.k: the plan's read-only walks;
│   │               CodegenContext.k; CodegenICE.k: ICE reports naming the
│   │               program node)
│   ├── Emit/       EmitIR (bodies), InterfaceEmitter, EmitWitness (interface
│   │               witnesses), CXXSpell (names)
│   ├── Sink/       token / text sinks (--print-cxx), TokenStreamPrinter
│   └── Backend/    CodegenBackend / CodegenAction (clang invocation), headers
│                   (EmitCXXHeader), the #include "foo.k" emitter
│                   (IncludeEmitter), InterfacePCH (per-build interface PCH)
├── AST/
│   ├── Node/       node defs + RTTI casting (isa/cast/dyn_cast via kind field)
│   ├── Kind/       discriminator enums (DeclKind, ExprKind, ...)
│   ├── Context/    ASTContext arena owner, DisambigTable (the parser's hoisted
│   │               scope table; GlobalDisambigTable the build-wide one),
│   │               symbol tables, translation unit, instantiation registry,
│   │               import overlay, canonical types
│   ├── Mixin/      shared node traits (annotation, redeclarable, qualifiers,
│   │               TemplateParams, FFILinkage)
│   ├── Visitor/    CRTP RecursiveASTVisitor, ASTWriter (structural rewrites)
│   ├── Matcher/    AST matching, position queries
│   ├── Serialize/  one file's parsed AST as bytes and back (its own module;
│   │               Compiler/Spec/Serialization.md): ASTArchive, one io_
│   │               function per node class, ASTBinWriter / ASTBinReader,
│   │               the round-trip verification behind --verify-ast-roundtrip
│   └── Printer/    tree/flat AST dump (ASTPrinter.k AstDumper; Printers.k the
│                   TypePrinter / ExprPrinter / ... / ASTPrinter entry points)
│                   Top level: shared fact tables (DeclFacts, AttrFacts,
│                   OperatorFacts, LangItems, EnumNiche, ParamMode,
│                   PrimitiveLimits, CxxReservedWords)
├── Interop/
│   └── Clang/      clang jobs for C/C++ inputs (ClangJobs), the one shared
│                   clang instance (ClangBackend), BuiltinsSet, the
│                   #include "foo.k" hook and include scan (KairoInclude,
│                   KairoIncludeScan), loc mapping (ClangLocMap); header sets
│                   (HeaderSet.k, HeaderSetCache.k) and the merged codegen
│                   PCH (CodegenPCH.k)
├── Driver/         CompilerInstance (shared resources; the class, its fields,
│                   construction, initialize and execute), split by concern
│                   into `extend CompilerInstance` files that reach its
│                   members as `prot` (module.k makes Driver/ one module):
│                   CompilerSetup (target/sysroot, backend config, the
│                   invocation), CompilerInfo (--help/--version/--explain/
│                   --print-*), CompilerGraph (input order, included .k,
│                   the incremental API), CompilerNative (runtime and C/C++
│                   inputs through clang), CompilerCache (runtime object
│                   cache, --kairo-lib), CompilerLink (outputs, the link);
│                   FrontendAction (the per-file pipeline); entry points
│                   Kairo.k (kairo) and
│                   Kcc.k (kcc), both starting through Runtime.k; input kinds
│                   (InputKinds), KairoIncludes (kcc's #include "foo.k"
│                   answer), per-TU / batch results and stages
├── Diagnostic/     engine, DiagBuilder, DiagSink (the builder's target) and
│   │               BufferedDiagSink, consumers (basic/pretty), clang
│   │               diagnostic adapter, generated Registry.k
│   └── TableGen/   *.diag.toml definitions (one per category); Registry.k is
│                   generated from them by Scripts/gen_diag.py
├── Command/        CLI flag parsing (registry, utils, parsed args), the
│                   kairo <-> clang flag translator
├── Config/         resolved CompilerInvocation + per-subsystem option structs
├── Location/       source locations, ranges, managers, line tables
├── Memory/         arena allocation, memory buffers, mmap regions
├── Threading/      thread pool, task queues, partitioning, cache-line consts
├── Support/        interning/hash helpers, assertions, limits, terminal
│   │               rendering, shell quoting, timers (Timer, TimeReport),
│   │               byte classes (Ascii), internal caps (Tuning), exit
│   │               statuses (ExitCodes)
│   └── FileIO/     Path, FileSystem, VirtualFileManager
├── Tooling/        parse API for tools (ParseAPI, ToolDiagnostics), kparse
│                   (ParseOnceTest.k), GenClangDiagIdentity.k
│                   (clang-diag-identity: lists clang's diagnostic flags for
│                   Scripts/gen_clang_diag_table.py)
├── Spec/           the compiler specification: pipeline, per-pass contracts,
│                   build system, self-hosting, incremental compilation
│                   (index: Compiler/Spec/README.md)
└── Native/         C++ interop headers (.hh) pooled, path-coupled: arenas
                    (ArenaBlock, GlobalRecycler, KPlacement), text and numbers
                    (CharTable, UTF8Decode, KInt128, KLocale), threading and
                    timing (KThread, KTimeReport, KTimeClang), Win32 calls
                    (Win32.hh/.cpp), Cc1As.hh (clang's -cc1as entry point),
                    KClangDiag.hh (questions about a clang::Diagnostic's
                    arguments), KClangPurity.hh (clang's const / pure marks
                    for FnPurityCheck), KSharedVFS.hh (a codegen TU's view of
                    the fan-out's shared in-memory file layer)

The linker (KLD) is not under Compiler/: it is ../Linker (Linker::API).

Modules and exports. Every top-level directory above that holds
.k files is one module: it has a comments-only module.k (no `module` pin, so
module paths and C++ namespaces are unchanged), and its nested directories
belong to it (Sema/Resolve is part of Sema). Compiler/ itself has no module.k.
The tree builds under the language's own visibility rule
(-fdefault-visibility=spec): an unmarked declaration is `prot`, visible to
every file of its module; `pub` marks what other modules use, i.e. the
module's API; `priv` is one file. A declaration another module needs is made
`pub` at the declaration, never by widening the default. Linker/API and
Linker/Driver are modules the same way. Note the generated full registry
(build/registry/Compiler/Diagnostic/Registry.k) compiles outside the
Diagnostic module, so what it names (DiagMeta's fields) is `pub`.

--------------------------------------------------------------------------------

 The compiler, and where it came from
---------------------------------------

This tree is the Kairo compiler (Stage 1), written in Kairo and built by
itself: since 2026-11-06 the repo is self-hosted, and `python3 build.py`
builds it with the last good release compiler (the seed). Stage 0, the old
C++ transpiler that bootstrapped it, no longer builds anything here; the
bootstrap and the seed chain are Compiler/Spec/SelfHosting.md.

Stage naming: Stage 1 is this self-hosting compiler; Stage 1.5 drops the C++
standard-library dependencies and std APIs from the compiler's own source;
Stage 2 is hardening (the safety pass, SSA).

The compiler has its own lexer, preprocessor, parser, full Sema (name
resolution, overload resolution, ADL, SFINAE, concept and conformance
checking, instance enumeration, all done Kairo-side), and a CodeGen that does
NOT emit C++ source. Many programs compile, link through KLD and run (Tests/
Codegen); a few constructs do not lower yet.
`--type-check-only` stops after Sema and is the fast loop when a change does
not touch codegen.
Panic is built end to end outside generic bodies: inferred and declared
sets, try/catch, tagged `Panic<T, ...E>` returns (every Kairo function
stays noexcept), the C++ view (`::builtin::value_or_throw`, ...) and C++
exception arms. `crash!` and every crash-family check go through one
signal-safe runtime call (Lib/rt/crash.c). The LLVM IR safety pass is
designed, not built.

CodeGen constructs an in-memory clang::Token stream located into the
original .k files, and Clang consumes it directly (via EnterTokenStream, or
the patched FileTokenizer hook). That token stream is a REDUCED subset of
C++: overload selection, specialization choice, constraint satisfaction,
all resolved Kairo-side by Sema before a token is built. Clang is not the
semantic engine. It's a lowering target: Kairo passes through Clang to
reach LLVM IR the same way Clang passes through LLVM IR to reach machine code.
Kairo owns the large backend surface above that line, instance enumeration,
ABI shaping, the safety pass; Clang is the narrow, ABI-correct interchange stage
it feeds already-resolved constructs into.

Generics: Kairo has no monomorphizer. A generic body is checked once, at its
definition, against its bounds, and emitted once, as a C++ template; Kairo
lowers generics to clang template specializations rather than custom-mangled
symbols because specializations are ABI-preserving. Sema enumerates every
instance it can see, and each has one home TU (its first namer) that emits
the explicit instantiation; every other TU using it emits `extern template`,
so Clang compiles a known instance once. What differs per instance is
selected by C++ itself (a specialization, `requires`, a `static_assert` pin),
because C++ also instantiates Kairo templates at types Kairo never sees.

Transitional: duck generics. `<T: type>` (the C++-checked regime,
Compiler/Spec/Generics.md#duck-regime) is still ON by default, because the
compiler's own source is written in it: its body is typed as written and
clang checks each instance. `-fno-duck-generics` turns it off (every `: type`
is then SC001E). Permanent removal is Compiler/Spec/Generics.md#duck-regime:
flip the default (FlagRegistry.k's help text, Config/Language.k,
SemaContext::duck_generics), then delete the regime branch (FlagGates' `: type`
gate, ChainBinding's `b.duck`, EmitIR's as-written member chain) and the flag.
Lowering stays ABI-stable with C++ throughout; Kairo stays the richer
language above that line, but the boundary is clean and stable.

The tokens live only in memory; their locations resolve to Kairo source the
whole way down, which keeps diagnostics, debug info, and the LLVM IR safety
pass anchored to one source of truth: the .k

Each stage owns one transformation and hands off; the directory layout
follows the pipeline.

  Load -> Lex -> Preprocess -> Index -> Parse -> Import Resolution
       -> Sema (KIR lowering) -> CodeGen -> Sema agreement
       -> LLVM IR safety -> Link

Built: Load, Lex, Preprocess, Index (the parser's hoisting pass), Parse,
Import Resolution, Sema, lowering, CodeGen, Link. Designed, not built: Sema
agreement, LLVM IR safety.

Index and Import Resolution are real stages, not sub-steps. C++ FFI is not
a linear stage, it's a guest invoke that fires during Index (see Pipeline 1).

--------------------------------------------------------------------------------

 Two entry points, one core
----------------------------

There are two pipelines. In both, Kairo is the driver and Clang is a guest
invoked as a library. The distinction is the entry point and which language
is the guest:


  kairo     enters on a .k translation unit. C++ is FFI:
            * kairo --------------------*
            | ffi "c++" import "foo.hh" |
            *---------------------------*
            Which invokes Clang as a guest to pull C++ symbols.
            C++ is the foreign language.


  kcc       enters on a .cc translation unit. Clang drives the C++ front
            normally until it hits:
            * kairo -----------*
            | #include "foo.k" |
            *------------------*
            Which calls into the Kairo pipeline as a library to own the
            .k span. Kairo is a re-entrant peer here, not subordinate.
            Kairo is the embedded language.


Both lean on the same Kairo-core library. Clang appears as a guest in both,
in kairo it's invoked at Index (FFI symbols) and at CodeGen (consume tokens
-> object); in kcc it's the front driver that yields the .k region.

kairo also takes every input kind clang's driver does (C, C++, ObjC/ObjC++,
preprocessed .i/.ii, LLVM IR .ll/.bc, headers -> .pch, objects and
libraries), classified by Driver/InputKinds.k or by -x <lang>. A non-.k
source is compiled by clang's own driver, run in-process
(Interop/Clang/ClangJobs.k), on the build's target and header roots, and
joins the same link. Every kairo <-> clang flag spelling, in both
directions, lives in Command/FlagTranslator.k; kcc (Driver/Kcc.k) is kairo
fed a clang command line through that file's reverse map.

--------------------------------------------------------------------------------

 Pipeline 1 - kairo (the primary compiler)
-------------------------------------------

Entry on .k. Heavily multithreaded. One file is a translation unit; every
import pulls in another TU.

    * kairo -----------------*
    |  import foo   // TU 1  |
    |  import bar   // TU 2  |
    |  // this file is TU 0  |
    *------------------------*

There is no entry file: every input is a module, named by the library
(a module.k pinning `module foo`) or search dir (the cwd, each -I) that
contains it, and `main` is the global `int main` wherever it is declared.
Each input gets one Frontend Action over the TUs it reaches. The inputs of
one build share a batch: a file reached by two inputs is built once (the
first action to reach it claims it), and an input another input imports is
run first. See Compiler/Spec/Imports.md for roots and module paths.

Per-Action pipeline (parallelism shown explicitly):

                          kairo main.k          (ONE Frontend Action)
                                |
                                v
                  *---------------------------*
                  |  Load TU0 into VFM + SM   |   Location/SourceManager
                  |  register file from VFM,  |   Memory/MappedFileBuffer
                  |  start FID index, set up  |   Support/FileIO
                  |  (FID, offset) addressing |
                  *-------------*-------------*
                                v
                  *---------------------------*
                  |  Lex TU0                  |   Lexer/Lexer.k
                  |  SIMD-optimized, fully    |   Token/TokenBuffer
                  |  UTF-8 / Unicode aware:   |
                  |  a run of CJK codepoints  |
                  |  is a valid identifier.   |
                  |  char = u32, str = u8/UTF8|
                  *-------------*-------------*
                                v
                  *---------------------------*
                  |  Preprocessor on TU0      |   Preprocessor/Preprocessor.k
                  |  walk TU0; on an import   |   Resolution/ImportProbe
                  |  line, resolve + lex the  |   Preprocessor/DepScanner
                  |  imported file and ITS    |
                  |  imports, recursively.    |
                  |  Register each as a       |
                  |  completed import. Then   |
                  |  walk from the leaves up, |
                  |  expanding scoped macros  |
                  |  correctly.               |
                  *-------------*-------------*
                                | (import graph known; fan out)
                                v
        *=================================================*
        |   INDEX  -- cheap, fully parallel over all TUs  |   Parser/ASTParse.k (hoist pass)
        |   walk each TU, pull ONLY decls + top-levels,   |   AST/Context/GlobalDisambigTable.k
        |   set correct scope info into the shared        |   AST/Context/ASTContext.k
        |   disambiguation table (thread-safe). Create an |
        |   ASTContext per TU.                            |
        |                                                 |
        |   FFI fires HERE: ffi "c++" import "foo.hh"     |   Sema/Foreign/HeaderIndex.k
        |   invokes Clang as a guest to extract C++       |   Sema/Foreign/DeclImport.k
        |   symbols for Sema.                             |
        *=================================================*
                                v
        *=================================================*
        |   PARSE  -- fully parallel over all TUs         |   Parser/ASTParse.k + *Parse.k
        |   each TU gets its formal TU classification     |   AST/Node/*
        |   (a Parser is what returns a TU). Builds the   |   Memory/ArenaAllocator (per-TU)
        |   arena-allocated Kairo AST.                    |
        *=================================================*
                                v
        *=================================================*
        |   IMPORT RESOLVER -- fully parallel over TUs    |   Resolution/*
        |   transform each import node into correctly     |   Sema/Resolve/ImportResolution.k
        |   scoped forward decls: module Foo { ..fwd.. }. |
        |   Rewrite unqualified callers to the right      |
        |   target: foo() -> Foo::foo().                  |
        *=================================================*
                                v
        *=================================================*
        |  SEMA -- per TU, in import order                |   Sema/*, Spec/Pipeline.md
        |  P -> I -> E -> V -> N -> T -> ChainBinding ->  |
        |  checks. Name + type resolution, overloads,     |
        |  conformance, init/move/const, control flow,    |
        |  patterns, eval.                                |
        |                                                 |
        |  ONE BARRIER, the Typed barrier: the import     |   Sema/Check/EffectPropagation.k
        |  graph runs in groups (one per import cycle,    |   Driver/FrontendAction.k
        |  one TU when there is none). Every TU of a      |
        |  group reaches Typed, then the build-wide       |
        |  EffectTable solves the group's inferred panic  |
        |  sets to one fixpoint; then each TU goes on to  |   Sema/Check/PanicEffectChecking.k
        |  the late checks (panic effects, eval usage,    |
        |  feature gates).                                |
        |                                                 |
        |  Lowering: Kairo's IR layer IS Kairo. Each      |   Sema/Lower/* (one pass per
        |  high-level construct is rewritten into more    |   construct; the fixed order
        |  primitive Kairo (variants, enum layout, ctor   |   is Sema.k::_stage_lowerings,
        |  init, script, panic, finally, nullable,        |   listed in Compiler/Spec/Lowering.md)
        |  operators, f-strings, iteration, match, ...).  |
        |                                                 |
        |  Mono (Compiler/Spec/Generics.md): a generic body is checked once |   AST/Context/
        |  against its bounds, never per instance. T, X   |   InstantiationRegistry.k
        |  and the reach mint instances into the build-   |   Sema/Check/
        |  wide registry's worklist; M1 drains it, and    |   ConformanceChecking.k
        |  EmitPlan homes each instance, named or reached |
        |  through a body, as a clang specialization.     |
        |  M2 (instance facts by substitution into the    |
        |  bounds: layout built; lifecycle, rows, panic   |
        |  sets open) is a Sema.k slot; until its panic   |
        |  sets land, a panicking call in a generic body  |
        |  is SC116E.                                     |
        *=================================================*
                                v
        *=================================================*
        |  CODEGEN -- always fully parallel over TUs      |   Spec/Codegen.md
        |  construct a clang::Token stream into a custom  |   Codegen/EmitPlan.k, Emit/*
        |  inline buffer; SourceLocs point into .k.       |   Codegen/Sink/TokenSink.k
        |  Invoke Clang cleanly as a guest -> object.     |   Codegen/Backend/CodegenBackend.k
        *=================================================*
                                v
        *=================================================*
        |  SEMA AGREEMENT -- parallel over TUs            |   (walk of clang's AST; not built)
        |  clang has parsed and type-checked the tokens   |
        |  CodeGen built. Walk what it produced and check |
        |  clang's Sema reached Kairo's decisions: each   |
        |  call's overload ranking and chosen callee,     |
        |  ADL candidates and ranking, conversions,       |
        |  template / specialization picked. A            |
        |  disagreement is a Kairo bug (CodeGen left      |
        |  clang a choice, or Sema ranked wrongly), so    |
        |  it is an internal error naming both answers.   |
        *=================================================*
                                v
                  *------------------------------*
                  |  LLVM IR safety pass         |   (post-Clang IR walk; not built)
                  |  Clang hands back ABI-       |
                  |  correct LLVM IR. Walk it    |
                  |  and inject safety instrs:   |
                  |  - integer overflow checks   |
                  |  - UB sanitization           |
                  |  - stack probes              |
                  |  - target-specific hardening |
                  |  - optional CFI              |
                  |  - backend-only transforms   |
                  *-------------*----------------*
                                v
                  *---------------------------*
                  |  KLD (linked as a lib)    |   ../Linker (Linker::API)
                  |  linking + completion,    |
                  |  Kairo demangling, Kairo  |
                  |  diagnostic integration.  |
                  *-------------*-------------*
                                v
                 Binary | .klib | ELF/MachO/PE object

--------------------------------------------------------------------------------

 FFI note - C++ headers, parsed once (mostly)
---------------------------------------------

Every header set (one file's ffi headers) is parsed by Clang once in
phase A (Interop/Clang/HeaderSet.k):

  1. Phase A, on the thread pool while the importer parses: clang parses
     the set and keeps its ASTContext and Sema alive, and writes an
     in-memory PCH. Sema/Foreign/HeaderIndex.k walks that AST to give
     Kairo Sema the C++ symbols it resolves and type-checks against.
  2. Phase B, CodeGen: the backend loads that PCH instead of re-parsing,
     so emission starts from phase A's AST
     (Codegen/Backend/CodegenBackend.k).

LIMITATION, the common case today: a clang TU takes ONE PCH. A Kairo TU's
codegen gets every header set in its import graph; the first (its own,
when it has one) is the PCH, and every other set's headers are #included
textually and parsed again, in every TU's backend run. builtin alone has
two sets (coro/generator.k's <coroutine>, fmt/fmt_buf.k's rt/fmt.h), so
every program pays it. Measured on a one-file program importing <vector>:
phase B reopens all three sets' headers, sub-headers included, and the backend's own time
(~1.3s over 6 TUs) dwarfs phase A's three set builds (~0.37s).

--------------------------------------------------------------------------------

 Pipeline 2 - kcc (Clang-fronted, .k embedded via patched Clang)
-----------------------------------------------------------------

kcc (Driver/Kcc.k) is a clang/clang++ drop-in: it translates a clang
command line into kairo's words (FlagTranslator::from_driver) and runs the
same CompilerInstance as kairo, so `kcc -c x.cc`, `kcc main.cc foo.k -o app`
and `kcc x.o y.o` behave as with clang. `-c` writes objects for the command
line's own files only; a link takes builtin, std and the runtime from the
toolchain's cached library (--kairo-lib). A C++ input's `#include "foo.k"`
files are found before the compile (Interop/Clang/KairoIncludeScan.k) and
built as modules beside it (foo.cc + foo.k -> foo.o + foo.k.o).

Entry on .cc. Clang drives the C++ TU normally. The patch adds a third
lexer-content mode: when EnterSourceFile builds a Lexer for a FileID, it
consults Preprocessor::FileTokenizerHook. If the hook returns a token vector
for that file, the Lexer yields those tokens (CLK_PrebuiltTokenLexer /
Lexer::LexPrebuiltToken) instead of lexing the buffer, and on exhaustion
routes through HandleEndOfFile so the include stack pops normally.

Consequence: #include "foo.k" traverses the NORMAL include path. It works
inside *if, mid-function, anywhere, full preprocessor fidelity. Locations
are native into the real foo.k FileID: column-accurate, no *line, no source
map, no proxy file.

                     kcc foo.cc
                         |
                         v
              *-----------------------*
              |  Clang front (normal) |   patched kairolang/llvm-project
              |  drives the .cc TU    |   (kairo-llvm-22.1.0 branch)
              *-----------*-----------*
                          |  on  #include "foo.k"
                          v
              *-------------------------------*
              |  FileTokenizer hook fires     |   Lexer::LexPrebuiltToken
              |  name ends with .k -> yield   |   CLK_PrebuiltTokenLexer
              |  prebuilt Kairo token vector  |
              *---------------*---------------*
                          |  calls into Kairo-core as a lib
                          v
              *-------------------------------*
              |  Kairo pipeline (as a lib)    |   same core as Pipeline 1:
              |  lex/pp/parse/sema the .k     |   Interop/Clang/KairoInclude.k
              |  region; construct clang::    |   Codegen/Backend/IncludeEmitter.k
              |  Tokens located into foo.k    |
              *---------------*---------------*
                          |  tokens handed back to the hook
                          v
              *--------------------------------*
              |  Clang resumes                 |   include stack pops via
              |  consumes the .k tokens as if  |   HandleEndOfFile
              |  part of the TU, continues .cc |
              *---------------*----------------*
                              v
               Clang Codegen -> object -> link

Token-construction model is identical to Pipeline 1's CodeGen: tokens in
memory, located into .k. The only difference is who asked for them, here
it's Clang's include machinery via the hook, not a standalone Frontend Action.
What the include yields is foo's interface (pub decls, plus the inline and
template bodies a C++ consumer compiles itself); foo's own bodies are in
foo.k.o (Compiler/Spec/Codegen.md#pipeline, EmitPlan(Include)).

--------------------------------------------------------------------------------

 Notes
-------

Resolution is import/path resolution (finding files); name resolution lives
in Sema. Different stages despite the similar name.

Sema/ currently holds two responsibilities of different shapes: analysis
(decide: type checking, inference, resolution, constraint checking) and
lowering (rewrite: desugar high-level constructs into primitive Kairo). They
are merged today and the surface is large. This is a known seam, not a design
choice: analysis decides, lowering rewrites, and the two will want splitting
as the folder grows.


Native/ headers are pooled rather than co-located because their #include
paths are relative and mutually dependent; -I does not reach them.

Native/ is plain C++ on the C++ standard library. Every header includes
Native/KPrelude.hh. KAIRO_NATIVE_STAGE0 there is the one switch between the
two worlds a header can be compiled in: with lib-helix's core.hh
force-included (the retired Stage 0 build) or with nothing but the C++
standard library (today's build). Only the second world is built now; what
sits behind the switch is leftover Stage 0 code (lib-helix's string, null_t,
std::Function, the print family) pending removal. Text parameters are templates
over native::bytes, so one signature takes either world's string.

--------------------------------------------------------------------------------

 Build
-------

  python3 build.py --debug kairo kcc     (from the repo root; the edit/test loop)
  python3 build.py --release kairo kcc   (the release pipeline)

build.py is the build of record (its module docstring and `--help` are
authoritative; Compiler/Spec/BuildSystem.md is the spec). kbld and build.k
drive Stage 0 and cannot build this tree. Targets: kairo, kcc, kld, kparse,
katar, clang-diag-identity (default kairo; `--print-jobs` shows the clang
jobs and the link without building).

  --debug    build/<triple>/debug, built by the newest staged release
             compiler (--kairo names another seed), with a permanent cache
             build/<triple>/cache/debug.
  --release  the two-stage pipeline: snapshot build/<triple>/release to
             build/<triple>/N-1 (the backup and the seed), N-1 builds kairo
             alone into build/<triple>/staging, staging builds the toolchain
             into build/<triple>/release, then the PATH entries for kairo and
             kcc are pointed at it (--no-path skips that). A failure restores
             release/ from N-1 and exits nonzero. <triple> is e.g.
             x86_64-linux-musl.

Every build writes the diagnostic registry first: Scripts/gen_diag.py reads
Diagnostic/TableGen/*.diag.toml, emits Diagnostic/Registry.k (generated, never
edited) and the registry object build/registry, which is linked into every
tool and so references no compiler-module symbol (TableGen/README says
why). Never rebuild a compiler
binary while a compile is running from it.

Both end with a post-build hook that turns build/<triple>/<mode> into a
self-contained toolchain:

  Scripts/stage_tree.py <tree>   bin/: clang-<ver> (+ clang, clang++,
                                 clang-cpp, clang-cl), lld (+ ld.lld,
                                 ld64.lld, lld-link, wasm-ld), llvm-nm,
                                 llvm-objdump -- whatever build/llvm/bin has
                                 of the list in the script.
                                 lib/: clang/<ver> (the resource dir),
                                 builtin, std, rt (Lib/'s trees).
                                 debug: builtin/std/rt are symlinks into Lib/
                                 (always current); release: copies.
                                 Then bundles it: copies non-system shared
                                 libs in and makes every search path
                                 relative to the binary (Linux: patchelf ->
                                 $ORIGIN RUNPATH; macOS: install_name_tool ->
                                 @rpath + @loader_path, re-signed; Windows:
                                 DLLs beside the exe), and fails unless the
                                 tree is relocatable (no dangling links,
                                 unresolved deps or absolute search paths).
                                 Prints the glibc floor on Linux.
                                 --no-bundle stages only.

By hand: `python3 Scripts/stage_tree.py --all` stages and bundles debug and
release.

A staged tree runs with no root flags:

  build/x86_64-linux-musl/debug/bin/kairo main.k -o main

Without --resource-dir / --builtins-dir / --std-dir the driver takes
<exe>/../lib/clang/<ver>, <exe>/../lib/builtin and <exe>/../lib/std
(CompilerInstance::_discover_roots); a flag always wins. Each root it cannot
find is a P001W naming the path searched and the flag; so is having no
sysroot (none given, no <exe>/../sysroot/<target>) unless --freestanding.
lit passes every root explicitly.
