/// --- The Kairo Project -------------------------------- Lexer/Lexer.k --- ///
///
///   The lexer: turns a file's UTF-8 text into tokens and literal payloads.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "llvm/ADT/SmallVector.h"
ffi "c++" import "Native/CharTable.hh"
ffi "c++" import "Native/KShims.hh" // volatile_i64
ffi "c++" import "Native/Types.hh"
ffi "c++" import "Native/KTimeReport.hh"
ffi "c++" import "Native/UTF8Decode.hh"
ffi "c++" import "Native/KLog.hh"
ffi "c++" import "stack"
ffi "c++" import "array"
ffi "c++" import "bit"
ffi "c++" import "string"
ffi "c++" import "utility"
ffi "c++" import "vector"
ffi "c++" import "chrono"

import Diagnostic::Code::DiagCode
import Diagnostic::Engine::DiagEngine
import Diagnostic::Registry::DiagID
import Lexer::BalanceTracker
import Lexer::HexParser::HexParser
import Lexer::Immediate::{
    Immediate,
    ImmediateTable,
}
import Lexer::OctalParser::OctalParser
import Location::SourceLocation::SourceLocation
import Location::SourceManager::SourceManager
import Location::SourceRange::SourceRange
import Memory::MemoryBuffer::MemoryBuffer
import Support::Assert::Assert
import Support::EvalHash::{
    HashState,
    to_hex_string,
}
import Support::FileIO::Path::Path
import Support::FileIO::VirtualFileManager::VirtualFileManager
import Support::FlagSet::FlagSet
import Support::Limits::U32_MAX
import Support::TimeReport::{
    TimeSampled,
    time_enabled,
    time_region_beside,
}
import Support::Timer::Timer
import Support::UTF8View::UTF8View
import Threading::ThreadPool::ThreadPool
import Token::Token::Token
import Token::TokenBuffer::TokenBuffer
import Token::TokenKind::{
    TokenKind,
    is_valid_token_kind,
    substitute,
    token_kind_to_readable_string,
}
import std::io

/// \brief tracks git merge conflict marker detection state during lexing
/// \details used to emit clean diagnostics when conflict markers are found
///
/// to prevent issues later down the pipeline
/// we need to be able to detect git conflict markers in the source code.
/// ignore them and emit clean diagnostics if they are found.
/// this enum represents the state of conflict marker detection.
pub enum ConflictMarker derives u8 { // TODO: add conflit erroring to show issue with git merge conflict
    None,      ///< no conflict detected.
    Start,     ///< conflict start "<<<<<<<<" marker detected.
    Separator, ///< conflict separator "========" marker detected.
    End        ///< conflict end ">>>>>>>>" marker detected.
}

/// \brief coarse classification of the previously emitted token
/// \details used for context-sensitive lexing decisions
pub enum LastTokenKind derives u8 {
    None,
    Text,
    Name,
    Symbol,
    Number,
}

/// \brief utf-8 aware lexer for kairo source files
/// \details
///  - performs tokenization only
///  - no semantic validation beyond lexical correctness
///  - produces immediate nodes for literals
///  - supports f-strings, byte strings, nested comments, and unicode
pub class Lexer {
    enum StreamState derives u8 {
        Closed,
        Streaming,
        Exhausted, ///< TkEof emitted, next() returns false forever
    }

    var _imm_tbl:     unsafe *ImmediateTable   = &null //< a pointer to another lexers imm table for calling lex_slice() on a sub-lexer.
    var _file_buffer: MemoryBuffer
    var _sm:          unsafe *SourceManager
    var cached_data:  kairo::std::ConstPtr<u8> = &null // used for lex_slice to avoid repeated file_data() calls
    var _pool:        unsafe *ThreadPool       = &null
    var _diag:        unsafe *DiagEngine       = &null
    var _cursor:      usize                    = 0 // last pos is always file_size - 1
    var _last_token:  usize                    = 0
    var _size:        usize                    = 0 ///< effective end of the stream: the
    ///  sub-range for a lex_slice sub-lexer,
    ///  else the whole buffer. Replaces the
    ///  old _end_pos, which existed only to be
    ///  branched on inside file_size().
    var _fid:      u32 = 0
    var _loc_base: u32 = 0 ///< raw SourceLocation of offset 0 in _fid;
    ///  see get_source_location.
    var _err_base: u32 = 0 ///< shared-DiagEngine error count at lex() entry;
    ///  error_count() reports the per-run delta.
    var _last_kind: LastTokenKind     = LastTokenKind::None
    var _state:     Self::StreamState = Self::StreamState::Closed
    var _eof_sent:  bool              = false
    // ideally this should be gated to test runner only but fine for now stage2 problems
    // PORT(stage2)
    var _test_buff: unsafe *TokenBuffer<512> = &null

    /// \brief kind of the most recent symbol token, when `_last_kind == Symbol`.
    ///        `_last_kind` collapses `)` `]` `+` `,` into one bucket, but the
    ///        `.`-is-member-access test needs to tell a closing bracket from an
    ///        operator. Written once per symbol token; not read in any scan loop.
    var _last_sym: TokenKind = TokenKind::TkError

    /// ## Pass timing (--time-passes)
    ///
    ///   Lexing is STREAMING: the preprocessor pulls one token at a time and
    ///   the Lexer produces it on demand, so lex time is interleaved with PP
    ///   time and cannot be bracketed from outside. It has to be measured here,
    ///   in next(), which is the only place it happens.
    ///
    ///   Sampled, because it must be. Two clock_gettime calls per token is
    ///   ~50ns through the vDSO on aarch64 against a tokenizer step of roughly
    ///   20ns   the instrument would be two thirds of the reading. At stride 64
    ///   it is ~1ns amortized and the aggregate is accurate to well under the
    ///   resolution anyone acts on.
    ///
    ///   _t_lex is null when timing is off, which is the first thing TimeSampled
    ///   checks, so the disabled path is one null test. The counter is per-Lexer
    ///   and therefore per-file and per-thread   a shared one would put a
    ///   contended cache line in the token loop.

    var _t_lex:      unsafe *kairo::KTimeRecord = &null
    var _lex_sample: u32                        = 0

    const PFX_FORMAT: u8 = 1 << 0
    const PFX_RAW:    u8 = 1 << 1

    /// \brief lightweight handle over string/char immediates
    /// \details abstracts over StringData vs CharData
    class TextImm {
        var lexer: unsafe *Lexer
        var delim: u8
        var idx:   u32

        /// \brief default constructor
        fn TextImm(self) {
            self.lexer = &null
            self.delim = 0
            self.idx   = 0
        }

        /// \brief constructs handle for an existing immediate
        /// \param lexer owning lexer
        /// \param delim string delimiter (' or ")
        /// \param idx immediate table index
        fn TextImm(self, lexer: unsafe *Lexer, delim: u8, idx: u32) {
            self.lexer = lexer
            self.delim = delim
            self.idx   = idx
        }

        /// \brief returns f-string expression list
        /// \returns deque of token buffers + source ranges
        fn get_exprs(self) -> unsafe *llvm::SmallVector<(unsafe *TokenBuffer<16>, SourceRange), 4> {
            if self.delim == 0x22 {
                var unsafe *imm = self.lexer->get_imm<Immediate::StringData>(self.idx)
                return unsafe &imm->exprs
            } else {
                var unsafe *imm = self.lexer->get_imm<Immediate::CharData>(self.idx)
                return unsafe &imm->exprs
            }
        }

        /// \brief returns the per-hole spec/self-doc list, parallel to get_exprs()
        fn get_holes(self) -> unsafe *llvm::SmallVector<Immediate::HoleSpec, 4> {
            if self.delim == 0x22 {
                var unsafe *imm = self.lexer->get_imm<Immediate::StringData>(self.idx)
                return unsafe &imm->holes
            } else {
                var unsafe *imm = self.lexer->get_imm<Immediate::CharData>(self.idx)
                return unsafe &imm->holes
            }
        }

        /// \brief returns prefix token
        /// \returns token reference
        fn get_prefix(self) -> *Token {
            if self.delim == 0x22 {
                var unsafe *imm = self.lexer->get_imm<Immediate::StringData>(self.idx)
                return &imm->prefix
            } else {
                var unsafe *imm = self.lexer->get_imm<Immediate::CharData>(self.idx)
                return &imm->prefix
            }
        }

        /// \brief returns suffix token
        /// \returns token reference
        fn get_suffix(self) -> *Token {
            if self.delim == 0x22 {
                var unsafe *imm = self.lexer->get_imm<Immediate::StringData>(self.idx)
                return &imm->suffix
            } else {
                var unsafe *imm = self.lexer->get_imm<Immediate::CharData>(self.idx)
                return &imm->suffix
            }
        }

        /// \brief returns body source range
        /// \returns source range reference
        fn get_body(self) -> *SourceRange {
            if self.delim == 0x22 {
                var unsafe *imm = self.lexer->get_imm<Immediate::StringData>(self.idx)
                return &imm->body
            } else {
                var unsafe *imm = self.lexer->get_imm<Immediate::CharData>(self.idx)
                return &imm->body
            }
        }

        /// \brief returns next immediate link
        /// \returns next index reference
        fn get_next(self) -> unsafe *u32 {
            if self.delim == 0x22 {
                var unsafe *imm = self.lexer->get_imm<Immediate::StringData>(self.idx)
                return unsafe &imm->next
            } else {
                var unsafe *imm = self.lexer->get_imm<Immediate::CharData>(self.idx)
                return unsafe &imm->next
            }
        }

        /// \brief returns prefix classification
        /// \returns prefix kind
        fn get_prefix_kind(self) -> *FlagSet<Immediate::TextPrefixKind, u8> {
            if self.delim == 0x22 {
                var unsafe *imm = self.lexer->get_imm<Immediate::StringData>(self.idx)
                return &imm->prefix_kind
            } else {
                var unsafe *imm = self.lexer->get_imm<Immediate::CharData>(self.idx)
                return &imm->prefix_kind
            }
        }
    }

    /// \brief transient context for string / char lexing
    /// \details lives only during lex_text
    struct TextCtx {
        struct FormatSpec { /// f-string hole: `{` expr [`=`] [`:` spec] `}`
            var start:      usize ///< first byte after the `{`
            var end:        usize ///< the `}`
            var spec_start: usize ///< first byte after the `:`; 0 when no spec
            var eq_pos:     usize ///< the self-documenting `=`; 0 when absent
        }

        var lexer: *Lexer
        var start: SourceLocation

        var delim:     u8
        var imm_idx:   u32
        var is_format: bool    = false
        var is_raw:    bool    = false
        var imm:       TextImm
        var prefix:    Token

        var body_start: SourceLocation
        var body_end:   SourceLocation

        var in_format_depth:  usize
        var in_bracket_depth: usize ///< `(` `[` nesting inside the hole; a `:` or `=` decides nothing inside one
        var terminators:      cxx::std::stack<SourceLocation>
        var fstring_specs:    llvm::SmallVector<Self::FormatSpec, 4>

        var has_error:   bool  = false
        var is_triple:   bool  = false
        var error_token: Token
    }

    /// \brief transient context for number lexing
    struct NumberCtx {
        /// \brief tracks what was last seen while lexing a number
        enum LastWasState derives u8 {
            None,
            Digit,
            Underscore,
            Dot,
            Prefix,
            Exponent
        }

        var start: SourceLocation

        var base:         u8
        var has_prefix:   bool = false
        var has_suffix:   bool = false
        var has_decimal:  bool = false
        var has_exponent: bool = false

        var number_start: SourceLocation
        var number_end:   SourceLocation
        var prefix_start: SourceLocation
        var prefix_end:   SourceLocation
        var suffix:       Token

        var last:             Self::LastWasState
        var allows_sign_next: bool               = false

        /// true when this number sits immediately after a member-access
        /// separator, i.e. it is a tuple index. Such a number must NOT swallow
        /// a following `.`: `t.0.1` is two indices, not `t` `.` `0.1`.
        var is_tuple_index: bool = false
    }

    /// \brief checks if character is a valid digit in the given base
    /// \param c input character
    /// \param base numeric base (2, 8, 10, 16)
    /// \returns true if c is a digit allowed for `base` (2, 8, 10, 16)
    priv inline static fn is_base_digit(c: char, base: u8) -> bool {
        match base {
            case 2 {
                return c == '0' || c == '1'
            } case 8 {
                return c >= '0' && c <= '7'
            } case 10 {
                return c >= '0' && c <= '9'
            } case 16 {
                return c >= '0' && c <= '9' || c >= 'A' && c <= 'F' || c >= 'a' && c <= 'f'
            } default {
                return false
            }
        }
    }

    /// \brief checks if character is a valid exponent character for the given base
    /// \param c input character
    /// \param base numeric base (10, 16)
    /// \returns true if `c` starts an exponent for the given base
    priv inline static fn is_exponent_char(c: char, base: u8) -> bool {
        return base == 10 && (c == 'e' || c == 'E') || base == 16 && (c == 'p' || c == 'P')
    }

    /// \brief checks if character is a decimal digit
    /// \param c input character
    /// \returns true if `c` is a decimal digit
    priv inline static fn is_decimal_digit(c: char) -> bool {
        return c >= '0' && c <= '9'
    }

    /// # LEXER TEST API

    /// \brief legacy batch API. drives the streaming API to exhaustion.
    /// \details tests were written against lex()/tokens(). keep them honest by
    ///          making the batch path a client of the stream path, not a fork of it.
    fn lex(self, fid: u32) -> bool {
        if !self.open(fid) {
            return false
        }

        self._test_buff = self.drain()
        return self._test_buff != &null
    }

    fn tokens(self) -> unsafe *TokenBuffer<512> {
        return self._test_buff
    }

    /// # LEXER API

    /// \brief gets the next token from the input stream
    /// \param start starting source location of the token
    /// \param decode decoded character at the current cursor position
    /// \returns next token
    priv inline fn get_token(self,
                             const start  : SourceLocation,
                             const decode : kairo::DecodeResult) -> Token {
        const cls: kairo::CharClass = self.classify(decode.chr)

        match cls {
            case kairo::CharClass::Identifier {
                // identifier or keyword
                return self.lex_name(start)
            } case kairo::CharClass::Number {
                // integer or float literal
                return self.lex_number(start)
            } case kairo::CharClass::Operator {
                // this is either an operator or punctuation
                return self.lex_symbol(start)
            } case kairo::CharClass::String {
                // string or char literal
                return self.lex_text(start)
            } case kairo::CharClass::Unassigned, kairo::CharClass::Illegal {
                // illegal character
                return self.lex_illegal(start)
            } case kairo::CharClass::NewLine, kairo::CharClass::Whitespace {
                // whitespace or newline
                return self.lex_whitespace(
                    start,
                    kairo::normalize_char32(decode.chr),
                    (decode.len as usize),
                    cls
                )
            } default { }
        }

        self.advance_cursor((decode.len as usize))
        return self.create_unrecognized_token(start)
    }

    /// \brief places this Lexer's "Lex" timing row explicitly.
    ///
    /// \details Call BEFORE open(), which otherwise picks a default position.
    ///          Needed because a Lexer can be driven by two unrelated passes:
    ///          the DepScanner's import scan and the preprocessor's walk. They
    ///          tokenize the same bytes for different reasons and have to show
    ///          up as separate rows, or the fact that the work happens twice
    ///          is invisible.
    pub fn bind_time_region(self, rec: unsafe *kairo::KTimeRecord) {
        self._t_lex = rec
    }

    /// \brief begin streaming a fid. imm table live immediately after this returns.
    pub fn open(self, fid: u32) -> bool {
        if self._state != Self::StreamState::Closed {
            kairo::Logger::error(
                kairo::Logger::Stage::Lexer,
                f"Lexer::open: already streaming fid={self._fid}",
            )

            return false
        }

        self._fid        = fid
        self._cursor     = 0
        self._size       = 0
        self.cached_data = &null
        self._eof_sent   = false
        self._last_kind  = LastTokenKind::None

        if !self.load_file(fid) {
            kairo::Logger::error(
                kairo::Logger::Stage::Lexer,
                f"Lexer::open: failed to load fid={fid}",
            )

            return false
        }

        self._sm->wait_for_line_index(fid)

        // Invalid bytes are reported here, once, as S072E; lexing continues
        // regardless so the user still sees the errors after them.
        self._sm->validate_utf8(fid)

        if self.file_data() == &null {
            kairo::Logger::error(
                kairo::Logger::Stage::Lexer,
                f"Lexer::open: null file_data for fid={fid}",
            )

            return false
        }

        // Cache the fid's base once. get_source_location is called at least
        // once per token and sometimes several times, and all get_loc does with
        // a valid fid is `segment.global_base + off + 1` behind four checks and
        // two cross-object calls (SourceManager -> VirtualFileManager).
        self._loc_base = self._sm->get_loc(fid, 0).raw()

        // The one check that is not a function of the cached base: get_loc ICEs
        // when a location leaves the 4 GB SourceLocation space. Bound the whole
        // file here rather than testing every token.
        if ((self._loc_base as u64) + (self.file_size() as u64) > U32_MAX) {
            kairo::std::ice_fail(
                "Lexer::open: file does not fit the 4GB SourceLocation address space",
            )
        }

        self._err_base = self._diag->error_count()
        self._state    = Self::StreamState::Streaming

        // Only if the caller has not already placed us. open_scan_stream binds
        // its own record (see bind_time_region) because the DepScanner's lex
        // and the walk's lex are two different passes over the same bytes and
        // must not collapse into one row.
        //
        // BESIDE, not under, for the default path: open() runs inside the PP's
        // "Open" region (TokenCacheManager::open_stream), but lex time is not
        // part of opening a stream   it belongs next to it, under the walk.
        // Resolving here rather than lazily in next() keeps the per-token path
        // down to a null check.
        if time_enabled() && self._t_lex == &null {
            self._t_lex = time_region_beside("Lex")
        }

        return true
    }

    /// \brief pull one token. false = stream exhausted.
    /// \details never blocks. lex errors emit TkError inline + diagnostics; stream continues.
    pub fn next(self, out: *Token) -> bool {
        if self._state != Self::StreamState::Streaming {
            return false
        }

        var _t = TimeSampled(self._t_lex, 64, unsafe &self._lex_sample)

        while !self.is_eof() {
            var decode = self.peek_char32()
            var token  = self.get_token(self.get_source_location(), decode)

            // whitespace is not surfaced; TkNewLine IS surfaced
            if token == TokenKind::TkWhitespace {
                continue
            }

            *out = token
            return true
        }

        // EOF contract: exactly one TkEof, then dead forever.
        if !self._eof_sent {
            self._eof_sent = true
            *out           = Token(self.get_source_range(), TokenKind::TkEof, 0)
            self._state    = Self::StreamState::Exhausted
            return true
        }

        return false
    }

    fn drain(self) -> unsafe *TokenBuffer<512> {
        var unsafe *buf       = kairo::std::create<TokenBuffer<512>>()
        var        tok: Token
        while self.next(&tok) {
            buf->append(tok)
        }

        return buf
    }

    pub fn close(self) {
        self._state = Self::StreamState::Closed
        // NOTE: does NOT reset _imm_tbl. Indices handed out are stable forever.
        // The imm table's lifetime is the TCM slot's, not the stream's.
    }

    /// \brief lexes a slice of the current file between start and end positions
    /// \param start starting position (inclusive)
    /// \param end ending position (exclusive)
    /// \returns token buffer containing lexed tokens
    /// \template N TokenBuffer chunk size
    pub fn <eval N: usize> lex_slice(self, start: u32, end: u32) -> unsafe *TokenBuffer<N> {
        var sub = Lexer(self._sm, self._pool, self._diag, self._imm_tbl)
        sub._fid         = self._fid
        sub._file_buffer = self._file_buffer
        sub.cached_data  = self.cached_data
        sub._cursor      = (start as usize)
        sub._loc_base    = self._loc_base
        sub._size        = (end as usize)
        sub._state       = Self::StreamState::Streaming

        var tokens       = kairo::std::create<TokenBuffer<N>>()
        var tok:   Token

        while sub.next(&tok) {
            tokens->append(tok)
        }

        return tokens
    }

    /// \brief a default destructor pretty self-explanatory
    fn Lexer(self) = delete

    /// \brief default constructor
    /// \details initializes lexer with source manager and thread pool
    /// \param sm source manager pointer
    /// \param pool thread pool pointer
    /// \returns initialized lexer
    fn Lexer(self,
             sm:      unsafe *SourceManager,
             pool:    unsafe *ThreadPool,
             diag:    unsafe *DiagEngine,
             imm_tbl: unsafe *ImmediateTable = &null) {
        self._sm      = sm
        self._pool    = pool
        self._diag    = diag
        self._imm_tbl = imm_tbl
        kairo::Logger::info(kairo::Logger::Stage::Lexer, "Lexer: initialized")
    }

    /// \brief destructor
    fn op finally (self) = default

    /// \brief loads the file buffer for the given file ID
    /// \param fid file ID to load
    /// \returns true on success
    priv inline fn load_file(self, fid: u32) -> bool {
        if self._sm == &null {
            return false
        }

        var buffer? = self._sm->get_buffer(fid)
        if buffer == null || !buffer.is_valid() {
            kairo::Logger::error(
                kairo::Logger::Stage::Lexer,
                f"Lexer::load_file: invalid buffer for fid={fid}",
            )

            return false
        }

        self._file_buffer = buffer

        // Resolve the buffer's data pointer and size ONCE per stream. Both were
        // recomputed per call behind a branch - file_data through a null-check
        // and a lazy memo, file_size through a sub-range test and a call into
        // MemoryBuffer - and both are on the per-token path via is_eof() and
        // peek_char32. They were 1,522 + 721 samples, 13% of main-thread self
        // time, after the scan loops stopped calling them per character.
        self.cached_data = self._file_buffer.data()
        self._size       = self._file_buffer.size()

        return true
    }

    /// # GETTERS/SETTERS

    priv inline fn is_eof(self) -> bool {
        return self._cursor >= self.file_size()
    }

    priv inline fn current_data(self) -> kairo::std::ConstPtr<u8> {
        return self.file_data() + self._cursor
    }

    /// \brief bytes readable at the cursor, 0 at EOF.
    ///
    /// \details this is a READ LENGTH, not an index distance. handing it to
    ///          decode_utf8 guarantees the decoder never touches a byte past
    ///          file_size(). the previous remaining_offset() returned
    ///          `size - cursor - 1` and every caller added 1 back "for the null
    ///          terminator"   there is no null terminator. MemoryBuffer is a
    ///          non-owning view over an mmap'd region of exactly size() bytes,
    ///          so at cursor == size that +1 handed the decoder a length of 1
    ///          over a pointer already at one-past-the-end.
    priv inline fn remaining_bytes(self) -> usize {
        const size: usize = self.file_size()
        if self._cursor >= size {
            return 0
        }

        return size - self._cursor
    }

    /// \note plain member reads. Set once by load_file (whole buffer) or by
    ///       lex_slice (the sub-range), the only two ways a stream begins.
    priv inline fn file_size(self) -> usize {
        return self._size
    }

    priv inline fn file_data(self) -> kairo::std::ConstPtr<u8> {
        return self.cached_data
    }

    /// \brief moves the cursor forward, never past end-of-buffer.
    ///
    /// \details INVARIANT: 0 <= _cursor <= file_size(). Landing exactly ON
    ///          file_size() is the EOF position and is legal   is_eof() reports
    ///          true there, current_data() forms a one-past-the-end pointer that
    ///          is never dereferenced, remaining_bytes() reports 0, and
    ///          VirtualFileManager::get_loc accepts off == seg->size. Going PAST
    ///          it is not legal: the scan loops in lex_name/scan_number_body/
    ///          scan_text_body/lex_*_comment/lex_whitespace derive their `end`
    ///          pointer from file_size() and run raw pointers against it, so an
    ///          over-advanced cursor reads outside the mapping.
    ///
    /// \note the clamp restored here is NOT the one that was commented out. That
    ///       one pinned the cursor to `file_size() - 1`, one byte SHORT of EOF,
    ///       so is_eof() could never become true and every `while !is_eof()`
    ///       scanner span forever on the last byte   which is why it was
    ///       disabled. It also underflowed on an empty buffer, and it left
    ///       _last_advanced holding the REQUESTED count rather than the distance
    ///       actually travelled, desyncing retreat_cursor_to_last.
    priv inline fn advance_cursor(self, count: usize = 1) {
        const size: usize = self.file_size()
        const room: usize = if (self._cursor < size) => (size - self._cursor) else => 0
        const step: usize = if (count < room) => (count) else => room

        self._last_advanced = (step as isize)
        self._cursor += step
    }

    /// \brief writes a raw-pointer scan back into the member cursor.
    ///
    /// \details the scan loops keep the position in a local `const u8*` so the
    ///          compiler can hold it in a register; this is how that position
    ///          re-enters the object. \p base is the buffer origin the scan was
    ///          derived from and \p step is the byte length of the LAST
    ///          character the loop consumed, which is exactly what
    ///          advance_cursor would have left in _last_advanced. A \p step of 0
    ///          means the loop consumed nothing, so _last_advanced is left
    ///          alone and still describes the advance that entered the loop.
    ///
    /// \warning must be called before ANY helper that reads _cursor
    ///          (get_source_location, create_source_range, peek_char32, a
    ///          diagnostic, or a nested scanner), not merely before returning.
    priv inline fn commit_cursor(self,
                                 const base: kairo::std::ConstPtr<u8>,
                                 const pos:  kairo::std::ConstPtr<u8>,
                                 const step: usize) {
        if step != 0 {
            self._last_advanced = (step as isize)
        }

        self._cursor = ((pos - base) as usize)
    }

    priv inline fn retreat_cursor(self, count: usize = 1) {
        if count > self._cursor {
            self._cursor = 0
            return
        }

        self._last_advanced = -(count as isize)
        self._cursor -= count
    }

    priv inline fn retreat_cursor_to_last(self) {
        if self._last_advanced > 0 {
            self.retreat_cursor(self._last_advanced as usize)
        } else if self._last_advanced < 0 {
            self.advance_cursor((-self._last_advanced) as usize)
        }
    }

    /// # LEXER INTERNALS

    /// \brief decodes the character at \p p, without a call for ASCII.
    ///
    /// \details decode_utf8_lut already has this exact test three instructions
    ///          in, so this is not a cheaper CHECK - it removes the call needed
    ///          to reach it. UTF8View::decode_utf8 lives behind an FFI header
    ///          and does not inline into the lexer: `sample` shows it as its
    ///          own frame on the hot path. Real source is >95% ASCII, so this
    ///          keeps the overwhelmingly common character entirely inside the
    ///          caller's scan loop.
    ///
    /// \param avail bytes readable at \p p. Zero is EOF and yields len 0, which
    ///        is what every scan loop breaks on.
    inline static fn decode_at(const p:     kairo::std::ConstPtr<u8>,
                               const avail: usize) -> kairo::DecodeResult {
        if avail == 0 {
            return kairo::DecodeResult { chr: '\x00', len: 0, ok: false }
        }

        if p[0] < 0x80 {
            return kairo::DecodeResult { chr: p[0], len: 1, ok: true }
        }

        return UTF8View::decode_utf8(p, avail)
    }

