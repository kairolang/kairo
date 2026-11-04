// RUN: { %kairo %S/first.k %s --type-check-only 2>&1 || true; } | %FileCheck %s --allow-empty
//
// G88b: `make_unique<K>()` where K is a Kairo class deriving a C++ class
// from a header set <memory>'s never saw. libc++ declares make_unique twice
// (non-array, and a deleted bounded-array one told apart by SFINAE), and
// with K unspellable in <memory>'s set clang was never asked, so both tied
// (SC064E). Likewise `mu::Fwd`, only declared in base.h's set. Only the
// template is in question, so each is a blob in <memory>'s set.
// CHECK-NOT: error

ffi "c++" import "memory"
ffi "c++" import "base.h"

pub class K derives mu::Base {
    pub var y: i32 = 0
}

fn mk() -> cxx::std::unique_ptr<K> {
    return cxx::std::make_unique<K>()
}
fn mk2() -> cxx::std::unique_ptr<mu::Base> {
    return cxx::std::make_unique<mu::Base>()
}
fn mk3() -> cxx::std::unique_ptr<mu::Fwd> {
    return cxx::std::make_unique<mu::Fwd>()
}
