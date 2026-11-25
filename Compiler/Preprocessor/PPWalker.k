/// --- The Kairo Project ---------------------- Preprocessor/PPWalker.k --- ///
///
///   PPWalker: the preprocessor walk over one file, run in wave order.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "llvm/ADT/DenseMap.h"
ffi "c++" import "llvm/ADT/DenseSet.h"
ffi "c++" import "llvm/ADT/StringMap.h"
ffi "c++" import "Native/Types.hh"
ffi "c++" import "Native/Log.hh"
ffi "c++" import "vector"
ffi "c++" import "string"
ffi "c++" import "algorithm"

import AST::Context::ASTContext::ASTContext
import AST::Context::TranslationUnit::{
    DeferredMacroError,
    ImportEdge,
    TranslationUnit,
}
import AST::LangItems::{
    LangIntrinsics,
    LangMacros,
    LowerTargets,
}
import AST::Mixin::Annotation::VisibilityKind
import AST::Mixin::FFILinkage::LinkageKind
import AST::Node::Declarations::{
    ImportDecl,
    ImportItem,
    ImportKind,
    MacroDecl,
    MacroParamSpec,
}
import AST::Node::Statements::{
    FFILang,
    ffi_lang_of_literal,
}
import Config::Invocation::CompilerInvocation
import Config::Preprocessor::PreprocessorOptions
import Diagnostic::Code::DiagCode
import Diagnostic::Engine::DiagEngine
import Diagnostic::Registry::DiagID
import Diagnostic::Severity::DiagSeverity
import Interop::Clang::HeaderSet::HeaderSet
import Interop::Clang::HeaderSetCache::HeaderSetCache
import Lexer::Immediate::{
    Immediate,
    ImmediateTable,
    next_string_segment,
}
import Lexer::Lexer::Lexer
import Location::SourceManager::SourceManager
import Location::SourceRange::SourceRange
import Macro::Sentinel::MacroSentinel
import Native::TimeReport::KTimeRecord
import Parser::Shared::ImportGrammar::ImportSpec
import Parser::Shared::StringOperand::{
    StringOperand,
    prefixed_range,
    refused_prefix,
    refused_prefix_fixable,
    refused_prefix_message,
    refused_suffix_message,
}
import Preprocessor::FileImportIndex::FileImportIndex
import Preprocessor::MacroTable::{
    MacroEntry,
    MacroTable,
}
import Preprocessor::PreprocessorSymbolTable::{
    PreprocessorSymbolTable,
    SymbolID,
}
import Preprocessor::ScopeTracker::{
    ModuleVisibility,
    ScopeTracker,
}
import Preprocessor::StreamCursor::StreamCursor
import Preprocessor::TokenSource::{
    InvokeHop,
    TokenSource,
}
import Resolution::ImportProbe::ImportResolver
import Resolution::ModulePath::ModulePath
import Support::Ascii::{
    is_ident_char,
    is_ident_start,
}
import Support::FlagSet::FlagSet
import Support::TimeReport::{
    TimeRegion,
    TimeSampled,
    time_enabled,
    time_region,
}
import Token::IdentifierToken::IdentifierToken
import Token::Token::Token
import Token::TokenBuffer::TokenBuffer
import Token::TokenCacheManager::TokenCacheManager
import Token::TokenKind::TokenKind
import Token::TokenText::TokenText
import std::io

/// A PPWalker's one read of its file (PPWalker::_phase).
pub enum WalkPhase derives u8 {
    Fresh,      ///< constructed; set_* may still configure the read.
    Collecting, ///< collect_macros(): macro definitions only, nothing emitted.
    Walking,    ///< run(): the walk proper.
    Done,       ///< the read is over; the walker is only queried and destroyed.
}

/// Splits a run of macro-argument tokens at the commas outside every `()`,
/// `[]` and `{}`. It is fed one token at a time, so a user macro's raw
/// arguments (split before expansion) and a value-position builtin's
/// expanded ones (split after it) share one rule without a copy of the run.
/// An expanded token arrives wrapped (TkMacroExpand, its origin chain in
/// `imm`); feed_as classifies it by the kind it was before the wrap, while
/// the buffers keep the wrapped token so diagnostics still read its origin.
class ArgSplitter {
    var args:    [unsafe *TokenBuffer<512>]
    var current: unsafe *TokenBuffer<512>   = &null
    var paren:   i32                        = 0
    var square:  i32                        = 0
    var brace:   i32                        = 0

    fn ArgSplitter(self) {
        self.current = unsafe (@create TokenBuffer<512>() as unsafe *TokenBuffer<512>)
    }

    fn feed(self, tok: Token) {
        self.feed_as(tok, tok.kind)
    }

    /// Feeds `tok`, splitting and nesting as if it were of `kind`.
    fn feed_as(self, tok: Token, kind: TokenKind) {
        if kind == TokenKind::OpLParen {
            self.paren += 1
        } else if kind == TokenKind::OpRParen {
            self.paren -= 1
        } else if kind == TokenKind::OpLSquare {
            self.square += 1
        } else if kind == TokenKind::OpRSquare {
            self.square -= 1
        } else if kind == TokenKind::OpLBrace {
            self.brace += 1
        } else if kind == TokenKind::OpRBrace {
            self.brace -= 1
        } else if kind == TokenKind::OpComma
            && self.paren == 0
            && self.square == 0
            && self.brace == 0 {
            self.args.push(self.current)
            self.current = unsafe (@create TokenBuffer<512>() as unsafe *TokenBuffer<512>)
            return
        }

        self.current->append(tok)
    }

    /// Every argument fed, the run after the last top-level comma included;
    /// the caller owns the buffers.
    fn finish(self) -> [unsafe *TokenBuffer<512>] {
        self.args.push(self.current)
        self.current = &null
        return self.args
    }
}

const BRACE_MODULE: u8 = 0
const BRACE_BRANCH: u8 = 1
const BRACE_BLOCK:  u8 = 2
const BRACE_GROUP:  u8 = 3

/// What the preprocessor knows of an `eval if` condition before Sema folds
/// it. Only a condition that asks `defined!` is the preprocessor's to
/// decide: any other is COND_SEMA, and its branches are walked as plain
/// text. One that asks is COND_OPEN when it also reads anything but
/// `true`, `false`, `!`, `&&`, `||` and parentheses, or when the name is no
/// Kairo macro: such a name may still be one of clang's.
const COND_FALSE: u8 = 0
const COND_TRUE:  u8 = 1
const COND_OPEN:  u8 = 2
const COND_SEMA:  u8 = 3

/// An `eval if` branch as the walk treats it: BRANCH_LIVE is walked as any
/// other text; BRANCH_OPEN is walked, and an unknown macro in it is an
/// error only if Sema keeps the branch; BRANCH_DEAD is not walked at all.
const BRANCH_LIVE: u8 = 0
const BRANCH_OPEN: u8 = 1
const BRANCH_DEAD: u8 = 2

/// The else-if chain a branch belongs to, as bits: CHAIN_TAKEN when the
/// condition of this branch or an earlier one is known true (every later
/// branch is dead), CHAIN_OPEN when one of them is not known.
const CHAIN_TAKEN: u8 = 1
const CHAIN_OPEN:  u8 = 2

pub class PPWalker {
    priv var _splices:          [unsafe *TokenBuffer<512>] ///< frame backing; freed in finalize
    priv var _opts:             PreprocessorOptions
    priv var _src:              unsafe *TokenSource
    priv var _imports:          unsafe *FileImportIndex
    priv var _tracker:          unsafe *ScopeTracker
    priv var _out:              unsafe *TokenBuffer<512>
    priv var _ctx:              unsafe *ASTContext
    priv var _tu:               unsafe *TranslationUnit
    priv var _macros:           unsafe *MacroTable
    priv var _sym:              unsafe *PreprocessorSymbolTable
    priv var _sm:               unsafe *SourceManager
    priv var _tcm:              unsafe *TokenCacheManager
    priv var _diag:             unsafe *DiagEngine
    priv var _imm:              unsafe *ImmediateTable
    priv var _lexer:            unsafe *Lexer
    priv var _inv:              *CompilerInvocation?
    priv var _sink:             unsafe *TokenBuffer<512>
    priv var _unique_tag_cache: llvm::StringMap<u32> ///< probed only, never iterated
    priv var _fid:              u32                             = u32::MAX //< invalid sentinel
    priv var _expansion_count:  i32                             = 0
    /// Outermost-invocation sites whose chain already hit --cmax-macro-depth.
    /// Every deeper hop of a runaway chain trips the same limit; one R008E per
    /// chain says it, the rest are noise that buries the real error.
    priv var _depth_reported: llvm::DenseSet<u64> ///< `raw as u64`: any u32 raw location is a valid key
    /// `defined!` invocations passed through to the parser (by the name
    /// token's location), so the rescan of their own output does not take
    /// them for an invocation again.
    priv var _defined_raw:    llvm::DenseSet<u64>     ///< `raw as u64`, as _depth_reported
    priv var _unique_counter: u32                 = 0

    /// A macro a block defines (_in_block), visible to the end
    /// of that block and never in the MacroTable: no other file and no
    /// sibling block can name it.
    struct BlockMacro {
        var entry: unsafe *MacroEntry
        var depth: i32                ///< the defining block's place in _braces, from 1.
    }

    priv var _block_macros: [Self::BlockMacro] ///< innermost block last.
    /// Every `{` the walk has open, outermost first: BRACE_MODULE (a module's
    /// own), BRACE_BRANCH (an `eval if` branch: its declarations are the
    /// enclosing scope's, so it is no scope for a macro either), BRACE_GROUP
    /// (an `ffi "lang" { }` or `eval { }` block, which groups declarations
    /// of the enclosing scope and is no scope for a macro for the same
    /// reason) or BRACE_BLOCK.
    priv var _braces:      [u8]
    priv var _branch_next: bool = false ///< the next `{` opens an `eval if` branch.
    priv var _group_next:  bool = false ///< the next `{` opens an `ffi` or `eval` block.
    /// The next branch's BRANCH_* and its chain's CHAIN_* bits, read when
    /// its `{` is met (_branch_next).
    priv var _next_branch: u8 = BRANCH_LIVE
    priv var _next_chain:  u8 = 0
    /// One entry per BRACE_BRANCH in _braces, innermost last: the branch's
    /// BRANCH_* in the low two bits, its chain's CHAIN_* bits above them.
    priv var _branches:    [u8]
    priv var _open_depth:  i32                  = 0 ///< BRANCH_OPEN branches the walk is inside.
    priv var _skip_dead:   bool                 = false ///< the `{` just emitted opened a BRANCH_DEAD branch.
    priv var _block_owned: [unsafe *MacroEntry] ///< every block macro of the walk; freed with it.

    /// ffi headers this file imports, spelled as HeaderSet::unquote does,
    /// deduped, in SOURCE ORDER: the key of the one HeaderSet _finalize
    /// requests. Order is part of the key because it is part of the meaning:
    /// a header may depend on what an earlier one declared or defined.
    priv var _ffi_headers: cxx::std::vector<string>
    /// Parallel to _ffi_headers: written `ffi "c"`. Carried into the set so
    /// the C ones are parsed, and linked, as extern "C".
    priv var _ffi_c: cxx::std::vector<u8>
    /// Parallel to _ffi_headers: the header string's span. A clang error at
    /// the set's synthesized `#include` line reports here, not at <injected>.
    priv var _ffi_locs: cxx::std::vector<SourceRange>
    /// Null in tooling runs with no clang: ffi imports then resolve to nothing.
    priv var _headers: unsafe *HeaderSetCache = &null

    /// # Pass timing (--time-passes)
    ///
    ///   Handles resolved once in run(), null when timing is off   which is
    ///   what makes the sampled scopes below cost a single null check on the
    ///   per-token path. Counters are per-walker, hence per-file and per-thread;
    ///   a shared counter would put a contended cache line in the token loop,
    ///   which is the exact cost sampling exists to avoid.

    priv var _t_detect: unsafe *KTimeRecord = &null
    priv var _t_emit:   unsafe *KTimeRecord = &null
    /// The builtin module's scope, searched after this file's own imports
    /// (PreProcessor::_walk_one sets it on every file outside the builtin
    /// root). Unset for the builtin files and with the prelude off.
    priv var _prelude:     ModulePath
    priv var _has_prelude: bool       = false
    priv var _c_detect:    u32        = 0
    priv var _c_emit:      u32        = 0

    /// # Import cycles (PreProcessor::_prelex_cycles)

    /// Where this walker is. A walker does ONE read of its file: either
    /// collect_macros() (an import cycle's first read) or run(), never both
    /// (the collecting walker is destroyed, and the walk gets a new one told
    /// assume_macros_known()). Collecting: nothing is emitted, and only macro
    /// definitions and scope tokens are acted on. The set_* configuration
    /// belongs before the read, while the walker is Fresh: the token source
    /// takes its replay frame before the first pull.
    priv var _phase: WalkPhase = WalkPhase::Fresh
    /// This file's macros are registered already: by collect_macros() on an
    /// earlier walker (assume_macros_known), or by this one's own collect.
    /// run() steps over each definition instead of defining it again.
    priv var _macros_known: bool = false
    /// ig_err is silent: the grammar is re-read for its tokens alone, and
    /// whatever it had to say was said on the first read. Only ever turned
    /// on around one grammar call, saved before and restored after (never
    /// set then cleared), so a nested quiet read cannot unmute the outer
    /// one; the calls that sit in a block of their own restore it in a
    /// `finally`, so no exit from that block leaves the walk muted.
    priv var _quiet: bool = false

    fn PPWalker(self,
                fid:         u32,
                lexer:       unsafe *Lexer,
                ctx:         unsafe *ASTContext,
                tu:          unsafe *TranslationUnit,
                macros:      unsafe *MacroTable,
                resolver:    unsafe *ImportResolver,
                sym:         unsafe *PreprocessorSymbolTable,
                sm:          unsafe *SourceManager,
                tcm:         unsafe *TokenCacheManager,
                diag:        unsafe *DiagEngine,
                const opts:  PreprocessorOptions,
                module_base: ModulePath,
                headers:     unsafe *HeaderSetCache = &null) {
        self._fid     = fid
        self._headers = headers
        self._lexer   = lexer
        self._ctx     = ctx
        self._tu      = tu
        self._macros  = macros
        self._sym     = sym
        self._sm      = sm
        self._tcm     = tcm
        self._diag    = diag
        self._opts    = opts.copy()
        self._imm     = lexer->get_imm_tbl()
        self._out     = unsafe (@create TokenBuffer<512>() as unsafe *TokenBuffer<512>)
        self._src = unsafe (@create TokenSource(
            lexer,
            opts.max_token_count,
            diag,
        ) as unsafe *TokenSource)

        self._src->set_preserve_comments(opts.preserve_comments)
        self._src->set_file_name(sm->get_filename(fid))
        self._imports = unsafe (@create FileImportIndex(
            unsafe (sym as *PreprocessorSymbolTable),
            unsafe (sm as *SourceManager),
            tcm,
            unsafe (resolver as *ImportResolver),
            unsafe (macros as *MacroTable),
            unsafe (diag as *DiagEngine),
            fid,
        ) as unsafe *FileImportIndex)

        self._tracker = unsafe (@create ScopeTracker(
            unsafe (sym as *PreprocessorSymbolTable),
            unsafe (sm as *SourceManager),
            unsafe (self._imm as *ImmediateTable),
            tcm,
            module_base,
        ) as unsafe *ScopeTracker)

        self._sink = self._out
    }

    /// the prelude for macros: the file behaves as though it wrote
    /// `import builtin::*` (Compiler/Spec/Panic.md#where-nothing-may-leave: `crash!` is a plain macro
    /// in Lib/builtin), searched after its own imports so an explicit
    /// import, or the file's own macro, of the same name wins.
    fn set_prelude_scope(self, const scope: ModulePath) {
        eval if defined!(DEBUG) {
            self._check_fresh("set_prelude_scope")
        }

        self._prelude     = scope
        self._has_prelude = true
    }

    /// an import the file did not write: a prelude-shaped wildcard
    /// of `target` (an f256 / f512 class file). Called after
    /// run(), so the TU gets it where the driver's builtin prelude
    /// import also lands, after every written one. Its edge orders
    /// Sema (the class is typed first, its N binding the lang item),
    /// and it binds the class's names as the builtin root's
    /// re-export did when every program loaded it.
    fn add_implicit_import(self, target: u32) {
        var rng = SourceRange::invalid()
        if self._sm != &null {
            var loc = self._sm->get_loc(self._fid, 0)
            rng = SourceRange(loc, loc)
        }

        var unsafe *id = ImportDecl::create(self._ctx, rng, ImportKind::Native)
        id->is_wildcard    = true
        id->is_prelude     = true
        id->resolved_fid   = target
        id->file_seg_count = 1
        self._tu->imports.push(id)

        var edge = ImportEdge{}
        edge.target_fid = target
        edge.decl       = id
        self._tu->import_edges.push(edge)
    }

