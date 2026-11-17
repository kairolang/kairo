# AST serialization

The binary form of one file's parsed AST: what is in it, how it is laid out, and how a reader turns it back into a tree. It is the first building block of incremental AST and Sema ([Incremental.md](Incremental.md), Phase 2). **Version 1 is implemented** (`Compiler/AST/Serialize/`). It holds a tree as the preprocessor and the parser leave it, before Sema; Sema's facts, cross-file identity and the cache are not built ([What the Sema section needs](#what-the-sema-section-needs)).

## Scope

| In version 1 | Not in version 1 |
|---|---|
| One file's tree after `Parse.Full`: the program, every declaration, statement, expression, type and pattern node under it | Anything Sema writes: resolved links, types, canonical types, instances, lowerings |
| What the preprocessor took out of the token stream: `tu->imports`, `tu->macros`, import edges | The macro table's token runs (a macro's body), the hoisted index, tokens |
| Every token a node holds, with what its `imm` stands for | Reading a file in another process (no flag loads one; the format is written to allow it) |
| Recovery nodes and `poisoned` bits of a file with syntax errors | Diagnostics (they were reported; the TU keeps its counts) |

The writer takes a tree **before Sema** and says so when it is given another: every slot it does not store is checked, in debug builds, to still hold what a freshly allocated node holds ([Slots that are not stored](#slots-that-are-not-stored)).

## Code

| File | Holds |
|---|---|
| `ByteBuffer.k` | `ByteWriter`, `ByteReader`: little-endian words, LEB128 and zigzag varints; a reader sets `failed` on short input instead of faulting |
| `StringTable.k` | spellings, stored once, in first-use order |
| `Format.k` | magic, version, section ids, family, payload and token tags |
| `Archive.k` | `ASTArchive`: the encodings, the tables, node identity. Writer or reader by its `ArchiveMode`, set once by `begin_writing` / `begin_reading`; single-use, so a node class has one `io_` function for both directions |
| `DeclIO.k`, `ExprIO.k`, `StmtIO.k`, `TypeIO.k`, `PatternIO.k` | one `io_` function per node class, the family headers, allocation by kind |
| `Serializer.k` | `ASTBinWriter`, `ASTBinReader`: header, sections, the TU's own fields |
| `RoundTrip.k` | `ASTRoundTrip::replace` and `::verify`, behind the driver's test flags |

Three scripts go with it:

| Script | Does |
|---|---|
| `Scripts/check_ast_serializer.py` | reads the node files and fails when a field of a node class is named in no `io_` function of that class |
| `Scripts/ast_roundtrip_corpus.py` | runs `--verify-ast-roundtrip` over a directory of sources in parallel and lists the failures |
| `Scripts/lit_ast_roundtrip.py` | `llvm-lit` with `KAIRO_AST_ROUNDTRIP=1` in the environment of every test command |

The third exists because lit hands tests a trimmed environment: the variable set on `llvm-lit`'s own command line never reaches the compiler, and such a run is the ordinary suite under a misleading name.

## The rule for a field

`RecursiveASTVisitor`'s `traverse_` functions are the map of what a node owns, but ownership is not what decides whether a field is written. A pointer field is one of three things, and its type does not say which (`unsafe *Type` is a written return type and a canonical-type slot):

| The field is written by | The serializer |
|---|---|
| the preprocessor or the parser (a child, a back-pointer such as a generic parameter's owner, a flag, a range, a token) | **stores** it through an archive primitive |
| a later stage (the node files name the pass: "One writer: ...", [Pipeline.md](Pipeline.md#fact-writers)) | **skips** it and names it in the function's `eval if defined!(DEBUG)` block, where the writer checks it is unset |
| the parser, as a function of the finished tree | **rebuilds** it on read ([What is rebuilt](#what-is-rebuilt)) |

Every pointer to a node goes through the same reference primitive whether the field owns the node or only names it, so the reader never needs to know which. Each `io_` function names every field of its class in one of the first two ways, and the checker script holds the files to that.

## Layout

All integers are unsigned LEB128 varints unless a width is given; `u32le` is four bytes, low byte first.

```text
header      u32le   magic "KAST" (0x5453414B)
            u32le   format version (`AST_FORMAT_VERSION`, 4)
            16 B    xxh3-128 of the source file's bytes
            u32le   flags (0)
section*    u8      id
            u32le   length of the body in bytes
            ...     body
end         u8 0, u32le 0
```

Sections, in file order:

| Id | Section | Body |
|---|---|---|
| 2 | strings | count, then `length, bytes` per string. Index 0 is the empty string. |
| 1 | files | count, then per file: string index of its module path, string index of its file name, size in bytes, 16-byte xxh3-128 of its bytes. Entry 0, the file itself, is implied and not written. |
| 3 | payloads | count, then one record per token payload ([Tokens](#tokens)) |
| 4 | tree | node count, the TU's fields, and inline in them every node ([Nodes](#nodes)) |

A reader skips a section whose id it does not know by its length. That is how a later version adds a section (Sema facts) without changing the ones before it: the AST section of a file with a Sema section is byte-identical to the same file's without one.

Nothing in a file is a property of the process or the machine that wrote it: no pointer, no fid, no global source offset, no index into a table that exists only in memory, no absolute path. The same source gives the same bytes from any directory (`Tests/Parser/Serialize/emit.k`).

### Versioning

`CXXLValueRefType` / `CXXRValueRefType` write a flag, `ffi_spelled` (the node was written `ffi::ref<T>` / `ffi::mref<T>`), and `UnaryOperatorExpr` writes `const_addr`; both are in version 2.

Format version 4: `StringLiteralExpr::string_kind` and `StringData::prefix_kind` carry a `Bytes` bit (`1 << 2`), and a `UnionDecl` writes its `implements` list (a union's `impl` interfaces). Version 4 also removes the `ImplConformanceExpr` and `DerivesRelationExpr` kinds, so every expression kind after `AssignOperatorExpr` has a new number.

`AST_FORMAT_VERSION` is bumped by any change to what is written: a field added to or removed from a node, an enum that is written being renumbered (kinds, modes and flags are written by value), an encoding changed. A reader accepts exactly its own version and refuses every other; there is no migration, an old file is a miss. The source hash is checked the same way: every range in the file is an offset into one exact text.

### Primitives

| Primitive | Encoding |
|---|---|
| `flag` | one bit. Consecutive flags share a byte, low bit first; any other primitive ends the byte. |
| `num8/16/32/64`, `size_` | varint |
| `snum*` | zigzag varint |
| `en` | an enum's numeric value, varint |
| `str` | string index |
| `range` | [Ranges](#ranges) |
| `tok`, `ident` | [Tokens](#tokens) |
| `decl`, `expr`, `stmt`, `type_`, `pattern`, `dc` | [Nodes](#nodes) |
| lists | length, then the elements |

There is no primitive that writes a `SourceLocation`, a fid or an `imm` as a number.

### Ranges

A `SourceRange` is two global offsets, each a file's base plus an offset in it. The first varint's low two bits say which of four shapes follows:

| Tag | Shape | Rest |
|---|---|---|
| 0 | invalid (both ends zero) | nothing |
| 1 | starts in this file | upper bits: the start as a zigzag delta from the previous range's start in the same stream; then the length |
| 2 | starts in another file | upper bits: file index; then offset, length |
| 3 | anything else | each end as a location: 0, `0xFFFFFFFF`, an offset relative to this file's start, or file index and offset |

A node's ranges sit next to its parent's, so the delta is usually one byte. A location in no file (the alignment gap past a file's end) is kept relative to this file. The reader rebases every range on the file's base in its own process.

### Tokens

A `Token` is `{range, kind, imm}`, and `imm` is an index into a table that exists only in memory. What it stands for is written instead:

| After kind and range | When | Holds |
|---|---|---|
| 0 none | `imm` is `u32::MAX` | |
| 1 sentinel | `TkMacroExpand` with a `MacroSentinel` constant (`todo!`, `include!`, ...) | which one |
| 2 expanded | `TkMacroExpand` | payload index of its expansion record |
| 3 identifier | `LitIdentifier` | string index of its spelling |
| 4 literal | `LitInt`, `LitFloat`, `LitString`, `LitChar` | payload index of its literal slot |
| 5 number | every other kind | the value: such an `imm` indexes nothing (an error token's expected kind, the 0 of a token nothing wrote) |

A reader checks that the tag is the one the token's kind is written with, and that a payload index names a record of the class the kind needs: a kind that indexes a table must come back with an index into that table.

Tag 5 is a catch-all, so it is only as right as the list of kinds whose `imm` indexes a table. That list was audited against every writer of a token's `imm` in the lexer, the preprocessor and the parser the six kinds above index tables; an error token carries a hash or the kind it expected, a comment its class (doc, line, block), a newline its count, and nothing else carries one. **A new token kind whose `imm` indexes a table must get its own tag**, or it will be written as a number that means something only in the process that wrote it, and every same-process test will still pass.

**The table a token's `imm` indexes is the table of the file its range is in** (`TokenCacheManager::get_imm_table_for_token`), and for a wrapped token that holds twice: its expansion records are in the table of the file its own range (the invocation site) is in, and the token it stands for is in the table of the file its `def_range` is in, which for an imported macro is another file's. The reader restores each `imm` into the same table.

A **payload record** is `class, file index of its home table`, then:

| Class | Fields |
|---|---|
| int | body, prefix and suffix ranges; `value_lo`, `value_hi`; bits, base, flags; a big integer's limbs, bit count and sign when it has one |
| float | the three ranges; bits, base, flags; the value as its IEEE binary128 bits (low word first); a big float's mantissa, precision, exponent, sign when it has one |
| string | owned text bytes when it has any (`stringify!`, `file!`); body range; prefix and suffix tokens; prefix kind; the next part of a multi-part literal (a payload index); per f-string hole, the range of its braces and its token run; per hole, its spec and doc ranges |
| char | as a string, without owned text |
| expansion | `invoke_range`; the token this hop wrapped (`def_range`, `original_kind`, `original_imm`, written as a token: an inner record of the same chain, or the original token); the parent record; the macro's name (a preprocessor `SymbolID`, written as its spelling) |

Records are written in completion order: the tokens of a hole, the inner records of a chain and the next part of a literal are complete before the record that names them, so every payload reference points backward and a reader creates each slot once, in order. A slot two tokens share is one record.

**Macro-expanded tokens keep their expansion records.** The alternative, storing the unwrapped original, would lose the invocation and definition sites a diagnostic prints. With the records restored, a diagnostic against a reloaded tree prints the same location and the same `in expansion of macro` notes as against the parsed one, in both renderers (`Tests/Parser/Serialize/macros.k`).

Identifier spellings are found again by `find_ident` and otherwise interned into table-owned storage (`intern_ident_copy`), never into the reading context's arena. A spelling with a byte past ASCII is looked up by its bytes, lowest index first: the lexer hashes one value per decoded code point and `find_ident` one per byte, so the two disagree on such a name and it can be in a table twice.

### Nodes

A reference to a node is one varint: 0 for null, 1 followed by the node itself the first time any field reaches it, and `id + 2` for a node already written. **A node's id is its position in that order**, and it is what a later section refers to a node by. The tree is a DAG in places (a record's member is in its `fields` / `methods` list and in its visibility group's `members`; a scope's `dc_decls` holds its nested types and group wrappers), and this is what writes a node once: whichever reference comes first carries it.

A node is `kind` (and, when the kind is the family's Recovery kind, `recovery_kind`), the family header, then its class's fields. A recovery node is an object of the class its `recovery_kind` names, so that is the class the reader allocates. The reader registers a node's id before it reads the node's fields: a child's back-pointer to it is a reference that must already resolve.

| Family | Header |
|---|---|
| Decl | range; flags (has visibility, has context links, `poisoned`, `is_implicit`); annotations; visibility and its range; `lexical_dc`, `semantic_dc` |
| Expr | range; `poisoned`; annotations |
| Stmt | range; annotations |
| Type | range; `type_flags` (the parser's: a generic parameter is dependent from the moment it is parsed); qualifier flags; `poisoned`; annotations; address space; qualifier spans |
| Pattern | range; `poisoned`; annotations |

Annotations (attributes, and comments under `--preserve-comments`) are a list of `kind, name, range, arguments`; a name is a spelling. `presence` is derived from the entries on read.

A reference to a `DeclContext` is 0 for null, 1 for the TU, or 2 and a reference to the declaration that owns the scope.

147 of the 153 node classes are written. The six that are not are Sema's and cannot be in a parsed tree: the canonical types `QualifiedType`, `BuiltinType`, `RecordType` and `AssocType` (build-wide, interned, shared between files), `SubstGenericParamType` (substitution around a canonical type) and `VariantInitExpr` (minted around a resolved enum declaration, which may be another file's). The writer fails on a tree that reaches one. Classes that only a lowering mints but that hold nothing of Sema's (`SwitchDispatchStmt`, `ParenExpr`, `VerbatimExpr`, `InitListExpr`, `PanicOpExpr`, `ImplicitBoundaryCastExpr`, the C++ reference types, `OpaqueFFIType`) have `io_` functions; no parsed tree exercises them.

### The translation unit

The tree section's fields, before the nodes they pull in:

`has_eval_if`, `has_eval_for`, `has_prim_member`, `has_alloc_sugar`; `error_count`, `warn_count`; the `module a::b` pin (`pin_segments`, `pin_range`, `pin_extra_range`); `imports`; `macros`; `import_edges` (the target as a file index, the declaration as a node reference); `global_alloc`, `global_alloc_at`; `dc_decls`; the program's items (kind and node).

`ImportDecl` and `MacroDecl` are allocated where the preprocessor allocates them (`pp_alloc`, through their factories). An `ImportDecl`'s `resolved_fid` is written as a file index when `file_seg_count` says the path resolved; an ffi import's header fid and include closure are the driver's, written during Sema, and are not in a parsed tree.

### Files

A file other than the one being written is named in three places: a range inside it (a macro's definition site), the home of a payload, and the target of an import. Each is a file index. A file is identified by what is the same on every machine: its module path, its file name, its size and the hash of its bytes. A reader maps an index to the loaded file that matches all four, and fails the read when none does: the tree was built against text that is no longer there. The file table is therefore also the list of other files this tree depends on textually.

## What is rebuilt

| Rebuilt | By |
|---|---|
| `dc_scope` of the TU and of every named scope | `ASTParse::_wire_scopes`, against the file's hoisted table |
| `dc_symbols` (the frozen per-scope symbol tables); `lexical_dc` / `semantic_dc` of every declaration the tables hold; `tu->out_of_line` | `ASTParse::_build_symbols` |
| `tu->module_self` | `ASTParse::_synthesize_module_self` |
| `tu->scope`, `tu->ctx`, `tu->fid`, a node's `ctx` | the context being read into |
| a literal node's `imm` pointer | its token, as its factory finds it |
| `Annotation::presence` | `add_annotation` |

The reader calls `ASTParse::rebuild_derived`, which runs the first three exactly as `parse()` does after its loop. They are functions of the tree, and one implementation is what keeps a reloaded tree's tables identical to a parsed one's.

**The hoisted table (`DisambigTable`) is not serialized and not rebuilt by the reader.** It is the Index pass's artifact, built from tokens before any file is parsed and read by other files' parsers; a reader requires `ctx->hoisted` and fails without it. In a round trip it is the one `Parse.Index` built. A cache that loads a tree without lexing the file will need the table from somewhere: serialized as its own section, or built from the tree (every entry is a name and a range the tree also holds).

Redeclaration rings are the parser's one-link ring on every node (`init_redecl`) and are not stored; `is_this_definition` is. `RedeclMerge` and T are what link more.

## Slots that are not stored

Every slot a later stage writes is named in a debug check, by class: `Expr::type_`, `value_category`, `expr_flags`; `Type::canonical`, `size_bits`, `align_bits`; `Pattern::type_`, `resolved_decl`, `field_decl`, `pack_index`; every `resolved_*` / `candidate_cell` / `narrowed_from` / instance and witness slot; a call's `arg_map` and what `CallTyping` selects; the panic, ADT, constructor-init, fold-pin and lifecycle fields; `TemplateParams::instantiated_from`; the whole imported half of `FFILinkage`; on a TU, `import_overlay`, `cxx_module`, `body_ranges`, `panic_sites`, `cxx_escaping`, `has_eval_string`, `no_extensions`, `is_foreign`.

A failed check fails the write (`slot the serializer skips is set on a parsed tree: Class::field`). It means the tree is not a parsed tree, or the slot is the parser's after all and belongs in the stored set; either way the alternative would be a reloaded tree that silently differs.

A TU records its stage (`TranslationUnit::stage`: Preprocessing, Parsing, Sema). The parser and the reader set Parsing, Sema's constructor sets Sema, and a debug writer refuses a TU past Parsing. The per-slot checks stay for Sema writes another TU's Sema makes.

Two fields of a TU belong to the build and not to the tree, and are carried over by the driver rather than stored: `header_set` (the clang header set the preprocessor requested for the file's ffi imports) and what `stamp_tu_visibility` derives from the file's path.

## Driver flags

[Driver.md](Driver.md#driver-phases) lists them with the dump flags. All three run once every file is parsed and before any dump or Sema, on the driver thread, one file at a time (a reader appends to its file's immediate table and, for an imported macro's payloads, to another file's).

| Flag | Does |
|---|---|
| `--emit-ast-bin=<path>` | writes the entry file's serialized AST |
| `--ast-roundtrip`, or `KAIRO_AST_ROUNDTRIP=1` in the environment | for every parsed file: serialize, read back into the same context, and continue with the reloaded tree. The parsed tree is abandoned in its arena (the macro table still names its `MacroDecl`s). |
| `--verify-ast-roundtrip` | for every parsed file: serialize, read into a second context, compare with the parsed tree, and report the first difference as I002F. The parsed tree stays. |

`--verify-ast-roundtrip` compares, weakest oracle first: the `--print-ast=tree` rendering (`PrintOptions::dump_plain`), line by line; the bytes of the reloaded tree serialized again, which covers every stored field the printer does not show; and what the reader rebuilt (scope wiring, symbol tables, the out-of-line list, the file's module declaration), node by node, since the writer's and the reader's node tables are index-aligned. It then hands a reader the same bytes damaged four ways (the version changed, the source hash changed, the last third cut off, the last byte cut off) and requires each to be refused, since nothing else ever reads a file that is not the one just written.

The two round-trip flags can be given together (the tree is verified, then replaced).

Both directions are recursive over the tree except down the left spine of a binary operator chain, which is walked in a loop: `a + b + c + ...` nests as deep as it is long and the parser builds it without recursion, so it is the one shape that is deeper than a stack while still being ordinary source. `--verify-ast-roundtrip` renders both trees with the AST printer, which does recurse there; it fails on the inputs `--print-ast=tree` fails on.

`--print-stats` adds `[stats] ast-serialize: N files, B bytes for S source bytes, ...`. The line, and the `Parse.ASTSerialize` rows of `--time-passes` (`Write`, `Read`, `Compare`), exist only when one of the flags is set.

## Measured

The compiler's own tree (`Compiler/Driver/Kairo.k` with the flags of `kairo_compile.json`: 378 files, 12.37 MB of source), **debug** compiler. The serializer runs on one thread; the parse rows are the same binary's `--time-passes`.

| | |
|---|---|
| Serialized | 16.14 MB, 1.30x the source: 1.195 M nodes, 0.783 M tokens, 52.5 k payload records |
| Write, all files | 0.86 s |
| Read, all files, the rebuild included | 0.81 s |
| `Parse.Full` | 7.10 s of CPU (0.35 s wall on 24 threads) |
| `Parse.Index`, the preprocessor's walk | 0.64 s and 4.96 s of CPU, which a load without lexing also saves |

`Tests/` (2613 files, each alone): 4.03 MB for 4.67 MB of source, 0.86x; test sources are mostly comments, the compiler's are mostly code. With `--preserve-comments` the same files are 4.18 MB (0.89x) and the compiler's tree 16.35 MB.

Where the bytes go: a node costs at least five (reference marker, kind, range, flag byte) and a simple named type about 28 (a `ChainType`, its segment and the segment's `NamedIdentExpr`). The one known slack is token kinds: `TokenKind` values of keywords and operators are 32-bit spelling hashes and are written as five-byte varints; a per-file kind table would make them one byte.

## What the Sema section needs

Version 1 gives a later Sema-facts section:

- **Node ids.** Every node has one, stable for a given tree, and both a writer and a reader hold the id-to-node table. A fact about a node of this file is `(node id, slot, value)`.
- **Skippable sections.** A Sema section appended after the tree leaves the AST section's bytes unchanged, and a reader that wants only the tree does not read it.
- **A file table** with content hashes, which a reference to another file's node extends naturally: `(file index, node id)`.
- **Payload tables** for whatever tokens Sema synthesizes.

It lacks, and the Sema section will have to add:

- **Canonical types.** They are build-wide and interned; a file's section must describe each one it uses structurally (a `RecordType` as its declaration reference and arguments) and the reader must intern them into the store.
- **Cross-file node identity.** A reference to another file's node is valid only against that file's own serialized tree with the same node numbering, so the section must record, per file it refers to, the hash that tree was written from; node ids are per tree, not per source text.
- **Nodes Sema adds.** Instances, lowered nodes, implicit members and synthesized declarations have no id in the parsed tree; they need their own id space or a second tree section written after Sema.
- **The hoisted table**, for a load that does not lex ([What is rebuilt](#what-is-rebuilt)), and the macro table's token runs for a file whose macros another file expands.
- **A reader that runs off the driver thread.** Version 1's reader writes into another file's immediate table for an imported macro's payloads, which is only safe while nothing else runs.
