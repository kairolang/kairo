// A set that failed because its header is bad has already reported that
// as clang's own error, so the HeaderIndex breadcrumb is a Warn-level log
// entry, visible under -v. Without -v its presence is NOT asserted either
// way: which levels stream by default differs between debug and release
// (KLog.hh stream_level_), and this test must pass on both binaries.

ffi "c++" import "unknown_type.h"

// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=QUIET
// QUIET:     unknown_type.h:3:12: error [CL001E]: unknown type name 'bar'

// RUN: { %kairo %s --type-check-only -v 2>&1 || true; } | %FileCheck %s --check-prefix=VERBOSE
// VERBOSE:   [WARN ] HeaderIndex: set failed to build; nothing imported