    // Not transferable: it owns its output, sources and tracker and is addressed by the parsers it drives; a copy would free them twice.
    @copy fn PPWalker(self, const other: Self) = delete

    fn op finally (self) {
        if self._out != &null {
            @destroy unsafe (self._out as *TokenBuffer<512>)
            self._out = &null
        }

        for b in self._splices {
            if b != &null {
                @destroy unsafe (b as *TokenBuffer<512>)
            }
        }

        for e in self._block_owned {
            if e != &null {
                @destroy unsafe (e as *MacroEntry)
            }
        }

        self._splices.clear()

        if self._src != &null {
            @destroy unsafe (self._src as *TokenSource)
            self._src = &null
        }

        if self._imports != &null {
            @destroy unsafe (self._imports as *FileImportIndex)
            self._imports = &null
        }

        if self._tracker != &null {
            @destroy unsafe (self._tracker as *ScopeTracker)
            self._tracker = &null
        }
    }

    /// # shared-grammar host surface (raw kinds; stream is pre-expansion)

    /// The shared grammars read this walk's stream through a StreamCursor:
    /// it reports into the walk's engine, and nothing while the walk is quiet.
    priv fn _silent_cursor(self) -> StreamCursor {
        return StreamCursor(unsafe (self._src as *TokenSource), &null)
    }

    priv fn _cursor(self) -> StreamCursor {
        var diag: unsafe *DiagEngine = &null
        if !self._quiet {
            diag = self._diag
        }

        return StreamCursor(unsafe (self._src as *TokenSource), diag)
    }

    /// An error of the walk's own grammar (ffi imports), reported as the
    /// shared grammars report theirs.
    priv fn _err(self, r: SourceRange, const msg: string, code: DiagID) {
        var cur = self._cursor()
        cur.ig_err(r, msg, code)
    }

    /// Frame 0 from tokens already lexed (TokenSource::set_replay).
    fn set_replay(self, toks: unsafe *[Token]) {
        eval if defined!(DEBUG) {
            self._check_fresh("set_replay")
        }

        self._src->set_replay(toks)
    }

    /// collect_macros() ran for this file on an earlier walker.
    fn assume_macros_known(self) {
        eval if defined!(DEBUG) {
            self._check_fresh("assume_macros_known")
        }

        self._macros_known = true
    }

    /// Debug builds: `what` configures the read, so it must come before it.
    priv fn _check_fresh(self, const what: string) {
        if self._phase != WalkPhase::Fresh {
            kairo::std::ice_fail(
                f"PPWalker::{what} after the walker started reading (phase {self._phase as u8 as u32})",
            )
        }
    }

    /// The macro DEFINITIONS of this file, registered ahead of its walk.
    ///
    /// A file sees an imported macro only once the file defining it
    /// has been walked, and the waves walk an importee first. On an
    /// import cycle there is no such order: one side of every cycle
    /// is walked before a file it imports, and its uses of that
    /// file's macros found nothing. So every file on a cycle runs
    /// this first (PreProcessor::_prelex_cycles), and the walks then
    /// see every macro of the cycle whatever their order. It acts
    /// only on what a definition needs: `macro` (and its visibility),
    /// and the `module` blocks and braces that give it its scope.
    /// Imports are stepped over, silently, so their braces are not
    /// read as scopes; nothing is emitted or expanded. A macro
    /// body is raw tokens, so no definition needs another file's
    /// macros to be read.
    fn collect_macros(self) {
        eval if defined!(DEBUG) {
            self._check_fresh("collect_macros")
        }

        self._phase = WalkPhase::Collecting
        while !self._src->at_eof() {
            var t = self._src->peek(0)
            var k = t.kind
            if k == TokenKind::TkEof {
                break
            }

            self._note_eval_if(k)
            if k == TokenKind::KwImport {
                {
                    var cur = self._silent_cursor()
                    cur.parse_import_spec()
                }

                continue
            }

            // A block's macro is the walk's to define, where the block is.
            if k == TokenKind::KwMacro {
                if self._in_block() {
                    self._skip_macro_def()
                } else {
                    self._handle_macro_def(VisibilityKind::Public)
                }

                continue
            }

            if k == TokenKind::KwPub || k == TokenKind::KwPriv || k == TokenKind::KwProt {
                var vis =      if (k == TokenKind::KwPub) => (VisibilityKind::Public)
                          else if (k == TokenKind::KwPriv) => (VisibilityKind::Private)
                          else => VisibilityKind::Protected
                var nk = self._src->peek(1).kind
                if nk == TokenKind::KwImport {
                    self._src->next()
                    {
                        var cur = self._silent_cursor()
                        cur.parse_import_spec()
                    }

                    continue
                }

                if nk == TokenKind::KwMacro {
                    self._src->next()
                    if self._in_block() {
                        self._skip_macro_def()
                    } else {
                        self._handle_macro_def(vis)
                    }

                    continue
                }

                if nk == TokenKind::KwModule {
                    var mv =      if (k == TokenKind::KwPub) => (ModuleVisibility::Public)
                             else if (k == TokenKind::KwPriv) => (ModuleVisibility::Private)
                             else => ModuleVisibility::Protected
                    self._src->next()
                    self._track_scope(self._src->peek(0), mv)
                    continue
                }

                self._src->next()
                continue
            }

            if self._track_scope(t, ModuleVisibility::Public) {
                continue
            }

            self._src->next()
        }

        self._phase        = WalkPhase::Done
        self._macros_known = true
    }

    /// A macro definition collect_macros() already registered: its tokens,
    /// consumed exactly as _handle_macro_def consumes them, and nothing else
    /// -- no second MacroDecl, no duplicate-definition error, no diagnostic
    /// the first read already gave.
    priv fn _skip_macro_def(self) {
        var kw = self._src->next() // `macro`
        if self._src->peek(0).kind == TokenKind::OpAt {
            self._emit(kw)
            return
        }

        var cur = self._silent_cursor()
        var hdr = cur.macro_header()
        if !hdr.ok {
            self._recover_to_terminator()
            return
        }

        var builtin = self._is_builtin_name(
            TokenText::spelling(hdr.name, self._tcm),
        )

        if self._src->peek(0).kind != TokenKind::OpLBrace {
            if builtin {
                self._recover_to_terminator()
            }

            return
        }

        self._src->next() // `{`
        var d: i32 = 1
        while !self._src->at_eof() && d > 0 {
            var t = self._src->next()
            if t.kind == TokenKind::OpLBrace {
                d += 1
            }

            if t.kind == TokenKind::OpRBrace {
                d -= 1
            }
        }

        if builtin {
            return
        }

        if d == 0 && self._src->peek(0).kind == TokenKind::OpSemicolon {
            self._src->next()
        }
    }

    //  The walk

    fn run(self) -> bool {
        eval if defined!(DEBUG) {
            self._check_fresh("run")
        }

        self._phase = WalkPhase::Walking
        finally {
            self._phase = WalkPhase::Done
        }

        // Resolved once per file, under the Walk region the wave opened. The
        // per-token scopes below check these for null before anything else, so
        // leaving them null when timing is off makes the instrumentation free.
        if time_enabled() {
            self._t_detect = time_region("Detect")
            self._t_emit   = time_region("Emit")
        }

        while !self._src->at_eof() {
            var t = self._src->peek(0)
            var k = t.kind

            if k == TokenKind::TkEof {
                break
            }

            self._note_eval_if(k)
            if self._skip_dead {
                self._skip_dead = false
                self._skip_branch_body()
                continue
            }

            if k == TokenKind::KwFfi {
                self._handle_ffi()
                continue
            }

            if k == TokenKind::KwImport {
                self._handle_import(VisibilityKind::Private)
                continue
            } // an import is priv by default

            if k == TokenKind::KwMacro {
                if self._macros_known && !self._in_block() { // a macro is pub by default
                    self._skip_macro_def()
                } else {
                    self._handle_macro_def(VisibilityKind::Public)
                }

                continue
            }

            if k == TokenKind::KwPub || k == TokenKind::KwPriv || k == TokenKind::KwProt {
                var vis =      if (k == TokenKind::KwPub) => (VisibilityKind::Public)
                          else if (k == TokenKind::KwPriv) => (VisibilityKind::Private)
                          else => VisibilityKind::Protected
                var nk = self._src->peek(1).kind
                if nk == TokenKind::KwImport {
                    self._src->next() // consume visibility keyword
                    self._handle_import(vis)
                    continue
                }

                if nk == TokenKind::KwMacro {
                    self._src->next()
                    if self._macros_known && !self._in_block() {
                        self._skip_macro_def()
                    } else {
                        self._handle_macro_def(vis)
                    }

                    continue
                }

                if nk == TokenKind::KwModule {
                    var mv =      if (k == TokenKind::KwPub) => (ModuleVisibility::Public)
                             else if (k == TokenKind::KwPriv) => (ModuleVisibility::Private)
                             else => ModuleVisibility::Protected
                    self._emit_next() // vis keyword IS emitted the
                    // parser needs `pub module Foo {`
                    self._track_scope(self._src->peek(0), mv)
                    continue
                }

                self._emit_next() // plain visibility on some other decl
                continue
            }

            // scope tracking off structural tokens (module/braces)
            if self._track_scope(t, ModuleVisibility::Public) {
                continue
            }

            // invocation?
            //
            // Timed INSIDE _detect_invocation, not around this call: hoisting
            // the result out of a timing block would copy an InvocationInfo
            // (three vectors) on every token. Pessimizing the preprocessor to
            // measure the preprocessor is a bad trade.
            var inv = self._detect_invocation()
            if inv.found {
                var _tx = TimeRegion("Expand")
                self._expand(unsafe &inv)
                continue
            }

            var chain:   [InvokeHop]
            var next_tok             = self._src->next_with_origin(&chain)
            self._emit(next_tok, unsafe &chain)
        }

        {
            var _tf = TimeRegion("Finalize")
            self._finalize()
        }

        return !self._diag->has_fatal()
    }

    //  Emission single choke point + disallow backstop

    /// ### Parameters
    /// - `chain`: the token's macro-origin chain, as captured atomically by
    ///   TokenSource::next_with_origin at the moment it was pulled.
    ///   &null (the default) for tokens that are never origin-wrapped
    ///   (the poison sentinel, a proc macro's `macro`). The walk's own
    ///   passthroughs (visibility keywords, braces, `module` paths, the
    ///   `ffi "lang"` head) go through _emit_next.
    priv fn _emit(self, t: Token, chain: unsafe *[InvokeHop] = &null) {
        // Sampled, same reasoning as _detect_invocation: the single choke
        // point every token passes through.
        var _t = TimeSampled(self._t_emit, 64, unsafe &self._c_emit)
        if self._phase == WalkPhase::Collecting { // collect_macros: a read, not a walk.
            return
        }

        if self._src->in_splice() {
            if t.kind == TokenKind::KwImport || t.kind == TokenKind::KwMacro {
                // BACKSTOP (primary check is at def time). To lift the rule:
                // delete this block and route these kinds into the walk switch.
                self._diag->report(
                    DiagCode(DiagID::R012E),
                    self._src->top_invoke_loc().start,
                    "macro expansion may not produce 'import' or 'macro' declarations",
                ).first(self._src->top_invoke_loc())->emit()
                return
            }
        }

        if t.kind == TokenKind::TkUnknown && t.imm != u32::MAX {
            t = self._illegal_chars(t)
        }

        t = self._expand_fstring(t, chain)

        if chain != &null && chain->size() > 0 {
            self._wrap_origin(&t, *chain)
        }

        self._sink->append(t)
    }

    /// stamps `t` with a real macro-expansion origin: TkMacroExpand at
    /// the OUTERMOST invocation's position, `imm` pointing at a chain
    /// of MacroExpansionInfo records (one per active frame) that
    /// ASTParse::report_tok/attach_macro_expansion_chain already know
    /// how to walk back to the true definition-site identity.
    ///
    ///        No-op for a token that's already TkMacroExpand (a poison/builtin
    ///        sentinel, or one wrapped by a deeper nested expansion already --
    ///        re-wrapping would shadow the sentinel/chain it already carries).
    ///
    ///        `chain` is OUTERMOST-first (see next_with_origin). The FIRST
    ///        record built here must be the one attach_macro_expansion_chain's
    ///        walk reaches LAST (since it walks from `t.imm` outward), so this
    ///        builds outermost-to-innermost, chaining each new record's
    ///        original_kind/imm at the PREVIOUS one, and keeps the innermost
    ///        (built last) as `t`'s new imm -- the walk then reports the
    ///        closest cause first and the true call site last, terminating on
    ///        the real original identity.
    ///
    ///        Applies uniformly to body-literal AND argument-substituted
    ///        tokens alike (both flow through the same splice frame by the
    ///        time _emit sees them) -- an argument token's reported position
    ///        moves to the invocation site rather than staying at its own
    ///        (usually adjacent) column. Accepted imprecision: distinguishing
    ///        the two would need per-token provenance threaded out of
    ///        _substitute_body, which isn't worth the complexity here.
    priv fn _wrap_origin(self, t: *Token, const chain: [InvokeHop]) {
        if t->kind == TokenKind::TkMacroExpand {
            return
        }

        var cur_kind  = t->kind
        var cur_imm   = t->imm
        var def_range = t->range

        for var i: usize = 0; i < chain.size(); ++i {
            var hop = (chain)[i]

            var idx = self._imm->create<Immediate::MacroExpansionInfo>()
            var unsafe *info = self._imm->get<Immediate::MacroExpansionInfo>(
                idx,
            )

            info->invoke_range  = hop.loc
            info->def_range     = def_range
            info->original_kind = cur_kind
            info->original_imm  = cur_imm
            info->macro_name    = hop.name
            info->parent_idx    = u32::MAX

            cur_kind = TokenKind::TkMacroExpand
            cur_imm  = idx
        }

        t->kind  = TokenKind::TkMacroExpand
        t->imm   = cur_imm
        t->range = (chain)[0].loc           // outermost invocation: the token's reportable position
    }

    /// consumes the next source token and emits it with its macro
    /// origin, for the walk's own passthroughs (visibility keywords,
    /// scope-tracked braces and `module` paths, the `ffi "lang"` head).
    ///
    /// every token of a macro body reads at the invocation, these
    /// included: a `pub` or a `}` emitted unwrapped keeps its
    /// body-site range, and a `pub fn get() { ... }` from an
    /// imported macro then spans from the invoking file into the
    /// defining one, which the codegen token sink reads past the end
    /// of the invoking file's buffer (I003E).
    /// `t`, a run of characters no token holds (Lexer::lex_illegal_ascii)
    /// on its way to the parser: reported once, as S011E, and handed on as
    /// the name its imm spells, so the parser goes on as after a non-ASCII
    /// run and reports nothing more. Reported here and not by the lexer: a
    /// macro body or argument may hold the run, and only a token that
    /// reaches the parser is code.
    priv fn _illegal_chars(self, t: Token) -> Token {
        if !self._quiet {
            var text = self._ctx->get_spelling(t.range)
            var what = if (text.size() > 0
                           && text.data()[0] >= 0x20
                           && text.data()[0] < 0x7f) => (f"character '{text.subslice(0, 1)}'")
                       else => "character U+007F"
            var b = self._diag->report(
                DiagCode(DiagID::S011E),
                t.range.start,
                f"{what} cannot appear outside a string, a character literal or a comment",
            )

            b.first(t.range)
            b.emit()
        }

        var out = t
        out.kind = TokenKind::LitIdentifier
        return out
    }

    priv fn _emit_next(self) {
        var chain: [InvokeHop]
        var t                  = self._src->next_with_origin(&chain)
        self._emit(t, unsafe &chain)
    }

    //  Scope tracking
    //  ScopeTracker consumes from a TokenSpan today. On the stream we feed it
    //  one token at a time via a 1-token shim. The tracker only needs the
    //  current token + the ability to look at i+1 for `module Foo {`; we give
    //  it a 2-token window built from peeks. This is the one place the
    //  tracker's API forces a small adapter.

    priv fn _track_scope(self, t: Token, vis: ModuleVisibility) -> bool {
        var k = t.kind
        if k != TokenKind::OpLBrace && k != TokenKind::OpRBrace && k != TokenKind::KwModule {
            return false
        }

        if k == TokenKind::OpLBrace {
            var kind = BRACE_BLOCK
            if self._tracker->brace_depth() + 1 == self._tracker->scope_depth() {
                kind = BRACE_MODULE
            } else if self._group_next {
                kind = BRACE_GROUP
            } else if self._branch_next {
                kind = BRACE_BRANCH
                self._branches.push(self._next_branch | (self._next_chain << 2))

                if self._next_branch == BRANCH_OPEN {
                    self._open_depth += 1
                }

                // Only the walk drops text: a collecting read registers the
                // macros of every branch.
                self._skip_dead = self._next_branch == BRANCH_DEAD
                    && self._phase == WalkPhase::Walking
            }

            self._branch_next = false
            self._group_next  = false
            self._next_branch = BRANCH_LIVE
            self._next_chain  = 0
            self._braces.push(kind)
        }

        self._tracker->feed_stream(self._src, vis, fn() { self._emit_next() })
        if k == TokenKind::OpRBrace {
            var was = BRACE_BLOCK
            if !self._braces.is_empty() {
                was = self._braces[self._braces.size() - 1]
                self._braces.pop()
            }

            // `} else {` and `} else if c {`, the `else` on this line or
            // a later one: the next `{` is a branch too.
            if was == BRACE_BRANCH {
                var info: u8 = 0
                if !self._branches.is_empty() {
                    info = self._branches[self._branches.size() - 1]
                    self._branches.pop()
                }

                if (info & 3) == BRANCH_OPEN {
                    self._open_depth -= 1
                }

                var at: usize = 0
                while self._src->peek(at).kind == TokenKind::TkNewLine {
                    at += 1
                }

                if self._src->peek(at).kind == TokenKind::KwElse {
                    self._else_branch(at, info >> 2)
                }
            }

            while !self._block_macros.is_empty()
                && (self._block_macros[self._block_macros.size() - 1].depth as usize) > self._braces.size() {
                self._block_macros.pop()
            }
        }

        return true
    }

