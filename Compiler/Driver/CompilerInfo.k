/// --- The Kairo Project ------------------------ Driver/CompilerInfo.k --- ///
///
///   CompilerInstance, part: the info queries. Everything the driver
///   answers without compiling: --help, --version, --explain, and the
///   --print-* family (targets, cpus, target info, dirs, clang args, the
///   clang-to-kairo flag map). An `extend` of the class in
///   CompilerInstance.k (Driver/module.k).
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "llvm/ADT/StringExtras.h"
ffi "c++" import "llvm/TargetParser/Triple.h"
ffi "c++" import "llvm/MC/TargetRegistry.h"
ffi "c++" import "llvm/MC/MCSubtargetInfo.h"
ffi "c++" import "llvm/Target/TargetMachine.h"
ffi "c++" import "llvm/Target/TargetOptions.h"
ffi "c++" import "llvm/Support/CodeGen.h"
ffi "c++" import "Native/Types.hh"
ffi "c++" import "Native/KShims.hh"
ffi "c++" import "vector"
ffi "c++" import "string"
ffi "c++" import "utility"
ffi "c++" import "algorithm"
ffi "c++" import "cstring"
ffi "c++" import "optional"

import API::Link::Link
import API::LinkDiag::LinkMessage
import API::LinkJob::LinkJob
import API::Toolchain::Toolchain
import Command::Command::Command
import Command::FlagRegistry::register_kairo_flags
import Command::FlagTranslator::FlagTranslator
import Diagnostic::Code::diag_from_code
import Diagnostic::Registry::{
    DiagID,
    diag_explain,
}
import Driver::CompilerInstance::CompilerInstance
import Driver::InputKinds::{
    InputClass,
    classify_input,
}
import Interop::Clang::ClangBackend::ClangBackend
import Interop::Clang::ClangJobs::ClangJobs
import Support::FileIO::Path::Path
import Support::ShellQuote::shell_quote
import Support::TermRenderer::TermRenderer
import Sysroot::Cache::SysCache
import Sysroot::Names::{
    SysNames,
    SysTarget,
    glibc_default_version,
}
import std::env
import std::io

