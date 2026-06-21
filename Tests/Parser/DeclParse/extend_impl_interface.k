// RUN: { %kairo %s --print-ast=tree 2>/dev/null || true; } | %FileCheck %s --check-prefix=AST
extend Point impl Drawable { fn draw(const self) -> string { return ""; } }