    /// The `else` at peek(`at`), after a branch whose chain is `chain`.
    /// Once a condition of the chain is known true the rest of it is dead
    /// text, conditions included, and is dropped here; Sema then sees the
    /// chain end at the branch before.
    priv fn _else_branch(self, at: usize, chain: u8) {
        if (chain & CHAIN_TAKEN) != 0 && self._phase == WalkPhase::Walking {
            self._drop_else_chain()
            return
        }

        self._branch_next = true
        if self._src->peek(at + 1).kind == TokenKind::KwIf {
            self._note_cond(at + 2, chain)
            return
        }

        self._next_chain  = chain
        self._next_branch = if ((chain & CHAIN_OPEN) != 0) => (BRANCH_OPEN) else => BRANCH_LIVE
    }

    /// The condition at peek(`at`) of a chain that is `chain` so far:
    /// what its branch is, into _next_branch and _next_chain.
    priv fn _note_cond(self, at: usize, chain: u8) {
        var v = self._cond_value(at)
        self._next_chain = chain
        if v == COND_SEMA {
            self._next_branch = if ((chain & CHAIN_OPEN) != 0) => (BRANCH_OPEN) else => BRANCH_LIVE
            return
        }

        if v == COND_FALSE {
            self._next_branch = BRANCH_DEAD
            return
        }

        if v == COND_TRUE {
            self._next_chain  = chain | CHAIN_TAKEN
            self._next_branch = if ((chain & CHAIN_OPEN) != 0) => (BRANCH_OPEN) else => BRANCH_LIVE
            return
        }

        self._next_chain  = chain | CHAIN_OPEN
        self._next_branch = BRANCH_OPEN
    }

    /// COND_* of the condition whose first token is peek(`at`): the
    /// tokens up to the `{` that opens its branch, read where they stand
    /// and not consumed. They are expanded and emitted as any other text
    /// afterwards, so Sema folds the same condition to the same value.
    priv fn _cond_value(self, at: usize) -> u8 {
        var toks: [Token]
        var paren         = 0
        var n             = at
        var asks          = false
        while true {
            if self._src->peek_leaves_frame(n) || toks.size() > 256 {
                return if (asks) => (COND_OPEN) else => COND_SEMA
            }

            var t = self._src->peek(n)
            if t.kind == TokenKind::TkEof {
                return if (asks) => (COND_OPEN) else => COND_SEMA
            }

            if t.kind == TokenKind::LitIdentifier
                && self._src->peek(n + 1).kind == TokenKind::OpExclaim
                && TokenText::spelling(t, self._tcm) == LangIntrinsics::defined() {
                asks = true
            }

            if t.kind == TokenKind::OpLBrace && paren == 0 {
                break
            }

            if t.kind == TokenKind::OpLParen {
                paren += 1
            } else if t.kind == TokenKind::OpRParen {
                paren -= 1
            }

            if t.kind != TokenKind::TkNewLine {
                toks.push(t)
            }

            n += 1
        }

        if !asks {
            return COND_SEMA
        }

        var pos: usize = 0
        var v          = self._cond_or(unsafe &toks, &pos)
        if pos != toks.size() {
            return COND_OPEN
        }

        return v
    }

    priv fn _cond_or(self, toks: unsafe *[Token], @inout pos: usize) -> u8 {
        var v = self._cond_and(toks, &pos)
        while pos < toks->size()
            && ((*toks)[pos].kind == TokenKind::OpPipePipe
                || (*toks)[pos].kind == TokenKind::KwOr) {
            pos += 1
            var r = self._cond_and(toks, &pos)
            if v == COND_TRUE || r == COND_TRUE {
                v = COND_TRUE
            } else if v == COND_OPEN || r == COND_OPEN {
                v = COND_OPEN
            }
        }

        return v
    }

    priv fn _cond_and(self, toks: unsafe *[Token], @inout pos: usize) -> u8 {
        var v = self._cond_unary(toks, &pos)
        while pos < toks->size()
            && ((*toks)[pos].kind == TokenKind::OpAmpAmp || (*toks)[pos].kind == TokenKind::KwAnd) {
            pos += 1
            var r = self._cond_unary(toks, &pos)
            if v == COND_FALSE || r == COND_FALSE {
                v = COND_FALSE
            } else if v == COND_OPEN || r == COND_OPEN {
                v = COND_OPEN
            }
        }

        return v
    }

    /// A token outside the grammar leaves `pos` where it is, so the
    /// caller's "all tokens read" test fails and the condition is open.
    priv fn _cond_unary(self, toks: unsafe *[Token], @inout pos: usize) -> u8 {
        if pos >= toks->size() {
            return COND_OPEN
        }

        var t = (*toks)[pos]
        if t.kind == TokenKind::OpExclaim || t.kind == TokenKind::KwNot {
            pos += 1
            var v = self._cond_unary(toks, &pos)
            if v == COND_OPEN {
                return COND_OPEN
            }

            return if (v == COND_TRUE) => (COND_FALSE) else => COND_TRUE
        }

        if t.kind == TokenKind::KwTrue {
            pos += 1
            return COND_TRUE
        }

        if t.kind == TokenKind::KwFalse {
            pos += 1
            return COND_FALSE
        }

        if t.kind == TokenKind::OpLParen {
            pos += 1
            var v = self._cond_or(toks, &pos)
            if pos >= toks->size() || (*toks)[pos].kind != TokenKind::OpRParen {
                pos = toks->size() + 1
                return COND_OPEN
            }

            pos += 1
            return v
        }

        // defined ! ( NAME )
        if t.kind == TokenKind::LitIdentifier
            && pos + 4 < toks->size()
            && TokenText::spelling(t, self._tcm) == LangIntrinsics::defined()
            && (*toks)[pos + 1].kind == TokenKind::OpExclaim
            && (*toks)[pos + 2].kind == TokenKind::OpLParen
            && (*toks)[pos + 3].kind == TokenKind::LitIdentifier
            && (*toks)[pos + 4].kind == TokenKind::OpRParen {
            var name  = (*toks)[pos + 3]
            var probe = Self::InvocationInfo()
            probe.name = name
            probe.name_sym = self._sym->intern(
                TokenText::spelling(name, self._tcm),
            )

            probe.range = name.range
            probe.found = true
            pos += 5
            return if (self._resolve(probe) != &null) => (COND_TRUE) else => COND_OPEN
        }

        pos = toks->size() + 1
        return COND_OPEN
    }

    /// The text of a dead branch, from after its `{` to before its `}`:
    /// consumed and not emitted, so nothing in it is expanded or imported.
    /// A macro the branch itself defines is still registered: an `eval if`
    /// branch is no scope for a macro, taken or not.
    priv fn _skip_branch_body(self) {
        var depth = 0
        while !self._src->at_eof() {
            var k = self._src->peek(0).kind
            if k == TokenKind::TkEof {
                return
            }

            if depth == 0 && self._dead_macro_def(k) {
                continue
            }

            if k == TokenKind::OpLBrace {
                depth += 1
            } else if k == TokenKind::OpRBrace {
                if depth == 0 {
                    return
                }

                depth -= 1
            }

            self._src->next()
        }
    }

    /// A macro definition at peek(0), kind `k`, in dead text: defined as
    /// the walk defines one in live text. False when peek(0) starts none.
    priv fn _dead_macro_def(self, k: TokenKind) -> bool {
        var vis = VisibilityKind::Public
        if k == TokenKind::KwPub || k == TokenKind::KwPriv || k == TokenKind::KwProt {
            if self._src->peek(1).kind != TokenKind::KwMacro {
                return false
            }

            vis =      if (k == TokenKind::KwPub) => (VisibilityKind::Public)
                  else if (k == TokenKind::KwPriv) => (VisibilityKind::Private)
                  else => VisibilityKind::Protected
            self._src->next()
        } else if k != TokenKind::KwMacro {
            return false
        }

        if self._macros_known && !self._in_block() {
            self._skip_macro_def()
        } else {
            self._handle_macro_def(vis)
        }

        return true
    }

    /// Every `else` branch from peek(0) on, with its condition: consumed
    /// and not emitted.
    priv fn _drop_else_chain(self) {
        while true {
            var at: usize = 0
            while self._src->peek(at).kind == TokenKind::TkNewLine {
                at += 1
            }

            if self._src->peek(at).kind != TokenKind::KwElse {
                return
            }

            for var i: usize = 0; i <= at; ++i {
                self._src->next()
            }

            // The condition, if any, up to the branch's `{`.
            var paren = 0
            while !self._src->at_eof() {
                var k = self._src->peek(0).kind
                if k == TokenKind::TkEof || (k == TokenKind::OpLBrace && paren == 0) {
                    break
                }

                if k == TokenKind::OpLParen {
                    paren += 1
                } else if k == TokenKind::OpRParen {
                    paren -= 1
                }

                self._src->next()
            }

            if self._src->peek(0).kind != TokenKind::OpLBrace {
                return
            }

            self._src->next()
            self._skip_branch_body()
            if self._src->peek(0).kind == TokenKind::OpRBrace {
                self._src->next()
            }
        }
    }

    /// The place in _braces, from 1, of the innermost open `{` that scopes a
    /// macro, or 0 at module level: an `eval if` branch, an `ffi` block and
    /// an `eval` block are looked through.
    priv fn _block_depth(self) -> i32 {
        var i = self._braces.size()
        while i > 0 {
            if self._braces[i - 1] == BRACE_BRANCH || self._braces[i - 1] == BRACE_GROUP {
                i -= 1
                continue
            }

            return if (self._braces[i - 1] == BRACE_BLOCK) => (i as i32) else => 0
        }

        return 0
    }

    priv fn _in_block(self) -> bool {
        return self._block_depth() > 0
    }

    /// `eval if` at `k`: its branches' braces are no scope of their own.
    /// Nor are an `ffi "lang" { }` block's and an `eval { }` block's: their
    /// declarations belong to the enclosing scope (macros.mdx, Scoping).
    priv fn _note_eval_if(self, k: TokenKind) {
        if k == TokenKind::KwEval && self._src->peek(1).kind == TokenKind::KwIf {
            self._branch_next = true
            self._note_cond(2, 0)
            return
        }

        if k == TokenKind::KwEval && self._src->peek(1).kind == TokenKind::OpLBrace {
            self._group_next = true
            return
        }

        if k == TokenKind::KwFfi && self._src->peek(1).kind == TokenKind::LitString {
            var at: usize = 2
            while self._src->peek(at).kind == TokenKind::TkNewLine {
                at += 1
            }

            if self._src->peek(at).kind == TokenKind::OpLBrace {
                self._group_next = true
            }
        }
    }

    //  FFI

    priv fn _handle_ffi(self) {
        // Decide form by lookahead BEFORE emitting anything.
        //   peek0 = ffi, peek1 = "lang", peek2 = import | { | decl-lead
        var p2 = self._src->peek(2).kind

        // The language string belongs on the `ffi` line. A lone `ffi` used
        // to take the NEWLINE as its language and the next line's `import
        // "h"` as its own, silently. Copied through instead, so the
        // parser reports it (S064E, "expected a language string") and the
        // next line is a statement of its own.
        if self._src->peek(1).kind != TokenKind::LitString {
            self._emit_next() // ffi
            return
        }

        // `ffi "c++"` NEWLINE `import "h"` (or a declaration, or `{`): the
        // language string stamped C++ linkage on whatever came next, so
        // `fn main` lost its C entry, and the `import` line was S046E
        //. Every documented form (imports.mdx, c-cpp-calling.mdx)
        // keeps `ffi "lang"` and what it applies to on one line. Reported
        // once, then read as the joined line, so nothing cascades.
        var nl: usize = 0
        while self._src->peek(2 + nl).kind == TokenKind::TkNewLine {
            nl += 1
        }

        if nl > 0 {
            var lang = self._src->peek(1)
            var what = self._src->peek(2 + nl)
            if !self._quiet {
                var b = self._diag->report(
                    DiagCode(DiagID::S064E),
                    lang.range.start,
                    "the declaration, block or import an ffi language string applies to must follow it on the same line",
                )

                b.first(lang.range)
                if what.range.is_valid() {
                    b.fix(
                        SourceRange::from_bounds(
                            lang.range.end,
                            what.range.start,
                        ),
                        " ",
                        "join the lines",
                    )
                }

                b.emit()
            }

            p2 = what.kind
        }

        if p2 == TokenKind::KwImport {
            // ffi "lang" import "hdr" (as name)? ;  -> consume + drop the tokens
            //
            // The header is clang's to parse (Interop/Clang/HeaderSet). Every
            // ffi header this file imports joins ONE ordered list, requested
            // as a set in _finalize so the parse runs on the pool while this
            // file is still being walked and parsed. Sema/Foreign indexes the
            // set into one Kairo TU per header before sema, and the driver
            // then stamps resolved_fid and the include closure onto the node
            // built here (FrontendAction::_attach_ffi_edges). Nothing about
            // the header resolves HERE: its fids do not exist until the set
            // is indexed.
            var ffi_kw   = self._src->next() // ffi
            var lang_tok = self._src->next() // "lang"
            for var i: usize = 0; i < nl; ++i {
                self._src->next() // the line break reported above
            }

            self._src->next() // import

            var header_tok = Token()
            var alias_tok  = Token()
            var has_alias  = false
            var last       = lang_tok
            var saw_header = false
            // One header per line, then an optional `as name` (imports.mdx,
            // c-cpp-calling.mdx). Anything else was dropped unread, so
            // `import {"a.h", "nope.h"}` imported only "a.h" and never looked
            // for the second: the first stray token is S064E and the
            // line imports nothing.
            var bad = false
            while !self._src->at_eof() {
                if self._src->peek(0).kind == TokenKind::OpSemicolon {
                    last = self._src->next()
                    break
                }

                var t = self._src->next()
                if t.kind == TokenKind::TkNewLine {
                    break
                }

                last = t
                if !saw_header && t.kind == TokenKind::LitString {
                    header_tok = t
                    saw_header = true
                    continue
                }

                if saw_header && t.kind == TokenKind::KwAs && !has_alias {
                    if self._src->peek(0).kind == TokenKind::LitIdentifier {
                        alias_tok = self._src->next()
                        has_alias = true
                        last      = alias_tok
                    } else if !bad {
                        self._err(
                            t.range,
                            "expected a name after 'as' in ffi import",
                            DiagID::S064E,
                        )

                        bad = true
                    }

                    continue
                }

                if !bad {
                    var msg = "unexpected token in an ffi import; the form is 'ffi \"c++\" import \"header\"', optionally followed by 'as name'"
                    if t.kind == TokenKind::OpLBrace && !saw_header {
                        msg = "an ffi import takes one header, not a list; write one 'ffi \"c++\" import \"header\"' line per header"
                    }

                    self._err(t.range, msg, DiagID::S064E)
                    bad = true
                }

                // A brace list may span lines: its `}` must not reach the
                // scope tracker or the parser.
                if t.kind == TokenKind::OpLBrace {
                    var depth: usize = 1
                    while !self._src->at_eof() && depth > 0 {
                        var u = self._src->next()
                        if u.kind == TokenKind::OpLBrace {
                            depth += 1
                        } else if u.kind == TokenKind::OpRBrace {
                            depth -= 1
                        }

                        last = u
                    }
                }
            }

            // `import "a.h" "b.h"`: adjacent literals are ONE token (the
            // lexer chains them), whose spelling is the first segment's, so
            // "b.h" was never looked for.
            if saw_header && !bad && self._chained_string(header_tok) {
                self._err(
                    header_tok.range,
                    "an ffi import takes one header, not a list; write one 'ffi \"c++\" import \"header\"' line per header",
                    DiagID::S064E,
                )

                bad = true
            }

            if !saw_header && !bad {
                self._err(
                    ffi_kw.range | last.range,
                    "expected a header path string after 'ffi \"...\" import'",
                    DiagID::S064E,
                )

                bad = true
            }

            if bad {
                return
            }

            // Reported, then imported as written: the header still resolves,
            // so the names it declares do not cascade.
            self._check_ffi_prefix(lang_tok, StringOperand::Tag)
            self._check_ffi_prefix(header_tok, StringOperand::Path)

            var fr = ffi_kw.range | last.range
            var unsafe *fid_node = ImportDecl::create(
                self._ctx,
                fr,
                ImportKind::Native,
            )

            fid_node->header    = header_tok
            fid_node->alias     = alias_tok
            fid_node->has_alias = has_alias
            fid_node->range     = fr
            fid_node->set_ffi_linkage(
                self._ffi_lang_kind(lang_tok),
                lang_tok,
                fr,
            )

            self._tu->imports.push(fid_node)

            if saw_header {
                var h = HeaderSet::unquote(self._ctx->get_spelling(header_tok))
                var dup = false
                for var i: usize = 0; i < self._ffi_headers.size(); ++i {
                    if self._ffi_headers[i] == h {
                        dup = true
                        break
                    }
                }

                if !dup && h.size() > 0 {
                    self._ffi_headers.push_back(h)
                    self._ffi_c.push_back(
                        (self._ffi_lang_kind(lang_tok) == LinkageKind::C) as u8,
                    )

                    self._ffi_locs.push_back(header_tok.range)
                }
            }

            return
        }

        // ffi "lang" { ... }  or  ffi "lang" <decl>  -> copy through.
        // Emit ffi + lang, then let the normal walk copy the rest. The block's
        // braces balance via ordinary emission; a single decl ends at its own
        // terminator. Nothing special needed just resume.
        self._emit_next() // ffi
        self._emit_next() // lang
        for var i: usize = 0; i < nl; ++i {
            self._src->next() // the line break reported above: joined
        }

        // walk resumes; `{`/decl tokens copy normally. Macro invocations INSIDE
        // an ffi block still expand (they did before) the walk doesn't treat
        // ffi-block interior as special, matching current behavior.
    }

