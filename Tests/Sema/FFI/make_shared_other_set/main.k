// RUN: { %kairo %S/first.k %s --type-check-only 2>&1 || true; } | %FileCheck %s --allow-empty
//
// G82: libc++ declares `make_shared<T>()` twice, told apart only by an
// `enable_if_t<is_bounded_array<T>::value, int> = 0` on a defaulted
// parameter. The template is first.k's set's (<memory>), which never saw
// `ms::Item`, so the explicit argument had no spelling there, clang was
// never asked, and both overloads tied (SC064E). The argument is now a
// layout-only blob for that one question, and a removal over it is soft.
// CHECK-NOT: error

ffi "c++" import "memory"
ffi "c++" import "item.h"

fn mk() -> cxx::std::shared_ptr<ms::Item> {
    return cxx::std::make_shared<ms::Item>()
}