    /// \brief byte length of the character ending immediately before \p q.
    ///
    /// \details Only for the raw-byte scanners (the comment bodies), which
    ///          never learn a character length because they never decode. Walk
    ///          back over UTF-8 continuation bytes once, at loop exit, so
    ///          commit_cursor can still record the same _last_advanced a
    ///          decoding loop would have.
    inline static fn char_len_before(const base: kairo::std::ConstPtr<u8>,
                                     const q:    kairo::std::ConstPtr<u8>) -> usize {
        if q <= base {
            return 0
        }

        var unsafe *r = q - 1
        while r > base && (r[0] & 0xC0) == 0x80 {
            r -= 1
        }

        return (q - r) as usize
    }

    /// 1 would be the immediate next char
    priv inline fn peek_char32(self, offset: isize = 0) -> kairo::DecodeResult {
        var data: kairo::std::ConstPtr<u8> = self.current_data()
        var size: usize                    = self.remaining_bytes()

        if offset < 0 {
            data -= -offset
            size += ((-offset) as usize)
        } else {
            const fwd: usize = (offset as usize)

            // `size - fwd` wraps on usize when the peek reaches past EOF, which
            // handed the decoder a length near 2^64. peek_char32(2) on the last
            // byte of a file (scan_text_body's triple-quote probe) does exactly
            // that.
            if fwd >= size {
                return kairo::DecodeResult { chr: '\x00', len: 0, ok: false }
            }

            data += fwd
            size -= fwd
        }

        if size == 0 {
            return kairo::DecodeResult { chr: '\x00', len: 0, ok: false }
        }

        return Lexer::decode_at(data, size)
    }

    priv inline fn get_char32(self) -> kairo::DecodeResult {
        var result = self.peek_char32()

        self.advance_cursor(((if (result.len > 0) => (result.len as usize) else => 1)))
        return result
    }

    priv inline fn <eval N: usize> peek_char32(self,
                                               const max_unicode_len: u8 = 4) -> cxx::std::array<kairo::DecodeResult, N> {
        var res = cxx::std::array<kairo::DecodeResult, N>()
        res.fill(kairo::DecodeResult { chr: '\x00', len: 0, ok: false })

        var data:   kairo::std::ConstPtr<u8> = self.current_data()
        var remain: usize                    = self.remaining_bytes()

        if remain == 0 {
            return res
        }

        var consumed: usize = 0
        var out_i:    usize = 0

        if max_unicode_len != 1 {
            while out_i < N && consumed < remain {
                var d = Lexer::decode_at(data + consumed, remain - consumed)
                if d.len == 0 {
                    break
                }

                res[out_i] = d
                consumed += (d.len as usize)
                ++out_i
            }

            return res
        }

        eval if defined!(__AVX512BW__) && defined!(__AVX512VL__) {
            const STRIDE: usize = 64

            while out_i < N {
                var rem = remain - consumed
                if rem < STRIDE { // <-- HARD BOUNDARY
                    break
                }

                var ptr = data + consumed

                // fully within mapping?
                // (only necessary if your MemoryBuffer isn't guaranteed padded)
                // Here we assume `remain` is correct for mapping.

                var chunk: __m512i = _mm512_loadu_si512(unsafe (ptr as unsafe *const __m512i))

                var mask: __mmask64 = _mm512_movepi8_mask(chunk)

                if mask == 0 { // fully ASCII
                    var limit = STRIDE
                    if out_i + STRIDE > N {
                        limit = N - out_i
                    }

                    for var j: usize = 0; j < limit; ++j {
                        res[out_i] = kairo::DecodeResult { chr: ptr[j] as char, len: 1, ok: true }
                        ++out_i
                    }

                    consumed += limit
                    continue
                } else { // first non-ASCII stops SIMD processing
                    // countr_zero returns int; the limits it meets are usize.
                    var first = cxx::std::countr_zero(mask) as usize

                    var limit = first
                    if out_i + limit > N {
                        limit = N - out_i
                    }

                    for var j: usize = 0; j < limit; ++j {
                        res[out_i] = kairo::DecodeResult { chr: ptr[j] as char, len: 1, ok: true }
                        ++out_i
                    }

                    consumed += first
                    break
                }
            }
        } else if defined!(__AVX2__) {
            const STRIDE: usize = 32

            while out_i < N {
                var rem = remain - consumed
                if rem < STRIDE {
                    break
                }

                var ptr = data + consumed

                var chunk: __m256i = _mm256_loadu_si256(unsafe (ptr as unsafe *const __m256i))

                var hi = _mm256_movemask_epi8(chunk)
                if hi == 0 {
                    var limit = STRIDE
                    if out_i + STRIDE > N {
                        limit = N - out_i
                    }

                    for var j: usize = 0; j < limit; ++j {
                        res[out_i] = kairo::DecodeResult { chr: ptr[j] as char, len: 1, ok: true }
                        ++out_i
                    }

                    consumed += limit
                    continue
                } else {
                    var first = cxx::std::countr_zero(hi)

                    var limit = first
                    if out_i + limit > N {
                        limit = N - out_i
                    }

                    for var j: usize = 0; j < limit; ++j {
                        res[out_i] = kairo::DecodeResult { chr: ptr[j] as char, len: 1, ok: true }
                        ++out_i
                    }

                    consumed += first
                    break
                }
            }
        } else if defined!(__SSE2__) {
            const STRIDE: usize = 16

            while out_i < N {
                var rem = remain - consumed
                if rem < STRIDE {
                    break
                }

                var unsafe *ptr = data + consumed
                var chunk: __m128i = _mm_loadu_si128(unsafe (ptr as kairo::std::ConstPtr<__m128i>))

                var hi = _mm_movemask_epi8(chunk)
                if hi == 0 {
                    var limit = STRIDE
                    if out_i + STRIDE > N {
                        limit = N - out_i
                    }

                    for var j: usize = 0; j < limit; ++j {
                        res[out_i] = kairo::DecodeResult { chr: ptr[j], len: 1, ok: true }
                        ++out_i
                    }

                    consumed += limit
                    continue
                } else {
                    var first = cxx::std::countr_zero(hi as u32) as usize

                    var limit = first
                    if out_i + limit > N {
                        limit = N - out_i
                    }

                    for var j: usize = 0; j < limit; ++j {
                        res[out_i] = kairo::DecodeResult { chr: ptr[j], len: 1, ok: true }
                        ++out_i
                    }

                    consumed += first
                    break
                }
            }
        } else if defined!(__ARM_NEON) {
            const STRIDE:  usize      = 16
            const hi_mask: uint8x16_t = vdupq_n_u8(0x80)

            while out_i < N {
                var rem = remain - consumed
                if rem < STRIDE {
                    break
                }

                var ptr = data + consumed

                var chunk = kairo::neon_ld_u8(ptr)
                var hi    = vandq_u8(chunk, hi_mask)
                hi = vtstq_u8(hi, hi_mask)

                var tmp: [u8; 16]
                kairo::neon_st_u8(unsafe &tmp[0], hi)

                var bitmask: u32 = 0
                for var k: usize = 0; k < 16; ++k {
                    if tmp[k] != 0 {
                        bitmask |= 1 << k
                    }
                }

                if bitmask == 0 {
                    var limit = STRIDE
                    if out_i + STRIDE > N {
                        limit = N - out_i
                    }

                    for var j: usize = 0; j < limit; ++j {
                        res[out_i] = kairo::DecodeResult { chr: ptr[j], len: 1, ok: true }
                        ++out_i
                    }

                    consumed += limit
                    continue
                } else {
                    // countr_zero returns int; the limits it meets are usize.
                    var first = cxx::std::countr_zero(bitmask) as usize

                    var limit = first
                    if out_i + limit > N {
                        limit = N - out_i
                    }

                    for var j: usize = 0; j < limit; ++j {
                        res[out_i] = kairo::DecodeResult { chr: ptr[j], len: 1, ok: true }
                        ++out_i
                    }

                    consumed += first
                    break
                }
            }
        }

        while out_i < N && consumed < remain {
            var d = Lexer::decode_at(data + consumed, remain - consumed)
            if d.len == 0 {
                break
            }

            res[out_i] = d
            consumed += (d.len as usize)
            ++out_i
        }

        return res
    }


    /// \brief position -> SourceLocation, without the SourceManager round trip.
    ///
    /// \details Identical to _sm->get_loc(_fid, pos) for any pos this lexer can
    ///          produce. get_loc's four guards are all invariants here rather
    ///          than per-token questions: the fid is valid and un-evicted for
    ///          the life of the stream (open() would have failed), pos <=
    ///          file_size() is the advance_cursor invariant, and the 4 GB cap
    ///          is checked once for the whole file in open().
    priv inline fn get_source_location(self) -> SourceLocation {
        return SourceLocation::from_raw(self._loc_base + (self._cursor as u32))
    }

    priv inline fn get_source_location(self, pos: usize) -> SourceLocation {
        return SourceLocation::from_raw(self._loc_base + (pos as u32))
    }

    priv inline fn get_source_range(self) -> SourceRange {
        return SourceRange::from_bounds(self.get_source_location(), self.get_source_location())
    }

    priv inline fn create_source_range(self, start: SourceLocation) -> SourceRange {
        return SourceRange::from_bounds(start, self.get_source_location())
    }

    priv inline fn create_source_range(self, start: usize, end: usize) -> SourceRange {
        return SourceRange::from_bounds(
            self.get_source_location(start),
            self.get_source_location(end),
        )
    }

    priv inline fn create_error_token(self,
                                      start:    SourceLocation,
                                      expected: TokenKind,
                                      kind:     TokenKind = TokenKind::TkError) -> Token {
        self._last_kind = LastTokenKind::None
        return Token(self.create_source_range(start), kind, expected as u32)
    }

    priv inline fn create_unrecognized_token(self,
                                             start: SourceLocation,
                                             kind:  TokenKind = TokenKind::TkUnknown) -> Token {
        self._last_kind = LastTokenKind::None
        return Token(self.create_source_range(start), kind, u32::MAX)
    }

    var _last_advanced: isize = 0

    /// # Char Classification

    static fn classify(chr: char) -> kairo::CharClass {
        return kairo::classify_char32(chr)
    }

    var _conflict_state: ConflictMarker = ConflictMarker::None

    /// # Lexical Parsing Functions

    priv inline fn lex_name(self, start: SourceLocation) -> Token {
        /// 1. identifier
        /// 2. keyword
        ///
        /// keywords are ASCII-only A-Za-z0-9_
        /// identifiers allow UTF-8 and all valid name chars.
        ///
        /// keywords must hash fully and cannot contain:
        ///   - utf8 chars
        ///   - '#'
        ///   - anything outside [A-Za-z0-9_]
        ///
        /// identifiers have no max length.
        /// keywords max length is 32 u8 chars.
        ///
        /// we hash keyword candidates as long as the stream stays
        /// within the ascii keyword subset and under MAX_KEYWORD_LENGTH.
        ///
        /// the moment we hit a utf-8 multibyte char or a non-keyword-safe char,
        /// the whole lexeme becomes an identifier.

        const MAX_KEYWORD_LENGTH: usize = 32

        var token:   Token     = Token()
        var hash:    HashState = HashState()
        var length:  usize     = 0
        var keyword: bool      = true

        // buffer bounds are loop invariants; _cursor lives in `p` for the whole
        // scan so the per-character cost is a decode and a pointer bump, with no
        // member load-modify-store and no file_size()/file_data() call.
        const base: kairo::std::ConstPtr<u8> = self.file_data()
        const end:  kairo::std::ConstPtr<u8> = base + self.file_size()

        var p:    kairo::std::ConstPtr<u8> = base + self._cursor
        var step: usize                    = 0

        var unsafe *s_p  = p
        var        first = Lexer::decode_at(p, (end - p) as usize)

        if self.is_valid_name(first) == 0 {
            self.advance_cursor((first.len as usize))
            return self.create_unrecognized_token(start)
        }

        hash.mix(first.chr as u8)
        length += (first.len as usize)
        p += first.len
        step = (first.len as usize)

        if first.len > 1 {
            keyword = false
        }

        while p < end {
            var d = Lexer::decode_at(p, (end - p) as usize)
            if self.is_valid_name(d) == 0 {
                break // finished
            }

            if keyword && d.len == 1 {
                var c: u8 = (d.chr as u8)

                // A-Z a-z _ 0-9 without branches
                var lo       = c | 0x20
                var is_alpha = lo >= ('a' as u8) && lo <= ('z' as u8)
                var is_digit = c >= ('0' as u8) && c <= ('9' as u8)
                var is_us    = c == ('_' as u8)

                if !(is_alpha || is_digit || is_us) {
                    keyword = false
                }
            }

            hash.mix(d.chr as u8)
            p += d.len
            step = (d.len as usize)
            length += (d.len as usize)
        }

        // everything past this point (create_source_range, peek_char32,
        // get_source_location, lex_text) reads _cursor.
        self.commit_cursor(base, p, step)

        if length > MAX_KEYWORD_LENGTH {
            keyword = false
        }

        var h = hash.finalize()
        if keyword && is_valid_token_kind((h as u32)) {
            var kind = (h as u32 as TokenKind)
            var sub  = substitute(kind)
            token.set_kind(if (sub != TokenKind::TkUnknown) => sub else => kind)
            token.set_range(self.create_source_range(start))

            /// we do also need to do a quick sub check since we support c++
            /// style word operators (yes its a bad feature, but its only
            /// sake of c++ devs migrating to kairo)
            self._last_kind = LastTokenKind::Name
            return token
        }

        /// we also need a quick second check to see if a string
        token.set_kind(TokenKind::LitIdentifier)
        token.set_range(self.create_source_range(start))
        token.set_imm(self.intern_ident(s_p, length, (h as u32)))

        // length is byte count; all valid prefixes are ASCII so this is fine
        var dec = self.peek_char32()
        if dec.chr == '"' || dec.chr == '\'' && length < 3 {
            // WE HAVE A STRING HERE
            // we also now need to see if our prefix is f, b, fb, or bf
            // and set the imm to 0, for invalid, 1 for format, 2 for bytes, 3 for bytes and format
            var ptype: u8 = 0

            match h {
                case 3591182180 /* "f" */, 3591178436 /* "F" */ {
                    ptype = self.PFX_FORMAT
                } case 3591188472 /* "r" */, 3591176536 /* "R" */ {
                    ptype = self.PFX_RAW
                } case 2670705545 /* "fR" */, 2679377641 /* "FR" */,
                     2679374857 /* "Fr" */, 2670219881 /* "fr" */,
                     2678220897 /* "Rf" */, 2678207169 /* "RF" */,
                     2678319073 /* "rF" */, 2678308417 /* "rf" */ {
                    ptype = self.PFX_FORMAT | self.PFX_RAW
                } default { }
            }

            if ptype != 0 {
                token.imm = ptype
                return self.lex_text(self.get_source_location(), token)
            }
        }

        self._last_kind = LastTokenKind::Name
        return token
    }

    /// FIXME:  this number lexer works but it's not the final
    ///         design. suffix detection is still kinda hacky, exponent rules
    ///         aren't fully spec'd, underscore validation is half-baked, and
    ///         hex-float edge cases are doing whatever they want as long as
    ///         the pipeline doesn't break on basic inputs or downstream stages.
    ///
    /// the rewrite needs:
    /// - a real suffix grammar (not "first non-digit = suffix")
    /// - stricter underscore rules across bases (consistent with clang/gcc)
    /// - consistent error paths for malformed floats
    /// - a saner state machine instead of this stitched logic
    /// - full separation of lexing vs semantic validation
    ///
    priv inline fn lex_number(self, start: SourceLocation, is_dot: bool = false) -> Token {
        var ctx = self.init_number_ctx(start, is_dot)

        while self.scan_number_body(&ctx) && !self.is_eof() {
            0 // keep scanning
        }

        ctx.number_end = self.get_source_location()

        self.scan_number_suffix(&ctx)
        return self.finalize_number(&ctx)
    }

    priv inline fn init_number_ctx(self, start: SourceLocation, is_dot: bool) -> Self::NumberCtx {
        var ctx: Self::NumberCtx

        ctx.start            = start
        ctx.base             = 10
        ctx.has_prefix       = false
        ctx.has_decimal      = is_dot
        ctx.has_exponent     = false
        ctx.allows_sign_next = false

        ctx.prefix_start = SourceLocation()
        ctx.prefix_end   = SourceLocation()
        ctx.number_start = start
        ctx.last         = Self::NumberCtx::LastWasState::None

        // Tuple-index position: the previous token is a member-access separator
        // AND this number is glued to it. `_last_sym` names which separator, so
        // adjacency reduces to "the byte before us is that separator's last
        // byte" `.` for `.`/`?.`, `>` for `->`/`?->`. A gap (`t. 0.5`) leaves
        // the number an ordinary float and lets the parser own the complaint.
        ctx.is_tuple_index = false
        if !is_dot
            && self._last_kind == LastTokenKind::Symbol
            && (self._last_sym == TokenKind::OpDot
                || self._last_sym == TokenKind::OpArrow
                || self._last_sym == TokenKind::OpQuestionDot
                || self._last_sym == TokenKind::OpQuestionArrow)
            && self._cursor > 0 {
            const src:      kairo::std::ConstPtr<u8> = self.file_data()
            var   prev_byte                          = src[self._cursor - 1]
            ctx.is_tuple_index = prev_byte == ('.' as u8) || prev_byte == ('>' as u8)
        }

        var chars = self.peek_char32<2>()

        if !is_dot && chars[0].len == 1 && chars[0].chr == '0' && chars[1].len == 1 {
            match chars[1].chr as u8 {
                case 0x62 /* 'b' */, 0x42 /* 'B' */ {
                    ctx.base       = 2
                    ctx.has_prefix = true
                } case 0x6f /* 'o' */, 0x4f /* 'O' */ {
                    ctx.base       = 8
                    ctx.has_prefix = true
                } case 0x78 /* 'x' */, 0x58 /* 'X' */ {
                    ctx.base       = 16
                    ctx.has_prefix = true
                } default { }
            }

            if ctx.has_prefix {
                ctx.prefix_start = start
                self.advance_cursor(((chars[0].len + chars[1].len) as usize))
                ctx.prefix_end   = self.get_source_location()
                ctx.number_start = ctx.prefix_end
                ctx.last         = Self::NumberCtx::LastWasState::Prefix
                return ctx
            }
        }

        if is_dot {
            self.advance_cursor(((chars[0].len) as usize))
            ctx.last = Self::NumberCtx::LastWasState::Dot
        } else {
            ctx.last = Self::NumberCtx::LastWasState::Digit
        }

        return ctx
    }

    /// \details scans at most 16 characters per call and reports whether the
    ///          caller should come back for more, same contract as before. The
    ///          batched peek_char32::<16> it used to open with is gone: the
    ///          cursor now lives in a local pointer for the whole call, so
    ///          decoding one character at a time costs less than staging
    ///          sixteen DecodeResults and then re-walking them through
    ///          advance_cursor.
    priv inline fn scan_number_body(self, @inout ctx: Self::NumberCtx) -> bool {
        const base: kairo::std::ConstPtr<u8> = self.file_data()
        const end:  kairo::std::ConstPtr<u8> = base + self.file_size()

        var p:    kairo::std::ConstPtr<u8> = base + self._cursor
        var step: usize                    = 0

        for var i: usize = 0; i < 16; ++i {
            if p >= end {
                // EOF used to arrive as a zero-filled DecodeResult that fell
                // through every test below to `return false`. Say it directly.
                self.commit_cursor(base, p, step)
                return false
            }

            var d = Lexer::decode_at(p, (end - p) as usize)
            var c = kairo::normalize_char32(d.chr)

            if ctx.has_exponent {
                if ctx.allows_sign_next && (c == '+' || c == '-') {
                    p += d.len
                    step                 = (d.len as usize)
                    ctx.allows_sign_next = false
                    ctx.last             = Self::NumberCtx::LastWasState::Exponent
                    continue
                }

                if !Lexer::is_decimal_digit(c) {
                    self.commit_cursor(base, p, step)
                    return false
                }

                p += d.len
                step     = (d.len as usize)
                ctx.last = Self::NumberCtx::LastWasState::Digit
                continue
            }

            if c == '_' {
                if ctx.last != Self::NumberCtx::LastWasState::Digit {
                    self.commit_cursor(base, p, step)
                    return false
                }

                ctx.last = Self::NumberCtx::LastWasState::Underscore
                p += d.len
                step = (d.len as usize)
                continue
            }

            if Lexer::is_base_digit(c, ctx.base) {
                ctx.last = Self::NumberCtx::LastWasState::Digit
                p += d.len
                step = (d.len as usize)
                continue
            }

            if c == '.' && ctx.base != 2 && ctx.base != 8 {
                var unsafe *q = p + d.len
                if q < end && q[0] == ('.' as u8) {
                    self.commit_cursor(base, p, step)
                    return false // range operator, stop here
                }

                // A decimal point must be followed by a base digit. Without this `1.`
                // lexes as 1.0, which (a) makes `1.foo()` unreachable and (b) is
                // ambiguous with `1 . <tuple-index>` now that `.N` is member access.
                // Raw byte compare is safe: digits are ASCII and no continuation byte
                // of a multibyte sequence is < 0x80 same reasoning as the `..` check
                // directly above.
                if q >= end
                    || !Lexer::is_base_digit(
                        kairo::normalize_char32(
                            if q[0] < 0x80 => (q[0] as char) else => (0xFFFFFFFF as char),
                        ),
                        ctx.base,
                    ) {
                    self.commit_cursor(base, p, step)
                    return false
                }

                // A tuple index is an ordinal, never a fraction. Stopping here
                // is what makes the second `.` of `t.0.1` its own separator
                // instead of fusing `0.1` into one float.
                if ctx.is_tuple_index {
                    self.commit_cursor(base, p, step)
                    return false
                }

                if ctx.has_decimal
                    || ctx.last == Self::NumberCtx::LastWasState::Dot
                    || ctx.last == Self::NumberCtx::LastWasState::Underscore {
                    self.commit_cursor(base, p, step)
                    return false
                }

                ctx.has_decimal = true
                ctx.last        = Self::NumberCtx::LastWasState::Dot
                p += d.len
                step = (d.len as usize)
                continue
            }

            if Lexer::is_exponent_char(c, ctx.base) {
                if ctx.has_exponent || ctx.last == Self::NumberCtx::LastWasState::Underscore {
                    self.commit_cursor(base, p, step)
                    return false
                }

                ctx.has_exponent     = true
                ctx.allows_sign_next = true
                ctx.last             = Self::NumberCtx::LastWasState::Exponent
                p += d.len
                step = (d.len as usize)
                continue
            }

            self.commit_cursor(base, p, step)
            return false
        }

        self.commit_cursor(base, p, step)
        return true // we are not done yet
    }

    priv inline fn scan_number_suffix(self, @inout ctx: Self::NumberCtx) {
        var d = self.peek_char32()

        if self.is_valid_name(d) != 0 {
            ctx.suffix     = self.lex_name(self.get_source_location())
            ctx.has_suffix = true
        } else {
            ctx.suffix     = Token()
            ctx.has_suffix = false
        }
    }

    priv inline fn finalize_number(self, @inout ctx: Self::NumberCtx) -> Token {
        var is_float = ctx.has_decimal || ctx.has_exponent

        var tok: Token
        tok.set_kind(if is_float => TokenKind::LitFloat else => TokenKind::LitInt)
        tok.set_range(self.create_source_range(ctx.start))

        var imm_idx: u32 = if is_float => (self.create_imm<Immediate::FloatData>())
                           else => self.create_imm<Immediate::IntData>()

        tok.imm = imm_idx

        if is_float {
            var unsafe *imm = self.get_imm<Immediate::FloatData>(imm_idx)

            imm->flags = 0
            imm->base  = ctx.base
            imm->body  = SourceRange::from_bounds(ctx.number_start, ctx.number_end)

            // bit0: has_exponent
            if ctx.has_exponent {
                imm->flags |= 0b00000001
            }

            // bit2: is_hex_float (0x prefix)
            if ctx.base == 16 {
                imm->flags |= 0b00000100
            }

            // bit4: has_suffix
            if ctx.has_suffix {
                imm->flags |= 0b00010000
                imm->suffix = ctx.suffix.range
            }

            if ctx.has_prefix {
                imm->prefix = SourceRange::from_bounds(ctx.prefix_start, ctx.prefix_end)
            }

            imm->evaluate(self._sm, self.get_imm_tbl())
        } else {
            var unsafe *imm = self.get_imm<Immediate::IntData>(imm_idx)

            // lexer fully defines its flag domain
            imm->flags = 0

            imm->base = ctx.base
            imm->body = SourceRange::from_bounds(ctx.number_start, ctx.number_end)

            // bit4: has_prefix
            if ctx.has_prefix {
                imm->flags |= 0b00010000
                imm->prefix = SourceRange::from_bounds(ctx.prefix_start, ctx.prefix_end)
            }

            // bit3: has_suffix
            if ctx.has_suffix {
                imm->flags |= 0b00001000
                imm->suffix = ctx.suffix.range
            }

            imm->evaluate(self._sm, self.get_imm_tbl())
        }

        self._last_kind = LastTokenKind::Number
        return tok
    }

    /// \brief true when the previous token can terminate a postfix chain, which
    ///        makes a following `.` a member-access operator rather than the
    ///        leading dot of a float literal.
    ///
    /// \details `t.0` must lex as `t` `.` `0`, but `x = .5` must still lex `.5`
    ///          as a float. Only what came before the dot distinguishes them.
    ///          `Name` covers identifiers and keywords alike deliberately, so
    ///          `self.0` works. A keyword followed by `.` + digit (`return.5`)
    ///          is a parse error under either reading, so the conflation costs
    ///          nothing but the wording of a diagnostic nobody will hit.
    ///          `Text` is a string/char literal, which likewise ends a postfix
    ///          chain (`"ab".len()`).
    priv inline fn _prev_can_end_postfix(self) -> bool {
        match self._last_kind {
            case LastTokenKind::Name {
                return true
            } case LastTokenKind::Text {
                return true
            } case LastTokenKind::Number {
                return true
            } case LastTokenKind::Symbol {
                return self._last_sym == TokenKind::OpRParen
                    || self._last_sym == TokenKind::OpRSquare
            } default {
                return false
            }
        }
    }

