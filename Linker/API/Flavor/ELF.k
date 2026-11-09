/// --- The Kairo Project ----------------------------- API/Flavor/ELF.k --- ///
///
///   Renders a LinkJob and Toolchain to ld.lld arguments (ELF).
///
///   Decides nothing the Toolchain did not resolve and runs nothing.
///
///   Order is clang's Gnu linker order, so a line from here diffs cleanly
///   against `clang++ -###` for the same target:
///
///     options, -o, crt startup, crtbegin, -L, rpaths, objects,
///     user libs, default libs, crtend, crt end
///
///   Output shape:
///     --shared                  -shared, crtbeginS/crtendS, no crt1
///     --static -fpie            static PIE: rcrt1.o, -static -pie
///                               --no-dynamic-linker
///     --static (or static-only) -static, crt1.o, crtbeginT.o
///     default on Linux          -pie, Scrt1.o, crtbeginS.o
///     -fno-pie                  -no-pie, crt1.o, crtbegin.o
///
///   Static links wrap the default libraries in one --start-group: libc++,
///   the unwinder, the builtins and libc reference each other in cycles, and
///   ordering them by hand is how static musl links break.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "vector"

import API::FS::LinkFS
import API::HostSystem::HostSystem
import API::LinkDiag::{
    LinkDiag,
    LinkMessage,
    LinkSeverity,
}
import API::LinkJob::LinkJob
import API::Text::LinkText
import API::Toolchain::Toolchain

