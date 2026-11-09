# Parsing

The parser turns one file's preprocessed token buffer ([Lexing.md](Lexing.md#preprocessor)) into a `TranslationUnit`: the AST, a frozen symbol table per declaration scope, and the file's parse diagnostics. It is hand-written recursive descent with a Pratt loop for expressions, and it runs twice per file: an index pass that records which names are types, generics and macros, then the full parse, which uses those records to resolve the grammar's ambiguities. Sema's view of the result (phase P) is in [Pipeline.md](Pipeline.md#compilation-phases). The source layout of `Compiler/Parser/` and `Compiler/AST/` is in `Compiler/README.txt`.

## Parser structure

`ASTParse` (`Compiler/Parser/ASTParse.k`) owns all parser state and derives the grammar from CRTP mixins, each reaching the parser through `self.dyn()`:

| Mixin | File | Productions |
|---|---|---|
| `DeclParse` | `DeclParse.k` | declarations; entry `parse_decl` |
| `StmtParse` | `StmtParse.k` | statements and blocks; entry `parse_stmt` |
| `ExprParse` | `ExprParse.k` | expressions (Pratt loop, postfix chains); entry `parse_expr` |
| `TypeParse` | `TypeParse.k` | types, generic argument lists, panic sets; entry `parse_type` |
| `PatternParse` | `PatternParse.k` | `match` and destructuring patterns; entry `parse_pattern` |
| `ImportGrammar` | `Shared/ImportGrammar.k` | import statements, shared with the preprocessor |
| `MacroHeaderGrammar` | `Shared/MacroHeaderGrammar.k` | `macro name!(params)` headers, shared with the preprocessor |

The two `Shared/` grammars have one implementation and several hosts. A host supplies the `ig_*` methods (`ig_kind`, `ig_peek_kind`, `ig_tok`, `ig_bump`, `ig_bump_nl`, `ig_eof`, `ig_err`, and for the import grammar `ig_err_remove`, an error with a removal fix-it); `ASTParse`, `PPWalker`, `StreamCursor` and `TokenRunCursor` each implement them over their own token source.

### Cursor

The parser reads the file's `TokenSpan` through `c_idx` and the cached `_prev`, `_current` and `_peek` pointers. Token accessors return 16-byte copies. Macro-expanded tokens are seen through their wrapper: `resolve_deep` and `resolve_kind_deep` unwrap a `TkMacroExpand` chain to the original kind and `imm`, and leave a sentinel as `TkMacroExpand` ([Lexing.md](Lexing.md#macros)). Comments never rest under the cursor: `_advance` stashes each `AtComment` it lands on and steps over it, and the stashed comments become annotations on the next declaration or trailing annotations on the previous one.

A newline (`TkNewLine`) or `;` terminates a statement. Inside bracketed constructs the parser calls `nl_push`, which makes every advance skip newlines until the matching `nl_pop`. A closer is consumed with `advance_raw`, which keeps a following newline only when the enclosing context still treats newlines as terminators.

Two RAII guards move the cursor:

- `TentativeGuard` saves the cursor, newline depth and pending comments and suppresses diagnostics. Unless `commit()` is called, its destructor restores everything and drops the diagnostics issued under it.
- `StreamGuard` swaps the cursor onto an f-string hole's own token buffer and restores the main stream on exit. No `TentativeGuard` may straddle one, because a saved index from one stream is meaningless in the other.

### Modes

`ParseMode::Index` drives the same declaration grammar as the full parse, but declaration productions stop after their heads (name, generic parameters, specialization pattern) and skip signatures and bodies; statement positions are skipped wholesale (`_index_skip_stmt`). Index mode suppresses all diagnostics and fills the file's `DisambigTable` (`ctx->hoisted`, `Compiler/AST/Context/ASTContext.k`), a trie of scopes whose entries record each name's `DisambigKind` (class, struct, enum, union, interface, type alias, function, operator, variable, procedural macro, basic macro, module) and whether it is generic. Every branch of an `eval if` is indexed, since which branch is taken is Sema's decision. A declaration is generic when it has type parameters or is a primary template; an explicit or partial specialization does not make its name generic.

The driver (`CompilerInstance`, `Compiler/Driver/CompilerInstance.k`) runs the index pass for every file of the closure in parallel and waits for all of them before any full parse starts. `GlobalDisambigTable` (`Compiler/AST/Context/GlobalDisambigTable.k`) owns each file's `ASTContext` and its table, and is read-only once indexing is done, so a full parse can consult any imported file's table without locking. The full parses then run in parallel; each writes diagnostics into its own `BufferedDiagSink`, and a flusher thread drains finished files into the `DiagEngine` in file order, so output is identical for serial and parallel runs. `--syntax-only` indexes the whole closure but fully parses only the input file.

### Top level

`parse()` loops over top-level items. For each it consumes leading annotations once, intercepts `@set_global_allocator(...)` (a property of the program), intercepts a bare `module a::b` pin (recorded on the TU for the resolver, never a declaration; [Imports.md](Imports.md#module-pinning)), and then routes the item to `_parse_top_decl` or `_parse_top_stmt` ([Disambiguation](#disambiguation)). Kairo files may contain top-level statements; their meaning is in [ScriptMode.md](ScriptMode.md#script-files). A top-level loop is bounded at four times the token count as a guard against a production that consumes nothing.

### Parse output

After the loop, `parse()` finishes the translation unit in three steps:

1. `_wire_scopes` links each named `DeclContext` to its node in the file's `DisambigTable`.
2. `_build_symbols` builds the per-`DeclContext` `SymbolTable`s (`Compiler/AST/Context/SymbolTable.k`) in one walk and freezes them. The tables are append-only multimaps and the walk reports nothing: duplicates, forward declarations with definitions, and specializations all stack in one cell for Sema to sort out. Anonymous containers (anonymous modules, visibility groups, `eval` and `ffi` blocks) have no table; their declarations land in the enclosing one. Extension members go in the `ExtensionDecl`'s own table. A function named like its enclosing type keys as a constructor; operators key on their operator kinds. Out-of-line definitions (`fn Class::method`) go to `tu->out_of_line` and into no table. Locals and parameters are in no table. A named declaration inside a function body (`class Local`, `fn inner`) is linked into the enclosing executable context's `dc_decls` (`StmtParse::_attach_local_decl`); its body gets tables (`_index_local_scopes`), its name does not.
3. `_synthesize_module_self` creates the file's own `ModuleDecl`, named by the leaf of the file's module path and sharing the TU's table, so a plain `import bar` binds a real declaration. The root file has no name and no such node.

Postcondition: every declaration context has a frozen table and `out_of_line` is complete. No later phase mutates a frozen table; later phases add overlays and links instead ([Imports.md](Imports.md#overlays-and-visibility)).

## Disambiguation

The grammar has ambiguities that tokens alone cannot settle. The parser settles each one at a fixed point, using lexical scope, the index pass and, where those give no answer, a tentative parse.

### Generic arguments or comparison

When `<` follows a name in expression position, `_generic_verdict` (`ExprParse.k`) decides:

1. A lexical binding (parameter, local) shadows everything. A generic parameter, or a `var` bound to a generic closure, is generic; any other binding is a value, so `<` is a comparison.
2. Otherwise the file's `DisambigTable`. Any generic entry for the name makes it generic, whatever overload is first. If every entry is a variable, `<` is a comparison. A known non-generic function, operator or type gives no verdict, so `foo<a>(10)` can still report that `foo` takes no generic arguments while `foo < limit` parses as a comparison.
3. On a table miss, `_import_generic_fallback` walks the file's import edges and asks each source file's frozen table: a wildcard import is probed with the name as written, a selective import through the item's visible name (its alias if any), and a plain module import contributes nothing to an unqualified name. A hit makes the name generic. No tables are merged.
4. Without a verdict, the parser parses generic arguments under a `TentativeGuard` and commits only if the list parsed and the next token can follow a generic name (`(`, `.`, `->`, `::`, `?.`, `?->`, `[`, `{`, `,`, `;`, `)`, `]`, `}`, newline, end of file). Otherwise it rolls back to a comparison.

`Self` never takes generic arguments; `<` after it is always a comparison. Qualified paths are decided segment by segment against the qualifying scope's table. Tests: `Tests/Parser/Disambiguation/`.

A generic list closed by `>>` (or `>>>`) splits the token: `_pending_close_angle` records the half that closes the outer list. The lexer already splits `>=>` and `>>=>` ([Lexing.md](Lexing.md#tokens)).

### Declaration or statement

`_routes_to_decl` (`ASTParse.k`) sends an item to the declaration path or the statement path by its first keyword:

| Lead | Route |
|---|---|
| `var`, `const` | statement path, which owns the plain-declaration versus destructuring split; `const static`, `const thread`, `const eval`, and `const` before a function go to the declaration path, so both modifier orders build the same tree |
| `thread` | declaration when a binding follows (`thread n: T`); otherwise an expression (`thread work()`) |
| `eval` | declaration for `eval { }`, `eval fn`, and `eval N = e`; `eval if`, `eval for` and `eval f(3)` are statements |
| `fn` | declaration; `parse_decl` speculates and, for an anonymous closure invoked in place (`fn () { }()`), returns null with the cursor rolled back, and the statement path parses it |
| other declaration keywords | declaration |

### Other fixed rules

- In the head of `if`, `while`, `for` and similar constructs the condition is parsed with `ExprStopKind::NoStructLiteral`, so `{` after it opens the body and is never a named initializer.
- `.Variant` and `.Variant { ... }` parse as a headless `NamedInitializerExpr`; which enum is meant is a Sema fact.
- `panic` directly followed by `(` on the same line, after the parameter list of a function, closure or `fn` type, is the declared panic set and never a tuple or a `panic` statement (`TypeParse::parse_panic_set`). A newline ends the specifier. An empty set `panic()` is S055E with a fix-it removing the parentheses and parses as a bare `panic`. The set's meaning is in [Panic.md](Panic.md#model).
- `fn op panic (const self)` is an operator declaration like `op await`.
- In patterns, `(` at the start is always a tuple pattern. A literal or path is parsed as a pattern lead and classified by what follows; a path's first segment is looked up shallowly in the index tables, and a hit makes a `ConstructorPattern`, a miss an `UnresolvedConstructorPattern` that Sema resolves or reports. The dotted form `.Variant` never looks anything up.
- `Self` lexes as `BiSelf` and parses as an ordinary `NamedIdentExpr` head.
- `t.0` versus `.5` is decided by the lexer ([Lexing.md](Lexing.md#operators-and-punctuation)).

## Error recovery

A production that fails reports one diagnostic, returns a recovery node, and resynchronizes; the parse always runs to the end of the file unless a depth limit fires.

Recovery nodes. Every node family has a `Recovery*` kind (`RecoveryDecl`, `RecoveryStmt`, `RecoveryExpr`, `RecoveryType`, `RecoveryPattern`). A node's `create_error` factory allocates the full concrete node, sets `kind` to the family's recovery kind, and stores the intended kind in `recovery_kind`. `is_error()` tests the former; `isa_recovery`, `cast_recovery` and `dyn_cast_recovery` (`Compiler/AST/Node/Casting.k`) read the latter, so code that wants partial structure can still reach it. Separately, `fatal_ptr<T>()` returns a per-family sentinel address that a production returns to abandon the whole item; the top-level loop stops on it.

Resynchronization. Each mixin has a sync routine that skips tokens while balancing `()`, `[]` and `{}`, and stops at depth zero on the construct's boundary. Each also has a `_progress` variant that guarantees the cursor moved, for use inside retry loops.

| Routine | Stops at | Token cap |
|---|---|---|
| `_sync_expr` | an unbalanced closer; `;`; `,` in list contexts; a newline in top-level context | 64 |
| `_sync_type` | the type context's closers | 64 |
| `_sync_stmt` | an unbalanced closer; newline; `;`; a statement or declaration lead keyword | 128 |
| `_sync_decl` | the declaration context's boundary | 128 |
| `_sync_generic_args` | the closing `>` (or `>>`) at the opening depth, a statement-level delimiter, or end of file | none |

`_sync_generic_args` has no cap: with a budget, a caller loop on deeply nested input stopped making progress and hung.

Specialised recovery exists for closures (`_sync_to_closure_milestone`), bodies (`_sync_to_body`), braced branches (`_recover_braced_branch`), match arms (`_recover_case_to_expr`), panic sets, field initializers, and patterns inside `()` and `[]`.

Depth limits. `enter_depth` caps nesting at `--cmax-scope-depth` (default
256) and `enter_expr_depth` caps expression nesting at `--cmax-expr-depth` (default 512). Exceeding either reports S063E with an S063N note and sets `_depth_aborted`, after which `is_eof()` reports true and the parse unwinds without further diagnostics.

Poisoned expansions. A `MacroSentinel::Poison` token in expression position becomes a recovery expression with no diagnostic: the preprocessor already reported the failed expansion. Diagnostics on macro-expanded tokens attach the expansion backtrace (`attach_macro_expansion_chain`); repeated backtraces for one invocation are collapsed.

## AST

The AST lives in `Compiler/AST/`. Nodes are allocated in the file's `ASTContext` arenas (`Compiler/AST/Context/ASTContext.k`) through static `create(ctx, ...)` factories and are never freed individually. Child lists are `FrozenList` (`Compiler/AST/ASTSupport.k`), built once from a stack buffer and then immutable.

### Node families

| Family | Base | Kind enum | Nodes |
|---|---|---|---|
| Declarations | `Decl` | `DeclKind` | `Compiler/AST/Node/Declarations.k` |
| Statements | `Stmt` | `StmtKind` | `Compiler/AST/Node/Statements.k` |
| Expressions | `Expr` | `ExprKind` | `Compiler/AST/Node/Expressions.k`, `PrimaryExpressions.k` |
| Types | `Type` | `TypeKind` | `Compiler/AST/Node/Types.k`, `CanonicalNodes.k` |
| Patterns | `Pattern` | `PatternKind` | `Compiler/AST/Node/Patterns.k` |

The kind enums are in `Compiler/AST/Kind/`; each starts with its recovery kind at 0 and ends with a `Count` sentinel. The kind field sits at offset 0 of every node, and `isa`, `cast` and `dyn_cast` (`Compiler/AST/Node/Casting.k`) switch on it: no vtables and no C++ RTTI.

Bases and mixins (`Compiler/AST/Node/Base.k`, `Compiler/AST/Mixin/`):

| Piece | Role |
|---|---|
| `Annotation` | attributes and comments on any node |
| `VisibilityAnnotation` | `pub`/`priv`/`prot` on declarations |
| `TypeQual` | qualifier bits on types (`const`, `atomic`, `unsafe`, `eval`, `async`), with per-qualifier ranges for fix-its; qualifiers are flags, not wrapper nodes |
| `TemplateParams` | generic parameters and the `where`/`requires` constraint |
| `Redeclarable` | a circular chain of redeclarations with a stable canonical declaration, after Clang's `Redeclarable<T>` |
| `FFILinkage` | foreign linkage, set by an `ffi` prefix or by importing a C++ declaration |
| `DeclContext` | a declaration that owns a scope: TU, module, record, enum, interface, function, block |

`DeclFacts.k` reads mixin slots off a bare `*Decl`, since there is no common base to read them through.

Two type nodes are never produced by the parser: `BuiltinType` and `RecordType` (`CanonicalNodes.k`) exist only as canonical forms created by `CanonicalTypeStore`. Everything else in `TypeKind` is syntax. Primitive type names are keyword tokens ([Lexing.md](Lexing.md#keywords)) and resolve to a `BuiltinType` without lookup.

A `TranslationUnit` (`Compiler/AST/Context/TranslationUnit.k`) is the root for one file: a `Program` (the ordered top-level items, each a declaration or statement), the file's imports and import edges, the out-of-line list, the module pin, and diagnostic counts. The preprocessor creates it and fills its imports and macros; the parser fills the rest.

### Visitors

| Tool | File | Use |
|---|---|---|
| `RecursiveASTVisitor` | `Compiler/AST/Visitor/RecursiveASTVisitor.k` | Read-only walks and one-for-one rewrites. `dispatch_F` switches on kind to `traverse_N`; `traverse_N` calls `walkup_N` (family hook `visit_F`, then leaf hook `visit_N`), recurses into children, and returns the possibly replaced node for the parent to store. A hook returning false prunes the subtree. List children are walked read-only. |
| `ASTWriter` | `Compiler/AST/Visitor/ASTWriter.k` | Structural rewrites: deleting, splicing or expanding statements and declarations, replacing a node with one of another family, rebuilding lists. |

Both are CRTP: a pass derives one and overrides only the hooks it needs.

### Printing

`ASTPrinter.k` holds the one renderer (`AstDumper`) with two paths (`Compiler/AST/Printer/PrintCore.k` selects by `PrintStyle`):

- The source-faithful path reproduces a node as one line of source text, in `Diagnostic` or `Canonical` style; Sema diagnostics use it to quote code.
- The debug tree path is built on `RecursiveASTVisitor` and renders an ASCII tree with optional ANSI color. `--print-ast=tree` (default), `flat` and `canonical` select the format; the dump is taken at the end of parsing, before Sema runs.

### Code completion

`CodeCompleteConsumer` (`Compiler/AST/CodeCompleteConsumer.k`) receives callbacks at completion points (`maybe_complete`, `maybe_complete_member`, `maybe_complete_qualified`, `maybe_complete_sighelp`). It is null in batch compilation.

## Grammar

[Grammar.ebnf](Grammar.ebnf) is an informative EBNF sketch of the language. It is not generated from the parser and not checked against it, and it is known to be out of date; the productions in `Compiler/Parser/` are the authority, and the language reference defines what each construct means.