    /// Reports `tok`, the language or the header of an `ffi ... import`
    /// line, when it carries a prefix a `what` operand does not take or a
    /// literal suffix.
    priv fn _check_ffi_prefix(self, tok: Token, what: StringOperand) {
        if self._quiet || tok.kind != TokenKind::LitString {
            return
        }

        var unsafe *tbl = self._tcm->get_imm_table_for_token(tok)
        if tbl == &null {
            return
        }

        var unsafe *d = tbl->get<Immediate::StringData>(tok.imm)
        if d != &null && d->suffix.range.is_valid() {
            self._diag->report(
                DiagCode(DiagID::S064E),
                d->suffix.range.start,
                refused_suffix_message(what, "ffi"),
            ).first(d->suffix.range)->remove(
                d->suffix.range,
                "remove the suffix",
            )->emit()
        }

        var refused = refused_prefix(d, what)
        if refused.is_empty() {
            return
        }

        var b = self._diag->report(
            DiagCode(DiagID::S064E),
            prefixed_range(d->prefix.range, tok.range).start,
            refused_prefix_message(what, "ffi", refused),
        )

        b.first(prefixed_range(d->prefix.range, tok.range))
        if refused_prefix_fixable(d->prefix.range, refused) {
            b.remove(d->prefix.range, "remove the prefix")
        }

        b.emit()
    }

    //  Imports

    priv fn _handle_import(self, default_vis: VisibilityKind) {
        var _t = TimeRegion("Import")

        // visibility already consumed by caller when prefixed; default_vis
        // carries Private unless caller saw pub/prot/priv.
        var vis = default_vis

        var cur  = self._cursor()
        var spec = cur.parse_import_spec() // shared grammar (consumes stmt)
        if !spec.ok {
            self._recover_to_terminator()
            return
        }

        // build the ImportDecl node into the TU (authority for klib)
        var unsafe *id = self._build_import_decl(&spec, vis)
        self._tu->imports.push(id)

        // resolve NOW; errors HERE. record() stamps id->resolved_fid and hands
        // back the source-module fid; a resolved import becomes a TU import
        // edge in declaration order (the one writer of import_edges). ffi
        // imports never reach here, so no edge is ever synthesized for them.
        // Resolved is file_seg_count, not a non-zero fid: fid 0 is the first
        // input, which a module it imports may import back (an import cycle
        // through the entry file), and that edge was dropped with the rest.
        var target_fid = self._imports->record(id)
        if id->file_seg_count > 0 {
            var edge = ImportEdge{}
            edge.target_fid = target_fid
            edge.decl       = id
            self._tu->import_edges.push(edge)
        }

        // consume trailing `;` if present (grammar leaves it)
        if self._src->peek(0).kind == TokenKind::OpSemicolon {
            self._src->next()
        }

        // NOTHING emitted import is PP-invisible in the output buffer.
    }

    priv fn _build_import_decl(self, spec: *ImportSpec, vis: VisibilityKind) -> unsafe *ImportDecl {
        var unsafe *id = ImportDecl::create(self._ctx, spec->range, spec->kind)

        var segs: kairo::std::StackBuf<Token, 8>
        for var i: usize = 0; i < spec->segments.size(); ++i {
            segs.push_back(spec->segments[i])
        }

        id->path_segments.from_buf_pp(segs.data(), (segs.size() as usize), self._ctx)
        id->last_seg_is_macro = spec->last_seg_is_macro
        id->is_wildcard       = spec->is_wildcard

        if spec->has_items {
            var items: kairo::std::StackBuf<ImportItem, 8>
            for var i: usize = 0; i < spec->items.size(); ++i {
                var *s                                  = &spec->items[i]
                var item                                = ImportItem{}
                var sub: kairo::std::StackBuf<Token, 4>
                for var j: usize = 0; j < s->sub_path.size(); ++j {
                    sub.push_back(s->sub_path[j])
                }

                item.sub_path.from_buf_pp(sub.data(), (sub.size() as usize), self._ctx)
                item.alias       = s->alias
                item.has_alias   = s->has_alias
                item.is_wildcard = s->is_wildcard
                item.is_macro    = s->is_macro
                item.range       = s->range
                items.push_back(item)
            }

            id->items.from_buf_pp(items.data(), (items.size() as usize), self._ctx)
            id->has_items = true
        }

        id->alias     = spec->alias
        id->has_alias = spec->has_alias
        id->set_visibility(vis, spec->range)
        id->range = spec->range
        return id
    }

    /// C when the parser's table (Statements::ffi_lang_of) says C, so
    /// `ffi "C"` is C here too; anything else -> Cpp. The parser owns the
    /// classification's diagnostic; the PP only needs enough to make
    /// has_ffi_linkage() true and to carry the language to codegen.
    priv fn _ffi_lang_kind(self, lang_tok: Token) -> LinkageKind {
        var        tt = TokenText::resolve(lang_tok, self._tcm)
        var unsafe *s = tt.get_text()
        if ffi_lang_of_literal(*s) == FFILang::C {
            return LinkageKind::C
        }

        return LinkageKind::Cpp
    }

    //  Macro definitions

    priv fn _handle_macro_def(self, vis: VisibilityKind) {
        var _t = TimeRegion("MacroDef")

        var kw = self._src->next() // `macro`

        // proc macro `macro @name` copy through, not ours
        if self._src->peek(0).kind == TokenKind::OpAt {
            self._emit(kw)
            return // remaining @-macro tokens flow to output via the walk
        }

        var cur = self._cursor()
        var hdr = cur.macro_header() // shared grammar
        if !hdr.ok {
            self._recover_to_terminator()
            return
        }

        // builtin names are reserved: dispatch checks builtins before user
        // macros, so this definition could never fire. Reject loudly instead
        // of letting the builtin silently hijack every call site.
        var def_name = TokenText::spelling(hdr.name, self._tcm)
        if self._is_builtin_name(def_name) {
            self._diag->report(
                DiagCode(DiagID::R014E),
                hdr.name.range.start,
                f"macro '{def_name}!' redefines a compiler builtin; builtin names are reserved",
            ).first(hdr.name.range)->emit()

            // discard the balanced body so it doesn't leak into the output
            // stream; _recover_to_terminator stops at newlines and would
            // spill multi-line bodies.
            if self._src->peek(0).kind == TokenKind::OpLBrace {
                self._src->next() // `{`
                var d: i32 = 1
                while !self._src->at_eof() && d > 0 {
                    var t = self._src->next()
                    if t.kind == TokenKind::OpLBrace {
                        d += 1
                    }

                    if t.kind == TokenKind::OpRBrace {
                        d -= 1
                    }
                }
            } else {
                self._recover_to_terminator()
            }

            return
        }

        if self._src->peek(0).kind != TokenKind::OpLBrace {
            self._diag->report(
                DiagCode(DiagID::S038E),
                hdr.name.range.start,
                "expected '{' for macro body",
            ).first(hdr.name.range)->emit()
            return
        }

        var lbrace = self._src->next().range // `{`

        var unsafe *storage = unsafe (@create TokenBuffer<512>() as unsafe *TokenBuffer<512>)
        var depth:       i32 = 1
        var seen_content     = false

        while !self._src->at_eof() {
            var t = self._src->next()
            if t.kind == TokenKind::OpLBrace {
                depth += 1
            }

            if t.kind == TokenKind::OpRBrace {
                depth -= 1
                if depth == 0 {
                    break
                }
            }

            if t.kind == TokenKind::KwImport || t.kind == TokenKind::KwMacro {
                self._diag->report(
                    DiagCode(DiagID::R012E),
                    t.range.start,
                    "'import' and 'macro' are not allowed inside a token macro body",
                ).first(t.range)->emit()
            }

            if !seen_content && t.kind == TokenKind::TkNewLine { // leading trim
                continue
            }

            seen_content = true
            storage->append(t)
        }

        if depth != 0 {
            self._diag->report(
                DiagCode(DiagID::S039E),
                lbrace.start,
                "unmatched '{' in macro body",
            ).first(lbrace)->emit()
            @destroy unsafe (storage as *TokenBuffer<512>)
            return
        }

        // trim edge newlines (THE newline fix)
        while storage->size() > 0
            && storage->get(storage->size() - 1)->kind == TokenKind::TkNewLine {
            storage->pop_back()
        }

        var lead: usize = 0
        while lead < storage->size() && storage->get(lead)->kind == TokenKind::TkNewLine {
            lead += 1
        }

        if lead > 0 {
            var unsafe *trimmed = unsafe (@create TokenBuffer<512>() as unsafe *TokenBuffer<512>)
            for var i: usize = lead; i < storage->size(); ++i {
                trimmed->append(*storage->get(i))
            }

            @destroy unsafe (storage as *TokenBuffer<512>)
            storage = trimmed
        }

        var body_len = (storage->size() as u32)

        // params + defaults appended after body
        var specs:      kairo::std::StackBuf<MacroParamSpec, 4>
        var is_variadic                                         = false
        for var i: usize = 0; i < hdr.params.size(); ++i {
            var *hp = &hdr.params[i]
            var sp  = MacroParamSpec{}
            sp.name     = hp->name
            sp.variadic = hp->variadic
            if hp->variadic != 0 {
                is_variadic = true
            }

            if hp->has_default {
                sp.has_default = true
                sp.default_off = (storage->size() as u32)
                for var j: usize = 0; j < hp->default_toks.size(); ++j {
                    storage->append(hp->default_toks[j])
                }

                sp.default_len = (storage->size() as u32) - sp.default_off
            }

            specs.push_back(sp)
        }

        if self._src->peek(0).kind == TokenKind::OpSemicolon {
            self._src->next()
        }

        // node into TU
        var unsafe *decl = MacroDecl::create(
            self._ctx,
            kw.range | lbrace,
            hdr.name,
        )

        decl->params_spec.from_buf_pp(specs.data(), (specs.size() as usize), self._ctx)
        decl->accepts_params = hdr.accepts_params
        decl->is_variadic    = is_variadic

        if body_len > 0 {
            decl->body_span = storage->get(0)->range | storage->get(
                (body_len as usize) - 1,
            )->range
        }

        decl->set_visibility(vis, kw.range | lbrace)
        self._tu->macros.push(decl)

        var unsafe *entry = unsafe (@create MacroEntry() as unsafe *MacroEntry)
        entry->decl     = decl
        entry->storage  = storage
        entry->body_len = body_len
        entry->name_sym = self._sym->intern(
            TokenText::spelling(hdr.name, self._tcm),
        )

        entry->scope      = *self._tracker->current_scope() // the entry keeps its own copy
        entry->source_fid = self._fid
        entry->visibility = vis

        var fresh = true
        if self._in_block() {
            // One name, one macro, from the file's scope inward: a block's
            // macro may not take the name of one an enclosing block or the
            // enclosing module of this file defines.
            fresh = self._block_macro(entry->name_sym) == &null
                && self._macros->find_same_fid(
                    entry->scope,
                    entry->name_sym,
                    self._fid,
                ) == &null

            self._block_owned.push(entry)
            if fresh {
                var bm = Self::BlockMacro{}
                bm.entry = entry
                bm.depth = self._block_depth()
                self._block_macros.push(bm)
            }
        } else {
            fresh = self._macros->register_macro(entry)
        }

        if !fresh {
            self._diag->report(
                DiagCode(DiagID::S040E),
                hdr.name.range.start,
                f"duplicate macro '{TokenText::spelling(hdr.name, self._tcm)}!' in this scope",
            ).first(hdr.name.range)->emit()
        }

        // NOTHING emitted.
    }

    //  Invocation detection + expansion
    //  _detect_invocation: PORT of MacroExpander::detect_invocation, retargeted
    //  to peeks on _src. Pattern unchanged: ident (:: ident)* ! ( ... )?.
    //  Critical difference: it must NOT consume until `found` is certain, then
    //  consume exactly the invocation. Because args need to be captured into a
    //  scratch buffer for pre-expansion, detection also copies the raw arg
    //  tokens (between balanced parens) into inv.arg_toks.

    struct InvocationInfo {
        var qualified:    ModulePath
        var chain:        [SymbolID]  ///< frame names live at detection
        var parent_chain: [InvokeHop] ///< full origin chain live at detection;
        ///  threaded into push_splice for
        ///  THIS invocation's own result
        ///  (see TokenSource::current_chain)
        var arg_toks:     [Token] ///< raw tokens between ( ), balanced
        var name:         Token
        var name_sym:     SymbolID    = 0
        var range:        SourceRange = SourceRange::invalid()
        var origin_site:  SourceRange = SourceRange::invalid() ///< outermost invoke loc at detection
        var is_qualified: bool        = false
        var found:        bool        = false
        var has_args:     bool        = false
    }

    priv fn _detect_invocation(self) -> Self::InvocationInfo {
        // Sampled: runs on EVERY token and almost always answers no, so it is
        // both hot and a plausible bottleneck   exactly the case an unsampled
        // scope cannot measure without becoming the cost it is measuring.
        var _t = TimeSampled(self._t_detect, 64, unsafe &self._c_detect)

        var result = Self::InvocationInfo()

        result.origin_site = self._src->bottom_invoke_loc()
        self._src->snapshot_chain(&result.chain)
        self._src->current_chain(&result.parent_chain)

        if self._src->peek(0).kind != TokenKind::LitIdentifier {
            return result
        }

        /// ## try to parse a path: ident (:: ident)*
        var path_toks: [Token]
        path_toks.push(self._src->peek(0))

        var n: usize = 1
        while true {
            if self._src->peek(n).kind != TokenKind::OpColonColon {
                break
            }

            if self._src->peek(n + 1).kind != TokenKind::LitIdentifier {
                break
            }

            path_toks.push(self._src->peek(n + 1))
            n += 2
        }

        /// ## expect `!` after the last identifier
        if self._src->peek(n).kind != TokenKind::OpExclaim {
            return result
        }

        var bang_offset = n

        var name_tok = path_toks[path_toks.size() - 1]

        // label!/jump!/unwrap! are PARSER intrinsics, not macros: leave the
        // raw tokens in the stream untouched; the parser owns the grammar
        // (`label` `!` `(` ident `)` in StmtParse, `unwrap` `!` `(` expr `)`
        // in ExprParse, whose operand must stay an ordinary expression).
        // So are the type facts (Compiler/Spec/Eval.md#deferred-conditions): their operand is a TYPE,
        // which only the parser can tell from a value.
        // Qualified forms (`a::label!`) are NOT intrinsics and still resolve
        // as ordinary macros.
        if path_toks.size() == 1 {
            var sp = TokenText::spelling(name_tok, self._tcm)
            if sp == LangIntrinsics::label()
                || sp == LangIntrinsics::jump()
                || sp == LangIntrinsics::unwrap() {
                return result
            }

            if sp == LangIntrinsics::is_trivially_copyable()
                || sp == LangIntrinsics::is_trivially_destructible() {
                return result
            }

            // A `defined!` _builtin_defined already passed through raw.
            if sp == LangIntrinsics::defined()
                && self._defined_raw.contains(name_tok.range.start.raw() as u64) {
                return result
            }
        }

        result.found = true
        result.name  = name_tok
        result.name_sym = self._sym->intern(
            TokenText::spelling(name_tok, self._tcm),
        )

        if path_toks.size() > 1 {
            result.is_qualified = true
            result.qualified    = ModulePath()
            for var k: usize = 0; k + 1 < path_toks.size(); ++k {
                var seg = IdentifierToken()
                seg.token = &null // peeked copy, not a source-owned pointer
                seg.name = self._sym->intern(
                    TokenText::spelling(path_toks[k], self._tcm),
                )

                result.qualified.segments.push_back(seg)
            }
        }

        n = bang_offset + 1 // past `!`

        /// ## check for argument list `(` ... `)`
        var has_paren = self._src->peek(n).kind == TokenKind::OpLParen
        var total_consumed: usize

        if has_paren {
            result.has_args = true
            var depth:    i32 = 1
            var arg_start     = n + 1     // first token inside `(`
            var m             = arg_start
            while true {
                // Out of tokens: no invocation. Inside a splice the frame's end
                // is the end (cross-frame lookahead is refused), not TkEof.
                if self._src->peek_leaves_frame(m) {
                    result.found = false
                    return result
                }

                var t = self._src->peek(m)
                if t.kind == TokenKind::TkEof {
                    result.found = false
                    return result
                }

                if t.kind == TokenKind::OpLParen {
                    depth += 1
                }

                if t.kind == TokenKind::OpRParen {
                    depth -= 1
                    if depth == 0 {
                        break
                    }
                }

                m += 1
            }

            // m is the index of the matching `)`
            // The invocation's `( ... )` is a bracket like any other: a
            // newline in it terminates nothing, so it is not part of an
            // argument. Kept, it reached the expansion as a statement end
            // (`check!(x` newline `> 3, ...)` became `if (x` / `> 3)`), and
            // a call spelled over lines parsed where the same macro
            // invocation did not. Inside a `{ }` of an argument (a block or
            // closure body) the newlines still separate statements.
            var braces: i32 = 0
            for var k: usize = arg_start; k < m; ++k {
                var at = self._src->peek(k)
                if at.kind == TokenKind::OpLBrace {
                    braces += 1
                }

                if at.kind == TokenKind::OpRBrace && braces > 0 {
                    braces -= 1
                }

                if at.kind == TokenKind::TkNewLine && braces == 0 {
                    continue
                }

                result.arg_toks.push(at)
            }

            total_consumed = m + 1 // past `)`
        } else {
            total_consumed = bang_offset + 1 // just past `!`
        }

        result.range = self._src->peek(0).range | self._src->peek(
            total_consumed - 1,
        ).range

        /// ## commit: consume exactly what we detected
        for var k: usize = 0; k < total_consumed; ++k {
            self._src->next()
        }

        return result
    }

