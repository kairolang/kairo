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

Two continuations cross a newline outside brackets. An infix operator at the end of a line takes its right operand from the next line (every binary operator consumes with `SkipNL::After`). An infix operator at the start of the next line continues the expression when it cannot also open a statement (`ExprParse::_parse_expr_prec`): `is_unary_operator` covers the ambiguous set (`+ - * & ~ ! ++ -- .. ...`), which ends the expression instead, as `.` and `->` do in `_parse_postfix_expr` by the member-access rule. `impl` and `derives` are infix operators here (a conformance constraint), so `a` NEWLINE `impl` NEWLINE `T` is one constraint `a impl T` (whether keyword operators should continue a line is not decided by the language reference).

Speculation records a `ParserCheckpoint` (`ASTParse::checkpoint`): the cursor, the `>>` debt, the newline depth, the pending comments, and the depth counters (`depth`, `expr_depth`, `ffi_decl_depth`) with `_no_comment_skip`. `rewind` restores the cursor and the `>>` debt; the depth counters are never restored, because every enter/exit pair inside a speculation is balanced, and a debug build records them and asserts they came back by themselves (a fired depth cap, `_depth_aborted`, is sticky and excused). The bare `tentative_begin` / `tentative_rollback` pair is a checkpoint and a rewind with no suppression, and leaves the newline depth and pending comments alone.

Two RAII guards move the cursor:

- `TentativeGuard` takes a checkpoint and suppresses diagnostics. Unless `commit()` is called, its destructor rewinds, restores the newline depth and pending comments, and drops the diagnostics issued under it.
- `StreamGuard` swaps the cursor onto an f-string hole's own token buffer and restores the main stream on exit. No `TentativeGuard` may straddle one, because a saved index from one stream is meaningless in the other.

### Modes

`ParseMode::Index` drives the same declaration grammar as the full parse, but declaration productions stop after their heads (name, generic parameters, specialization pattern) and skip signatures and bodies; statement positions are skipped wholesale (`_index_skip_stmt`). Index mode suppresses all diagnostics and fills the file's `DisambigTable` (`ctx->hoisted`, `Compiler/AST/Context/ASTContext.k`), a trie of scopes whose entries record each name's `DisambigKind` (class, struct, enum, union, interface, type alias, function, operator, variable, procedural macro, basic macro, module) and whether it is generic. Every branch of an `eval if` is indexed, since which branch is taken is Sema's decision. A declaration is generic when it has type parameters or is a primary template; an explicit or partial specialization does not make its name generic.

The driver (`CompilerInstance`, `Compiler/Driver/CompilerInstance.k`) runs the index pass for every file of the closure in parallel and waits for all of them before any full parse starts. `GlobalDisambigTable` (`Compiler/AST/Context/GlobalDisambigTable.k`) owns each file's `ASTContext` and its table, and is read-only once indexing is done, so a full parse can consult any imported file's table without locking. The full parses then run in parallel; each writes diagnostics into its own `BufferedDiagSink`, and a flusher thread drains finished files into the `DiagEngine` in file order, so output is identical for serial and parallel runs. `--syntax-only` indexes the whole closure but fully parses only the input file.

### Top level