    priv inline fn lex_symbol(self, start: SourceLocation) -> Token {
        const CHARS: cxx::std::array<kairo::DecodeResult, 4> = self.peek_char32<4>(1)
        const C1:    kairo::DecodeResult                     = CHARS[0]
        const C2:    kairo::DecodeResult                     = CHARS[1]
        const C3:    kairo::DecodeResult                     = CHARS[2]
        const C4:    kairo::DecodeResult                     = CHARS[3]

        if !self.is_valid_symbol(C1) {
            self.advance_cursor((C1.len as usize))
            return self.create_unrecognized_token(start)
        }

        // A `.` followed by a digit is a leading-dot float ONLY in value position.
        // After an identifier, a number, `)`, `]`, or `self`, it is member access:
        // `t.0`, `(a, b).1`, `arr[i].0`. Falling through lets the normal symbol
        // path emit OpDot and the digits lex as their own LitInt.
        if C1.chr == '.' && C2.len == 1 && C2.chr >= '0' && C2.chr <= '9' {
            if !self._prev_can_end_postfix() {
                return self.lex_number(start, true)
            }
        }

        var hash1 = HashState()
        hash1.mix(C1.chr as u8)

        var best_hash: u64   = 0
        var best_len:  usize = 0

        var h1 = hash1.finalize()
        if is_valid_token_kind((h1 as u32)) {
            best_hash = h1
            best_len  = 1
        }

        if self.is_valid_symbol(C2) {
            var hash2 = hash1.copy()
            hash2.mix(C2.chr as u8)
            var h2 = hash2.finalize()

            if h2 == 2645673611 /* "//" */ {
                self.advance_cursor(2)
                return self.lex_line_comment(start)
            }

            if h2 == 2645686962 /* "/ *" */ {
                self.advance_cursor(2)
                return self.lex_block_comment(start)
            }

            if h2 == 2644915348 /* "* /" */ {
                self.advance_cursor(2)
                return self.create_error_token(start, TokenKind::AtComment)
            }

            if is_valid_token_kind((h2 as u32)) {
                best_hash = h2
                best_len  = 2
            }

            if self.is_valid_symbol(C3) {
                var hash3 = hash2.copy()
                hash3.mix(C3.chr as u8)
                var h3 = hash3.finalize()

                if is_valid_token_kind((h3 as u32)) {
                    best_hash = h3
                    best_len  = 3
                }

                if self.is_valid_symbol(C4) {
                    var hash4 = hash3.copy()
                    hash4.mix(C4.chr as u8)
                    var h4 = hash4.finalize()

                    if is_valid_token_kind((h4 as u32)) {
                        best_hash = h4
                        best_len  = 4
                    }
                }
            }
        }

        // `>=` / `>>=` directly followed by `>` hands its `=` to a `=>`: a
        // generic close before a value arm (`case Box<i32>=> 1`) would
        // otherwise lex as `>=` `>`. No prefix `>` exists, so `>=>` and
        // `>>=>` are never valid input as `>=` `>` / `>>=` `>`, and the split
        // cannot change the meaning of a program that lexed before. The type
        // parser already splits the `>>` this leaves behind.
        if best_hash == 2619617910 /* ">=" */ && C3.len == 1 && C3.chr == '>' {
            best_hash = 3591191388 /* ">" */
            best_len  = 1
        } else if best_hash == 1861878763 /* ">>=" */ && C4.len == 1 && C4.chr == '>' {
            best_hash = 2619618109 /* ">>" */
            best_len  = 2
        }

        /// ## git conflict marker detection
        /// check for 7+ repeated '<', '=', '>' at the START of a line: git
        /// writes its markers at column 1 and nowhere else. Mid-line, a run
        /// of seven is code -- seven nested generics close with `>>>>>>>`
        /// (`A<A<A<A<A<A<A<i32>>>>>>>`), and taking that for a marker ate the
        /// rest of the line (S049E); six closers or spaced ones lexed.
        var at_line_start = true
        if self._cursor > 0 {
            const src:   kairo::std::ConstPtr<u8> = self.file_data()
            var   before                          = src[self._cursor - 1]
            at_line_start = before == 0x0A || before == 0x0D
        }

        if at_line_start && (C1.chr == '<' || C1.chr == '>' || C1.chr == '=') {
            var conflict_char       = C1.chr
            var run_len:      usize = 0

            // count how many in a row (need 7)
            var scan_offset: isize = 0
            while run_len < 7 {
                var sc = self.peek_char32(scan_offset)
                if sc.chr != conflict_char || sc.len == 0 {
                    break
                }

                run_len += 1
                scan_offset += 1
            }

            if run_len >= 7 {
                // consume to end of line
                var line_start = start
                while !self.is_eof() {
                    var d = self.peek_char32()
                    if d.chr == '\n' || d.chr == '\r' || d.len == 0 {
                        break
                    }

                    self.advance_cursor((d.len as usize))
                }

                match conflict_char {
                    case '<' {
                        self._conflict_state = ConflictMarker::Start
                    } case '=' {
                        self._conflict_state = ConflictMarker::Separator
                    } case '>' {
                        self._conflict_state = ConflictMarker::End
                    } default { }
                }

                // TODO: emit proper conflict diagnostic
                kairo::Logger::warn(
                    kairo::Logger::Stage::Lexer,
                    f"Lexer::lex_symbol: git conflict marker detected ({run_len} chars) at fid={self._fid} cursor={self._cursor}",
                )

                return self.create_error_token(start, TokenKind::TkError, TokenKind::TkError)
            }
        }

        if best_len > 0 {
            self.advance_cursor(best_len)
            return self.make_symbol_token(best_hash, start)
        }

        // No valid token found
        self.advance_cursor(1)
        return self.create_error_token(start, h1 as u32 as TokenKind)
    }

    priv inline fn make_symbol_token(self, hash: u64, start: SourceLocation) -> Token {
        var token = Token()
        token.set_kind(hash as u32 as TokenKind)
        token.set_range(self.create_source_range(start))
        self._last_kind = LastTokenKind::Symbol
        self._last_sym  = (hash as u32 as TokenKind)
        return token
    }

    priv inline fn lex_line_comment(self, start: SourceLocation) -> Token {
        var is_doc = false
        {
            // we have alr consumed the first two chars, so we see if the char we are on is a third '/' or '<'
            var c3 = self.peek_char32()
            is_doc = c3.len == 1 && (c3.chr == '/' || c3.chr == '<')
        }

        const base: kairo::std::ConstPtr<u8> = self.file_data()
        const end:  kairo::std::ConstPtr<u8> = base + self.file_size()

        var p:    kairo::std::ConstPtr<u8> = base + self._cursor
        var step: usize                    = 0

        // A comment body needs no decoding at all: UTF-8 is self-synchronising,
        // so no byte of a multibyte sequence is ever < 0x80 and none of them can
        // be mistaken for the 0x0A/0x0D that ends the run. Scan raw bytes.
        var unsafe *scan_start = p

        while p < end {
            if p[0] == 0x0A || p[0] == 0x0D {
                break
            }

            p += 1
        }

        // The loop never learned a character length, so recover the last one
        // rather than reporting 1 and desyncing _last_advanced.
        step = Lexer::char_len_before(scan_start, p)

        self.commit_cursor(base, p, step) // create_source_range reads _cursor

        var token = Token()
        token.set_kind(TokenKind::AtComment)
        token.set_range(self.create_source_range(start))
        token.set_imm(((if (is_doc) => (1) else => 2) as u32)) // 1=DocComment, 2=LineComment
        return token
    }

    priv inline fn lex_block_comment(self, start: SourceLocation) -> Token {
        var nest_depth: i32  = 1
        var is_doc:     bool = false
        {
            // we have alr consumed the first two chars, so we see if the char we are on is a third '*' or '<'
            var c3 = self.peek_char32()
            is_doc = c3.len == 1 && c3.chr == '*'
        }

        const base: kairo::std::ConstPtr<u8> = self.file_data()
        const end:  kairo::std::ConstPtr<u8> = base + self.file_size()

        var p:    kairo::std::ConstPtr<u8> = base + self._cursor
        var step: usize                    = 0

        // Same as lex_line_comment: the body needs no decoding. Both nesting
        // markers are ASCII pairs, and no byte of a multibyte sequence can be
        // '*' or '/', so a raw byte scan finds exactly the same delimiters.
        var unsafe *scan_start = p

        while p < end && nest_depth > 0 {
            var b0 = p[0]
            var b1 = if (p + 1 < end) => (p[1]) else => (0)

            if b0 == ('*' as u8) && b1 == ('/' as u8) {
                nest_depth -= 1
                p += 2
                continue
            }

            if b0 == ('/' as u8) && b1 == ('*' as u8) {
                nest_depth += 1
                p += 2
                continue
            }

            p += 1
        }

        step = Lexer::char_len_before(scan_start, p)

        self.commit_cursor(base, p, step) // both exits below read _cursor

        if nest_depth > 0 {
            kairo::Logger::warn(
                kairo::Logger::Stage::Lexer,
                f"Lexer::lex_block_comment: unterminated block comment fid={self._fid}",
            )

            return self.create_error_token(start, TokenKind::AtComment)
        }

        var token = Token()
        token.set_kind(TokenKind::AtComment)
        token.set_range(self.create_source_range(start))
        token.set_imm(((if (is_doc) => (3) else => 0) as u32)) // 3=DocBlockComment, 0=None
        return token
    }

    /// TODO: so this is good enough for now but theres a quite a few problems
    ///       starting with if theres a string and nothing else in the file
    ///       no tokens get emitted?
    ///       also error handling is very week here. i have tested a lot of broken
    ///       strings and escapes/etc.
    ///
    priv inline fn lex_text(self, start: SourceLocation, prefix: Token = Token()) -> Token {
        var ctx = self.init_text_ctx(start, prefix)
        if ctx.has_error {
            return ctx.error_token
        }

        self.scan_text_body(&ctx)

        if !self.finalize_text(&ctx) {
            return self.create_error_token(start, TokenKind::LitString)
        }

        self.lex_text_suffix(&ctx)
        self.emit_fstring_exprs(&ctx)

        var head = self.make_text_token(&ctx)
        self.chain_adjacent_text(&ctx)

        return head
    }

    /// \brief links an adjacent string literal onto this one via StringData::next.
    ///
    /// \details `"a" "b"`, including split across newlines, is one logical
    ///          string. Each segment keeps its own imm entry - body range,
    ///          prefix, suffix, f-string exprs - and the entries are linked
    ///          head-to-tail through StringData::next, so a diagnostic can
    ///          still blame the exact segment a byte came from rather than the
    ///          fused whole. Only the head token reaches the parser.
    ///
    ///          lex_text recurses through this, so a run of any length links in
    ///          a single pass: each call chains the one segment after it, and
    ///          that segment chains the next.
    ///
    /// \note    Only `"` chains. A char literal is a single codepoint, and a
    ///          prefixed continuation (`"a" r"b"`) is deliberately left alone
    ///          because the segments would disagree about escape handling.
    ///
    /// \warning the cursor is restored when no adjacent literal follows. The
    ///          newline after a lone string is a statement terminator and must
    ///          survive this lookahead.
    priv inline fn chain_adjacent_text(self, @inout ctx: Self::TextCtx) {
        if ctx.delim != 0x22 {
            return
        }

        var saved = self._cursor

        // inter-segment whitespace, newlines included
        while !self.is_eof() {
            var w = self.peek_char32()
            if w.chr == ' ' || w.chr == '\t' || w.chr == '\n' || w.chr == '\r' {
                self.advance_cursor((w.len as usize))
                continue
            }

            break
        }

        if self.is_eof() || self.peek_char32().chr != '"' {
            self._cursor = saved
            return
        }

        var seg = self.lex_text(self.get_source_location())
        if seg.kind == TokenKind::LitString {
            *ctx.imm.get_next() = seg.imm
        } else {
            self._cursor = saved
        }
    }

    priv inline fn init_text_ctx(self, start: SourceLocation, prefix: Token) -> Self::TextCtx {
        var ctx: Self::TextCtx
        ctx.lexer     = &self
        ctx.start     = start
        ctx.has_error = false

        var d = self.peek_char32()
        if d.chr != '"' && d.chr != '\'' {
            ctx.has_error = true
            kairo::Logger::error(
                kairo::Logger::Stage::Lexer,
                f"Lexer::scan_text_body: unterminated string at fid={self._fid} cursor={self._cursor}",
            )

            var _r015 = SourceRange::from_bounds(start, self.get_source_location())
            self._diag->report(
                DiagCode(DiagID::S015E),
                _r015.start,
                f"expected string or character literal delimiter ('\"' or ''')",
            ).first(_r015)->emit()
            ctx.error_token = self.create_error_token(start, TokenKind::LitString)
            return ctx
        }

        ctx.delim     = (d.chr as u8)
        ctx.is_triple = false

        self.advance_cursor((d.len as usize)) // consume opening delim #1

        // triple-quote: only for " (a char literal is a single codepoint, never triple)
        if ctx.delim == 0x22 {
            var q2 = self.peek_char32()
            var q3 = self.peek_char32(1)
            if q2.chr == '"' && q3.chr == '"' {
                ctx.is_triple = true
                self.advance_cursor(((q2.len + q3.len) as usize)) // consume delims #2 and #3
            }
        }

        ctx.body_start = self.get_source_location()

        if ctx.delim == 0x22 {
            ctx.imm_idx = self.create_imm<Immediate::StringData>()
            ctx.imm     = Self::TextImm(unsafe &self, ctx.delim, ctx.imm_idx)
        } else {
            ctx.imm_idx = self.create_imm<Immediate::CharData>()
            ctx.imm     = Self::TextImm(unsafe &self, ctx.delim, ctx.imm_idx)
        }

        ctx.is_format = false
        ctx.is_raw    = false

        if prefix == TokenKind::LitIdentifier {
            ctx.is_format = (prefix.imm & self.PFX_FORMAT) != 0
            ctx.is_raw    = (prefix.imm & self.PFX_RAW) != 0
            ctx.prefix    = prefix
        }

        ctx.in_format_depth  = 0
        ctx.in_bracket_depth = 0
        ctx.terminators      = cxx::std::stack<SourceLocation>()
        ctx.fstring_specs    = llvm::SmallVector<Self::TextCtx::FormatSpec, 4>()

        return ctx
    }

    /// \details split into a raw-pointer fast path for literal content and a
    ///          cursor-backed slow path (scan_text_special) for the five bytes
    ///          that can do something other than "advance one character".
    ///          Everything interesting in a string literal   diagnostics,
    ///          f-string expression offsets, the escape scanner   reads
    ///          _cursor, so the cursor is committed before the slow path runs
    ///          and the scan pointer is re-derived from it afterwards.
    priv inline fn scan_text_body(self, @inout ctx: Self::TextCtx) {
        const base: kairo::std::ConstPtr<u8> = self.file_data()
        const end:  kairo::std::ConstPtr<u8> = base + self.file_size()

        var p:    kairo::std::ConstPtr<u8> = base + self._cursor
        var step: usize                    = 0

        while p < end {
            var d = Lexer::decode_at(p, (end - p) as usize)

            // fast path: plain content. a multibyte codepoint is always > 0x7f
            // and can never equal one of these, so the test is exact.
            if ctx.in_format_depth == 0
                && d.chr != '"'
                && d.chr != '\''
                && d.chr != '{'
                && d.chr != '}'
                && d.chr != '\\' {
                p += d.len
                step = (d.len as usize)
                continue
            }

            self.commit_cursor(base, p, step)
            step = 0

            if !self.scan_text_special(&ctx, d) {
                return // closing delimiter consumed
            }

            // the slow path moved the cursor itself (possibly by a lot, as with
            // is_valid_escape or a nested f-string expression).
            p = base + self._cursor
        }

        self.commit_cursor(base, p, step)

        ctx.has_error = true
        var _r012 = SourceRange::from_bounds(ctx.start, self.get_source_location())
        self._diag->report(
            DiagCode(DiagID::S012E),
            _r012.start,
            if (ctx.is_triple) => ("unterminated string literal; add a closing '\"\"\"' to end the string")
            else => "unterminated string literal; add a closing '\"' to end the string",
        ).first(_r012)->emit()
    }

    /// \brief handles the one character scan_text_body's fast path refused.
    ///
    /// \details every branch here needs a live _cursor, so the caller commits
    ///          before calling and re-reads _cursor after. Advances through
    ///          advance_cursor exactly as the inlined switch used to.
    ///
    /// \returns false once the closing delimiter has been consumed and the
    ///          literal is complete; true to keep scanning.
    priv inline fn scan_text_special(self,
                                     @inout ctx: Self::TextCtx,
                                     d:          kairo::DecodeResult) -> bool {
        if ctx.in_format_depth > 0 {
            self.scan_format_expr(&ctx, d)
            return true
        }

        match d.chr {
            case '"', '\'' {
                if d.chr == (ctx.delim as char) {
                    if ctx.is_triple {
                        // need three in a row to close
                        var q2 = self.peek_char32(1)
                        var q3 = self.peek_char32(2)
                        if q2.chr == (ctx.delim as char) && q3.chr == (ctx.delim as char) {
                            ctx.body_end = self.get_source_location()
                            self.advance_cursor(((d.len + q2.len + q3.len) as usize)) // consume all three
                            return false
                        }

                        // fewer than three: this quote is content
                        self.advance_cursor((d.len as usize))
                    } else {
                        ctx.body_end = self.get_source_location()
                        self.advance_cursor((d.len as usize))
                        return false
                    }
                } else {
                    self.advance_cursor((d.len as usize)) // a different quote char, content
                }
            } case '{' { // {
                if ctx.is_format {
                    ctx.in_format_depth  = 1
                    ctx.in_bracket_depth = 0
                    ctx.terminators.push(self.get_source_location())
                    self.advance_cursor((d.len as usize))

                    ctx.fstring_specs.push_back(
                        Self::TextCtx::FormatSpec {
                            start:      self._cursor,
                            end:        0,
                            spec_start: 0,
                            eq_pos:     0,
                        },
                    )

                    return true
                }

                self.advance_cursor((d.len as usize))
            } case '}' { // } - this is only called if our format depth is 0
                if ctx.is_format {
                    ctx.has_error = true
                    var _r016 = SourceRange::from_bounds(
                        self.get_source_location(),
                        self.get_source_location(self._cursor + (d.len as usize)),
                    )

                    self._diag->report(
                        DiagCode(DiagID::S016E),
                        _r016.start,
                        "unmatched '}' in format string literal; use '\\\\}' for a literal brace",
                    ).first(_r016)->emit()
                }

                self.advance_cursor((d.len as usize))
            } case '\\' { // backslash (raw-aware branch the only 0x5c case)
                if ctx.is_raw {
                    var nxt = self.peek_char32(1)
                    // in a triple-quoted raw string a lone " is content, not a terminator,
                    // so \" does not end the string and must not warn.
                    if !ctx.is_triple && nxt.chr == (ctx.delim as char) {
                        var _r = SourceRange::from_bounds(
                            self.get_source_location(),
                            self.get_source_location(
                                self._cursor + (d.len as usize) + (nxt.len as usize),
                            ),
                        )

                        self._diag->report(
                            DiagCode(DiagID::S017W),
                            _r.start,
                            "backslash doesn't escape in raw string literal; the quote ends the string here",
                        ).first(_r)->emit() // TODO: add a clean fix message too
                    }

                    self.advance_cursor((d.len as usize)) // backslash only, always literal in raw
                } else {
                    var esc_start = self.get_source_location()
                    self.advance_cursor((d.len as usize))
                    if !self.is_valid_escape(esc_start, ctx.is_raw, ctx.is_format) {
                        ctx.has_error = true
                    }
                }
            } default {
                self.advance_cursor((d.len as usize))
            }
        }

        return true
    }

    /// \brief one character inside a hole.
    ///
    /// \details beyond the nesting that finds the closing `}`, this records
    ///          the two things the hole's TOKENS cannot carry: where a format
    ///          spec begins (`{x:>4}`) and whether the hole is self-documenting
    ///          (`{x=}`). Both are decided by the byte, at nesting depth 1 and
    ///          outside any bracket, so `{f(a: 1)}`, `{m["k"]}`, `{Foo::bar}`
    ///          and `{a == b}` stay whole expressions. The spec bytes are never
    ///          lexed: `>4`, `#x`, `?` and `08.3` are not tokens.
    priv inline fn scan_format_expr(self, @inout ctx: Self::TextCtx, d: kairo::DecodeResult) {
        var top = ctx.in_format_depth == 1
            && ctx.in_bracket_depth == 0
            && ctx.fstring_specs.back().spec_start == 0

        match d.chr {
            case '"', '\'' { // " or ' string inside expression
                self.advance_cursor((d.len as usize))
                self.scan_string_in_fstring_expr(d.chr)
            } case '(', '[' { // ( [
                ++ctx.in_bracket_depth
                self.advance_cursor((d.len as usize))
            } case ')', ']' { // ) ]
                if ctx.in_bracket_depth > 0 {
                    --ctx.in_bracket_depth
                }

                self.advance_cursor((d.len as usize))
            } case '{' { // {
                ++ctx.in_format_depth
                ctx.terminators.push(self.get_source_location())
                self.advance_cursor((d.len as usize))
            } case '}' { // }
                --ctx.in_format_depth
                if ctx.in_format_depth == 0 {
                    ctx.fstring_specs.back().end = self._cursor
                }

                ctx.terminators.pop()
                self.advance_cursor((d.len as usize))
            } case ':' { // : opens the spec, unless it is half of a `::`
                const src: kairo::std::ConstPtr<u8> = self.file_data()
                var prev: u8 = if (self._cursor > 0) => (src[self._cursor - 1]) else => (0)
                var next     = self.peek_char32(1)
                if top && prev != (':' as u8) && next.chr != ':' {
                    ctx.fstring_specs.back().spec_start = self._cursor + (d.len as usize)
                }

                self.advance_cursor((d.len as usize))
            } case '=' { // = is self-documenting when it is the last thing before `}` or `:`
                var next = self.peek_char32(1)
                if top && (next.chr == '}' || next.chr == ':') {
                    const src: kairo::std::ConstPtr<u8> = self.file_data()
                    var prev: u8 = if (self._cursor > 0) => (src[self._cursor - 1]) else => (0)
                    // `{a == }` / `{a != }` / `{a <= }` are comparisons with a stray space, not doc holes.
                    if prev != ('=' as u8)
                        && prev != ('!' as u8)
                        && prev != ('<' as u8)
                        && prev != ('>' as u8) {
                        ctx.fstring_specs.back().eq_pos = self._cursor
                    }
                }

                self.advance_cursor((d.len as usize))
            } case '\n' { // newline
                ctx.has_error = true
                var _r018 = SourceRange::from_bounds(
                    self.get_source_location(),
                    self.get_source_location(self._cursor + (d.len as usize)),
                )

                self._diag->report(
                    DiagCode(DiagID::S018E),
                    _r018.start,
                    "newline inside format string interpolation expression; expressions must be on a single line",
                ).first(_r018)->emit()
                self.advance_cursor((d.len as usize))
            } default {
                self.advance_cursor((d.len as usize))
            }
        }
    }

    /// \brief scans a string literal inside an f-string expression
    /// \details skips to matching quote, handling escapes but not nested f-strings
    priv inline fn scan_string_in_fstring_expr(self, quote: char) {
        // opening quote already consumed
        while !self.is_eof() {
            var c = self.peek_char32()

            if c.chr == quote {
                self.advance_cursor((c.len as usize))
                return
            }

            if c.chr == '\\' { // backslash escape
                self.advance_cursor((c.len as usize))
                if !self.is_eof() {
                    var next = self.peek_char32()
                    self.advance_cursor((next.len as usize))
                }

                continue
            }

            self.advance_cursor((c.len as usize))
        }

        // unterminated error will be caught by outer f-string termination check
    }

    priv inline fn finalize_text(self, @inout ctx: Self::TextCtx) -> bool {
        if ctx.has_error {
            return false
        }

        if !ctx.terminators.empty() {
            return false
        }

        return true
    }

    priv inline fn lex_text_suffix(self, @inout ctx: Self::TextCtx) {
        if self.is_valid_name(self.peek_char32()) != 0 {
            var suffix = self.lex_name(self.get_source_location())
            if suffix.kind != TokenKind::TkUnknown {
                (*ctx.imm.get_suffix()).set_range(suffix.range)
            }
        }
    }

    /// \brief lexes each hole's EXPRESSION and records what the tokens
    ///        cannot carry. The expression stops at the `=` of `{x=}`, else
    ///        at the `:` of a spec, else at the `}`; only that slice is
    ///        lexed. The spec is handed on as a byte range for X to parse.
    priv inline fn emit_fstring_exprs(self, @inout ctx: Self::TextCtx) {
        if !ctx.is_format {
            return
        }

        for *spec in ctx.fstring_specs {
            var expr_end = spec->end
            if spec->spec_start != 0 {
                expr_end = spec->spec_start - 1
            }

            if spec->eq_pos != 0 {
                expr_end = spec->eq_pos
            }

            ctx.imm.get_exprs()->push_back(
                (
                    self.lex_slice<16>((spec->start as u32), (expr_end as u32)),
                    self.create_source_range(spec->start, expr_end),
                ),
            )

            var hole = Immediate::HoleSpec{}
            hole.spec = if (spec->spec_start != 0) => (self.create_source_range(
                            spec->spec_start,
                            spec->end,
                        ))
                        else => SourceRange::invalid()
            var doc_end = if (spec->spec_start != 0) => (spec->spec_start - 1) else => spec->end
            hole.doc = if (spec->eq_pos != 0) => (self.create_source_range(spec->start, doc_end))
                       else => SourceRange::invalid()
            ctx.imm.get_holes()->push_back(hole)
        }
    }

    priv inline fn make_text_token(self, @inout ctx: Self::TextCtx) -> Token {
        var tok: Token
        tok.set_kind(if ctx.delim == 0x22 => TokenKind::LitString else => TokenKind::LitChar)
        tok.set_range(self.create_source_range(ctx.start))
        tok.imm         = ctx.imm_idx
        self._last_kind = LastTokenKind::Text

        *ctx.imm.get_body() = SourceRange::from_bounds(ctx.body_start, ctx.body_end)

        *ctx.imm.get_prefix() = ctx.prefix
        var prefix_kind = FlagSet<Immediate::TextPrefixKind, u8>()
        if ctx.is_raw {
            prefix_kind.set(Immediate::TextPrefixKind::Raw)
        }

        if ctx.is_format {
            prefix_kind.set(Immediate::TextPrefixKind::Format)
        }

        *ctx.imm.get_prefix_kind() = prefix_kind

        return tok
    }

    priv inline fn lex_illegal(self, start: SourceLocation) -> Token {
        return self.lex_name(start)
    }

