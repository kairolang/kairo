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
├── Sema/           type checking, inference, lowering passes, monomorphization
├── AST/
│   ├── Node/       node defs + RTTI casting (isa/cast/dyn_cast via kind field)
│   ├── Kind/       discriminator enums (DeclKind, ExprKind, ...)
│   ├── Context/    ASTContext arena owner, hoisted scope, translation unit
│   ├── Mixin/      shared node traits (annotation, redeclarable, qualifiers)
│   ├── Visitor/    CRTP RecursiveASTVisitor
│   ├── Matcher/    AST matching, position queries
│   └── Printer/    tree/flat AST dump
├── Interop/
│   └── Clang/      C++ symbol extraction (FFI), token injection into Clang SourceManager
├── Driver/         per-TU orchestration, batch results, pipeline stages
├── Diagnostic/     engine, consumers (basic/pretty)
│   └──TableGen/    diagnostic registry, --explain, *.diag.toml files
├── Command/        CLI flag parsing (registry, utils, parsed args)
├── Config/         resolved CompilerInvocation + per-subsystem option structs
├── Location/       source locations, ranges, managers, line tables
├── Memory/         arena allocation, memory buffers, mmap regions
├── Threading/      thread pool, task queues, partitioning, cache-line consts
├── Support/        interning, file IO, terminal rendering, misc primitives
└── Native/         C++ interop headers (.hh) pooled, path-coupled

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
  checking, monomorphization, all done Kairo-side), and a CodeGen that does
  NOT emit C++ source.

BUILD STATE: complete through the parser. Lexer, preprocessor, and parser
work. Everything downstream, Index, Import Resolution, Sema, CodeGen, the
LLVM IR safety pass, and KLD linking, is designed but not yet implemented.
The pipeline and stages described below are the intended architecture, not
running code. Treat anything past Parse as a spec until the source says
otherwise.

Stage 1 CodeGen constructs an in-memory clang::Token stream located into the
original .k files, and Clang consumes it directly (via EnterTokenStream, or
the patched FileTokenizer hook). That token stream is a REDUCED subset of
C++: overload selection, specialization choice, constraint satisfaction,
all resolved Kairo-side by Sema before a token is built. Clang is not the
semantic engine. It's a lowering target: Kairo passes through Clang to
reach LLVM IR the same way Clang passes through LLVM IR to reach machine code.
Kairo owns the large backend surface above that line, monomorphization, ABI
shaping, the safety pass; Clang is the narrow, ABI-correct interchange stage
it feeds already-resolved constructs into.

Monomorphization: Kairo lowers generics to clang template specializations
rather than custom-mangled symbols because specializations are ABI-preserving.
The TU owning a generic's definition emits the specialization; every other TU
using it emits `extern template`, so Clang does not re-instantiate what Sema
already monomorphized. Lowering stays ABI-stable with C++ throughout; Kairo
stays the richer language above that line, but the boundary is clean and stable.

The tokens live only in memory; their locations resolve to Kairo source the
whole way down, which keeps diagnostics, debug info, and the LLVM IR safety
pass anchored to one source of truth: the .k

Each stage owns one transformation and hands off; the directory layout
follows the pipeline.

  Load -> Lex -> Preprocess -> Index -> Parse -> Import Resolution
       -> Sema (KairoIR lowering) -> CodeGen -> LLVM IR safety -> Link

Built today: Load, Lex, Preprocess, Parse. Designed but not implemented:
Index, Import Resolution, Sema, CodeGen, LLVM IR safety, Link. (Index is
drawn before Parse because it hoists decls pre-parse; it is not built yet.)

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

