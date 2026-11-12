/// --- The Kairo Project --------------- Extras/Formatter/Driver/kfmt.k --- ///
///
///   kfmt: the Kairo formatter's driver. Format.k prints; this file decides
///   whether what it printed may replace the file.
///
///   Nothing is written (and `--check` reports the file as refused) unless
///   the output passes every check of README 1.1-1.5 and 16.3-16.4:
///
///     1. it parses, with no syntax error (1.1);
///     2. it re-lexes to the same code tokens, modulo what the rules may
///        change: `;` (13.1), a `,` before a closer (4.2), the order and
///        brace form of imports, compared as a multiset (5.1-5.4), and,
///        under `--normalize-parens`, parentheses (9.5);
///     3. it has the same comments in the same order (1.3), a comment that
///        travels with its import (5.4) compared with that import;
///     4. it parses to the same tree: every top-level item dumped by the
///        compiler's own AST printer, compared line for line (1.2, 16.3).
///        This is the check that catches a line break that changes parsing
///        (4.5) or a paren removal that changes the operator tree (9.5);
///     5. formatting it again changes nothing (1.4).
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "Native/GlobalRecycler.hh"
ffi "c++" import "Native/KLocale.hh" // init_process_locale
ffi "c++" import "Native/KLog.hh"
ffi "c++" import "Native/Types.hh"
ffi "c++" import "cstdlib"
ffi "c++" import "cstring"
ffi "c++" import "filesystem"
ffi "c++" import "llvm/Support/InitLLVM.h"
ffi "c++" import "llvm/Support/TargetSelect.h"
ffi "c++" import "llvm/Support/raw_ostream.h"
ffi "c++" import "locale"
ffi "c++" import "sstream"
ffi "c++" import "vector"

import AST::Context::ASTContext::*
import AST::Context::TranslationUnit::*
import AST::Node::Base::*
import AST::Node::Program::*
import AST::Printer::PrintCore::*
import AST::Printer::Printers::*
import Diagnostic::Consumer::*
import Diagnostic::Severity::*
import DocIR::*
import Driver::CompilerGraph
import Driver::CompilerInstance::*
import Driver::TUStage::*
import Format::*
import Options::*
import Renderer::*
import Resolution::ModulePath::*
import Support::FileIO::Path::*
import Token::TokenKind::*
import Tooling::ParseAPI::*
import Tooling::ToolDiagnostics::*
import std::c_char
import std::env
import std::io

pub enum FmtMode derives u8 {
    Check,  ///< list files that would change; exit 1 if any
    Write,  ///< rewrite them in place
    Stdout, ///< print the formatted file
}

/// One file through the preprocessor and parser alone.
pub struct Parsed {
    var fid:   u32                        = u32::MAX
    var ctx:   unsafe *ASTContext         = &null
    var tu:    unsafe *TranslationUnit    = &null
    var diags: cxx::std::vector<ToolDiag>
}

fn std_to_string(s: cxx::std::string) -> string {
    return string(
        unsafe ((s.data() as unsafe *const u8) as *const u8),
        s.size(),
    )
}

fn diag_line(d: ToolDiag) -> string {
    var head: string = ""
    if d.has_loc {
        head = f"{d.file}:{d.line}:{d.column}: "
    }

    if d.code.empty() {
        return f"{head}{d.message}"
    }

    return f"{head}{d.code}: {d.message}"
}

fn is_error(d: ToolDiag) -> bool {
    return d.severity == DiagSeverity::Error || d.severity == DiagSeverity::Fatal
}

/// \p fid through the preprocessor and parser alone: no dependency scan, no
/// import graph. Imports stay unresolved, which formatting never needs, and a
/// module whose files import each other (builtin) formats file by file.
fn parse_fid(ci: unsafe *CompilerInstance, fid: u32) -> Parsed {
    var u = Parsed{}
    u.fid = fid

    var unsafe *collector = kairo::std::create<ToolDiagConsumer>(ci->sm())
    var        saved      = ci->diag()->take_consumers()
    ci->diag()->add_consumer(collector)
    finally {
        ci->diag()->restore_consumers(saved)
        kairo::std::destroy(collector)
    }

    if ci->pp()->preprocess_one(fid, ModulePath()) {
        u.ctx = ci->global_scope()->get_context(fid)
        if u.ctx != &null {
            ci->parse_one(fid)
            u.ctx->diag_sink.drain_into(ci->diag(), u.ctx->sm)
            u.tu = unsafe (u.ctx->tu as unsafe *TranslationUnit)
        }
    }

    u.diags = collector->diags
    return u
}