    priv inline fn lex_whitespace(self,
                                  start:       SourceLocation,
                                  first_char:  char,
                                  first_len:   usize,
                                  first_class: kairo::CharClass) -> Token {
        /// we consume all whitespace and newlines here
        /// we can batch spaces and newlines into a single new line
        /// we also batch just spaces into a single space token
        /// mixing spaces and newlines creates a new line token
        /// newlines do need to be tracked for line endings since `;` are optional
        /// at the end of lines in Kairo.

        var token:    Token = Token()
        var nl_count: usize = 0

        match first_class {
            case kairo::CharClass::Whitespace {
                token.set_kind(TokenKind::TkWhitespace)
            } case kairo::CharClass::NewLine {
                token.set_kind(TokenKind::TkNewLine)
                ++nl_count
            } default {
                self.advance_cursor() // consume first char
                return self.create_unrecognized_token(start)
            }
        }

        const base: kairo::std::ConstPtr<u8> = self.file_data()
        const end:  kairo::std::ConstPtr<u8> = base + self.file_size()

        // the first character was already classified by get_token; charge it to
        // the run here rather than paying a member round-trip for it.
        var p:    kairo::std::ConstPtr<u8> = base + self._cursor + first_len
        var step: usize                    = first_len

        while p < end {
            var current_char      = Lexer::decode_at(p, (end - p) as usize)
            var c:           char = kairo::normalize_char32(current_char.chr)

            match self.classify(c) {
                case kairo::CharClass::Whitespace {
                    if token != TokenKind::TkNewLine {
                        token.set_kind(TokenKind::TkWhitespace)
                    }
                } case kairo::CharClass::NewLine {
                    token.set_kind(TokenKind::TkNewLine)
                    ++nl_count
                } default {
                    // the run ends BEFORE this character; it is not consumed.
                    self.commit_cursor(base, p, step)
                    token.set_range(self.create_source_range(start))
                    token.imm = (nl_count as u32)
                    return token
                }
            }

            p += current_char.len
            step = (current_char.len as usize)
        }

        self.commit_cursor(base, p, step)
        token.set_range(self.create_source_range(start))
        token.imm = (nl_count as u32)
        return token
    }

    /// \details switch over MACRO_UNICODE_OPERATOR_CHAR_CASES replaced by the
    ///          ASCII_LEX_FLAGS table it is now generated from. Same set, one
    ///          load and a mask.
    inline static fn is_valid_symbol(c: kairo::DecodeResult) -> bool {
        return kairo::is_operator_char(c.chr, c.len)
    }

    /// \brief classifies a character for identifier/keyword scanning.
    /// \returns 0 not a name character, 1 keyword-safe ASCII, 2 identifier-only.
    ///
    /// \details the 63-case switch over MACRO_UNICODE_KEYWORD_CASES is now the
    ///          ASCII_LEX_FLAGS table generated from that same macro. This is
    ///          called once per character by lex_name's scan loop, and the old
    ///          body was far too large to inline into it.
    inline static fn is_valid_name(c: kairo::DecodeResult) -> u8 {
        return kairo::name_char_kind(c.chr, c.len)
    }

    priv inline fn is_valid_escape(self,
                                   start:     SourceLocation,
                                   is_byte:   bool,
                                   is_format: bool) -> bool {
        var chars = self.peek_char32<10>()

        // 2 classes one for octal and one for hex
        // 2 very simple classes contains a is_digit function and a push_back function
        // both store values in usize internally and have a check(against: usize) -> bool function
        // and a getter to return the final value along with a digits count

        match chars[0].chr {
            /// byte escapes
            case 'n',  'r', 't', 'v', 'f', 'a', '\'', '"',
                 '\\' { // both
                self.advance_cursor(((chars[0].len) as usize))
            }

            /// standard escapes / both
            case '{', '}' { // both
                self.advance_cursor(((chars[0].len) as usize))

                if is_format {
                    return true
                }

                var range = SourceRange::from_bounds(start, self.get_source_location())

                self._diag->report(
                    DiagCode(DiagID::S022W),
                    range.start,
                    "'\\{' and '\\}' escapes are only valid inside format strings (f\"...\"); remove the backslash or use an f-string prefix",
                ).first(range)->emit()
                return false
            } case 'x', 'X' { // both // \xHH (exactly 2 hex digits)
                var hex_parser = HexParser()
                self.advance_cursor(((chars[0].len) as usize))

                for var i: usize = 1; i <= 2; ++i {
                    if !hex_parser.is_digit(chars[i].chr) {
                        var range = SourceRange::from_bounds(start, self.get_source_location())

                        self.advance_cursor(((chars[i].len) as usize))
                        self._diag->report(
                            DiagCode(DiagID::S023E),
                            range.start,
                            f"invalid '\\x' hex escape '{self._sm->get_text(range)}': expected exactly 2 hex digits (0-9, a-f, A-F)",
                        ).first(range)->emit()
                        return false
                    }

                    hex_parser.push_back(chars[i].chr)
                    self.advance_cursor(((chars[i].len) as usize))
                }

                var value = hex_parser.get_value()

                // explicit byte-range check
                if value > 0xFF {
                    var range = SourceRange::from_bounds(start, self.get_source_location())

                    self._diag->report(
                        DiagCode(DiagID::S024E),
                        range.start,
                        f"hex escape '{self._sm->get_text(range)}' is out of byte range (0x00-0xFF)",
                    ).first(range)->emit()
                    return false
                }
            } case '0', '1', '2', '3', // \ooo (1-3 octal digits)
                 '4', '5', '6', '7' { // only byte
                var octal_parser = OctalParser()

                // first digit is guaranteed to be valid
                octal_parser.push_back(chars[0].chr)
                self.advance_cursor(((chars[0].len) as usize))

                // we have no loops since we need exactly 1-3 digits
                if octal_parser.is_digit(chars[1].chr) {
                    octal_parser.push_back(chars[1].chr)
                    self.advance_cursor(((chars[1].len) as usize))

                    if octal_parser.is_digit(chars[2].chr) {
                        octal_parser.push_back(chars[2].chr)
                        self.advance_cursor(((chars[2].len) as usize))
                    }
                }

                if !is_byte {
                    var range = SourceRange::from_bounds(start, self.get_source_location())

                    self._diag->report(
                        DiagCode(DiagID::S025W),
                        range.start,
                        f"octal escape '{self._sm->get_text(range)}' is only valid in byte strings (b\"...\"); use '\\u' for unicode codepoints",
                    ).first(range)->emit()
                }

                /// we now validate the value
                var value = octal_parser.get_value()

                if octal_parser.get_digits() < 1 || octal_parser.get_digits() > 3 {
                    // defensive: should never happen
                    var range = SourceRange::from_bounds(start, self.get_source_location())

                    self._diag->report(
                        DiagCode(DiagID::S026E),
                        range.start,
                        f"octal escape '{self._sm->get_text(range)}' must contain 1 to 3 digits",
                    ).first(range)->emit()
                    return false
                }

                // explicit byte-range check
                if value > 0xFF {
                    var range = SourceRange::from_bounds(start, self.get_source_location())

                    self._diag->report(
                        DiagCode(DiagID::S027E),
                        range.start,
                        f"octal escape '{self._sm->get_text(range)}' is out of byte range (0-255, i.e., \\0-\\377)",
                    ).first(range)->emit()
                    return false
                }
            } case 'u' { // only !byte // \uHHHH (exactly 4 hex digits)
                var hex_parser = HexParser()
                self.advance_cursor(((chars[0].len) as usize))

                for var i: usize = 1; i <= 4; ++i {
                    if !hex_parser.is_digit(chars[i].chr) {
                        var range = SourceRange::from_bounds(start, self.get_source_location())

                        self.advance_cursor(((chars[i].len) as usize))
                        self._diag->report(
                            DiagCode(DiagID::S028E),
                            range.start,
                            f"invalid '\\u' unicode escape '{self._sm->get_text(range)}': expected exactly 4 hex digits (0-9, a-f, A-F)",
                        ).first(range)->emit()
                        return false
                    }

                    hex_parser.push_back(chars[i].chr)
                    self.advance_cursor(((chars[i].len) as usize))
                }

                if is_byte {
                    var range = SourceRange::from_bounds(start, self.get_source_location())

                    self._diag->report(
                        DiagCode(DiagID::S029E),
                        range.start,
                        f"unicode escape '\\u' is not valid in a byte string; use '\\x' for raw byte values",
                    ).first(range)->emit()
                    return false
                }

                var value = hex_parser.get_value()

                // check for valid unicode range
                if value > 0xFFFF {
                    // defensive: impossible with 4 hex digits, but documents intent
                    var range = SourceRange::from_bounds(start, self.get_source_location())

                    self._diag->report(
                        DiagCode(DiagID::S030E),
                        range.start,
                        f"unicode escape '{self._sm->get_text(range)}' is out of the valid range (U+0000-U+FFFF for '\\u')",
                    ).first(range)->emit()
                    return false
                }

                // Surrogate halves are invalid Unicode scalar values
                if value >= 0xD800 && value <= 0xDFFF {
                    var range = SourceRange::from_bounds(start, self.get_source_location())

                    self._diag->report(
                        DiagCode(DiagID::S031E),
                        range.start,
                        f"unicode escape '{self._sm->get_text(range)}' encodes a surrogate code point (U+D800-U+DFFF), which is not a valid unicode scalar value",
                    ).first(range)->emit()
                    return false
                }
            } case 'U' { // only !byte // \UHHHHHHHH (exactly 8 hex digits)
                var hex_parser = HexParser()
                self.advance_cursor(((chars[0].len) as usize))

                // we have no loops since we need exactly 8 digits
                for var i: usize = 1; i <= 8; ++i {
                    if !hex_parser.is_digit(chars[i].chr) {
                        var range = SourceRange::from_bounds(start, self.get_source_location())

                        self.advance_cursor(((chars[i].len) as usize))
                        self._diag->report(
                            DiagCode(DiagID::S028E),
                            range.start,
                            f"invalid '\\U' unicode escape '{self._sm->get_text(range)}': expected exactly 8 hex digits (0-9, a-f, A-F)",
                        ).first(range)->emit()
                        return false
                    }

                    hex_parser.push_back(chars[i].chr)
                    self.advance_cursor(((chars[i].len) as usize))
                }

                if is_byte {
                    var range = SourceRange::from_bounds(start, self.get_source_location())

                    self._diag->report(
                        DiagCode(DiagID::S029E),
                        range.start,
                        f"unicode escape '\\U' is not valid in a byte string; use '\\x' for raw byte values",
                    ).first(range)->emit()
                    return false
                }

                var value = hex_parser.get_value()

                // check for valid unicode range
                if value > 0x10FFFF {
                    var range = SourceRange::from_bounds(start, self.get_source_location())

                    self._diag->report(
                        DiagCode(DiagID::S030E),
                        range.start,
                        f"unicode escape '{self._sm->get_text(range)}' is out of the valid unicode range (U+0000-U+10FFFF)",
                    ).first(range)->emit()
                    return false
                }

                // Surrogate halves are invalid Unicode scalar values
                if value >= 0xD800 && value <= 0xDFFF {
                    var range = SourceRange::from_bounds(start, self.get_source_location())

                    self._diag->report(
                        DiagCode(DiagID::S031E),
                        range.start,
                        f"unicode escape '{self._sm->get_text(range)}' encodes a surrogate code point (U+D800-U+DFFF), which is not a valid unicode scalar value",
                    ).first(range)->emit()
                    return false
                }
            } case 'b' { // only !byte // \b (backspace)
                self.advance_cursor(((chars[0].len) as usize))

                if !is_byte {
                    return true
                }

                var range = SourceRange::from_bounds(start, self.get_source_location())

                self._diag->report(
                    DiagCode(DiagID::S032E),
                    range.start,
                    f"'\\b' (backspace) escape is not valid in a byte string; use '\\x08' instead",
                ).first(range)->emit()
                return false
            } default {
                self.advance_cursor(((chars[0].len) as usize))

                var range = SourceRange::from_bounds(start, self.get_source_location())

                self._diag->report(
                    DiagCode(DiagID::S033E),
                    range.start,
                    f"unknown escape sequence '{self._sm->get_text(range)}'",
                ).first(range)->emit()
                return false
            }
        }

        return true
    }

    /// \brief errors emitted by THIS lexer's most recent lex() run.
    ///
    /// \details the DiagEngine is shared across the whole compilation, so its
    ///          raw counts are cumulative; comparing against the baseline
    ///          captured at lex() entry gives the per-run delta. Anything else
    ///          makes one file's (or one test's) errors bleed into the next.
    inline fn has_errors(self) -> bool {
        return self.error_count() > 0
    }

    inline fn error_count(self) -> u32 {
        return self._diag->error_count() - self._err_base
    }

    inline static fn set_kind(tok: *Token, hash_state: *HashState) {
        var hash: u64 = hash_state->finalize()

        if is_valid_token_kind((hash as u32)) {
            tok->kind = (hash as u32 as TokenKind)
            return
        } else {
            tok->kind = TokenKind::TkError
            tok->imm  = (hash as u32)
            return
        }
    }

    fn <T> get_imm(self, imm_idx: u32) -> unsafe *T {
        return self.get_imm_tbl()->get<T>(imm_idx)
    }

    fn <T> create_imm(self) -> u32 {
        return self.get_imm_tbl()->create<T>()
    }

    pub fn get_imm_tbl(self) -> unsafe *ImmediateTable {
        if self._imm_tbl == &null {
            kairo::std::ice_fail("lexer has no imm table owner must supply one")
        }

        return self._imm_tbl
    }

    fn intern_ident(self, data: unsafe *const u8, len: usize, hash: u32) -> u32 {
        return self.get_imm_tbl()->intern_ident(data, len, hash)
    }

    fn wait_for_imm_evaluation(self) {
        self.get_imm_tbl()->wait_for_evaluation()
    }

    static fn get_text(token: Token, sm: *SourceManager) -> string {
        return sm->get_text(token.range)
    }
}

