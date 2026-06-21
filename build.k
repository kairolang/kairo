/// --- The Kairo Project ------------------------------------ build.k ----- ///
///
///   Build script for the Kairo compiler and tools.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///
///
///   TOOLCHAIN LINKAGE INVARIANT, do not violate:
///     Linux/macOS : shared (libLLVM.so/.dylib), one copy in lib/, thin bins.
///     Windows     : static (.lib), forced, libLLVM.dll is unsupported there.
///     No system-LLVM fallback on ANY platform. We link our patched fork
///     (custom Clang PP-token injection); system LLVM lacks the patch and
///     would silently produce a broken compiler. Absence is a hard error.
///

fn zero_pad(n: i32) -> string {
    if n < 10 { return f"0{n}"; }
    return f"{n}";
}

fn version(target: string, suffix: string) -> string {
    var date_suffix = "";
    if (suffix.contains("+rc")) || (suffix.contains("+dev")) {
        var now    = libcxx::chrono::system_clock::now();
        var now_t  = libcxx::chrono::system_clock::to_time_t(now);
        var now_tm = libcxx::localtime(&now_t);
        var year   = 1900 + now_tm->tm_year;
        var month  = zero_pad(1 + now_tm->tm_mon);
        var day    = zero_pad(now_tm->tm_mday);
        date_suffix = f".{year}{month}{day}";
    }
    return f"{target}{suffix}{date_suffix}";
}

fn version_macro(target: string, suffix: string) -> string {
    return f"VERSION=L\\\\\\\"{version(target, suffix)}\\\\\\\"";
}

// llvm-config queries (Windows-only: used to GENERATE the static component
// list instead of hand-maintaining 90 archive names). Never used as a
// system-LLVM fallback, see the invariant above.

fn llvm_static_components() -> string {
    // Windows links static. llvm-config --link-static --libs emits the LLVM
    // archive set in dependency order with correct current names, so an LLVM
    // bump can't silently drift a hand-typed list. Clang libs aren't reported
    // by llvm-config, so those stay explicit in llvm_libs().
    return run(["sh", "-c",
        "llvm-config --link-static --libs " +
        "core support target targetparser option " +
        "x86codegen x86asmparser x86desc x86info " +
        "aarch64codegen aarch64asmparser aarch64desc aarch64info aarch64utils " +
        "webassemblycodegen webassemblyasmparser webassemblydesc webassemblyinfo webassemblyutils " +
        "codegen asmprinter selectiondag globalisel " +
        "ipo instrumentation vectorize passes linker irreader " +
        "bitreader bitwriter mc mcparser object " +
        "| tr -d '\\n\x27"
    ]).stdout_str.r_strip();
}

// Clang archives, explicit because llvm-config doesn't report them.
// Windows static only.
fn clang_static_components(t: ref!(Target)) {
    t.passthrough("-lclangBasic").passthrough("-lclangDriver").passthrough("-lclangFrontend")
     .passthrough("-lclangFrontendTool").passthrough("-lclangCodeGen").passthrough("-lclangSema")
     .passthrough("-lclangAnalysis").passthrough("-lclangAST").passthrough("-lclangParse")
     .passthrough("-lclangLex").passthrough("-lclangEdit").passthrough("-lclangRewrite")
     .passthrough("-lclangSerialization").passthrough("-lclangSupport");
}


// Windows SDK / MSVC toolchain discovery
//   Host-toolchain probing, NOT LLVM linkage.

