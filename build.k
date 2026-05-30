/// --- The Kairo Project ------------------------------------ build.k ----- ///
///
///   Build script for the Kairo compiler and tools. This script defines how
///   to compile the various components of the Kairo project, including the
///   compiler itself, the standard library, and any auxiliary tools or tests.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

fn zero_pad(n: i32) -> string {
    if n < 10 { return f"0{n}"; }
    return f"{n}";
}

fn version(target: string, suffix: string) -> string {
    var date_suffix = "";

    if (suffix.contains("+rc")) || (suffix.contains("+dev")) {
        var now     = libcxx::chrono::system_clock::now();
        var now_t   = libcxx::chrono::system_clock::to_time_t(now);
        var now_tm  = libcxx::localtime(&now_t);
        var year    = 1900 + now_tm->tm_year;
        var month   = zero_pad(1 + now_tm->tm_mon);
        var day     = zero_pad(now_tm->tm_mday);
        date_suffix = f".{year}{month}{day}";
    }

    return f"{target}{suffix}{date_suffix}";
}

fn version_macro(target: string, suffix: string) -> string {
    return f"VERSION=L\\\\\\\"{version(target, suffix)}\\\\\\\"";
}

fn llvm_link_windows(t: ref!(Target)) {
    const eval if defined(_WIN64) || defined(_WIN32) {
        t.passthrough("-DNOMINMAX");
        t.passthrough("-fms-runtime-lib=dll");
        t.passthrough("-Xlinker").passthrough("/nodefaultlib:libcmt");

        // --- locate Windows SDK ---
        var sdk_lib_root: string = "";

        inline "c++" {
            HKEY hkey;
            if (RegOpenKeyExA(HKEY_LOCAL_MACHINE,
                            "SOFTWARE\\WOW6432Node\\Microsoft\\Windows Kits\\Installed Roots",
                            0, KEY_READ, &hkey) == ERROR_SUCCESS) {
                char buf[512];
                DWORD sz = 512;
                if (RegQueryValueExA(hkey, "KitsRoot10", nullptr, nullptr,
                                    reinterpret_cast<LPBYTE>(buf), &sz) == ERROR_SUCCESS) {
                    // hand the C string back to kairo land
                    sdk_lib_root = kairo::std::nstring_to_string(buf) + kairo::std::nstring_to_string("Lib");
                }
                RegCloseKey(hkey);
            }
        }

        if sdk_lib_root.is_empty() {
            sdk_lib_root = "C:/Program Files (x86)/Windows Kits/10/Lib";
        }

        // --- find newest SDK version ---
        var newest_sdk: string = "";
        inline "c++" {
            for (auto& entry : libcxx::filesystem::directory_iterator(sdk_lib_root.raw())) {
                if (entry.is_directory()) {
                    auto name_cxx = entry.path().filename().string();
                    auto name = kairo::std::nstring_to_string(name_cxx.c_str());
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

        var sdk_base = string(sdk_lib_root) + "/" + string(newest_sdk);
        t.passthrough("-Xlinker").passthrough("\\\x22/libpath:" + sdk_base + "/ucrt/x64\\\x22");
        t.passthrough("-Xlinker").passthrough("\\\x22/libpath:" + sdk_base + "/um/x64\\\x22");

        // --- MSVC toolchain via vswhere ---
        var vswhere: string = "C:/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe";
        if path_exists(vswhere) {
            var vs_path = run([
                vswhere,
                "-latest",
                "-products", "*",
                "-requires", "Microsoft.VisualStudio.Component.VC.Tools.x86.x64",
                "-property", "installationPath"
            ]).stdout_str.r_strip();
            
            if !vs_path.is_empty() {
                var msvc_tools = vs_path + "/VC/Tools/MSVC";
                if path_exists(msvc_tools) {
                    var newest_msvc: string = "";
                    inline "c++" {
                        for (auto& entry : libcxx::filesystem::directory_iterator(msvc_tools.raw())) {
                            if (entry.is_directory()) {
                                auto name = kairo::std::nstring_to_string(entry.path().filename().string().c_str());
                                if (name > newest_msvc) {
                                    newest_msvc = name;
                                }
                            }
                        }
                    }
                    
                    if !newest_msvc.is_empty() {
                        t.passthrough("-Xlinker").passthrough("\\\x22/libpath:" + msvc_tools + "/" + newest_msvc + "/lib/x64\\\x22");
                    }
                }
            }
        }
    }

    // otherwise this function is a no-op on non-Windows platforms
}

fn apply_llvm(t: ref!(Target), llvm_src: string, llvm_build: string, out_lib: string) -> void {
    if path_exists(llvm_build + "/include") {
        t.passthrough("-I" + llvm_build + "/include");
        t.passthrough("-I" + llvm_src   + "/llvm/include");
        t.passthrough("-I" + llvm_src   + "/clang/include");
        t.passthrough("-I" + llvm_build + "/tools/clang/include");
        t.passthrough("-L" + llvm_build + "/lib");
        t.passthrough("-L" + out_lib);

        t.passthrough("-fno-lto");
        t.passthrough("-Wno-parentheses-equality");
        t.passthrough("-Wno-return-type");

        if platform() == "windows" {
            t.passthrough("-DNOMINMAX"); // avoid conflicts with std::min and std::max
            t.passthrough("-lclangBasic").passthrough("-lclangDriver").passthrough("-lclangFrontend")
             .passthrough("-lclangFrontendTool").passthrough("-lclangCodeGen").passthrough("-lclangSema")
             .passthrough("-lclangAnalysis").passthrough("-lclangAST").passthrough("-lclangParse")
             .passthrough("-lclangLex").passthrough("-lclangEdit").passthrough("-lclangRewrite")
             .passthrough("-lclangSerialization").passthrough("-lclangSupport").passthrough("-lLLVMCore")
             .passthrough("-lLLVMSupport").passthrough("-lLLVMTarget").passthrough("-lLLVMTargetParser")
             .passthrough("-lLLVMX86CodeGen").passthrough("-lLLVMX86AsmParser").passthrough("-lLLVMX86Desc")
             .passthrough("-lLLVMX86Info").passthrough("-lLLVMAArch64CodeGen").passthrough("-lLLVMAArch64AsmParser")
             .passthrough("-lLLVMAArch64Desc").passthrough("-lLLVMAArch64Info").passthrough("-lLLVMAArch64Utils")
             .passthrough("-lLLVMWebAssemblyCodeGen").passthrough("-lLLVMWebAssemblyAsmParser")
             .passthrough("-lLLVMWebAssemblyDesc").passthrough("-lLLVMWebAssemblyInfo").passthrough("-lLLVMWebAssemblyUtils")
             .passthrough("-lLLVMCodeGen").passthrough("-lLLVMCodeGenTypes").passthrough("-lLLVMAsmPrinter")
             .passthrough("-lLLVMSelectionDAG").passthrough("-lLLVMGlobalISel").passthrough("-lLLVMScalarOpts")
             .passthrough("-lLLVMInstCombine").passthrough("-lLLVMAggressiveInstCombine").passthrough("-lLLVMTransformUtils")
             .passthrough("-lLLVMAnalysis").passthrough("-lLLVMProfileData").passthrough("-lLLVMipo")
             .passthrough("-lLLVMVectorize").passthrough("-lLLVMPasses").passthrough("-lLLVMLinker")
             .passthrough("-lLLVMIRReader").passthrough("-lLLVMAsmParser").passthrough("-lLLVMBitReader")
             .passthrough("-lLLVMBitWriter").passthrough("-lLLVMMC").passthrough("-lLLVMMCParser")
             .passthrough("-lLLVMMCDisassembler").passthrough("-lLLVMObject").passthrough("-lLLVMBinaryFormat")
             .passthrough("-lLLVMRemarks").passthrough("-lLLVMBitstreamReader").passthrough("-lLLVMDemangle")
             .passthrough("-lLLVMTextAPI").passthrough("-lLLVMOption").passthrough("-lLLVMCoroutines")
             .passthrough("-lLLVMInstrumentation").passthrough("-lLLVMIRPrinter").passthrough("-lLLVMWindowsDriver")
             .passthrough("-lLLVMFrontendOpenMP").passthrough("-lLLVMFrontendOffloading").passthrough("-lLLVMFrontendHLSL")
             .passthrough("-lLLVMFrontendAtomic").passthrough("-lLLVMFrontendDirective").passthrough("-lLLVMFrontendDriver")
             .passthrough("-lLLVMLTO").passthrough("-lLLVMCFGuard").passthrough("-lLLVMObjCARCOpts")
             .passthrough("-lLLVMHipStdPar").passthrough("-lLLVMCGData").passthrough("-lLLVMSandboxIR")
             .passthrough("-lLLVMExtensions").passthrough("-lLLVMDebugInfoDWARF").passthrough("-lLLVMDebugInfoDWARFLowLevel")
             .passthrough("-lLLVMDebugInfoCodeView").passthrough("-lLLVMDebugInfoMSF").passthrough("-lLLVMDebugInfoPDB")
             .passthrough("-lLLVMDebugInfoBTF").passthrough("-lLLVMSymbolize").passthrough("-lLLVMCoverage")
             .passthrough("-lLLVMTelemetry").passthrough("-lLLVMMIRParser")
             .passthrough("-lversion").passthrough("-ladvapi32").passthrough("-lshell32")
             .passthrough("-lole32").passthrough("-luuid").passthrough("-lntdll")
             .passthrough("-lws2_32").passthrough("-lpsapi");
        } else {
            t.passthrough("-lclang-cpp")
             .passthrough("-lLLVM");
        }
    } else {
        if platform() == "windows" {
            var inc    = run(["llvm-config", "--includedir"]).stdout_str;
            var libdir = run(["llvm-config", "--libdir"]).stdout_str;
            var prefix = run(["llvm-config", "--prefix"]).stdout_str;

            if (inc.is_empty()) || (libdir.is_empty()) || (prefix.is_empty()) {
                log::warn("LLVM not found. Run: powershell Scripts/prebuild-llvm-windows.ps1");
            }

            t.passthrough("-I" + inc);
            t.passthrough("-I" + prefix + "/include");
            t.passthrough("-I" + prefix + "/tools/clang/include");
            t.passthrough("-L" + libdir)
             .passthrough("-fno-lto")
             .passthrough("-lclang-cpp")
             .passthrough("-lLLVM");
        } else {
            var inc    = run(["sh", "-c", "llvm-config --includedir | tr -d '\\n' "]).stdout_str;
            var libdir = run(["sh", "-c", "llvm-config --libdir | tr -d '\\n' "]).stdout_str;
            var prefix = run(["sh", "-c", "llvm-config --prefix | tr -d '\\n' "]).stdout_str;
            t.passthrough("-I" + inc);
            t.passthrough("-I" + prefix + "/include");
            t.passthrough("-I" + prefix + "/tools/clang/include");
            t.passthrough("-L" + libdir)
             .passthrough("-fno-lto")
             .passthrough("-lclang-cpp")
             .passthrough("-lLLVM");
        }
    }

    if platform() == "linux" {
        t.passthrough("\\\x27-Wl,-rpath,\\$ORIGIN/../lib\\\x27");
    }

    if platform() == "macos" {
        t.passthrough("\\\x27-Wl,-rpath,\\@loader_path/../lib\\\x27");
    }

    if platform() == "windows" {
        llvm_link_windows(t);
    }

    t.passthrough("-g");
}

fn main() -> i32 {
    const KAIRO_VERSION: string = version_macro("kairo", "-0.1.1+dev");
    const KBLD_VERSION:  string = version_macro("kbld",  "-0.1.0+dev");
    const KFMT_VERSION:  string = version_macro("kfmt",  "-0.1.0+dev");
    const KLD_VERSION:   string = version_macro("kld",   "-0.1.0+dev");
    const KALS_VERSION:  string = version_macro("kals",  "-0.1.0+dev");
    const KPKG_VERSION:  string = version_macro("kpkg",  "-0.1.0+dev");

    // -- LLVM paths -------------------------------------------------------------
    // derived deterministicallyprebuild script guarantees libs are here
    var llvm_build = build_dir() + "/llvm";
    var llvm_src   = project_root() + "/Lib/llvm-runtimes";
    var out_lib    = build_dir() + "/" + triple() + "/" + build_mode() + "/lib";

    // -- prebuild script selection ----------------------------------------------
    var llvm_prebuild = "";
    if platform() == "linux" {
        llvm_prebuild = "bash Scripts/prebuild-llvm-linux.sh";
    }
    if platform() == "macos" {
        llvm_prebuild = "bash Scripts/prebuild-llvm-macos.sh";
    }
    if platform() == "windows" {
        llvm_prebuild = "powershell -ExecutionPolicy Bypass -File Scripts/prebuild-llvm-windows.ps1";
    }

    // we also need to add
    //    "python3 Scripts/gen_diag.py Compiler/DiagTblg > Compiler/Diag/DiagRegistry.k"
    //    as a prebuild step for the entire project, but that is currently not
    //    possible since it would require regenerating DiagRegistry.k before every target

    var p = Project("Kairo")
        .version("kairo-0.0.1+rc.20260220")
        .author("Dhruvan, Ojas and Arnav")
        .license("CC-BY-4.0")
        .compiler("kairo")
        .mode("release")
        .skip_dirs(["build", "Lib", "private"]);

    var kairo = Target("kairo")
        .entry("Compiler/Driver/Kairo.k")
        .includes(["Compiler", "Lib/bootstrap/lib-helix/core"])
        .define(KAIRO_VERSION)
        .passthrough("-fno-lto")
        .pre_build(llvm_prebuild);
    apply_llvm(kairo, llvm_src, llvm_build, out_lib);

    var kbld = Target("kbld")
        .entry("Extras/BuildTool/Driver/kbld.k")
        .include("Compiler")
        .define(KBLD_VERSION)
        .pre_build(llvm_prebuild);
    apply_llvm(kbld, llvm_src, llvm_build, out_lib);

    var kfmt = Target("kfmt")
        .entry("Extras/Formatter/Driver/kfmt.k")
        .include("Compiler")
        .define(KFMT_VERSION)
        .pre_build(llvm_prebuild);
    apply_llvm(kfmt, llvm_src, llvm_build, out_lib);

    var kld = Target("kld")
        .entry("Linker/Driver/kld.k")
        .include("Compiler")
        .define(KLD_VERSION)
        .pre_build(llvm_prebuild);
    apply_llvm(kld, llvm_src, llvm_build, out_lib);

    var klsp = Target("kals")
        .entry("Analyzer/Driver/kals.k")
        .include("Compiler")
        .define(KALS_VERSION)
        .pre_build(llvm_prebuild);
    apply_llvm(klsp, llvm_src, llvm_build, out_lib);

    var kpkg = Target("kpkg")
        .entry("Extras/PackageManager/Driver/kpkg.k")
        .include("Compiler")
        .define(KPKG_VERSION)
        .pre_build(llvm_prebuild);
    apply_llvm(kpkg, llvm_src, llvm_build, out_lib);

    p.target(kairo);
    p.target(kbld);
    p.target(kfmt);
    p.target(kld);
    p.target(klsp);
    p.target(kpkg);

    return 0;
}

__inline_cpp("
#if defined(_WIN32) || defined(_WIN64)
#   pragma comment(lib, \"advapi32.lib\")
#endif
");