pub class ELFArgs {
    static fn build(@inout job:  LinkJob,
                    @inout tc:   Toolchain,
                    @inout argv: cxx::std::vector<string>,
                    @inout msgs: cxx::std::vector<LinkMessage>) -> bool {
        var errs0 = LinkDiag::error_count(&msgs)
        var *o    = job.opts

        if job.output.empty() {
            msgs.push_back(LinkDiag::make(LinkSeverity::Error, "link: no output path"))
            return false
        }

        var shared     = o->shared
        var want_stat  = o->static_link || tc.static_only
        var is_linux   = LinkText::starts_with(tc.os, "linux")
        var static_pie = want_stat && !shared && o->f_pie == 1
        var pie        = !shared && !want_stat && (o->f_pie == 1 || o->f_pie == -1 && is_linux)
        var dyn_exe    = !shared && !want_stat
        var no_crt     = o->no_crt || o->no_entry || o->freestanding
        var no_libs    = o->no_default_libs || o->freestanding

        if shared && tc.static_only {
            msgs.push_back(
                LinkDiag::make(
                    LinkSeverity::Error,
                    f"cannot build a shared library: the sysroot {tc.sysroot} for {tc.triple} is static-only (no dynamic loader or libc.so); pass --target for a dynamic target, e.g. --target=x86_64-linux-gnu",
                ),
            )

            return false
        }

        if shared && o->static_link {
            msgs.push_back(
                LinkDiag::make(LinkSeverity::Error, "--shared and --static are mutually exclusive"),
            )

            return false
        }

        /// # options
        argv.push_back("ld.lld")
        argv.push_back("--color-diagnostics=never")
        argv.push_back("--error-limit=0")
        if job.threads > 0 {
            argv.push_back(f"--threads={job.threads}")
        }

        // No --lto-O<n>: the backend always emits native objects (EmitObjAction),
        // so no bitcode reaches lld and --lto is marked unimplemented.
        // A bitcode archive still can (LinkJob::lto_cache_dir): its compiled
        // modules are reused across links. Capped so the cache cannot grow
        // without bound; lld prunes it.
        if !job.lto_cache_dir.empty() {
            argv.push_back(f"--thinlto-cache-dir={job.lto_cache_dir}")
            argv.push_back("--thinlto-cache-policy=cache_size_bytes=4g")
        }

        if !tc.emulation.empty() {
            argv.push_back("-m")
            argv.push_back(tc.emulation)
        }

        if tc.pass_sysroot {
            argv.push_back(f"--sysroot={tc.sysroot}")
        }

        if !want_stat && !o->hash_style.empty() {
            argv.push_back(f"--hash-style={o->hash_style}")
        }

        // An empty value (--build-id=) means "the default", not "no note": the
        // note is what debuggers and symbol servers key on, and dropping the
        // flag would silently turn it off only for people who wrote it.
        var bid = o->build_id
        if bid.empty() {
            bid = "fast"
        }

        argv.push_back(f"--build-id={bid}")
        if o->f_eh_frame_hdr != 0 {
            argv.push_back("--eh-frame-hdr")
        }

        if o->f_relro == 1 {
            argv.push_back("-z")
            argv.push_back("relro")
        }

        if o->f_relro == 0 {
            argv.push_back("-z")
            argv.push_back("norelro")
        }

        if o->now {
            argv.push_back("-z")
            argv.push_back("now")
        }

        if o->z_noexecstack {
            argv.push_back("-z")
            argv.push_back("noexecstack")
        }

        if shared {
            argv.push_back("-shared")
        } else if static_pie {
            argv.push_back("-static")
            argv.push_back("-pie")
            argv.push_back("--no-dynamic-linker")
            argv.push_back("-z")
            argv.push_back("text")
        } else if want_stat {
            argv.push_back("-static")
        } else if pie {
            argv.push_back("-pie")
        } else {
            argv.push_back("-no-pie")
        }

        if dyn_exe {
            if tc.dynamic_linker.empty() {
                msgs.push_back(
                    LinkDiag::make(
                        LinkSeverity::Error,
                        f"no known dynamic linker for {tc.triple}; pass --dynamic-linker",
                    ),
                )
            } else {
                argv.push_back("-dynamic-linker")
                argv.push_back(tc.dynamic_linker)
            }
        }

        argv.push_back("-o")
        argv.push_back(job.output)

        /// # crt startup
        var pic_crt = shared || pie || static_pie
        var begin_v = if (pic_crt) => ("S") else => (if (want_stat) => ("T") else => "")
        var end_v   = if (pic_crt) => ("S") else => ""

        if !no_crt {
            if tc.has_manifest && !tc.manifest.crt_startup.empty() {
                for var n: string in tc.manifest.crt_startup {
                    var is_start = n == "crt1.o" || n == "Scrt1.o" || n == "rcrt1.o"
                    if shared && is_start {
                        continue
                    }

                    var name = n
                    if is_start && static_pie {
                        name = "rcrt1.o"
                    } else if is_start && pie {
                        name = "Scrt1.o"
                    }

                    ELFArgs::_crt(&tc, name, &argv, &msgs)
                }
            } else {
                if !shared {
                    var c1 = if (static_pie) => ("rcrt1.o")
                             else => (if (pie) => ("Scrt1.o") else => "crt1.o")
                    ELFArgs::_crt(&tc, c1, &argv, &msgs)
                }

                ELFArgs::_crt(&tc, "crti.o", &argv, &msgs)
            }

            var cb = tc.crt_object("crtbegin", begin_v)
            if !cb.empty() {
                argv.push_back(cb)
            }
        }

        /// # search path, user's first
        for var d: string in o->lib_dirs {
            argv.push_back(f"-L{d}")
        }

        if !tc.toolchain_lib.empty() {
            argv.push_back(f"-L{tc.toolchain_lib}")
        }

        if !tc.gcc_dir.empty() {
            argv.push_back(f"-L{tc.gcc_dir}")
        }

        for var d: string in tc.lib_dirs {
            argv.push_back(f"-L{d}")
        }

        // The host's dirs last: a library the sysroot has (libc, libm) is
        // always the sysroot's, and only what it lacks is the host's.
        for var d: string in tc.host_lib_dirs {
            argv.push_back(f"-L{d}")
        }

        // A static image has no dynamic section to carry a DT_RUNPATH, and lld
        // would leave an unused one in a static PIE; say so instead of emitting
        // a flag that does nothing.
        if want_stat && !o->rpath.empty() {
            msgs.push_back(
                LinkDiag::make(
                    LinkSeverity::Warning,
                    "--rpath has no effect on a static link (there is no dynamic section); dropped",
                ),
            )
        }

        if !want_stat {
            for var r: string in o->rpath {
                argv.push_back("-rpath")
                argv.push_back(r)
            }
        }

        if !want_stat && !no_libs && !tc.toolchain_lib.empty() {
            argv.push_back("-rpath")
            argv.push_back(tc.toolchain_lib)
            msgs.push_back(
                LinkDiag::make(
                    LinkSeverity::Verbose,
                    f"added -rpath {tc.toolchain_lib}: libc++ is linked from outside the system library directories",
                ),
            )
        }

        for var r: string in o->rpath_link {
            argv.push_back("-rpath-link")
            argv.push_back(r)
        }

        /// # host libraries (the default build's glibc floor)
        if job.target->host_mode == "floor" && tc.libc == "glibc" && tc.has_manifest {
            job.glibc_floor = tc.manifest.glibc_version
            ELFArgs::_scan_host_libs(&job, &tc, want_stat, &msgs)
            // A host shared library was linked against the host's glibc, and
            // the floor's libc.so stubs lack its newer symbol versions; lld
            // would reject them. What that means for the program is said
            // after the link (Link::execute), from the library's VERNEED.
            if !job.host_shared.empty() {
                argv.push_back("--allow-shlib-undefined")
            }
        }

        /// # behavior
        if o->export_dynamic {
            argv.push_back("--export-dynamic")
        }

        if o->f_gc_sections == 1 {
            argv.push_back("--gc-sections")
        }

        if o->f_gc_sections == 0 {
            argv.push_back("--no-gc-sections")
        }

        if o->icf {
            if o->icf_mode != "safe" && o->icf_mode != "all" {
                msgs.push_back(
                    LinkDiag::make(
                        LinkSeverity::Error,
                        f"unknown --icf-mode {o->icf_mode}; expected safe or all",
                    ),
                )
            } else {
                argv.push_back(f"--icf={o->icf_mode}")
            }
        }

        if o->strip {
            argv.push_back("--strip-all")
        } else if o->strip_debug {
            argv.push_back("--strip-debug")
        }

        if !o->linker_script.empty() {
            argv.push_back("-T")
            argv.push_back(o->linker_script)
        }

        if !o->version_script.empty() {
            argv.push_back(f"--version-script={o->version_script}")
        }

        if !o->map_file.empty() {
            argv.push_back(f"--Map={o->map_file}")
        }

        if !o->compress_debug.empty() && o->compress_debug != "none" {
            argv.push_back(f"--compress-debug-sections={o->compress_debug}")
        }

        // With crt, main is called by crt1 and the ELF entry is _start. The
        // entry flag only names the ELF entry when there is no crt to do it.
        if no_crt && !shared && !o->no_entry && !o->entry.empty() {
            argv.push_back("-e")
            argv.push_back(o->entry)
        }

        for var f: string in o->ld_flags {
            argv.push_back(f)
        }

        /// # inputs
        for var obj: string in job.objects {
            argv.push_back(obj)
        }

        if job.lazy_objects.size() > 0 {
            argv.push_back("--start-lib")
            for var obj: string in job.lazy_objects {
                argv.push_back(obj)
            }

            argv.push_back("--end-lib")
        }

        for var spec: string in o->link_libs {
            ELFArgs::_user_lib(spec, want_stat, &argv, &msgs)
        }

        if !no_libs {
            ELFArgs::_default_libs(&tc, want_stat, &argv, &msgs)
        }

        /// # crt end
        if !no_crt {
            var ce = tc.crt_object("crtend", end_v)
            if !ce.empty() {
                argv.push_back(ce)
            }

            if tc.has_manifest && !tc.manifest.crt_end.empty() {
                for var n: string in tc.manifest.crt_end {
                    ELFArgs::_crt(&tc, n, &argv, &msgs)
                }
            } else {
                ELFArgs::_crt(&tc, "crtn.o", &argv, &msgs)
            }
        }

        return LinkDiag::error_count(&msgs) == errs0
    }