/// Syntax errors (and fatals) in \p u, printed to stderr when \p show; 0
/// when clean. An import that does not resolve from here says nothing
/// about the text.
fn syntax_errors(u: Parsed, show: bool) -> u32 {
    var bad: u32 = 0
    for var i: usize = 0; i < u.diags.size(); ++i {
        var d = u.diags[i]
        if !is_error(d) {
            continue
        }

        if d.severity == DiagSeverity::Fatal || d.code.size() > 0 && d.code[0] == ('S' as u8) {
            if show {
                io::eprintln(f"  {diag_line(d)}")
            }

            bad += 1
        }
    }

    return bad
}

/// The tree of \p u as the compiler's printer dumps it (no source
/// locations), comment annotations dropped: rule 12.4 may move a comment to
/// another line, which can change the node it annotates without changing
/// the code. Comments are compared on their own (check 3).
fn tree_dump(u: Parsed) -> string {
    var opts = PrintOptions{}
    opts.style = PrintStyle::Debug
    opts.color = false

    var        out:  string = ""
    var unsafe *prog        = u.tu->program
    for var i: usize = 0; i < prog->items.size(); ++i {
        var unsafe *item = prog->items.get(i)
        if item == &null {
            continue
        }

        var s: string = ""
        match item->get_kind() {
            case TopLevelKind::Decl {
                s = DeclPrinter::print(item->as_decl(), u.ctx, opts)
            } case TopLevelKind::Stmt {
                s = StmtPrinter::print(item->as_stmt(), u.ctx, opts)
            } case TopLevelKind::Expr {
                s = ExprPrinter::print(item->as_expr(), u.ctx, opts)
            }
        }

        out += s
        out += "\n"
    }

    // drop the comment-annotation rows
    var kept: string = ""
    var a:    usize  = 0
    while a < out.size() {
        var b = a
        while b < out.size() && out[b] != ('\n' as u8) {
            b += 1
        }

        var row = out.subslice(a, b - a)
        var drop = find_str(row, "doc-comment") < row.size()
            || find_str(row, "line-comment") < row.size()
            || find_str(row, "block-comment") < row.size()
            || find_str(row, "<annotation>") < row.size()
        if !drop {
            kept += row
            kept += "\n"
        }

        a = b + 1
    }

    return kept
}

/// What checks 2 and 3 compare, read from one lexed file.
pub struct Sig {
    var code: cxx::std::vector<string> ///< code tokens, in order
    var cmts: cxx::std::vector<string> ///< comments not travelling with an import, in order
    var imps: cxx::std::vector<string> ///< Kairo imports + their comments, sorted (a multiset)
    var ffis: cxx::std::vector<string> ///< ffi imports + their comments, in order
}

