/// --- The Kairo Project ----------- Codegen/Backend/SemaAgreeReport.k --- ///
///
///   \brief One finding of the Sema agreement pass in the form it is
///          reported, and that form as text, so the incremental cache can
///          keep a TU's findings beside its object and say them again
///          (Compiler/Spec/SemaAgreement.md).
///
///   A finding is the parts of its diagnostic: where, the message, the
///   label and the notes. The walk's run builds them once
///   (KairoInject::agree_report); the run that reuses the TU's object reads
///   them back and reports the same text at the same places.
///
///   The text names a file by its content, never by a FileID or a clang
///   location, which are one run's: size, hash and path. Reading it back
///   finds the file of this run with that content, the one at the same
///   path when several have it, so a checkout that moved still resolves,
///   and a file whose bytes changed does not: the offsets were its old
///   bytes'. Then the findings are not read at all, and the TU compiles.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "Native/ObjCache.hh"
ffi "c++" import "Native/Types.hh"
ffi "c++" import "vector"

import AST::Context::ASTContext::ASTContext
import Diagnostic::Code::DiagCode
import Diagnostic::Registry::DiagID
import Location::SourceLocation::SourceLocation
import Location::SourceManager::{
    FileID,
    SourceManager,
}
import Location::SourceRange::SourceRange
import Support::Ascii::{
    parse_decimal,
    split,
}

/// A note under a finding. \p labelled: the note underlines \p at;
/// otherwise it only points at its start.
pub struct AgreeNote {
    pub var at:       SourceRange
    pub var labelled: bool        = false
    pub var text:     string
}

/// One disagreement, as I012W says it.
pub struct AgreeFinding {
    /// Which check found it: `callee`.
    pub var kind:  string                      = "callee"
    pub var at:    SourceRange
    pub var msg:   string
    pub var label: string
    pub var notes: cxx::std::vector<AgreeNote>
}

/// The first line of a TU's findings as text.
pub fn agree_text_magic() -> string {
    return "kairo-agree-findings 1"
}

/// Reports \p f into \p ctx's sink.
pub fn agree_emit(ctx: unsafe *ASTContext, const f: AgreeFinding) {
    var b = ctx->diag_sink.report(
        DiagCode(DiagID::I012W),
        f.at.start,
        f.msg.copy(),
    )

    b.first(f.at, f.label)
    for var i: usize = 0; i < f.notes.size(); ++i {
        var n = f.notes[i]
        if n.labelled {
            b.note(n.at.start, n.text)->child_first(n.at)
        } else {
            b.note(n.at.start, n.text)
        }
    }

    b.emit()
}

/// \p s on one line: a line break in it would end its record.
fn _one_line(const s: string) -> string {
    var clean = true
    for var i: usize = 0; i < s.size(); ++i {
        if s[i] == ('\n' as u8) || s[i] == ('\r' as u8) {
            clean = false
            break
        }
    }

    if clean {
        return s.copy()
    }

    var out = ""
    for var i: usize = 0; i < s.size(); ++i {
        if s[i] == ('\n' as u8) || s[i] == ('\r' as u8) {
            out += " "
        } else {
            out += s.subslice(i, 1)
        }
    }

    return out
}

fn _base_name(const path: string) -> string {
    var at = path.size()
    while at > 0 && path[at - 1] != ('/' as u8) && path[at - 1] != ('\\' as u8) {
        at -= 1
    }

    return path.subslice(at, path.size() - at)
}

/// The content hash of \p fid's bytes, "" when they are not at hand.
fn _file_hash(sm: unsafe *SourceManager, fid: FileID) -> string {
    var buf? = sm->get_buffer(fid)
    if buf == null || !buf.is_valid() {
        return ""
    }

    return kairo::std::from_std_string<string>(
        kairo::objcache_hash128_bytes(buf.data(), buf.size()),
    )
}

/// \class AgreeFiles
/// \brief The files a TU's findings point into, each once, in the order
///        the text lists them.
class AgreeFiles {
    pub var fids:  cxx::std::vector<FileID>
    pub var lines: string                   = ""
    pub var ok:    bool                     = true

    /// " <file> <offset> <length>" for \p r, the file by its index here;
    /// `-` for the file of an invalid range.
    fn place(self, sm: unsafe *SourceManager, r: SourceRange) -> string {
        if !r.is_valid() {
            return " - 0 0"
        }

        var fid        = sm->get_fid(r.start)
        var idx: usize = self.fids.size()
        for var i: usize = 0; i < self.fids.size(); ++i {
            if self.fids[i] == fid {
                idx = i
                break
            }
        }

        if idx == self.fids.size() {
            var h = _file_hash(sm, fid)
            if h.empty() {
                self.ok = false
            }

            self.fids.push_back(fid)
            self.lines += f"file {sm->get_file_size(fid)} {h} {_one_line(sm->get_filename(fid))}\n"
        }

        return f" {idx} {sm->get_offset(r.start)} {r.size()}"
    }
}