`parse()` loops over top-level items. For each it consumes leading annotations once, intercepts `@set_global_allocator(...)` (a property of the program), intercepts a bare `module a::b` pin (recorded on the TU for the resolver, never a declaration; [Imports.md](Imports.md#module-pinning)), and then routes the item to `_parse_top_decl` or `_parse_top_stmt` ([Disambiguation](#disambiguation)). Kairo files may contain top-level statements; their meaning is in [ScriptMode.md](ScriptMode.md#script-files). A top-level loop is bounded at four times the token count as a guard against a production that consumes nothing. An item never ends the loop silently: a lead-in `parse_decl` declines without consuming or reporting anything (`inline "c++" { }`, a closure `fn`) goes to `_parse_top_stmt`; an item that fails, or yields a recovery node, with no error of its own gets S063E at its first token, and the loop resumes at the next line or declaration (`sync_top_level_progress`). The loop still stops on a fatal sentinel and on a null that came with an error. The closure signature's recovery (`_sync_to_closure_milestone`) reports S047E when it drops tokens and stops at a milestone, since the body that follows reports nothing; stopped at EOF, the body check's S054E is the error. A function name with a leading `::` (`fn ::gf`, `fn ::ns::f`) is a declaration head, not a closure: S093E at the name, then parsed on without the `::` (defining a C++ global from Kairo is undecided).

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

A generic list closed by `>>` (or `>>>`) splits the token: the inner list owes the outer one its `>` (`TypeParse::_angle_debt`, 0 or 1). `owe_close` sets the debt, `pay_close` tests and clears it where a list may close, `forgive_close` drops it after a list nothing encloses, and `owes_close` reads it without settling. The debt is part of a speculation's checkpoint. The lexer already splits `>=>` and `>>=>` ([Lexing.md](Lexing.md#tokens)).

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
- A function's name is an identifier. A keyword (`fn class`, `fn while`, `fn self`: `self` is taken after `fn` only as the head of a qualified name, `fn self::...`) or a primitive type's name is S047E; `self` and a primitive name are reported and kept as the name, so the signature and body still parse (`DeclParse`).
- `fn op []=` (the place form of the subscript) is three tokens, `[` `]` `=`, the `=` touching the `]` (no lexer token: a `]=` token would break `a[i]= 5`). Written apart (`op [] =`) it is S045E with a fix-it closing the gap and is still read as `op []=`. It keys as `[` `=` (`DeclName::op_name_of`), apart from `op []`, in the declaration tables, explicit call steps (`b.op []=(1)`) and out-of-line definitions.
- An operator declaration stores its operator tokens through the macro expansion (`DeclParse::_stored_op_token`): `fn op t (...)` in a macro body, with `t` bound to `<`, is `op <`, and `op []`, `op []=` and `op ()` are recognised there too. Every reader of `op_token` keys by kind, so a wrapped token made every operator one macro declared one table cell. The `l` / `r` marker is re-interned in the declaring file, since a wrapped identifier's imm indexes the table of the file that wrote it. `NamedIdentExpr::create` likewise unwraps a keyword (`i32`, `bool`, `Self`), whose readers key by kind (TypeResolve's `builtin_for_token`); an identifier stays wrapped.
- In patterns, `(` at the start is always a tuple pattern. A literal or path is parsed as a pattern lead and classified by what follows; a path's first segment is looked up shallowly in the index tables, and a hit makes a `ConstructorPattern`, a miss an `UnresolvedConstructorPattern` that Sema resolves or reports. The dotted form `.Variant` never looks anything up.
- `Self` lexes as `BiSelf` and parses as an ordinary `NamedIdentExpr` head.
- A `[` or `{` in primary position whose matching closer is immediately followed by `::` opens a container type heading a path (`[T]::make()`, `{T}::make()`, `{K: V}::make()`; `ASTParse::closer_followed_by`): it parses as a type, and the head is a `NamedIdentExpr` whose generic arguments are the element types and whose `container_head` is the type's kind. N binds it to the builtin Vector, HashSet or HashMap record, not by name. No list, set or map literal is followed by `::`, so the literal forms are unaffected. A fixed array or slice there is S094E.
- `t.0` versus `.5` is decided by the lexer ([Lexing.md](Lexing.md#operators-and-punctuation)).
- `test` is a keyword only where a test block can start. As a name it is the identifier it spells (`ASTParse::is_member_name_keyword`, `keyword_as_name`) after `fn` in a type body, after `Class::` in an out-of-line definition, and after `.`, `->`, `?.`, `?->` and `::`, so a method may be named `test` and a C++ `test` (`std::bitset::test`) can be called. A top-level `fn test()` stays S047E. No other keyword is contextual this way.

## Error recovery

A production that fails reports one diagnostic, returns a recovery node, and resynchronizes; the parse always runs to the end of the file unless a depth limit fires.

Recovery nodes. Every node family has a `Recovery*` kind (`RecoveryDecl`, `RecoveryStmt`, `RecoveryExpr`, `RecoveryType`, `RecoveryPattern`). A node's `create_error` factory allocates the full concrete node, sets `kind` to the family's recovery kind, and stores the intended kind in `recovery_kind`. `is_error()` tests the former; `isa_recovery`, `cast_recovery` and `dyn_cast_recovery` (`Compiler/AST/Node/Casting.k`) read the latter, so code that wants partial structure can still reach it. Separately, `fatal_ptr<T>()` returns a per-family sentinel address that a production returns to abandon the whole item; the top-level loop stops on it.

Resynchronization. Each mixin has a sync routine that skips tokens while balancing `()`, `[]` and `{}`, and stops at depth zero on the construct's boundary. Each also has a `_progress` variant that guarantees the cursor moved, for use inside retry loops.

What recovery never consumes. A failed operand, type or pattern does not eat a token that ends something around it. That is: a closer (`}`, `)`, `]`) that the text still has an opener for (`ASTParse::closer_is_owned`: walking back, each closer waits for an opener of its own kind, an opener pairs with the nearest waiting closer of its kind and the ones above it are strays, and an opener nothing waits for is unclosed and stepped over; a `}` must in addition end its line or be followed by `else`, `catch`, `;`, `,` or a closer); a statement terminator (`;`, a newline); the end of the file; in the expression parser, a `,` where the stop set has `StopComma` (a list separator) and a `case` / `default` that starts a line (the next match arm). The no-match paths of the primary expression parser, `TypeParse::parse_type` and `PatternParse::parse_pattern` report (S052E / S053E / S061E) and leave such a token in place; anything else in that position, a stray closer included, is junk and is skipped as before. The owner of the token makes the progress: `parse_compound` and the match body end on `}`; a list loop (call arguments, tuple, list, set, map, initializers, function-pointer parameters) ends on its own closer, takes a `,` as the separator and goes on, and leaves on a closer of something around it so that construct reports what is missing (`foo(1,` then the body's `}`: one S054E for the `)`, and the block still closes). The `_progress` variants of `_sync_expr`, `_sync_type` and `_sync_stmt` follow the same rule: they step over a stray token, and return true when they leave the cursor on an owned closer or at the end of the file, which is the caller's signal to leave its loop. Lists sync at depth 0, so the sync stops at the list's own closer instead of consuming it. The block and top-level statement loops carry a progress guard (a statement that consumed nothing has its token skipped), and a closer a failed operand already reported (`ASTParse::_kept_closer`, recorded only when the report was not suppressed by a speculation) is skipped without being parsed again, so it is reported once. A type body still open at the end of the file is S048E at the last token read, with a note at the body's `{`: the error can only land on the file's end, far from the body that is open. A list element that is not there at all (`[1, , 3]`, `f(1, , 2)`, `P { a: }`) is reported as S052E by the list loop, since `parse_expr` returns null, unreported, on a stop token (not at the end of the file, where the unclosed list is the report). A match arm whose value failed counts as neither form, so it does not make the match "mixed" (S075E), and a `case` whose pattern failed on the match's `}` stops there without an S074E.

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

Bodies that keep their errors (`--check-past-syntax-errors`, the language server's index run; [LanguageServer.md](LanguageServer.md) section 9). Recovery is not changed by the mode: the same tokens are consumed and the same diagnostics reported, so the mode's output is the normal mode's. What the mode adds is bookkeeping. `DeclParse::_parse_fn_body` counts the errors reported while an OUTERMOST function block body is parsed (a nested function or closure is part of the body around it) and asks `ASTParse::closes_lexically` whether the `}` the parse consumed is the one the text pairs with the body's `{` (brackets of all kinds counted together from the opener). Only then is the rest of the file known to have parsed exactly as it would have without the errors, and the function is recorded in `TranslationUnit::recovered_bodies` with its error count. A body that stopped at an inner closer, ran past the right one, or never closed is not recorded. Since recovery leaves closers in place (above), `var x = 1 +` followed by the body's `}` is recorded: one S052E on the `}`, and the body closes on it. An unclosed `(` is not: `foo(1,` then the body's `}` reports one S054E and the parse closes the body on that `}`, but counting brackets from the body's `{` the `}` pairs with nothing (the `(` is still open), so the file falls back to unchecked. The rule for what a recovery may do to names: a declaration the parser has seen must stay in the tree (with a recovery node where its type or initializer failed) rather than vanish, because a use of a name that vanished resolves to whatever outer or imported name it shadowed. The sites that drop names today (`_parse_var` dropping a recovery initializer, a destructuring `var (a, b) = <broken>` becoming one error statement) sit inside function bodies, which the mode drops whole, so they cannot be reached from checked code; fixing them is what checking INSIDE a broken body would need.

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
- The debug tree path is built on `RecursiveASTVisitor` and renders an ASCII tree with optional ANSI color. `--print-ast=tree` (default), `flat` and `canonical` select the format; the dump is taken at the end of parsing, before Sema runs. A struct's or union's members are its fields and its `methods` (the operators and constructors its body may hold), as for a class.

### Code completion

`CodeCompleteConsumer` (`Compiler/AST/CodeCompleteConsumer.k`) receives callbacks at completion points (`maybe_complete`, `maybe_complete_member`, `maybe_complete_qualified`, `maybe_complete_sighelp`). It is null in batch compilation.

## Grammar

[Grammar.ebnf](Grammar.ebnf) is the language's grammar in W3C-style EBNF, generated from the tree-sitter grammar (`Extras/LSPClients/tree-sitter-kairo/grammar.js`) by `Scripts/gen_grammar_ebnf.py`; `--check` reports whether it is current. It leaves out what EBNF cannot say: operator precedence and associativity, and the tree-sitter grammar's declared conflicts. The productions in `Compiler/Parser/` remain the authority where the two disagree, and the language reference defines what each construct means.