/// Comment tokens that travel with import \p im (5.4): the own-line ones
/// directly above it, and one trailing its last line. Marked in \p used.
fn import_comments(f: *Formatter, im: ImportInfo, used: unsafe *cxx::std::vector<u8>) -> string {
    var s: string = ""
    // above: walk back over whitespace / newlines; a comment ending on the
    // line just above, which starts its own line, is part of the import
    var i    = f->_lb(im.start)
    var line = f->_line(im.start)
    while i > 0 {
        var j = i
        while j > 0 {
            var k = f->toks[j - 1].kind
            if k != TokenKind::TkWhitespace && k != TokenKind::TkNewLine {
                break
            }

            j -= 1
        }

        if j == 0 || f->toks[j - 1].kind != TokenKind::AtComment {
            break
        }

        var c = f->toks[j - 1]
        if f->_line(c.end - 1) + 1 != line {
            break
        }

        // own line: nothing but whitespace before it on its line
        var p   = j - 1
        var own = true
        while p > 0 {
            var k = f->toks[p - 1].kind
            if k == TokenKind::TkWhitespace {
                p -= 1
                continue
            }

            own = k == TokenKind::TkNewLine
            break
        }

        if !own {
            break
        }

        s              = f->_trimmed(c.start, c.end) + "\n" + s
        (*used)[j - 1] = 1
        line           = f->_line(c.start)
        i              = j - 1
    }

    // trailing
    var t = f->_lb(im.end)
    while t < f->toks.size() && f->toks[t].kind == TokenKind::TkWhitespace {
        t += 1
    }

    if t < f->toks.size()
        && f->toks[t].kind == TokenKind::AtComment
        && f->_line(f->toks[t].start) == f->_line(im.end - 1) {
        s += "|" + f->_trimmed(f->toks[t].start, f->toks[t].end)
        (*used)[t] = 1
    }

    return s
}

/// Kairo import \p im as a set of `path::item` names, in a canonical order:
/// `import a::{x, y}`, `import a::{y, x}` and, for one name, the 5.1 forms
/// all read the same.
fn import_names(im: ImportInfo) -> string {
    var s: string = im.vis + "|" + im.anchor + "|"
    var xs        = cxx::std::vector<string>()
    if im.braced {
        for var i: usize = 0; i < im.items.size(); ++i {
            xs.push_back(im.path + "::" + im.items[i])
        }
    } else if im.star {
        xs.push_back(im.path + "::*")
    } else if im.alias.size() > 0 {
        xs.push_back(im.path + " as " + im.alias)
    } else {
        xs.push_back(im.path)
    }

    sort_strings(unsafe &xs)
    for var i: usize = 0; i < xs.size(); ++i {
        s += xs[i] + ","
    }

    return s
}

fn signature(f: *Formatter, set: Settings) -> Sig {
    var g = Sig{}
    var n = f->toks.size()
    // u8, not bool: a vector of bool hands out proxies, not bools
    var used   = cxx::std::vector<u8>()
    var in_imp = cxx::std::vector<u8>()
    for var i: usize = 0; i < n; ++i {
        used.push_back(0)
        in_imp.push_back(0)
    }

    for var x: usize = 0; x < f->imps.size(); ++x {
        var im = f->imps[x]
        // not understood: not restyled or moved, so compared as code
        if im.raw {
            continue
        }

        for var i = f->_lb(im.start); i < n && f->toks[i].start < im.end; ++i {
            in_imp[i] = 1
        }

        var cm = import_comments(f, im, unsafe &used)
        if im.is_ffi {
            var t: string = ""
            for var i = f->_lb(im.start); i < n && f->toks[i].start < im.core; ++i {
                if Formatter::trivia(f->toks[i].kind) {
                    continue
                }

                t += f->tok_text(i) + " "
            }

            g.ffis.push_back(t + "#" + cm)
        } else {
            g.imps.push_back(import_names(im) + "#" + cm)
        }
    }

    sort_strings(unsafe &g.imps)

    var have      = false
    var prev: u32 = 0
    for var i: usize = 0; i < n; ++i {
        var t = f->toks[i]
        if have && in_imp[i] == 0 {
            // non-blank text the lexer left between two tokens (a chained
            // string segment) is code too
            var gtxt = f->_trimmed(prev, t.start)
            if gtxt.size() > 0 {
                g.code.push_back("\x01" + squeeze(gtxt))
            }
        }

        prev = t.end
        have = true

        if t.kind == TokenKind::TkNewLine || t.kind == TokenKind::TkWhitespace {
            continue
        }

        if t.kind == TokenKind::AtComment {
            if used[i] == 0 {
                g.cmts.push_back(f->_trimmed(t.start, t.end))
            }

            continue
        }

        if in_imp[i] != 0 {
            continue
        }

        if t.kind == TokenKind::OpSemicolon {
            continue
        }

        if t.kind == TokenKind::OpComma {
            // a trailing comma: the next code token closes the list
            var k = f->_kind_at(f->_sig_after(t.end))
            if k == TokenKind::OpRParen || k == TokenKind::OpRSquare || k == TokenKind::OpRBrace {
                continue
            }
        }

        if set.normalize_parens
            && (t.kind == TokenKind::OpLParen || t.kind == TokenKind::OpRParen) {
            continue
        }

        g.code.push_back(f->tok_text(i))
    }

    return g
}