pub fn Test() -> i32 {
    io::println("=== Lexer Test Suite ===\n ")

    var test_diag = DiagEngine()
    // The test lambdas below capture by copy (stage1 semantics), and a
    // DiagEngine is not copyable: they share the engine through this pointer.
    var unsafe *test_diag_p = unsafe &test_diag
    var unsafe *pool        = kairo::std::create<ThreadPool>(4)
    var unsafe *vfm         = kairo::std::create<VirtualFileManager>(test_diag_p)
    // the engine is shared across every test case and error-case tests run at
    // ~1000 iterations each; past _error_limit errors go to suppressed_count
    // instead of error_count, which would zero the per-lex deltas the tests
    // assert on. effectively unlimited for the suite.
    test_diag.set_error_limit(u32::MAX)
    var unsafe *sm   = kairo::std::create<SourceManager>(pool, vfm, test_diag_p)
    var        suite = Assert("Lexer Tests")

    // HELPER: Create a lexer from string content
    static data:     cxx::std::string
    static test_imm: unsafe *ImmediateTable = &null

    finally {
        if test_imm != &null {
            kairo::std::destroy(test_imm)
            test_imm = &null
        }

        kairo::std::destroy(sm)
        kairo::std::destroy(vfm)
        kairo::std::destroy(pool)
    }

    var create_lexer_from_string_with_diag = fn (content: string, lsm: unsafe *SourceManager, lpool: unsafe *ThreadPool, diag: unsafe *DiagEngine) -> (unsafe *Lexer, u32) {
        var temp_path = Path::temp_dir().join("hlx_lexer_test.k")
        lsm->reset()
        var temp_data = content
        data = kairo::std::to_std_string(temp_data)

        var        path = Path(temp_path, false)
        var unsafe *ptr = unsafe (data.data() as kairo::std::ConstPtr<u8>)
        var        fid  = lsm->load_virtual(path, ptr, data.size())

        // imm table is TCM-owned in production; the suite has no TCM, so it owns
        // one itself. rebuilt per call so interner state does not bleed between
        // tests   several assert on first-intern behavior.
        if test_imm != &null {
            kairo::std::destroy(test_imm)
        }

        test_imm = kairo::std::create<ImmediateTable>()
        test_imm->initialize(lsm)

        var unsafe *lexer = kairo::std::create<Lexer>(lsm, lpool, diag, test_imm)

        return (lexer, fid)
    }

    /// Narrow-bytes variant, for the hot-loop benchmark.
    ///
    /// (Historical: `string` was wchar_t-backed.) Staging a 1 GiB corpus as one cost 4 GiB
    /// of wide buffer and then pays a 1 GiB wide->narrow conversion that lands
    /// in profiles as string_to_nstring + wcslen. Neither has anything to do
    /// with lexing   the lexer only ever sees the narrow bytes   but both were
    /// being attributed to the lex run. Take the bytes already narrow.
    var create_lexer_from_bytes = fn (@move bytes: cxx::std::string, lsm: unsafe *SourceManager, lpool: unsafe *ThreadPool, diag: unsafe *DiagEngine) -> (unsafe *Lexer, u32) {
        var temp_path = Path::temp_dir().join("hlx_lexer_test.k")
        lsm->reset()
        data = cxx::std::move(bytes)

        var        path = Path(temp_path, false)
        var unsafe *ptr = unsafe (data.data() as kairo::std::ConstPtr<u8>)
        var        fid  = lsm->load_virtual(path, ptr, data.size())

        if test_imm != &null {
            kairo::std::destroy(test_imm)
        }

        test_imm = kairo::std::create<ImmediateTable>()
        test_imm->initialize(lsm)

        var unsafe *lexer = kairo::std::create<Lexer>(lsm, lpool, diag, test_imm)

        return (lexer, fid)
    }

    // HELPER: Dump tokens for debugging

    var dump_tokens = fn (tokens: unsafe *(TokenBuffer<512>), expected_count: usize, text: string = "none provided") -> string {
        var ret = ""
        for var i: usize = 0; i < tokens->size(); ++i {
            ret += f"\t{(*(tokens->get(i))) as string}, text: '{sm->get_text(tokens->get(i)->range)}'\n"
        }

        ret += f"\texpected {expected_count} tokens but got {tokens->size()}"
        return f"invalid token count\n\tgot tokens:\n{ret}"
    }

    // HELPER: content token count

    // the lexer appends a trailing TkEof to every stream; test expectations
    // count CONTENT tokens, so compare against this instead of size().
    var content_count = fn (tokens: unsafe *(TokenBuffer<512>)) -> usize {
        var n = tokens->size()
        if n > 0 && tokens->get(n - 1)->kind == TokenKind::TkEof {
            return n - 1
        }

        return n
    }

    // BASIC TOKENIZATION

    suite.equal<string>(
        "lex empty file",
        "pass",
        fn () -> string {
            var        res    = create_lexer_from_string_with_diag(" ", sm, pool, test_diag_p)
            var unsafe *lexer = res.0
            var        fid    = res.1

            finally {
                kairo::std::destroy(lexer)
            }

            if !lexer->lex(fid) {
                return "lexer failed to lex"
            }

            var unsafe *tokens = lexer->tokens()
            if content_count(tokens) != 0 {
                return f"expected 0 tokens for empty file, got {tokens->size()}"
            }

            if lexer->has_errors() {
                return f"lexer reported {lexer->error_count()} error(s) (check DiagEngine consumer for details)"
            }

            return "pass"
        },
        1000,
    )

    suite.equal<string>(
        "lex single identifier",
        "pass",
        fn () -> string {
            var        res    = create_lexer_from_string_with_diag("foo", sm, pool, test_diag_p)
            var unsafe *lexer = res.0
            var        fid    = res.1

            finally {
                kairo::std::destroy(lexer)
            }

            if !lexer->lex(fid) {
                return "lexer failed to lex"
            }

            var unsafe *tokens = lexer->tokens()
            if content_count(tokens) != 1 {
                return dump_tokens(tokens, 1)
            }

            var unsafe *tok = tokens->get(0)
            if tok->kind != TokenKind::LitIdentifier {
                return f"expected LitIdentifier, got {token_kind_to_readable_string(tok->kind)}"
            }

            if sm->get_text(tok->range) != "foo" {
                return f"expected text 'foo', got '{sm->get_text(tok->range)}'"
            }

            if lexer->has_errors() {
                return f"lexer reported {lexer->error_count()} error(s) (check DiagEngine consumer for details)"
            }

            return "pass"
        },
        1000,
    )

    suite.equal<string>(
        "lex keywords",
        "pass",
        fn () -> string {
            var res = create_lexer_from_string_with_diag(
                "fn var const class if else while for return",
                sm,
                pool,
                test_diag_p,
            )

            var unsafe *lexer = res.0
            var        fid    = res.1

            finally {
                kairo::std::destroy(lexer)
            }

            if !lexer->lex(fid) {
                return "lexer failed to lex"
            }

            var unsafe *tokens  = lexer->tokens()
            var        expected = cxx::std::vector<TokenKind>()
            expected.push_back(TokenKind::KwFn)
            expected.push_back(TokenKind::KwVar)
            expected.push_back(TokenKind::KwConst)
            expected.push_back(TokenKind::KwClass)
            expected.push_back(TokenKind::KwIf)
            expected.push_back(TokenKind::KwElse)
            expected.push_back(TokenKind::KwWhile)
            expected.push_back(TokenKind::KwFor)
            expected.push_back(TokenKind::KwReturn)

            if content_count(tokens) != expected.size() {
                return dump_tokens(tokens, expected.size())
            }

            for var i: usize = 0; i < expected.size(); ++i {
                if tokens->get(i)->kind != expected[i] {
                    return f"token {i}: expected {token_kind_to_readable_string(expected[i])}, got {token_kind_to_readable_string(tokens->get(i)->kind)}"
                }
            }

            if lexer->has_errors() {
                return f"lexer reported {lexer->error_count()} error(s) (check DiagEngine consumer for details)"
            }

            return "pass"
        },
        1000,
    )

    suite.equal<string>(
        "lex all primitive types",
        "pass",
        fn () -> string {
            var res = create_lexer_from_string_with_diag(
                "void bool i8 i16 i32 i64 i128 u8 u16 u32 u64 u128 f32 f64 usize isize",
                sm,
                pool,
                test_diag_p,
            )

            var unsafe *lexer = res.0
            var        fid    = res.1

            finally {
                kairo::std::destroy(lexer)
            }

            if !lexer->lex(fid) {
                return "lexer failed to lex"
            }

            var unsafe *tokens  = lexer->tokens()
            var        expected = cxx::std::vector<TokenKind>()
            expected.push_back(TokenKind::AtVoid)
            expected.push_back(TokenKind::AtBool)
            expected.push_back(TokenKind::AtI8)
            expected.push_back(TokenKind::AtI16)
            expected.push_back(TokenKind::AtI32)
            expected.push_back(TokenKind::AtI64)
            expected.push_back(TokenKind::AtI128)
            expected.push_back(TokenKind::AtU8)
            expected.push_back(TokenKind::AtU16)
            expected.push_back(TokenKind::AtU32)
            expected.push_back(TokenKind::AtU64)
            expected.push_back(TokenKind::AtU128)
            expected.push_back(TokenKind::AtF32)
            expected.push_back(TokenKind::AtF64)
            expected.push_back(TokenKind::AtUsize)
            expected.push_back(TokenKind::AtIsize)

            if content_count(tokens) != expected.size() {
                return dump_tokens(tokens, expected.size())
            }

            for var i: usize = 0; i < expected.size(); ++i {
                if tokens->get(i)->kind != expected[i] {
                    return f"token {i}: expected {token_kind_to_readable_string(expected[i])}, got {token_kind_to_readable_string(tokens->get(i)->kind)}"
                }
            }

            if lexer->has_errors() {
                return f"lexer reported {lexer->error_count()} error(s) (check DiagEngine consumer for details)"
            }

            return "pass"
        },
        1000,
    )

    suite.equal<string>(
        "lex identifier with hash",
        "pass",
        fn () -> string {
            var res = create_lexer_from_string_with_diag("foo#bar my#ident", sm, pool, test_diag_p)
            var unsafe *lexer = res.0
            var        fid    = res.1

            finally {
                kairo::std::destroy(lexer)
            }

            if !lexer->lex(fid) {
                return "lexer failed to lex"
            }

            var unsafe *tokens = lexer->tokens()
            if content_count(tokens) != 2 {
                return dump_tokens(tokens, 2)
            }

            if tokens->get(0)->kind != TokenKind::LitIdentifier {
                return f"token 0: expected LitIdentifier, got {token_kind_to_readable_string(tokens->get(0)->kind)}"
            }

            if tokens->get(1)->kind != TokenKind::LitIdentifier {
                return f"token 1: expected LitIdentifier, got {token_kind_to_readable_string(tokens->get(1)->kind)}"
            }

            if lexer->has_errors() {
                return f"lexer reported {lexer->error_count()} error(s) (check DiagEngine consumer for details)"
            }

            return "pass"
        },
        1000,
    )

    // OPERATORS AND PUNCTUATION

    suite.equal<string>(
        "lex single-char operators",
        "pass",
        fn () -> string {
            var res = create_lexer_from_string_with_diag(
                "+ - * / % ^ | & ~ < > ! = ? @ : ; , .",
                sm,
                pool,
                test_diag_p,
            )

            var unsafe *lexer = res.0
            var        fid    = res.1

            finally {
                kairo::std::destroy(lexer)
            }

            if !lexer->lex(fid) {
                return "lexer failed to lex"
            }

            var unsafe *tokens  = lexer->tokens()
            var        expected = cxx::std::vector<TokenKind>()
            expected.push_back(TokenKind::OpPlus)
            expected.push_back(TokenKind::OpMinus)
            expected.push_back(TokenKind::OpStar)
            expected.push_back(TokenKind::OpSlash)
            expected.push_back(TokenKind::OpPercent)
            expected.push_back(TokenKind::OpCaret)
            expected.push_back(TokenKind::OpPipe)
            expected.push_back(TokenKind::OpAmp)
            expected.push_back(TokenKind::OpTilde)
            expected.push_back(TokenKind::OpLess)
            expected.push_back(TokenKind::OpGreater)
            expected.push_back(TokenKind::OpExclaim)
            expected.push_back(TokenKind::OpEqual)
            expected.push_back(TokenKind::OpQuestion)
            expected.push_back(TokenKind::OpAt)
            expected.push_back(TokenKind::OpColon)
            expected.push_back(TokenKind::OpSemicolon)
            expected.push_back(TokenKind::OpComma)
            expected.push_back(TokenKind::OpDot)

            if content_count(tokens) != expected.size() {
                return dump_tokens(tokens, expected.size())
            }

            for var i: usize = 0; i < expected.size(); ++i {
                if tokens->get(i)->kind != expected[i] {
                    return f"token {i}: expected {token_kind_to_readable_string(expected[i])}, got {token_kind_to_readable_string(tokens->get(i)->kind)}"
                }
            }

            if lexer->has_errors() {
                return f"lexer reported {lexer->error_count()} error(s) (check DiagEngine consumer for details)"
            }

            return "pass"
        },
        1000,
    )

    suite.equal<string>(
        "lex multi-char operators",
        "pass",
        fn () -> string {
            var res = create_lexer_from_string_with_diag(
                "++ -- -> :: .. ... == != <= >= && || << >> += -= *= /= <=> =>",
                sm,
                pool,
                test_diag_p,
            )

            var unsafe *lexer = res.0
            var        fid    = res.1

            finally {
                kairo::std::destroy(lexer)
            }

            if !lexer->lex(fid) {
                return "lexer failed to lex"
            }

            var unsafe *tokens  = lexer->tokens()
            var        expected = cxx::std::vector<TokenKind>()
            expected.push_back(TokenKind::OpPlusPlus)
            expected.push_back(TokenKind::OpMinusMinus)
            expected.push_back(TokenKind::OpArrow)
            expected.push_back(TokenKind::OpColonColon)
            expected.push_back(TokenKind::OpRange)
            expected.push_back(TokenKind::OpEllipsis)
            expected.push_back(TokenKind::OpEqualEqual)
            expected.push_back(TokenKind::OpExclaimEqual)
            expected.push_back(TokenKind::OpLessEqual)
            expected.push_back(TokenKind::OpGreaterEqual)
            expected.push_back(TokenKind::OpAmpAmp)
            expected.push_back(TokenKind::OpPipePipe)
            expected.push_back(TokenKind::OpLessLess)
            expected.push_back(TokenKind::OpGreaterGreater)
            expected.push_back(TokenKind::OpPlusEqual)
            expected.push_back(TokenKind::OpMinusEqual)
            expected.push_back(TokenKind::OpStarEqual)
            expected.push_back(TokenKind::OpSlashEqual)
            expected.push_back(TokenKind::OpLessEqualGreater)
            expected.push_back(TokenKind::OpFatArrow)

            if content_count(tokens) != expected.size() {
                return dump_tokens(tokens, expected.size())
            }

            for var i: usize = 0; i < expected.size(); ++i {
                if tokens->get(i)->kind != expected[i] {
                    return f"token {i}: expected {token_kind_to_readable_string(expected[i])}, got {token_kind_to_readable_string(tokens->get(i)->kind)}"
                }
            }

            if lexer->has_errors() {
                return f"lexer reported {lexer->error_count()} error(s) (check DiagEngine consumer for details)"
            }

            return "pass"
        },
        1000,
    )

    suite.equal<string>(
        "lex brackets",
        "pass",
        fn () -> string {
            var        res    = create_lexer_from_string_with_diag("{ } ( ) [ ]", sm, pool, test_diag_p)
            var unsafe *lexer = res.0
            var        fid    = res.1

            finally {
                kairo::std::destroy(lexer)
            }

            if !lexer->lex(fid) {
                return "lexer failed to lex"
            }

            var unsafe *tokens = lexer->tokens()
            if content_count(tokens) != 6 {
                return dump_tokens(tokens, 6)
            }

            if tokens->get(0)->kind != TokenKind::OpLBrace {
                return f"token 0: expected OpLBrace, got {token_kind_to_readable_string(tokens->get(0)->kind)}"
            }

            if tokens->get(1)->kind != TokenKind::OpRBrace {
                return f"token 1: expected OpRBrace, got {token_kind_to_readable_string(tokens->get(1)->kind)}"
            }

            if tokens->get(2)->kind != TokenKind::OpLParen {
                return f"token 2: expected OpLParen, got {token_kind_to_readable_string(tokens->get(2)->kind)}"
            }

            if tokens->get(3)->kind != TokenKind::OpRParen {
                return f"token 3: expected OpRParen, got {token_kind_to_readable_string(tokens->get(3)->kind)}"
            }

            if tokens->get(4)->kind != TokenKind::OpLSquare {
                return f"token 4: expected OpLSquare, got {token_kind_to_readable_string(tokens->get(4)->kind)}"
            }

            if tokens->get(5)->kind != TokenKind::OpRSquare {
                return f"token 5: expected OpRSquare, got {token_kind_to_readable_string(tokens->get(5)->kind)}"
            }

            if lexer->has_errors() {
                return f"lexer reported {lexer->error_count()} error(s) (check DiagEngine consumer for details)"
            }

            return "pass"
        },
        1000,
    )

    suite.equal<string>(
        "lex arrow variants",
        "pass",
        fn () -> string {
            var res = create_lexer_from_string_with_diag(
                "-> ->* ?-> ?->* !-> !->*",
                sm,
                pool,
                test_diag_p,
            )

            var unsafe *lexer = res.0
            var        fid    = res.1

            finally {
                kairo::std::destroy(lexer)
            }

            if !lexer->lex(fid) {
                return "lexer failed to lex"
            }

            var unsafe *tokens = lexer->tokens()
            // note: there are no '!->' / '!->*' compound tokens   bang lexes
            // separately, so '!->' is OpExclaim + OpArrow (8 content tokens).
            if content_count(tokens) != 8 {
                return dump_tokens(tokens, 8)
            }

            var expected = cxx::std::vector<TokenKind>()
            expected.push_back(TokenKind::OpArrow)
            expected.push_back(TokenKind::OpArrowStar)
            expected.push_back(TokenKind::OpQuestionArrow)
            expected.push_back(TokenKind::OpQuestionArrowStar)
            expected.push_back(TokenKind::OpExclaim)
            expected.push_back(TokenKind::OpArrow)
            expected.push_back(TokenKind::OpExclaim)
            expected.push_back(TokenKind::OpArrowStar)
            for var i: usize = 0; i < 8; ++i {
                if tokens->get(i)->kind != expected[i] {
                    return f"token {i}: expected {token_kind_to_readable_string(expected[i])}, got {token_kind_to_readable_string(tokens->get(i)->kind)}"
                }
            }

            if lexer->has_errors() {
                return f"lexer reported {lexer->error_count()} error(s) (check DiagEngine consumer for details)"
            }

            return "pass"
        },
        100,
    )

    suite.equal<string>(
        "lex dot variants",
        "pass",
        fn () -> string {
            var res = create_lexer_from_string_with_diag(
                ". .* ?. ?.* !. !.*",
                sm,
                pool,
                test_diag_p,
            )

            var unsafe *lexer = res.0
            var        fid    = res.1

            finally {
                kairo::std::destroy(lexer)
            }

            if !lexer->lex(fid) {
                return "lexer failed to lex"
            }

            var unsafe *tokens = lexer->tokens()
            // note: there are no '!.' / '!.*' compound tokens   bang lexes
            // separately, so '!.' is OpExclaim + OpDot (8 content tokens).
            if content_count(tokens) != 8 {
                return dump_tokens(tokens, 8)
            }

            var expected = cxx::std::vector<TokenKind>()
            expected.push_back(TokenKind::OpDot)
            expected.push_back(TokenKind::OpDotStar)
            expected.push_back(TokenKind::OpQuestionDot)
            expected.push_back(TokenKind::OpQuestionDotStar)
            expected.push_back(TokenKind::OpExclaim)
            expected.push_back(TokenKind::OpDot)
            expected.push_back(TokenKind::OpExclaim)
            expected.push_back(TokenKind::OpDotStar)
            for var i: usize = 0; i < 8; ++i {
                if tokens->get(i)->kind != expected[i] {
                    return f"token {i}: expected {token_kind_to_readable_string(expected[i])}, got {token_kind_to_readable_string(tokens->get(i)->kind)}"
                }
            }

            if lexer->has_errors() {
                return f"lexer reported {lexer->error_count()} error(s) (check DiagEngine consumer for details)"
            }

            return "pass"
        },
        1000,
    )

    // the reason '!->' / '!.' must NOT lex as compound tokens: 'foo!' is a
    // macro invocation, so 'foo!->bar' is (expansion of foo!)->bar. this is
    // the identifier-adjacent case the lexer's bang tracking actually has to
    // get right   'foo', '!', '->', 'bar'.
    suite.equal<string>(
        "lex macro invoke followed by member access",
        "pass",
        fn () -> string {
            var res = create_lexer_from_string_with_diag(
                "foo!->bar foo!.baz",
                sm,
                pool,
                test_diag_p,
            )

            var unsafe *lexer = res.0
            var        fid    = res.1

            finally {
                kairo::std::destroy(lexer)
            }

            if !lexer->lex(fid) {
                return "lexer failed to lex"
            }

            var unsafe *tokens = lexer->tokens()
            if content_count(tokens) != 8 {
                return dump_tokens(tokens, 8)
            }

            var expected = cxx::std::vector<TokenKind>()
            expected.push_back(TokenKind::LitIdentifier)
            expected.push_back(TokenKind::OpExclaim)
            expected.push_back(TokenKind::OpArrow)
            expected.push_back(TokenKind::LitIdentifier)
            expected.push_back(TokenKind::LitIdentifier)
            expected.push_back(TokenKind::OpExclaim)
            expected.push_back(TokenKind::OpDot)
            expected.push_back(TokenKind::LitIdentifier)
            for var i: usize = 0; i < 8; ++i {
                if tokens->get(i)->kind != expected[i] {
                    return f"token {i}: expected {token_kind_to_readable_string(expected[i])}, got {token_kind_to_readable_string(tokens->get(i)->kind)}"
                }
            }

            if lexer->has_errors() {
                return f"lexer reported {lexer->error_count()} error(s) (check DiagEngine consumer for details)"
            }

            return "pass"
        },
        1000,
    )

    // INTEGER LITERALS

    suite.equal<string>(
        "lex decimal integers",
        "pass",
        fn () -> string {
            var res = create_lexer_from_string_with_diag(
                "0 1 42 12345 999999",
                sm,
                pool,
                test_diag_p,
            )

            var unsafe *lexer = res.0
            var        fid    = res.1

            finally {
                kairo::std::destroy(lexer)
            }

            if !lexer->lex(fid) {
                return "lexer failed to lex"
            }

            var unsafe *tokens               = lexer->tokens()
            const      expected_count: usize = (5)
            if content_count(tokens) != expected_count {
                return dump_tokens(tokens, expected_count)
            }

            var expected_values = cxx::std::vector<u64>()
            expected_values.push_back(0 as u64)
            expected_values.push_back(1 as u64)
            expected_values.push_back(42 as u64)
            expected_values.push_back(12345 as u64)
            expected_values.push_back(999999 as u64)

            for var i: usize = 0; i < expected_count; ++i {
                if tokens->get(i)->kind != TokenKind::LitInt {
                    return f"token {i}: expected LitInt, got {token_kind_to_readable_string(tokens->get(i)->kind)}"
                }

                var unsafe *imm = lexer->get_imm<Immediate::IntData>(tokens->get(i)->imm)
                imm->evaluate(sm, lexer->get_imm_tbl())

                const base_10: u8 = (10)
                if imm->base != base_10 {
                    return f"token {i}: expected base 10, got base {imm->base}"
                }

                if imm->value_lo != expected_values[i] {
                    return f"token {i}: expected value {expected_values[i]}, got {imm->value_lo}"
                }

                const zero_u64: u64 = (0)
                if imm->value_hi != zero_u64 {
                    return f"token {i}: expected value_hi 0, got {imm->value_hi}"
                }
            }

            if lexer->has_errors() {
                return f"lexer reported {lexer->error_count()} error(s) (check DiagEngine consumer for details)"
            }

            return "pass"
        },
        1000,
    )

    suite.equal<string>(
        "lex hex integers",
        "pass",
        fn () -> string {
            var res = create_lexer_from_string_with_diag(
                "0x0 0xFF 0xDEADBEEF 0X123ABC",
                sm,
                pool,
                test_diag_p,
            )

            var unsafe *lexer = res.0
            var        fid    = res.1

            finally {
                kairo::std::destroy(lexer)
            }

            if !lexer->lex(fid) {
                return "lexer failed to lex"
            }

            var unsafe *tokens               = lexer->tokens()
            const      expected_count: usize = (4)
            if content_count(tokens) != expected_count {
                return dump_tokens(tokens, expected_count)
            }

            var expected_values = cxx::std::vector<u64>()
            expected_values.push_back(0x0 as u64)
            expected_values.push_back(0xFF as u64)
            expected_values.push_back(0xDEADBEEF as u64)
            expected_values.push_back(0x123ABC as u64)

            for var i: usize = 0; i < expected_count; ++i {
                if tokens->get(i)->kind != TokenKind::LitInt {
                    return f"token {i}: expected LitInt, got {token_kind_to_readable_string(tokens->get(i)->kind)}"
                }

                var unsafe *imm = lexer->get_imm<Immediate::IntData>(tokens->get(i)->imm)
                imm->evaluate(sm, lexer->get_imm_tbl())

                const base_16: u8 = (16)
                if imm->base != base_16 {
                    return f"token {i}: expected base 16, got base {imm->base}"
                }

                if imm->value_lo != expected_values[i] {
                    return f"token {i}: expected value 0x{to_hex_string(((expected_values[i]) as usize))}, got 0x{to_hex_string(((imm->value_lo) as usize))}"
                }

                const has_prefix_flag: u8 = (0b00010000)
                if (imm->flags & has_prefix_flag) == 0 {
                    return f"token {i}: expected has_prefix flag (bit4) to be set"
                }
            }

            if lexer->has_errors() {
                return f"lexer reported {lexer->error_count()} error(s) (check DiagEngine consumer for details)"
            }

            return "pass"
        },
        1000,
    )

    suite.equal<string>(
        "lex binary integers",
        "pass",
        fn () -> string {
            var res = create_lexer_from_string_with_diag(
                "0b0 0b1 0b1010 0B11110000",
                sm,
                pool,
                test_diag_p,
            )

            var unsafe *lexer = res.0
            var        fid    = res.1

            finally {
                kairo::std::destroy(lexer)
            }

            if !lexer->lex(fid) {
                return "lexer failed to lex"
            }

            var unsafe *tokens               = lexer->tokens()
            const      expected_count: usize = (4)
            if content_count(tokens) != expected_count {
                return dump_tokens(tokens, expected_count)
            }

            var expected_values = cxx::std::vector<u64>()
            expected_values.push_back(0b0 as u64)
            expected_values.push_back(0b1 as u64)
            expected_values.push_back(0b1010 as u64)
            expected_values.push_back(0b11110000 as u64)

            for var i: usize = 0; i < expected_count; ++i {
                if tokens->get(i)->kind != TokenKind::LitInt {
                    return f"token {i}: expected LitInt, got {token_kind_to_readable_string(tokens->get(i)->kind)}"
                }

                var unsafe *imm = lexer->get_imm<Immediate::IntData>(tokens->get(i)->imm)
                imm->evaluate(sm, lexer->get_imm_tbl())

                const base_2: u8 = (2)
                if imm->base != base_2 {
                    return f"token {i}: expected base 2, got base {imm->base}"
                }

                if imm->value_lo != expected_values[i] {
                    return f"token {i}: expected value {expected_values[i]}, got {imm->value_lo}"
                }
            }

            if lexer->has_errors() {
                return f"lexer reported {lexer->error_count()} error(s) (check DiagEngine consumer for details)"
            }

            return "pass"
        },
        1000,
    )

    suite.equal<string>(
        "lex octal integers",
        "pass",
        fn () -> string {
            var res = create_lexer_from_string_with_diag(
                "0o0 0o7 0o755 0O1234567",
                sm,
                pool,
                test_diag_p,
            )

            var unsafe *lexer = res.0
            var        fid    = res.1

            finally {
                kairo::std::destroy(lexer)
            }

            if !lexer->lex(fid) {
                return "lexer failed to lex"
            }

            var unsafe *tokens               = lexer->tokens()
            const      expected_count: usize = (4)
            if content_count(tokens) != expected_count {
                return dump_tokens(tokens, expected_count)
            }

            var expected_values = cxx::std::vector<u64>()
            expected_values.push_back(0 as u64)
            expected_values.push_back(7 as u64)
            expected_values.push_back(0755 as u64)     // octal literal in C++
            expected_values.push_back(01234567 as u64) // octal literal in C++

            for var i: usize = 0; i < expected_count; ++i {
                if tokens->get(i)->kind != TokenKind::LitInt {
                    return f"token {i}: expected LitInt, got {token_kind_to_readable_string(tokens->get(i)->kind)}"
                }

                var unsafe *imm = lexer->get_imm<Immediate::IntData>(tokens->get(i)->imm)
                imm->evaluate(sm, lexer->get_imm_tbl())

                const base_8: u8 = (8)
                if imm->base != base_8 {
                    return f"token {i}: expected base 8, got base {imm->base}"
                }

                if imm->value_lo != expected_values[i] {
                    return f"token {i}: expected value {expected_values[i]}, got {imm->value_lo}"
                }
            }

            if lexer->has_errors() {
                return f"lexer reported {lexer->error_count()} error(s) (check DiagEngine consumer for details)"
            }

            return "pass"
        },
        1000,
    )

    suite.equal<string>(
        "lex integers with underscores",
        "pass",
        fn () -> string {
            var res = create_lexer_from_string_with_diag(
                "1_000 1_000_000 0xFF_FF 0b1010_1010",
                sm,
                pool,
                test_diag_p,
            )

            var unsafe *lexer = res.0
            var        fid    = res.1

            finally {
                kairo::std::destroy(lexer)
            }

            if !lexer->lex(fid) {
                return "lexer failed to lex"
            }

            var unsafe *tokens               = lexer->tokens()
            const      expected_count: usize = (4)
            if content_count(tokens) != expected_count {
                return dump_tokens(tokens, expected_count)
            }

            var expected_values = cxx::std::vector<u64>()
            expected_values.push_back(1000 as u64)
            expected_values.push_back(1000000 as u64)
            expected_values.push_back(0xFFFF as u64)
            expected_values.push_back(0b10101010 as u64)

            var expected_bases = cxx::std::vector<u8>()
            expected_bases.push_back(10 as u8)
            expected_bases.push_back(10 as u8)
            expected_bases.push_back(16 as u8)
            expected_bases.push_back(2 as u8)

            for var i: usize = 0; i < expected_count; ++i {
                if tokens->get(i)->kind != TokenKind::LitInt {
                    return f"token {i}: expected LitInt, got {token_kind_to_readable_string(tokens->get(i)->kind)}"
                }

                var unsafe *imm = lexer->get_imm<Immediate::IntData>(tokens->get(i)->imm)
                imm->evaluate(sm, lexer->get_imm_tbl())

                if imm->base != expected_bases[i] {
                    return f"token {i}: expected base {expected_bases[i]}, got base {imm->base}"
                }

                if imm->value_lo != expected_values[i] {
                    return f"token {i}: expected value {expected_values[i]}, got {imm->value_lo}"
                }
            }

            if lexer->has_errors() {
                return f"lexer reported {lexer->error_count()} error(s) (check DiagEngine consumer for details)"
            }

            return "pass"
        },
        1000,
    )

    suite.equal<string>(
        "lex integers with suffixes",
        "pass",
        fn () -> string {
            var res = create_lexer_from_string_with_diag(
                "42u8 100i32 0xFFu64",
                sm,
                pool,
                test_diag_p,
            )

            var unsafe *lexer = res.0
            var        fid    = res.1

            finally {
                kairo::std::destroy(lexer)
            }

            if !lexer->lex(fid) {
                return "lexer failed to lex"
            }

            var unsafe *tokens               = lexer->tokens()
            const      expected_count: usize = (3)
            if content_count(tokens) != expected_count {
                return dump_tokens(tokens, expected_count)
            }

            var expected_values = cxx::std::vector<u64>()
            expected_values.push_back(42 as u64)
            expected_values.push_back(100 as u64)
            expected_values.push_back(0xFF as u64)

            var expected_bits = cxx::std::vector<u16>()
            expected_bits.push_back(8 as u16)
            expected_bits.push_back(32 as u16)
            expected_bits.push_back(64 as u16)

            var expected_unsigned = cxx::std::vector<u8>()
            expected_unsigned.push_back(1) // u8
            expected_unsigned.push_back(0) // i32
            expected_unsigned.push_back(1) // u64

            for var i: usize = 0; i < expected_count; ++i {
                if tokens->get(i)->kind != TokenKind::LitInt {
                    return f"token {i}: expected LitInt, got {token_kind_to_readable_string(tokens->get(i)->kind)}"
                }

                var unsafe *imm = lexer->get_imm<Immediate::IntData>(tokens->get(i)->imm)

                const has_suffix_flag: u8 = (0b00001000)
                if (imm->flags & has_suffix_flag) == 0 {
                    return f"token {i}: expected has_suffix flag (bit3) to be set, flags={imm->flags}"
                }

                imm->evaluate(sm, lexer->get_imm_tbl())

                if imm->value_lo != expected_values[i] {
                    return f"token {i}: expected value {expected_values[i]}, got {imm->value_lo}"
                }

                if imm->bits != expected_bits[i] {
                    return f"token {i}: expected bits {expected_bits[i]}, got {imm->bits}"
                }

                const unsigned_flag: u8 = (0b00000001)
                var   is_unsigned       = (imm->flags & unsigned_flag) != 0
                if is_unsigned != (expected_unsigned[i] != 0) {
                    return f"token {i}: expected unsigned={(expected_unsigned[i] != 0)}, got unsigned={is_unsigned}"
                }
            }

            if lexer->has_errors() {
                return f"lexer reported {lexer->error_count()} error(s) (check DiagEngine consumer for details)"
            }

            return "pass"
        },
        1000,
    )

    suite.equal<string>(
        "lex large 64-bit integer",
        "pass",
        fn () -> string {
            var res = create_lexer_from_string_with_diag( // u64 max
                "18446744073709551615",
                sm,
                pool,
                test_diag_p,
            )

            var unsafe *lexer = res.0
            var        fid    = res.1

            finally {
                kairo::std::destroy(lexer)
            }

            if !lexer->lex(fid) {
                return "lexer failed to lex"
            }

            var unsafe *tokens               = lexer->tokens()
            const      expected_count: usize = (1)
            if content_count(tokens) != expected_count {
                return dump_tokens(tokens, expected_count)
            }

            var unsafe *imm = lexer->get_imm<Immediate::IntData>(tokens->get(0)->imm)
            imm->evaluate(sm, lexer->get_imm_tbl())

            const u64_max: u64 = (0xFFFFFFFFFFFFFFFF)
            if imm->value_lo != u64_max {
                return f"expected u64 max (0xFFFFFFFFFFFFFFFF), got 0x{to_hex_string(((imm->value_lo) as usize))}"
            }

            const zero_u64: u64 = (0)
            if imm->value_hi != zero_u64 {
                return f"expected value_hi 0, got {imm->value_hi}"
            }

            const bits_64: u16 = (64)
            if imm->bits != bits_64 {
                return f"expected bits 64, got {imm->bits}"
            }

            if lexer->has_errors() {
                return f"lexer reported {lexer->error_count()} error(s) (check DiagEngine consumer for details)"
            }

            return "pass"
        },
        1000,
    )

    suite.equal<string>(
        "lex 128-bit integer",
        "pass",
        fn () -> string {
            // 0x1_00000000_00000000 = 2^64 (requires 128 bits)
            var res = create_lexer_from_string_with_diag(
                "0x1_00000000_00000000",
                sm,
                pool,
                test_diag_p,
            )

            var unsafe *lexer = res.0
            var        fid    = res.1

            finally {
                kairo::std::destroy(lexer)
            }

            if !lexer->lex(fid) {
                return "lexer failed to lex"
            }

            var unsafe *tokens               = lexer->tokens()
            const      expected_count: usize = (1)
            if content_count(tokens) != expected_count {
                return dump_tokens(tokens, expected_count)
            }

            var unsafe *imm = lexer->get_imm<Immediate::IntData>(tokens->get(0)->imm)
            imm->evaluate(sm, lexer->get_imm_tbl())

            const zero_u64: u64 = (0)
            const one_u64:  u64 = (1)
            if imm->value_lo != zero_u64 {
                return f"expected value_lo 0, got 0x{to_hex_string(((imm->value_lo) as usize))}"
            }

            if imm->value_hi != one_u64 {
                return f"expected value_hi 1, got 0x{to_hex_string(((imm->value_hi) as usize))}"
            }

            const bits_128: u16 = (128)
            if imm->bits != bits_128 {
                return f"expected bits 128, got {imm->bits}"
            }

            if lexer->has_errors() {
                return f"lexer reported {lexer->error_count()} error(s) (check DiagEngine consumer for details)"
            }

            return "pass"
        },
        1000,
    )

    suite.equal<string>(
        "lex 128-bit max integer",
        "pass",
        fn () -> string {
            // 0xFFFFFFFFFFFFFFFF_FFFFFFFFFFFFFFFF = 2^128 - 1
            var res = create_lexer_from_string_with_diag(
                "0xFFFFFFFFFFFFFFFF_FFFFFFFFFFFFFFFF",
                sm,
                pool,
                test_diag_p,
            )

            var unsafe *lexer = res.0
            var        fid    = res.1

            finally {
                kairo::std::destroy(lexer)
            }

            if !lexer->lex(fid) {
                return "lexer failed to lex"
            }

            var unsafe *tokens               = lexer->tokens()
            const      expected_count: usize = (1)
            if content_count(tokens) != expected_count {
                return dump_tokens(tokens, expected_count)
            }

            var unsafe *imm = lexer->get_imm<Immediate::IntData>(tokens->get(0)->imm)
            imm->evaluate(sm, lexer->get_imm_tbl())

            const u64_max: u64 = (0xFFFFFFFFFFFFFFFF)
            if imm->value_lo != u64_max {
                return f"expected value_lo 0xFFFFFFFFFFFFFFFF, got 0x{to_hex_string(((imm->value_lo) as usize))}"
            }

            if imm->value_hi != u64_max {
                return f"expected value_hi 0xFFFFFFFFFFFFFFFF, got 0x{to_hex_string(((imm->value_hi) as usize))}"
            }

            const bits_128: u16 = (128)
            if imm->bits != bits_128 {
                return f"expected bits 128, got {imm->bits}"
            }

            if lexer->has_errors() {
                return f"lexer reported {lexer->error_count()} error(s) (check DiagEngine consumer for details)"
            }

            return "pass"
        },
        1000,
    )

    suite.equal<string>(
        "lex ImmBigInt integer (>128 bits)",
        "pass",
        fn () -> string {
            // 0x1_00000000_00000000_00000000_00000000 = 2^128 (requires ImmBigInt)
            var res = create_lexer_from_string_with_diag(
                "0x1_00000000_00000000_00000000_00000000",
                sm,
                pool,
                test_diag_p,
            )

            var unsafe *lexer = res.0
            var        fid    = res.1

            finally {
                kairo::std::destroy(lexer)
            }

            if !lexer->lex(fid) {
                return "lexer failed to lex"
            }

            var unsafe *tokens               = lexer->tokens()
            const      expected_count: usize = (1)
            if content_count(tokens) != expected_count {
                return dump_tokens(tokens, expected_count)
            }

            var unsafe *imm = lexer->get_imm<Immediate::IntData>(tokens->get(0)->imm)
            imm->evaluate(sm, lexer->get_imm_tbl())

            // should have is_big flag set
            const is_big_flag: u8 = (0b00000100)
            if (imm->flags & is_big_flag) == 0 {
                return f"expected is_big flag (bit2) to be set, flags={imm->flags}"
            }

            if imm->big == &null {
                return "expected big pointer to be set for >128-bit integer"
            }

            // value_lo and value_hi should be the lower 128 bits (which are 0)
            const zero_u64: u64 = (0)
            const one_u64:  u64 = (1)
            if imm->value_lo != zero_u64 {
                return f"expected value_lo 0, got 0x{to_hex_string(((imm->value_lo) as usize))}"
            }

            if imm->value_hi != zero_u64 {
                return f"expected value_hi 0, got 0x{to_hex_string(((imm->value_hi) as usize))}"
            }

            // check ImmBigInt has correct structure
            const min_limbs: usize = (3)
            if imm->big->limbs.size() < min_limbs {
                return f"expected at least 3 limbs, got {imm->big->limbs.size()}"
            }

            if imm->big->limbs[0] != zero_u64 {
                return f"expected limb[0] = 0, got 0x{to_hex_string(((imm->big->limbs[0]) as usize))}"
            }

            if imm->big->limbs[1] != zero_u64 {
                return f"expected limb[1] = 0, got 0x{to_hex_string(((imm->big->limbs[1]) as usize))}"
            }

            if imm->big->limbs[2] != one_u64 {
                return f"expected limb[2] = 1, got 0x{to_hex_string(((imm->big->limbs[2]) as usize))}"
            }

            const min_bits: u16 = (129)
            if imm->bits < min_bits {
                return f"expected bits >= 129, got {imm->bits}"
            }

            if lexer->has_errors() {
                return f"lexer reported {lexer->error_count()} error(s) (check DiagEngine consumer for details)"
            }

            return "pass"
        },
        1000,
    )

    suite.equal<string>(
        "lex integer bit width inference",
        "pass",
        fn () -> string {
            var res = create_lexer_from_string_with_diag(
                "255 256 65535 65536 0xFFFFFFFF 0x100000000",
                sm,
                pool,
                test_diag_p,
            )

            var unsafe *lexer = res.0
            var        fid    = res.1

            finally {
                kairo::std::destroy(lexer)
            }

            if !lexer->lex(fid) {
                return "lexer failed to lex"
            }

            var unsafe *tokens               = lexer->tokens()
            const      expected_count: usize = (6)
            if content_count(tokens) != expected_count {
                return dump_tokens(tokens, expected_count)
            }

            var expected_bits = cxx::std::vector<u16>()
            expected_bits.push_back(8 as u16)  // 255 fits in 8 bits
            expected_bits.push_back(16 as u16) // 256 needs 9 bits -> 16
            expected_bits.push_back(16 as u16) // 65535 fits in 16 bits
            expected_bits.push_back(32 as u16) // 65536 needs 17 bits -> 32
            expected_bits.push_back(32 as u16) // 0xFFFFFFFF fits in 32 bits
            expected_bits.push_back(64 as u16) // 0x100000000 needs 33 bits -> 64

            for var i: usize = 0; i < expected_count; ++i {
                var unsafe *imm = lexer->get_imm<Immediate::IntData>(tokens->get(i)->imm)
                imm->evaluate(sm, lexer->get_imm_tbl())

                if imm->bits != expected_bits[i] {
                    return f"token {i}: expected bits {expected_bits[i]}, got {imm->bits}"
                }
            }

            if lexer->has_errors() {
                return f"lexer reported {lexer->error_count()} error(s) (check DiagEngine consumer for details)"
            }

            return "pass"
        },
        1000,
    )

    // FLOAT LITERALS

    suite.equal<string>(
        "lex decimal floats",
        "pass",
        fn () -> string {
            var res = create_lexer_from_string_with_diag(
                "0.0 1.5 3.14159 123.456",
                sm,
                pool,
                test_diag_p,
            )

            var unsafe *lexer = res.0
            var        fid    = res.1

            finally {
                kairo::std::destroy(lexer)
            }

            if !lexer->lex(fid) {
                return "lexer failed to lex"
            }

            var unsafe *tokens               = lexer->tokens()
            const      expected_count: usize = (4)
            if content_count(tokens) != expected_count {
                return dump_tokens(tokens, expected_count)
            }

            var expected_values = cxx::std::vector<f64>()
            expected_values.push_back(0.0 as f64)
            expected_values.push_back(1.5 as f64)
            expected_values.push_back(3.14159 as f64)
            expected_values.push_back(123.456 as f64)

            for var i: usize = 0; i < expected_count; ++i {
                if tokens->get(i)->kind != TokenKind::LitFloat {
                    return f"token {i}: expected LitFloat, got {token_kind_to_readable_string(tokens->get(i)->kind)}"
                }

                var unsafe *imm = lexer->get_imm<Immediate::FloatData>(tokens->get(i)->imm)
                imm->evaluate(sm, lexer->get_imm_tbl())

                const base_10: u8 = (10)
                if imm->base != base_10 {
                    return f"token {i}: expected base 10, got base {imm->base}"
                }

                // compare with small epsilon for floating point
                var   diff          = (imm->value_ieee as f64) - (expected_values[i])
                const zero_f80: f64 = (0.0)
                if diff < zero_f80 {
                    diff = -diff
                }

                const epsilon: f64 = (0.00001)
                if diff > epsilon {
                    return f"token {i}: expected value ~{expected_values[i]}, got {imm->value_ieee as f64}"
                }

                // default bit width should be 64
                const bits_64: u32 = (64)
                if imm->bits != bits_64 {
                    return f"token {i}: expected bits 64 (default), got {imm->bits}"
                }
            }

            if lexer->has_errors() {
                return f"lexer reported {lexer->error_count()} error(s) (check DiagEngine consumer for details)"
            }

            return "pass"
        },
        1000,
    )

    suite.equal<string>(
        "lex float with leading dot",
        "pass",
        fn () -> string {
            var        res    = create_lexer_from_string_with_diag(".5 .123 .0", sm, pool, test_diag_p)
            var unsafe *lexer = res.0
            var        fid    = res.1

            finally {
                kairo::std::destroy(lexer)
            }

            if !lexer->lex(fid) {
                return "lexer failed to lex"
            }

            var unsafe *tokens               = lexer->tokens()
            const      expected_count: usize = (3)
            if content_count(tokens) != expected_count {
                return dump_tokens(tokens, expected_count)
            }

            var expected_values = cxx::std::vector<f64>()
            expected_values.push_back(0.5 as f64)
            expected_values.push_back(0.123 as f64)
            expected_values.push_back(0.0 as f64)

            for var i: usize = 0; i < expected_count; ++i {
                if tokens->get(i)->kind != TokenKind::LitFloat {
                    return f"token {i}: expected LitFloat, got {token_kind_to_readable_string(tokens->get(i)->kind)}"
                }

                var unsafe *imm = lexer->get_imm<Immediate::FloatData>(tokens->get(i)->imm)
                imm->evaluate(sm, lexer->get_imm_tbl())

                var   diff          = (imm->value_ieee as f64) - (expected_values[i])
                const zero_f80: f64 = (0.0)
                if diff < zero_f80 {
                    diff = -diff
                }

                const epsilon: f64 = (0.00001)
                if diff > epsilon {
                    return f"token {i}: expected value ~{expected_values[i]}, got {imm->value_ieee as f64}"
                }
            }

            if lexer->has_errors() {
                return f"lexer reported {lexer->error_count()} error(s) (check DiagEngine consumer for details)"
            }

            return "pass"
        },
        1000,
    )

    suite.equal<string>(
        "lex floats with exponent",
        "pass",
        fn () -> string {
            var res = create_lexer_from_string_with_diag(
                "1e10 1E10 1.5e-3 2.0E+5 1e3",
                sm,
                pool,
                test_diag_p,
            )

            var unsafe *lexer = res.0
            var        fid    = res.1

            finally {
                kairo::std::destroy(lexer)
            }

            if !lexer->lex(fid) {
                return "lexer failed to lex"
            }

            var unsafe *tokens               = lexer->tokens()
            const      expected_count: usize = (5)
            if content_count(tokens) != expected_count {
                return dump_tokens(tokens, expected_count)
            }

            var expected_values = cxx::std::vector<f64>()
            expected_values.push_back(1e10 as f64)
            expected_values.push_back(1e10 as f64)
            expected_values.push_back(1.5e-3 as f64)
            expected_values.push_back(2.0e5 as f64)
            expected_values.push_back(1e3 as f64)

            for var i: usize = 0; i < expected_count; ++i {
                if tokens->get(i)->kind != TokenKind::LitFloat {
                    return f"token {i}: expected LitFloat, got {token_kind_to_readable_string(tokens->get(i)->kind)}"
                }

                var unsafe *imm = lexer->get_imm<Immediate::FloatData>(tokens->get(i)->imm)

                const has_exponent_flag: u8 = (0b00000001)
                if (imm->flags & has_exponent_flag) == 0 {
                    return f"token {i}: expected has_exponent flag (bit0) to be set, flags={imm->flags}"
                }

                imm->evaluate(sm, lexer->get_imm_tbl())

                // relative comparison for large values
                var   expected        = (expected_values[i])
                var   ratio           = (imm->value_ieee as f64) / expected
                const low_bound:  f64 = (0.999999)
                const high_bound: f64 = (1.000001)
                if ratio < low_bound || ratio > high_bound {
                    return f"token {i}: expected value ~{expected_values[i]}, got {imm->value_ieee as f64}"
                }
            }

            if lexer->has_errors() {
                return f"lexer reported {lexer->error_count()} error(s) (check DiagEngine consumer for details)"
            }

            return "pass"
        },
        1000,
    )

    suite.equal<string>(
        "lex hex floats",
        "pass",
        fn () -> string {
            var res = create_lexer_from_string_with_diag(
                "0x1.0p0 0x1.0p4 0x1.0p-4",
                sm,
                pool,
                test_diag_p,
            )

            var unsafe *lexer = res.0
            var        fid    = res.1

            finally {
                kairo::std::destroy(lexer)
            }

            if !lexer->lex(fid) {
                return "lexer failed to lex"
            }

            var unsafe *tokens               = lexer->tokens()
            const      expected_count: usize = (3)
            if content_count(tokens) != expected_count {
                return dump_tokens(tokens, expected_count)
            }

            // 0x1.0p0 = 1.0 * 2^0 = 1.0
            // 0x1.0p4 = 1.0 * 2^4 = 16.0
            // 0x1.0p-4 = 1.0 * 2^-4 = 0.0625
            var expected_values = cxx::std::vector<f64>()
            expected_values.push_back(1.0 as f64)
            expected_values.push_back(16.0 as f64)
            expected_values.push_back(0.0625 as f64)

            for var i: usize = 0; i < expected_count; ++i {
                if tokens->get(i)->kind != TokenKind::LitFloat {
                    return f"token {i}: expected LitFloat, got {token_kind_to_readable_string(tokens->get(i)->kind)}"
                }

                var unsafe *imm = lexer->get_imm<Immediate::FloatData>(tokens->get(i)->imm)

                const is_hex_flag: u8 = (0b00000100)
                if (imm->flags & is_hex_flag) == 0 {
                    return f"token {i}: expected is_hex_float flag (bit2) to be set, flags={imm->flags}"
                }

                imm->evaluate(sm, lexer->get_imm_tbl())

                const base_16: u8 = (16)
                if imm->base != base_16 {
                    return f"token {i}: expected base 16, got base {imm->base}"
                }

                var   diff          = (imm->value_ieee as f64) - (expected_values[i])
                const zero_f80: f64 = (0.0)
                if diff < zero_f80 {
                    diff = -diff
                }

                const epsilon: f64 = (0.00001)
                if diff > epsilon {
                    return f"token {i}: expected value ~{expected_values[i]}, got {imm->value_ieee as f64}"
                }
            }

            if lexer->has_errors() {
                return f"lexer reported {lexer->error_count()} error(s) (check DiagEngine consumer for details)"
            }

            return "pass"
        },
        1000,
    )

    suite.equal<string>(
        "lex hex floats complex",
        "pass",
        fn () -> string {
            var res = create_lexer_from_string_with_diag("0xA.Bp+2 0xC.8p-1", sm, pool, test_diag_p)
            var unsafe *lexer = res.0
            var        fid    = res.1

            finally {
                kairo::std::destroy(lexer)
            }

            if !lexer->lex(fid) {
                return "lexer failed to lex"
            }

            var unsafe *tokens               = lexer->tokens()
            const      expected_count: usize = (2)
            if content_count(tokens) != expected_count {
                return dump_tokens(tokens, expected_count)
            }

            // 0xA.Bp+2 = (10 + 11/16) * 2^2 = 10.6875 * 4 = 42.75
            // 0xC.8p-1 = (12 + 8/16) * 2^-1 = 12.5 * 0.5 = 6.25
            var expected_values = cxx::std::vector<f64>()
            expected_values.push_back(42.75 as f64)
            expected_values.push_back(6.25 as f64)

            for var i: usize = 0; i < expected_count; ++i {
                var unsafe *imm = lexer->get_imm<Immediate::FloatData>(tokens->get(i)->imm)
                imm->evaluate(sm, lexer->get_imm_tbl())

                var   diff          = (imm->value_ieee as f64) - (expected_values[i])
                const zero_f80: f64 = (0.0)
                if diff < zero_f80 {
                    diff = -diff
                }

                const epsilon: f64 = (0.001)
                if diff > epsilon {
                    return f"token {i}: expected value ~{expected_values[i]}, got {imm->value_ieee as f64}"
                }
            }

            if lexer->has_errors() {
                return f"lexer reported {lexer->error_count()} error(s) (check DiagEngine consumer for details)"
            }

            return "pass"
        },
        1000,
    )

    suite.equal<string>(
        "lex floats with suffixes",
        "pass",
        fn () -> string {
            var res = create_lexer_from_string_with_diag(
                "1.0f32 2.5f64 3.14f128",
                sm,
                pool,
                test_diag_p,
            )

            var unsafe *lexer = res.0
            var        fid    = res.1

            finally {
                kairo::std::destroy(lexer)
            }

            if !lexer->lex(fid) {
                return "lexer failed to lex"
            }

            var unsafe *tokens               = lexer->tokens()
            const      expected_count: usize = (3)
            if content_count(tokens) != expected_count {
                return dump_tokens(tokens, expected_count)
            }

            var expected_bits = cxx::std::vector<u32>()
            expected_bits.push_back(32 as u32)
            expected_bits.push_back(64 as u32)
            expected_bits.push_back(128 as u32)

            var expected_values = cxx::std::vector<f64>()
            expected_values.push_back(1.0 as f64)
            expected_values.push_back(2.5 as f64)
            expected_values.push_back(3.14 as f64)

            for var i: usize = 0; i < expected_count; ++i {
                if tokens->get(i)->kind != TokenKind::LitFloat {
                    return f"token {i}: expected LitFloat, got {token_kind_to_readable_string(tokens->get(i)->kind)}"
                }

                var unsafe *imm = lexer->get_imm<Immediate::FloatData>(tokens->get(i)->imm)

                const has_suffix_flag: u8 = (0b00010000)
                if (imm->flags & has_suffix_flag) == 0 {
                    return f"token {i}: expected has_suffix flag (bit4) to be set, flags={imm->flags}"
                }

                imm->evaluate(sm, lexer->get_imm_tbl())

                if imm->bits != expected_bits[i] {
                    return f"token {i}: expected bits {expected_bits[i]}, got {imm->bits}"
                }

                var   diff          = (imm->value_ieee as f64) - (expected_values[i])
                const zero_f80: f64 = (0.0)
                if diff < zero_f80 {
                    diff = -diff
                }

                const epsilon: f64 = (0.00001)
                if diff > epsilon {
                    return f"token {i}: expected value ~{expected_values[i]}, got {imm->value_ieee as f64}"
                }
            }

            if lexer->has_errors() {
                return f"lexer reported {lexer->error_count()} error(s) (check DiagEngine consumer for details)"
            }

            return "pass"
        },
        1000,
    )

    suite.equal<string>(
        "lex floats with underscores",
        "pass",
        fn () -> string {
            var res = create_lexer_from_string_with_diag(
                "1_000.0 1.234_567 1_2_3.4_5_6e78",
                sm,
                pool,
                test_diag_p,
            )

            var unsafe *lexer = res.0
            var        fid    = res.1

            finally {
                kairo::std::destroy(lexer)
            }

            if !lexer->lex(fid) {
                return "lexer failed to lex"
            }

            var unsafe *tokens = lexer->tokens()
            if content_count(tokens) != 3 {
                return dump_tokens(tokens, 3)
            }

            var expected_values = cxx::std::vector<f64>()
            expected_values.push_back(1000.0)
            expected_values.push_back(1.234567)
            expected_values.push_back(123.456e78)

            for var i: usize = 0; i < 3; ++i {
                var unsafe *imm = lexer->get_imm<Immediate::FloatData>(tokens->get(i)->imm)
                imm->evaluate(sm, lexer->get_imm_tbl()) // removing evaluation step only adds 1MB/s to perf

                // use relative comparison for very large numbers
                var expected = (expected_values[i])
                var ratio    = (imm->value_ieee as f64) / expected
                if ratio < 0.999 || ratio > 1.001 {
                    return f"token {i}: expected value ~{expected_values[i]}, got {imm->value_ieee as f64}"
                }
            }

            if lexer->has_errors() {
                return f"lexer reported {lexer->error_count()} error(s) (check DiagEngine consumer for details)"
            }

            return "pass"
        },
        1000,
    )

    suite.equal<string>(
        "distinguish dot from float",
        "pass",
        fn () -> string {
            var        res    = create_lexer_from_string_with_diag("foo.bar .5", sm, pool, test_diag_p)
            var unsafe *lexer = res.0
            var        fid    = res.1

            finally {
                kairo::std::destroy(lexer)
            }

            if !lexer->lex(fid) {
                return "lexer failed to lex"
            }

            var unsafe *tokens               = lexer->tokens()
            const      expected_count: usize = (4)
            if content_count(tokens) != expected_count {
                return dump_tokens(tokens, expected_count)
            }

            if tokens->get(0)->kind != TokenKind::LitIdentifier {
                return f"token 0: expected LitIdentifier (foo), got {token_kind_to_readable_string(tokens->get(0)->kind)}"
            }

            if tokens->get(1)->kind != TokenKind::OpDot {
                return f"token 1: expected OpDot, got {token_kind_to_readable_string(tokens->get(1)->kind)}"
            }

            if tokens->get(2)->kind != TokenKind::LitIdentifier {
                return f"token 2: expected LitIdentifier (bar), got {token_kind_to_readable_string(tokens->get(2)->kind)}"
            }

            if tokens->get(3)->kind != TokenKind::LitFloat {
                return f"token 3: expected LitFloat (.5), got {token_kind_to_readable_string(tokens->get(3)->kind)}"
            }

            // verify the float value
            var unsafe *imm = lexer->get_imm<Immediate::FloatData>(tokens->get(3)->imm)
            imm->evaluate(sm, lexer->get_imm_tbl()) // removing evaluation step only adds 1MB/s to perf

            const expected_val: f64 = (0.5)
            var   diff              = (imm->value_ieee as f64) - expected_val
            const zero_f80:     f64 = (0.0)
            if diff < zero_f80 {
                diff = -diff
            }

            const epsilon: f64 = (0.00001)
            if diff > epsilon {
                return f"token 3: expected value 0.5, got {imm->value_ieee as f64}"
            }

            if lexer->has_errors() {
                return f"lexer reported {lexer->error_count()} error(s) (check DiagEngine consumer for details)"
            }

            return "pass"
        },
        1000,
    )

    suite.equal<string>(
        "lex float scientific notation edge cases",
        "pass",
        fn () -> string {
            var res = create_lexer_from_string_with_diag("1e0 1e+0 1e-0 0e0", sm, pool, test_diag_p)
            var unsafe *lexer = res.0
            var        fid    = res.1

            finally {
                kairo::std::destroy(lexer)
            }

            if !lexer->lex(fid) {
                return "lexer failed to lex"
            }

            var unsafe *tokens               = lexer->tokens()
            const      expected_count: usize = (4)
            if content_count(tokens) != expected_count {
                return dump_tokens(tokens, expected_count)
            }

            // all should evaluate to their base value (exponent is 0)
            var expected_values = cxx::std::vector<f64>()
            expected_values.push_back(1.0 as f64)
            expected_values.push_back(1.0 as f64)
            expected_values.push_back(1.0 as f64)
            expected_values.push_back(0.0 as f64)

            for var i: usize = 0; i < expected_count; ++i {
                var unsafe *imm = lexer->get_imm<Immediate::FloatData>(tokens->get(i)->imm)
                imm->evaluate(sm, lexer->get_imm_tbl())

                var   diff          = (imm->value_ieee as f64) - (expected_values[i])
                const zero_f80: f64 = (0.0)
                if diff < zero_f80 {
                    diff = -diff
                }

                const epsilon: f64 = (0.00001)
                if diff > epsilon {
                    return f"token {i}: expected value {expected_values[i]}, got {imm->value_ieee as f64}"
                }
            }

            if lexer->has_errors() {
                return f"lexer reported {lexer->error_count()} error(s) (check DiagEngine consumer for details)"
            }

            return "pass"
        },
        1000,
    )

    suite.equal<string>(
        "lex range vs float disambiguation",
        "pass",
        fn () -> string {
            var res = create_lexer_from_string_with_diag("0..10 0.5 1..2", sm, pool, test_diag_p)
            var unsafe *lexer = res.0
            var        fid    = res.1

            finally {
                kairo::std::destroy(lexer)
            }

            if !lexer->lex(fid) {
                return "lexer failed to lex"
            }

            var unsafe *tokens = lexer->tokens()
            // 0..10 -> LitInt OpRange LitInt
            // 0.5   -> LitFloat
            // 1..2  -> LitInt OpRange LitInt
            const expected_count: usize = (7)
            if content_count(tokens) != expected_count {
                return dump_tokens(tokens, expected_count)
            }

            if tokens->get(0)->kind != TokenKind::LitInt {
                return f"token 0: expected LitInt (0), got {token_kind_to_readable_string(tokens->get(0)->kind)}"
            }

            if tokens->get(1)->kind != TokenKind::OpRange {
                return f"token 1: expected OpRange (..), got {token_kind_to_readable_string(tokens->get(1)->kind)}"
            }

            if tokens->get(2)->kind != TokenKind::LitInt {
                return f"token 2: expected LitInt (10), got {token_kind_to_readable_string(tokens->get(2)->kind)}"
            }

            if tokens->get(3)->kind != TokenKind::LitFloat {
                return f"token 3: expected LitFloat (0.5), got {token_kind_to_readable_string(tokens->get(3)->kind)}"
            }

            if tokens->get(4)->kind != TokenKind::LitInt {
                return f"token 4: expected LitInt (1), got {token_kind_to_readable_string(tokens->get(4)->kind)}"
            }

            if tokens->get(5)->kind != TokenKind::OpRange {
                return f"token 5: expected OpRange (..), got {token_kind_to_readable_string(tokens->get(5)->kind)}"
            }

            if tokens->get(6)->kind != TokenKind::LitInt {
                return f"token 6: expected LitInt (2), got {token_kind_to_readable_string(tokens->get(6)->kind)}"
            }

            // verify values
            var unsafe *int0 = lexer->get_imm<Immediate::IntData>(tokens->get(0)->imm)
            int0->evaluate(sm, lexer->get_imm_tbl())
            const zero_u64: u64 = (0)
            if int0->value_lo != zero_u64 {
                return f"token 0: expected value 0, got {int0->value_lo}"
            }

            var unsafe *int2 = lexer->get_imm<Immediate::IntData>(tokens->get(2)->imm)
            int2->evaluate(sm, lexer->get_imm_tbl())
            const ten_u64: u64 = (10)
            if int2->value_lo != ten_u64 {
                return f"token 2: expected value 10, got {int2->value_lo}"
            }

            var unsafe *float3 = lexer->get_imm<Immediate::FloatData>(tokens->get(3)->imm)
            float3->evaluate(sm, lexer->get_imm_tbl())
            const expected_float: f64 = (0.5)
            var   diff                = (float3->value_ieee as f64) - expected_float
            const zero_f80:       f64 = (0.0)
            if diff < zero_f80 {
                diff = -diff
            }

            const epsilon: f64 = (0.00001)
            if diff > epsilon {
                return f"token 3: expected value 0.5, got {float3->value_ieee as f64}"
            }

            if lexer->has_errors() {
                return f"lexer reported {lexer->error_count()} error(s) (check DiagEngine consumer for details)"
            }

            return "pass"
        },
        1000,
    )

    suite.equal<string>(
        "lex extreme float values",
        "pass",
        fn () -> string {
            var res = create_lexer_from_string_with_diag("1e308 1e-308", sm, pool, test_diag_p)
            var unsafe *lexer = res.0
            var        fid    = res.1

            finally {
                kairo::std::destroy(lexer)
            }

            if !lexer->lex(fid) {
                return "lexer failed to lex"
            }

            var unsafe *tokens               = lexer->tokens()
            const      expected_count: usize = (2)
            if content_count(tokens) != expected_count {
                return dump_tokens(tokens, expected_count)
            }

            for var i: usize = 0; i < expected_count; ++i {
                if tokens->get(i)->kind != TokenKind::LitFloat {
                    return f"token {i}: expected LitFloat, got {token_kind_to_readable_string(tokens->get(i)->kind)}"
                }

                var unsafe *imm = lexer->get_imm<Immediate::FloatData>(tokens->get(i)->imm)
                imm->evaluate(sm, lexer->get_imm_tbl())

                const zero_u:          usize = (0)
                const one_u:           usize = (1)
                const large_threshold: f64   = (1e307)
                const small_threshold: f64   = (1e-307)
                const zero_f80:        f64   = (0.0)

                // just verify it parsed without becoming infinity or zero incorrectly
                if i == zero_u {
                    // 1e308 should be a large but finite number
                    if (imm->value_ieee as f64) < large_threshold {
                        return f"token 0: value too small, expected ~1e308, got {imm->value_ieee as f64}"
                    }
                } else {
                    // 1e-308 should be a small but non-zero number
                    if (imm->value_ieee as f64) > small_threshold
                        || (imm->value_ieee as f64) <= zero_f80 {
                        return f"token 1: value unexpected, expected ~1e-308, got {imm->value_ieee as f64}"
                    }
                }
            }

            if lexer->has_errors() {
                return f"lexer reported {lexer->error_count()} error(s) (check DiagEngine consumer for details)"
            }

            return "pass"
        },
        1000,
    )

    // STRING LITERALS

    suite.equal<string>(
        "lex simple string",
        "pass",
        fn () -> string {
            var res = create_lexer_from_string_with_diag("\"hello world\"", sm, pool, test_diag_p)
            var unsafe *lexer = res.0
            var        fid    = res.1

            finally {
                kairo::std::destroy(lexer)
            }

            if !lexer->lex(fid) {
                return "lexer failed to lex"
            }

            var unsafe *tokens = lexer->tokens()
            if content_count(tokens) != 1 {
                return dump_tokens(tokens, 1)
            }

            if tokens->get(0)->kind != TokenKind::LitString {
                return f"token 0: expected LitString, got {token_kind_to_readable_string(tokens->get(0)->kind)}"
            }

            if lexer->has_errors() {
                return f"lexer reported {lexer->error_count()} error(s) (check DiagEngine consumer for details)"
            }

            return "pass"
        },
        1000,
    )

    suite.equal<string>(
        "lex empty string",
        "pass",
        fn () -> string {
            var        res    = create_lexer_from_string_with_diag("\"\"", sm, pool, test_diag_p)
            var unsafe *lexer = res.0
            var        fid    = res.1

            finally {
                kairo::std::destroy(lexer)
            }

            if !lexer->lex(fid) {
                return "lexer failed to lex"
            }

            var unsafe *tokens = lexer->tokens()
            if content_count(tokens) != 1 {
                return dump_tokens(tokens, 1)
            }

            if tokens->get(0)->kind != TokenKind::LitString {
                return f"token 0: expected LitString, got {token_kind_to_readable_string(tokens->get(0)->kind)}"
            }

            if lexer->has_errors() {
                return f"lexer reported {lexer->error_count()} error(s) (check DiagEngine consumer for details)"
            }

            return "pass"
        },
        1000,
    )

    suite.equal<string>(
        "lex string with escapes",
        "pass",
        fn () -> string {
            var res = create_lexer_from_string_with_diag(
                "\"hello\\nworld\\t!\"",
                sm,
                pool,
                test_diag_p,
            )

            var unsafe *lexer = res.0
            var        fid    = res.1

            finally {
                kairo::std::destroy(lexer)
            }

            if !lexer->lex(fid) {
                return "lexer failed to lex"
            }

            var unsafe *tokens = lexer->tokens()
            if content_count(tokens) != 1 {
                return dump_tokens(tokens, 1)
            }

            if tokens->get(0)->kind != TokenKind::LitString {
                return f"token 0: expected LitString, got {token_kind_to_readable_string(tokens->get(0)->kind)}"
            }

            if lexer->has_errors() {
                return f"lexer reported {lexer->error_count()} error(s) (check DiagEngine consumer for details)"
            }

            return "pass"
        },
        1000,
    )

    suite.equal<string>(
        "lex string with hex escape",
        "pass",
        fn () -> string {
            var res = create_lexer_from_string_with_diag(
                "\"\\x41\\x42\\x43\"",
                sm,
                pool,
                test_diag_p,
            )

            var unsafe *lexer = res.0
            var        fid    = res.1

            finally {
                kairo::std::destroy(lexer)
            }

            if !lexer->lex(fid) {
                return "lexer failed to lex"
            }

            var unsafe *tokens = lexer->tokens()
            if content_count(tokens) != 1 {
                return dump_tokens(tokens, 1)
            }

            if tokens->get(0)->kind != TokenKind::LitString {
                return f"token 0: expected LitString, got {token_kind_to_readable_string(tokens->get(0)->kind)}"
            }

            if lexer->has_errors() {
                return f"lexer reported {lexer->error_count()} error(s) (check DiagEngine consumer for details)"
            }

            return "pass"
        },
        1000,
    )

    suite.equal<string>(
        "lex string with unicode escape",
        "pass",
        fn () -> string {
            var res = create_lexer_from_string_with_diag(
                "\"\\u0041\\u03B1\"",
                sm,
                pool,
                test_diag_p,
            )

            var unsafe *lexer = res.0
            var        fid    = res.1

            finally {
                kairo::std::destroy(lexer)
            }

            if !lexer->lex(fid) {
                return "lexer failed to lex"
            }

            var unsafe *tokens = lexer->tokens()
            if content_count(tokens) != 1 {
                return dump_tokens(tokens, 1)
            }

            if tokens->get(0)->kind != TokenKind::LitString {
                return f"token 0: expected LitString, got {token_kind_to_readable_string(tokens->get(0)->kind)}"
            }

            if lexer->has_errors() {
                return f"lexer reported {lexer->error_count()} error(s) (check DiagEngine consumer for details)"
            }

            return "pass"
        },
        1000,
    )

    suite.equal<string>(
        "lex string with large unicode escape",
        "pass",
        fn () -> string {
            var res = create_lexer_from_string_with_diag("\"\\U0001F600\"", sm, pool, test_diag_p)
            var unsafe *lexer = res.0
            var        fid    = res.1

            finally {
                kairo::std::destroy(lexer)
            }

            if !lexer->lex(fid) {
                return "lexer failed to lex"
            }

            var unsafe *tokens = lexer->tokens()
            if content_count(tokens) != 1 {
                return dump_tokens(tokens, 1)
            }

            if tokens->get(0)->kind != TokenKind::LitString {
                return f"token 0: expected LitString, got {token_kind_to_readable_string(tokens->get(0)->kind)}"
            }

            if lexer->has_errors() {
                return f"lexer reported {lexer->error_count()} error(s) (check DiagEngine consumer for details)"
            }

            return "pass"
        },
        1000,
    )

    suite.equal<string>(
        "lex f-string simple",
        "pass",
        fn () -> string {
            var res = create_lexer_from_string_with_diag("f\"hello {name}\"", sm, pool, test_diag_p)
            var unsafe *lexer = res.0
            var        fid    = res.1

            finally {
                kairo::std::destroy(lexer)
            }

            if !lexer->lex(fid) {
                return "lexer failed to lex"
            }

            var unsafe *tokens = lexer->tokens()
            if content_count(tokens) != 1 {
                return dump_tokens(tokens, 1)
            }

            if tokens->get(0)->kind != TokenKind::LitString {
                return f"token 0: expected LitString, got {token_kind_to_readable_string(tokens->get(0)->kind)}"
            }

            var unsafe *imm = lexer->get_imm<Immediate::StringData>(tokens->get(0)->imm)
            if !imm->prefix_kind.equals(
                FlagSet<Immediate::TextPrefixKind, u8>(Immediate::TextPrefixKind::Format),
            ) {
                return f"expected prefix_kind Format, got different prefix kind"
            }

            if lexer->has_errors() {
                return f"lexer reported {lexer->error_count()} error(s) (check DiagEngine consumer for details)"
            }

            return "pass"
        },
        1000,
    )

    suite.equal<string>(
        "lex f-string with expression",
        "pass",
        fn () -> string {
            var res = create_lexer_from_string_with_diag(
                "f\"result: {1 + 2}\"",
                sm,
                pool,
                test_diag_p,
            )

            var unsafe *lexer = res.0
            var        fid    = res.1

            finally {
                kairo::std::destroy(lexer)
            }

            if !lexer->lex(fid) {
                return "lexer failed to lex"
            }

            var unsafe *tokens = lexer->tokens()
            if content_count(tokens) != 1 {
                return dump_tokens(tokens, 1)
            }

            if tokens->get(0)->kind != TokenKind::LitString {
                return f"token 0: expected LitString, got {token_kind_to_readable_string(tokens->get(0)->kind)}"
            }

            var unsafe *imm = lexer->get_imm<Immediate::StringData>(tokens->get(0)->imm)
            if imm->exprs.size() != 1 {
                return f"expected 1 expression in f-string, got {imm->exprs.size()}"
            }

            if lexer->has_errors() {
                return f"lexer reported {lexer->error_count()} error(s) (check DiagEngine consumer for details)"
            }

            return "pass"
        },
        1000,
    )

    suite.equal<string>(
        "lex f-string with nested braces",
        "pass",
        fn () -> string {
            var res = create_lexer_from_string_with_diag(
                "f\"value: {map[key]}\"",
                sm,
                pool,
                test_diag_p,
            )

            var unsafe *lexer = res.0
            var        fid    = res.1

            finally {
                kairo::std::destroy(lexer)
            }

            if !lexer->lex(fid) {
                return "lexer failed to lex"
            }

            var unsafe *tokens = lexer->tokens()
            if content_count(tokens) != 1 {
                return dump_tokens(tokens, 1)
            }

            if tokens->get(0)->kind != TokenKind::LitString {
                return f"token 0: expected LitString, got {token_kind_to_readable_string(tokens->get(0)->kind)}"
            }

            if lexer->has_errors() {
                return f"lexer reported {lexer->error_count()} error(s) (check DiagEngine consumer for details)"
            }

            return "pass"
        },
        1000,
    )

    suite.equal<string>(
        "lex raw string",
        "pass",
        fn () -> string {
            var        res    = create_lexer_from_string_with_diag("r\"hello\"", sm, pool, test_diag_p)
            var unsafe *lexer = res.0
            var        fid    = res.1

            finally {
                kairo::std::destroy(lexer)
            }

            if !lexer->lex(fid) {
                return "lexer failed to lex"
            }

            var unsafe *tokens = lexer->tokens()
            if content_count(tokens) != 1 {
                return dump_tokens(tokens, 1)
            }

            if tokens->get(0)->kind != TokenKind::LitString {
                return f"token 0: expected LitString, got {token_kind_to_readable_string(tokens->get(0)->kind)}"
            }

            var unsafe *imm = lexer->get_imm<Immediate::StringData>(tokens->get(0)->imm)
            if !imm->prefix_kind.equals(
                FlagSet<Immediate::TextPrefixKind, u8>(Immediate::TextPrefixKind::Raw),
            ) {
                return f"expected prefix_kind Raw, got different prefix kind"
            }

            if lexer->has_errors() {
                return f"lexer reported {lexer->error_count()} error(s) (check DiagEngine consumer for details)"
            }

            return "pass"
        },
        1000,
    )

    suite.equal<string>(
        "lex raw string with octal",
        "pass",
        fn () -> string {
            var res = create_lexer_from_string_with_diag(
                "r\"\\101\\102\\103\"",
                sm,
                pool,
                test_diag_p,
            )

            var unsafe *lexer = res.0
            var        fid    = res.1

            finally {
                kairo::std::destroy(lexer)
            }

            if !lexer->lex(fid) {
                return "lexer failed to lex"
            }

            var unsafe *tokens = lexer->tokens()
            if content_count(tokens) != 1 {
                return dump_tokens(tokens, 1)
            }

            if tokens->get(0)->kind != TokenKind::LitString {
                return f"token 0: expected LitString, got {token_kind_to_readable_string(tokens->get(0)->kind)}"
            }

            if lexer->has_errors() {
                return f"lexer reported {lexer->error_count()} error(s) (check DiagEngine consumer for details)"
            }

            return "pass"
        },
        1000,
    )

    suite.equal<string>(
        "lex fr-string (format + raw)",
        "pass",
        fn () -> string {
            var res = create_lexer_from_string_with_diag("fr\"value: {x}\"", sm, pool, test_diag_p)
            var unsafe *lexer = res.0
            var        fid    = res.1

            finally {
                kairo::std::destroy(lexer)
            }

            if !lexer->lex(fid) {
                return "lexer failed to lex"
            }

            var unsafe *tokens = lexer->tokens()
            if content_count(tokens) != 1 {
                return dump_tokens(tokens, 1)
            }

            if tokens->get(0)->kind != TokenKind::LitString {
                return f"token 0: expected LitString, got {token_kind_to_readable_string(tokens->get(0)->kind)}"
            }

            var unsafe *imm = lexer->get_imm<Immediate::StringData>(tokens->get(0)->imm)
            var want = FlagSet<Immediate::TextPrefixKind, u8>(Immediate::TextPrefixKind::Raw).plus(
                Immediate::TextPrefixKind::Format,
            )

            if !imm->prefix_kind.equals(want) {
                return f"expected prefix_kind raw|format (rf), got '{imm->prefix_kind.bits}'"
            }

            if lexer->has_errors() {
                return f"lexer reported {lexer->error_count()} error(s) (check DiagEngine consumer for details)"
            }

            return "pass"
        },
        1000,
    )

    // CHAR LITERALS

    suite.equal<string>(
        "lex simple char",
        "pass",
        fn () -> string {
            var        res    = create_lexer_from_string_with_diag("'a' 'Z' '0'", sm, pool, test_diag_p)
            var unsafe *lexer = res.0
            var        fid    = res.1

            finally {
                kairo::std::destroy(lexer)
            }

            if !lexer->lex(fid) {
                return "lexer failed to lex"
            }

            var unsafe *tokens = lexer->tokens()
            if content_count(tokens) != 3 {
                return dump_tokens(tokens, 3)
            }

            for var i: usize = 0; i < 3; ++i {
                if tokens->get(i)->kind != TokenKind::LitChar {
                    return f"token {i}: expected LitChar, got {token_kind_to_readable_string(tokens->get(i)->kind)}"
                }
            }

            if lexer->has_errors() {
                return f"lexer reported {lexer->error_count()} error(s) (check DiagEngine consumer for details)"
            }

            return "pass"
        },
        1000,
    )

    suite.equal<string>(
        "lex char with escapes",
        "pass",
        fn () -> string {
            var res = create_lexer_from_string_with_diag(
                "'\\n' '\\t' '\\'' '\\\\'",
                sm,
                pool,
                test_diag_p,
            )

            var unsafe *lexer = res.0
            var        fid    = res.1

            finally {
                kairo::std::destroy(lexer)
            }

            if !lexer->lex(fid) {
                return "lexer failed to lex"
            }

            var unsafe *tokens = lexer->tokens()
            if content_count(tokens) != 4 {
                return dump_tokens(tokens, 4)
            }

            for var i: usize = 0; i < 4; ++i {
                if tokens->get(i)->kind != TokenKind::LitChar {
                    return f"token {i}: expected LitChar, got {token_kind_to_readable_string(tokens->get(i)->kind)}"
                }
            }

            if lexer->has_errors() {
                return f"lexer reported {lexer->error_count()} error(s) (check DiagEngine consumer for details)"
            }

            return "pass"
        },
        1000,
    )

    // COMMENTS

    suite.equal<string>(
        "lex line comment",
        "pass",
        fn () -> string {
            var res = create_lexer_from_string_with_diag(
                "foo // this is a comment\nbar",
                sm,
                pool,
                test_diag_p,
            )

            var unsafe *lexer = res.0
            var        fid    = res.1

            finally {
                kairo::std::destroy(lexer)
            }

            if !lexer->lex(fid) {
                return "lexer failed to lex"
            }

            var unsafe *tokens = lexer->tokens()

            var found_comment = false
            var found_foo     = false
            var found_bar     = false

            for var i: usize = 0; i < tokens->size(); ++i {
                var unsafe *tok = tokens->get(i)
                if tok->kind == TokenKind::AtComment {
                    found_comment = true
                }

                if tok->kind == TokenKind::LitIdentifier {
                    var text = sm->get_text(tok->range)
                    if text == "foo" {
                        found_foo = true
                    }

                    if text == "bar" {
                        found_bar = true
                    }
                }
            }

            if !found_comment {
                return f"missing AtComment token\n{dump_tokens(tokens, 0)}"
            }

            if !found_foo {
                return f"missing identifier 'foo'\n{dump_tokens(tokens, 0)}"
            }

            if !found_bar {
                return f"missing identifier 'bar'\n{dump_tokens(tokens, 0)}"
            }

            if lexer->has_errors() {
                return f"lexer reported {lexer->error_count()} error(s) (check DiagEngine consumer for details)"
            }

            return "pass"
        },
        1000,
    )

    suite.equal<string>(
        "lex block comment",
        "pass",
        fn () -> string {
            var res = create_lexer_from_string_with_diag(
                "foo /* block comment */ bar",
                sm,
                pool,
                test_diag_p,
            )

            var unsafe *lexer = res.0
            var        fid    = res.1

            finally {
                kairo::std::destroy(lexer)
            }

            if !lexer->lex(fid) {
                return "lexer failed to lex"
            }

            var unsafe *tokens = lexer->tokens()

            var found_comment = false
            var found_foo     = false
            var found_bar     = false

            for var i: usize = 0; i < tokens->size(); ++i {
                var unsafe *tok = tokens->get(i)
                if tok->kind == TokenKind::AtComment {
                    found_comment = true
                }

                if tok->kind == TokenKind::LitIdentifier {
                    var text = sm->get_text(tok->range)
                    if text == "foo" {
                        found_foo = true
                    }

                    if text == "bar" {
                        found_bar = true
                    }
                }
            }

            if !found_comment {
                return f"missing AtComment token\n{dump_tokens(tokens, 0)}"
            }

            if !found_foo {
                return f"missing identifier 'foo'\n{dump_tokens(tokens, 0)}"
            }

            if !found_bar {
                return f"missing identifier 'bar'\n{dump_tokens(tokens, 0)}"
            }

            if lexer->has_errors() {
                return f"lexer reported {lexer->error_count()} error(s) (check DiagEngine consumer for details)"
            }

            return "pass"
        },
        1000,
    )

    suite.equal<string>(
        "lex nested block comments",
        "pass",
        fn () -> string {
            var res = create_lexer_from_string_with_diag(
                "foo /* outer /* inner */ still outer */ bar",
                sm,
                pool,
                test_diag_p,
            )

            var unsafe *lexer = res.0
            var        fid    = res.1

            finally {
                kairo::std::destroy(lexer)
            }

            if !lexer->lex(fid) {
                return "lexer failed to lex"
            }

            var unsafe *tokens = lexer->tokens()

            var found_comment = false
            var found_foo     = false
            var found_bar     = false

            for var i: usize = 0; i < tokens->size(); ++i {
                var unsafe *tok = tokens->get(i)
                if tok->kind == TokenKind::AtComment {
                    found_comment = true
                }

                if tok->kind == TokenKind::LitIdentifier {
                    var text = sm->get_text(tok->range)
                    if text == "foo" {
                        found_foo = true
                    }

                    if text == "bar" {
                        found_bar = true
                    }
                }
            }

            if !found_comment {
                return f"missing AtComment token for nested block comment\n{dump_tokens(tokens, 0)}"
            }

            if !found_foo {
                return f"missing identifier 'foo'\n{dump_tokens(tokens, 0)}"
            }

            if !found_bar {
                return f"missing identifier 'bar'\n{dump_tokens(tokens, 0)}"
            }

            if lexer->has_errors() {
                return f"lexer reported {lexer->error_count()} error(s) (check DiagEngine consumer for details)"
            }

            return "pass"
        },
        1000,
    )

    suite.equal<string>(
        "error on unmatched block comment end",
        "pass",
        fn () -> string {
            var        res    = create_lexer_from_string_with_diag("foo */ bar", sm, pool, test_diag_p)
            var unsafe *lexer = res.0
            var        fid    = res.1

            finally {
                kairo::std::destroy(lexer)
            }

            if !lexer->lex(fid) {
                return "lexer failed to lex"
            }

            var unsafe *tokens = lexer->tokens()

            var found_error = false
            for var i: usize = 0; i < tokens->size(); ++i {
                if tokens->get(i)->kind == TokenKind::TkError {
                    found_error = true
                    break
                }
            }

            if !found_error {
                return f"expected TkError for unmatched '*/', but no error token found\n{dump_tokens(tokens, 0)}"
            }

            return "pass"
        },
        1000,
    )

    // BALANCE TRACKING
    // This is now no longer a part of the Lexer PP tracks balance post PP stream.

    // suite.equal::<string>("balance tracker - matched braces", "pass", fn () -> string {
    //     var res = create_lexer_from_string_with_diag("{ { } }", sm, pool, test_diag_p);
    //     var lexer = libcxx::get::<0>(res);
    //     var fid = libcxx::get::<1>(res);

    //     finally { std::destroy(lexer); }

    //     if !lexer->lex(fid) { return "lexer failed to lex"; }

    //     if lexer->_balance.has_errors() {
    //         return f"unexpected balance errors for matched braces, error count: {lexer->_balance.errors.size()}";
    //     }

    //     if lexer->has_errors() {
    //         return f"lexer reported {lexer->error_count()} error(s) (check DiagEngine consumer for details)";
    //     }

    //     return "pass";
    // }, 1000);

    // suite.equal::<string>("balance tracker - matched parens", "pass", fn () -> string {
    //     var res = create_lexer_from_string_with_diag("((()))", sm, pool, test_diag_p);
    //     var lexer = libcxx::get::<0>(res);
    //     var fid = libcxx::get::<1>(res);

    //     finally { std::destroy(lexer); }

    //     if !lexer->lex(fid) { return "lexer failed to lex"; }

    //     if lexer->_balance.has_errors() {
    //         return f"unexpected balance errors for matched parens, error count: {lexer->_balance.errors.size()}";
    //     }

    //     if lexer->has_errors() {
    //         return f"lexer reported {lexer->error_count()} error(s) (check DiagEngine consumer for details)";
    //     }

    //     return "pass";
    // }, 1000);

    // suite.equal::<string>("balance tracker - matched brackets", "pass", fn () -> string {
    //     var res = create_lexer_from_string_with_diag("[[[]]]", sm, pool, test_diag_p);
    //     var lexer = libcxx::get::<0>(res);
    //     var fid = libcxx::get::<1>(res);

    //     finally { std::destroy(lexer); }

    //     if !lexer->lex(fid) { return "lexer failed to lex"; }

    //     if lexer->_balance.has_errors() {
    //         return f"unexpected balance errors for matched brackets, error count: {lexer->_balance.errors.size()}";
    //     }

    //     if lexer->has_errors() {
    //         return f"lexer reported {lexer->error_count()} error(s) (check DiagEngine consumer for details)";
    //     }

    //     return "pass";
    // }, 1000);

    // suite.equal::<string>("balance tracker - mixed matched", "pass", fn () -> string {
    //     var res = create_lexer_from_string_with_diag("fn foo() { arr[0] = (x + y); }", sm, pool, test_diag_p);
    //     var lexer = libcxx::get::<0>(res);
    //     var fid = libcxx::get::<1>(res);

    //     finally { std::destroy(lexer); }

    //     if !lexer->lex(fid) { return "lexer failed to lex"; }

    //     if lexer->_balance.has_errors() {
    //         return f"unexpected balance errors for mixed matched delimiters, error count: {lexer->_balance.errors.size()}";
    //     }

    //     if lexer->has_errors() {
    //         return f"lexer reported {lexer->error_count()} error(s) (check DiagEngine consumer for details)";
    //     }

    //     return "pass";
    // }, 1000);

    // suite.equal::<string>("balance tracker - unclosed brace", "pass", fn () -> string {
    //     var res = create_lexer_from_string_with_diag("{ foo", sm, pool, test_diag_p);
    //     var lexer = libcxx::get::<0>(res);
    //     var fid = libcxx::get::<1>(res);

    //     finally { std::destroy(lexer); }

    //     if !lexer->lex(fid) { return "lexer failed to lex"; }

    //     if !lexer->_balance.has_errors() {
    //         return "expected balance error for unclosed brace, but no errors found";
    //     }

    //     if lexer->_balance.errors.size() < 1 {
    //         return "expected at least 1 balance error, got 0";
    //     }
    //     if lexer->_balance.errors[0].kind != BalanceTracker::BalanceErrorKind::Unclosed {
    //         return f"expected Unclosed error kind, got different error kind";
    //     }

    //     // balance errors ARE user-facing diagnostics now (S033E); expect it.
    //     if lexer->error_count() != 1 {
    //         return f"expected exactly 1 diagnostic for the unclosed brace, got {lexer->error_count()}";
    //     }

    //     return "pass";
    // }, 1000);

    // suite.equal::<string>("balance tracker - unexpected closer", "pass", fn () -> string {
    //     var res = create_lexer_from_string_with_diag("foo }", sm, pool, test_diag_p);
    //     var lexer = libcxx::get::<0>(res);
    //     var fid = libcxx::get::<1>(res);

    //     finally { std::destroy(lexer); }

    //     if !lexer->lex(fid) { return "lexer failed to lex"; }

    //     if !lexer->_balance.has_errors() {
    //         return "expected balance error for unexpected closer, but no errors found";
    //     }

    //     if lexer->_balance.errors.size() < 1 {
    //         return "expected at least 1 balance error, got 0";
    //     }
    //     if lexer->_balance.errors[0].kind != BalanceTracker::BalanceErrorKind::Unexpected {
    //         return f"expected Unexpected error kind, got different error kind";
    //     }

    //     // balance errors ARE user-facing diagnostics now (S034E); expect it.
    //     if lexer->error_count() != 1 {
    //         return f"expected exactly 1 diagnostic for the unexpected closer, got {lexer->error_count()}";
    //     }

    //     return "pass";
    // }, 1000);

    // suite.equal::<string>("balance tracker - mismatched", "pass", fn () -> string {
    //     var res = create_lexer_from_string_with_diag("{ foo )", sm, pool, test_diag_p);
    //     var lexer = libcxx::get::<0>(res);
    //     var fid = libcxx::get::<1>(res);

    //     finally { std::destroy(lexer); }

    //     if !lexer->lex(fid) { return "lexer failed to lex"; }

    //     if !lexer->_balance.has_errors() {
    //         return "expected balance error for mismatched delimiters '{ foo )', but no errors found";
    //     }

    //     // balance errors ARE user-facing diagnostics now (S035E + unclosed);
    //     // '{ foo )' produces at least the mismatch diagnostic.
    //     if !lexer->has_errors() {
    //         return "expected diagnostics for the mismatched delimiters, got none";
    //     }

    //     return "pass";
    // }, 1000);

    // suite.equal::<string>("balance tracker - macro invocation", "pass", fn () -> string {
    //     var res = create_lexer_from_string_with_diag("foo!(bar)", sm, pool, test_diag_p);
    //     var lexer = libcxx::get::<0>(res);
    //     var fid = libcxx::get::<1>(res);

    //     finally { std::destroy(lexer); }

    //     if !lexer->lex(fid) { return "lexer failed to lex"; }

    //     if lexer->_balance.has_errors() {
    //         return f"unexpected balance errors for macro invocation, error count: {lexer->_balance.errors.size()}";
    //     }

    //     if lexer->has_errors() {
    //         return f"lexer reported {lexer->error_count()} error(s) (check DiagEngine consumer for details)";
    //     }

    //     return "pass";
    // }, 1000);

    // EDGE CASES

    suite.equal<string>(
        "lex unicode identifier",
        "pass",
        fn () -> string {
            var res = create_lexer_from_string_with_diag("café αβγ 日本語", sm, pool, test_diag_p)
            var unsafe *lexer = res.0
            var        fid    = res.1

            finally {
                kairo::std::destroy(lexer)
            }

            if !lexer->lex(fid) {
                return "lexer failed to lex"
            }

            var unsafe *tokens = lexer->tokens()
            if content_count(tokens) != 3 {
                return dump_tokens(tokens, 3)
            }

            for var i: usize = 0; i < 3; ++i {
                if tokens->get(i)->kind != TokenKind::LitIdentifier {
                    return f"token {i}: expected LitIdentifier for unicode identifier, got {token_kind_to_readable_string(tokens->get(i)->kind)}"
                }
            }

            if lexer->has_errors() {
                return f"lexer reported {lexer->error_count()} error(s) (check DiagEngine consumer for details)"
            }

            return "pass"
        },
        1000,
    )

    suite.equal<string>(
        "lex consecutive operators",
        "pass",
        fn () -> string {
            var        res    = create_lexer_from_string_with_diag("a+-b", sm, pool, test_diag_p)
            var unsafe *lexer = res.0
            var        fid    = res.1

            finally {
                kairo::std::destroy(lexer)
            }

            if !lexer->lex(fid) {
                return "lexer failed to lex"
            }

            var unsafe *tokens = lexer->tokens()
            if content_count(tokens) != 4 {
                return dump_tokens(tokens, 4)
            }

            if tokens->get(0)->kind != TokenKind::LitIdentifier {
                return f"token 0: expected LitIdentifier (a), got {token_kind_to_readable_string(tokens->get(0)->kind)}"
            }

            if tokens->get(1)->kind != TokenKind::OpPlus {
                return f"token 1: expected OpPlus, got {token_kind_to_readable_string(tokens->get(1)->kind)}"
            }

            if tokens->get(2)->kind != TokenKind::OpMinus {
                return f"token 2: expected OpMinus, got {token_kind_to_readable_string(tokens->get(2)->kind)}"
            }

            if tokens->get(3)->kind != TokenKind::LitIdentifier {
                return f"token 3: expected LitIdentifier (b), got {token_kind_to_readable_string(tokens->get(3)->kind)}"
            }

            if lexer->has_errors() {
                return f"lexer reported {lexer->error_count()} error(s) (check DiagEngine consumer for details)"
            }

            return "pass"
        },
        1000,
    )

    suite.equal<string>(
        "lex generics syntax",
        "pass",
        fn () -> string {
            var        res    = create_lexer_from_string_with_diag("Vec::<i32>", sm, pool, test_diag_p)
            var unsafe *lexer = res.0
            var        fid    = res.1

            finally {
                kairo::std::destroy(lexer)
            }

            if !lexer->lex(fid) {
                return "lexer failed to lex"
            }

            var unsafe *tokens = lexer->tokens()
            if content_count(tokens) != 5 {
                return dump_tokens(tokens, 5)
            }

            if tokens->get(0)->kind != TokenKind::LitIdentifier {
                return f"token 0: expected LitIdentifier (Vec), got {token_kind_to_readable_string(tokens->get(0)->kind)}"
            }

            if tokens->get(1)->kind != TokenKind::OpColonColon {
                return f"token 1: expected OpColonColon, got {token_kind_to_readable_string(tokens->get(1)->kind)}"
            }

            if tokens->get(2)->kind != TokenKind::OpLess {
                return f"token 2: expected OpLess, got {token_kind_to_readable_string(tokens->get(2)->kind)}"
            }

            if tokens->get(3)->kind != TokenKind::AtI32 {
                return f"token 3: expected AtI32, got {token_kind_to_readable_string(tokens->get(3)->kind)}"
            }

            if tokens->get(4)->kind != TokenKind::OpGreater {
                return f"token 4: expected OpGreater, got {token_kind_to_readable_string(tokens->get(4)->kind)}"
            }

            if lexer->has_errors() {
                return f"lexer reported {lexer->error_count()} error(s) (check DiagEngine consumer for details)"
            }

            return "pass"
        },
        1000,
    )

    suite.equal<string>(
        "lex range expressions",
        "pass",
        fn () -> string {
            var res = create_lexer_from_string_with_diag("0..10 0..=10", sm, pool, test_diag_p)
            var unsafe *lexer = res.0
            var        fid    = res.1

            finally {
                kairo::std::destroy(lexer)
            }

            if !lexer->lex(fid) {
                return "lexer failed to lex"
            }

            var unsafe *tokens = lexer->tokens()
            if content_count(tokens) != 6 {
                return dump_tokens(tokens, 6)
            }

            if tokens->get(0)->kind != TokenKind::LitInt {
                return f"token 0: expected LitInt, got {token_kind_to_readable_string(tokens->get(0)->kind)}"
            }

            if tokens->get(1)->kind != TokenKind::OpRange {
                return f"token 1: expected OpRange (..), got {token_kind_to_readable_string(tokens->get(1)->kind)}"
            }

            if tokens->get(2)->kind != TokenKind::LitInt {
                return f"token 2: expected LitInt, got {token_kind_to_readable_string(tokens->get(2)->kind)}"
            }

            if tokens->get(3)->kind != TokenKind::LitInt {
                return f"token 3: expected LitInt, got {token_kind_to_readable_string(tokens->get(3)->kind)}"
            }

            if tokens->get(4)->kind != TokenKind::OpRangeEqual {
                return f"token 4: expected OpRangeEqual (..=), got {token_kind_to_readable_string(tokens->get(4)->kind)}"
            }

            if tokens->get(5)->kind != TokenKind::LitInt {
                return f"token 5: expected LitInt, got {token_kind_to_readable_string(tokens->get(5)->kind)}"
            }

            if lexer->has_errors() {
                return f"lexer reported {lexer->error_count()} error(s) (check DiagEngine consumer for details)"
            }

            return "pass"
        },
        1000,
    )

    suite.equal<string>(
        "lex exponentiation operator",
        "pass",
        fn () -> string {
            var        res    = create_lexer_from_string_with_diag("2^^8", sm, pool, test_diag_p)
            var unsafe *lexer = res.0
            var        fid    = res.1

            finally {
                kairo::std::destroy(lexer)
            }

            if !lexer->lex(fid) {
                return "lexer failed to lex"
            }

            var unsafe *tokens = lexer->tokens()
            if content_count(tokens) != 3 {
                return dump_tokens(tokens, 3)
            }

            if tokens->get(0)->kind != TokenKind::LitInt {
                return f"token 0: expected LitInt (2), got {token_kind_to_readable_string(tokens->get(0)->kind)}"
            }

            if tokens->get(1)->kind != TokenKind::OpCaretCaret {
                return f"token 1: expected OpCaretCaret (^^), got {token_kind_to_readable_string(tokens->get(1)->kind)}"
            }

            if tokens->get(2)->kind != TokenKind::LitInt {
                return f"token 2: expected LitInt (8), got {token_kind_to_readable_string(tokens->get(2)->kind)}"
            }

            if lexer->has_errors() {
                return f"lexer reported {lexer->error_count()} error(s) (check DiagEngine consumer for details)"
            }

            return "pass"
        },
        1000,
    )

    suite.equal<string>(
        "lex spaceship operator",
        "pass",
        fn () -> string {
            var        res    = create_lexer_from_string_with_diag("a <=> b", sm, pool, test_diag_p)
            var unsafe *lexer = res.0
            var        fid    = res.1

            finally {
                kairo::std::destroy(lexer)
            }

            if !lexer->lex(fid) {
                return "lexer failed to lex"
            }

            var unsafe *tokens = lexer->tokens()
            if content_count(tokens) != 3 {
                return dump_tokens(tokens, 3)
            }

            if tokens->get(1)->kind != TokenKind::OpLessEqualGreater {
                return f"token 1: expected OpLessEqualGreater (<=>), got {token_kind_to_readable_string(tokens->get(1)->kind)}"
            }

            if lexer->has_errors() {
                return f"lexer reported {lexer->error_count()} error(s) (check DiagEngine consumer for details)"
            }

            return "pass"
        },
        1000,
    )

    suite.equal<string>(
        "lex triple equals",
        "pass",
        fn () -> string {
            var        res    = create_lexer_from_string_with_diag("a === b", sm, pool, test_diag_p)
            var unsafe *lexer = res.0
            var        fid    = res.1

            finally {
                kairo::std::destroy(lexer)
            }

            if !lexer->lex(fid) {
                return "lexer failed to lex"
            }

            var unsafe *tokens = lexer->tokens()
            if content_count(tokens) != 3 {
                return dump_tokens(tokens, 3)
            }

            if tokens->get(1)->kind != TokenKind::OpEqualEqualEqual {
                return f"token 1: expected OpEqualEqualEqual (===), got {token_kind_to_readable_string(tokens->get(1)->kind)}"
            }

            if lexer->has_errors() {
                return f"lexer reported {lexer->error_count()} error(s) (check DiagEngine consumer for details)"
            }

            return "pass"
        },
        1000,
    )

    suite.equal<string>(
        "lex C++ word operators",
        "pass",
        fn () -> string {
            var res = create_lexer_from_string_with_diag(
                "and or not xor bitand bitor compl",
                sm,
                pool,
                test_diag_p,
            )

            var unsafe *lexer = res.0
            var        fid    = res.1

            finally {
                kairo::std::destroy(lexer)
            }

            if !lexer->lex(fid) {
                return "lexer failed to lex"
            }

            var unsafe *tokens = lexer->tokens()
            if content_count(tokens) != 7 {
                return dump_tokens(tokens, 7)
            }

            if tokens->get(0)->kind != TokenKind::OpAmpAmp {
                return f"token 0: expected OpAmpAmp, got {token_kind_to_readable_string(tokens->get(0)->kind)}"
            }

            if tokens->get(1)->kind != TokenKind::OpPipePipe {
                return f"token 1: expected OpPipePipe, got {token_kind_to_readable_string(tokens->get(1)->kind)}"
            }

            if tokens->get(2)->kind != TokenKind::OpExclaim {
                return f"token 2: expected OpExclaim, got {token_kind_to_readable_string(tokens->get(2)->kind)}"
            }

            if tokens->get(3)->kind != TokenKind::OpCaret {
                return f"token 3: expected OpCaret, got {token_kind_to_readable_string(tokens->get(3)->kind)}"
            }

            if tokens->get(4)->kind != TokenKind::OpAmp {
                return f"token 4: expected OpAmp, got {token_kind_to_readable_string(tokens->get(4)->kind)}"
            }

            if tokens->get(5)->kind != TokenKind::OpPipe {
                return f"token 5: expected OpPipe, got {token_kind_to_readable_string(tokens->get(5)->kind)}"
            }

            if tokens->get(6)->kind != TokenKind::OpTilde {
                return f"token 6: expected OpTilde, got {token_kind_to_readable_string(tokens->get(6)->kind)}"
            }

            if lexer->has_errors() {
                return f"lexer reported {lexer->error_count()} error(s) (check DiagEngine consumer for details)"
            }

            return "pass"
        },
        1000,
    )

    suite.equal<string>(
        "lex builtins",
        "pass",
        fn () -> string {
            var res = create_lexer_from_string_with_diag(
                "__file__ __line__ __column__ __function__ __module__",
                sm,
                pool,
                test_diag_p,
            )

            var unsafe *lexer = res.0
            var        fid    = res.1

            finally {
                kairo::std::destroy(lexer)
            }

            if !lexer->lex(fid) {
                return "lexer failed to lex"
            }

            var unsafe *tokens = lexer->tokens()
            if content_count(tokens) != 5 {
                return dump_tokens(tokens, 5)
            }

            if tokens->get(0)->kind != TokenKind::BiFile {
                return f"token 0: expected BiFile, got {token_kind_to_readable_string(tokens->get(0)->kind)}"
            }

            if tokens->get(1)->kind != TokenKind::BiLine {
                return f"token 1: expected BiLine, got {token_kind_to_readable_string(tokens->get(1)->kind)}"
            }

            if tokens->get(2)->kind != TokenKind::BiColumn {
                return f"token 2: expected BiColumn, got {token_kind_to_readable_string(tokens->get(2)->kind)}"
            }

            if tokens->get(3)->kind != TokenKind::BiFunction {
                return f"token 3: expected BiFunction, got {token_kind_to_readable_string(tokens->get(3)->kind)}"
            }

            if tokens->get(4)->kind != TokenKind::BiModule {
                return f"token 4: expected BiModule, got {token_kind_to_readable_string(tokens->get(4)->kind)}"
            }

            if lexer->has_errors() {
                return f"lexer reported {lexer->error_count()} error(s) (check DiagEngine consumer for details)"
            }

            return "pass"
        },
        1000,
    )

    suite.equal<string>(
        "lex null literal",
        "pass",
        fn () -> string {
            var        res    = create_lexer_from_string_with_diag("null", sm, pool, test_diag_p)
            var unsafe *lexer = res.0
            var        fid    = res.1

            finally {
                kairo::std::destroy(lexer)
            }

            if !lexer->lex(fid) {
                return "lexer failed to lex"
            }

            var unsafe *tokens = lexer->tokens()
            if content_count(tokens) != 1 {
                return dump_tokens(tokens, 1)
            }

            if tokens->get(0)->kind != TokenKind::LitNull {
                return f"token 0: expected LitNull, got {token_kind_to_readable_string(tokens->get(0)->kind)}"
            }

            if lexer->has_errors() {
                return f"lexer reported {lexer->error_count()} error(s) (check DiagEngine consumer for details)"
            }

            return "pass"
        },
        1000,
    )

    suite.equal<string>(
        "lex boolean literals",
        "pass",
        fn () -> string {
            var        res    = create_lexer_from_string_with_diag("true false", sm, pool, test_diag_p)
            var unsafe *lexer = res.0
            var        fid    = res.1

            finally {
                kairo::std::destroy(lexer)
            }

            if !lexer->lex(fid) {
                return "lexer failed to lex"
            }

            var unsafe *tokens = lexer->tokens()
            if content_count(tokens) != 2 {
                return dump_tokens(tokens, 2)
            }

            if tokens->get(0)->kind != TokenKind::KwTrue {
                return f"token 0: expected KwTrue, got {token_kind_to_readable_string(tokens->get(0)->kind)}"
            }

            if tokens->get(1)->kind != TokenKind::KwFalse {
                return f"token 1: expected KwFalse, got {token_kind_to_readable_string(tokens->get(1)->kind)}"
            }

            if lexer->has_errors() {
                return f"lexer reported {lexer->error_count()} error(s) (check DiagEngine consumer for details)"
            }

            return "pass"
        },
        1000,
    )

    // INTERNER CONSISTENCY

    // pins the hash-consistency contract between the lexer's incremental hash
    // and compute_hash: a lexed 'foo' and a synthesized (intern_ident_copy)
    // 'foo' MUST intern to the same index, or imm-based identifier equality
    // silently breaks for every synthesized identifier (unique_id!, gensym,
    // sema-generated names).
    suite.equal<string>(
        "lexed and copied identifiers intern to the same index",
        "pass",
        fn () -> string {
            var        res    = create_lexer_from_string_with_diag("foo bar foo", sm, pool, test_diag_p)
            var unsafe *lexer = res.0
            var        fid    = res.1

            finally {
                kairo::std::destroy(lexer)
            }

            if !lexer->lex(fid) {
                return "lexer failed to lex"
            }

            var unsafe *tokens = lexer->tokens()
            if content_count(tokens) != 3 {
                return dump_tokens(tokens, 3)
            }

            var foo_imm = tokens->get(0)->imm
            var bar_imm = tokens->get(1)->imm

            // lexed occurrences of the same spelling collapse
            if tokens->get(2)->imm != foo_imm {
                return f"lexed 'foo' interned twice: idx {foo_imm} vs {tokens->get(2)->imm}"
            }

            if bar_imm == foo_imm {
                return "distinct spellings 'foo'/'bar' interned to the same index"
            }

            // synthesized spelling must collapse onto the lexed one
            var unsafe *tbl = lexer->get_imm_tbl()
            if tbl == &null {
                return "lexer has no imm table"
            }

            var copied = tbl->intern_ident_copy("foo")
            if copied != foo_imm {
                return f"intern_ident_copy('foo') = {copied}, lexed 'foo' = {foo_imm}; "
                       "incremental hash and compute_hash disagree"
            }

            // and a genuinely new synthesized spelling must get a fresh index
            var synth = tbl->intern_ident_copy("__synth_0_9999")
            if synth == foo_imm || synth == bar_imm {
                return "fresh synthesized spelling collided with existing index"
            }

            if tbl->get_ident(synth) != "__synth_0_9999" {
                return f"round-trip failed: get_ident returned '{tbl->get_ident(synth)}'"
            }

            return "pass"
        },
        10,
    )

    // ERROR CASES

    suite.equal<string>(
        "error on invalid escape in string",
        "pass",
        fn () -> string {
            var res = create_lexer_from_string_with_diag("\"hello\\qworld\"", sm, pool, test_diag_p)
            var unsafe *lexer = res.0
            var        fid    = res.1

            finally {
                kairo::std::destroy(lexer)
            }

            lexer->lex(fid)

            var unsafe *tokens = lexer->tokens()
            if tokens->size() < 1 {
                return "expected at least 1 token (the string with error recovery)"
            }

            if !lexer->has_errors() {
                return "expected lexer to report errors for invalid escape '\\q', but no errors found"
            }

            return "pass"
        },
        10,
    )

    // PINNING TEST byte strings are NOT implemented in this lexer version.
    // The prefix switch has no 'b'/'B' cases and no PFX_BYTES const, so
    // b"..." lexes as identifier 'b' followed by an ordinary string, and the
    // is_byte machinery in is_valid_escape (S029E etc.) is unreachable dead
    // wiring. This test pins that behavior: when byte strings land, it will
    // fail here at that point restore the real assertion (S029E on \u in a
    // byte string) and wire TextCtx.is_bytes -> is_valid_escape properly
    // (note: the call site currently passes ctx.is_raw as is_byte).
    suite.equal<string>(
        "byte string prefix not yet implemented (pin)",
        "pass",
        fn () -> string {
            var res = create_lexer_from_string_with_diag("b\"\\u0041\"", sm, pool, test_diag_p)
            var unsafe *lexer = res.0
            var        fid    = res.1

            finally {
                kairo::std::destroy(lexer)
            }

            if !lexer->lex(fid) {
                return "lexer failed to lex"
            }

            var unsafe *tokens = lexer->tokens()
            if content_count(tokens) != 2 {
                return dump_tokens(tokens, 2)
            }

            if tokens->get(0)->kind != TokenKind::LitIdentifier {
                return f"expected 'b' as LitIdentifier, got {token_kind_to_readable_string(tokens->get(0)->kind)}"
            }

            if tokens->get(1)->kind != TokenKind::LitString {
                return f"expected LitString, got {token_kind_to_readable_string(tokens->get(1)->kind)}"
            }

            if lexer->has_errors() {
                return f"lexer reported {lexer->error_count()} error(s); byte strings implemented? restore the real test"
            }

            return "pass"
        },
        10,
    )

    suite.equal<string>(
        "error on surrogate in unicode escape",
        "pass",
        fn () -> string {
            var        res    = create_lexer_from_string_with_diag("\"\\uD800\"", sm, pool, test_diag_p)
            var unsafe *lexer = res.0
            var        fid    = res.1

            finally {
                kairo::std::destroy(lexer)
            }

            lexer->lex(fid)

            if !lexer->has_errors() {
                return "expected lexer to report error for surrogate code point U+D800, but no errors found"
            }

            return "pass"
        },
        10,
    )

    // PERFORMANCE TESTS

    suite.equal<string>(
        "performance - lex realistic code",
        "pass",
        fn () -> string {
            var code = "fn factorial(n: i32) -> i32 {\n" + "    if n <= 1 {\n" + "        return 1;\n" + "    }\n" + "    return n * factorial(n - 1);\n" + "}\n" + "\n" + "class Point {\n" + "    var x: f64;\n" + "    var y: f64;\n" + "    \n" + "    fn Point(self, x: f64, y: f64) {\n" + "        self.x = x;\n" + "        self.y = y;\n" + "    }\n" + "    \n" + "    fn distance(self, other: *Point) -> f64 {\n" + "        var dx = self.x - other->x;\n" + "        var dy = self.y - other->y;\n" + "        return (dx * dx + dy * dy).sqrt();\n" + "    }\n" + "}\n" + "\n" + "fn main() -> i32 {\n" + "    var p1 = Point(0.0, 0.0);\n" + "    var p2 = Point(3.0, 4.0);\n" + "    var d = p1.distance(&p2);\n" + "    std::print(f\"Distance: {d}\n\");\n" + "    return 0;\n" + "}\n"

            var        res    = create_lexer_from_string_with_diag(code, sm, pool, test_diag_p)
            var unsafe *lexer = res.0
            var        fid    = res.1

            finally {
                kairo::std::destroy(lexer)
            }

            if !lexer->lex(fid) {
                return "lexer failed to lex realistic code"
            }

            var unsafe *tokens = lexer->tokens()
            if tokens->size() < 50 {
                return f"expected at least 50 tokens for realistic code, got {tokens->size()}"
            }

            if lexer->has_errors() {
                return f"lexer reported {lexer->error_count()} error(s) (check DiagEngine consumer for details)"
            }

            return "pass"
        },
        100,
    )

    // THROUGHPUT MEASUREMENT

    fn measure_timer_overhead() -> i64 {
        const iterations                     = 1000
        var   total                          = cxx::std::chrono::nanoseconds(0)
        var   dummy:     kairo::volatile_i64 = 0

        for var i = 0; i < iterations; ++i {
            const s = cxx::std::chrono::steady_clock::now()
            dummy = s.time_since_epoch().count() // force materialization
            const e = cxx::std::chrono::steady_clock::now()
            total += cxx::std::chrono::duration_cast<cxx::std::chrono::nanoseconds>(e - s)
        }

        return total.count() / iterations
    }

    io::println("\n=== Performance Benchmark ===\n")

    // Hot-loop throughput: one large contiguous buffer, lexed twice in a row.
    //
    // Run 1 pays for page faults, allocator growth, and a cold interner.
    // Run 2 is the hot number (warm pages, warmed interner buckets, trained
    // branch predictors). The gap between the two is the warmup cost.
    //
    // Streams via open/next/close instead of the batch lex() shim: buffering
    // every token would add ~4x hot_size in Token slabs and turn this into an
    // allocator benchmark. Counting inline gives the same number for free.
    //
    // ns/token is amortized over the whole run, so timer overhead (tens of ns
    // against a ~0.5s measurement) is not subtracted. Do not read a per-token
    // number off a small input; at single-digit ns/token the timer dominates.
    //
    // MEMORY: hot_size bytes of narrow source + the wide staging string in
    // load_virtual + imm data + interner. Dial HOT_TARGET down on small
    // machines.
    io::println("\n=== Hot-Loop Benchmark ===\n")

    const HOT_TARGET: usize = 1024 * 1024 * 1024 // 1 GiB of source

    // Two corpora, because one number was hiding the other.
    //
    //   A/dense  arithmetic function bodies. ~3.3 B/token, roughly twice as
    //            operator-dense as real source. Kept because every prior
    //            measurement is against it, but it over-weights lex_symbol and
    //            under-weights the identifier, comment and string paths.
    //
    //   B/real   shaped like Stage 1 compiler source: doc comments, long
    //            qualified identifiers, generics, ref!/obs::/own::, f-strings
    //            with interpolation, switch/case. ~6-7 B/token.
    //
    // Seeds are built wide (f-strings are wide) but converted ONCE while still
    // small; the 1 GiB replication is narrow. See create_lexer_from_bytes.
    var build_seed = fn (real: bool) -> cxx::std::string {
        var wide = string()

        for var i: i32 = 0; i < 1000; ++i {
            if !real {
                wide += f"fn test_func_{i}\n" + "(a: i32, b: i32) -> i32 {\n" + "    var result = a + b * 2;\n" + "    if result > 100 {\n" + "        return result - 50;\n" + "    } else if result < 0 {\n" + "        return 0;\n" + "    }\n" + "    return result;\n" + "}\n"
                continue
            }

            wide += f" +/// \\brief resolves declaration reference {i} against the scope chain\n"
            " +/// \\param candidate_reference unresolved identifier expression to look up\n"
            " +/// \\returns the resolved declaration, or null when lookup fails outright\n"
            f"inline priv fn resolve_declaration_reference_{i}(\n" + "    self,\n" + "    @inout resolution_context: NameResolutionContext,\n" + "    candidate_reference: obs::<UnresolvedIdentifierExpr>\n" + ") -> own::<ResolvedDeclaration> {\n" + "    var enclosing_lexical_scope = resolution_context.scope_chain().innermost();\n" + "\n" + "    if enclosing_lexical_scope == &null {\n" + "        self.diagnostic_engine->report(DiagCode(DiagID::R001E),\n" + "            candidate_reference->range.start,\n" + "            f\"unresolved identifier {candidate_reference} in this scope\")\n" + "            .first(candidate_reference->range).emit();\n" + "        return &null;\n" + "    }\n" + "\n" + "    var depth = enclosing_lexical_scope->depth() + 1;\n" + "    if (depth > 0) && (depth < 64) && !candidate_reference->is_synthetic {\n" + "        resolution_context.record(candidate_reference, depth * 2 - 1);\n" + "    }\n" + "\n" + "    switch candidate_reference->lookup_kind {\n" + "        case LookupKind::Ordinary {\n" + "            return enclosing_lexical_scope->lookup_ordinary::<ResolvedDeclaration>(\n" + "                candidate_reference->qualified_name);\n" + "        } case LookupKind::Qualified {\n" + "            return enclosing_lexical_scope->lookup_qualified::<ResolvedDeclaration>(\n" + "                candidate_reference->qualified_name);\n" + "        } default {\n" + "            return &null;\n" + "        }\n" + "    }\n" + "}\n" + "\n"
        }

        return kairo::std::to_std_string(wide)
    }

    for var corpus: i32 = 0; corpus < 2; ++corpus {
        var label = if (corpus == 0) => ("A/dense") else => "B/real "
        var seed  = build_seed(corpus != 0)

        // Linear appends into a pre-reserved buffer. Doubling would overshoot
        // the target and force a realloc-copy of the whole buffer on the last
        // append.
        var hot_code = cxx::std::string()
        hot_code.reserve(HOT_TARGET + seed.size())
        while hot_code.size() < HOT_TARGET {
            hot_code += seed
        }

        var hot_size = hot_code.size()
        var hot_res = create_lexer_from_bytes(cxx::std::move(hot_code), sm, pool, test_diag_p)
        var unsafe *hot_lexer = hot_res.0
        var        hot_fid    = hot_res.1

        io::println(
            f"\n[{label}] buffer: {hot_size} bytes ({(hot_size as f64) / (1024.0 * 1024.0):.1} MiB)\n",
        )

        var run1_ns    = 0 as u64
        var run1_count = 0 as usize

        for var run: i32 = 1; run <= 2; ++run {
            // Run 2 must not append into run 1's immediates. Without this the
            // table carries every literal from run 1 into run 2, so run 2
            // measures a different allocator state than run 1 and peak RSS
            // reports twice the real per-pass cost.
            hot_lexer->get_imm_tbl()->reset()

            if !hot_lexer->open(hot_fid) {
                io::println(f"[{label}] run {run}: OPEN FAILED\n")
                break
            }

            var t     = Timer("hot lex")
            var tok   = Token()
            var count = 0 as usize
            while hot_lexer->next(&tok) {
                ++count
            }

            var ns = t.elapsed_ns()

            hot_lexer->close()

            var run_label       = if (run == 1) => ("cold") else => "hot "
            var mbps            = (hot_size as f64) / (ns as f64) * 1000.0
            var ns_per_token    = (ns as f64) / (count as f64)
            var bytes_per_token = (hot_size as f64) / (count as f64)

            io::println(
                f"[{label}] run {run} ({run_label}): {ns} ns, {mbps:.1} MB/s, {count} tokens, {ns_per_token:.2} ns/token, {bytes_per_token:.1} B/token\n",
            )

            if run == 1 {
                run1_ns    = (ns as u64)
                run1_count = count
            } else {
                var speedup = (run1_ns as f64) / (ns as f64)
                io::println(f"[{label}] hot/cold speedup: {speedup:.2}x\n")

                if count != run1_count {
                    io::println(
                        f"[{label}] MISMATCH: run1 {run1_count} tokens, run2 {count} tokens -- open() is not restoring state from close()\n",
                    )
                }
            }
        }

        kairo::std::destroy(hot_lexer)
    }

    return 0
}
