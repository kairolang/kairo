#include "tree_sitter/parser.h"

#include <stdbool.h>
#include <stdint.h>

// Externals, in grammar.js order.
enum TokenType {
  NEWLINE,        // automatic statement terminator
  BLOCK_COMMENT,  // nesting /* ... */
  RAW_BLOCK,      // `{ ... }` opaque, brace balanced (inline "lang" bodies)
  INIT_OPEN,      // `{` that opens a named initializer: `{ name:` / `{ .name:`
  DOT_FLOAT,      // `.5` where only an operand can start (never `t.0`)
  FSTRING,        // f"..{expr}.." with arbitrary expressions (and quotes) in holes
  ERROR_SENTINEL,
};

void *tree_sitter_kairo_external_scanner_create(void) { return NULL; }
void tree_sitter_kairo_external_scanner_destroy(void *p) { (void)p; }
unsigned tree_sitter_kairo_external_scanner_serialize(void *p, char *b) { (void)p; (void)b; return 0; }
void tree_sitter_kairo_external_scanner_deserialize(void *p, const char *b, unsigned n) { (void)p; (void)b; (void)n; }

static inline void adv(TSLexer *l) { l->advance(l, false); }
static inline void skip(TSLexer *l) { l->advance(l, true); }

static inline bool is_ident(int32_t c) {
  return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c > 0x7f;
}

// Consumes an identifier-shaped word into buf (lowercase keywords only matter).
static unsigned read_word(TSLexer *l, char *buf, unsigned cap) {
  unsigned n = 0;
  while (is_ident(l->lookahead)) {
    if (n + 1 < cap) buf[n] = (char)l->lookahead;
    n++;
    adv(l);
  }
  buf[n < cap ? n : cap - 1] = 0;
  return n;
}

static bool streq(const char *a, const char *b) {
  while (*a && *a == *b) { a++; b++; }
  return *a == *b;
}

// Words that cannot begin a statement and continue the previous line
// (ExprParse::_parse_expr_prec infix set minus is_unary_operator, plus the
// heritage / clause / chain keywords the decl and stmt parsers peek past).
static bool is_continuation_word(const char *w) {
  static const char *words[] = {
    "else", "catch", "requires", "where", "derives", "impl",
    "and", "or", "xor", "bitand", "bitor", "not_eq", "in", NULL,
  };
  for (int i = 0; words[i]; i++)
    if (streq(w, words[i])) return true;
  return false;
}

// Called with the lexer positioned on the first significant character of the
// next line (the newline already marked as the token end). Decides whether
// that line continues the current one. May consume characters freely: the
// token end is already marked.
static bool next_line_continues(TSLexer *l) {
  int32_t c = l->lookahead;
  switch (c) {
    case '.':
      adv(l);
      return l->lookahead != '.';           // `.x` continues; `..` / `...` start a statement
    case '-':
      adv(l);
      return l->lookahead == '>' || l->lookahead == '=';  // `->`, `-=`
    case '+':
      adv(l);
      return l->lookahead == '=';           // `+=`
    case '*':
      adv(l);
      return l->lookahead == '=';           // `*=`
    case '&':
      adv(l);
      return l->lookahead == '&' || l->lookahead == '=';
    case '?':
      adv(l);
      return l->lookahead == '.' || l->lookahead == '-' || l->lookahead == '?';
    case '=':
      adv(l);
      return l->lookahead == '=' || l->lookahead == '>';  // `==`, `===`, `=>`
    case '!':
      adv(l);
      return l->lookahead == '=';
    case '/':
      adv(l);
      if (l->lookahead == '/') {           // comment line: decide on the next real line
        while (!l->eof(l) && l->lookahead != '\n') adv(l);
        while (l->lookahead == ' ' || l->lookahead == '\t' || l->lookahead == '\r' || l->lookahead == '\n') adv(l);
        return !l->eof(l) && next_line_continues(l);
      }
      if (l->lookahead == '*') {
        adv(l);
        while (!l->eof(l)) { int32_t d = l->lookahead; adv(l); if (d == '*' && l->lookahead == '/') { adv(l); break; } }
        while (l->lookahead == ' ' || l->lookahead == '\t' || l->lookahead == '\r' || l->lookahead == '\n') adv(l);
        return !l->eof(l) && next_line_continues(l);
      }
      return true;                          // `/` operator
    case '<': case '>': case '|': case '^': case '%': case '{':
      return true;
    default:
      break;
  }
  if (c == '@') {
    // `@likely else` / `@unlikely else` on its own line continues the if
    adv(l);
    char w[16];
    unsigned n = read_word(l, w, sizeof w);
    if (!(n < sizeof w && (streq(w, "likely") || streq(w, "unlikely")))) return false;
    while (l->lookahead == ' ' || l->lookahead == '\t' || l->lookahead == '\r' || l->lookahead == '\n') adv(l);
    n = read_word(l, w, sizeof w);
    return n < sizeof w && streq(w, "else");
  }
  if ((c >= 'a' && c <= 'z') || c == '_') {
    char w[16];
    unsigned n = read_word(l, w, sizeof w);
    if (n >= sizeof w) return false;
    return is_continuation_word(w);
  }
  return false;
}

