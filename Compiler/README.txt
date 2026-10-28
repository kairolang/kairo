 Compiler
==========

 Layout
--------
Compiler/
├── Lexer/          source text -> tokens (scanners: hex, octal, immediate)
├── Token/          token types, buffers, kind enums, identifier interning
├── Preprocessor/   import scanning, expansion driving, scope tracking
├── Macro/          macro definitions, collection, expansion, builtin sentinels
├── Resolution/     import probing, module path resolution, search roots
├── Parser/         tokens -> AST, two-pass hoisted (decl/expr/stmt/type/pattern)
├── Sema/           RESOLUTION.md (pass spec), IMPORTS.md (import/overlay model)
│   ├── Resolve/    name, member, type and import resolution, chain binding
│   ├── Type/       expression typing, calls, casts, argument deduction
│   ├── Check/      conformance, init/move/const, control flow, patterns
│   ├── Verify/     post-resolution checks (e.g. ModulePinCheck)
│   ├── Expand/     macro expansion, eval, requires desugaring
│   ├── Foreign/    C++ (ffi) decl import/export, header index
│   └── Lower/      Kairo -> core-Kairo rewrites that feed Codegen
├── Codegen/        CODEGEN.md; checked tree -> tokens -> object
│   ├── Emit/       EmitIR (bodies), InterfaceEmitter, CXXSpell (names)
│   ├── Sink/       token / text sinks (--print-cxx)
│   └── Backend/    clang invocation, headers, #include "foo.k" emitter
├── AST/
│   ├── Node/       node defs + RTTI casting (isa/cast/dyn_cast via kind field)
│   ├── Kind/       discriminator enums (DeclKind, ExprKind, ...)
│   ├── Context/    ASTContext arena owner, symbol tables, translation unit,
│   │               instantiation registry
│   ├── Mixin/      shared node traits (annotation, redeclarable, qualifiers)
│   ├── Visitor/    CRTP RecursiveASTVisitor
│   ├── Matcher/    AST matching, position queries
│   └── Printer/    tree/flat AST dump
├── Interop/
│   └── Clang/      clang jobs for C/C++ inputs, the codegen backend, the
│                   #include "foo.k" hook and include scan, loc mapping
├── Driver/         CompilerInstance; entry points Kairo.k (kairo), Kcc.k
│                   (kcc), KairoWatch.k (kwatch); input kinds
├── Diagnostic/     engine, consumers (basic/pretty)
│   └──TableGen/    diagnostic registry, --explain, *.diag.toml files
├── Command/        CLI flag parsing (registry, utils, parsed args)
├── Config/         resolved CompilerInvocation + per-subsystem option structs
├── Location/       source locations, ranges, managers, line tables
├── Memory/         arena allocation, memory buffers, mmap regions
├── Threading/      thread pool, task queues, partitioning, cache-line consts
├── Support/        interning, file IO, terminal rendering, misc primitives
├── Tooling/        parse API for tools, kparse / kparsebench
└── Native/         C++ interop headers (.hh) pooled, path-coupled

The linker (KLD) is not under Compiler/: it is ../Linker (Linker::API).

--------------------------------------------------------------------------------

 Stage 0 vs Stage 1
--------------------

Stage 1 compiler: self-hosted, written in Kairo. This tree is Stage 1.

Stage 0 and Stage 1 are different compilers, not two versions of one. Do
not carry assumptions from one to the other.

  Stage 0 - the current shipping compiler, written in C++. A transpiler:
  it parses every file and import, has NO semantic analysis, and codegens
  the entire program into one mono C++ file that it dumps to disk and hands
  to a C++ compiler. It compiles all ~65k lines of Stage 1 today. Stage 1
  does not yet compile itself.

  Stage 1 - a real compiler. Own lexer, preprocessor, parser, full Sema
  (name resolution, overload resolution, ADL, SFINAE, concept and conformance
  checking, instance enumeration, all done Kairo-side), and a CodeGen that
  does NOT emit C++ source.

BUILD STATE: lexer, preprocessor, parser, import resolution and Sema's name
and type resolution are complete (`--type-check-only` is the dependable
loop). Lowering and CodeGen are in progress: many programs compile, link
through KLD and run (Tests/Codegen), but not every construct lowers yet.
Panic is built end to end outside generic bodies: inferred and declared
sets, try/catch, tagged `Panic<T, ...E>` returns (every Kairo function
stays noexcept), the C++ view (`::builtin::value_or_throw`, ...) and C++
exception arms. `crash!` and every crash-family check go through one
signal-safe runtime call (Lib/rt/crash.c). The LLVM IR safety pass is
designed, not built.