/// \p s with each run of whitespace outside double quotes made one space:
/// the pieces of a chained string (`"a "\n    "b"`) are re-indented with
/// their statement, and only their text is the code.
fn squeeze(s: string) -> string {
    var out: string = ""
    var q           = false
    var sp          = false
    var i:   usize  = 0
    while i < s.size() {
        var c = s[i]
        if q {
            out.push_back(c)
            if c == ('\\' as u8) && i + 1 < s.size() {
                out.push_back(s[i + 1])
                i += 2
                continue
            }

            if c == ('"' as u8) {
                q = false
            }

            i += 1
            continue
        }

        if c == (' ' as u8) || c == ('\t' as u8) || c == ('\n' as u8) || c == ('\r' as u8) {
            sp = true
            i += 1
            continue
        }

        if sp && out.size() > 0 {
            out.push_back(' ' as u8)
        }

        sp = false
        out.push_back(c)
        if c == ('"' as u8) {
            q = true
        }

        i += 1
    }

    return out
}

fn same_list(a:    cxx::std::vector<string>,
             b:    cxx::std::vector<string>,
             what: string,
             why:  unsafe *string) -> bool {
    var n = if a.size() < b.size() => a.size() else => b.size()
    for var i: usize = 0; i < n; ++i {
        if a[i] != b[i] {
            // the entries before it: `f` became `f` alone does not say where
            var ctx: string = ""
            var k           = if i > 4 => i - 4 else => 0
            while k < i {
                ctx += a[k] + " "
                k += 1
            }

            *why = f"{what} differ at #{i} (after `{ctx}`): `{a[i]}` became `{b[i]}`"
            return false
        }
    }

    if a.size() != b.size() {
        *why = f"{what}: {a.size()} became {b.size()}"
        return false
    }

    return true
}

/// The first differing line of two dumps, for the refusal message.
fn first_diff(a: string, b: string) -> string {
    var i:    usize = 0
    var line: usize = 1
    var ls:   usize = 0
    while i < a.size() && i < b.size() && a[i] == b[i] {
        if a[i] == ('\n' as u8) {
            line += 1
            ls = i + 1
        }

        i += 1
    }

    var e = ls
    while e < a.size() && a[e] != ('\n' as u8) {
        e += 1
    }

    return f"dump line {line}: `{a.subslice(ls, e - ls)}`"
}

