/// --- The Kairo Project -------------------------- Linker/API/Link.k ----- ///
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
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import Linker::API::Text::*;
import Linker::API::FS::*;
import Linker::API::LinkDiag::*;
import Linker::API::LinkJob::*;
import Linker::API::Toolchain::*;
import Linker::API::Flavor::ELF::*;
import Linker::API::LLDRunner::*;

struct LinkResult {
    var ok:          bool = false;
    var ran:         bool = false;    ///< lld (or kld) actually ran
    var in_process:  bool = true;
    var ret:         i32  = 1;
    var argv:        vec::<string>;
    var messages:    vec::<LinkMessage>;
    var stdout_text: string;
}

class Link {
    static fn plan(job: ref!(LinkJob), tc: ref!(Toolchain),
                   argv: ref!(vec::<string>), msgs: ref!(vec::<LinkMessage>)) -> bool {
        if !tc.resolve(job.target, job.opts, msgs) { return false; }
        return ELFArgs::build(job, tc, argv, msgs);
    }

    static fn execute(job: ref!(LinkJob), argv: ref!(vec::<string>), res: ref!(LinkResult)) -> bool {
        res.argv = argv;

        var parent = LinkFS::parent(job.output);
        if (!parent.empty()) && (!LinkFS::make_dirs(parent)) {
            res.messages.push_back(LinkDiag::make(LinkSeverity::Error,
                f"cannot create the output directory {parent}"));
            return false;
        }

        var run = LLDRunner::run(argv, job.kld_path, job.out_of_process);
        if !run.spawn_error.empty() {
            res.messages.push_back(LinkDiag::make(LinkSeverity::Fatal, run.spawn_error));
            return false;
        }

        res.ran         = true;
        res.in_process  = run.in_process;
        res.ret         = run.ret;
        res.stdout_text = run.stdout_text;

        var errs0 = LinkDiag::error_count(res.messages);
        LinkDiag::parse(run.stderr_text, res.messages);

        if run.poisoned_now {
            res.messages.push_back(LinkDiag::make(LinkSeverity::Warning,
                "the in-process linker could not reset its state; later links in this process run kld out of process"));
        }
        if (run.ret != 0) && (LinkDiag::error_count(res.messages) == errs0) {
            res.messages.push_back(LinkDiag::make(LinkSeverity::Error,
                f"the linker exited with status {run.ret} without reporting an error"));
        }

        res.ok = (run.ret == 0) && (LinkDiag::error_count(res.messages) == errs0);
        return res.ok;
    }

    static fn link(job: ref!(LinkJob)) -> LinkResult {
        var res  = LinkResult{};
        var tc   = Toolchain();
        var argv = vec::<string>();
        if !Link::plan(job, tc, argv, res.messages) {
            res.argv = argv;
            return res;
        }
        Link::execute(job, argv, res);
        return res;
    }

    /// One shell-pasteable line.
    static fn render(argv: ref!(vec::<string>)) -> string {
        var s = "";
        for var i: usize = 0; i < argv.size(); ++i {
            if i > 0 { s += " "; }
            s += LinkText::quote_shell(argv[i]);
        }
        return s;
    }
}