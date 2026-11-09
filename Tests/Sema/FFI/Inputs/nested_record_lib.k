// Import corpus for nested_record_xtu.k: a SECOND TU that names
// `holder<alloc>::node` on its own, so the test can check both TUs reach the
// one decl registered under the nested record's USR.
ffi "c++" import "../traits_typedef.h"

pub fn make() -> holder<alloc>::node {
    var n: holder<alloc>::node
    return n
}