    /// The libraries this link takes from outside the sysroot: each -l
    /// resolved as lld will resolve it (the -L order above), and each shared
    /// object named as an input. Shared ones go into job.host_shared; a
    /// static archive from a host dir is warned about, since what it needs
    /// from glibc is invisible once it is linked in.
    priv static fn _scan_host_libs(@inout job:  LinkJob,
                                   @inout tc:   Toolchain,
                                   want_stat:   bool,
                                   @inout msgs: cxx::std::vector<LinkMessage>) {
        var *o   = job.opts
        var dirs = cxx::std::vector<string>()
        for var d: string in o->lib_dirs {
            dirs.push_back(d)
        }

        if !tc.toolchain_lib.empty() {
            dirs.push_back(tc.toolchain_lib)
        }

        if !tc.gcc_dir.empty() {
            dirs.push_back(tc.gcc_dir)
        }

        for var d: string in tc.lib_dirs {
            dirs.push_back(d)
        }

        for var d: string in tc.host_lib_dirs {
            dirs.push_back(d)
        }

        var found = cxx::std::vector<string>()
        for var spec: string in o->link_libs {
            var name = spec
            var stat = want_stat
            if LinkText::starts_with(spec, "static:") {
                name = LinkText::slice(spec, 7, spec.size())
                stat = true
            } else if LinkText::starts_with(spec, "dynamic:") {
                name = LinkText::slice(spec, 8, spec.size())
            }

            if name.empty() {
                continue
            }

            if LinkText::contains(name, "/")
                || LinkText::ends_with(name, ".a")
                || LinkText::ends_with(name, ".o")
                || LinkText::ends_with(name, ".so") {
                if LinkFS::is_file(name) {
                    found.push_back(name)
                }

                continue
            }

            var p = HostSystem::find_lib(name, &dirs, stat)
            if !p.empty() {
                found.push_back(p)
            }
        }

        for var obj: string in job.objects {
            if HostSystem::is_shared(obj) && LinkFS::is_file(obj) {
                found.push_back(obj)
            }
        }

        for var p: string in found {
            if HostSystem::under(p, tc.sysroot) {
                continue
            }

            if HostSystem::is_shared(p) {
                var dup = false
                for var h: string in job.host_shared {
                    if h == p {
                        dup = true
                    }
                }

                if !dup {
                    job.host_shared.push_back(p)
                }

                continue
            }

            if !LinkText::ends_with(p, ".a") {
                continue
            }

            var host_dir = false
            var pdir     = LinkFS::real(LinkFS::parent(p))
            for var d: string in tc.host_lib_dirs {
                if LinkFS::real(d) == pdir {
                    host_dir = true
                }
            }

            if !host_dir {
                continue
            }

            msgs.push_back(
                LinkDiag::make(
                    LinkSeverity::Warning,
                    f"{p} is a static archive from the host system: it was built against the host's glibc, and linking it can silently raise the glibc this program needs above the floor ({job.glibc_floor}); link its shared library instead, or build it against the floor",
                ),
            )
        }
    }