    priv fn _report_expand_err(self,
                               code:         DiagID,
                               inv:          unsafe *Self::InvocationInfo,
                               const msg:    string,
                               const note:   string = "expanded from here",
                               const remark: string = "") {
        var site = self._inv_site(inv)
        if !remark.is_empty() {
            if site.start.id != inv->range.start.id {
                self._diag->report(DiagCode(code), site.start, msg.copy()).first(
                    site,
                )->note(inv->range.start, note)->child_first(inv->range)->remark(
                    remark,
                )->emit()
                return
            }

            self._diag->report(DiagCode(code), site.start, msg.copy()).first(
                site,
            )->remark(remark)->emit()

            return
        }

        if site.start.id != inv->range.start.id {
            self._diag->report(DiagCode(code), site.start, msg.copy()).first(
                site,
            )->note(inv->range.start, note)->child_first(inv->range)->emit()
            return
        }

        self._diag->report(DiagCode(code), site.start, msg.copy()).first(site)->emit()

        return
    }

    priv fn _expand(self, inv: unsafe *Self::InvocationInfo) {
        if self._opts.macro_debug {
            // --cmacro-trace-depth caps how deep the log follows nested expansion;
            // 0 (default) is unlimited, matching every other --cmax-* knob's convention.
            var depth = self._src->depth()
            var within_trace_depth = self._opts.trace_depth <= 0
                || (depth as i32) <= self._opts.trace_depth

            var nm = self._sym_name(inv->name_sym)
            if within_trace_depth
                && (self._opts.macro_debug_filter.is_empty()
                    || nm == self._opts.macro_debug_filter) {
                // Straight to stderr, not the Logger: Logger::info is gated on -v,
                // which made --macro-debug print nothing on its own. The user
                // asked for this trace by name; it must not need a second flag.
                io::eprintln(
                    f"[macro-debug] expand '{nm}!' depth={depth} count={self._expansion_count}",
                )
            }
        }

        var unsafe *b = self._try_builtin(inv)
        if b != &null {
            self._push_splice(
                b,
                inv->name_sym,
                inv->range,
                unsafe &inv->parent_chain,
            )

            return
        }

        var unsafe *entry = self._resolve(*inv)
        if entry == &null {
            // `import lib::getter` then `getter!`: the import named the
            // macro without its `!`. Said at the import, with the
            // `!` as the fix.
            var hint = if (self._imports != &null) => (self._imports->bare_macro_import(
                           inv->name_sym,
                       ))
                       else => SourceRange()
            if hint.is_valid() {
                var nm   = self._sym_name(inv->name_sym)
                var site = self._inv_site(inv)
                var b = self._diag->report(
                    DiagCode(DiagID::R013E),
                    site.start,
                    f"unknown macro '{nm}!': its import names '{nm}' without the '!'",
                )

                b.first(site)
                b.note(
                    hint.start,
                    f"'{nm}' without '!' imports a declaration; a macro is imported as '{nm}!'",
                )->child_first(hint)
                b.insert(hint.end, "!", f"import the macro '{nm}!'")
                b.emit()
                self._emit_poison(inv)
                return
            }

            // In a branch only Sema can decide, the name is unknown only if
            // the branch is kept: Sema reports it then.
            if self._open_depth > 0 && self._tu != &null {
                var late = DeferredMacroError{}
                late.site    = self._inv_site(inv)
                late.name    = inv->name.range
                late.written = inv->range
                self._tu->deferred_macro_errors.push(late)
                self._emit_poison(inv)
                return
            }

            self._report_expand_err(
                DiagID::R013E,
                inv,
                f"unknown macro '{self._sym_name(inv->name_sym)}!' (macros must be defined or imported before use)",
            )

            self._emit_poison(inv)
            return
        }

        if entry->decl->accepts_params && !inv->has_args {
            self._report_expand_err(
                DiagID::R006E,
                inv,
                f"macro '{self._sym_name(inv->name_sym)}!' requires arguments; add '(...)'",
            )

            self._emit_poison(inv)
            return
        }

        if !entry->decl->accepts_params && inv->has_args {
            self._report_expand_err(
                DiagID::R007E,
                inv,
                f"macro '{self._sym_name(inv->name_sym)}!' is parameterless; remove '(...)'",
            )

            self._emit_poison(inv)
            return
        }

        if (self._src->depth() as i32) >= self._opts.max_depth {
            // Once per chain (keyed on the outermost invoke site); the poison
            // still goes out so the chain stops expanding here either way.
            var chain_key = inv->origin_site.start.raw()
            if self._depth_reported.insert(chain_key as u64).second {
                self._report_expand_err(
                    DiagID::R008E,
                    inv,
                    f"macro expansion depth limit ({self._opts.max_depth}) exceeded",
                    "expanded from here",
                    f"limit can be increased with --cmax-macro-depth=N",
                )
            }

            self._emit_poison(inv)
            return
        }

        if self._opts.max_expansions > 0 && self._expansion_count >= self._opts.max_expansions {
            self._report_expand_err(
                DiagID::R008E,
                inv,
                "macro expansion budget exhausted",
                "expanded from here",
                f"budget can be increased with --cmax-macro-expansions=N, current budget is {self._opts.max_expansions}",
            )

            self._emit_poison(inv)
            return
        }

        var cyclic = false
        for s in inv->chain {
            if s == entry->name_sym {
                cyclic = true
                break
            }
        }

        // `inv.chain` is the LIVE frame stack, and a tail-position invocation
        // outlives its parent: `ping!` ending in `pong!(x)` has its frame
        // exhausted and popped (by the depth() check above) before pong's
        // body is walked, so pong's `ping!` saw a stack without ping and the
        // pair expanded forever -- each hop copying a chain one longer, so
        // the budget took minutes to trip. The origin chain captured at
        // detection keeps every ancestor, popped or not.
        if !cyclic {
            for var i: usize = 0; i < inv->parent_chain.size(); ++i {
                if inv->parent_chain[i].name == entry->name_sym {
                    cyclic = true
                    break
                }
            }
        }

        if cyclic {
            self._report_expand_err(
                DiagID::R008E,
                inv,
                f"cyclic expansion of macro '{self._sym_name(inv->name_sym)}!'",
                "recursion occurs here, in the macro body",
                "a macro cannot invoke itself; recursion is not supported in token macros",
            )

            self._emit_poison(inv)
            return
        }

        self._expansion_count += 1

        //    ARGUMENTS PRE-EXPAND IN CALLER CONTEXT (before pushing the frame)
        //    Each arg is a token run; expand invocations within it against the
        //    CURRENT chain by recursively running a nested expansion over a
        //    temporary TokenSource seeded with the arg tokens. Because the
        //    callee is NOT yet on the stack, square!(square!(x)) is legal.
        var unsafe *bound = self._bind_and_substitute(entry, inv)
        if bound == &null {
            return
        }

        //    push; the walk re-enters the spliced body next loop turn, and any
        //    nested invocations inside it are found by _detect_invocation again.
        self._push_splice(
            bound,
            entry->name_sym,
            inv->range,
            unsafe &inv->parent_chain,
        )
    }

    priv fn _push_splice(self,
                         buf:          unsafe *(TokenBuffer<512>),
                         name:         SymbolID,
                         loc:          SourceRange,
                         parent_chain: unsafe *[InvokeHop]) {
        self._splices.push(buf) // own it for the run's lifetime
        self._src->push_splice(buf, name, loc, *parent_chain)
    }

    priv fn _buf_has_invocation(self, b: unsafe *(TokenBuffer<512>)) -> bool {
        for var i: usize = 0; i + 1 < b->size(); ++i {
            if b->get(i)->kind == TokenKind::LitIdentifier
                && b->get(i + 1)->kind == TokenKind::OpExclaim {
                return true
            }
        }

        return false
    }

    priv fn _expand_buffer(self,
                           src_buf:      unsafe *(TokenBuffer<512>),
                           parent_chain: unsafe *[InvokeHop]) -> unsafe *(TokenBuffer<512>) {
        // The sink is redirected for this expansion only: restored on every
        // way out, so a nested expansion hands its caller's sink back intact.
        var unsafe *out   = unsafe (@create TokenBuffer<512>() as unsafe *TokenBuffer<512>)
        var unsafe *saved = self._sink
        self._sink = out
        finally {
            self._sink = saved
        }

        var d0 = self._src->depth()
        self._src->push_splice(
            src_buf,
            0,
            SourceRange::invalid(),
            *parent_chain,
        )

        while self._src->depth() > d0 {
            var t = self._src->peek(0)
            if t.kind == TokenKind::TkEof {
                break
            }

            var inv = self._detect_invocation()
            if inv.found {
                self._expand(unsafe &inv)
                continue
            }

            var chain:   [InvokeHop]
            var next_tok             = self._src->next_with_origin(&chain)
            self._emit(next_tok, unsafe &chain)
        }

        return out
    }

    priv fn _bind_and_substitute(self,
                                 e:   unsafe *MacroEntry,
                                 inv: unsafe *Self::InvocationInfo) -> unsafe *(TokenBuffer<512>) {
        // Args pre-expand in CALLER context: the callee's frame is not on the
        // stack yet, so square!(square!(x)) is legal. Cycle detection then only
        // fires on true body-recursion (boom!).
        // Split FIRST, then expand each arg: commas produced by expansion do
        // not change the call's arity (C semantics). Value-position builtins
        // deliberately differ see _parse_expanded_builtin_arguments.
        var args = self._parse_builtin_arguments(inv) // splits on top-level commas

        for var k: usize = 0; k < args.size(); ++k {
            if self._buf_has_invocation(args[k]) {
                var unsafe *ex = self._expand_buffer(
                    args[k],
                    unsafe &inv->parent_chain,
                )

                if args[k] != &null {
                    @destroy unsafe (args[k] as *TokenBuffer<512>)
                }

                args[k] = ex
            }
        }

        var *params             = &e->decl->params_spec
        var required:     usize = 0
        var has_variadic        = false
        var variadic_idx: usize = 0
        for var k: usize = 0; k < params->size(); ++k {
            var unsafe *p = params->get(k)
            if p->variadic != 0 {
                has_variadic = true
                variadic_idx = k
                break
            }

            if !p->has_default {
                required += 1
            }
        }

        var non_variadic_count = if has_variadic => variadic_idx else => params->size()

        if args.size() < required {
            self._report_expand_err(
                DiagID::R006E,
                inv,
                f"macro '{self._sym_name(inv->name_sym)}!' expects at least {required} arguments, got {args.size()}",
            )

            return &null
        }

        if !has_variadic && args.size() > params->size() {
            self._report_expand_err(
                DiagID::R006E,
                inv,
                f"macro '{self._sym_name(inv->name_sym)}!' expects at most {params->size()} arguments, got {args.size()}",
            )

            return &null
        }

        // One per expansion, a handful of parameters: inline buckets, no
        // heap node per parameter. Keyed `sym as u64`, clear of the two
        // reserved keys a u32 key would take from the SymbolID range.
        var bindings = llvm::SmallDenseMap<u64, unsafe *(TokenBuffer<512>), 8>()
        for var k: usize = 0; k < non_variadic_count; ++k {
            var unsafe *p = params->get(k)
            var name_sym = self._sym->intern(
                TokenText::spelling(p->name, self._tcm),
            )

            if k < args.size() {
                bindings[name_sym as u64] = args[k]
            } else if p->has_default {
                var unsafe *dflt = unsafe (@create TokenBuffer<512>() as unsafe *TokenBuffer<512>)
                for var d: usize = ((p->default_off) as usize); d < ((p->default_off) as usize) + (p->default_len as usize); ++d {
                    dflt->append(*e->storage->get(d))
                }

                bindings[name_sym as u64] = dflt
                self._splices.push(dflt) // owner; freed in op finally (leak fix)
            }
        }

        var variadic_name:     SymbolID                     = 0
        var variadic_bindings: [unsafe *(TokenBuffer<512>)]
        if has_variadic {
            var unsafe *vp = params->get(variadic_idx)
            variadic_name = self._sym->intern(
                TokenText::spelling(vp->name, self._tcm),
            )

            for var k: usize = non_variadic_count; k < args.size(); ++k {
                variadic_bindings.push(args[k])
            }
        }

        // Where a rewritten f-string from another file's body is anchored
        // (_subst_fstring): the outermost invocation, which this file wrote.
        var anchor = if (inv->origin_site.is_valid()) => (inv->origin_site) else => inv->range
        return self._substitute_body(
            e,
            unsafe &bindings,
            variadic_name,
            variadic_bindings,
            inv->range,
            anchor,
        )
    }

    /// Body substitution. Pack expansion is POSTFIX, mirroring expression- and
    /// type-level `PackExpansionExpr` (declaration is prefix `...xs`, use is
    /// postfix the same split C++ makes):
    ///
    ///   BARE SPLAT     `xs...`          -> a, b, c              (comma-joined)
    ///   PATTERN SPLAT  `( pattern )...` -> pat(a), pat(b), ...  (comma-joined)
    ///
    /// A pattern splat replicates the parenthesized token run once per pack
    /// element, substituting the pack name with that element (and ordinary
    /// parameter bindings as usual). The parentheses are grouping syntax and
    /// are NOT emitted. A `( ... )...` whose pattern does not mention the pack
    /// name is not ours it passes through verbatim as target-language pack
    /// expansion, as does `ident...` for any non-pack identifier. Expansion is
    /// single-level: a nested `...` inside a pattern is emitted verbatim.
    ///
    /// An empty pack consumes the whole splat and emits nothing.
    priv fn _substitute_body(
        self,
        e:                       unsafe *MacroEntry,
        bindings:                unsafe *llvm::SmallDenseMap<u64, unsafe *(TokenBuffer<512>), 8>,
        variadic_name:           SymbolID,
        const variadic_bindings: [unsafe *(TokenBuffer<512>)],
        invoke_loc:              SourceRange,
        anchor:                  SourceRange,
    ) -> unsafe *(TokenBuffer<512>) {
        var unsafe *output       = unsafe (@create TokenBuffer<512>() as unsafe *TokenBuffer<512>)
        var        i:      usize = 0
        while i < ((e->body_len) as usize) {
            var unsafe *tok = e->storage->get(i)

            /// ### pattern splat: `(` pattern `)` `...`
            if tok->kind == TokenKind::OpLParen && variadic_name != 0 {
                var close = self._find_matching_rparen(e, i)
                if close != 0
                    && close + 1 < (e->body_len as usize)
                    && e->storage->get(close + 1)->kind == TokenKind::OpEllipsis
                    && self._pattern_mentions_pack(
                        e,
                        i + 1,
                        close,
                        variadic_name,
                    ) {
                    for var k: usize = 0; k < variadic_bindings.size(); ++k {
                        if k > 0 {
                            self._append_builtin_comma(output, invoke_loc)
                        }

                        self._emit_pattern_instance(
                            output,
                            e,
                            i + 1,
                            close,
                            bindings,
                            variadic_name,
                            (variadic_bindings)[k],
                            anchor,
                        )
                    }

                    i = close + 2
                    continue
                }

                // not a pack pattern: plain parenthesized tokens, fall through
            }

            if tok->kind == TokenKind::LitIdentifier {
                var tok_name = self._sym->intern(
                    TokenText::spelling(*tok, self._tcm),
                )

                /// ### bare splat: `xs` `...`
                if tok_name == variadic_name
                    && i + 1 < (e->body_len as usize)
                    && e->storage->get(i + 1)->kind == TokenKind::OpEllipsis {
                    for var k: usize = 0; k < variadic_bindings.size(); ++k {
                        if k > 0 {
                            self._append_builtin_comma(output, invoke_loc)
                        }

                        var unsafe *span = (variadic_bindings)[k]
                        for var j: usize = 0; j < span->size(); ++j {
                            output->append(*span->get(j))
                        }
                    }

                    i += 2
                    continue
                }

                var bit = bindings->find(tok_name as u64)
                if bit != bindings->end() {
                    var unsafe *bound = bit->second
                    for var j: usize = 0; j < bound->size(); ++j {
                        output->append(*bound->get(j))
                    }

                    i += 1
                    continue
                }
            }

            output->append(
                self._subst_fstring(
                    *tok,
                    *bindings,
                    variadic_name,
                    &null,
                    anchor,
                ),
            )

            i += 1
        }

        return output
    }

