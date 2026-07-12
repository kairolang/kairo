// SEPARATE:
macro boom!() { boom!() }
var a = boom!();
// direct self-recursion → R008E, primary at the invocation

// SEPARATE:
macro pp!() { qq!() }
macro qq!() { pp!() }
var a = pp!();
// mutual recursion → R008E; check the chain is reported usefully

// SEPARATE:
var a = nosuch!();
// R013E unknown macro

// SEPARATE:
var a = nosuch::mac!();
// R013E qualified unknown must NOT fall back to unqualified or hit a builtin

// SEPARATE:
macro np!() { 1 }
var a = np!(1);
// R007E parameterless, args given

// SEPARATE:
macro needs!(x) { x }
var a = needs!;
// R006E requires arguments

// SEPARATE:
macro two!(x, y) { x + y }
var a = two!(1);
var b = two!(1, 2, 3);
// R006E arity both directions

// SEPARATE:
macro bad!(x) { x }
var a = bad!(1) + bad!(2) + nosuch!();
// poison recovery: exactly ONE error (the nosuch), no S052E cascade,
// and bad! still expands correctly around it

// SEPARATE:
macro inner!() { import foo }
// R012E import inside a token macro body, caught at def time

// SEPARATE:
macro m!() { 1 }
macro m!() { 2 }
// S040E duplicate macro in scope
// SEPARATE:
macro first!(x) { x }
// R014E redefines a compiler builtin; name is reserved

// SEPARATE:
macro compile_error!(a, b) {
    a + b
}
// R014E multi-line body must be fully discarded, no token spill
