 Compiler
==========

 Layout
--------
Compiler/
├── Lexer/          source text -> tokens (Lexer.k; Immediate: literal
│                   records and the escape table; UnicodeTables: generated
│                   XID / White_Space ranges; BalanceTracker; ImmBig.k: wide
│                   literal arithmetic, Int128 / ImmBigInt / ImmBigFloat)
├── Token/          token types and kind enums (Token, TokenKind), buffers and
│                   windows over them (TokenBuffer, TokenSpan), an identifier's
│                   SymbolID with its token (IdentifierToken), the
│                   immediate-value cache (TokenCacheManager), token text
│                   (TokenText) and printing (TokenPrinter)
├── Preprocessor/   import scanning, expansion driving, scope tracking
│                   (Preprocessor.k batch driver, WaveExecutor.k the wave
│                   loop, PPWalker.k per-fid walk, DepScanner.k import-only
│                   scan, MacroTable.k, FileImportIndex.k, ScopeTracker.k,
│                   PreprocessorSymbolTable.k identifier interning;
│                   TokenSource / StreamCursor / TokenRunCursor feed the
│                   shared grammars)
├── Macro/          macro parameters and builtin sentinels
├── Resolution/     import probing, module path resolution, search roots,
│                   file extensions, the lazily scanned directory tree
│                   (DirEntry)
├── Parser/         tokens -> AST, two-pass hoisted (ASTParse.k entry; Decl /
│   │               Expr / Stmt / Type / Pattern parse files; LexicalScope)
│   └── Shared/     grammars shared with the preprocessor (ImportGrammar,
│                   MacroHeaderGrammar)
├── Sema/           Compiler/Spec/Pipeline.md (pass spec), Compiler/Spec/Imports.md
│   │               (import/overlay model); Sema.k schedules, SemaContext.k
│   │               carries state, SemaDump.k is --print-sema
│   ├── Resolve/    name, member, type and import resolution, chain binding,
│   │               redeclaration merge, access checks
│   ├── Type/       expression typing, calls, casts, conversions, overloads,
│   │               argument deduction, substitution, nullness flow, panic sets
│   ├── Check/      conformance, lifecycle, init/move, purity, control flow,
│   │               patterns, effects, local disposition (union storage for
│   │               locals a finally() ends early), feature gates
│   ├── Verify/     structural checks between expansion and name resolution
│   │               (arm order, labels, loop context, pattern bindings, C++
│   │               names, module pins)
│   ├── Expand/     eval-if folding, primitive-limit / alloc / requires
│   │               desugaring (MacroExpansion.k is a stub)
│   ├── Foreign/    C++ (ffi) decls in and out: header index, decl/type
│   │               import and export, clang-filled template instances and
│   │               the C++ body walk for moves (ForeignInstantiate)
│   ├── Incremental/ incremental Sema: declaration identities, interface
│   │               hashes and dependency rows (Facts), the invalidation
│   │               rules (Plan), taking re-checked files back out of the
│   │               instantiation registry (Retract)
│   └── Lower/      Kairo -> core-Kairo rewrites that feed Codegen
├── Codegen/        Compiler/Spec/Codegen.md; checked tree -> tokens -> object.
│   │               What every part shares lives here: the codegen context
│   │               (CodegenContext), ICE reports naming the program node
│   │               (CodegenICE), the builtin-operator forms on a type C++
│   │               decides (WrapForms). A large class (the plan, an
│   │               emitter, the speller) spans files, one `extend` per
│   │               concern, listed in its head file's header
│   ├── Plan/       the emit plan (EmitPlan.k is the class) and the read-only
│   │               tree walks it and the body emitter run (Visitors)
│   ├── Spell/      the one C++ speller (Spell.k is the class): types,
│   │               names, namespaces, constraints, record spellings
│   ├── Interface/  declarations: InterfaceEmitter.k writes a plan as C++
│   │               declarations; Witness.k the interface witnesses
│   ├── Emit/       bodies: EmitIR.k is the class, one file per concern
│   ├── Sink/       what the emitters write through: located clang tokens,
│   │               text (--print-cxx, headers), the object cache's hash; the
│   │               token stream printer
│   └── Backend/    the clang invocation per TU, C++ headers (--emit-headers),
│                   the #include "foo.k" emitter, the program's interface PCH
├── AST/
│   ├── Node/       node defs + RTTI casting (isa/cast/dyn_cast via kind
│   │               field); CanonicalNodes: BuiltinType and RecordType, the
│   │               two type nodes only the canonical store makes
│   ├── Kind/       discriminator enums (DeclKind, ExprKind, ...)
│   ├── Context/    ASTContext arena owner, DisambigTable (the parser's hoisted
│   │               scope table; GlobalDisambigTable the build-wide one),
│   │               DeclContext, symbol tables, translation unit, instantiation
│   │               registry, import overlay, canonical types, the records
│   │               tuples are (TupleRecords), the per-TU dependency log for
│   │               incremental Sema (DepLog)
│   ├── Mixin/      shared node traits (annotation, redeclarable, qualifiers,
│   │               TemplateParams, FFILinkage)
│   ├── Visitor/    CRTP RecursiveASTVisitor, ASTWriter (structural rewrites)
│   ├── Matcher/    AST matching, position queries
│   ├── Serialize/  one file's parsed AST as bytes and back (its own module;
│   │               Compiler/Spec/Serialization.md): ASTArchive, one io_
│   │               function per node class, ASTBinWriter / ASTBinReader,
│   │               AST_FORMAT_VERSION (Format.k), and ASTRoundTrip behind
│   │               --verify-ast-roundtrip / --ast-roundtrip
│   └── Printer/    tree/flat AST dump (ASTPrinter.k AstDumper; PrintCore.k
│                   the shared styles; Printers.k the TypePrinter /
│                   ExprPrinter / ... / ASTPrinter entry points)
│                   Top level: shared fact tables (DeclFacts, AttrFacts,
│                   OperatorFacts, LangItems, EnumNiche, ParamMode,
│                   PrimitiveLimits, ForeignReservedWords, VisibilityFacts),
│                   FrozenList (ASTSupport), the completion callback the
│                   parser calls (CodeCompleteConsumer)
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
│                   cache, --kairo-lib), CompilerLink (outputs, the link),
│                   CompilerRecovery (--check-past-syntax-errors);
│                   FrontendAction (the per-file pipeline); entry points
│                   Kairo.k (kairo) and Kcc.k (kcc), both starting through
│                   Runtime.k; input kinds (InputKinds), KairoIncludes
│                   (kcc's #include "foo.k" answer), the incremental object
│                   cache (ObjectCache) and per-module Sema records
│                   (ModuleRecords) with the words they share (CacheFormat),
│                   build progress (Progress), per-TU / batch results and
│                   stages
├── Diagnostic/     engine, DiagBuilder, DiagSink (the builder's target) and
│   │               BufferedDiagSink, consumers (basic, which also writes
│   │               --error-format=json lines; pretty), per-file diagnostics
│   │               for tools (FileDiagnostics), shared note wordings
│   │               (NoteText), clang diagnostic adapter, generated
│   │               Registry.k and ClangDiagLookup.k
│   └── TableGen/   *.diag.toml definitions (one per category); Registry.k is
│                   generated from them by Scripts/gen_diag.py (TableGen/README)
├── Command/        CLI flag parsing (registry, utils, parsed args), the
│                   kairo <-> clang flag translator
├── Config/         resolved CompilerInvocation + per-subsystem option structs,
│                   the toolchain's directory layout (ResourceLayout)
├── Location/       source locations, ranges, managers, line tables
├── Memory/         arena allocation, memory buffers, mmap regions
├── Threading/      thread pool, task queues, partitioning, cache-line consts
├── Support/        the compile-time string hash (EvalHash), assertions,
│   │               limits, terminal rendering, shell quoting, timers (Timer,
│   │               TimeReport), byte classes (Ascii), UTF-8 iteration
│   │               (UTF8View), bit sets over enums (FlagSet), internal caps
│   │               (Tuning), exit statuses (ExitCodes)
│   └── FileIO/     Path, FileSystem, VirtualFileManager
├── Tooling/        the compiler as a library: parse API for tools (ParseAPI,
│                   ToolDiagnostics), Sema's checked tree for a tool
│                   (SemaObserver), the live check a long-running process
│                   drives (LiveCheck) and its test mode --incr-replay
│                   (IncrReplay), kparse (ParseOnceTest.k), kunit
│                   (UnitTests.k: runs the modules' own Test() functions),
│                   GenClangDiagIdentity.k (clang-diag-identity: lists
│                   clang's diagnostic flags for Scripts/gen_clang_diag_table.py)
├── Spec/           the compiler specification: pipeline, per-pass contracts,
│                   build system, self-hosting, incremental compilation
│                   (index: Compiler/Spec/README.md)
└── Native/         the base layer under the compiler, a module (module.k).
                    Kairo: character tables and UTF-8 decoding (CharTable,
                    UTF8Decode), arenas (ArenaBlock, GlobalRecycler), Int128,
                    Locale, Thread, timing and progress (TimeReport,
                    ClangTime, Progress), the object cache's hashing
                    (ObjCache), SharedVFS (a codegen TU's view of the
                    fan-out's shared in-memory file layer), ClangDiag,
                    ClangPurity, ClangEnableIf (a C++ function's enable_if
                    conditions, for overload resolution), ClangMoveWalk
                    (whether a C++ function's body moves out of a reference
                    parameter, for MoveCheck), and
                    the plain parts of Shims and Types. C++ (.hh), for what
                    Kairo cannot spell: Prelude, Types, SmallFunction, Shims,
                    TokenArray, Placement, AddrRanges, Log, the rest of
                    Thread, ArenaBlock and Int128, FileSystem, Cc1As.hh
                    (clang's -cc1as entry point), ClangSemaAgree, and the
                    Win32 calls (Win32.hh/.cpp)

The toolchain's other tools are outside Compiler/, built from the same tree
by build.py:

  kld    ../Linker/Driver/kld.k              the linker driver
  ksys   ../Linker/Sysroot/Driver/ksys.k     sysroot generation and validation
  kfmt   ../Extras/Formatter/Driver/kfmt.k   the formatter
  kals   ../Analyzer/Driver/kals.k           the language server

The linker layer kairo links through is ../Linker/API, imported as
API::.

Modules and exports. Every top-level directory above that holds
.k files is one module: it has a comments-only module.k (no `module` pin, so
module paths and C++ namespaces are unchanged), and its nested directories
belong to it (Sema/Resolve is part of Sema) unless one has a module.k of its
own (AST/Serialize). Compiler/ itself has no module.k.
The tree builds under the language's own visibility rule
(-fdefault-visibility=spec): an unmarked declaration is `prot`, visible to
every file of its module; `pub` marks what other modules use, i.e. the
module's API; `priv` is one file. A declaration another module needs is made
`pub` at the declaration, never by widening the default. Linker/API,
Linker/Driver, Linker/Sysroot (and its Driver/ and Providers/), Analyzer and
Extras/Formatter are modules the same way. The generated full registry
(build/registry/Compiler/Diagnostic/Registry.k) compiles outside the
Diagnostic module, so what it names (DiagMeta's fields) is `pub`.

--------------------------------------------------------------------------------

 The compiler
--------------

This tree is the Kairo compiler, written in Kairo and built by itself:
`python3 build.py` builds it with the last good release compiler (the seed).
The bootstrap and the seed chain are Compiler/Spec/SelfHosting.md, which
also names the planned stages after this one (Stage 1.5: the compiler
depends on nothing from the C++ standard library; Stage 2: hardening, SSA,
Tether).

The compiler has its own lexer, preprocessor, parser, full Sema (name
resolution, overload resolution, ADL, SFINAE, concept and conformance
checking, instance enumeration, all done Kairo-side), and a CodeGen that does
NOT emit C++ source. It compiles itself, and many programs compile, link and
run (Tests/codegen); a construct the lowerings cannot render yet is SC116E
(FeatureGateCheck), reported before codegen.
`--type-check-only` stops after Sema and is the fast loop when a change does
not touch codegen.
Panic is built end to end, generic bodies included: inferred and declared
sets, try/catch, tagged `Panic<T, ...E>` returns (every Kairo function
stays noexcept), the C++ view (`::builtin::value_or_throw`, ...) and C++
exception arms; what it does not cover yet is SC116E
(Compiler/Spec/Panic.md#gates). `crash!` and every crash-family check go
through one signal-safe runtime call (Lib/rt/crash.c). The LLVM IR safety pass is
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
instance it can see, and each has one home TU, chosen by EmitPlan among the
TUs that use it (Compiler/Spec/Generics.md#homing), that emits the explicit
instantiation; every other TU using it emits `extern template`, so Clang
compiles a known instance once. A partial or explicit specialization of a
generic record, and a full specialization of a generic function, is the
matching C++ specialization. What differs per instance is selected by C++
itself (a specialization, `requires`, a `static_assert` pin), because C++
also instantiates Kairo templates at types Kairo never sees.

Overloads and constraints: candidates that tie and are equally specialized
are ordered by their constraints, [temp.constr.order]
(OverloadResolution::_partial_order asks ConformanceChecking::
more_constrained; an inline bound counts as a `requires` conjunct). A
partial specialization with a `requires` clause is a candidate only where
the clause holds at the bindings (InstantiationRegistry::requires_holds).

Moves: MoveCheck records each transfer it counts (SemaContext::move_sites),
and CopyMoveLowering casts exactly those to `T&&`, so what C++ moves is what
the checker counted. A MOVE value passed to a C++ function by `T&` / `T*`
is moved-from when the function's body moves out of it
(Native/ClangMoveWalk.k, through Sema/Foreign/ForeignInstantiate.k) and,
when no body can be inspected, under -fstrict-cxx-moves (on by default;
-fno-strict-cxx-moves borrows every such call).

Transitional: duck generics. `<T: type>` (the C++-checked regime: its body
is typed as written and clang checks each instance) is OFF by default:
without -fduck-generics every `: type` is SC198E (Sema/Check/FlagGates.k).
The flag is internal and hidden from --help; build.py passes it for the
compiler's own targets and the registry object, whose source still has
`<T: type>` sites (TODO(DUCK-GENERIC);
Compiler/Spec/BuildSystem.md#internal-generics-regime). Removing the regime
deletes FlagGates' `: type` gate, ChainBinding's `b.duck`, EmitIR's duck
paths (`plan_under_duck`) and the flag, once those sites have real bounds.
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
Import Resolution, Sema, lowering, CodeGen, Link, and the callee check of
Sema agreement (Compiler/Spec/SemaAgreement.md). Designed, not built: the
rest of Sema agreement (template choice, conversions, ADL), LLVM IR safety.

Index is a pass of its own over every file, not a sub-step of the parse;
Import Resolution is Sema's first stage (I). C++ FFI is not a linear stage:
the clang parse of the build's header sets starts when preprocessing ends,
runs on the thread pool beside Index and Parse, and Sema reads it first
(see Pipeline 1 and the FFI note).

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
            Which calls into the Kairo side, in the same process, for the
            .k span. Kairo is a re-entrant peer here, not subordinate.
            Kairo is the embedded language.


Both lean on the same Kairo-core library. Clang appears as a guest in both,
in kairo it's invoked for the ffi header sets (parsed after preprocessing,
read by Sema) and at CodeGen (consume tokens -> object); in kcc it's the
front driver that yields the .k region.

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
contains it, and `main` is the global `int main` wherever it is declared
(or the one a script file's top-level statements become,
Compiler/Spec/ScriptMode.md). Each input gets one Frontend Action over the TUs it
reaches. The inputs of one build share a batch: a file reached by two
inputs is built once (the first action to reach it claims it), and an
input another input imports is run first. See Compiler/Spec/Imports.md for
roots and module paths.

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
                  |  correctly. Each file's   |
                  |  ffi header list is       |
                  |  recorded; when the walk  |   Interop/Clang/HeaderSetCache.k
                  |  ends, clang parses them  |
                  |  on the pool (phase A).   |
                  *-------------*-------------*
                                | (import graph known; fan out)
                                v
        *=================================================*
        |   INDEX  -- cheap, fully parallel over all TUs  |   Parser/ASTParse.k (ParseMode::Index)
        |   walk each TU, pull ONLY decls + top-levels,   |   AST/Context/GlobalDisambigTable.k
        |   set correct scope info into the shared        |   AST/Context/ASTContext.k
        |   disambiguation table (thread-safe). Create an |
        |   ASTContext per TU.                            |
        |                                                 |
        |   Every file is indexed before any full parse   |
        |   starts; the table is read-only after that.    |
        *=================================================*
                                v
        *=================================================*
        |   PARSE  -- fully parallel over all TUs         |   Parser/ASTParse.k + *Parse.k
        |   each TU gets its formal TU classification     |   AST/Node/*
        |   (a Parser is what returns a TU). Builds the   |   Memory/ArenaAllocator (per-TU)
        |   arena-allocated Kairo AST and freezes each    |
        |   scope's symbol table. --emit-ast-bin /        |   AST/Serialize/
        |   --verify-ast-roundtrip / --ast-roundtrip then |
        |   write (and reload) each file's AST.           |
        *=================================================*
                                v
        *=================================================*
        |   C++ HEADERS -- driver thread, first in Sema   |   Sema/Foreign/HeaderIndex.k
        |   wait for phase A; per header clang touched,   |   Sema/Foreign/DeclImport.k
        |   mint a Kairo TU and import its declarations   |   Sema/Foreign/TypeImport.k
        |   (clang already resolved them; no Sema run).   |
        *=================================================*
                                v
        *=================================================*
        |   IMPORT RESOLUTION -- Sema's stage I, per TU   |   Sema/Resolve/ImportResolution.k
        |   fold each import's source symbol table into   |   AST/Context/ImportOverlay.k
        |   this TU's import overlay. After I the TU is   |
        |   self-contained: unqualified lookup is the     |
        |   DeclContext chain, then the overlay. Files    |
        |   come from Resolution/, found while            |
        |   preprocessing.                                |
        *=================================================*
                                v
        *=================================================*
        |  SEMA -- per import group, in import order      |   Sema/*, Spec/Pipeline.md
        |  P -> I -> E -> V -> N -> T (ChainBinding last) |
        |  -> typed checks (X, ..., Conformance). Name +  |
        |  type resolution, overloads, conformance,       |
        |  init/move, control flow, patterns, eval.       |
        |  A group is one import cycle, or one TU. The    |   Driver/FrontendAction.k
        |  fronts (I to the typed checks) of groups that  |   (_sema_parallel)
        |  do not import each other run on the pool;      |
        |  Conformance onward runs on the driver, one     |
        |  group at a time.                               |
        |                                                 |
        |  ONE BARRIER, the Typed barrier: every TU of a  |   Sema/Check/EffectPropagation.k
        |  group reaches Typed, then the build-wide       |
        |  EffectTable solves the group's inferred panic  |
        |  sets to one fixpoint; then each TU goes on to  |   Sema/Check/PanicEffect.k
        |  the late checks (panic effects, eval usage,    |
        |  feature gates).                                |
        |                                                 |
        |  Lowering: Kairo's IR layer IS Kairo. Each      |   Sema/Lower/* (one pass per
        |  high-level construct is rewritten into more    |   construct; the fixed order
        |  primitive Kairo (variants, enum layout, ctor   |   is Sema.k::_stage_lowerings,
        |  init, script, panic, finally, nullable,        |   listed in Compiler/Spec/Lowering.md)
        |  operators, f-strings, iteration, match, ...).  |
        |                                                 |
        |  Mono (Compiler/Spec/Generics.md): a generic    |   AST/Context/
        |  body is checked once against its bounds, never |   InstantiationRegistry.k
        |  per instance. T, X and the reach mint          |   Sema/Check/
        |  instances into the build-wide registry's       |   Check/Conformance.k
        |  worklist; M1 drains it, and EmitPlan homes     |
        |  each instance, named or reached through a      |
        |  body, as a clang specialization. Instance      |
        |  facts come by substitution into the bounds: M2 |   Sema/Lower/Panic.k
        |  forms each live instance's panic results and   |   (PanicInstances)
        |  sweeps ADT layout again; lifecycle and         |
        |  conformance rows are computed when an instance |
        |  becomes live.                                  |
        *=================================================*
                                v
        *=================================================*
        |  CODEGEN -- always fully parallel over TUs      |   Spec/Codegen.md
        |  construct a clang::Token stream into a custom  |   Codegen/Plan/EmitPlan.k, Emit/*
        |  inline buffer; SourceLocs point into .k.       |   Codegen/Sink/TokenSink.k
        |  Invoke Clang cleanly as a guest -> object.     |   Codegen/Backend/CodegenBackend.k
        |  Each TU loads the merged header PCH (and the   |
        |  interface PCH chained on it).                  |
        *=================================================*
                                v
        *=================================================*
        |  SEMA AGREEMENT -- parallel over TUs            |   Spec/SemaAgreement.md
        |  clang has parsed and type-checked the tokens   |   Native/ClangSemaAgree.hh
        |  CodeGen built. Before clang's CodeGen takes a  |   Codegen/Backend/CodegenAction.k
        |  declaration, walk it and check clang's Sema    |   Codegen/Backend/SemaAgreeReport.k
        |  reached Kairo's decisions. Walked: each TU's   |
        |  stream, the interface PCH's bodies at the      |
        |  PCH's build, and the Kairo streams a C++ file  |
        |  includes. Built: each call's chosen callee,    |
        |  and whether it was found by                    |
        |  argument-dependent lookup. Not built:          |
        |  overload ranking, conversions, the template /  |
        |  specialization picked, a dependent call in an  |
        |  instance of a body the PCH holds. A            |
        |  disagreement is a Kairo bug (CodeGen left      |
        |  clang a choice, or Sema ranked wrongly): an    |
        |  internal warning naming both answers (I012W),  |
        |  reported by a debug-built compiler or under    |
        |  -fsema-agreement and only counted otherwise.   |
        |  The call is pointed at Kairo's answer where    |
        |  the two have one type; compilation continues   |
        |  either way. A TU's findings are stored with    |
        |  its cached object and said again by the build  |
        |  that reuses it.                                |
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
                  |  Link: lld as a library   |   ../Linker/API (API::Link)
                  |  Linker/API plans the job |   Compiler/Spec/Linking.md
                  |  (crt objects, runtimes,  |
                  |  library dirs), checks    |
                  |  ABI notes and runs lld   |
                  |  in process; kld is the   |
                  |  out-of-process fallback. |
                  |  lld's messages become    |
                  |  L002 diagnostics.        |
                  *-------------*-------------*
                                v
       executable | shared library | object, assembly, LLVM IR / bitcode

A .klib library (Compiler/Spec/LibraryFormat.md) is designed, not built.

--------------------------------------------------------------------------------

 FFI note - C++ headers, parsed once
-------------------------------------

Each file's ffi headers form a header set. The preprocessor records every
set (PPWalker); when it is done, HeaderSetCache::start_shared parses the
union of every list once, on the pool, overlapping the Kairo parse (each
list alone when there is only one, when the union cannot be used, or under
-fno-shared-header-set) (Interop/Clang/HeaderSet.k):

  1. Phase A, Sema: the clang instance keeps its ASTContext and Sema alive.
     At the start of Sema, Sema/Foreign/HeaderIndex.k walks that AST to give
     Kairo Sema the C++ declarations it resolves and type-checks against;
     an instance of a C++ class template is completed by clang and imported
     (Sema/Foreign/ForeignInstantiate.k). Phase A writes no PCH.
  2. Phase B, CodeGen: one merged PCH of every header set in the graph
     (Interop/Clang/CodegenPCH.k), built on the pool while Sema runs, is
     every TU's implicit PCH; the program's interface PCH
     (Codegen/Backend/InterfacePCH.k, --interface-pch, auto by default) is
     chained on it. If the merged PCH fails to build, each TU loads one set
     as its PCH and includes the others as text
     (Codegen/Backend/CodegenBackend.k).

--------------------------------------------------------------------------------

 Pipeline 2 - kcc (Clang-fronted, .k embedded via patched Clang)
-----------------------------------------------------------------

kcc (Driver/Kcc.k) is a clang/clang++ drop-in: it translates a clang
command line into kairo's words (FlagTranslator::from_driver) and runs the
same CompilerInstance as kairo, so `kcc -c x.cc`, `kcc main.cc foo.k -o app`
and `kcc x.o y.o` behave as with clang. `-c` writes objects for the command
line's own files only (--emit-scope=inputs); a link takes builtin, std and
the runtime from the toolchain's cached library (--kairo-lib). A C++
input's `#include "foo.k"` files are found before the compile
(Interop/Clang/KairoIncludeScan.k) and built as modules beside it
(foo.cc + foo.k -> foo.o + foo.k.o).

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
          |  foo.k went through Sema and  |   Driver/KairoIncludes.k
          |  lowering before any C/C++    |   Interop/Clang/KairoInclude.k
          |  input compiles; emit its     |   Codegen/Backend/IncludeEmitter.k
          |  interface as clang::Tokens   |
          |  located into foo.k           |
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

 Incremental compilation and the live check
--------------------------------------------

  --cache-dir           keeps objects and the incremental object cache: a
                        TU whose object key (a hash of the stream codegen
                        would hand clang, its headers and options) is
                        unchanged skips codegen and clang
                        (Driver/ObjectCache.k, Codegen/Sink/HashSink.k;
                        Compiler/Spec/Incremental.md).
  --incremental-sema    with --cache-dir: a record per module and a run
                        manifest; a run whose every input is unchanged skips
                        parse, Sema and codegen and links the recorded
                        objects (Driver/ModuleRecords.k; also
                        KAIRO_INCR_SEMA=1).
  --dump-interface,     each file's interface hashes and dependency rows
  --dump-deps           (Sema/Incremental/Facts.k, AST/Context/DepLog.k).
  --print-incr-plan     the modules the stored rows say must be re-checked
                        (Sema/Incremental/Plan.k); --incr-verify proves it
                        against a full run. No result is reused on its
                        strength.

Tooling/LiveCheck.k is the API a process that stays up (kals) calls when a
file of the graph changes: a full check in a new CompilerInstance, or, with
`in_place`, a re-check of the edited file and every file that imports it
against the rest of the graph, after their instances are taken out of the
registry (Sema/Incremental/Retract.k). `--incr-replay=<script>` (with
`--incr-replay-in-place`) drives it from the command line
(Tooling/IncrReplay.k). The design is Compiler/Spec/IncrementalSema.md.

--------------------------------------------------------------------------------

 Notes
-------

Resolution is import/path resolution (finding files); name resolution lives
in Sema. Different stages despite the similar name.

Sema/ holds two responsibilities of different shapes: analysis (decide:
type checking, inference, resolution, constraint checking) and lowering
(rewrite: desugar high-level constructs into primitive Kairo, Sema/Lower/).
They share one module and one schedule and the surface is large. This is a
known seam, not a design choice: analysis decides, lowering rewrites, and
the two will want splitting as the folder grows.


Native/ headers are pooled rather than co-located because their #include
paths are relative and mutually dependent; -I does not reach them.

Native/ is plain C++ on the C++ standard library. Every header includes
Native/Prelude.hh, which defines KAIRO_NATIVE_STAGE0 from whether
lib-helix's <include/core.hh> is on the include path. No build of this tree
puts it there, so the switch is 0 and the code behind `#if
KAIRO_NATIVE_STAGE0` (lib-helix's string, null_t, std::Function, the print
family) is never compiled; it is to be removed. Text parameters are
templates over native::bytes.

--------------------------------------------------------------------------------

 Build
-------

  python3 build.py --debug kairo --no-prebuild   (from the repo root; the edit/test loop)
  python3 build.py --release kairo kcc           (the release pipeline)

build.py is the build of record (its module docstring and `--help` are
authoritative; Compiler/Spec/BuildSystem.md is the spec). kbld does not
build this tree. Targets: kairo, kcc, kld, kparse, kunit, katar, kfmt,
ksys, clang-diag-identity, kals. Outside --single, the default target list
(`kairo` alone) builds the whole toolchain: kairo, kcc, kld, kfmt, ksys,
kals. `--print-jobs` shows
the clang jobs and the link without building; `--no-prebuild` skips
Scripts/build_llvm.py (gen_diag.py always runs).

  python3 build.py --debug kunit --no-prebuild   (the unit-test runner)

kunit (Tooling/UnitTests.k) calls each module's Test() function in a fixed
order (ThreadPool, MappedFileBuffer, SourceManager, Lexer, FlagRegistry,
TermRenderer), prints `ok <name>` or `FAIL <name>` after each, and exits 1
when any failed. `kunit <name> ...` runs those alone, `--list` names them,
`--bench` adds the lexer's 1 GiB throughput benchmark. It is not staged or
installed; Tests/unit runs it when it sits beside the kairo under test.

  --debug    build/<triple>/debug (<triple> the host's, e.g.
             x86_64-linux-gnu), built by --kairo, else $KAIRO_SEED, else
             the installed release compiler, else a `kairo` on PATH; with a
             permanent cache build/<triple>/cache/debug.
  --release  the two-stage pipeline: snapshot build/<triple>/release to
             build/<triple>/N-1 (the backup and the seed), N-1 builds kairo
             alone into build/<triple>/staging, staging builds the targets
             into build/<triple>/release, then the PATH entries of the
             built tools are pointed at it (--no-path skips that). A
             failure restores release/ from N-1 and exits nonzero. Every
             release is static: on Linux <triple> is the musl one (e.g.
             x86_64-linux-musl).
  --single   (or --out, --src, --print-jobs) builds exactly one tree,
             build/<triple>/stage1.5/<mode> unless --out names another.

The compiler's own targets take internal flags the build adds:
-fduck-generics, -fno-strict-cxx-moves (the tree relies on clang and LLVM
functions borrowing what it passes by `T&`) and -fdefault-visibility=spec.

Every build writes the diagnostic registry first: Scripts/gen_diag.py reads
Diagnostic/TableGen/*.diag.toml and emits Diagnostic/Registry.k (generated,
never edited) and the full registry source under build/registry, which is
compiled into the registry object (<cache root>/registry/registry.o) that is
linked into every tool and so references no compiler-module symbol
(TableGen/README says why). Never rebuild a compiler binary while a compile
is running from it.

A build ends with a post-build hook (--no-postbuild skips it) that turns
the tree into a self-contained toolchain:

  Scripts/stage_tree.py <tree>   bin/: clang-<ver> (+ clang, clang++,
                                 clang-cpp, clang-cl), lld (+ ld.lld,
                                 ld64.lld, lld-link, wasm-ld), and the
                                 optional tools in the script's list
                                 (llvm-nm, llvm-objdump, llvm-ar, ...)
                                 that build/llvm/bin has.
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
find is a P008W with a P008N naming the flag. The sysroot is the bundled
<exe>/../sysroot/<target>, else one the sysroot generator (Linker/Sysroot,
also the ksys tool) builds or has cached; having none is a P008W unless
--freestanding (Compiler/Spec/Driver.md#sysroot-selection). lit passes the
resource dir, builtin and std roots explicitly.