    /// index of the `)` matching the `(` at `open`, or 0 if unbalanced
    /// (0 can never be a valid answer: the match is always past `open`).
    priv fn _find_matching_rparen(self, e: unsafe *MacroEntry, open: usize) -> usize {
        var depth: i32 = 0
        for var i: usize = open; i < ((e->body_len) as usize); ++i {
            var k = e->storage->get(i)->kind
            if k == TokenKind::OpLParen {
                depth += 1
            }

            if k == TokenKind::OpRParen {
                depth -= 1
                if depth == 0 {
                    return i
                }
            }
        }

        return 0
    }

    /// does the token run [lo, hi) mention the pack name?
    priv fn _pattern_mentions_pack(self,
                                   e:             unsafe *MacroEntry,
                                   lo:            usize,
                                   hi:            usize,
                                   variadic_name: SymbolID) -> bool {
        for var i: usize = lo; i < hi; ++i {
            var unsafe *t = e->storage->get(i)
            if t->kind != TokenKind::LitIdentifier {
                continue
            }

            if self._sym->intern(TokenText::spelling(*t, self._tcm)) == variadic_name {
                return true
            }
        }

        return false
    }

    /// emits one instance of the pattern token run [lo, hi): the pack name is
    /// replaced by `element`, ordinary parameter bindings substitute as usual,
    /// everything else is copied verbatim.
    priv fn _emit_pattern_instance(
        self,
        output:        unsafe *(TokenBuffer<512>),
        e:             unsafe *MacroEntry,
        lo:            usize,
        hi:            usize,
        bindings:      unsafe *llvm::SmallDenseMap<u64, unsafe *(TokenBuffer<512>), 8>,
        variadic_name: SymbolID,
        element:       unsafe *(TokenBuffer<512>),
        anchor:        SourceRange,
    ) {
        for var i: usize = lo; i < hi; ++i {
            var unsafe *tok = e->storage->get(i)

            if tok->kind == TokenKind::LitIdentifier {
                var tok_name = self._sym->intern(
                    TokenText::spelling(*tok, self._tcm),
                )

                if tok_name == variadic_name {
                    for var j: usize = 0; j < element->size(); ++j {
                        output->append(*element->get(j))
                    }

                    continue
                }

                var bit = bindings->find(tok_name as u64)
                if bit != bindings->end() {
                    var unsafe *bound = bit->second
                    for var j: usize = 0; j < bound->size(); ++j {
                        output->append(*bound->get(j))
                    }

                    continue
                }
            }

            output->append(
                self._subst_fstring(
                    *tok,
                    *bindings,
                    variadic_name,
                    element,
                    anchor,
                ),
            )
        }
    }

    /// # f-string holes
    ///
    ///   An f-string is ONE token: its holes are token buffers the lexer kept
    ///   on the literal's StringData, which the walk never visits. So neither
    ///   a macro's parameter written in a hole (`macro g!(x) { f"v={x}" }`)
    ///   nor an invocation in one (`f"v={m!}"`) was ever seen: the parser met
    ///   the raw `x` / `m` (R020E). Two steps, in the order the walk reaches
    ///   them. _subst_fstring rewrites a body's f-string per expansion, with
    ///   the parameters bound; _expand_fstring, at emission, runs each hole
    ///   through the walk like an argument, which expands its invocations and
    ///   gives a macro body's hole tokens their origin chain as the body's
    ///   other tokens get theirs.

    /// `tok`'s StringData when it is an f-string with holes, read from the
    /// table of the file that lexed it (`tbl` becomes that table); null
    /// otherwise. Adjacent literals join whatever their prefixes, so
    /// the holes can sit in any segment of the chain: `"a" f"{x}"` is one.
    priv fn _fstring_data(self,
                          tok:        Token,
                          @inout tbl: unsafe *ImmediateTable) -> unsafe *Immediate::StringData {
        if tok.kind != TokenKind::LitString {
            return &null
        }

        tbl = self._tcm->get_imm_table_for_token(tok)
        if tbl == &null {
            return &null
        }

        var unsafe *d   = tbl->get<Immediate::StringData>(tok.imm)
        var unsafe *seg = d
        while seg != &null {
            if seg->exprs.size() > 0 && seg->prefix_kind.has(Immediate::TextPrefixKind::Format) {
                return d
            }

            seg = next_string_segment(tbl, seg)
        }

        return &null
    }

    /// `tok` is a string literal the lexer made from source (its range is
    /// its spelling), not one with owned text (file!, stringify!).
    priv fn _lexed_string(self, tok: Token) -> bool {
        var unsafe *tbl = self._tcm->get_imm_table_for_token(tok)
        if tbl == &null {
            return false
        }

        var unsafe *d = tbl->get<Immediate::StringData>(tok.imm)
        return d != &null && !d->has_owned_text()
    }

    /// `tok` is a string literal with an adjacent one chained after it.
    priv fn _chained_string(self, tok: Token) -> bool {
        var unsafe *tbl = self._tcm->get_imm_table_for_token(tok)
        if tbl == &null {
            return false
        }

        var unsafe *d = tbl->get<Immediate::StringData>(tok.imm)
        return d != &null && d->next != u32::MAX
    }

    /// A fresh slot in this file's table with `d`'s text and hole specs and
    /// no hole buffers yet: the caller pushes one per hole. Fresh, never the
    /// lexed slot written over: a body's literal is shared by every
    /// expansion, and the lexed slot frees its own buffers. Its `next` is
    /// unset; the caller links the copy of the chain.
    priv fn _fstring_slot(self, d: unsafe *Immediate::StringData) -> u32 {
        var        idx = self._imm->create<Immediate::StringData>()
        var unsafe *nd = self._imm->get<Immediate::StringData>(idx)
        nd->body        = d->body
        nd->prefix      = d->prefix
        nd->suffix      = d->suffix
        nd->prefix_kind = d->prefix_kind
        nd->owned_ptr   = d->owned_ptr
        nd->owned_len   = d->owned_len
        nd->next        = u32::MAX
        for var i: usize = 0; i < d->holes.size(); ++i {
            nd->holes.push_back(d->holes[i])
        }

        return idx
    }

    /// Every segment of `d`'s chain copied into this file's table and
    /// linked, in order; returns the first copy. The caller fills each
    /// copy's hole buffers (segs[i] is the source of copies[i]). The whole
    /// chain is copied, holes or not: a copy's `next` must index THIS table,
    /// and the source chain may live in another file's.
    priv fn _fstring_chain(self,
                           d:      unsafe *Immediate::StringData,
                           tbl:    unsafe *ImmediateTable,
                           segs:   unsafe *[unsafe *Immediate::StringData],
                           copies: unsafe *[u32]) -> u32 {
        var unsafe *seg = d
        while seg != &null {
            var idx = self._fstring_slot(seg)
            if copies->size() > 0 {
                self._imm->get<Immediate::StringData>(
                    (*copies)[copies->size() - 1],
                )->next = idx
            }

            segs->push(seg)
            copies->push(idx)
            seg = next_string_segment(tbl, seg)
        }

        return (*copies)[0]
    }

    /// `tok` from a macro body: an f-string with holes comes back as a copy
    /// whose holes have the parameters substituted (a pack's name, inside a
    /// pattern splat, by `element`); any other token unchanged. The copy
    /// lives in THIS file's table, so a literal from another file's body is
    /// re-anchored at `anchor`, the invocation this file wrote: the parser
    /// finds a string's table from where it was written (ASTContext::
    /// get_payload_table), and the copy was written here. Its hole tokens
    /// stay raw; _expand_fstring wraps them on the way out.
    priv fn _subst_fstring(self,
                           tok:            Token,
                           const bindings: llvm::SmallDenseMap<u64, unsafe *(TokenBuffer<512>), 8>,
                           variadic_name:  SymbolID,
                           element:        unsafe *(TokenBuffer<512>),
                           anchor:         SourceRange) -> Token {
        var        tbl: unsafe *ImmediateTable = &null
        var unsafe *d                          = self._fstring_data(tok, &tbl)
        if d == &null {
            return tok
        }

        var same_tbl                                 = tbl == self._imm
        var segs:    [unsafe *Immediate::StringData]
        var copies:  [u32]
        var idx = self._fstring_chain(d, tbl, unsafe &segs, unsafe &copies)
        for var s: usize = 0; s < segs.size(); ++s {
            var unsafe *sd = segs[s]
            var unsafe *nd = self._imm->get<Immediate::StringData>(copies[s])
            for var h: usize = 0; h < sd->exprs.size(); ++h {
                var unsafe *src = sd->exprs[h].0
                var        rng  = sd->exprs[h].1
                var unsafe *nb  = unsafe (@create TokenBuffer<16>() as unsafe *TokenBuffer<16>)
                if src != &null {
                    for var k: usize = 0; k < src->size(); ++k {
                        var unsafe *ht = src->get(k)
                        if ht->kind == TokenKind::LitIdentifier {
                            var nm = self._sym->intern(
                                TokenText::spelling(*ht, self._tcm),
                            )

                            if element != &null && nm == variadic_name {
                                for var j: usize = 0; j < element->size(); ++j {
                                    nb->append(*element->get(j))
                                }

                                continue
                            }

                            var bit = bindings.find(nm as u64)
                            if bit != bindings.end() {
                                var unsafe *bound = bit->second
                                for var j: usize = 0; j < bound->size(); ++j {
                                    nb->append(*bound->get(j))
                                }

                                continue
                            }
                        }

                        nb->append(*ht)
                    }
                }

                nd->exprs.push_back((nb, rng))
            }
        }

        var out = tok
        out.imm = idx
        if !same_tbl && anchor.is_valid() {
            out.range = anchor
        }

        return out
    }

    /// `t`, about to be emitted with origin chain `chain`: an f-string of
    /// this file's whose holes need the walk comes back as a copy with each
    /// hole walked (_expand_buffer: invocations expanded, every token given
    /// `chain`); any other token unchanged. A hole needs it when it holds
    /// an invocation, or when the string came out of a macro body: its hole
    /// tokens are the body's, raw, and a body token another file wrote reads
    /// against that file's tables only once wrapped. A string another file
    /// lexed that no body rewrote (an argument from a macro of that file)
    /// is left to the parser (ASTContext::wrap_foreign_token).
    priv fn _expand_fstring(self, t: Token, chain: unsafe *[InvokeHop]) -> Token {
        var        tbl: unsafe *ImmediateTable = &null
        var unsafe *d                          = self._fstring_data(t, &tbl)
        if d == &null {
            return t
        }

        if tbl != self._imm {
            return t
        }

        // A hole's tokens reach the parser without passing _emit: an illegal
        // run in one is reported and handed on as a name here, once (the
        // token is a name after the first time).
        var unsafe *seg = d
        while seg != &null {
            for var h: usize = 0; h < seg->exprs.size(); ++h {
                var unsafe *src = seg->exprs[h].0
                for var k: usize = 0; src != &null && k < src->size(); ++k {
                    var unsafe *tk = src->get(k)
                    if tk->kind == TokenKind::TkUnknown && tk->imm != u32::MAX {
                        *tk = self._illegal_chars(*tk)
                    }
                }
            }

            seg = next_string_segment(tbl, seg)
        }

        var        from_body = chain != &null && chain->size() > 0
        var        any       = from_body
        var unsafe *scan     = d
        while scan != &null && !any {
            for var h: usize = 0; h < scan->exprs.size() && !any; ++h {
                var unsafe *src = scan->exprs[h].0
                if src == &null {
                    continue
                }

                for var k: usize = 0; k + 1 < src->size(); ++k {
                    if src->get(k)->kind == TokenKind::LitIdentifier
                        && src->get(k + 1)->kind == TokenKind::OpExclaim {
                        any = true
                        break
                    }
                }
            }

            scan = next_string_segment(tbl, scan)
        }

        if !any {
            return t
        }

        var empty: [InvokeHop]
        var unsafe *pc = if (chain != &null) => (chain) else => unsafe &empty
        var segs:   [unsafe *Immediate::StringData]
        var copies: [u32]
        var idx = self._fstring_chain(d, tbl, unsafe &segs, unsafe &copies)
        for var s: usize = 0; s < segs.size(); ++s {
            var unsafe *sd = segs[s]
            for var h: usize = 0; h < sd->exprs.size(); ++h {
                var unsafe *src = sd->exprs[h].0
                var        rng  = sd->exprs[h].1
                var unsafe *nb  = unsafe (@create TokenBuffer<16>() as unsafe *TokenBuffer<16>)
                if src != &null {
                    // An EOF in the run would end _expand_buffer's walk with its
                    // frame still pushed; the hole's parse needs none.
                    var unsafe *run = unsafe (@create TokenBuffer<512>() as unsafe *TokenBuffer<512>)
                    for var k: usize = 0; k < src->size(); ++k {
                        if src->get(k)->kind != TokenKind::TkEof {
                            run->append(*src->get(k))
                        }
                    }

                    var unsafe *ex = self._expand_buffer(run, pc)
                    for var k: usize = 0; k < ex->size(); ++k {
                        nb->append(*ex->get(k))
                    }

                    self._splices.push(run) // owned for the run, as a splice frame's tokens.
                    if ex != &null {
                        @destroy unsafe (ex as *TokenBuffer<512>)
                    }
                }

                // re-read: the walk above may have grown this table.
                self._imm->get<Immediate::StringData>(copies[s])->exprs.push_back(
                    (nb, rng),
                )
            }
        }

        var out = t
        out.imm = idx
        return out
    }

    priv fn make_int_token(self, value: u64, range: SourceRange) -> Token {
        var tok = Token()
        tok.kind  = TokenKind::LitInt
        tok.range = range
        if self._imm != &null {
            var        idx   = self._imm->create<Immediate::IntData>()
            var unsafe *data = self._imm->get<Immediate::IntData>(idx)
            data->value_lo = value
            data->value_hi = 0
            data->bits     = 32
            data->base     = 10
            data->assign_flags(FlagSet<Immediate::IntFlags, u8>())
            data->body = range
            tok.imm    = idx
        }

        return tok
    }

    priv fn _punct(self, k: TokenKind, range: SourceRange) -> Token {
        var tok = Token()
        tok.kind  = k
        tok.range = range
        return tok
    }

    priv fn make_ident_token(self, const name: string, range: SourceRange) -> Token {
        var tok = Token()
        tok.kind  = TokenKind::LitIdentifier
        tok.range = range
        if self._imm != &null {
            tok.imm = self._imm->intern_ident_copy(name)
        }

        return tok
    }

    //  Builtins