    priv static fn _crt(@inout tc:   Toolchain,
                        const name:  string,
                        @inout argv: cxx::std::vector<string>,
                        @inout msgs: cxx::std::vector<LinkMessage>) {
        var p = tc.find_lib_file(name)
        if p.empty() {
            var _where = if (!tc.crt_dir.empty()) => (tc.crt_dir) else => tc.sysroot
            msgs.push_back(
                LinkDiag::make(
                    LinkSeverity::Error,
                    f"cannot find startup object {name} (searched {_where} and the sysroot library directories)",
                ),
            )

            return
        }

        argv.push_back(p)
    }

    /// `-l foo`, `-l static:foo`, `-l dynamic:foo`, or a path to an archive,
    /// object or shared library, which goes in as an input.
    priv static fn _user_lib(const spec:  string,
                             want_stat:   bool,
                             @inout argv: cxx::std::vector<string>,
                             @inout msgs: cxx::std::vector<LinkMessage>) {
        var name = spec
        var mode = ""
        if LinkText::starts_with(spec, "static:") {
            mode = "static"
            name = LinkText::slice(spec, 7, spec.size())
        } else if LinkText::starts_with(spec, "dynamic:") {
            mode = "dynamic"
            name = LinkText::slice(spec, 8, spec.size())
        }

        if name.empty() {
            msgs.push_back(LinkDiag::make(LinkSeverity::Error, f"-l {spec}: no library name"))
            return
        }

        if LinkText::contains(name, "/")
            || LinkText::ends_with(name, ".a")
            || LinkText::ends_with(name, ".o")
            || LinkText::ends_with(name, ".so") {
            argv.push_back(name)
            return
        }

        if mode == "dynamic" && want_stat {
            msgs.push_back(
                LinkDiag::make(
                    LinkSeverity::Error,
                    f"-l dynamic:{name} cannot be satisfied by a static link",
                ),
            )

            return
        }

        if mode == "static" && !want_stat {
            argv.push_back("-Bstatic")
            argv.push_back(f"-l{name}")
            argv.push_back("-Bdynamic")
            return
        }

        argv.push_back(f"-l{name}")
    }