TU 0 must be main-like (a program entry point) or a library target (compiled
to an object / .klib). All TUs reachable from one root form ONE Frontend
Action. `kairo main1.k main2.k` launches two Frontend Actions running fully
in parallel, separate TU graphs, separate thread fan-out, separate objects.

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
        |   INDEX  -- cheap, fully parallel over all TUs  |   AST/Context/ASTIndex.k
        |   walk each TU, pull ONLY decls + top-levels,   |   AST/Context/GlobalHoistedScope.k
        |   set correct scope info into the shared        |   AST/Context/ASTContext.k
        |   GlobalHoistedScope (thread-safe). Create an   |
        |   ASTContext per TU.                            |
        |                                                 |
        |   FFI fires HERE: ffi "c++" import "foo.hh"     |   Interop/Clang/ClangBridge.k
        |   invokes Clang as a guest to extract C++       |   Interop/Clang/ClangBridgeImpl.hh
        |   symbols into the GlobalHoistedScope.          |
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
        |   transform each import node into correctly     |   Sema/ImportResolution.k
        |   scoped forward decls: module Foo { ..fwd.. }. |
        |   Rewrite unqualified callers to the right      |
        |   target: foo() -> Foo::foo().                  |
        *=================================================*
                                v
        *=================================================*
        |  SEMA -- mostly parallel; some passes converge  |   Sema/*
        |  type resolution, trait/conformance checking,   |
        |  generic instantiation, AMT borrow checking,    |
        |  Code expansion. Kairo's IR layer IS Kairo:     |
        |  every high-level construct lowers into more    |   Sema/MatchLowering,
        |  primitive Kairo constructs (match, nullable,   |   NullableTypeLowering,
        |  panic, finally, operators, ...).               |   PanicLowering, OperatorLowering
        |                                                 |
        |  Most passes fan out. Some will need a          |   Sema/Monomorphization.k
        |  convergence barrier -- monomorphization is     |
        |  designed as 2-pass (pass 1 converges across    |
        |  TUs before pass 2). Barrier set not yet        |
        |  settled; passes are still landing.             |
        *=================================================*
                                v
        *=================================================*
        |  CODEGEN -- always fully parallel over TUs     |   Token/TokenSpan, Token/Token.k
        |  construct a clang::Token stream into a custom |   Interop/Clang/SourceLocTranslator.k
        |  inline buffer; SourceLocs point into .k.      |   AST/Printer
        |  Invoke Clang cleanly as a guest -> object.    |
        *=================================================*
                                v
                  *----------------------------*
                  |  LLVM IR safety pass       |   (post-Clang IR walk)
                  |  Clang hands back ABI-     |
                  |  correct LLVM IR. Walk it  |
                  |  and inject safety instrs: |
                  |  null checks, overflow /   |
                  |  underflow guards.         |
                  *-------------*--------------*
                                v
                  *---------------------------*
                  |  KLD (linked as a lib)    |   Driver/
                  |  linking + completion,    |
                  |  Kairo demangling, Kairo  |
                  |  diagnostic integration.  |
                  *-------------*-------------*
                                v
                 Binary | .klib | ELF/MachO/PE object

--------------------------------------------------------------------------------

 FFI note - the C++ gets parsed twice
--------------------------------------

C++ headers are parsed by Clang TWICE per build:

  1. At Index, to pull C++ symbols into the GlobalHoistedScope so Kairo
     Sema can resolve and type-check against them.
  2. After CodeGen, when -include brings the header back in as Clang
     consumes the injected token stream and lowers to LLVM IR.

Both passes are currently full reparses via a RecursiveASTVisitor
(Interop/Clang/ClangBridge.k, ClangBridgeImpl.hh). That's the current state:
correct, but redundant, the Index pass walks the whole AST when, for hoisting,
it mostly needs names and scopes.

Planned: collapse the Index-time pass to a lighter token walker that pulls
symbol + scope without building/walking a full Clang AST, keeping the full
RAV only where a symbol's shape (member layout, template signatures, overload
sets) is load-bearing for Sema. Not done yet, don't code against it.

--------------------------------------------------------------------------------

 Pipeline 2 - kcc (Clang-fronted, .k embedded via patched Clang)
-----------------------------------------------------------------

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
              |  lex/pp/parse/sema the .k     |   Lexer, Preprocessor, Parser, Sema
              |  region; construct clang::    |   Token/, AST/Printer
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

  kbld kairo --debug     (from the kairo/ root)

Stage 0 compiles all of Stage 1. Stage 1 does not yet compile itself.