    priv fn _try_builtin(self, invoke: unsafe *Self::InvocationInfo) -> unsafe *(TokenBuffer<512>) {
        // Builtins are unqualified. `foo::count!` must resolve as an ordinary
        // macro instead of being hijacked by the builtin dispatcher.
        if invoke->is_qualified {
            return &null
        }

        var name = self._sym_name(invoke->name_sym)

        // source location
        if name == LangMacros::file() {
            return self._builtin_file(invoke)
        }

        if name == LangMacros::line() {
            return self._builtin_line(invoke)
        }

        if name == LangMacros::column() {
            return self._builtin_column(invoke)
        }

        if name == LangMacros::module_path() {
            return self._builtin_module_path(invoke)
        }

        // argument manipulation
        if name == LangMacros::count() {
            return self._builtin_count(invoke)
        }

        if name == LangMacros::first() {
            return self._builtin_first(invoke)
        }

        if name == LangMacros::last() {
            return self._builtin_last(invoke)
        }

        if name == LangMacros::rest() {
            return self._builtin_rest(invoke)
        }

        if name == LangMacros::butlast() {
            return self._builtin_butlast(invoke)
        }

        // token manipulation
        if name == LangMacros::paste() {
            return self._builtin_paste(invoke)
        }

        if name == LangMacros::stringify() {
            return self._builtin_stringify(invoke)
        }

        if name == LangMacros::unstringify() {
            return self._builtin_unstringify(invoke)
        }

        // macro visibility
        if name == LangIntrinsics::defined() {
            return self._builtin_defined(invoke)
        }

        // deferred code generation
        if name == LangMacros::todo() {
            return self._builtin_sentinel(
                invoke,
                TokenKind::TkMacroExpand,
                MacroSentinel::Todo,
            )
        }

        if name == LangMacros::unreachable() {
            return self._builtin_sentinel(
                invoke,
                TokenKind::TkMacroExpand,
                MacroSentinel::Unreachable,
            )
        }

        if name == LangMacros::unreachable_unchecked() {
            return self._builtin_sentinel(
                invoke,
                TokenKind::TkMacroExpand,
                MacroSentinel::UnreachableUnchecked,
            )
        }

        if name == LangMacros::unique_id() {
            return self._builtin_unique_id(invoke)
        }

        if name == LangMacros::include() {
            return self._builtin_sentinel(
                invoke,
                TokenKind::TkMacroExpand,
                MacroSentinel::Include,
            )
        }

        if name == LangMacros::embed_str() {
            return self._builtin_sentinel(
                invoke,
                TokenKind::LitString,
                MacroSentinel::EmbedStr,
            )
        }

        if name == LangMacros::embed() {
            return self._builtin_sentinel(
                invoke,
                TokenKind::TkMacroExpand,
                MacroSentinel::Embed,
            )
        }

        // diagnostics
        if name == LangMacros::compile_error() {
            return self._builtin_diag(invoke, DiagSeverity::Error)
        }

        if name == LangMacros::compile_warn() {
            return self._builtin_diag(invoke, DiagSeverity::Warning)
        }

        if name == LangMacros::compile_note() {
            return self._builtin_diag(invoke, DiagSeverity::Note)
        }

        return &null
    }

    /// Builtin names are reserved unqualified: a user definition would never
    /// be reachable (dispatch checks builtins first), so `_handle_macro_def`
    /// rejects the definition outright instead of silently hijacking it.
    /// Every LangMacros row is reserved through LangMacros::known, so a row
    /// added there is reserved here; `_try_builtin` dispatches the same rows.
    priv fn _is_builtin_name(self, const name: string) -> bool {
        var i: usize = 0
        while !LangMacros::known(i).is_empty() {
            if name == LangMacros::known(i) {
                return true
            }

            i += 1
        }

        // defined! is a builtin with a _try_builtin entry; label!, jump! and
        // unwrap! are parser intrinsics (_detect_invocation passes them
        // through raw), reserved so a user macro of that name is never
        // unreachable at an unqualified call site.
        return name == LangIntrinsics::defined()
            || name == LangIntrinsics::label()
            || name == LangIntrinsics::jump()
            || name == LangIntrinsics::unwrap()
    }

    //  Builtin helpers

    priv fn _builtin_report(self, range: SourceRange, const message: string, code: DiagID) {
        self._diag->report(DiagCode(code), range.start, message.copy()).first(
            range,
        )->emit()
    }

    priv fn _inv_site(self, inv: unsafe *Self::InvocationInfo) -> SourceRange {
        if inv->origin_site.is_valid() {
            return inv->origin_site
        }

        return inv->range
    }

    priv fn _emit_poison(self, inv: unsafe *Self::InvocationInfo) {
        var tok = Token()
        tok.kind  = TokenKind::TkMacroExpand
        tok.range = self._inv_site(inv)
        tok.imm   = (MacroSentinel::Poison as u32)
        self._emit(tok)
    }

    /// Splits the tokens inside `(...)` at top-level commas.
    ///
    /// `invoke.arg_toks` already excludes the outer `(` and `)`. There is no
    /// whole-file buffer and therefore no args_start/args_end arithmetic.
    priv fn _parse_builtin_arguments(self,
                                     invoke: unsafe *Self::InvocationInfo) -> [unsafe *TokenBuffer<512>] {
        var args: [unsafe *TokenBuffer<512>]

        if !invoke->has_args {
            return args
        }

        // `foo!()` is zero arguments, not one empty argument.
        if invoke->arg_toks.size() == 0 {
            return args
        }

        var split = ArgSplitter()
        for var i: usize = 0; i < invoke->arg_toks.size(); ++i {
            split.feed(invoke->arg_toks[i])
        }

        return split.finish()
    }

    /// Builtin argument pre-expansion policy (documented-asymmetric, C model):
    ///
    /// VALUE-position builtins count!, first!, last!, rest!, butlast!, paste!,
    /// unstringify! fully expand macro invocations inside their arguments
    /// before operating on them, identical to user-macro argument pre-expansion
    /// in _bind_and_substitute. This makes composition sane:
    ///     count!(rest!(a, b, c))  ->  2
    ///
    /// QUOTING/NAME-position builtins stringify!, defined!, unique_id!,
    /// diag builtins operate on RAW tokens: stringify! quotes source spelling
    /// (the `#` analog), defined! probes a macro name without invoking it,
    /// unique_id! takes a literal tag. Pre-expanding those would destroy their
    /// meaning, exactly as in C's `#`/`defined` carve-outs.
    ///
    /// NOTE: unlike C (where commas produced by expansion never act as argument
    /// separators), value-position builtins expand FIRST and split on top-level
    /// commas SECOND. rest!/butlast! return comma lists precisely so they can feed
    /// count!/first!/last!; split-before-expand would make that composition
    /// silently arity-1. User macros keep C semantics (split, then expand each
    /// arg) so expansion cannot change a call's arity.
    priv fn _parse_expanded_builtin_arguments(self,
                                              invoke: unsafe *Self::InvocationInfo) -> [unsafe *TokenBuffer<512>] {
        var args: [unsafe *TokenBuffer<512>]

        if !invoke->has_args {
            return args
        }

        if invoke->arg_toks.size() == 0 {
            return args
        }

        // 1. gather the raw argument token run
        var unsafe *run = unsafe (@create TokenBuffer<512>() as unsafe *TokenBuffer<512>)
        for var i: usize = 0; i < invoke->arg_toks.size(); ++i {
            run->append(invoke->arg_toks[i])
        }

        // 2. expand invocations within it, in caller context
        if self._buf_has_invocation(run) {
            var unsafe *ex = self._expand_buffer(
                run,
                unsafe &invoke->parent_chain,
            )

            @destroy unsafe (run as *TokenBuffer<512>)
            run = ex
        }

        // an expansion may legitimately produce zero tokens (e.g. butlast!(x));
        // that is zero arguments, not one empty argument
        if run->size() == 0 {
            if run != &null {
                @destroy unsafe (run as *TokenBuffer<512>)
            }

            return args
        }

        // 3. split the EXPANDED stream on top-level commas. Every token a
        //    nested invocation produced is origin-wrapped by now, its comma
        //    and brackets included: split by the kind under the wrap, or a
        //    nested rest!'s result stays one argument.
        var split = ArgSplitter()
        for var i: usize = 0; i < run->size(); ++i {
            var t = *run->get(i)
            split.feed_as(t, self._unwrapped_kind(t))
        }

        if run != &null {
            @destroy unsafe (run as *TokenBuffer<512>)
        }

        return split.finish()
    }

    /// The kind `t` had before _wrap_origin wrapped it: its own kind for an
    /// unwrapped token, TkMacroExpand for a sentinel (poison, deferred
    /// builtins), whose imm is no chain.
    priv fn _unwrapped_kind(self, t: Token) -> TokenKind {
        var kind  = t.kind
        var imm   = t.imm
        var depth = 0
        while kind == TokenKind::TkMacroExpand
            && imm < (MacroSentinel::Threshold as u32)
            && depth < 64 {
            var unsafe *info = self._imm->get<Immediate::MacroExpansionInfo>(
                imm,
            )

            if info == &null {
                return TokenKind::TkMacroExpand
            }

            kind = info->original_kind
            imm  = info->original_imm
            depth += 1
        }

        return kind
    }

    priv fn _append_builtin_argument(self,
                                     out: unsafe *(TokenBuffer<512>),
                                     arg: unsafe *(TokenBuffer<512>)) {
        for var i: usize = 0; i < arg->size(); ++i {
            out->append(*arg->get(i))
        }
    }

    priv fn _append_builtin_comma(self, out: unsafe *(TokenBuffer<512>), range: SourceRange) {
        var comma = Token()
        comma.kind  = TokenKind::OpComma
        comma.range = range
        out->append(comma)
    }

    priv fn _builtin_token_text(self, tok: unsafe *Token) -> string {
        return TokenText::spelling(*tok, self._tcm)
    }

    //  Source-location builtins

    priv fn _builtin_file(self,
                          invoke: unsafe *Self::InvocationInfo) -> unsafe *(TokenBuffer<512>) {
        var unsafe *out = unsafe (@create TokenBuffer<512>() as unsafe *TokenBuffer<512>)

        var loc      = self._sm->get_full_loc(invoke->name.range.start)
        var filename = self._sm->get_filename((loc.file_id as u32))

        var tok = Token()
        tok.kind  = TokenKind::LitString
        tok.range = invoke->name.range

        if self._imm != &null {
            tok.imm = self._imm->intern_string_copy(filename)
        }

        out->append(tok)
        return out
    }

    priv fn _builtin_line(self,
                          invoke: unsafe *Self::InvocationInfo) -> unsafe *(TokenBuffer<512>) {
        var unsafe *out = unsafe (@create TokenBuffer<512>() as unsafe *TokenBuffer<512>)
        var        loc  = self._sm->get_full_loc(invoke->name.range.start)

        out->append(self.make_int_token(loc.line as u64, invoke->name.range))

        return out
    }

    priv fn _builtin_column(self,
                            invoke: unsafe *Self::InvocationInfo) -> unsafe *(TokenBuffer<512>) {
        var unsafe *out = unsafe (@create TokenBuffer<512>() as unsafe *TokenBuffer<512>)
        var        loc  = self._sm->get_full_loc(invoke->name.range.start)

        out->append(self.make_int_token(loc.column as u64, invoke->name.range))

        return out
    }

    priv fn _builtin_module_path(self,
                                 invoke: unsafe *Self::InvocationInfo) -> unsafe *(TokenBuffer<512>) {
        var unsafe *out  = unsafe (@create TokenBuffer<512>() as unsafe *TokenBuffer<512>)
        var        *path = self._tracker->current_scope()

        for var i: usize = 0; i < path->segments.size(); ++i {
            if i != 0 {
                var sep = Token()
                sep.kind  = TokenKind::OpColonColon
                sep.range = invoke->range
                out->append(sep)
            }

            var segment_name = self._sym_name(path->segments[i].name)

            out->append(self.make_ident_token(segment_name, invoke->range))
        }

        return out
    }

    //  Argument manipulation builtins

    priv fn _builtin_count(self,
                           invoke: unsafe *Self::InvocationInfo) -> unsafe *(TokenBuffer<512>) {
        var unsafe *out = unsafe (@create TokenBuffer<512>() as unsafe *TokenBuffer<512>)

        if !invoke->has_args {
            self._builtin_report(
                invoke->range,
                "builtin 'count!' requires an argument list; use 'count!(...)'",
                DiagID::R009E,
            )

            return out
        }

        var args = self._parse_expanded_builtin_arguments(invoke)

        out->append(self.make_int_token(args.size() as u64, invoke->range))

        return out
    }

    priv fn _builtin_first(self,
                           invoke: unsafe *Self::InvocationInfo) -> unsafe *(TokenBuffer<512>) {
        var unsafe *out = unsafe (@create TokenBuffer<512>() as unsafe *TokenBuffer<512>)
        var        args = self._parse_expanded_builtin_arguments(invoke)

        if args.size() == 0 {
            self._builtin_report(
                invoke->range,
                "builtin 'first!()' requires at least one argument",
                DiagID::R009E,
            )

            return out
        }

        self._append_builtin_argument(out, args[0])
        return out
    }

    priv fn _builtin_last(self,
                          invoke: unsafe *Self::InvocationInfo) -> unsafe *(TokenBuffer<512>) {
        var unsafe *out = unsafe (@create TokenBuffer<512>() as unsafe *TokenBuffer<512>)
        var        args = self._parse_expanded_builtin_arguments(invoke)

        if args.size() == 0 {
            self._builtin_report(
                invoke->range,
                "builtin 'last!()' requires at least one argument",
                DiagID::R009E,
            )

            return out
        }

        self._append_builtin_argument(out, args[args.size() - 1])
        return out
    }

    priv fn _builtin_rest(self,
                          invoke: unsafe *Self::InvocationInfo) -> unsafe *(TokenBuffer<512>) {
        var unsafe *out = unsafe (@create TokenBuffer<512>() as unsafe *TokenBuffer<512>)
        var        args = self._parse_expanded_builtin_arguments(invoke)

        for var k: usize = 1; k < args.size(); ++k {
            if k > 1 {
                self._append_builtin_comma(out, invoke->range)
            }

            self._append_builtin_argument(out, args[k])
        }

        return out
    }

    priv fn _builtin_butlast(self,
                             invoke: unsafe *Self::InvocationInfo) -> unsafe *(TokenBuffer<512>) {
        var unsafe *out = unsafe (@create TokenBuffer<512>() as unsafe *TokenBuffer<512>)
        var        args = self._parse_expanded_builtin_arguments(invoke)

        if args.size() == 0 {
            return out
        }

        for var k: usize = 0; k + 1 < args.size(); ++k {
            if k > 0 {
                self._append_builtin_comma(out, invoke->range)
            }

            self._append_builtin_argument(out, args[k])
        }

        return out
    }

    /// `paste!(a, b, ...)` token paste. Joins the canonical spelling of every
    /// token in every argument and produces ONE identifier.
    ///   paste!(get_, name) -> `get_name`
    /// Non-identifier results (numbers, operators) are not yet supported: they
    /// need owned imm payloads, which StringData/IntData do not have.
    priv fn _builtin_paste(self,
                           invoke: unsafe *Self::InvocationInfo) -> unsafe *(TokenBuffer<512>) {
        var unsafe *out = unsafe (@create TokenBuffer<512>() as unsafe *TokenBuffer<512>)
        var        args = self._parse_expanded_builtin_arguments(invoke)

        if args.size() == 0 {
            self._builtin_report(
                invoke->range,
                "builtin 'paste!()' requires at least one argument",
                DiagID::R009E,
            )

            return out
        }

        var text = string()
        for var k: usize = 0; k < args.size(); ++k {
            var unsafe *a = args[k]
            for var i: usize = 0; i < a->size(); ++i {
                text += self._builtin_token_text(a->get(i))
            }
        }

        if !self._is_identifier_text(text) {
            self._builtin_report(
                invoke->range,
                f"builtin 'paste!()': '{text}' is not a valid identifier; paste! can only paste identifier-like tokens",
                DiagID::R009E,
            )

            return out
        }

        out->append(self.make_ident_token(text, invoke->range))
        return out
    }

    priv fn _is_identifier_text(self, const s: string) -> bool {
        if s.is_empty() {
            return false
        }

        if !is_ident_start(s.data()[0]) && s.data()[0] != ('#' as u8) {
            return false
        }

        for var i: usize = 1; i < s.size(); ++i {
            if !is_ident_char(s.data()[i]) && s.data()[i] != ('#' as u8) {
                return false
            }
        }

        return true
    }

    //  Token transformation builtins

