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

// llvm-config queries (Windows-only)
fn llvm_static_components(t: ref!(Target)) {
    // Windows links static.
    t.passthrough("-lLLVMCore")
     .passthrough("-lLLVMSupport")
     .passthrough("-lLLVMDemangle")
     .passthrough("-lLLVMTarget")
     .passthrough("-lLLVMTargetParser")

     .passthrough("-lLLVMX86CodeGen")
     .passthrough("-lLLVMX86AsmParser")
     .passthrough("-lLLVMX86Desc")
     .passthrough("-lLLVMX86Disassembler")
     .passthrough("-lLLVMX86Info")
     .passthrough("-lLLVMX86TargetMCA")

     .passthrough("-lLLVMAArch64CodeGen")
     .passthrough("-lLLVMAArch64AsmParser")
     .passthrough("-lLLVMAArch64Desc")
     .passthrough("-lLLVMAArch64Disassembler")
     .passthrough("-lLLVMAArch64Info")
     .passthrough("-lLLVMAArch64Utils")

     .passthrough("-lLLVMWebAssemblyCodeGen")
     .passthrough("-lLLVMWebAssemblyAsmParser")
     .passthrough("-lLLVMWebAssemblyDesc")
     .passthrough("-lLLVMWebAssemblyDisassembler")
     .passthrough("-lLLVMWebAssemblyInfo")
     .passthrough("-lLLVMWebAssemblyUtils")

     .passthrough("-lLLVMARMCodeGen")
     .passthrough("-lLLVMARMAsmParser")
     .passthrough("-lLLVMARMDesc")
     .passthrough("-lLLVMARMDisassembler")
     .passthrough("-lLLVMARMInfo")
     .passthrough("-lLLVMARMUtils")

     .passthrough("-lLLVMRISCVCodeGen")
     .passthrough("-lLLVMRISCVAsmParser")
     .passthrough("-lLLVMRISCVDesc")
     .passthrough("-lLLVMRISCVDisassembler")
     .passthrough("-lLLVMRISCVInfo")
     .passthrough("-lLLVMRISCVTargetMCA")

     .passthrough("-lLLVMCodeGen")
     .passthrough("-lLLVMCodeGenTypes")
     .passthrough("-lLLVMAsmPrinter")
     .passthrough("-lLLVMSelectionDAG")
     .passthrough("-lLLVMGlobalISel")
     .passthrough("-lLLVMMCA")

     .passthrough("-lLLVMScalarOpts")
     .passthrough("-lLLVMInstCombine")
     .passthrough("-lLLVMAggressiveInstCombine")
     .passthrough("-lLLVMTransformUtils")
     .passthrough("-lLLVMVectorize")
     .passthrough("-lLLVMSandboxIR")

     .passthrough("-lLLVMAnalysis")
     .passthrough("-lLLVMProfileData")
     .passthrough("-lLLVMipo")
     .passthrough("-lLLVMPasses")
     .passthrough("-lLLVMPlugins")
     .passthrough("-lLLVMLinker")
     .passthrough("-lLLVMCGData")

     .passthrough("-lLLVMIRReader")
     .passthrough("-lLLVMIRPrinter")
     .passthrough("-lLLVMAsmParser")
     .passthrough("-lLLVMBitReader")
     .passthrough("-lLLVMBitWriter")
     .passthrough("-lLLVMBitstreamReader")

     .passthrough("-lLLVMMC")
     .passthrough("-lLLVMMCParser")
     .passthrough("-lLLVMMCDisassembler")
     .passthrough("-lLLVMObject")
     .passthrough("-lLLVMObjectYAML")
     .passthrough("-lLLVMBinaryFormat")
     .passthrough("-lLLVMInterfaceStub")

     .passthrough("-lLLVMExecutionEngine")
     .passthrough("-lLLVMInterpreter")
     .passthrough("-lLLVMMCJIT")
     .passthrough("-lLLVMJITLink")
     .passthrough("-lLLVMOrcJIT")
     .passthrough("-lLLVMOrcDebugging")
     .passthrough("-lLLVMOrcShared")
     .passthrough("-lLLVMOrcTargetProcess")
     .passthrough("-lLLVMRuntimeDyld")

     .passthrough("-lLLVMRemarks")
     .passthrough("-lLLVMTextAPI")
     .passthrough("-lLLVMTextAPIBinaryReader")
     .passthrough("-lLLVMOption")
     .passthrough("-lLLVMCoroutines")
     .passthrough("-lLLVMInstrumentation")
     .passthrough("-lLLVMWindowsDriver")
     .passthrough("-lLLVMWindowsManifest")

     .passthrough("-lLLVMFrontendOpenMP")
     .passthrough("-lLLVMFrontendOffloading")
     .passthrough("-lLLVMFrontendOpenACC")
     .passthrough("-lLLVMFrontendHLSL")
     .passthrough("-lLLVMFrontendAtomic")
     .passthrough("-lLLVMFrontendDirective")
     .passthrough("-lLLVMFrontendDriver")

     .passthrough("-lLLVMLTO")
     .passthrough("-lLLVMDTLTO")
     .passthrough("-lLLVMCFGuard")
     .passthrough("-lLLVMObjCARCOpts")
     .passthrough("-lLLVMHipStdPar")
     .passthrough("-lLLVMExtensions")

     .passthrough("-lLLVMDebugInfoDWARF")
     .passthrough("-lLLVMDebugInfoDWARFLowLevel")
     .passthrough("-lLLVMDebugInfoCodeView")
     .passthrough("-lLLVMDebugInfoMSF")
     .passthrough("-lLLVMDebugInfoPDB")
     .passthrough("-lLLVMDebugInfoGSYM")
     .passthrough("-lLLVMDebugInfoLogicalView")
     .passthrough("-lLLVMDebugInfoBTF")
     .passthrough("-lLLVMDebuginfod")
     .passthrough("-lLLVMDWP")
     .passthrough("-lLLVMDWARFLinker")
     .passthrough("-lLLVMDWARFLinkerClassic")
     .passthrough("-lLLVMDWARFLinkerParallel")
     .passthrough("-lLLVMDWARFCFIChecker")
     .passthrough("-lLLVMSymbolize")
     .passthrough("-lLLVMCoverage")

     .passthrough("-lLLVMObjCopy")
     .passthrough("-lLLVMXRay")
     .passthrough("-lLLVMDlltoolDriver")
     .passthrough("-lLLVMLibDriver")
     .passthrough("-lLLVMCFIVerify")
     .passthrough("-lLLVMDiff")
     .passthrough("-lLLVMExegesis")
     .passthrough("-lLLVMExegesisX86")
     .passthrough("-lLLVMExegesisAArch64")
     .passthrough("-lLLVMExegesisRISCV")
     .passthrough("-lLLVMOptDriver")
     .passthrough("-lLLVMFuzzMutate")
     .passthrough("-lLLVMFuzzerCLI")
     .passthrough("-lLLVMFileCheck")
     .passthrough("-lLLVMLineEditor")
     .passthrough("-lLLVMTelemetry")
     .passthrough("-lLLVMMIRParser")
     .passthrough("-lLLVMABI")

     .passthrough("-lversion")
     .passthrough("-ladvapi32")
     .passthrough("-lshell32")
     .passthrough("-lole32")
     .passthrough("-luuid")
     .passthrough("-lntdll")
     .passthrough("-lws2_32")
     .passthrough("-lpsapi")
     .passthrough("-lzstd")
     .passthrough("-lzlib");
}

