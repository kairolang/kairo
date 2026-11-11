// macOS and MSVC roots from the user's SDK plus the shipped overlay
// (Linker/Sysroot/Sdk.k): what scripts/darwin-sysroot.sh and
// scripts/msvc-sysroot do on their fast path, in-process, into the sysroot
// cache. The driver runs it on first use on the SDK's own host; ksys ensure
// --input runs it anywhere (the scripts' SDK= / XWIN=).
//
// The SDK and the splat here are hard-link copies of the bundled roots
// (SDK-shaped, Apple's / Microsoft's half included), with the pieces the
// staging must leave out added: Apple's libc++ headers and stub, swift.
// The overlays are the tree's own (build/sdk-overlays, beside the share).
//
//   - darwin: staged, SYSROOT.toml as darwin-sysroot.sh writes it (no
//     clang_triple, which would override a spelled --target version), the
//     excludes gone, ours in their place; a second ensure reuses it by name.
//   - msvc: the CRT and SDK for the one arch, under msvc/.
//   - neither an SDK nor a splat: refusals that say what to run; the MSVC
//     one names the script's exact command, since it downloads under a
//     license and is never run silently.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: ksys, ksys-share
// RUN: rm -rf %t && mkdir -p %t
// RUN: cp -al %sysgen_rt/arm64-apple-macosx %t/sdk && rm %t/sdk/SYSROOT.toml
// RUN: mkdir -p %t/sdk/usr/include/c++/apple %t/sdk/usr/lib/swift %t/sdk/System/Library/Frameworks/Foo.framework/Modules/Foo.swiftmodule %t/sdk/System/Library/Frameworks/Foo.framework/Headers
// RUN: touch %t/sdk/usr/lib/libc++.1.tbd %t/sdk/System/Library/Frameworks/Foo.framework/Headers/Foo.h
// RUN: cp -al %sysgen_rt/x86_64-windows-msvc/msvc %t/splat
//
// RUN: env KAIRO_SYSROOT_CACHE=%t/cache KAIRO_SYSROOT_SHARE=%sysgen_share %ksys ensure arm64-apple-macosx --input %t/sdk > %t/mac.path 2> %t/mac.err
// RUN: %FileCheck %s --check-prefix=NOTE < %t/mac.err
// NOTE: They contain Apple's SDK: keep them local, never redistribute them.
// RUN: %FileCheck %s --check-prefix=PATH < %t/mac.path
// PATH: {{.*}}/cache/sysroots/{{[0-9a-f]+$}}
// RUN: R=$(cat %t/mac.path) && { cat $R/SYSROOT.toml && test -f $R/usr/include/stdio.h && test -f $R/usr/include/c++/v1/vector \
// RUN:   && test -f $R/usr/lib/libc++.a && test -f $R/usr/lib/libSystem.tbd && test -f $R/System/Library/Frameworks/Foo.framework/Headers/Foo.h \
// RUN:   && test ! -e $R/usr/include/c++/apple && test ! -e $R/usr/lib/libc++.1.tbd && test ! -e $R/usr/lib/swift \
// RUN:   && test ! -e $R/System/Library/Frameworks/Foo.framework/Modules/Foo.swiftmodule && echo STAGED-OK; } | %FileCheck %s --check-prefix=MAC
// MAC:      triple        = "arm64-apple-macosx"
// MAC-NOT:  clang_triple
// MAC:      libc_link     = ["-lSystem"]
// MAC-NOT:  clang_triple
// MAC:      STAGED-OK
//
// RUN: env KAIRO_SYSROOT_CACHE=%t/cache KAIRO_SYSROOT_SHARE=%sysgen_share %ksys ensure arm64-apple-macosx > %t/mac2.path
// RUN: cmp %t/mac.path %t/mac2.path
//
// RUN: env KAIRO_SYSROOT_CACHE=%t/cache KAIRO_SYSROOT_SHARE=%sysgen_share %ksys ensure x86_64-windows-msvc --input %t/splat > %t/msvc.path 2> %t/msvc.err
// RUN: %FileCheck %s --check-prefix=MSNOTE < %t/msvc.err
// MSNOTE: They contain Microsoft's CRT and SDK: keep them local, never redistribute them.
// RUN: R=$(cat %t/msvc.path) && { cat $R/SYSROOT.toml && test -f $R/msvc/sdk/include/um/Windows.h && test -d $R/msvc/crt/lib/x86_64 \
// RUN:   && test -f $R/lib/libc++.lib && test -f $R/include/c++/v1/__config_site && echo STAGED-OK; } | %FileCheck %s --check-prefix=MSVC
// MSVC:      triple        = "x86_64-windows-msvc"
// MSVC:      lib_dirs      = ["lib", "msvc/crt/lib/x86_64", "msvc/sdk/lib/um/x86_64", "msvc/sdk/lib/ucrt/x86_64"]
// MSVC:      STAGED-OK
//
// RUN: env -u XWIN MSVC_CACHE=%t/none KAIRO_SYSROOT_CACHE=%t/empty KAIRO_SYSROOT_SHARE=%sysgen_share %ksys ensure i686-windows-msvc > %t/nosplat.out 2>&1; test $? -eq 2
// RUN: %FileCheck %s --check-prefix=NOSPLAT < %t/nosplat.out
// NOSPLAT: error [P009E]: no sysroot for i686-windows-msvc: no Visual Studio C++ tools and no MSVC splat were found
// NOSPLAT: note [P009N]: run: powershell -ExecutionPolicy Bypass -File "{{.*}}/scripts/msvc-sysroot.ps1" i686
//
// RUN: env -u SDKROOT KAIRO_SYSROOT_CACHE=%t/empty KAIRO_SYSROOT_SHARE=%sysgen_share %ksys ensure x86_64-apple-macosx > %t/nosdk.out 2>&1; test $? -eq 2
// RUN: %FileCheck %s --check-prefix=NOSDK < %t/nosdk.out
// NOSDK: error [P009E]: no macOS SDK found for x86_64-apple-macosx
