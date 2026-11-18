// witness/lone_literal -- an expression-bodied extension member whose body
// is a lone literal (e.k: `= 7`), called through a bound from another TU.
// The `return` the parser synthesizes for an expression body has the
// expression's range, one byte here; EmitIR::_return borrowed six bytes
// from it for the keyword, and with the literal four bytes before the end
// of e.k that ran past the buffer: an ICE, "TokenSink: span runs past the
// end of its buffer" at e.k:4:37. e.k must end right after the literal's
// line, so it carries no comment and no wiring.
import m::M
import n
import e
fn main() -> i32 { return n::get(M { b: 1 }) }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 7