// Clang archives, explicit because llvm-config doesn't report them.
// Windows static only.
fn clang_static_components(t: ref!(Target)) {
    t.passthrough("-lclangBasic")
     .passthrough("-lclangDriver")
     .passthrough("-lclangOptions")
     .passthrough("-lclangFrontend")
     .passthrough("-lclangFrontendTool")
     .passthrough("-lclangRewriteFrontend")

     .passthrough("-lclangCodeGen")
     .passthrough("-lclangSema")
     .passthrough("-lclangAnalysis")
     .passthrough("-lclangAnalysisFlowSensitive")
     .passthrough("-lclangAnalysisFlowSensitiveModels")
     .passthrough("-lclangAnalysisLifetimeSafety")
     .passthrough("-lclangAnalysisScalable")

     .passthrough("-lclangAST")
     .passthrough("-lclangASTMatchers")
     .passthrough("-lclangDynamicASTMatchers")
     .passthrough("-lclangParse")
     .passthrough("-lclangLex")
     .passthrough("-lclangEdit")
     .passthrough("-lclangRewrite")
     .passthrough("-lclangAPINotes")

     .passthrough("-lclangSerialization")
     .passthrough("-lclangCrossTU")
     .passthrough("-lclangIndex")
     .passthrough("-lclangIndexSerialization")
     .passthrough("-lclangInstallAPI")
     .passthrough("-lclangExtractAPI")

     .passthrough("-lclangStaticAnalyzerCore")
     .passthrough("-lclangStaticAnalyzerCheckers")
     .passthrough("-lclangStaticAnalyzerFrontend")

     .passthrough("-lclangFormat")
     .passthrough("-lclangToolingCore")
     .passthrough("-lclangToolingInclusions")
     .passthrough("-lclangToolingInclusionsStdlib")
     .passthrough("-lclangToolingRefactoring")
     .passthrough("-lclangToolingASTDiff")
     .passthrough("-lclangToolingSyntax")
     .passthrough("-lclangTransformer")
     .passthrough("-lclangTooling")

     .passthrough("-lclangDependencyScanning")
     .passthrough("-lclangDirectoryWatcher")
     .passthrough("-lclangSupport");
}

