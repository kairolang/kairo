# lexical specification

*version: stage1 (bootstrap lexer)*

---

# table of contents

- [lexical specification](#lexical-specification)
  - [1. scope and responsibilities](#1-scope-and-responsibilities)
  - [2. character model](#2-character-model)
    - [2.1 input encoding](#21-input-encoding)
    - [2.2 unicode handling rules](#22-unicode-handling-rules)
  - [3. character classification](#3-character-classification)
  - [4. token stream invariants](#4-token-stream-invariants)
  - [5. token categories](#5-token-categories)
  - [6. identifiers and keywords](#6-identifiers-and-keywords)
    - [6.1 grammar](#61-grammar)
    - [6.2 keyword grammar](#62-keyword-grammar)
    - [6.3 resolution rules](#63-resolution-rules)
    - [6.4 invariants](#64-invariants)
  - [7. numeric literals](#7-numeric-literals)
    - [7.1 base prefixes](#71-base-prefixes)
    - [7.2 integer literals](#72-integer-literals)
    - [7.3 floating-point literals](#73-floating-point-literals)
    - [7.4 numeric invariants](#74-numeric-invariants)
  - [8. operators and punctuation](#8-operators-and-punctuation)
    - [8.1 grammar](#81-grammar)
    - [8.2 constraints](#82-constraints)
  - [9. comments](#9-comments)
    - [9.1 line comments](#91-line-comments)
    - [9.2 block comments](#92-block-comments)
  - [10. string and char literals](#10-string-and-char-literals)
    - [10.1 delimiters](#101-delimiters)
    - [10.2 prefixes](#102-prefixes)
    - [10.3 string body grammar](#103-string-body-grammar)
    - [10.4 escape sequences](#104-escape-sequences)
      - [basic escapes](#basic-escapes)
      - [hex escapes](#hex-escapes)
      - [octal escapes (byte only)](#octal-escapes-byte-only)
      - [unicode escapes (non-byte only)](#unicode-escapes-non-byte-only)
    - [10.5 format strings](#105-format-strings)
    - [10.6 string invariants](#106-string-invariants)
  - [11. whitespace and newlines](#11-whitespace-and-newlines)
  - [12. error handling](#12-error-handling)
    - [12.1 error tokens](#121-error-tokens)
    - [12.2 invariants](#122-invariants)
  - [13. immediate evaluation model](#13-immediate-evaluation-model)
  - [14. conflict marker handling](#14-conflict-marker-handling)
  - [15. guarantees to downstream stages](#15-guarantees-to-downstream-stages)
  - [16. non-goals (explicit)](#16-non-goals-explicit)
  - [17. known limitations (stage1)](#17-known-limitations-stage1)
  - [18. forward compatibility notes (non-normative)](#18-forward-compatibility-notes-non-normative)

---

## 1. scope and responsibilities

the lexer is responsible for:

* converting a utf-8 source file into a linear token stream
* producing **no semantic meaning**
* validating **lexical correctness only**
* emitting **Immediate** records for literal tokens
* preserving exact **source ranges** for all tokens

the lexer **must not**:

* perform name resolution
* validate numeric ranges beyond lexical constraints
* reject constructs that are syntactically valid but semantically invalid

---

## 2. character model

### 2.1 input encoding

* source input is utf-8 encoded
* decoding is performed incrementally
* invalid utf-8 sequences yield a zero-length decode and terminate scanning

### 2.2 unicode handling rules

* identifiers may contain arbitrary unicode scalar values
* keywords are restricted to **single-byte ascii**
* operators and punctuation are restricted to **single-byte ascii**

---

## 3. character classification

each decoded `char32` is classified into exactly one `CharClass`:

| class      | description              |
| ---------- | ------------------------ |
| Identifier | name or keyword start    |
| Number     | numeric literal start    |
| Operator   | operator or punctuation  |
| String     | string or char delimiter |
| Whitespace | horizontal whitespace    |
| NewLine    | line terminator          |
| Illegal    | invalid code point       |
| Unassigned | reserved / undefined     |

classification is **context-free** and based solely on the character.

---

## 4. token stream invariants

the following invariants **must always hold**:

1. token ranges are contiguous and non-overlapping
2. tokens are emitted in strict source order
3. every token range refers to valid source memory
4. whitespace tokens may be dropped but **cursor movement is never skipped**
5. immediate indices are stable for the lifetime of the lexer
6. error tokens do not suppress further lexing

---

## 5. token categories

the lexer emits tokens belonging to the following high-level groups:

* identifiers / keywords
* numeric literals
* string / char literals
* operators / punctuation
* comments
* whitespace / newline
* error / unknown

---

## 6. identifiers and keywords

### 6.1 grammar

```ebnf
identifier :=
    identifier_start identifier_continue*

identifier_start :=
    unicode_scalar
  | '_'
  | '#'

identifier_continue :=
    identifier_start
  | decimal_digit
```

### 6.2 keyword grammar

```ebnf
keyword :=
    ascii_letter (ascii_letter | decimal_digit | '_')*
```

constraints:

* length ≤ 32 bytes
* ascii-only
* no `#`
* no multibyte utf-8

### 6.3 resolution rules

* if the lexeme matches a keyword hash → keyword token
* otherwise → `LitIdentifier`
* once a multibyte character is seen, the token **cannot** be a keyword

### 6.4 invariants

* keywords and identifiers share the same scanning logic
* keyword detection is opportunistic and aborts early
* identifiers have no length limit

---

## 7. numeric literals

### 7.1 base prefixes

```ebnf
base_prefix :=
    "0b" | "0B"   // base 2
  | "0o" | "0O"   // base 8
  | "0x" | "0X"   // base 16
```

default base is 10.

---

### 7.2 integer literals

```ebnf
integer_literal :=
    base_prefix? integer_body integer_suffix?
```

```ebnf
integer_body :=
    digit (digit | '_')*
```

constraints:

* underscores may only follow digits
* at least one digit required
* suffix is lexed as identifier

---

### 7.3 floating-point literals

```ebnf
float_literal :=
    base_prefix?
    (
        digit+ '.' digit*
      | '.' digit+
      | digit+
    )
    exponent?
    float_suffix?
```

```ebnf
exponent :=
    ('e' | 'E') ['+' | '-'] digit+    // base 10
  | ('p' | 'P') ['+' | '-'] digit+    // base 16
```

constraints:

* base 2 and base 8 do not allow decimal points
* exponent marker depends on base
* suffix is lexed as identifier

---

### 7.4 numeric invariants

* underscores cannot be adjacent to '.', prefix, or exponent
* exponent may appear at most once
* suffix parsing is lexical only
* numeric evaluation is deferred to Immediate evaluation

---

## 8. operators and punctuation

### 8.1 grammar

```ebnf
symbol :=
    one_char_symbol
  | two_char_symbol
  | three_char_symbol
  | four_char_symbol
```

symbols are matched greedily by maximum length.

### 8.2 constraints

* symbols are ascii-only
* max symbol length is 4 bytes
* invalid symbol hashes produce `TkError`

---

## 9. comments

### 9.1 line comments

```ebnf
line_comment :=
    "//" .* (newline | eof)
```

### 9.2 block comments

```ebnf
block_comment :=
    "/*" block_comment_body "*/"
```

* block comments **may nest**
* unclosed block comments produce error tokens
* comment tokens are emitted as `AtComment`

---

## 10. string and char literals

### 10.1 delimiters

```ebnf
string_literal := '"' string_body '"'
char_literal   := "'" string_body "'"
```

---

### 10.2 prefixes

prefixes are parsed as identifiers immediately preceding the delimiter:

| prefix  | meaning            |
| ------- | ------------------ |
| f       | format string      |
| b       | byte string        |
| fb / bf | format byte string |

prefix resolution is case-insensitive.

---

### 10.3 string body grammar

```ebnf
string_body :=
    (string_char | escape_sequence | format_expr)*
```

---

### 10.4 escape sequences

#### basic escapes

```
\n \r \t \v \f \a \' \" \\
```

#### hex escapes

```
\xHH        // exactly 2 hex digits
```

#### octal escapes (byte only)

```
\ooo        // 1–3 octal digits
```

#### unicode escapes (non-byte only)

```
\uHHHH
\UHHHHHHHH
```

constraints:

* byte strings forbid unicode escapes
* unicode escapes must not encode surrogate halves
* values must fit unicode scalar range

---

### 10.5 format strings

```ebnf
format_expr :=
    '{' format_body '}'
```

* format expressions may nest
* newlines inside format expressions are illegal
* each format slice is recursively lexed using `lex_slice`

---

### 10.6 string invariants

* unterminated strings produce error tokens
* unmatched `{` or `}` inside format strings is an error
* string body ranges exclude delimiters
* prefix and suffix tokens are preserved verbatim

---

## 11. whitespace and newlines

```ebnf
whitespace :=
    ' ' | '\t' | '\f' | '\v'

newline :=
    '\n' | '\r'
```

rules:

* consecutive whitespace collapses into one token
* any newline converts the token to `TkNewLine`
* newline tokens are preserved for parser-level semicolon inference

---

## 12. error handling

### 12.1 error tokens

* `TkError` is emitted for malformed constructs
* `imm` field stores expected token kind or hash
* error tokens do not terminate lexing

### 12.2 invariants

* lexer must never panic on malformed input
* all errors must be localized to a source range
* cursor must always make forward progress

---

## 13. immediate evaluation model

* immediates are created during lexing
* evaluation may be deferred and parallelized
* lexer must remain valid until all immediates complete
* immediate evaluation **must not** mutate token stream

---

## 14. conflict marker handling

the lexer tracks git conflict markers:

`<<<<<<<`
`=======`
`>>>>>>>`

* detection suppresses cascaded errors
* state transitions are linear
* conflict state is reset after full sequence

---

## 15. guarantees to downstream stages

the lexer guarantees:

1. token stream is lossless w.r.t source text
2. all literals have valid immediate records
3. invalid constructs are explicitly marked
4. no token overlaps another token
5. format expressions are fully isolated

---

## 16. non-goals (explicit)

* validating numeric ranges
* normalizing escapes
* resolving names
* handling macros or preprocessing

---

## 17. known limitations (stage1)

* suffix grammar is permissive
* underscore rules are incomplete
* float edge cases are accepted liberally
* keyword hashing is ascii-only

---

## 18. forward compatibility notes (non-normative)

future revisions may:

* introduce a formal suffix grammar
* tighten underscore placement rules
* move conflict detection to pre-lex phase
* unify string and char literal handling