fn windows_sdk_paths(t: ref!(Target)) {
    const eval if defined(_WIN64) || defined(_WIN32) {
        t.passthrough("-fms-runtime-lib=dll");
        t.passthrough("-Xlinker").passthrough("/nodefaultlib:libcmt");

        var sdk_lib_root: string = "";
        inline "c++" {
            HKEY hkey;
            if (RegOpenKeyExA(HKEY_LOCAL_MACHINE,
                    "SOFTWARE\\WOW6432Node\\Microsoft\\Windows Kits\\Installed Roots",
                    0, KEY_READ, &hkey) == ERROR_SUCCESS) {
                char buf[512]; DWORD sz = 512;
                if (RegQueryValueExA(hkey, "KitsRoot10", nullptr, nullptr,
                        reinterpret_cast<LPBYTE>(buf), &sz) == ERROR_SUCCESS) {
                    sdk_lib_root = kairo::std::nstring_to_string(buf)
                                 + kairo::std::nstring_to_string("Lib");
                }
                RegCloseKey(hkey);
            }
        }
        if sdk_lib_root.is_empty() {
            sdk_lib_root = "C:/Program Files (x86)/Windows Kits/10/Lib";
        }

        var newest_sdk: string = "";
        inline "c++" {
            for (auto& entry : libcxx::filesystem::directory_iterator(sdk_lib_root.raw())) {
                if (entry.is_directory()) {
                    auto name = kairo::std::nstring_to_string(entry.path().filename().string().c_str());
                    if (name.starts_with(kairo::std::nstring_to_string("10.")) && name > newest_sdk) {
                        newest_sdk = name;
                    }
                }
            }
        }
        if newest_sdk.is_empty() {
            log::error("No Windows SDK found in " + sdk_lib_root);
            log::error("Install the Windows 10/11 SDK");
            return;
        }

        var sdk_base = sdk_lib_root + "/" + newest_sdk;
        t.passthrough("-Xlinker").passthrough("\\\x22/libpath:" + sdk_base + "/ucrt/x64\\\x22");
        t.passthrough("-Xlinker").passthrough("\\\x22/libpath:" + sdk_base + "/um/x64\\\x22");

        var vswhere = "C:/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe";
        if path_exists(vswhere) {
            var vs_path = run([vswhere, "-latest", "-products", "*",
                "-requires", "Microsoft.VisualStudio.Component.VC.Tools.x86.x64",
                "-property", "installationPath"]).stdout_str.r_strip();
            if !vs_path.is_empty() {
                var msvc_tools = vs_path + "/VC/Tools/MSVC";
                if path_exists(msvc_tools) {
                    var newest_msvc: string = "";
                    inline "c++" {
                        for (auto& entry : libcxx::filesystem::directory_iterator(msvc_tools.raw())) {
                            if (entry.is_directory()) {
                                auto name = kairo::std::nstring_to_string(entry.path().filename().string().c_str());
                                if (name > newest_msvc) { newest_msvc = name; }
                            }
                        }
                    }
                    if !newest_msvc.is_empty() {
                        t.passthrough("-Xlinker")
                         .passthrough("\\\x22/libpath:" + msvc_tools + "/" + newest_msvc + "/lib/x64\\\x22");
                    }
                }
            }
        }
    }
}

fn common_flags(t: ref!(Target)) {
    // Every target gets these. One place, no per-target drift.
    t.passthrough("-flto=thin")
     .passthrough("-fuse-ld=lld")
     .passthrough("-w")
     .passthrough("-g");
}

fn require_vendored_llvm(llvm_build: string) {
    // Hard gate. The prebuild script should have already built or errored,
    // but if build.k is invoked with no vendored LLVM present, fail loud
    // rather than limp toward a system fallback that doesn't exist.
    if !path_exists(llvm_build + "/include") {
        log::error("vendored LLVM not found at " + llvm_build);
        log::error("the patched llvm-project fork is REQUIRED, there is no system fallback.");
        log::error("run the prebuild script for this platform, or:");
        log::error("  git submodule update --init --recursive Lib/llvm-runtimes");
        abort();
    }
}

fn llvm_includes(t: ref!(Target), llvm_src: string, llvm_build: string) {
    t.passthrough("-I" + llvm_build + "/include")
     .passthrough("-I" + llvm_src   + "/llvm/include")
     .passthrough("-I" + llvm_src   + "/clang/include")
     .passthrough("-I" + llvm_build + "/tools/clang/include");
}

fn lld_libs(t: ref!(Target)) {
    // LLD isn't in llvm-config. Fixed bundle, group-wrapped for the
    // lldCommon<->flavor cycle. Emitted after inputs by the builder.
    t.passthrough("-llldCommon")
     .passthrough("-llldELF")
     .passthrough("-llldCOFF")
     .passthrough("-llldMinGW")
     .passthrough("-llldMachO")
     .passthrough("-llldWasm");
}

fn llvm_libs(t: ref!(Target), llvm_build: string, out_lib: string) {
    t.passthrough("-L" + llvm_build + "/lib")
     .passthrough("-L" + out_lib)
     .passthrough("-Wno-parentheses-equality")
     .passthrough("-Werror=return-type");

    lld_libs(t);

    if platform() == "windows" {
        // STATIC, libLLVM.dll is unsupported on Windows (invariant).
        t.passthrough("-DNOMINMAX");
        clang_static_components(t);
        t.passthrough(llvm_static_components())
         // Win32 system deps the static set pulls in.
         .passthrough("-lversion").passthrough("-ladvapi32").passthrough("-lshell32")
         .passthrough("-lole32").passthrough("-luuid").passthrough("-lntdll")
         .passthrough("-lws2_32").passthrough("-lpsapi");
    } else {
        // SHARED, one libLLVM, thin bins (invariant).
        t.passthrough("-lclang-cpp").passthrough("-lLLVM");
    }
}