static bool scan_block_comment(TSLexer *l) {
  // positioned on '/', next must be '*'
  adv(l);
  if (l->lookahead != '*') return false;
  adv(l);
  unsigned depth = 1;
  while (!l->eof(l)) {
    int32_t c = l->lookahead;
    adv(l);
    if (c == '*' && l->lookahead == '/') {
      adv(l);
      if (--depth == 0) {
        l->mark_end(l);
        l->result_symbol = BLOCK_COMMENT;
        return true;
      }
    } else if (c == '/' && l->lookahead == '*') {
      adv(l);
      depth++;
    }
  }
  l->mark_end(l);
  l->result_symbol = BLOCK_COMMENT;
  return true;  // unterminated: swallow to EOF
}

static void skip_quoted(TSLexer *l, int32_t q) {
  adv(l);
  while (!l->eof(l) && l->lookahead != q && l->lookahead != '\n') {
    if (l->lookahead == '\\') adv(l);
    adv(l);
  }
  if (l->lookahead == q) adv(l);
}

static bool scan_raw_block(TSLexer *l) {
  if (l->lookahead != '{') return false;
  adv(l);
  unsigned depth = 1;
  while (!l->eof(l)) {
    int32_t c = l->lookahead;
    if (c == '"' || c == '\'') { skip_quoted(l, c); continue; }
    if (c == '/') {
      adv(l);
      if (l->lookahead == '/') { while (!l->eof(l) && l->lookahead != '\n') adv(l); }
      else if (l->lookahead == '*') {
        adv(l);
        while (!l->eof(l)) { int32_t d = l->lookahead; adv(l); if (d == '*' && l->lookahead == '/') { adv(l); break; } }
      }
      continue;
    }
    adv(l);
    if (c == '{') depth++;
    else if (c == '}' && --depth == 0) {
      l->mark_end(l);
      l->result_symbol = RAW_BLOCK;
      return true;
    }
  }
  return false;
}

// positioned on '{'. Emits INIT_OPEN when the brace is followed by
// `ident :` (not `::`) or `.ident :`, i.e. it cannot open a block.
static bool scan_init_open(TSLexer *l) {
  adv(l);
  l->mark_end(l);
  while (l->lookahead == ' ' || l->lookahead == '\t' || l->lookahead == '\r' || l->lookahead == '\n') adv(l);
  if (l->lookahead == '.') {
    adv(l);
    if (l->lookahead == '.') return false;
  }
  if (!((l->lookahead >= 'a' && l->lookahead <= 'z') || (l->lookahead >= 'A' && l->lookahead <= 'Z') || l->lookahead == '_' || l->lookahead == '#' || l->lookahead > 0x7f)) return false;
  while (is_ident(l->lookahead) || l->lookahead == '#') adv(l);
  while (l->lookahead == ' ' || l->lookahead == '\t') adv(l);
  if (l->lookahead != ':') return false;
  adv(l);
  if (l->lookahead == ':') return false;
  l->result_symbol = INIT_OPEN;
  return true;
}

static void skip_plain_string(TSLexer *l) {
  // on the opening '"'
  adv(l);
  while (!l->eof(l) && l->lookahead != '"' && l->lookahead != '\n') {
    if (l->lookahead == '\\') adv(l);
    adv(l);
  }
  if (l->lookahead == '"') adv(l);
}

static bool scan_fstring_body(TSLexer *l);

// positioned on the first char of a hole (after '{'); consumes through '}'
static bool scan_hole(TSLexer *l) {
  unsigned depth = 1;
  while (!l->eof(l)) {
    int32_t c = l->lookahead;
    if (c == '"') { skip_plain_string(l); continue; }
    if (c == '\'') { skip_quoted(l, '\''); continue; }
    if (c == 'f') {
      adv(l);
      if (l->lookahead == '"') { if (!scan_fstring_body(l)) return false; }
      continue;
    }
    adv(l);
    if (c == '{') depth++;
    else if (c == '}' && --depth == 0) return true;
  }
  return false;
}

