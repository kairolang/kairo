// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
//
// `holder<alloc>::node` named in two TUs is ONE decl: the completed nested
// record is registered under its own USR in the shell's table, so the
// library's return type and this file's written path are the same type. If
// they were two decls the initializer below would not convert.

ffi "c++" import "traits_typedef.h"
import inputs::nested_record_lib

fn use() -> u64 {
    var mine: holder<alloc>::node = nested_record_lib::make()
    return mine.v + nested_record_lib::make().get()
}

// DIAG-NOT: error

// SEMA:      member .v @ 14:{{[0-9]+}} -> field v @ {{[0-9]+:[0-9]+}} [member of node]
// SEMA:      member .get @ 14:{{[0-9]+}} -> fn get @ {{[0-9]+:[0-9]+}} [member of node]
// SEMA:      0 unknown, 0 errored
