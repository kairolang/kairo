# Lexing and preprocessing

The front end turns each source file into the token stream the parser reads. The lexer (`Compiler/Lexer/`) produces tokens on demand; the preprocessor (`Compiler/Preprocessor/`, `Compiler/Macro/`) pulls them one at a time, consumes imports and macro definitions into the file's translation unit, expands macro invocations, and writes the result into a per-file token buffer. Where these phases sit in a compilation is in [Pipeline.md](Pipeline.md#compilation-phases); what the parser does with the buffer is in [Parsing.md](Parsing.md#parser-structure).

What identifiers, literals and macros mean is defined by the language reference (pages *variables*, *primitives*, *macros*, *macros-builtin*; see [README.md](README.md#language-reference)). This document owns how the compiler recognises them.

## Source files

A source file is UTF-8. `Lexer::open` loads the file through the `SourceManager`, waits for its line index, and calls `SourceManager::validate_utf8`, which reports each maximal run of invalid bytes once as S072E. Lexing continues past invalid bytes: the decoder returns U+FFFD for each, and `name_char_kind` classifies U+FFFD as an identifier-only character, so a bad byte inside a name does not split it and add a second error. A file whose bytes would carry a `SourceLocation` past the 4 GB location space is an ICE in `open`. The preprocessor rejects files larger than `--cmax-file-size-mb` (default 256) with S066E before walking them (`PreProcessor::_walk_one`).

### Character classes

Every decoded code point falls in one `CharClass` (`Compiler/Native/CharTable.hh`). The class of the first character selects the scanner (`Lexer::get_token`).

| Class | ASCII members | Non-ASCII members | Scanner |
|---|---|---|---|
| `Identifier` | `A-Z a-z _ #` | `iswalpha`/`iswdigit`, plus the range table (Greek, Cyrillic, Armenian, Hebrew, Arabic, Devanagari, kana, CJK, letterlike symbols, mathematical alphanumerics, combining marks) | `lex_name` |
| `Number` | `0-9` | none | `lex_number` |
| `Operator` | `{ } ( ) [ ] + - * / % ^ \| & ~ < > ! = ? @ : ; , . \` | none | `lex_symbol` |
| `String` | `" '` | none | `lex_text` |
| `Whitespace` | 0x00-0x20 except `\n` `\r` | `iswspace`, U+00A0, U+2000-U+206F | `lex_whitespace` |
| `NewLine` | `\n` `\r` | none | `lex_whitespace` |
| `Illegal` | `$`, `` ` ``, DEL | anything unclassified | `lex_illegal` |

The ASCII classes come from a 128-entry table; the name-character and operator-character sets used inside a scan come from `ASCII_LEX_FLAGS`, which is generated at compile time from the same case-list macros, so the two cannot drift. `normalize_char32` maps confusables (fullwidth ASCII, curly quotes, guillemets) to ASCII; the whitespace and number scanners apply it, the identifier and string scanners do not.

`lex_illegal` runs the identifier scanner. A non-ASCII illegal character is identifier-only to `name_char_kind`, so it lexes as part of an identifier; an illegal ASCII byte is no name character and becomes a one-character `TkUnknown` token with no lexer diagnostic. The parser reports it where it expected something else.

### Streaming interface

The lexer is a pull stream, one per file (`Compiler/Lexer/Lexer.k`):

| Method | Contract |
|---|---|
| `open(fid)` | Loads the file and validates UTF-8. The file's `ImmediateTable` is usable as soon as it returns. |
| `next(out)` | Produces one token and returns true; never blocks. `TkWhitespace` is never surfaced. After the last token it produces exactly one `TkEof`, then returns false forever. |
| `drain()` | Runs `next` to exhaustion into a `TokenBuffer<512>`; used by the lexer's own tests (`lex`). |
| `lex_slice(start, end)` | Lexes a byte range of the same file with a sub-lexer that shares the parent's `ImmediateTable`. Used for f-string holes. |
| `close()` | Ends the stream. Immediate indices already handed out stay valid: the table belongs to the file's `TokenCacheManager` slot, not to the stream. |

Malformed input never stops the stream. A lexical error produces a `TkError` token (or a diagnostic attached to an otherwise normal token) and scanning resumes after it; every scanner advances the cursor by at least one character.

`TokenCacheManager` (`Compiler/Token/TokenCacheManager.k`) owns one slot per file id: the lexer, the file's `ImmediateTable`, and the preprocessed `TokenBuffer`. A file is tokenized twice, once by the dependency scan and once by the preprocessor walk; the diagnostic engine drops the second copy of each lexer diagnostic ([Diagnostics.md](Diagnostics.md#rendering)).

## Tokens

A `Token` (`Compiler/Token/Token.k`) is 16 bytes: a `SourceRange` (two 32-bit locations), a `TokenKind` (`u32`), and `imm`, a `u32` index into the file's `ImmediateTable` or `u32::MAX` for none.

A keyword's or operator's `TokenKind` value is the hash of its spelling (`HashState` in `Compiler/Support/EvalHash.k`, folded to 32 bits). The scanners hash characters as they consume them and accept the lexeme when `is_valid_token_kind(hash)` holds, so recognising a keyword or operator is one switch, with no table lookup. `is_valid_token_kind` is a hand-written list in `Compiler/Token/TokenKind.k` that must name every kind in the enum. Non-hashed kinds use reserved low values:

| Kind | Meaning | `imm` |
|---|---|---|
| `TkUnknown` | unrecognised character | none |
| `TkEof` | end of stream | none |
| `TkError` | malformed lexeme | the kind that was expected |
| `AtComment` | comment | 0 block, 1 doc line (`///`, `//<`), 2 line, 3 doc block (`/**`) |
| `TkNewLine` | a whitespace run containing at least one newline | number of newlines in the run |
| `TkWhitespace` | a whitespace run without newline; never leaves the lexer | none |
| `TkMacroExpand` | a token produced by macro expansion ([Macros](#macros)) | `MacroExpansionInfo` index or a sentinel |
| `TkFileStart`, `TkFileEnd`, `TkGenerated`, `TkCodeComplete` | reserved markers | |
| `LitIdentifier` | identifier | interned identifier index |
| `LitInt`, `LitFloat`, `LitString`, `LitChar` | literals ([Literals](#literals)) | immediate record index |

`TokenText::resolve` (`Compiler/Token/TokenText.k`) is the only sanctioned way to turn a token into its spelling: identifiers come from the interner (a synthesized identifier has no source bytes), literals from their immediate records, keywords and operators from their canonical spellings. No code outside that file reads token text from a source range.

### Identifiers

`lex_name` consumes name characters while hashing them. A lexeme stays a keyword candidate only while every character is ASCII `[A-Za-z0-9_]` and the length is at most 32 bytes; the first `#` or non-ASCII character makes it an identifier. A candidate whose hash is a valid kind is a keyword ([Keywords](#keywords)); anything else is `LitIdentifier`. Identifiers have no length limit. `ImmediateTable::intern_ident` interns the spelling in an open-addressed table keyed on the same hash, so equal spellings in one file share one `imm`.

An identifier of at most two bytes followed directly by `"` or `'` is checked as a string prefix ([Strings and characters](#strings-and-characters)).

### Operators and punctuation

`lex_symbol` reads up to four operator characters, hashes each prefix, and takes the longest prefix that is a valid kind. The operator set is:

```text
{ } ( ) [ ] \ ; : , . :: ... ..  ..=
+ - * / % ^ ^^ & | ~ ! ? ?? @ = ++ --
+= -= *= /= %= &= |= ^= <<= >>= @=
== != === < > <= >= <=> << >> && ||
-> ->* => . .* ?. ?.* ?-> ?->*
```

Rules that override longest match:

- `//` and `/*` start comments; a stray `*/` is a `TkError`.
- `.` followed by a digit starts a leading-dot float (`.5`) unless the previous token can end a postfix chain: an identifier or keyword, a literal, `)` or `]` (`_prev_can_end_postfix`). After those, `.` is member access, so `t.0`, `(a, b).1` and `arr[i].0` lex as `.` and an integer.
- `>=` directly followed by `>`, and `>>=` directly followed by `>`, give up their `=` so it can form `=>`: `case Box<i32>=> 1` lexes `>` `=>`. No prefix `>` exists, so no program that lexed before changes meaning. The parser splits the remaining `>>` when it closes generic lists.

### Comments

A line comment runs from `//` to the end of the line, excluding the newline. A block comment runs from `/*` to the matching `*/` and nests. An unterminated block comment is a `TkError` with no diagnostic (a logger warning only). Comments are dropped by the preprocessor's token source unless `--preserve-comments` is given; comments that reach the parser become annotations on the next declaration ([Parsing.md](Parsing.md#parser-structure)).

### Whitespace and newlines

`lex_whitespace` consumes a maximal run of whitespace and newlines as one token. A run containing a newline is `TkNewLine` with the newline count in `imm`; a run without one is `TkWhitespace` and is discarded by `next`. Newlines reach the parser because they terminate statements.

### Conflict markers

A run of seven or more `<`, `=` or `>` at the start of a line is a git conflict marker. The lexer consumes the rest of the line and emits one `TkError`; it reports no diagnostic, only a logger warning. Mid-line runs are ordinary operators, so seven nested generic closers lex. `_conflict_state` records the last marker seen but nothing reads it.

## Keywords

A keyword is a lexeme that passes the keyword-candidate test in [Identifiers](#identifiers) and whose spelling hash is a `TokenKind`. Because `#` is a name character that never occurs in a keyword, `#op` or `#type` is an identifier that spells like a keyword (language reference, *variables*, Identifiers).

The set below is the enum in `Compiler/Token/TokenKind.k`, grouped by its section comments. A spelling outside this table is an identifier, including type names such as `string`, `vec` or `map` that the library declares.

| Group | Keywords |
|---|---|
| Control flow | `return` `break` `continue` `panic` `match` `case` `default` `catch` `try` `finally` `if` `else` `while` `for` `assert` `loop` |
| Declarations | `var` `const` `fn` `op` `class` `union` `enum` `type` `struct` `interface` `extend` `module` `test` `macro` `import` `override` `final` `ffi` `impl` `derives` `where` `requires` |
| Access control | `pub` `priv` `prot` |
| Specifiers and qualifiers | `eval` `unsafe` `static` `async` `inline` `atomic` `volatile` `virtual` `mutable` |
| Special identifiers | `self` |
| Literals | `true` `false` `null` |
| Binary operators | `in` `as` |
| Word operators | `and` `and_eq` `bitand` `bitor` `compl` `not` `not_eq` `or` `or_eq` `xor` `xor_eq` |
| Primitive types | `void` `bool` `byte` `char` `usize` `isize` `f8` `f8e4m3` `f8e5m2` `bf16` `f16` `f32` `f64` `f80` `f128` `f256` `f512` `u8` `u16` `u32` `u64` `u128` `u256` `u512` `i8` `i16` `i32` `i64` `i128` `i256` `i512` |
| Unary keywords | `await` `thread` `spawn` `yield` `sizeof` `alignof` `typeof` |
| Reserved | `delete` |
| Builtins | `__file__` `__line__` `__column__` `__function__` `__module__` `Self` |

Notes on particular kinds:

- The word operators are C++ alternative tokens. `lex_name` replaces each with its operator kind through `substitute()` (`and` is `&&`, `bitand` is `&`, `xor_eq` is `^=`, ...), so no later stage sees the word.
- Primitive type names are keyword tokens (`At*` kinds), never identifiers, which is why `i32` resolves without a symbol table lookup ([Parsing.md](Parsing.md#ast), canonical nodes).
- `Self` is `BiSelf`, a keyword, so no declaration (an enum variant included) can be named `Self`; in expression and pattern position it parses as an ordinary name and never takes generic arguments ([Parsing.md](Parsing.md#disambiguation)).
- `null` is the literal kind `LitNull`.
- `delete` stays a keyword (`KwDelete`) although Kairo has no `delete` expression and `op delete` is no longer the destructor (0.2.0). It is reserved so the parser can answer the old forms precisely: `delete p` is S091E with a fix-it to `@destroy`, `fn op delete(self)` / `x.op delete()` are S090E with a fix-it to `finally`. It is also the `= delete` body and the second half of `@cxx::delete`.

## Literals

Every literal token carries an immediate record in the file's `ImmediateTable` (`Compiler/Lexer/Immediate.k`). The table holds arena lists of `IntData`, `FloatData`, `StringData`, `CharData`, `IdentData` and `MacroExpansionInfo`; indices are stable for the table's lifetime. Records store source ranges for the body, prefix and suffix rather than copies, so a diagnostic can point at the exact part of a literal.

### Numbers

| Part | Rule |
|---|---|
| Prefix | `0b`/`0B` (base 2), `0o`/`0O` (base 8), `0x`/`0X` (base 16); otherwise base 10. |
| Digits | Digits of the base. `_` is accepted only directly after a digit. |
| Fraction | `.` in base 10 or 16, only when followed by a digit of the base, only once, and not after `_`. `1.` is the integer `1` then `.`, so `1.foo()` is a call. `..` ends the number, so `1..5` is a range. |
| Tuple index | A number glued to a preceding `.`, `->`, `?.` or `?->` never takes a fraction: `t.0.1` is two member accesses. |
| Exponent | `e`/`E` in base 10, `p`/`P` in base 16, then an optional sign and decimal digits; once per literal. Bases 2 and 8 have no fraction and no exponent. |
| Suffix | Name characters directly after the digits are lexed by `lex_name` and recorded as the suffix range. |

A literal with a fraction or exponent is `LitFloat`, otherwise `LitInt`. The lexer evaluates the value synchronously when it creates the record (`IntData::evaluate`, `FloatData::evaluate`): integers accumulate in 64 bits, then 128, then an arbitrary-width `ImmBigInt`; floats accumulate in `ImmFloat`, which is `f80` on x86 hosts and `f128` elsewhere. Range checks against a target type are Sema's. The `ImmediateTable` counts evaluations in flight (`begin_evaluation`/`end_evaluation`) so `wait_for_evaluation` is correct if evaluation is ever moved off the lexing thread.

The number grammar is permissive by design for now: any name after the digits is a suffix, and underscore placement is checked only against the previous character.

### Strings and characters

`"` starts a `LitString`, `'` a `LitChar`. A string opened with `"""` is triple-quoted: it ends at the next `"""`, and a lone `"` inside it is content. Character literals are never triple-quoted.

A prefix is an identifier of one or two letters written directly before the quote:

| Prefix | Meaning |
|---|---|
| `f`, `F` | format string: `{...}` holes |
| `r`, `R` | raw string: backslash is literal |
| `fr`, `rf` (any case) | raw format string |

No other prefix exists. The prefix kind is stored in the record as `TextPrefixKind`.

Escapes, checked by `Lexer::is_valid_escape`:

| Escape | Rule |
|---|---|
| `\n \r \t \v \f \a \b \' \" \\` | accepted |
| `\{ \}` | accepted in format strings; elsewhere S022W |
| `\xHH` | exactly two hex digits (S023E) |
| `\o`, `\oo`, `\ooo` | one to three octal digits, value at most 0xFF (S027E); accepted with S025W |
| `\uHHHH` | exactly four hex digits (S028E); a surrogate is S031E |
| `\UHHHHHHHH` | exactly eight hex digits (S028E); above U+10FFFF is S030E; a surrogate is S031E |
| anything else | S033E |

In a raw string a backslash is content. In a raw string that is not triple-quoted, `\` followed by the closing quote warns S017W: the quote ends the string. A missing closing quote is S012E.

In a format string, `{` opens a hole and the scanner tracks nested braces, brackets and parentheses, skipping string literals inside the hole. At the hole's top level, outside brackets, a `:` that is not half of `::` starts the format spec, and an `=` directly before `}` or `:` (and not the second character of `==`, `!=`, `<=`, `>=`) marks a self-documenting hole `{x=}`. A newline inside a hole is S018E; an unmatched `}` is S016E. After the closing quote, `emit_fstring_exprs` lexes each hole's expression bytes (up to the `=` or `:`) with `lex_slice` into a `TokenBuffer<16>` stored in `StringData::exprs`, and records the spec and self-documenting ranges in a parallel `HoleSpec`. The spec bytes are never tokenized; their parsing and the lowering of holes are in [FormatStrings.md](FormatStrings.md#lowering).

Name characters directly after the closing quote are recorded as the literal's suffix, except a string prefix glued to a `"` (`"a"f"b"`): that starts the next segment of a chain (below), not a suffix.

Adjacent string literals separated only by spaces, tabs and newlines form one logical string, whatever their prefixes (P486): `chain_adjacent_text` lexes the next literal and links its record through `StringData::next`, and only the head token is emitted. That token's range runs from the head's start to the last segment's end (P879), so whatever reads a token's text by its range (stringify!, a diagnostic caret) sees the whole chain; a reader that colours or lays out the later segments itself (kals' semantic tokens, kfmt) takes the head's own extent from `chain_head_len`. The next literal is one that starts with `"`, or with a string prefix glued to its quote (`f`, `r`, `fr`, `rf`, any case; `string_prefix_len` admits exactly the spellings `lex_name` accepts, and `lex_name` lexes it). A prefix with a space before its quote (`"a" f "b"`), a word that is not a prefix (`ff"b"`, `b"x"`: there are no byte strings), and a char literal do not chain. Triple-quoted literals chain like any other. Each segment is lexed under its own prefix and keeps its own record (body, prefix, suffix, holes), so its escapes and holes are its own and diagnostics name the segment a byte came from. When no literal follows, the cursor is restored so the newline after a lone string still terminates its statement.

The parser makes one `StringLiteralExpr` of a chain. Its kind's Raw bit is the head's (every decoder reads each later segment's Raw off its `prefix_kind`); its Format bit is set when any segment is an f-string, and its parts are the holes of every segment, in order (`StringLiteralExpr::hole_segment` / `hole_index` / `hole_spec` map a part back). A chain with an f segment is therefore one f-string: its value and type (`string`) are those of the segments joined with `+`, its holes evaluated in source order, and `FStringLowering` emits each segment's text decoded under its own prefix. A chain with no f segment (plain and raw) stays one compile-time literal. A literal suffix on any segment is the whole chain's, as in C++ (P878, `LiteralTyping::_chain_suffix`): `"12" "3"_km` is `"123"_km`, and the head's suffix reads the same way. Every chain with a suffix warns SC276W, with a fix-it that joins the segments into one literal when their text can be joined (every segment has the head's prefix, none is an f segment, triple-quoted or made by a macro; otherwise the warning names the edit and makes none); segments that spell different suffixes are SC277E; a suffix on any segment of a chain with an f segment is SC074E (a format string takes no suffix). Before P486 only an unprefixed continuation chained, and a prefixed one was a second token, a new statement whose value was discarded.

## Preprocessor

The preprocessor (`Compiler/Preprocessor/Preprocessor.k`) runs once per compilation over the entry file's import closure. Its result is a `PPResult`: success, the closure's file ids (sorted), and the builtin module's file id for Sema.

### Import graph

`DepScanner::build_graph` walks the closure from the entry file on one thread. For each file it opens a scan stream, reads only the import statements through `ImportGrammar` (`Compiler/Parser/Shared/ImportGrammar.k`, hosted by `StreamCursor` in silent mode), resolves each path ([Imports.md](Imports.md#path-resolution)), and records the edge in a `DepGraph` (`deps`, `rdeps`, `in_degree`, `mod_paths`). An edge that would close a cycle is not added; the cycle is recorded in `DepGraph::cycles` and reported after the walk at the import that closes it, with a note at each other edge (`_report_cycle`): R058W by default, R058E under `-fno-import-cycles`, which stops the build after parse. A cycle through the builtin root is not reported. Sema compiles a cycle as one group ([Pipeline.md](Pipeline.md#compilation-phases)). Exceeding `--cmax-import-depth` (default 512) is R019E. In a batch of inputs, files an earlier input already scanned are followed through their recorded edges instead of being rescanned.

`preprocess` then adds edges no file wrote:

| Edge | Condition |
|---|---|
| entry to the builtin root module | unless `--no-prelude` or `--freestanding`; `--prelude <file>` replaces the root with that file |
| entry to each `--force-include` file | always |
| each file using `@create`/`@destroy` to `builtin::base::alloc` | default prelude only |
| every file outside the builtin root's own closure to the builtin root | so builtin macros are defined before any file expands one |

### Walk

Files on an import cycle are lexed in full first and their macro definitions registered (`_prelex_cycles`, `PPWalker::collect_macros`), so every file on the cycle sees every macro the cycle defines whatever order the walk takes; their walks then replay the saved tokens. `WaveExecutor` then dispatches every file whose dependencies are done to the thread pool, wave by wave, so an importee is always walked before its importers. It counts down a copy of `in_degree`, so the graph keeps the scan's counts. A file the waves never reach (`WaveExecutor::stranded`) is reported as I003E (a scanner bug: every cycle edge was dropped).

`PPWalker::run` walks one file over a `TokenSource` (`Compiler/Preprocessor/TokenSource.k`). Frame 0 of the source is the streaming lexer with a small lookahead ring; frames above it are macro splices. The source drops `AtComment` unless `--preserve-comments` is set, and enforces `--cmax-token-count` (S065E). The walk dispatches on each token:

| Token | Action |
|---|---|
| `ffi` | `_handle_ffi`: records header imports (source order, C or C++) for the file's header set and passes `ffi` blocks through to the parser ([Interop.md](Interop.md#ffi-imports)) |
| `import` | `_handle_import`: parses the import with `ImportGrammar`, builds an `ImportDecl` in the translation unit and indexes it in `FileImportIndex`; default visibility `priv`. Imports are not emitted. |
| `macro` | `_handle_macro_def`: registers a token macro; default visibility `pub`. Not emitted. |
| `pub`/`priv`/`prot` | before `import` or `macro`: consumed, and sets that declaration's visibility; before `module`: emitted (the parser needs `pub module Foo {`) and sets the scope's visibility; otherwise emitted |
| `module`, `{`, `}` | emitted, and tracked by `ScopeTracker` so macro definitions get their module scope |
| `name!` | invocation: expanded ([Macros](#macros)) |
| anything else | emitted |

Every emitted token passes through `_emit`, which rejects `import` and `macro` produced by an expansion (R012E), expands tokens inside f-string holes, and wraps expansion output with its origin chain. The output buffer becomes the file's slot in `TokenCacheManager`, which the parser reads.

`-D NAME[=VALUE]` defines a token macro whose body is `VALUE` (default `1`) lexed from a virtual file (`_register_defines`); an empty name is U006E. The driver can add one late define (`define_late`, used for `__KAIRO_GLOBAL_ALLOCATOR_SET`) before any file is walked.

## Macros

The language rules for token macros (parameters, defaults, variadics, pattern expansion, scoping) are in the language reference, *macros* and *macros-builtin*. This section covers the implementation.

### Definitions

`_handle_macro_def` parses the header with `MacroHeaderGrammar` (`Compiler/Parser/Shared/MacroHeaderGrammar.k`), the grammar the parser shares: `name ! ( params )?`, where a parameter is `IDENT`, `IDENT = default`, `...IDENT` or `...`; the `!` is required (S037E), a variadic parameter is last, and a required parameter cannot follow a defaulted one. The body is a brace-balanced raw token run. `MacroTable` (`Compiler/Preprocessor/MacroTable.k`) pairs the translation unit's `MacroDecl` with an owned `TokenBuffer` holding the body and the default-value runs. A definition whose body contains `import` or `macro` is rejected at definition time; the R012E check in `_emit` is the backstop. A builtin macro name cannot be redefined. `macro @` introduces a procedural macro, which the walk passes to the parser unexpanded.

Visibility is order-dependent and scoped: a macro is visible after its definition, inside its module scope, subject to `pub`/`priv`/`prot`. An imported macro is visible once its file has been walked, which the wave order guarantees. `FileImportIndex` (`Compiler/Preprocessor/FileImportIndex.k`) maps the forms `import Foo::mac!`, `import Foo::{mac!}` and `import Foo::*` to bare names, and plain or aliased module imports to qualifiers for `Foo::mac!`. A `pub import` does not re-export macros: a wildcard import's macros are not followed through the imported file's own `pub import`s. The intended rule is that `pub import x::*` re-exports x's `pub` macros, as it does declarations ([Re-exports](Imports.md#re-exports)); not implemented.

### Expansion

`_detect_invocation` recognises an invocation and `_expand` handles it:

1. An unqualified name is first tried as a builtin (`_try_builtin`: `file`, `line`, `column`, `module_path`, `count`, `first`, `last`, `rest`, `butlast`, `paste`, `stringify`, `unstringify`, `defined`, `todo`, `unreachable`, `unreachable_unchecked`, `unique_id`, `include`, `embed_str`, `embed`, `compile_error`, `compile_warn`, `compile_note`). `defined!(NAME)` becomes `true` or `false` when `NAME` is a Kairo macro; otherwise it is passed through unchanged for the parser's `DefinedExpr`, since only Sema can ask clang about C macros. The parser intrinsics `label`, `jump` and `unwrap` are also reserved and are passed through to the parser.
2. Otherwise the name resolves through `_resolve`. An unknown macro is R013E; a parameterised macro written without arguments is R006E, and the reverse R007E.
3. Expansion depth beyond `--cmax-macro-depth` (default 128), more than `--cmax-macro-expansions` expansions per file (default 65536, 0 for unlimited), and a macro that reaches itself through the active chain are all R008E. The depth error is reported once per outermost invocation.
4. Arguments are expanded first, in the caller's context, before the callee's frame exists, so `square!(square!(x))` is not a cycle. `_bind_and_substitute` builds the substituted body.
5. The body is pushed as a splice frame on the `TokenSource`; the same walk rescans it on the following iterations, so nested invocations are found by `_detect_invocation` again.

An f-string is one token whose holes are token buffers. A macro parameter written in a hole (`macro g!(x) { f"v={x}" }`) is substituted when the body is bound, and an invocation inside a hole (`f"v={m!}"`) expands when the f-string is emitted (`_expand_fstring`), so holes see the same expansion as the code around them.

A failed expansion emits one poison token (`MacroSentinel::Poison`) in place of the invocation so the parser does not report a second error there. `--macro-debug` (optionally `--macro-debug-filter`, `--cmacro-trace-depth`) prints each expansion to stderr.

### Origin tracking

Each token that leaves a splice frame is wrapped by `_wrap_origin`: its kind becomes `TkMacroExpand`, its range the outermost invocation, and its `imm` the head of a chain of `MacroExpansionInfo` records (one per active frame: invocation range, definition range, original kind and `imm`, macro name). `TokenText::unwrap_expansion` walks a chain back to the original token; the parser's `resolve_kind_deep` uses it, and diagnostics attach the expansion backtrace from it (limited by `--cmax-macro-backtrace`, default 8).

An `imm` at or above `MacroSentinel::Threshold` (`Compiler/Macro/Sentinel.k`) is a sentinel, not a record index. The builtins `todo!`, `unreachable!`, `unreachable_unchecked!`, `include!`, `embed_str!` and `embed!` expand to a single `TkMacroExpand` token carrying their sentinel. Only `Poison` has a consumer in `Compiler/Parser/`; the others reach the parser as tokens no production accepts.
