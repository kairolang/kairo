/// --- The Kairo Project ---------------------- Linker/API/LinkDiag.k ----- ///
///
///   \brief What the linker API reports, and the parser that turns lld's
///          captured stderr into it.
///
///   The API never touches DiagEngine. Callers get LinkMessage records and
///   map them onto their own diagnostic codes; the compiler driver is the
///   only place L001* exists. That keeps this layer usable from kld and from
///   tooling that has no engine.
///
///   lld's format (lld/Common/ErrorHandler.cpp, reportDiagnostic):
///
///       <logName>: error: <first line>
///       >>> <continuation>           (referenced by, defined in, ...)
///
///   logName is argv[0]'s basename, so "ld.lld" in-process and "kld" out of
///   process. Parsing keys on the ": error: " / ": warning: " marker, never
///   on the program name. Colors are off (--color-diagnostics=never), so no
///   escape codes reach this.
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

enum LinkSeverity { Fatal, Error, Warning, Note, Remark, Info, Verbose, Debug }

struct LinkMessage {
    var severity: LinkSeverity = LinkSeverity::Note;
    var text:     string;       ///< may span lines: lld's ">>>" block stays attached
}

class LinkDiag {
    static fn make(sev: LinkSeverity, text: string) -> LinkMessage {
        var m = LinkMessage{};
        m.severity = sev;
        m.text     = text;
        return m;
    }

    /// Fatal + Error. Every "did this step fail" check compares this before
    /// and after, so a step never has to track its own failure flag.
    static fn error_count(msgs: ref!(vec::<LinkMessage>)) -> usize {
        var n: usize = 0;
        for m: LinkMessage in msgs {
            if (m.severity == LinkSeverity::Fatal) || (m.severity == LinkSeverity::Error) { n += 1; }
        }
        return n;
    }

    /// lld stderr -> messages, appended to \p out in order.
    static fn parse(text: string, out: ref!(vec::<LinkMessage>)) {
        var have = false;
        var cur  = LinkMessage{};
        for line: string in LinkText::split_lines(text) {
            if LinkText::trim(line).empty() { continue; }

            if LinkText::starts_with(line, ">>>") || LinkText::starts_with(line, " ") {
                if have {
                    cur.text += "\n";
                    cur.text += line;
                } else {
                    out.push_back(LinkDiag::make(LinkSeverity::Note, line));
                }
                continue;
            }

            if have { out.push_back(cur); }
            cur  = LinkDiag::_classify(line);
            have = true;
        }
        if have { out.push_back(cur); }
    }

    /// The earliest marker wins, so a warning whose text quotes ": error: "
    /// stays a warning.
    priv static fn _classify(line: string) -> LinkMessage {
        var n  = line.size();
        var pe = LinkText::find(line, ": error: ", 0);
        var pw = LinkText::find(line, ": warning: ", 0);
        var pn = LinkText::find(line, ": note: ", 0);

        if (pe < n) && (pe <= pw) && (pe <= pn) {
            return LinkDiag::make(LinkSeverity::Error, LinkText::slice(line, pe + 9, n));
        }
        if (pw < n) && (pw <= pn) {
            return LinkDiag::make(LinkSeverity::Warning, LinkText::slice(line, pw + 11, n));
        }
        if pn < n {
            return LinkDiag::make(LinkSeverity::Note, LinkText::slice(line, pn + 8, n));
        }

        // The dispatcher's own errors (bad -flavor) carry no program prefix.
        if LinkText::starts_with(line, "error: ") {
            return LinkDiag::make(LinkSeverity::Error, LinkText::slice(line, 7, n));
        }
        if LinkText::starts_with(line, "warning: ") {
            return LinkDiag::make(LinkSeverity::Warning, LinkText::slice(line, 9, n));
        }
        return LinkDiag::make(LinkSeverity::Note, line);
    }
}