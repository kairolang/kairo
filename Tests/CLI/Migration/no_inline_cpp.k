// The compiler's own sources carry no inline C++. Stage 1 does not emit
// `inline "c++"` blocks or `__inline_cpp(...)` expressions (EmitIR ICEs on
// the first), so a site in Compiler/ or Linker/ is a self-host blocker even
// though Stage 0 still builds it. C++ the compiler needs goes in a header
// under Compiler/Native/ and is called from Kairo.
//
// Comment lines are not sites: the parser and AST document the construct.

// --- lit wiring ---
// RUN: python3 %S/Inputs/no_inline_cpp/scan.py %S/../../../Compiler %S/../../../Linker | %FileCheck %s
// CHECK-NOT: :{{[0-9]+}}:
// CHECK: {{^}}0 site(s)