fn platform_glue(t: ref!(Target)) {
    if platform() == "linux" {
        t.passthrough("\\\x27-Wl,-rpath,\\$ORIGIN/../lib\\\x27");
    }
    if platform() == "macos" {
        t.passthrough("\\\x27-Wl,-rpath,\\@loader_path/../lib\\\x27");
    }
    if platform() == "windows" {
        windows_sdk_paths(t);
    }
}

fn apply_llvm(t: ref!(Target), llvm_src: string, llvm_build: string, out_lib: string) {
    // require_vendored_llvm(llvm_build);
    common_flags(t);
    llvm_includes(t, llvm_src, llvm_build);
    llvm_libs(t, llvm_build, out_lib);
    platform_glue(t);
}

// Target wiring

fn prebuild_script() -> string {
    if platform() == "linux"   { return "bash Scripts/prebuild-llvm-linux.sh"; }
    if platform() == "macos"   { return "bash Scripts/prebuild-llvm-macos.sh"; }
    if platform() == "windows" { return "powershell -ExecutionPolicy Bypass -File Scripts/prebuild-llvm-windows.ps1"; }
    return "";
}

// Every LLVM-linking tool shares this shape. One call site = no drift.
fn llvm_tool(name: string, entry: string, ver: string, includes: vec::<string>,
             llvm_src: string, llvm_build: string, out_lib: string) -> Target {
    var t = Target(name)
        .entry(entry)
        .includes(includes)
        .define(ver)
        .pre_build(prebuild_script());
    apply_llvm(t, llvm_src, llvm_build, out_lib);
    return t;
}

fn main() -> i32 {
    const KAIRO_VERSION : string = version_macro("kairo", "-0.1.1+dev");
    const KBLD_VERSION  : string = version_macro("kbld",  "-0.1.0+dev");
    const KFMT_VERSION  : string = version_macro("kfmt",  "-0.1.0+dev");
    const KLD_VERSION   : string = version_macro("kld",   "-0.1.0+dev");
    const KALS_VERSION  : string = version_macro("kals",  "-0.1.0+dev");
    const KPKG_VERSION  : string = version_macro("kpkg",  "-0.1.0+dev");

    var llvm_build = build_dir() + "/llvm";
    var llvm_src   = project_root() + "/Lib/llvm-runtimes";
    var out_lib    = build_dir() + "/" + triple() + "/" + build_mode() + "/lib";

    var p = Project("Kairo")
        .version("kairo-0.0.1+rc.20260220")
        .author("Dhruvan, Ojas and Arnav")
        .license("CC-BY-4.0")
        .compiler("kairo")
        .mode("release")
        .skip_dirs(["build", "Lib", "private"]);

    var core         = "Lib/bootstrap/lib-helix/core";
    var katar_inc    = ["Extras/KaTAR", core];
    var kbld_inc     = ["Extras/BuildTool", core, "Compiler", "Extras/KaTAR", "Linker"];
    var kfmt_inc     = ["Extras/Formatter", core, "Compiler", "Extras/KaTAR", "Linker"];
    var kld_inc      = ["Linker", core];
    var kals_inc     = ["Analyzer", core, "Compiler", "Extras/KaTAR", "Linker"];
    var kpkg_inc     = ["Extras/PackageManager", core];
    var compiler_inc = ["Compiler", core, "Extras/KaTAR", "Linker"];

    p.target(llvm_tool("kairo", "Compiler/Driver/Kairo.k",             KAIRO_VERSION, compiler_inc, llvm_src, llvm_build, out_lib));
    p.target(llvm_tool("kbld",  "Extras/BuildTool/Driver/kbld.k",      KBLD_VERSION,  kbld_inc,     llvm_src, llvm_build, out_lib));
    p.target(llvm_tool("kfmt",  "Extras/Formatter/Driver/kfmt.k",      KFMT_VERSION,  kfmt_inc,     llvm_src, llvm_build, out_lib));
    p.target(llvm_tool("kld",   "Linker/Driver/kld.k",                 KLD_VERSION,   kld_inc,      llvm_src, llvm_build, out_lib));
    p.target(llvm_tool("kals",  "Analyzer/Driver/kals.k",              KALS_VERSION,  kals_inc,     llvm_src, llvm_build, out_lib));
    p.target(llvm_tool("kpkg",  "Extras/PackageManager/Driver/kpkg.k", KPKG_VERSION,  kpkg_inc,     llvm_src, llvm_build, out_lib));
    p.target(llvm_tool("katar", "Extras/KaTAR/KTCompress.k",           KAIRO_VERSION, katar_inc,    llvm_src, llvm_build, out_lib));

    return 0;
}

__inline_cpp("
#if defined(_WIN32) || defined(_WIN64)
#   pragma comment(lib, \"advapi32.lib\")
#endif
");