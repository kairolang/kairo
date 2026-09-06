// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
//
// Regression test for RESOLUTION.md §2.5(b)'s first [BROKEN] item:
//
//   "A CLASS's generic params are not declared into N's lexical stack
//   (only a function's are). `T` in EXPRESSION position inside a method
//   of `class <T> Foo` -- a `requires T impl X` on the class, a
//   `ConstraintExpr` lhs, `T::CONST` -- reports undeclared. Fix: every
//   type-scope `traverse_*` in N pushes `n->generic_params` into a frame
//   exactly as `traverse_function_decl` does. Struct, union, interface,
//   enum, extension, alias too."
//
// Fixed: every type-shaped scope now pushes a locals frame for its own
// generic params, so the class's `<T>` is frame 0 and a method's params
// nest inside it as frame 1.
//
// No direct clang analogue (C++ template parameters ARE visible in
// expression position inside member bodies by construction -- there is no
// comparable phase split to port a regression test FROM). This file is a
// from-scratch minimal reproducer, kept so the suite catches a regression.
//
// `T::SIZE` inside `Box<T>::describe` names the class's OWN generic
// parameter `T` in a `::` chain position, exactly as it would if `T` were a
// function generic (contrast typeres_dependent.k's CASE 3, where a
// FUNCTION's own `<T>` already resolved this way).

class <T> Box {
    var val: T;

    fn describe(self) -> i32 {
        // `T` names the class's own generic parameter, and `T::SIZE` is a
        // dependent chain step (deferred to M2) -- the same shape as
        // typeres_dependent.k's CASE 1/3, which a FUNCTION's own `<T>`
        // already produced before this was fixed.
        var x = T::SIZE;
        return x
    }
}

// DIAG-NOT: error

// The class's own frame holds `T`; the method's params are the frame under
// it. `T::SIZE` stays dependent -- resolving it is M2's job, not N's.
// SEMA:      block Box  @
// SEMA-NEXT:   declare T           = generic T @
// SEMA:      fn Box::describe  @
// SEMA:        use     T  {{.*}} -> generic T {{.*}}  [local frame 0]
// SEMA-NEXT:   member  ::SIZE  {{.*}}<dependent: rooted in a generic parameter   M2>
// SEMA:        use     x  {{.*}} -> var x {{.*}}  [local frame 1]
// SEMA: 0 unresolved