Stage 1 CodeGen constructs an in-memory clang::Token stream located into the
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

Transitional: duck generics. `<T: type>` (the C++-checked regime, MONO.md
D1) is ON by default until the compiler hosts itself, because the bootstrap
corpus is written in it: its body is typed as written and clang checks each
instance. `-fno-duck-generics` turns it off (every `: type` is then SC001E).
Permanent removal is MONO.md G14: flip the default (FlagRegistry.k's help
text, Config/Language.k, SemaContext::duck_generics), then delete the regime
branch (FlagGates' `: type` gate, ChainBinding's `b.duck`, EmitIR's
as-written member chain) and the flag.
Lowering stays ABI-stable with C++ throughout; Kairo stays the richer
language above that line, but the boundary is clean and stable.

The tokens live only in memory; their locations resolve to Kairo source the
whole way down, which keeps diagnostics, debug info, and the LLVM IR safety
pass anchored to one source of truth: the .k

Each stage owns one transformation and hands off; the directory layout
follows the pipeline.

  Load -> Lex -> Preprocess -> Index -> Parse -> Import Resolution
       -> Sema (KairoIR lowering) -> CodeGen -> Sema agreement
       -> LLVM IR safety -> Link

Built: Load, Lex, Preprocess, Index (the parser's hoisting pass), Parse,
Import Resolution, Sema. In progress: lowering, CodeGen, Link. Designed,
not built: Sema agreement, LLVM IR safety.

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
run first. See Sema/IMPORTS.md for roots and module paths.

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
        |  SEMA -- per TU, in import order                |   Sema/*, Sema/RESOLUTION.md
        |  P -> I -> E -> V -> N -> T -> ChainBinding ->  |
        |  checks. Name + type resolution, overloads,     |
        |  conformance, init/move/const, control flow,    |
        |  patterns, eval.                                |
        |                                                 |
        |  ONE BARRIER, the Typed barrier: the import     |   Sema/Check/EffectPropagation.k
        |  graph runs in groups (one per import cycle,    |   Driver/CompilerInstance.k
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
        |  init, script, panic, finally, nullable,        |   listed in RESOLUTION.md §2.10)
        |  operators, f-strings, iteration, match, ...).  |
        |                                                 |
        |  Mono (MONO.md): a generic body is checked once |   AST/Context/
        |  against its bounds, never per instance. T, X   |   InstantiationRegistry.k
        |  and the reach mint instances into the build-   |   Sema/Check/
        |  wide registry's worklist; M1 drains it, and    |   ConformanceChecking.k
        |  EmitPlan homes each instance, named or reached |
        |  through a body, as a clang specialization.     |
        |  M2 (instance facts by substitution into the    |
        |  bounds: layout built; lifecycle, rows, panic   |
        |  sets open) is a Sema.k slot; until P10, a      |
        |  panicking call in a generic body is SC116E.    |
        *=================================================*
                                v
        *=================================================*
        |  CODEGEN -- always fully parallel over TUs      |   Codegen/CODEGEN.md
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
two sets (types.k's <coroutine>, fmt.k's rt/fmt.h), so every program pays
it. Measured on a one-file program importing <vector>: phase B reopens
all three sets' headers, sub-headers included, and the backend's own time
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
foo.k.o (CODEGEN.md §1, EmitPlan(Include)).

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
paths are relative and mutually dependent; -I does not currently reach them.
(stage0 limitation)

--------------------------------------------------------------------------------

 Build
-------

  kbld kairo --debug     (from the repo root)
  kbld kcc --debug       (when Driver/ or anything kcc links changes)

Both end with a post-build hook (build.k) that turns build/<triple>/<mode>
into a self-contained toolchain:

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

  build/x86_64-linux-gnu/debug/bin/kairo main.k -o main

Without --resource-dir / --builtins-dir / --std-dir the driver takes
<exe>/../lib/clang/<ver>, <exe>/../lib/builtin and <exe>/../lib/std
(CompilerInstance::_discover_roots); a flag always wins. Each root it cannot
find is a P001W naming the path searched and the flag; so is having no
sysroot (none given, no <exe>/../sysroot/<target>) unless --freestanding.
lit still passes every root explicitly.

Stage 0 compiles all of Stage 1. Stage 1 does not yet compile itself.