// positioned on the opening '"'; consumes through the closing '"'
static bool scan_fstring_body(TSLexer *l) {
  adv(l);
  while (!l->eof(l)) {
    int32_t c = l->lookahead;
    if (c == '"') { adv(l); return true; }
    if (c == '\n') return false;
    if (c == '\\') { adv(l); adv(l); continue; }
    adv(l);
    if (c == '{') {
      if (l->lookahead == '{') { adv(l); continue; }   // `{{` escape
      if (!scan_hole(l)) return false;
    }
  }
  return false;
}

static bool scan_fstring(TSLexer *l) {
  // prefixes: f, fb, bf
  if (l->lookahead == 'b') {
    adv(l);
    if (l->lookahead != 'f') return false;
    adv(l);
  } else if (l->lookahead == 'f') {
    adv(l);
    if (l->lookahead == 'b') adv(l);
  } else {
    return false;
  }
  if (l->lookahead != '"') return false;
  if (!scan_fstring_body(l)) return false;
  while (is_ident(l->lookahead)) adv(l);              // literal suffix
  l->mark_end(l);
  l->result_symbol = FSTRING;
  return true;
}

bool tree_sitter_kairo_external_scanner_scan(void *payload, TSLexer *l, const bool *valid) {
  (void)payload;
  if (valid[ERROR_SENTINEL]) {
    // error recovery: only offer comments
    while (l->lookahead == ' ' || l->lookahead == '\t' || l->lookahead == '\r' || l->lookahead == '\n') skip(l);
    if (l->lookahead == '/' && valid[BLOCK_COMMENT]) return scan_block_comment(l);
    return false;
  }

  if (valid[INIT_OPEN] && !valid[RAW_BLOCK]) {
    // never across a terminating newline: that is checked below when NEWLINE is valid
    if (!valid[NEWLINE]) {
      while (l->lookahead == ' ' || l->lookahead == '\t' || l->lookahead == '\r' || l->lookahead == '\n') skip(l);
      if (l->lookahead == '{') return scan_init_open(l);
    } else {
      while (l->lookahead == ' ' || l->lookahead == '\t') skip(l);
      if (l->lookahead == '{') return scan_init_open(l);
    }
  }

  if (valid[DOT_FLOAT] && !valid[NEWLINE]) {
    while (l->lookahead == ' ' || l->lookahead == '\t' || l->lookahead == '\r' || l->lookahead == '\n') skip(l);
    if (l->lookahead == '.') {
      adv(l);
      if (!(l->lookahead >= '0' && l->lookahead <= '9')) return false;
      while ((l->lookahead >= '0' && l->lookahead <= '9') || l->lookahead == '_') adv(l);
      if (l->lookahead == 'e' || l->lookahead == 'E') {
        adv(l);
        if (l->lookahead == '+' || l->lookahead == '-') adv(l);
        while ((l->lookahead >= '0' && l->lookahead <= '9') || l->lookahead == '_') adv(l);
      }
      while (is_ident(l->lookahead)) adv(l);
      l->mark_end(l);
      l->result_symbol = DOT_FLOAT;
      return true;
    }
  }

  if (valid[RAW_BLOCK]) {
    while (l->lookahead == ' ' || l->lookahead == '\t' || l->lookahead == '\r' || l->lookahead == '\n') skip(l);
    if (l->lookahead == '{') return scan_raw_block(l);
  }

  if (valid[NEWLINE]) {
    bool saw_nl = false;
    while (l->lookahead == ' ' || l->lookahead == '\t' || l->lookahead == '\r' || l->lookahead == '\n') {
      if (l->lookahead == '\n') {
        if (!saw_nl) { adv(l); l->mark_end(l); saw_nl = true; continue; }
      }
      if (saw_nl) adv(l); else skip(l);
    }
    if (l->eof(l)) {
      if (!saw_nl) return false;
      l->result_symbol = NEWLINE;
      return true;
    }
    if (saw_nl) {
      if (l->lookahead == '}' || l->lookahead == ')' || l->lookahead == ']') {
        // a closer ends the list anyway; let the grammar see the closer
        l->result_symbol = NEWLINE;
        return true;
      }
      if (next_line_continues(l)) return false;
      l->result_symbol = NEWLINE;
      return true;
    }
    // No newline before the next token: fall through to the comment check.
  } else {
    while (l->lookahead == ' ' || l->lookahead == '\t' || l->lookahead == '\r' || l->lookahead == '\n') skip(l);
  }

  if (l->lookahead == '/' && valid[BLOCK_COMMENT]) return scan_block_comment(l);
  if (valid[FSTRING] && (l->lookahead == 'f' || l->lookahead == 'b')) return scan_fstring(l);
  return false;
}