/// \brief \p found as text for the object stored under \p key, or "" when
///        a file one of them points into has no bytes at hand to identify
///        it by.
pub fn agree_encode(sm:          unsafe *SourceManager,
                    const key:   string,
                    const found: cxx::std::vector<AgreeFinding>) -> string {
    var files = AgreeFiles()
    var body  = ""
    for var i: usize = 0; i < found.size(); ++i {
        var f = found[i]
        body += "finding " + _one_line(f.kind) + files.place(sm, f.at) + "\n"
        body += "msg " + _one_line(f.msg) + "\n"
        body += "label " + _one_line(f.label) + "\n"
        for var k: usize = 0; k < f.notes.size(); ++k {
            var n    = f.notes[k]
            var flag = if (n.labelled) => ("1") else => "0"
            body += "note" + files.place(sm, n.at) + " " + flag + " " + _one_line(
                n.text,
            ) + "\n"
        }
    }

    if !files.ok {
        return ""
    }

    return agree_text_magic() + "\nO " + key + "\n" + files.lines + body + "end\n"
}

/// Whether \p text is the whole findings text of the object stored under
/// \p key.
pub fn agree_text_whole(const text: string, const key: string) -> bool {
    return text.starts_with(agree_text_magic() + "\nO " + key + "\n") && text.ends_with("\nend\n")
}

/// The next word of \p line from \p at, which moves past it and the space
/// after it.
fn _word(const line: string, @inout at: usize) -> string {
    var start = at
    while at < line.size() && line[at] != (' ' as u8) {
        at += 1
    }

    var w = line.subslice(start, at - start)
    if at < line.size() {
        at += 1
    }

    return w
}

fn _rest(const line: string, at: usize) -> string {
    if at >= line.size() {
        return ""
    }

    return line.subslice(at, line.size() - at)
}

/// The file of this run that has \p size bytes hashing to \p hash and is
/// named as \p path's last component: the one at \p path when several do.
/// u32::MAX when none does.
fn _find_file(sm:         unsafe *SourceManager,
              size:       usize,
              const hash: string,
              const path: string) -> FileID {
    var base         = _base_name(path)
    var best: FileID = u32::MAX as FileID
    var n            = sm->file_count()
    for var i: usize = 0; i < n; ++i {
        var fid = i as FileID
        if sm->get_file_size(fid) != size {
            continue
        }

        var name = sm->get_filename(fid)
        if _base_name(name) != base || _file_hash(sm, fid) != hash {
            continue
        }

        if name == path {
            return fid
        }

        if best == (u32::MAX as FileID) {
            best = fid
        }
    }

    return best
}

/// The range " <file> <offset> <length>" names, read from \p line at
/// \p at. False when it names a file \p fids does not hold.
fn _read_place(sm:         unsafe *SourceManager,
               const fids: cxx::std::vector<FileID>,
               const line: string,
               @inout at:  usize,
               @inout out: SourceRange) -> bool {
    var file = _word(line, &at)
    var off  = parse_decimal(_word(line, &at)) as usize
    var len  = parse_decimal(_word(line, &at)) as usize
    if file == "-" {
        out = SourceRange::invalid()
        return true
    }

    var idx = parse_decimal(file) as usize
    if idx >= fids.size() || off + len > sm->get_file_size(fids[idx]) {
        return false
    }

    out = sm->get_range(fids[idx], off, len)
    return true
}

/// \brief the findings \p text holds (agree_encode's, whole for its key),
///        placed in this run's files. False, with \p out to be ignored,
///        when a file one of them points into is not among this run's with
///        the bytes it had: the text describes another source.
pub fn agree_decode(sm:         unsafe *SourceManager,
                    const text: string,
                    @inout out: cxx::std::vector<AgreeFinding>) -> bool {
    var fids  = cxx::std::vector<FileID>()
    var lines = split(text, '\n' as u8, false)
    var open  = false
    var cur   = AgreeFinding{}
    for var li: usize = 0; li < lines.size(); ++li {
        var line       = lines[li].copy()
        var at:  usize = 0
        var tag        = _word(line, &at)
        if tag == "file" {
            var size = parse_decimal(_word(line, &at)) as usize
            var hash = _word(line, &at)
            var fid  = _find_file(sm, size, hash, _rest(line, at))
            if fid == (u32::MAX as FileID) {
                return false
            }

            fids.push_back(fid)
        } else if tag == "finding" {
            if open {
                out.push_back(cur)
            }

            cur      = AgreeFinding{}
            open     = true
            cur.kind = _word(line, &at)
            if !_read_place(sm, fids, line, &at, &cur.at) {
                return false
            }
        } else if tag == "msg" && open {
            cur.msg = _rest(line, at)
        } else if tag == "label" && open {
            cur.label = _rest(line, at)
        } else if tag == "note" && open {
            var n = AgreeNote{}
            if !_read_place(sm, fids, line, &at, &n.at) {
                return false
            }

            n.labelled = _word(line, &at) == "1"
            n.text     = _rest(line, at)
            cur.notes.push_back(n)
        }
    }

    if open {
        out.push_back(cur)
    }

    return true
}