/// Checks 1-5 on \p out, the formatting of a file whose signature and tree
/// dump are \p a and \p ta (taken before the file was released: the output
/// is parsed in the same instance, and a file that declares a `module` would
/// otherwise meet its own macros twice). \p why gets the first failure.
fn verify(ci:       unsafe *CompilerInstance,
          name:     string,
          a:        Sig,
          ta:       string,
          file_dir: string,
          roots:    cxx::std::vector<string>,
          out:      string,
          set:      Settings,
          buf:      unsafe *cxx::std::string,
          why:      unsafe *string) -> bool {
    // the source manager keeps the pointer, not the bytes: \p buf belongs
    // to the caller and outlives the virtual file
    *buf = kairo::std::to_std_string(out)
    var vfid = ci->sm()->load_virtual(
        Path(name + ".kfmt-check.k", false),
        unsafe (buf->data() as kairo::std::ConstPtr<u8>),
        buf->size(),
    )

    if vfid == u32::MAX {
        *why = "the output could not be loaded"
        return false
    }

    // 1. it parses
    var v = parse_fid(ci, vfid)
    if syntax_errors(v, false) > 0 || v.tu == &null || v.tu->program == &null {
        syntax_errors(v, true)
        *why = "the output does not parse"
        return false
    }

    var f2 = Formatter(v.ctx, ci, vfid, set)
    f2.file_dir = file_dir
    f2.roots    = roots
    if !f2.prepare() {
        *why = "the output does not lex"
        return false
    }

    // 2, 3. the same code, comments and imports
    var b = signature(&f2, set)
    if !same_list(a.code, b.code, "code tokens", why) {
        return false
    }

    if !same_list(a.cmts, b.cmts, "comments", why) {
        return false
    }

    if !same_list(a.imps, b.imps, "imports", why) {
        return false
    }

    if !same_list(a.ffis, b.ffis, "ffi imports", why) {
        return false
    }

    // 4. the same tree
    var tb = tree_dump(v)
    if ta != tb {
        *why = f"the tree changed ({first_diff(ta, tb)})"
        return false
    }

    // 5. idempotent
    var again = f2.run(v.tu->program)
    if again != out {
        *why = "not idempotent: formatting the output changes it again"
        var unsafe *dir = cxx::std::getenv(r"KFMT_REFUSED_DIR")
        if dir != &null {
            var d = string(
                unsafe ((dir as unsafe *const u8) as *const u8),
                cxx::std::strlen(dir),
            )

            Path::write_file(
                Path::join_str(d, Path::filename_of(name) + ".kfmt-again"),
                again,
            )
        }

        return false
    }

    return true
}

/// 0 unchanged, 1 changed (reformatted, or would be), 2 refused or failed.
fn format_one_file(ci:    unsafe *CompilerInstance,
                   name:  string,
                   mode:  FmtMode,
                   set:   Settings,
                   roots: cxx::std::vector<string>) -> i32 {
    // the checked output's bytes: declared before the release below so they
    // outlive the virtual file that points at them
    var buf = cxx::std::string()
    finally {
        // Per-file release: nothing is held across files.
        release_all(ci, TUStage::Lexing)
        ci->diag()->clear_retained()
    }

    var fid = load(ci, Path(name))
    if fid == u32::MAX {
        io::eprintln(f"kfmt: {name}: cannot read")
        return 2
    }

    var u = parse_fid(ci, fid)
    if syntax_errors(u, true) > 0 {
        io::eprintln(f"kfmt: {name}: syntax errors, not formatting")
        return 2
    }

    if u.tu == &null || u.tu->program == &null {
        io::eprintln(f"kfmt: {name}: no translation unit")
        return 2
    }

    var fmt = Formatter(u.ctx, ci, fid, set)
    fmt.file_dir = Path::parent_of(Path::absolute_if_exists(name))
    fmt.roots    = roots
    if !fmt.prepare() {
        io::eprintln(f"kfmt: {name}: could not lex")
        return 2
    }

    var out  = fmt.run(u.tu->program)
    var orig = fmt.source()

    if out == orig {
        if mode == FmtMode::Stdout {
            io::print(out)
        }

        return 0
    }

    var sig = signature(&fmt, set)
    var ta  = tree_dump(u)
    release_all(ci, TUStage::Lexing)

    var why: string = ""
    if !verify(
        ci,
        name,
        sig,
        ta,
        fmt.file_dir,
        roots,
        out,
        set,
        unsafe &buf,
        unsafe &why,
    ) {
        io::eprintln(f"kfmt: {name}: refused, {why}; left unchanged")
        // A developer aid, not a knob: $KFMT_REFUSED_DIR gets the refused
        // output, so a kfmt bug can be read off a diff. Its own suffix, so
        // pointing the variable at a source directory overwrites nothing.
        var unsafe *dir = cxx::std::getenv(r"KFMT_REFUSED_DIR")
        if dir != &null {
            var d = string(
                unsafe ((dir as unsafe *const u8) as *const u8),
                cxx::std::strlen(dir),
            )

            Path::write_file(
                Path::join_str(d, Path::filename_of(name) + ".kfmt-refused"),
                out,
            )
        }

        return 2
    }

    match mode {
        case FmtMode::Stdout {
            io::print(out)
        } case FmtMode::Check {
            io::println(name)
        } case FmtMode::Write {
            if !Path::write_file(name, out) {
                io::eprintln(f"kfmt: {name}: cannot write")
                return 2
            }
        }
    }

    return 1
}