extend CompilerInstance {
    /// No-op when the instance was built from an invocation: there is no flag
    /// table to describe and no argv[0] to name in the USAGE line.
    fn print_help(self) {
        if self._cmd == &null {
            return
        }

        self._cmd->print_help(self.invocation()->args.get_bool("help-hidden"))
    }

    fn print_version(self) {
        // version_string() is a C `const char *`, and an f-string formats a
        // pointer as `const c_char @ 0x...`: copy the text into a string.
        var ver = string(unsafe ((kairo::version_string() as unsafe *const u8) as *const u8))
        io::println(f"installed version: {ver}")
        // "target" is what this run would compile for (--target when given),
        // "host" is the machine running the compiler; reporting only the host
        // misled anyone checking a cross invocation.
        io::println(f"target triple:     {self._effective_triple()}")
        io::println(f"host triple:       {self.get_target_triple()}")
        io::println(
            f"thread model:      {string(unsafe ((kairo::std::thread_model_cstr() as unsafe *const u8) as *const u8))}",
        )

        io::println(f"installed at:      {Path::parent_of(env::exe_path())}")
        var sr = self._version_sysroot()
        if sr.empty() {
            sr = "could not find associated sysroot"
        }

        io::println(f"sysroot:           {sr}")
    }

    /// The sysroot this run would compile against: the bundled one for the
    /// target (_use_bundled_sysroot's lookup, without its validation), else
    /// --sysroot, else "".
    priv fn _version_sysroot(self) -> string {
        var want = self._sysroot_target()
        if !want.empty() {
            var dir = self._bundled_sysroot_dir(want)
            if !dir.empty() {
                return dir
            }

            // Then the generator's cache, as the --target hook looks: never
            // a build, --version only reports.
            if self.invocation()->target.sysroot.empty() {
                var tgt   = SysTarget{}
                var cands = cxx::std::vector<string>()
                var why   = ""
                var name  = want
                if SysNames::parse(want, glibc_default_version(), &tgt, &cands, &why) {
                    name = tgt.name
                }

                var cache = SysCache(SysCache::default_root())
                if !cache.root.empty() {
                    var cached = cache.lookup(name)
                    if !cached.empty() {
                        return cached
                    }
                }
            }
        }

        return self.invocation()->target.sysroot
    }

    /// Resolves and renders the long-form explanation for a diagnostic code.
    /// Returns 1 if the code is unknown.
    fn run_explain(self) -> i32 {
        var code = self.invocation()->args.get_string("explain")

        var first: usize = kairo::std::to_std_string(code).find_first_not_of(" \t\n\r\f\v")
        if !(cxx::std::string::npos == first) {
            var last: usize = kairo::std::to_std_string(code).find_last_not_of(" \t\n\r\f\v")
            code = code.subslice(first, last - first + 1)
        }

        var diag_id = diag_from_code(code)
        var explain = diag_explain(diag_id)
        if explain.empty() {
            io::eprintln(f"error: unknown diagnostic code '{code}'")
            return 1
        }

        var r = TermRenderer(true, 80)
        io::println(f"{r.render(explain)}")
        return 0
    }

    //  --print-targets

    /// Lists all targets registered in this LLVM build. Mirrors `llc -version`'s
    /// "Registered Targets" section.
    fn print_targets(self) -> i32 {
        io::println("Registered targets:")

        // collect into a vector so we can sort and align the output
        var rows:     cxx::std::vector<cxx::std::pair<llvm::StringRef, llvm::StringRef>>
        var max_name: usize                                                              = 0

        for T in llvm::TargetRegistry::targets() {
            rows.emplace_back(T.getName(), T.getShortDescription())
            max_name = cxx::std::max(max_name, cxx::std::strlen(T.getName()))
        }

        cxx::std::sort(
            rows.begin(),
            rows.end(),
            fn (const a: cxx::std::pair<llvm::StringRef, llvm::StringRef>,
                const b: cxx::std::pair<llvm::StringRef, llvm::StringRef>) || -> bool = a.first < b.first,
        )

        for row in rows {
            var out = f"  {string(unsafe ((row.first.data() as unsafe *const u8) as *const u8), row.first.size())}"
            for var i: usize = row.first.size(); i < max_name + 2; ++i {
                out += " "
            }

            out += f"- {string(unsafe ((row.second.data() as unsafe *const u8) as *const u8), row.second.size())}"
            io::println(f"{out}")
        }

        return 0
    }

    //  --print-cpus

    /// Lists CPUs supported by the effective target. Uses --target if given,
    /// otherwise the host triple. Mirrors `llc -mtriple=X -mcpu=help`.
    fn print_cpus(self) -> i32 {
        var triple = self._effective_triple()
        var llvm_triple = llvm::Triple(llvm::Triple::normalize(kairo::sref(triple)))
        var err: cxx::std::string

        var T: unsafe *llvm::Target = unsafe (llvm::TargetRegistry::lookupTarget(llvm_triple, &err) as unsafe *llvm::Target)

        if T == &null {
            // _apply_invocation already reported this triple (and cleared ok)
            // when it resolved the target; a second P004F here printed the
            // same line twice.
            if self.invocation()->ok {
                self._diag->report(
                    DiagID::P004F,
                    f"unknown target triple '{triple}': {kairo::std::from_std_string<string>(err)}",
                ).emit()
            }

            // Info queries exit before execute(), so nothing else drains the
            // engine; without this the error is built and never printed.
            self.flush_errors()
            return 1
        }

        var TM:   unsafe *llvm::TargetMachine = &null
        var opts: llvm::TargetOptions

        TM = T->createTargetMachine(
            llvm_triple,
            kairo::sref(/*CPU=*/r"generic"),
            /*Features=*/kairo::sref(r""),
            opts,
            cxx::std::optional<llvm::Reloc::Model>(cxx::std::nullopt)
        )

        finally {
            @cxx::delete TM
        }

        if TM == &null {
            self._diag->report(
                DiagID::P005F,
                f"failed to create TargetMachine for '{string(triple.raw())}'",
            ).emit()
            return 1
        }

        var STI: unsafe *llvm::MCSubtargetInfo = unsafe (TM->getMCSubtargetInfo() as unsafe *llvm::MCSubtargetInfo)
        if STI == &null {
            self._diag->report(
                DiagID::P005F,
                f"no subtarget info for '{string(triple.raw())}'",
            ).emit()
            return 1
        }

        io::println(f"Available CPUs for target '{string(triple.raw())}':")

        var cpu_rows: cxx::std::vector<cxx::std::string>
        var max_cpu:  usize                              = 0

        for cpu in STI->getAllProcessorDescriptions() {
            cpu_rows.emplace_back(cpu.Key)
            max_cpu = cxx::std::max(max_cpu, cxx::std::strlen(cpu.Key))
        }

        cxx::std::sort(
            cpu_rows.begin(),
            cpu_rows.end(),
            fn (const a: cxx::std::string, const b: cxx::std::string) || -> bool = a < b,
        )

        for *row in cpu_rows {
            io::println(f"  {kairo::std::from_std_string<string>((*row))}")
        }

        io::println("")
        io::println("Available features:")

        var feat_rows: cxx::std::vector<cxx::std::pair<cxx::std::string, cxx::std::string>>
        var max_feat:  usize                                                                = 0

        for feat in STI->getAllProcessorFeatures() {
            var unsafe *d = feat.Desc
            if d != &null && *d != 0x00 {
                feat_rows.emplace_back(feat.Key, d)
            } else {
                feat_rows.emplace_back(feat.Key, cxx::std::string())
            }

            max_feat = cxx::std::max(max_feat, cxx::std::strlen(feat.Key))
        }

        cxx::std::sort(
            feat_rows.begin(),
            feat_rows.end(),
            fn (const a: cxx::std::pair<cxx::std::string, cxx::std::string>,
                const b: cxx::std::pair<cxx::std::string, cxx::std::string>) || -> bool = a.first < b.first,
        )

        for *row in feat_rows {
            var out = f"  {string(unsafe ((row->first.c_str() as unsafe *const u8) as *const u8), row->first.size())}"
            for var i: usize = row->first.size(); i < max_feat + 2; ++i {
                out += " "
            }

            if row->second.size() > 0 {
                out += f"- {string(unsafe ((row->second.c_str() as unsafe *const u8) as *const u8), row->second.size())}"
            }

            io::println(f"{out}")
        }

        return 0
    }

    //  --print-target-info

    /// Prints triple, architecture, ABI, pointer width, endianness, object format,
    /// data layout, and default CPU for the effective target. Uses --target if
    /// given, otherwise the host triple.
    fn print_target_info(self) -> i32 {
        var triple = self._effective_triple()
        var llvm_triple = llvm::Triple(llvm::Triple::normalize(kairo::sref(triple)))
        var err: cxx::std::string

        var T: unsafe *llvm::Target = unsafe (llvm::TargetRegistry::lookupTarget(llvm_triple, &err) as unsafe *llvm::Target)

        if T == &null {
            if self.invocation()->ok { // see print_cpus: _apply_invocation may have reported it already
                self._diag->report(
                    DiagID::P004F,
                    f"unknown target triple '{string(triple.raw())}': {kairo::std::from_std_string<string>(err)}",
                ).emit()
            }

            self.flush_errors() // see print_cpus: info queries never reach execute()
            return 1
        }

        var full_triple: string = kairo::std::from_std_string<string>(llvm_triple.getTriple())
        var arch:        llvm::StringRef = llvm_triple.getArchName()
        var vendor:      llvm::StringRef = llvm_triple.getVendorName()
        var os_name:     llvm::StringRef = llvm_triple.getOSName()
        var environment: llvm::StringRef = llvm_triple.getEnvironmentName()

        var ptr_width: string
        if llvm_triple.isArch64Bit() {
            ptr_width = "64-bit"
        } else if llvm_triple.isArch32Bit() {
            ptr_width = "32-bit"
        } else if llvm_triple.isArch16Bit() {
            ptr_width = "16-bit"
        } else {
            ptr_width = "unknown"
        }

        var endian: string = if (llvm_triple.isLittleEndian()) => ("little") else => "big"

        var os_family: string
        if llvm_triple.isOSLinux() {
            os_family = "linux"
        } else if llvm_triple.isOSDarwin() {
            os_family = "darwin"
        } else if llvm_triple.isOSWindows() {
            os_family = "windows"
        } else if llvm_triple.isOSFreeBSD() {
            os_family = "freebsd"
        } else if llvm_triple.isOSWASI() {
            os_family = "wasi"
        } else if llvm_triple.isOSBinFormatELF() {
            os_family = "elf (other)"
        } else if llvm_triple.isOSBinFormatMachO() {
            os_family = "macho (other)"
        } else {
            os_family = "unknown"
        }

        var obj_format: string
        match llvm_triple.getObjectFormat() {
            case llvm::Triple::COFF {
                obj_format = "COFF"
            } case llvm::Triple::ELF {
                obj_format = "ELF"
            } case llvm::Triple::MachO {
                obj_format = "Mach-O"
            } case llvm::Triple::Wasm {
                obj_format = "Wasm"
            } case llvm::Triple::XCOFF {
                obj_format = "XCOFF"
            } case llvm::Triple::GOFF {
                obj_format = "GOFF"
            } case llvm::Triple::DXContainer {
                obj_format = "DXContainer"
            } case llvm::Triple::SPIRV {
                obj_format = "SPIR-V"
            } default {
                obj_format = "unknown"
            }
        }

        io::println(f"Triple:          {full_triple}")
        io::println(
            f"Architecture:    {string(unsafe ((arch.data() as unsafe *const u8) as *const u8), arch.size())}",
        )

        io::println(
            f"Vendor:          {string(unsafe ((vendor.data() as unsafe *const u8) as *const u8), vendor.size())}",
        )

        io::println(
            f"OS:              {string(unsafe ((os_name.data() as unsafe *const u8) as *const u8), os_name.size())}",
        )

        io::println(
            f"Environment:     {string(unsafe ((environment.data() as unsafe *const u8) as *const u8), environment.size())}",
        )

        io::println(f"Pointer width:   {ptr_width}")
        io::println(f"Endianness:      {endian}")
        io::println(f"OS family:       {os_family}")
        io::println(f"Object format:   {obj_format}")

        // Data layout via TargetMachine
        var TM:   unsafe *llvm::TargetMachine = &null
        var opts: llvm::TargetOptions

        TM = T->createTargetMachine(
            llvm_triple,
            kairo::sref(/*CPU=*/r"generic"),
            /*Features=*/kairo::sref(r""),
            opts,
            cxx::std::optional<llvm::Reloc::Model>(cxx::std::nullopt)
        )

        if TM == &null {
            self._diag->report(
                DiagID::P005F,
                f"failed to create TargetMachine for '{string(triple.raw())}'",
            ).emit()
            return 1
        }

        finally {
            @cxx::delete TM
        }

        var data_layout: string = kairo::std::from_std_string<string>(
            TM->createDataLayout().getStringRepresentation(),
        )

        var default_cpu: llvm::StringRef = TM->getTargetCPU()

        io::println(f"Data layout:     {data_layout}")
        io::println(
            f"Default CPU:     {string(unsafe ((default_cpu.data() as unsafe *const u8) as *const u8), default_cpu.size())}",
        )

        return 0
    }

    /// Handles info-query flags. Currently implements \c --print-cfg;
    /// all other flags are no-ops until their subsystems exist.
    fn run_info_query(self) -> i32 {
        if self.invocation()->args.get_bool("print-targets") {
            return self.print_targets()
        }

        if self.invocation()->args.get_bool("print-cpus") {
            return self.print_cpus()
        }

        if self.invocation()->args.get_bool("print-target-info") {
            return self.print_target_info()
        }

        if self.invocation()->args.get_bool("print-dirs") {
            return self.print_dirs()
        }

        if self.invocation()->args.get_bool("print-clang-args") {
            return self.print_clang_args(false)
        }

        if self.invocation()->args.get_bool("print-jobs") {
            return self.print_clang_args(true)
        }

        if self.invocation()->args.get_bool("print-from-clang") {
            return self.print_from_clang()
        }

        if self.invocation()->args.get_bool("print-runtimes-revision") {
            io::println(
                f"{string(unsafe ((kairo::runtimes_revision_string() as unsafe *const u8) as *const u8))}",
            )

            return 0
        }

        if self.invocation()->args.get_bool("print-cfg") {
            for *s in *self.invocation()->args.get_list("cfg") {
                io::println(f"{(*s)}")
            }

            return 0
        }

        return 0
    }

    //  --print-dirs

    /// Resolves the link toolchain for the effective target and sysroot and
    /// prints where everything was found. Exit 1 if resolution failed.
    fn print_dirs(self) -> i32 {
        var tc   = Toolchain()
        var msgs = cxx::std::vector<LinkMessage>()
        var ok   = tc.resolve(&self.invocation()->target, &self.invocation()->linker, &msgs)
        for var line: string in tc.describe() {
            io::println(f"{line}")
        }

        self._report_link(&msgs)
        // Info queries return before execute(), so nothing else drains the
        // engine; without this a failed resolve exits 1 silently.
        self.flush_errors()
        return if (ok) => (0) else => 1
    }

    //  --print-clang-args

    /// Prints the cc1 invocation every compile copies, as one shell line:
    /// `clang -cc1` and the arguments, each quoted when the shell would
    /// split or expand it. The input is a placeholder; a real compile hands
    /// clang each TU as an in-memory buffer. Builds the backend's
    /// configuration and starts nothing.
    //  --print-from-clang

    /// \brief the reverse map, made visible: the clang command line given as
    ///        the inputs (after `--`) as kairo CLI words, and the words kairo
    ///        has no flag for. The kairo words are then parsed by the real
    ///        kairo parser, so a row that maps to a flag that does not exist
    ///        fails here, not first in kcc.
    ///
    /// \details Two lines, each word shell-quoted:
    ///            kairo: <kairo words>
    ///            clang-only: <clang words>
    ///          Exit 1 if clang's table or kairo's parser rejected a word.
    fn print_from_clang(self) -> i32 {
        var clang_argv = self.invocation()->input_files
        var kw         = cxx::std::vector<string>()
        var cw         = cxx::std::vector<string>()
        var err        = ""
        if !FlagTranslator::from_driver(&clang_argv, &kw, &cw, &err) {
            self._diag->report(DiagID::U014E, err).emit()
            self.flush_errors()
            return 1
        }

        var line = "kairo:"
        for *w in kw {
            line = line + " " + shell_quote(*w)
        }

        io::println(f"{line}")
        var cline = "clang-only:"
        for *w in cw {
            cline = cline + " " + shell_quote(*w)
        }

        io::println(f"{cline}")

        var unsafe *cmd = kairo::std::create<Command>(0, &null, self._diag)
        finally {
            kairo::std::destroy(cmd)
        }

        register_kairo_flags(cmd)
        // Validated, not run: a placeholder input after `--` (from_driver
        // never emits one) satisfies "at least one input" for a clang line
        // that names only flags.
        var check = kw
        check.push_back("--")
        check.push_back("<from-clang>")
        var parsed = cmd->parse_words(&check)
        self.flush_errors()
        return if (parsed.ok) => (0) else => 1
    }

    /// \p with_link: --print-jobs, which also prints the planned link.
    fn print_clang_args(self, with_link: bool) -> i32 {
        // A failed parse leaves the invocation at its defaults, so the line
        // would show a target and level the user did not ask for.
        if !self.args_ok() {
            self.flush_errors()
            return 1
        }

        var unsafe *be = kairo::std::create<ClangBackend>(self._sm, self._backend_config())
        finally {
            kairo::std::destroy(be)
        }

        var line = "clang -cc1"
        for var a: string in be->invocation_args() {
            line = line + " " + shell_quote(a)
        }

        io::println(f"{line}")

        // Then, per C/C++ input, the cc1 line clang's driver plans for it
        // (its -###), as the input's object would be compiled. Only these
        // start clang: a Kairo-only line still starts nothing.
        var n_in = self.invocation()->input_files.size()
        var exe  = Path::join_str(Path::parent_of(env::exe_path()), "clang")
        for var i: usize = 0; i < n_in; ++i {
            var k = classify_input(
                self.invocation()->input_files[i],
                self.invocation()->input_lang(i),
            )

            if k.cls != InputClass::Source {
                continue
            }

            var w = self._native_words_for(be, k)
            w.push_back("-c")
            w.push_back("-x")
            w.push_back(k.type_name())
            w.push_back(k.path)
            w.push_back("-o")
            w.push_back(Path(k.path).stem() + ".o")
            var jobs = ClangJobs(be, exe)
            if !jobs.plan(&w) {
                if !jobs.error.empty() {
                    self._diag->report(DiagID::U011E, f"{k.path}: {jobs.error}").emit()
                }

                self.flush_errors()
                return 1
            }

            for *pl in jobs.planned {
                io::println(f"{(*pl)}")
            }
        }

        // Then, for --print-jobs (kcc's -###), the link as the run would
        // plan it, when the run links. Objects are named as the run would write them; a Kairo
        // input's imports are only known after preprocessing, so a graph
        // run lists its entries and the library, not each module it reaches.
        var *lk = &self.invocation()->linker
        if with_link && !lk->compile_only && !self.invocation()->frontend.stops_before_codegen() {
            var job = LinkJob(&self.invocation()->target, lk)
            job.output = if (!self.invocation()->frontend.output.empty()) => (self.invocation()->frontend.output)
                         else => "a.out"
            for var i: usize = 0; i < n_in; ++i {
                var k = classify_input(
                    self.invocation()->input_files[i],
                    self.invocation()->input_lang(i),
                )

                if k.cls == InputClass::Source {
                    job.add_object(Path(k.path).stem() + ".o")
                } else if k.cls == InputClass::Kairo {
                    // kairo_object_stem's rule; _inputs is not built for an info query.
                    var stem  = Path(k.path).stem()
                    var taken = false
                    for var j: usize = 0; j < n_in; ++j {
                        var o = classify_input(
                            self.invocation()->input_files[j],
                            self.invocation()->input_lang(j),
                        )

                        if o.cls == InputClass::Source && Path::stem_of(o.path) == stem {
                            taken = true
                        }
                    }

                    job.add_object(stem + (if (taken) => (".k.o") else => ".o"))
                } else if k.cls == InputClass::LinkInput {
                    job.add_object(k.path)
                }
            }

            if lk->kairo_lib {
                job.lazy_objects.push_back("<kairo-library>/*.o")
            }

            var tc   = Toolchain()
            var argv = cxx::std::vector<string>()
            var msgs = cxx::std::vector<LinkMessage>()
            var ok   = Link::plan(&job, &tc, &argv, &msgs)
            self._report_link(&msgs)
            if ok {
                io::println(f"{Link::render(&argv)}")
            }
        }

        self.flush_errors()
        return 0
    }
}
