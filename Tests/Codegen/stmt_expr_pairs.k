// A statement expression's `(` `{` and `}` `)` reach clang in one location
// context. Clang warns (C195W, -Wcompound-token-split-by-macro) when either
// half of such a pair is a macro location and the two are in different
// FileIDs. TokenSink gives each token a byte of the .k file, and an arena
// token (a macro location with one expansion each) once the bytes run out;
// the per-TU preamble alone takes about a hundred of them. So a valid program
// smaller than its own token stream used to warn.
//
// The sources are fixtures under Inputs/ because the case needs a tiny file:
// these comments are bytes the sink can spend, and would hide it. Keep the
// fixtures as they are; padding them makes this test pass vacuously.
//
//   stmt_expr_match.k      a MatchLowering statement expression
//   stmt_expr_sequence.k   a SequenceLowering one (`f(g(), g())`)
//
// `-W C195W` asks for the warning explicitly, so the check still means
// something if it is ever silenced by default.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: { %kairo %S/Inputs/stmt_expr_match.k -c -W C195W --cache-dir %t.d/m 2>&1 || true; } | %FileCheck %s --check-prefix=OBJ --allow-empty
// RUN: { %kairo %S/Inputs/stmt_expr_sequence.k -c -W C195W --cache-dir %t.d/s 2>&1 || true; } | %FileCheck %s --check-prefix=OBJ --allow-empty
// OBJ-NOT: warning
// RUN: find %t.d/m -name '*.o' | grep -q .
// RUN: find %t.d/s -name '*.o' | grep -q .