    /// `stringify!(tokens...)`
    ///
    /// Produces an OWNED-text string literal (StringData::owned_ptr). Two text
    /// strategies:
    ///
    ///  - SOURCE-BACKED run: every token's source bytes match its canonical
    ///    spelling and offsets are monotonic the text is the exact source
    ///    slice, preserving whitespace/punctuation, and `body` is additionally
    ///    populated so unstringify! can re-lex it.
    ///  - SYNTHESIZED/discontiguous run (tokens from paste!, unique_id!,
    ///    spliced defaults, ...): canonical spellings joined with single
    ///    spaces. `body` stays invalid.
    priv fn _builtin_stringify(self,
                               invoke: unsafe *Self::InvocationInfo) -> unsafe *(TokenBuffer<512>) {
        var unsafe *out = unsafe (@create TokenBuffer<512>() as unsafe *TokenBuffer<512>)

        if !invoke->has_args || invoke->arg_toks.size() == 0 {
            self._builtin_report(
                invoke->range,
                "builtin 'stringify!()' requires at least one token",
                DiagID::R009E,
            )

            return out
        }

        var *first = &invoke->arg_toks[0]
        var *last  = &invoke->arg_toks[invoke->arg_toks.size() - 1]

        // A synthesized token carries a range pointing at whatever produced it,
        // not at its own spelling; source bytes != canonical spelling exposes
        // that. Monotonicity rejects reordered/duplicated splices.
        var source_backed = first->range.start.id <= last->range.end.id
        if source_backed {
            for var i: usize = 0; i < invoke->arg_toks.size(); ++i {
                var *t = &invoke->arg_toks[i]
                if i > 0 && t->range.start.id < invoke->arg_toks[i - 1].range.end.id {
                    source_backed = false
                    break
                }

                // A lexed string literal's source bytes ARE its spelling, a
                // chain's included (its range covers every segment);
                // TokenText rebuilds only `"<head body>"`, which no prefixed
                // or joined literal matches. Only a synthesized one (owned
                // text: file!, a nested stringify!) is not source.
                if t->kind == TokenKind::LitString && self._lexed_string(*t) {
                    continue
                }

                if self._sm->get_text(t->range) != TokenText::spelling(
                    *t,
                    self._tcm,
                ) {
                    source_backed = false
                    break
                }
            }
        }

        // A prefixed string's token range starts at its quote (the prefix
        // is the StringData's own token), so the slice starts at the prefix
        // when the first argument has one, or `stringify!(r"a" y)` lost the
        // `r`. A later argument's prefix is inside the slice anyway.
        var head = first->range.start
        if source_backed && first->kind == TokenKind::LitString && self._lexed_string(*first) {
            var unsafe *ftbl = self._tcm->get_imm_table_for_token(*first)
            var unsafe *fd   = ftbl->get<Immediate::StringData>(first->imm)
            if fd->prefix.range.is_valid() && fd->prefix.range.start.id < head.id {
                head = fd->prefix.range.start
            }
        }

        var text = string()
        if source_backed {
            text = self._sm->get_text(
                SourceRange::from_bounds(head, last->range.end),
            )
        } else {
            for var i: usize = 0; i < invoke->arg_toks.size(); ++i {
                if i > 0 {
                    text += " "
                }

                text += self._builtin_token_text(unsafe &invoke->arg_toks[i])
            }
        }

        var tok = Token()
        tok.kind  = TokenKind::LitString
        tok.range = invoke->range
        tok.imm   = self._imm->intern_string_copy(text)

        if source_backed {
            // also range-backed: lets unstringify! re-lex without owned-text
            // lexing support
            var unsafe *data = self._imm->get<Immediate::StringData>(tok.imm)
            data->body = SourceRange::from_bounds(head, last->range.end)
        }

        out->append(tok)
        return out
    }

    priv fn _builtin_unstringify(self,
                                 invoke: unsafe *Self::InvocationInfo) -> unsafe *(TokenBuffer<512>) {
        var unsafe *out = unsafe (@create TokenBuffer<512>() as unsafe *TokenBuffer<512>)
        var        args = self._parse_expanded_builtin_arguments(invoke)

        if args.size() != 1 || args[0]->size() != 1 {
            self._builtin_report(
                invoke->range,
                "builtin 'unstringify!()' requires exactly one string literal",
                DiagID::R009E,
            )

            return out
        }

        var unsafe *str_tok = args[0]->get(0)

        if str_tok->kind != TokenKind::LitString {
            self._builtin_report(
                str_tok->range,
                "builtin 'unstringify!()' argument must be a string literal",
                DiagID::R009E,
            )

            return out
        }

        if self._lexer == &null {
            self._builtin_report(
                str_tok->range,
                "builtin 'unstringify!()': no lexer is available for range re-lexing",
                DiagID::R009E,
            )

            return out
        }

        var unsafe *data = self._imm->get<Immediate::StringData>(str_tok->imm)
        if data == &null {
            self._builtin_report(
                str_tok->range,
                "builtin 'unstringify!()': string literal has no backing data",
                DiagID::R009E,
            )

            return out
        }

        var body = data->body
        if body.start.id >= body.end.id {
            // no source backing: owned-only text (synthesized via stringify!
            // on synthesized tokens, or file!) cannot be re-lexed until the
            // lexer can run over table-owned bytes (load_virtual plumbing).
            if data->has_owned_text() {
                self._builtin_report(
                    str_tok->range,
                    "builtin 'unstringify!()': re-lexing a compiler-synthesized string is not supported yet",
                    DiagID::R009E,
                )
            }

            return out // empty string body, nothing to re-lex
        }

        // the string's body may live in a different file than the one this
        // preprocessor's lexer has loaded (imported macro); re-lexing would
        // read the wrong buffer's bytes.
        if self._sm->get_fid(body) != self._fid {
            self._builtin_report(
                str_tok->range,
                "builtin 'unstringify!()': string content originates in another file; cross-file re-lexing is not supported yet",
                DiagID::R009E,
            )

            return out
        }

        // SourceLocation ids are GLOBAL (file_base + offset); the lexer cursor
        // is FILE-LOCAL. Convert before slicing passing raw ids re-lexes from
        // the wrong bytes for any nonzero file base.
        var start_off = self._sm->get_offset(body.start)
        var body_len  = ((body.end.id - body.start.id) as usize)

        var unsafe *lexed = self._lexer->lex_slice<512>(
            start_off as u32,
            ((start_off + body_len) as u32)
        )

        if lexed == &null {
            self._builtin_report(
                str_tok->range,
                "builtin 'unstringify!()': could not re-lex string content",
                DiagID::R009E,
            )

            return out
        }

        finally {
            if lexed != &null {
                @destroy unsafe (lexed as *TokenBuffer<512>)
            }
        }

        for var i: usize = 0; i < lexed->size(); ++i {
            var unsafe *tok = lexed->get(i)
            if tok->kind == TokenKind::TkEof {
                continue
            }

            if tok->kind == TokenKind::TkError {
                self._builtin_report(
                    str_tok->range,
                    "builtin 'unstringify!()': lexical error in string content",
                    DiagID::R009E,
                )

                continue
            }

            out->append(*tok)
        }

        return out
    }

    //  Macro visibility builtins

    priv fn _builtin_defined(self,
                             invoke: unsafe *Self::InvocationInfo) -> unsafe *(TokenBuffer<512>) {
        var unsafe *out       = unsafe (@create TokenBuffer<512>() as unsafe *TokenBuffer<512>)
        var        found: u64 = 0
        var        args       = self._parse_builtin_arguments(invoke)

        if args.size() == 1 && args[0]->size() == 1 {
            var unsafe *name_tok = args[0]->get(0)

            if name_tok->kind == TokenKind::LitIdentifier {
                var raw_name = *name_tok
                var name_sym = self._sym->intern(
                    self._builtin_token_text(name_tok),
                )

                var probe = Self::InvocationInfo()
                probe.name         = *name_tok
                probe.name_sym     = name_sym
                probe.is_qualified = false
                probe.has_args     = false
                probe.range        = name_tok->range
                probe.found        = true

                if self._resolve(probe) != &null {
                    found = 1
                } else {
                    // Not a Kairo macro: it may be clang's (predefined, or
                    // from an ffi header), which only Sema can ask, after
                    // the headers are built. Passed on as written for the
                    // parser's DefinedExpr (Compiler/Spec/Eval.md#defined).
                    self._defined_raw.insert(
                        invoke->name.range.start.raw() as u64,
                    )

                    out->append(invoke->name)
                    out->append(
                        self._punct(TokenKind::OpExclaim, invoke->name.range),
                    )

                    out->append(
                        self._punct(TokenKind::OpLParen, invoke->name.range),
                    )

                    out->append(raw_name)
                    out->append(
                        self._punct(TokenKind::OpRParen, invoke->name.range),
                    )

                    return out
                }
            }
        }

        // A condition: `true` / `false`, not 1 / 0 (Compiler/Spec/Eval.md#defined).
        var b = Token()
        b.kind  = if (found == (1 as u64)) => (TokenKind::KwTrue) else => TokenKind::KwFalse
        b.range = invoke->name.range
        out->append(b)

        return out
    }

    //  Deferred/sentinel builtins

    /// One `TkMacroExpand` token (an `embed_str!` slot is a `LitString`)
    /// at the invocation's name, its imm the `sentinel` the parser lowers.
    /// `unreachable!` is the safe form: a panic if reached.
    /// `unreachable_unchecked!` tells the optimizer the path is dead;
    /// reaching it at run time is undefined behaviour.
    priv fn _builtin_sentinel(self,
                              invoke:   unsafe *Self::InvocationInfo,
                              kind:     TokenKind,
                              sentinel: MacroSentinel) -> unsafe *(TokenBuffer<512>) {
        var unsafe *out = unsafe (@create TokenBuffer<512>() as unsafe *TokenBuffer<512>)

        var tok = Token()
        tok.kind  = kind
        tok.range = invoke->name.range
        tok.imm   = (sentinel as u32)

        out->append(tok)
        return out
    }

    /// `unique_id!` / `unique_id!(tag)`
    ///
    /// TokenSource must expose the serial of the currently active splice frame.
    /// A source location is not a valid substitute because the same source token
    /// can be duplicated and expanded more than once.
    priv fn _builtin_unique_id(self,
                               invoke: unsafe *Self::InvocationInfo) -> unsafe *(TokenBuffer<512>) {
        var unsafe *out         = unsafe (@create TokenBuffer<512>() as unsafe *TokenBuffer<512>)
        var        range        = invoke->name.range
        var        tag:  string = ""

        if invoke->has_args {
            var args = self._parse_builtin_arguments(invoke)

            var valid = args.size() == 1
                && args[0]->size() == 1
                && args[0]->get(0)->kind == TokenKind::LitIdentifier

            if !valid {
                self._builtin_report(
                    invoke->range,
                    "builtin 'unique_id!()' takes at most one identifier tag, e.g. unique_id!(guard)",
                    DiagID::R009E,
                )

                return out
            }

            tag = self._builtin_token_text(args[0]->get(0))
        }

        var serial = self._src->current_expansion_serial()

        // Tagged inside a macro expansion: stable for this dynamic expansion
        // instance and this tag.
        if !tag.is_empty() && serial != 0 {
            var key = f"{serial}:{tag}"
            var it  = self._unique_tag_cache.find(kairo::sref(key))

            if it != self._unique_tag_cache.end() {
                var tok = Token()
                tok.kind  = TokenKind::LitIdentifier
                tok.range = range
                tok.imm   = it->second

                out->append(tok)
                return out
            }

            self._unique_counter += 1

            var tok = self.make_ident_token(
                LowerTargets::unique_ident(tag, self._fid, self._unique_counter),
                range,
            )

            self._unique_tag_cache.try_emplace(kairo::sref(key), tok.imm) // a miss above: never an overwrite
            out->append(tok)
            return out
        }

        // Untagged, or tagged at the top level: fresh on every invocation.
        self._unique_counter += 1

        out->append(
            self.make_ident_token(
                LowerTargets::unique_ident(tag, self._fid, self._unique_counter),
                range,
            ),
        )

        return out
    }

    //  Diagnostic builtins

    priv fn _builtin_diag(self,
                          invoke: unsafe *Self::InvocationInfo,
                          level:  DiagSeverity) -> unsafe *(TokenBuffer<512>) {
        var unsafe *out = unsafe (@create TokenBuffer<512>() as unsafe *TokenBuffer<512>)
        var        args = self._parse_builtin_arguments(invoke)

        if args.size() == 0 {
            return out
        }

        var message = string()

        for var i: usize = 0; i < args[0]->size(); ++i {
            message += self._builtin_token_text(args[0]->get(i))
        }

        var code =      if (level == DiagSeverity::Error) => (DiagID::R010E)
                   else if (level == DiagSeverity::Warning) => (DiagID::R010W)
                   else => DiagID::R010N

        self._report_expand_err(
            code,
            invoke,
            message,
            "diagnostic emitted from this macro body",
        )

        return out
    }

    //  Resolution

    priv fn _resolve(self, const inv: Self::InvocationInfo) -> unsafe *MacroEntry {
        if inv.is_qualified {
            // The rule Sema uses for a qualified name (Compiler/Spec/NameResolution.md#name-resolution N,
            // T "Heads"): the HEAD is looked up in the scopes that LEXICALLY
            // enclose the use -- this file's own module blocks, innermost
            // first, then the file's scope -- and only then through what the
            // file imported. So the path is tried relative to each scope
            // from the current one down to the file's own module path, and
            // only for macros THIS file registered (find_same_fid): a file
            // at `a::b` with `module std { macro m!() }` registers `m` under
            // [a, b, std], and `std::m!()` there must find it, imported or
            // not (6f101377). Shorter prefixes are not enclosing scopes --
            // the parent module's other files are not lexically around this
            // one, and Sema does not see their decls without an import --
            // and neither is a macro another file registered under a
            // relative path: `c::m!()` in L/b.k, which imports library `c`,
            // must expand the library's macro, not one L/module.k declares
            // in its own `module c { }` (it did, while Sema bound `c::g()`
            // in the same file to the library). Then the path as written,
            // then an import alias.
            var *cur = self._tracker->current_scope()
            var base = self._tracker->file_base()->segments.size()
            for var k: usize = cur->segments.size(); k > 0 && k >= base; --k {
                var rel = ModulePath()
                for var j: usize = 0; j < k; ++j {
                    rel.segments.push_back(cur->segments[j])
                }

                for seg in inv.qualified.segments {
                    rel.segments.push_back(seg)
                }

                var unsafe *r = self._macros->find_same_fid(
                    rel,
                    inv.name_sym,
                    self._fid,
                )

                if r != &null {
                    return r
                }
            }

            // exact scope
            var unsafe *e = self._macros->find(
                inv.qualified,
                inv.name_sym,
                self._fid,
            )

            if e != &null {
                return e
            }

            // alias head: module_aliases[first] + rest
            if inv.qualified.segments.size() > 0 {
                var head = inv.qualified.segments[0].name
                var ait  = self._imports->module_aliases.find(head as u64)
                if ait != self._imports->module_aliases.end() {
                    var scope = ait->second
                    for var k: usize = 1; k < inv.qualified.segments.size(); ++k {
                        scope.segments.push_back(inv.qualified.segments[k])
                    }

                    return self._macros->find(scope, inv.name_sym, self._fid)
                }
            }

            return &null // qualified NEVER falls back to unqualified
        }

        // unqualified: the open blocks, innermost first -> current scope
        // chain (same-fid, order irrelevant under the two-phase-free single
        // walk since defs before this point are the only ones registered)
        // -> named imports -> wildcards -> global
        var unsafe *bm = self._block_macro(inv.name_sym)
        if bm != &null {
            return bm
        }

        var *scope = self._tracker->current_scope()
        var unsafe *e = self._macros->find_same_fid(
            *scope,
            inv.name_sym,
            self._fid,
        )

        if e != &null {
            return e
        }

        var nit = self._imports->named.find(inv.name_sym as u64)
        if nit != self._imports->named.end() {
            return nit->second
        }

        for *wscope in self._imports->wildcards {
            var unsafe *w = self._macros->find(*wscope, inv.name_sym, self._fid)
            if w != &null {
                return w
            }
        }

        // the prelude's own `import builtin::*`, last of the imports
        if self._has_prelude {
            var unsafe *pm = self._macros->find(
                self._prelude,
                inv.name_sym,
                self._fid,
            )

            if pm != &null {
                return pm
            }
        }

        // global scope (empty ModulePath)
        return self._macros->find(ModulePath(), inv.name_sym, self._fid)
    }

    /// The macro `name` of an open block, innermost first, or null.
    priv fn _block_macro(self, name: SymbolID) -> unsafe *MacroEntry {
        var i = self._block_macros.size()
        while i > 0 {
            i -= 1
            if self._block_macros[i].entry->name_sym == name {
                return self._block_macros[i].entry
            }
        }

        return &null
    }

    priv fn _sym_name(self, id: SymbolID) -> string {
        var unsafe *p = self._sym->resolve(id)
        return if (p == &null) => ("<unknown>") else => p->copy()
    }

    priv fn _recover_to_terminator(self) {
        while !self._src->at_eof() {
            var k = self._src->peek(0).kind
            if k == TokenKind::OpSemicolon || k == TokenKind::TkNewLine {
                self._src->next()
                return
            }

            self._src->next()
        }
    }

    //  Finalize

    priv fn _finalize(self) {
        // hand the produced buffer to the TCM as this fid's tokens.
        self._tcm->close_stream(self._fid, self._out)
        self._out = &null // ownership transferred to the slot
        // splice buffers stay owned here until op delete their tokens were
        // COPIED into _out via wrap/append, so freeing them post-handoff is safe.

        // One clang parse per distinct ordered header list; another file
        // importing the same headers in the same order shares the set. The
        // quoted-include directory is THIS file's, as for a .cpp beside it.
        if self._headers != &null && self._ffi_headers.size() > 0 {
            var unsafe *hs = self._headers->request(
                self._ffi_headers,
                self._ffi_c,
                self._ffi_locs,
                self._sm->get_file_dir(self._fid).full_path(),
            )

            self._tu->header_set = unsafe (hs as unsafe *void)
        }
    }
}