/// \return the InitLLVM guard; main destroys it before returning.
///
/// \details Kairo.k's init_runtime: see there for why the guard is returned
///          rather than kept in a static.
fn init_runtime(argc: i32, argv: unsafe *(unsafe *c_char)) -> unsafe *llvm::InitLLVM {
    var unsafe *init_llvm = kairo::std::create<llvm::InitLLVM>(argc, argv)
    llvm::InitializeAllTargetInfos()
    llvm::InitializeAllTargets()
    llvm::InitializeAllTargetMCs()
    llvm::InitializeAllAsmParsers()
    llvm::InitializeAllAsmPrinters()

    llvm::setBugReportMsg(
        "PLEASE submit a bug report to https://github.com/kairolang/kairo/issues and include the crash backtrace.\n",
    )

    kairo::init_process_locale()

    cxx::std::use_facet<cxx::std::num_put<c_char>>(cxx::std::locale())
    cxx::std::use_facet<cxx::std::num_get<c_char>>(cxx::std::locale())

    { // Force narrow char locale facets used by stringstream/to_string
        var oss: cxx::std::ostringstream
        // i32 and f32, as in Compiler/Driver/Runtime.k: where double and long double are
        // both 64-bit (aarch64 Windows, arm64 Darwin), and size_t and uint64_t are distinct,
        // ffi maps each pair to one Kairo type, so usize and f64 each match two operator<<
        // (SC064E). The facets are the same either way.
        oss << (1 as i32) << (1.0 as f32)
        oss.str()
    }

    return init_llvm
}

fn usage() {
    io::eprintln(
        "Usage: kfmt [--check | --write | --stdout] [--no-align] [--indent=spaces|tabs] [--tab-size=N]",
    )

    io::eprintln(
        "            [--normalize-parens] [--call-width=N] <file.k | dir>... [kairo flags ...]",
    )
}

/// The value of `--name=value` in \p arg, or "" when \p arg is not that flag.
fn flag_value(arg: string, name: string) -> string {
    var p = name + "="
    if arg.size() <= p.size() || !arg.starts_with(p) {
        return ""
    }

    return arg.subslice(p.size(), arg.size() - p.size())
}

