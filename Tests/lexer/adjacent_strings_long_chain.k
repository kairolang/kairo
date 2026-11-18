// A chain of adjacent string literals is linked in a loop, so its length is
// not bounded by the lexer's stack: 200000 segments lex as one literal.

// --- lit wiring ---
// RUN: python3 -c "print('fn f() {\n    var s = ' + ' '.join(['\"a\"'] * 200000) + '\n}')" > %t.k
// RUN: %kairo %t.k --syntax-only
