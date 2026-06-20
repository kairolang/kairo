Compiler
========

Stage 1 compiler - self-hosted, written in Kairo. This is the Kairo-side compiler; Stage 0 (the C++ transpiler) compiles this tree and is the current shipping compiler. Stage 1 is the target.

The pipeline runs source -> tokens -> AST -> typed/lowered AST -> IR -> object code. Each stage owns one transformation and hands off; the directory layout follows the pipeline. Codegen is handled by injecting Kairo tokens directly into Clang's SourceManager rather than emitting C++ text - see Interop/Clang.

  Lex -> Preprocess -> Parse -> Clang Interop -> Semantic Analysis -> KairoIR -> CodeGen


Layout
------

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
│   └── Clang/      C++ symbol extraction, token injection into Clang SourceManager
├── Driver/         per-TU orchestration, batch results, pipeline stages
├── Diagnostic/     engine, consumers (basic/pretty), TableGen .diag.toml defs
├── Command/        CLI flag parsing (registry, utils, parsed args)
├── Config/         resolved CompilerInvocation + per-subsystem option structs
├── Location/       source locations, ranges, managers, line tables
├── Memory/         arena allocation, memory buffers, mmap regions
├── Threading/      thread pool, task queues, partitioning, cache-line consts
├── Support/        interning, file IO, terminal rendering, misc primitives
└── Native/         C++ interop headers (.hh) - pooled, path-coupled


Notes
-----

Resolution is import/path resolution (finding files); name resolution lives in Sema. They are different stages despite the similar name.

Native/ headers are pooled rather than co-located because their #include paths are relative and mutually dependent; -I does not currently reach them. (stage0 limitation)


Build
-----

  kbld kairo      (from the kairo/ root)

Stage 0 compiles all of Stage 1. Stage 1 does not yet compile itself.