pub fn main(argc: i32, argv: unsafe *(unsafe *c_char)) -> i32 {
    if argc < 2 {
        usage()
        return 1
    }

    kairo::Logger::init(kairo::Logger::Level::Warn)
    var unsafe *llvm_init = init_runtime(argc, argv)

    finally {
        kairo::Logger::shutdown()
        kairo::GlobalRecycler::shutdown_allocator_runtime()
        kairo::std::destroy(llvm_init)
    }

    // kfmt's own flags come out of argv before the rest reaches kairo's parser
    var mode               = FmtMode::Check
    var set                = Settings{}
    var tab_size_given     = false
    var n:             i32 = 1
    for var i: i32 = 1; i < argc; ++i {
        var a = string(
            unsafe ((argv[i] as unsafe *const u8) as *const u8),
            cxx::std::strlen(argv[i]),
        )

        if a == "--write" {
            mode = FmtMode::Write
            continue
        }

        if a == "--check" {
            mode = FmtMode::Check
            continue
        }

        if a == "--stdout" {
            mode = FmtMode::Stdout
            continue
        }

        if a == "--no-align" {
            set.align = false
            continue
        }

        if a == "--normalize-parens" {
            set.normalize_parens = true
            continue
        }

        if a == "--help" || a == "-h" {
            usage()
            return 0
        }

        var ind = flag_value(a, "--indent")
        if ind.size() > 0 {
            if ind == "tabs" {
                set.use_tabs = true
            } else if ind == "spaces" {
                set.use_tabs = false
            } else {
                io::eprintln(
                    f"kfmt: --indent takes spaces or tabs, not '{ind}\x27",
                )

                return 1
            }

            continue
        }

        var ts = flag_value(a, "--tab-size")
        if ts.size() > 0 {
            var v: i32 = 0
            var ok     = ts.size() <= 2
            for var k: usize = 0; k < ts.size(); ++k {
                var c = ts[k]
                if c < ('0' as u8) || c > ('9' as u8) {
                    ok = false
                    break
                }

                v = v * 10 + ((c - ('0' as u8)) as i32)
            }

            if !ok || v < 1 || v > 16 {
                io::eprintln(
                    f"kfmt: --tab-size takes a number from 1 to 16, not '{ts}\x27",
                )

                return 1
            }

            set.tab_size   = v
            tab_size_given = true
            continue
        }

        // 2.8: the compiler tree's pass uses 100 (the full line width)
        var cw = flag_value(a, "--call-width")
        if cw.size() > 0 {
            var v: i32 = 0
            var ok     = cw.size() <= 3
            for var k: usize = 0; k < cw.size(); ++k {
                var c = cw[k]
                if c < ('0' as u8) || c > ('9' as u8) {
                    ok = false
                    break
                }

                v = v * 10 + ((c - ('0' as u8)) as i32)
            }

            if !ok || v < 40 || v > line_width() {
                io::eprintln(
                    f"kfmt: --call-width takes a number from 40 to {line_width()}, not '{cw}'",
                )

                return 1
            }

            set.call_width = v
            continue
        }

        argv[n] = argv[i]
        n += 1
    }

    // 2.4: one level is 4 spaces, or 1 tab
    if set.use_tabs && !tab_size_given {
        set.tab_size = 1
    }

    // One instance for the whole walk.
    var unsafe *ci = kairo::std::create<CompilerInstance>(n, argv)
    finally {
        kairo::std::destroy(ci)
    }

    if !ci->args_ok() {
        return 1
    }

    var inputs = ci->invocation()->input_files
    if inputs.empty() {
        io::eprintln("kfmt: no input path")
        return 1
    }

    ci->initialize(Path::cwd())

    // the -I directories, for the 5.1 module-collision test
    var roots = cxx::std::vector<string>()
    var dirs  = ci->invocation()->include_dirs
    for var i: usize = 0; i < dirs.size(); ++i {
        roots.push_back(dirs[i])
    }

    // every .k file named, or under a named directory; sorted so runs agree
    var files = cxx::std::vector<string>()
    for var x: usize = 0; x < inputs.size(); ++x {
        var target_path = inputs[x]
        var path = cxx::std::filesystem::path(kairo::sref(target_path).str())
        if !cxx::std::filesystem::exists(path) {
            io::eprintln(f"kfmt: path does not exist: {target_path}")
            return 1
        }

        if cxx::std::filesystem::is_directory(path) {
            var found = cxx::std::vector<string>()
            for entry in cxx::std::filesystem::recursive_directory_iterator(path) {
                if !entry.is_regular_file() {
                    continue
                }

                var ext = std_to_string(
                    entry.path().extension().generic_string(),
                )

                if ext != ".k" {
                    continue
                }

                found.push_back(std_to_string(entry.path().generic_string()))
            }

            sort_strings(unsafe &found)
            for var i: usize = 0; i < found.size(); ++i {
                files.push_back(found[i])
            }
        } else {
            if Path::extension_of(target_path) != ".k" {
                io::eprintln(f"kfmt: not a .k file: {target_path}")
                return 1
            }

            files.push_back(target_path)
        }
    }

    var changed: usize = 0
    var failed:  usize = 0
    for var i: usize = 0; i < files.size(); ++i {
        var r = format_one_file(ci, files[i], mode, set, roots)
        if r == 1 {
            changed += 1
        }

        if r == 2 {
            failed += 1
        }
    }

    if mode != FmtMode::Stdout {
        var what = if mode == FmtMode::Write => "reformatted" else => "would change"
        io::eprintln(
            f"kfmt: {files.size()} file(s): {changed} {what}, {failed} refused",
        )
    }

    if failed > 0 {
        return 1
    }

    if mode == FmtMode::Check && changed > 0 {
        return 1
    }

    return 0
}