// Windows SDK / MSVC toolchain discovery
//   Host-toolchain probing, NOT LLVM linkage.

fn windows_sdk_paths(t: ref!(Target)) {
    const eval if defined(_WIN64) || defined(_WIN32) {
        t.passthrough("-fms-runtime-lib=dll");
        t.passthrough("-Xlinker").passthrough("/nodefaultlib:libcmt");

        var sdk_lib_root: string = "";
        var hkey: HKEY;
        if RegOpenKeyExA(HKEY_LOCAL_MACHINE,
          r"SOFTWARE\\WOW6432Node\\Microsoft\\Windows Kits\\Installed Roots",
          0, KEY_READ, &hkey) == ERROR_SUCCESS {
            var buf: std::Memory::buffer::<char, 512>;
            var sz:  DWORD = 512;
            
            if RegQueryValueExA(hkey, r"KitsRoot10", &null, &null,
              reinterpret_cast::<LPBYTE>(buf), &sz) == ERROR_SUCCESS {
                sdk_lib_root = (
                    kairo::std::nstring_to_string(
                        inline "c++" { reinterpret_cast<unsigned char*>(buf) }
                    )
                ) + kairo::std::nstring_to_string(r"Lib");
            }

            RegCloseKey(hkey);
        }

        if sdk_lib_root.is_empty() {
            sdk_lib_root = "C:/Program Files (x86)/Windows Kits/10/Lib";
        }

        var newest_sdk: string = "";
        for entry in libcxx::filesystem::directory_iterator(sdk_lib_root.raw()) {
            if entry.is_directory() {
                var name = kairo::std::nstring_to_string(entry.path().filename().string().c_str());
                if name.starts_with(kairo::std::nstring_to_string(r"10.")) && (name > newest_sdk) {
                    newest_sdk = name;
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

fn really_is_debug() -> bool {
    // KBLD_MODE is hardcoded to "release" by kbld's driver right now.
    // Fall back to a separate env var the user sets explicitly.
    var m = env("KAIRO_BUILD_MODE");
    if (m.has_value()) && (m.value() == "debug") { return true; }
    return false;
}

fn common_flags(t: ref!(Target)) {
    // Every target gets these. One place, no per-target drift.
    t.passthrough("-flto=thin")
     .passthrough("-fuse-ld=lld")
     .passthrough("-w")
     .passthrough("-g");

    // Stage 0 unconditionally adds -fsanitize=undefined,bounds,function in debug.
    // On Windows that pulls MSVC's compiler-rt which is incompatible with our
    // LLVM 19 toolchain. Cancel it here; clang takes the last -fsanitize wins.
    if (really_is_debug()) {
        t.passthrough("-fno-sanitize=all");
    }

    if (really_is_debug()) {
        t.passthrough("-DDEBUG");
        t.passthrough("-fno-lto");
    } else {
        t.passthrough("-DNDEBUG");
    }
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
        llvm_static_components(t);
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
    if platform() == "linux"   { return "bash Scripts/prebuild-llvm-linux.sh && python3 Scripts/gen_diag.py Compiler/Diagnostic/TableGen --lib-output=build/.kbld/registry.o --output=Compiler/Diagnostic/Registry.k"; }
    if platform() == "macos"   { return "bash Scripts/prebuild-llvm-macos.sh && python3 Scripts/gen_diag.py Compiler/Diagnostic/TableGen --lib-output=build/.kbld/registry.o --output=Compiler/Diagnostic/Registry.k"; }
    if platform() == "windows" { return "powershell -ExecutionPolicy Bypass -Command \"& 'Scripts/prebuild-llvm-windows.ps1'; python3 Scripts/gen_diag.py Compiler/Diagnostic/TableGen --lib-output=build/.kbld/registry.o --output=Compiler/Diagnostic/Registry.k\" "; }
    return "";
}

// Every LLVM-linking tool shares this shape. One call site = no drift.
fn llvm_tool(name:     string, entry:      string, ver:     string, includes: vec::<string>,
             llvm_src: string, llvm_build: string, out_lib: string) -> Target {
    var t = Target(name)
        .entry(entry)
        .includes(includes)
        .define(ver)
        .passthrough("-x none")
        .passthrough("build/.kbld/registry.o")
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
    const KWATCH_VERSION: string = version_macro("kwatch","-0.1.0+dev");
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

    p.target(llvm_tool("kairo", "Compiler/Driver/Kairo.k",                KAIRO_VERSION, compiler_inc, llvm_src, llvm_build, out_lib));
    p.target(llvm_tool("kbld",  "Extras/BuildTool/Driver/kbld.k",         KBLD_VERSION,  kbld_inc,     llvm_src, llvm_build, out_lib));
    p.target(llvm_tool("kfmt",  "Extras/Formatter/Driver/kfmt.k",         KFMT_VERSION,  kfmt_inc,     llvm_src, llvm_build, out_lib));
    p.target(llvm_tool("kld",   "Linker/Driver/kld.k",                    KLD_VERSION,   kld_inc,      llvm_src, llvm_build, out_lib));
    p.target(llvm_tool("kals",  "Analyzer/Driver/kals.k",                 KALS_VERSION,  kals_inc,     llvm_src, llvm_build, out_lib));
    p.target(llvm_tool("kwatch","Compiler/Driver/KairoWatch.k",           KWATCH_VERSION, compiler_inc, llvm_src, llvm_build, out_lib));
    p.target(llvm_tool("kpkg",  "Extras/PackageManager/Driver/kpkg.k",    KPKG_VERSION,  kpkg_inc,     llvm_src, llvm_build, out_lib));
    p.target(llvm_tool("katar", "Extras/KaTAR/KTCompress.k",              KAIRO_VERSION, katar_inc,    llvm_src, llvm_build, out_lib));
    p.target(llvm_tool("clang-diag-identity", "Compiler/Driver/GenClangDiagIdentity.k", KAIRO_VERSION, compiler_inc, llvm_src, llvm_build, out_lib));

    return 0;
}

__inline_cpp("
#if defined(_WIN32) || defined(_WIN64)
#   pragma comment(lib, \"advapi32.lib\")
#endif
");