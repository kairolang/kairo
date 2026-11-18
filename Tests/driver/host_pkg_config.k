// --pkg-config <name> runs `pkg-config --cflags --libs <name>` and applies
// it: -I/-D to clang, -L/-l to the link. In the default build curl/curl.h
// comes from the host's /usr/include (after the floor's headers) and
// libcurl.so from the host's library dirs, and the program runs. The host's
// libcurl may need a glibc newer than the floor; that is a warning, not a
// failure.
//
// An unknown package is an error naming it. With --target it is an error
// unless PKG_CONFIG_SYSROOT_DIR or PKG_CONFIG_LIBDIR say which tree's .pc
// files describe the target.

ffi "c" import "curl/curl.h"

fn main() -> i32 {
    var unsafe *v = curl_version()
    if v == &null { return 1 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: default-glibc, pkg-libcurl
// RUN: rm -rf %t && mkdir -p %t
// RUN: %kairo %s --pkg-config libcurl -o %t/a.out
// RUN: %t/a.out

// RUN: %kairo %s --pkg-config libcurl --print-jobs | %FileCheck %s --check-prefix=LD
// LD: ld.lld {{.*}}--allow-shlib-undefined {{.*}}-lcurl

// RUN: { %kairo %s --pkg-config no-such-package-kairo --type-check-only 2>&1; echo "exit $?"; } | %FileCheck %s --check-prefix=UNKNOWN
// UNKNOWN: error [U019E]: --pkg-config no-such-package-kairo: pkg-config does not know the package 'no-such-package-kairo'
// UNKNOWN: exit 1

// RUN: { env -u PKG_CONFIG_SYSROOT_DIR -u PKG_CONFIG_LIBDIR %kairo %s --target=x86_64-linux-gnu --pkg-config libcurl --type-check-only 2>&1; echo "exit $?"; } | %FileCheck %s --check-prefix=CROSS
// CROSS: error [U018E]: --pkg-config cannot be used with --target=x86_64-linux-gnu as is
// CROSS: note [U018N]: point PKG_CONFIG_SYSROOT_DIR or PKG_CONFIG_LIBDIR
// CROSS: exit 1

// Hermetic: the host's header is not there at all.
// RUN: { %kairo %s --target=x86_64-linux-gnu --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=HERM
// HERM: error [CL001E]: 'curl/curl.h' file not found