    /// libc++ (Kairo objects always need it), libm, the unwinder, the
    /// builtins, libc. Dynamic order matches clang on glibc/libgcc exactly:
    ///   -lc++ -lc++abi -lm -lgcc_s -lgcc -lc -lgcc_s -lgcc
    priv static fn _default_libs(@inout tc:   Toolchain,
                                 want_stat:   bool,
                                 @inout argv: cxx::std::vector<string>,
                                 @inout msgs: cxx::std::vector<LinkMessage>) {
        var cxx_v = cxx::std::vector<string>()
        var libc  = cxx::std::vector<string>()
        var libm  = false
        if tc.has_manifest {
            if !tc.manifest.has_libcxx {
                msgs.push_back(
                    LinkDiag::make(
                        LinkSeverity::Error,
                        f"the sysroot {tc.sysroot} has no libc++ (has_libcxx = false), and Kairo objects need it",
                    ),
                )
            }

            cxx_v = tc.manifest.libcxx_link
            libc  = tc.manifest.libc_link
        } else if !tc.native_bundle.empty() {
            // --native: the bundled libc++ by path, never by -L (that dir's
            // libc would win over the host's), and the host's libc.
            var nb = LinkText::join(tc.native_bundle, "lib")
            cxx_v.push_back(LinkText::join(nb, "libc++.a"))
            cxx_v.push_back(LinkText::join(nb, "libc++abi.a"))
            if tc.libc == "glibc" {
                libc.push_back("-lpthread")
            }

            libc.push_back("-lc")
            libm = true
        } else {
            cxx_v.push_back("-lc++")
            cxx_v.push_back("-lc++abi")
            libc.push_back("-lc")
            libm = true
        }

        var rt = cxx::std::vector<string>()
        if tc.rtlib == "compiler-rt" {
            if !tc.builtins.empty() {
                rt.push_back(tc.builtins)
            }
        } else {
            rt.push_back("-lgcc")
        }

        // A manifest's libcxx_link already names its unwinder.
        var uw = cxx::std::vector<string>()
        if !tc.has_manifest {
            var nb_uw = LinkText::join(LinkText::join(tc.native_bundle, "lib"), "libunwind.a")
            if tc.unwindlib == "libunwind" && !tc.native_bundle.empty() && LinkFS::is_file(nb_uw) {
                uw.push_back(nb_uw)
            } else if tc.unwindlib == "libunwind" {
                uw.push_back("-lunwind")
            } else if tc.unwindlib == "libgcc" {
                uw.push_back(if (want_stat) => ("-lgcc_eh") else => "-lgcc_s")
            }
        }

        if want_stat {
            argv.push_back("--start-group")
            ELFArgs::_append(&argv, &cxx_v)
            if libm {
                argv.push_back("-lm")
            }

            ELFArgs::_append(&argv, &uw)
            ELFArgs::_append(&argv, &rt)
            ELFArgs::_append(&argv, &libc)
            argv.push_back("--end-group")
            return
        }

        ELFArgs::_append(&argv, &cxx_v)
        if libm {
            argv.push_back("-lm")
        }

        ELFArgs::_append(&argv, &uw)
        ELFArgs::_append(&argv, &rt)
        ELFArgs::_append(&argv, &libc)
        ELFArgs::_append(&argv, &uw)
        ELFArgs::_append(&argv, &rt)
    }

    priv static fn _append(@inout argv: cxx::std::vector<string>,
                           @inout xs:   cxx::std::vector<string>) {
        for var x: string in xs {
            argv.push_back(x)
        }
    }
}
