// BEGIN-GENERATED-CHECKS (gen_checks.py) -- do not hand-edit, re-run instead
// RUN: { %kairo %s --type-check-only --print-ast=tree 2>&1 || true; } | %FileCheck %s --check-prefix=AST
// AST: ============== AST (tree) for fid 0 ==============
// AST-NEXT: TranslationUnit '{{.*}}'(fid=0)
// AST-NEXT: `-FunctionDecl  use(c: _lib_a::Cfg, a: _lib_a::Alias, h: Hidden, o: _lib_a::Own)
// AST-NEXT:   |-ParamDecl c: _lib_a::Cfg
// AST-NEXT:   |-ParamDecl a: _lib_a::Alias
// AST-NEXT:   |-ParamDecl h: Hidden
// AST-NEXT:   |-ParamDecl o: _lib_a::Own
// AST-NEXT:   `-CompoundStmt (0)
// AST: -- 0 error(s), 0 warning(s) --
// END-GENERATED-CHECKS

// EXPECT: 0 errors.
// EXPECT: `Cfg` (default arg) resolves Hidden in _lib_a's scope, NOT here (this file never imports _lib_b).
// EXPECT: `_lib_a::Alias` expands to Hidden through _lib_a's overlay (not ours).
// EXPECT: `Hidden` selective import via _lib_a's re-export resolves.
import _lib_a
import _lib_a::{Hidden}

fn use(c: _lib_a::Cfg, a: _lib_a::Alias, h: Hidden, o: _lib_a::Own) { }
