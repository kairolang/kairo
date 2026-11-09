/// --- The Kairo Project ----------------------------------- API/Link.k --- ///
///
///   The linker API entry points: plan, execute and link.
///
///   \brief The linker API. Three calls:
///
///     plan(job, tc, argv, msgs)   resolve the toolchain, render argv. No lld.
///                                 --print-ld-args and --print-dirs stop here.
///     execute(job, argv, res)     run a planned argv, parse what lld said.
///     link(job)                   both.
///
///   Plan and execute are separate so the driver can echo the exact line
///   under -v BEFORE lld runs, which is the line you want when a link hangs.
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
import API::Flavor::COFF::COFFArgs
import API::Flavor::ELF::ELFArgs
import API::Flavor::MachO::MachOArgs
import API::Flavor::MinGW::MinGWArgs
import API::Flavor::Wasm::WasmArgs
import API::HostSystem::HostSystem
import API::LLDRunner::LLDRunner
import API::LinkABI::LinkABI
import API::LinkDiag::{
    LinkDiag,
    LinkMessage,
    LinkSeverity,
}
import API::LinkJob::LinkJob
import API::Text::LinkText
import API::Toolchain::Toolchain

pub struct LinkResult {
    pub var ok:          bool                          = false
    var     ran:         bool                          = false ///< lld (or kld) actually ran
    var     in_process:  bool                          = true
    var     ret:         i32                           = 1
    var     argv:        cxx::std::vector<string>
    pub var messages:    cxx::std::vector<LinkMessage>
    pub var stdout_text: string
}

pub class Link {
    pub static fn plan(@inout job:  LinkJob,
                       @inout tc:   Toolchain,
                       @inout argv: cxx::std::vector<string>,
                       @inout msgs: cxx::std::vector<LinkMessage>) -> bool {
        if !tc.resolve(job.target, job.opts, &msgs) {
            return false
        }

        if tc.format == "Mach-O" {
            return MachOArgs::build(&job, &tc, &argv, &msgs)
        }

        if tc.format == "COFF" {
            if tc.libc == "msvc" {
                return COFFArgs::build(&job, &tc, &argv, &msgs)
            }

            return MinGWArgs::build(&job, &tc, &argv, &msgs)
        }

        if tc.format == "Wasm" {
            return WasmArgs::build(&job, &tc, &argv, &msgs)
        }

        return ELFArgs::build(&job, &tc, &argv, &msgs)
    }

    pub static fn execute(@inout job:  LinkJob,
                          @inout argv: cxx::std::vector<string>,
                          @inout res:  LinkResult) -> bool {
        res.argv = argv

        var parent = LinkFS::parent(job.output)
        if !parent.empty() && !LinkFS::make_dirs(parent) {
            res.messages.push_back(
                LinkDiag::make(LinkSeverity::Error, f"cannot create the output directory {parent}"),
            )

            return false
        }

        // The objects' ABI notes, before lld spends a link on objects that
        // cannot be combined (LinkABI).
        var errs_abi = LinkDiag::error_count(&res.messages)
        LinkABI::check(&job, &res.messages)
        if LinkDiag::error_count(&res.messages) != errs_abi {
            return false
        }

        var run = LLDRunner::run(&argv, job.kld_path, job.out_of_process)
        if !run.spawn_error.empty() {
            res.messages.push_back(LinkDiag::make(LinkSeverity::Fatal, run.spawn_error))
            return false
        }

        res.ran         = true
        res.in_process  = run.in_process
        res.ret         = run.ret
        res.stdout_text = run.stdout_text

        var errs0 = LinkDiag::error_count(&res.messages)
        LinkDiag::parse(run.stderr_text, &res.messages)

        if run.poisoned_now {
            res.messages.push_back(
                LinkDiag::make(
                    LinkSeverity::Warning,
                    "the in-process linker could not reset its state; later links in this process run kld out of process",
                ),
            )
        }

        if run.ret != 0 && LinkDiag::error_count(&res.messages) == errs0 {
            res.messages.push_back(
                LinkDiag::make(
                    LinkSeverity::Error,
                    f"the linker exited with status {run.ret} without reporting an error",
                ),
            )
        }

        res.ok = run.ret == 0 && LinkDiag::error_count(&res.messages) == errs0
        if res.ok {
            Link::_check_glibc_floor(&job, &res.messages)
        }

        return res.ok
    }

    /// After a link against the glibc floor: each host shared library that
    /// needs a newer GLIBC_ symbol version than the floor raises the glibc
    /// the program needs to run, which is what the floor exists to pin. Said
    /// once per library, at its highest version; the link itself is fine.
    priv static fn _check_glibc_floor(@inout job:  LinkJob,
                                      @inout msgs: cxx::std::vector<LinkMessage>) {
        var floor = job.glibc_floor
        if floor.empty() {
            return
        }

        for var p: string in job.host_shared {
            var n = HostSystem::glibc_needs(p)
            if !n.ok || n.max_glibc.empty() {
                continue
            }

            if !Toolchain::version_less(floor, n.max_glibc) {
                continue
            }

            var v = n.max_glibc
            msgs.push_back(
                LinkDiag::make(
                    LinkSeverity::Warning,
                    f"'{n.soname}' needs GLIBC_{v}, so this program needs glibc {v} or newer to run (the floor is {floor})",
                ),
            )
        }
    }

    static fn link(@inout job: LinkJob) -> LinkResult {
        var res  = LinkResult{}
        var tc   = Toolchain()
        var argv = cxx::std::vector<string>()
        if !Link::plan(&job, &tc, &argv, &res.messages) {
            res.argv = argv
            return res
        }

        Link::execute(&job, &argv, &res)
        return res
    }

    /// One shell-pasteable line.
    pub static fn render(@inout argv: cxx::std::vector<string>) -> string {
        var s = ""
        for var i: usize = 0; i < argv.size(); ++i {
            if i > 0 {
                s += " "
            }

            s += LinkText::quote_shell(argv[i])
        }

        return s
    }
}
