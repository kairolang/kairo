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
ffi "c++" import "Native/Shims.hh" // volatile_i64
ffi "c++" import "Native/Types.hh"
ffi "c++" import "Native/Log.hh"
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
import Lexer::Immediate::{
    Immediate,
    ImmediateTable,
}
import Lexer::UnicodeTables::UnicodeTables
import Location::SourceLocation::SourceLocation
import Location::SourceManager::SourceManager
import Location::SourceRange::SourceRange
import Memory::MemoryBuffer::MemoryBuffer
import Native::CharTable::{
    CharClass,
    classify_ascii,
    is_operator_char,
    name_char_kind,
    normalize_char32,
}
import Native::TimeReport::KTimeRecord
import Native::UTF8Decode::DecodeResult
import Support::Ascii::is_illegal_ascii
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

/// The bytes of string token `t`'s FIRST segment, prefix, quotes and
/// suffix included; `len` (its range's size) for anything else. A chain
/// is one token whose range covers every segment; a reader that
/// handles the later segments itself -- kals' tokens colour each apart,
/// kfmt keeps them in the gap after the head -- takes the head's own
/// length from here.
pub fn chain_head_len(imm: unsafe *ImmediateTable, t: Token, len: u32) -> u32 {
    if t.kind != TokenKind::LitString || imm == &null {
        return len
    }

    var unsafe *d = imm->get<Immediate::StringData>(t.imm)
    if d == &null || d->next == u32::MAX || (!d->body.start.is_valid()) {
        return len
    }

    var s = t.range.start.raw()
    if d->suffix.range.is_valid() && d->suffix.range.end.raw() > s {
        var n = d->suffix.range.end.raw() - s
        return if (n < len) => (n) else => len
    }

    // The closing quotes are as many as the opening ones, which run from
    // the prefix's end (or the token's start) to the body.
    var qs = s
    if !d->prefix_kind.empty() && d->prefix.range.is_valid() {
        qs = d->prefix.range.end.raw()
    }

    var bs = d->body.start.raw()
    var be = d->body.end.raw()
    if bs < qs || be < bs || be < s {
        return len
    }

    var n = (be - s) + (bs - qs)
    return if (n < len) => (n) else => len
}

/// coarse classification of the previously emitted token
///
/// used for context-sensitive lexing decisions
pub enum LastTokenKind derives u8 {
    None,
    Text,
    Name,
    Symbol,
    Number,
}

/// utf-8 aware lexer for kairo source files
///
/// - performs tokenization only
/// - no semantic validation beyond lexical correctness
/// - produces immediate nodes for literals
/// - supports f-strings, byte strings, nested comments, and unicode
/// Element counts of the UnicodeTables arrays, which Lexer::in_ranges
/// takes beside the table (a slice does not expose its length).
const XID_START_LEN:    usize = 1378
const XID_CONTINUE_LEN: usize = 1604
const WHITE_SPACE_LEN:  usize = 16

pub class Lexer {
    /// The stream's one record of where it is: Streaming means the TkEof is
    /// still to come, Exhausted that it went out.
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
    var _size:        usize                    = 0 ///< effective end of the stream: the
    ///  sub-range for a lex_slice sub-lexer,
    ///  else the whole buffer.
    var _fid:      u32 = 0
    var _loc_base: u32 = 0 ///< raw SourceLocation of offset 0 in _fid;
    ///  see get_source_location.
    var _err_base: u32 = 0 ///< shared-DiagEngine error count at lex() entry;
    ///  error_count() reports the per-run delta.
    var _last_kind: LastTokenKind     = LastTokenKind::None
    var _state:     Self::StreamState = Self::StreamState::Closed
    // ideally this should be gated to test runner only but fine for now stage2 problems
    // PORT(stage2)
    var _test_buff: unsafe *TokenBuffer<512> = &null

    /// kind of the most recent symbol token, when `_last_kind == Symbol`.
    /// `_last_kind` collapses `)` `]` `+` `,` into one bucket, but the
    /// `.`-is-member-access test needs to tell a closing bracket from an
    /// operator. Written once per symbol token; not read in any scan loop.
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

    var _t_lex:      unsafe *KTimeRecord = &null
    var _lex_sample: u32                 = 0

    const PFX_FORMAT: u8 = 1 << 0
    const PFX_RAW:    u8 = 1 << 1
    const PFX_BYTES:  u8 = 1 << 2

    /// HashState values of the two-character runs lex_symbol turns into
    /// comments; no TokenKind is numbered with them.
    const HASH_LINE_COMMENT: u64 = 2645673611 ///< `//`
    const HASH_BLOCK_OPEN:   u64 = 2645686962 ///< `/` `*`
    const HASH_BLOCK_CLOSE:  u64 = 2644915348 ///< `*` `/`

    /// lex_text is lexing a segment after the first of a chain of adjacent
    /// string literals: the head's loop links the next one, not the segment.
    var _in_chain: bool = false

    /// transient context for string / char lexing
    ///
    /// lives only during lex_text
    struct TextCtx {
        /// f-string hole: `{` expr [`=`] [`:` spec] `}`. 0 is "absent" for
        /// spec_start and eq_pos, and can never be a real position: both lie
        /// past the hole's `{`. While the hole is open, spec_start == 0 is
        /// the expression part and != 0 the (never lexed) spec part.
        struct FormatSpec {
            var start:      usize ///< first byte after the `{`
            var end:        usize ///< the `}`
            var spec_start: usize ///< first byte after the `:`; 0 when no spec
            var eq_pos:     usize ///< the self-documenting `=`; 0 when absent
        }

        var lexer: *Lexer
        var start: SourceLocation

        var delim:     u8
        var imm_idx:   u32
        var is_format: bool                        = false
        var is_raw:    bool                        = false
        var is_bytes:  bool                        = false ///< `b"..."`: escapes are bytes, the text is ASCII
        var imm:       unsafe *Immediate::TextData = &null ///< the literal's StringData or CharData
        var prefix:    Token

        var body_start: SourceLocation
        var body_end:   SourceLocation

        /// `{` nesting: 0 in literal text, 1 in a hole, more inside braces
        /// within it. The only record of it.
        var in_format_depth:  usize
        var in_bracket_depth: usize ///< `(` `[` nesting inside the hole; a `:` or `=` decides nothing inside one
        var fstring_specs:    llvm::SmallVector<Self::FormatSpec, 4>

        var has_error:   bool  = false
        var is_triple:   bool  = false
        var error_token: Token
    }

    /// transient context for number lexing
    struct NumberCtx {
        /// tracks what was last seen while lexing a number
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

    /// checks if character is a valid digit in the given base
    ///
    /// ### Parameters
    /// - `c`: input character
    /// - `base`: numeric base (2, 8, 10, 16)
    ///
    /// ### Returns
    /// true if c is a digit allowed for `base` (2, 8, 10, 16)
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

    /// checks if character is a valid exponent character for the given base
    ///
    /// ### Parameters
    /// - `c`: input character
    /// - `base`: numeric base (10, 16)
    ///
    /// ### Returns
    /// true if `c` starts an exponent for the given base
    priv inline static fn is_exponent_char(c: char, base: u8) -> bool {
        return base == 10 && (c == 'e' || c == 'E') || base == 16 && (c == 'p' || c == 'P')
    }

    /// checks if character is a decimal digit
    ///
    /// ### Parameters
    /// - `c`: input character
    ///
    /// ### Returns
    /// true if `c` is a decimal digit
    priv inline static fn is_decimal_digit(c: char) -> bool {
        return c >= '0' && c <= '9'
    }

    /// # LEXER TEST API

    /// batch API. drives the streaming API to exhaustion.
    ///
    /// the batch path is a client of the stream path, not a fork of it.
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

    /// gets the next token from the input stream
    ///
    /// ### Parameters
    /// - `start`: starting source location of the token
    /// - `decode`: decoded character at the current cursor position
    ///
    /// ### Returns
    /// next token
    priv inline fn get_token(self,
                             const start:  SourceLocation,
                             const decode: DecodeResult) -> Token {
        const cls: CharClass = self.classify(decode.chr)

        match cls {
            case CharClass::Identifier {
                // identifier or keyword
                return self.lex_name(start)
            } case CharClass::Number {
                // integer or float literal
                return self.lex_number(start)
            } case CharClass::Operator {
                // this is either an operator or punctuation; `\` outside a
                // literal is neither
                if decode.chr == '\\' {
                    return self.lex_illegal_ascii(start)
                }

                return self.lex_symbol(start)
            } case CharClass::String {
                // string or char literal
                return self.lex_text(start)
            } case CharClass::Unassigned, CharClass::Illegal {
                // illegal character
                return self.lex_illegal(start, decode)
            } case CharClass::NewLine, CharClass::Whitespace {
                // whitespace or newline
                return self.lex_whitespace(
                    start,
                    normalize_char32(decode.chr),
                    (decode.len as usize),
                    cls
                )
            } default { }
        }

        self.advance_cursor((decode.len as usize))
        return self.create_unrecognized_token(start)
    }

    /// places this Lexer's "Lex" timing row explicitly.
    ///
    /// Call BEFORE open(), which otherwise picks a default position.
    /// Needed because a Lexer can be driven by two unrelated passes:
    /// the DepScanner's import scan and the preprocessor's walk. They
    /// tokenize the same bytes for different reasons and have to show
    /// up as separate rows, or the fact that the work happens twice
    /// is invisible.
    pub fn bind_time_region(self, rec: unsafe *KTimeRecord) {
        self._t_lex = rec
    }

    /// begin streaming a fid. imm table live immediately after this returns.
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

    /// pull one token. false = stream exhausted.
    ///
    /// never blocks. lex errors emit TkError inline + diagnostics; stream continues.
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

        // EOF contract: exactly one TkEof, then dead forever. Still
        // Streaming (the check above), so this is the first time here.
        *out        = Token(self.get_source_range(), TokenKind::TkEof, 0)
        self._state = Self::StreamState::Exhausted
        return true
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

    /// lexes a slice of the current file between start and end positions
    ///
    /// ### Parameters
    /// - `start`: starting position (inclusive)
    /// - `end`: ending position (exclusive)
    ///
    /// ### Returns
    /// token buffer containing lexed tokens
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

    /// a default destructor pretty self-explanatory
    fn Lexer(self) = delete

    /// default constructor
    ///
    /// initializes lexer with source manager and thread pool
    ///
    /// ### Parameters
    /// - `sm`: source manager pointer
    /// - `pool`: thread pool pointer
    ///
    /// ### Returns
    /// initialized lexer
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

    /// destructor
    fn op finally (self) = default

    /// loads the file buffer for the given file ID
    ///
    /// ### Parameters
    /// - `fid`: file ID to load
    ///
    /// ### Returns
    /// true on success
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

    /// bytes readable at the cursor, 0 at EOF.
    ///
    /// this is a READ LENGTH, not an index distance. handing it to
    /// decode_utf8 guarantees the decoder never touches a byte past
    /// file_size(). the previous remaining_offset() returned
    /// `size - cursor - 1` and every caller added 1 back "for the null
    /// terminator"   there is no null terminator. MemoryBuffer is a
    /// non-owning view over an mmap'd region of exactly size() bytes,
    /// so at cursor == size that +1 handed the decoder a length of 1
    /// over a pointer already at one-past-the-end.
    priv inline fn remaining_bytes(self) -> usize {
        const size: usize = self.file_size()
        if self._cursor >= size {
            return 0
        }

        return size - self._cursor
    }

    /// **Note:** plain member reads. Set once by load_file (whole buffer) or by
    /// lex_slice (the sub-range), the only two ways a stream begins.
    priv inline fn file_size(self) -> usize {
        return self._size
    }

    priv inline fn file_data(self) -> kairo::std::ConstPtr<u8> {
        return self.cached_data
    }

    /// moves the cursor forward, never past end-of-buffer.
    ///
    /// INVARIANT: 0 <= _cursor <= file_size(). Landing exactly ON
    /// file_size() is the EOF position and is legal   is_eof() reports
    /// true there, current_data() forms a one-past-the-end pointer that
    /// is never dereferenced, remaining_bytes() reports 0, and
    /// VirtualFileManager::get_loc accepts off == seg->size. Going PAST
    /// it is not legal: the scan loops in lex_name/scan_number_body/
    /// scan_text_body/lex_*_comment/lex_whitespace derive their `end`
    /// pointer from file_size() and run raw pointers against it, so an
    /// over-advanced cursor reads outside the mapping.
    ///
    /// **Note:** the clamp is to file_size(), not `file_size() - 1`: one byte short
    /// of EOF, is_eof() never becomes true and every `while !is_eof()`
    /// scanner spins on the last byte; it also underflows on an empty
    /// buffer.
    priv inline fn advance_cursor(self, count: usize = 1) {
        const size: usize = self.file_size()
        const room: usize = if (self._cursor < size) => (size - self._cursor) else => 0
        const step: usize = if (count < room) => (count) else => room

        self._cursor += step
    }

    /// writes a raw-pointer scan back into the member cursor.
    ///
    /// the scan loops keep the position in a local `const u8*` so the
    /// compiler can hold it in a register; this is how that position
    /// re-enters the object. `base` is the buffer origin the scan was
    /// derived from.
    ///
    /// **Warning:** must be called before ANY helper that reads _cursor
    /// (get_source_location, create_source_range, peek_char32, a
    /// diagnostic, or a nested scanner), not merely before returning.
    priv inline fn commit_cursor(self,
                                 const base: kairo::std::ConstPtr<u8>,
                                 const pos:  kairo::std::ConstPtr<u8>) {
        self._cursor = ((pos - base) as usize)
    }

    /// # LEXER INTERNALS

    /// decodes the character at `p`, without a call for ASCII.
    ///
    /// decode_utf8_lut already has this exact test three instructions
    /// in, so this is not a cheaper CHECK - it removes the call needed
    /// to reach it. UTF8View::decode_utf8 lives behind an FFI header
    /// and does not inline into the lexer: `sample` shows it as its
    /// own frame on the hot path. Real source is >95% ASCII, so this
    /// keeps the overwhelmingly common character entirely inside the
    /// caller's scan loop.
    ///
    /// ### Parameters
    /// - `avail`: bytes readable at `p`. Zero is EOF and yields len 0, which
    ///   is what every scan loop breaks on.
    inline static fn decode_at(const p:     kairo::std::ConstPtr<u8>,
                               const avail: usize) -> DecodeResult {
        if avail == 0 {
            return DecodeResult { chr: '\x00', len: 0, ok: false }
        }

        if p[0] < 0x80 {
            return DecodeResult { chr: p[0], len: 1, ok: true }
        }

        return UTF8View::decode_utf8(p, avail)
    }

    /// 1 would be the immediate next char
    priv inline fn peek_char32(self, offset: isize = 0) -> DecodeResult {
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
                return DecodeResult { chr: '\x00', len: 0, ok: false }
            }

            data += fwd
            size -= fwd
        }

        if size == 0 {
            return DecodeResult { chr: '\x00', len: 0, ok: false }
        }

        return Lexer::decode_at(data, size)
    }

    priv inline fn <eval N: usize> peek_char32(self,
                                               const max_unicode_len: u8 = 4) -> cxx::std::array<DecodeResult, N> {
        var res = cxx::std::array<DecodeResult, N>()
        res.fill(DecodeResult { chr: '\x00', len: 0, ok: false })

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

                var chunk: __m512i = _mm512_loadu_si512(
                    unsafe (ptr as unsafe *const __m512i),
                )

                var mask: __mmask64 = _mm512_movepi8_mask(chunk)

                if mask == 0 { // fully ASCII
                    var limit = STRIDE
                    if out_i + STRIDE > N {
                        limit = N - out_i
                    }

                    for var j: usize = 0; j < limit; ++j {
                        res[out_i] = DecodeResult { chr: ptr[j] as char, len: 1, ok: true }
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
                        res[out_i] = DecodeResult { chr: ptr[j] as char, len: 1, ok: true }
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

                var chunk: __m256i = _mm256_loadu_si256(
                    unsafe (ptr as unsafe *const __m256i),
                )

                var hi = _mm256_movemask_epi8(chunk)
                if hi == 0 {
                    var limit = STRIDE
                    if out_i + STRIDE > N {
                        limit = N - out_i
                    }

                    for var j: usize = 0; j < limit; ++j {
                        res[out_i] = DecodeResult { chr: ptr[j] as char, len: 1, ok: true }
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
                        res[out_i] = DecodeResult { chr: ptr[j] as char, len: 1, ok: true }
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
                var chunk: __m128i = _mm_loadu_si128(
                    unsafe (ptr as kairo::std::ConstPtr<__m128i>),
                )

                var hi = _mm_movemask_epi8(chunk)
                if hi == 0 {
                    var limit = STRIDE
                    if out_i + STRIDE > N {
                        limit = N - out_i
                    }

                    for var j: usize = 0; j < limit; ++j {
                        res[out_i] = DecodeResult { chr: ptr[j], len: 1, ok: true }
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
                        res[out_i] = DecodeResult { chr: ptr[j], len: 1, ok: true }
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
                        res[out_i] = DecodeResult { chr: ptr[j], len: 1, ok: true }
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
                        res[out_i] = DecodeResult { chr: ptr[j], len: 1, ok: true }
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


    /// position -> SourceLocation, without the SourceManager round trip.
    ///
    /// Identical to _sm->get_loc(_fid, pos) for any pos this lexer can
    /// produce. get_loc's four guards are all invariants here rather
    /// than per-token questions: the fid is valid and un-evicted for
    /// the life of the stream (open() would have failed), pos <=
    /// file_size() is the advance_cursor invariant, and the 4 GB cap
    /// is checked once for the whole file in open().
    priv inline fn get_source_location(self) -> SourceLocation {
        return SourceLocation::from_raw(self._loc_base + (self._cursor as u32))
    }

    priv inline fn get_source_location(self, pos: usize) -> SourceLocation {
        return SourceLocation::from_raw(self._loc_base + (pos as u32))
    }

    priv inline fn get_source_range(self) -> SourceRange {
        return SourceRange::from_bounds(
            self.get_source_location(),
            self.get_source_location(),
        )
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

    /// # Char Classification

    /// ASCII is one table load (ASCII_CLASS). Any other character is
    /// classified by its Unicode properties, from the tables in the
    /// compiler and not from the host's C library, so every build of the
    /// compiler reads a source file the same way.
    static fn classify(chr: char) -> CharClass {
        if (chr as u32) < 128 {
            return classify_ascii(chr)
        }

        return Lexer::classify_unicode(chr as u32)
    }

    /// White_Space separates tokens and XID_Start starts a name (UAX #31);
    /// no other non-ASCII character starts a token.
    static fn classify_unicode(c: u32) -> CharClass {
        if Lexer::in_ranges(UnicodeTables::XID_START, XID_START_LEN, c) {
            return CharClass::Identifier
        }

        if Lexer::in_ranges(UnicodeTables::WHITE_SPACE, WHITE_SPACE_LEN, c) {
            return CharClass::Whitespace
        }

        return CharClass::Illegal
    }

    /// `c` lies in one of the ranges of `t`, a UnicodeTables
    /// table of `n` elements: inclusive [first, last] pairs, ascending. Bisection.
    static fn in_ranges(t: [const u32;], n: usize, c: u32) -> bool {
        var lo: usize = 0
        var hi: usize = n / 2
        while lo < hi {
            var mid = lo + (hi - lo) / 2
            if c > t[mid * 2 + 1] {
                lo = mid + 1
            } else {
                hi = mid
            }
        }

        return lo < n / 2 && c >= t[lo * 2]
    }

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

        var p: kairo::std::ConstPtr<u8> = base + self._cursor

        var unsafe *s_p  = p
        var        first = Lexer::decode_at(p, (end - p) as usize)

        var first_len = (first.len as usize)
        if self.is_valid_name(first) == 0 {
            // A run of characters no name can contain is reported once and
            // kept in the name: one error, and still one identifier.
            first_len = 0
            if first.len > 1 {
                first_len = self.illegal_run(p, end)
            }

            if first_len == 0 {
                if first.len == 1 && is_illegal_ascii(p[0]) {
                    return self.lex_illegal_ascii(start)
                }

                self.advance_cursor((first.len as usize))
                return self.create_unrecognized_token(start)
            }
        }

        // the interner hashes the spelling's UTF-8 BYTES (find_ident,
        // intern_ident_copy), so the lexer must mix bytes too: mixing the
        // code point truncated to u8 gave a non-ASCII name a different hash
        // here than at every lookup, and `lib::naïve` never resolved.
        for var b: usize = 0; b < first_len; ++b {
            hash.mix(p[b])
        }

        length += first_len
        p += first_len

        if first.len > 1 {
            keyword = false
        }

        while p < end {
            var d = Lexer::decode_at(p, (end - p) as usize)
            if self.is_valid_name(d) == 0 {
                var bad: usize = 0
                if d.len > 1 {
                    bad = self.illegal_run(p, end)
                }

                if bad == 0 {
                    break // finished
                }

                for var b: usize = 0; b < bad; ++b {
                    hash.mix(p[b])
                }

                p += bad
                length += bad
                keyword = false
                continue
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

            for var b: usize = 0; b < (d.len as usize); ++b {
                hash.mix(p[b])
            }

            p += d.len
            length += (d.len as usize)
        }

        // everything past this point (create_source_range, peek_char32,
        // get_source_location, lex_text) reads _cursor.
        self.commit_cursor(base, p)

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

        token.set_kind(TokenKind::LitIdentifier)
        token.set_range(self.create_source_range(start))

        // A string prefix touching its quote is read off its bytes and never
        // interned: it names nothing. A longer name is a name. `b` is a
        // string's prefix only: before a `'` it is the name `b`.
        if length < 3 {
            var dec = self.peek_char32()
            if dec.chr == '"' || dec.chr == '\'' {
                var ptype = self.text_prefix_bits(s_p, length)
                if ptype != 0 && ((ptype & self.PFX_BYTES) == 0 || dec.chr == '"') {
                    token.imm = ptype
                    return self.lex_text(self.get_source_location(), token)
                }
            }
        }

        token.set_imm(self.intern_ident(s_p, length, (h as u32)))
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

    /// scans at most 16 characters per call and reports whether the
    /// caller should come back for more. The cursor lives
    /// in a local pointer for the whole call, so decoding one
    /// character at a time costs less than staging sixteen
    /// DecodeResults and then re-walking them through advance_cursor.
    priv inline fn scan_number_body(self, @inout ctx: Self::NumberCtx) -> bool {
        const base: kairo::std::ConstPtr<u8> = self.file_data()
        const end:  kairo::std::ConstPtr<u8> = base + self.file_size()

        var p: kairo::std::ConstPtr<u8> = base + self._cursor

        for var i: usize = 0; i < 16; ++i {
            if p >= end {
                // EOF is tested explicitly: a zero-filled DecodeResult would
                // fall through every test below to `return false`.
                self.commit_cursor(base, p)
                return false
            }

            var d = Lexer::decode_at(p, (end - p) as usize)
            var c = normalize_char32(d.chr)

            if ctx.has_exponent {
                if ctx.allows_sign_next && (c == '+' || c == '-') {
                    p += d.len
                    ctx.allows_sign_next = false
                    ctx.last             = Self::NumberCtx::LastWasState::Exponent
                    continue
                }

                if !Lexer::is_decimal_digit(c) {
                    self.commit_cursor(base, p)
                    return false
                }

                p += d.len
                ctx.last = Self::NumberCtx::LastWasState::Digit
                continue
            }

            if c == '_' {
                if ctx.last != Self::NumberCtx::LastWasState::Digit {
                    self.commit_cursor(base, p)
                    return false
                }

                ctx.last = Self::NumberCtx::LastWasState::Underscore
                p += d.len
                continue
            }

            if Lexer::is_base_digit(c, ctx.base) {
                ctx.last = Self::NumberCtx::LastWasState::Digit
                p += d.len
                continue
            }

            if c == '.' && ctx.base != 2 && ctx.base != 8 {
                var unsafe *q = p + d.len
                if q < end && q[0] == ('.' as u8) {
                    self.commit_cursor(base, p)
                    return false // range operator, stop here
                }

                // A decimal point must be followed by a base digit. Without this `1.`
                // lexes as 1.0, which (a) makes `1.foo()` unreachable and (b) is
                // ambiguous with `1 . <tuple-index>` since `.N` is member access.
                // Raw byte compare is safe: digits are ASCII and no continuation byte
                // of a multibyte sequence is < 0x80 same reasoning as the `..` check
                // directly above.
                if q >= end
                    || !Lexer::is_base_digit(
                        normalize_char32(
                            if q[0] < 0x80 => (q[0] as char) else => (0xFFFFFFFF as char),
                        ),
                        ctx.base,
                    ) {
                    self.commit_cursor(base, p)
                    return false
                }

                // A tuple index is an ordinal, never a fraction. Stopping here
                // is what makes the second `.` of `t.0.1` its own separator
                // instead of fusing `0.1` into one float.
                if ctx.is_tuple_index {
                    self.commit_cursor(base, p)
                    return false
                }

                if ctx.has_decimal
                    || ctx.last == Self::NumberCtx::LastWasState::Dot
                    || ctx.last == Self::NumberCtx::LastWasState::Underscore {
                    self.commit_cursor(base, p)
                    return false
                }

                ctx.has_decimal = true
                ctx.last        = Self::NumberCtx::LastWasState::Dot
                p += d.len
                continue
            }

            if Lexer::is_exponent_char(c, ctx.base) {
                if ctx.has_exponent || ctx.last == Self::NumberCtx::LastWasState::Underscore {
                    self.commit_cursor(base, p)
                    return false
                }

                ctx.has_exponent     = true
                ctx.allows_sign_next = true
                ctx.last             = Self::NumberCtx::LastWasState::Exponent
                p += d.len
                continue
            }

            self.commit_cursor(base, p)
            return false
        }

        self.commit_cursor(base, p)
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
        tok.set_kind(
            if is_float => TokenKind::LitFloat else => TokenKind::LitInt,
        )

        tok.set_range(self.create_source_range(ctx.start))

        var imm_idx: u32 = if is_float => (self.create_imm<Immediate::FloatData>())
                           else => self.create_imm<Immediate::IntData>()

        tok.imm = imm_idx

        if is_float {
            var unsafe *imm = self.get_imm<Immediate::FloatData>(imm_idx)

            imm->assign_flags(FlagSet<Immediate::FloatFlags, u8>())
            imm->base = ctx.base
            imm->body = SourceRange::from_bounds(
                ctx.number_start,
                ctx.number_end,
            )

            if ctx.has_exponent {
                imm->set_flag(Immediate::FloatFlags::HasExponent)
            }

            if ctx.base == 16 {
                imm->set_flag(Immediate::FloatFlags::IsHex)
            }

            if ctx.has_suffix {
                imm->set_flag(Immediate::FloatFlags::HasSuffix)
                imm->suffix = ctx.suffix.range
            }

            if ctx.has_prefix {
                imm->prefix = SourceRange::from_bounds(
                    ctx.prefix_start,
                    ctx.prefix_end,
                )
            }

            imm->evaluate(self._sm, self.get_imm_tbl())
        } else {
            var unsafe *imm = self.get_imm<Immediate::IntData>(imm_idx)

            // the lexer defines every flag
            imm->assign_flags(FlagSet<Immediate::IntFlags, u8>())

            imm->base = ctx.base
            imm->body = SourceRange::from_bounds(
                ctx.number_start,
                ctx.number_end,
            )

            if ctx.has_prefix {
                imm->set_flag(Immediate::IntFlags::HasPrefix)
                imm->prefix = SourceRange::from_bounds(
                    ctx.prefix_start,
                    ctx.prefix_end,
                )
            }

            if ctx.has_suffix {
                imm->set_flag(Immediate::IntFlags::HasSuffix)
                imm->suffix = ctx.suffix.range
            }

            imm->evaluate(self._sm, self.get_imm_tbl())
        }

        self._last_kind = LastTokenKind::Number
        return tok
    }

    /// true when the previous token can terminate a postfix chain, which
    /// makes a following `.` a member-access operator rather than the
    /// leading dot of a float literal.
    ///
    /// `t.0` must lex as `t` `.` `0`, but `x = .5` must still lex `.5`
    /// as a float. Only what came before the dot distinguishes them.
    /// `Name` covers identifiers and keywords alike deliberately, so
    /// `self.0` works. A keyword followed by `.` + digit (`return.5`)
    /// is a parse error under either reading, so the conflation costs
    /// nothing but the wording of a diagnostic nobody will hit.
    /// `Text` is a string/char literal, which likewise ends a postfix
    /// chain (`"ab".len()`).
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
        const CHARS: cxx::std::array<DecodeResult, 4> = self.peek_char32<4>(1)

        const C1: DecodeResult = CHARS[0]
        const C2: DecodeResult = CHARS[1]
        const C3: DecodeResult = CHARS[2]
        const C4: DecodeResult = CHARS[3]

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

            if h2 == self.HASH_LINE_COMMENT {
                self.advance_cursor(2)
                return self.lex_line_comment(start)
            }

            if h2 == self.HASH_BLOCK_OPEN {
                self.advance_cursor(2)
                return self.lex_block_comment(start)
            }

            if h2 == self.HASH_BLOCK_CLOSE {
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
        if best_hash == (TokenKind::OpGreaterEqual as u32 as u64) && C3.len == 1 && C3.chr == '>' {
            best_hash = (TokenKind::OpGreater as u32 as u64)
            best_len  = 1
        } else if best_hash == (TokenKind::OpGreaterGreaterEqual as u32 as u64)
            && C4.len == 1
            && C4.chr == '>' {
            best_hash = (TokenKind::OpGreaterGreater as u32 as u64)
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

                // TODO: emit proper conflict diagnostic
                kairo::Logger::warn(
                    kairo::Logger::Stage::Lexer,
                    f"Lexer::lex_symbol: git conflict marker detected ({run_len} chars) at fid={self._fid} cursor={self._cursor}",
                )

                return self.create_error_token(
                    start,
                    TokenKind::TkError,
                    TokenKind::TkError,
                )
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

        var p: kairo::std::ConstPtr<u8> = base + self._cursor

        // A comment body needs no decoding at all: UTF-8 is self-synchronising,
        // so no byte of a multibyte sequence is ever < 0x80 and none of them can
        // be mistaken for the 0x0A/0x0D that ends the run. Scan raw bytes.
        while p < end {
            if p[0] == 0x0A || p[0] == 0x0D {
                break
            }

            p += 1
        }

        self.commit_cursor(base, p) // create_source_range reads _cursor

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

        var p: kairo::std::ConstPtr<u8> = base + self._cursor

        // Same as lex_line_comment: the body needs no decoding. Both nesting
        // markers are ASCII pairs, and no byte of a multibyte sequence can be
        // '*' or '/', so a raw byte scan finds exactly the same delimiters.
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

        self.commit_cursor(base, p) // both exits below read _cursor

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

        if ctx.is_bytes && !ctx.has_error {
            self.check_byte_text(&ctx)
        }

        if !self.finalize_text(&ctx) {
            return self.create_error_token(start, TokenKind::LitString)
        }

        self.lex_text_suffix(&ctx)
        self.emit_fstring_exprs(&ctx)

        var head = self.make_text_token(&ctx)
        if self._in_chain || ctx.delim != 0x22 {
            return head
        }

        // Each adjacent segment is linked onto the one before it. A chain is
        // one token, so its range runs to the last segment's end: what reads a
        // token's text by its range -- stringify!, a caret -- must see the
        // whole chain, so `stringify!("a" "b")` covers both segments.
        self._in_chain = true
        var unsafe *link = unsafe &ctx.imm->next
        while true {
            var seg = self.lex_adjacent_segment()
            if seg.kind != TokenKind::LitString {
                break
            }

            // Bytes and text do not join: one is a `[const u8;]`, the other
            // a `string`. The chain is still linked, so the one error is all
            // the literal reports.
            var unsafe *seg_d = self.get_imm<Immediate::StringData>(seg.imm)
            if seg_d->prefix_kind.has(Immediate::TextPrefixKind::Bytes) != ctx.is_bytes {
                self._diag->report(
                    DiagCode(DiagID::S097E),
                    seg.range.start,
                    "a byte string and a string cannot be joined: every literal of a chain is b\"...\", or none is",
                ).first(seg.range)->emit()
            }

            *link = seg.imm
            link  = unsafe &seg_d->next
            head.set_range(
                SourceRange::from_bounds(head.range.start, seg.range.end),
            )
        }

        self._in_chain = false
        return head
    }

    /// lexes the string literal adjacent to the one just lexed, the
    /// next segment of its chain; a non-string token when none follows.
    ///
    /// `"a" "b"`, including split across newlines, is one logical
    /// string. Each segment keeps its own imm entry - body range,
    /// prefix, suffix, f-string exprs - and lex_text links the entries
    /// head-to-tail through StringData::next, so a diagnostic can
    /// still blame the exact segment a byte came from rather than the
    /// fused whole. Only the head token reaches the parser.
    ///
    /// **Note:** Only `"` chains: a char literal is a single codepoint. A
    /// continuation may carry any string prefix (`"a" r"b"`,
    /// `f"a{x}" f"b{y}"`); each segment is lexed under its own
    /// prefix, so its escapes and holes are its own, and the
    /// consumers read every segment's prefix_kind. A prefixed
    /// continuation that did not chain would be a second token: a
    /// new statement whose value was discarded.
    ///
    /// **Warning:** the cursor is restored when no adjacent literal follows. The
    /// newline after a lone string is a statement terminator and must
    /// survive this lookahead.
    priv inline fn lex_adjacent_segment(self) -> Token {
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

        if self.is_eof() {
            self._cursor = saved
            return Token()
        }

        // A prefixed continuation goes through lex_name, which owns what a
        // prefix is: the lookahead only admits the spellings it accepts, so
        // `"a" f "b"` (a space after the `f`) and `"a" ff"b"` stay apart.
        var seg = Token()
        if self.peek_char32().chr == '"' {
            seg = self.lex_text(self.get_source_location())
        } else if self.string_prefix_len() != 0 {
            seg = self.lex_name(self.get_source_location())
        } else {
            self._cursor = saved
            return Token()
        }

        if seg.kind != TokenKind::LitString {
            self._cursor = saved
        }

        self._last_kind = LastTokenKind::Text
        return seg
    }

    /// the length of the string prefix at the cursor (`f`, `r`, `b`,
    /// or two of them, either case) when a `"` follows it directly,
    /// else 0.
    ///
    /// decides, without consuming, that the name at the cursor is a
    /// prefix and not a word, by the same test lex_name lexes it with.
    /// A `'` after it is a char literal, which never chains, so it is
    /// 0 here.
    priv inline fn string_prefix_len(self) -> isize {
        var unsafe *p = self.current_data()
        var        n  = self.remaining_bytes()
        for var len: usize = 1; len <= 2 && len < n; ++len {
            if p[len] == ('"' as u8) && self.text_prefix_bits(p, len) != 0 {
                return len as isize
            }
        }

        return 0
    }

    /// the PFX_* bits of the `n` bytes at `p` when they spell a
    /// string prefix: `f`, `r`, `b`, or two different ones, either
    /// case. 0 for anything else, `ff` and `rr` included.
    ///
    /// `br` and `bf` are prefixes here so that the literal after
    /// them is lexed as one; init_text_ctx reports them.
    priv inline fn text_prefix_bits(self, p: kairo::std::ConstPtr<u8>, n: usize) -> u8 {
        if n == 0 || n > 2 {
            return 0
        }

        var bits: u8 = 0
        for var i: usize = 0; i < n; ++i {
            var lower    = p[i] | 0x20 // 'F' -> 'f', 'R' -> 'r', 'B' -> 'b'; no other byte lands on one
            var bit:  u8 = 0
            if lower == ('f' as u8) {
                bit = self.PFX_FORMAT
            } else if lower == ('r' as u8) {
                bit = self.PFX_RAW
            } else if lower == ('b' as u8) {
                bit = self.PFX_BYTES
            }

            if bit == 0 || (bits & bit) != 0 {
                return 0
            }

            bits |= bit
        }

        return bits
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

            var _r015 = SourceRange::from_bounds(
                start,
                self.get_source_location(),
            )

            self._diag->report(
                DiagCode(DiagID::S015E),
                _r015.start,
                f"expected string or character literal delimiter ('\"' or ''')",
            ).first(_r015)->emit()
            ctx.error_token = self.create_error_token(
                start,
                TokenKind::LitString,
            )

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

        // An ArenaList element never moves, so the pointer stays good while
        // the literal's holes add entries to the same table.
        if ctx.delim == 0x22 {
            ctx.imm_idx = self.create_imm<Immediate::StringData>()
            ctx.imm     = self.get_imm<Immediate::StringData>(ctx.imm_idx)
        } else {
            ctx.imm_idx = self.create_imm<Immediate::CharData>()
            ctx.imm     = self.get_imm<Immediate::CharData>(ctx.imm_idx)
        }

        ctx.is_format = false
        ctx.is_raw    = false

        ctx.is_bytes = false

        if prefix == TokenKind::LitIdentifier {
            ctx.is_format = (prefix.imm & self.PFX_FORMAT) != 0
            ctx.is_raw    = (prefix.imm & self.PFX_RAW) != 0
            ctx.is_bytes  = (prefix.imm & self.PFX_BYTES) != 0
            ctx.prefix    = prefix
        }

        // `b` combines with nothing. The literal is still lexed whole, as
        // bytes (raw when `r` was written, so its backslashes report
        // nothing more; never with holes), and stays one token.
        if ctx.is_bytes && (ctx.is_format || ctx.is_raw) {
            self._diag->report(
                DiagCode(DiagID::S097E),
                prefix.range.start,
                if (ctx.is_format) => ("a byte string cannot be a format string: 'b' and 'f' do not combine")
                else => "a raw byte string is not supported: write b\"...\" and escape each backslash",
            ).first(prefix.range)->emit()
            ctx.is_format = false
        }

        ctx.in_format_depth  = 0
        ctx.in_bracket_depth = 0
        ctx.fstring_specs    = llvm::SmallVector<Self::TextCtx::FormatSpec, 4>()

        return ctx
    }

    /// split into a raw-pointer fast path for literal content and a
    /// cursor-backed slow path (scan_text_special) for the five bytes
    /// that can do something other than "advance one character".
    /// Everything interesting in a string literal   diagnostics,
    /// f-string expression offsets, the escape scanner   reads
    /// _cursor, so the cursor is committed before the slow path runs
    /// and the scan pointer is re-derived from it afterwards.
    priv inline fn scan_text_body(self, @inout ctx: Self::TextCtx) {
        const base: kairo::std::ConstPtr<u8> = self.file_data()
        const end:  kairo::std::ConstPtr<u8> = base + self.file_size()

        var p: kairo::std::ConstPtr<u8> = base + self._cursor

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
                continue
            }

            self.commit_cursor(base, p)

            if !self.scan_text_special(&ctx, d) {
                return // closing delimiter consumed
            }

            // the slow path moved the cursor itself (possibly by a lot, as with
            // is_valid_escape or a nested f-string expression).
            p = base + self._cursor
        }

        self.commit_cursor(base, p)

        ctx.has_error = true
        var _r012 = SourceRange::from_bounds(
            ctx.start,
            self.get_source_location(),
        )

        self._diag->report(
            DiagCode(DiagID::S012E),
            _r012.start,
            if (ctx.is_triple) => ("unterminated string literal; add a closing '\"\"\"' to end the string")
            else => "unterminated string literal; add a closing '\"' to end the string",
        ).first(_r012)->emit()
    }

    /// handles the one character scan_text_body's fast path refused.
    ///
    /// every branch here needs a live _cursor, so the caller commits
    /// before calling and re-reads _cursor after. Advances through
    /// advance_cursor.
    ///
    /// ### Returns
    /// false once the closing delimiter has been consumed and the
    /// literal is complete; true to keep scanning.
    priv inline fn scan_text_special(self, @inout ctx: Self::TextCtx, d: DecodeResult) -> bool {
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
                            self.advance_cursor( // consume all three
                                ((d.len + q2.len + q3.len) as usize),
                            )

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
                    self.advance_cursor((d.len as usize))

                    ctx.fstring_specs.push_back(
                        Self::TextCtx::FormatSpec {
                            start:      self._cursor,
                            end:        0,
                            spec_start: 0, // no spec yet
                            eq_pos:     0, // no `=` yet
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
                        self.get_source_location(
                            self._cursor + (d.len as usize),
                        ),
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
                    if !self.is_valid_escape(
                        esc_start,
                        ctx.is_bytes,
                        ctx.is_format,
                    ) {
                        ctx.has_error = true
                    }
                }
            } default {
                self.advance_cursor((d.len as usize))
            }
        }

        return true
    }

    /// one character inside a hole.
    ///
    /// beyond the nesting that finds the closing `}`, this records
    /// the two things the hole's TOKENS cannot carry: where a format
    /// spec begins (`{x:>4}`) and whether the hole is self-documenting
    /// (`{x=}`). Both are decided by the byte, at nesting depth 1 and
    /// outside any bracket, so `{f(a: 1)}`, `{m["k"]}`, `{Foo::bar}`
    /// and `{a == b}` stay whole expressions. The spec bytes are never
    /// lexed: `>4`, `#x`, `?` and `08.3` are not tokens.
    priv inline fn scan_format_expr(self, @inout ctx: Self::TextCtx, d: DecodeResult) {
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
                self.advance_cursor((d.len as usize))
            } case '}' { // }
                --ctx.in_format_depth
                if ctx.in_format_depth == 0 {
                    ctx.fstring_specs.back().end = self._cursor
                }

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

    /// scans a string literal inside an f-string expression
    ///
    /// skips to matching quote, handling escapes but not nested f-strings
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

        // A hole still open at the closing quote.
        if ctx.in_format_depth > 0 {
            return false
        }

        return true
    }

    priv inline fn lex_text_suffix(self, @inout ctx: Self::TextCtx) {
        // `"a"f"b"`: a prefix glued to the closing quote starts the next
        // segment of the chain, not a suffix. lex_name would lex that whole
        // literal as the "suffix" (and its imm would be orphaned).
        if ctx.delim == 0x22 && self.string_prefix_len() != 0 {
            return
        }

        if self.is_valid_name(self.peek_char32()) != 0 {
            var suffix = self.lex_name(self.get_source_location())
            if suffix.kind == TokenKind::TkUnknown {
                return
            }

            // A suffix names a literal operator over a `string`; bytes have
            // none. The name is consumed and dropped.
            if ctx.is_bytes {
                self._diag->report(
                    DiagCode(DiagID::S097E),
                    suffix.range.start,
                    "a byte string takes no literal suffix",
                ).first(suffix.range)->remove(suffix.range, "remove the suffix")->emit()
                return
            }

            ctx.imm->suffix.set_range(suffix.range)
        }
    }

    /// reports each run of non-ASCII bytes in the body of the byte
    /// string `ctx` as S097E.
    ///
    /// A byte string's source text is ASCII: what a character
    /// above U+007F would mean (which encoding's bytes) is not
    /// left to the file's. One pass over the finished body, off
    /// scan_text_body's per-character path.
    priv fn check_byte_text(self, @inout ctx: Self::TextCtx) {
        const base: kairo::std::ConstPtr<u8> = self.file_data()
        var i   = ((ctx.body_start.raw() - self._loc_base) as usize)
        var end = ((ctx.body_end.raw() - self._loc_base) as usize)
        while i < end {
            if base[i] < 0x80 {
                i += 1
                continue
            }

            var run = i
            while i < end && base[i] >= 0x80 {
                i += 1
            }

            var range = self.create_source_range(run, i)
            self._diag->report(
                DiagCode(DiagID::S097E),
                range.start,
                "non-ASCII character in a byte string; write its bytes as '\\xNN' escapes",
            ).first(range)->emit()
        }
    }

    /// lexes each hole's EXPRESSION and records what the tokens
    /// cannot carry. The expression stops at the `=` of `{x=}`, else
    /// at the `:` of a spec, else at the `}`; only that slice is
    /// lexed. The spec is handed on as a byte range for X to parse.
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

            ctx.imm->exprs.push_back(
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
            hole.doc = if (spec->eq_pos != 0) => (self.create_source_range(
                           spec->start,
                           doc_end,
                       ))
                       else => SourceRange::invalid()
            ctx.imm->holes.push_back(hole)
        }
    }

    priv inline fn make_text_token(self, @inout ctx: Self::TextCtx) -> Token {
        var tok: Token
        tok.set_kind(
            if ctx.delim == 0x22 => TokenKind::LitString else => TokenKind::LitChar,
        )

        tok.set_range(self.create_source_range(ctx.start))
        tok.imm         = ctx.imm_idx
        self._last_kind = LastTokenKind::Text

        ctx.imm->body = SourceRange::from_bounds(ctx.body_start, ctx.body_end)

        ctx.imm->prefix = ctx.prefix
        var prefix_kind = FlagSet<Immediate::TextPrefixKind, u8>()
        if ctx.is_raw {
            prefix_kind.set(Immediate::TextPrefixKind::Raw)
        }

        if ctx.is_format {
            prefix_kind.set(Immediate::TextPrefixKind::Format)
        }

        if ctx.is_bytes {
            prefix_kind.set(Immediate::TextPrefixKind::Bytes)
        }

        ctx.imm->prefix_kind = prefix_kind

        return tok
    }

    /// the character at the cursor starts no token.
    ///
    /// It is lexed as a name all the same, so the parser sees one
    /// identifier and not a hole. lex_name reports a character no
    /// name can contain (illegal_run); a character that may continue
    /// a name but not start one (a combining mark, a non-ASCII
    /// digit) is reported here, since lex_name takes it silently.
    /// An ASCII character (`$`, a backtick) and a byte that is not
    /// UTF-8 (reported as S072E, decoded as one byte) take the name
    /// path unreported: lex_name makes the first an unknown token
    /// (lex_illegal_ascii) and the second part of a name.
    priv fn lex_illegal(self, start: SourceLocation, decode: DecodeResult) -> Token {
        if decode.len > 1
            && Lexer::in_ranges(
                UnicodeTables::XID_CONTINUE,
                XID_CONTINUE_LEN,
                decode.chr as u32,
            ) {
            var range = SourceRange::from_bounds(start, decode.len as u32)
            self._diag->report(
                DiagCode(DiagID::S011E),
                range.start,
                f"character U+{Lexer::hex4(decode.chr as u32)} cannot start an identifier",
            ).first(range)->emit()
        }

        return self.lex_name(start)
    }

    /// the run of ASCII characters at the cursor that no token holds
    /// (Ascii::is_illegal_ascii), as one TkUnknown token whose imm is the run
    /// interned as a name.
    ///
    /// Not reported here: a macro body or argument may hold any
    /// token, and stringify! makes text of it, so only a run that
    /// reaches the parser is an error. PPWalker::_emit reports it
    /// there, once, as S011E, and hands the parser a name (the imm
    /// is its spelling), as a non-ASCII run is one (illegal_run).
    priv fn lex_illegal_ascii(self, start: SourceLocation) -> Token {
        const      base: kairo::std::ConstPtr<u8> = self.file_data()
        const      end:  kairo::std::ConstPtr<u8> = base + self.file_size()
        var        p:    kairo::std::ConstPtr<u8> = base + self._cursor
        var unsafe *s_p                           = p
        var        hash: HashState                = HashState()
        while p < end && is_illegal_ascii(p[0]) {
            hash.mix(p[0])
            p += 1
        }

        var length = ((p - s_p) as usize)
        self.commit_cursor(base, p)
        var token = self.create_unrecognized_token(start)
        token.set_imm(self.intern_ident(s_p, length, (hash.finalize() as u32)))
        return token
    }

    /// the length in bytes of the run of characters at `p` that no
    /// token can contain, reported once as S011E; 0 when `p` starts
    /// no such run.
    ///
    /// Such a character is non-ASCII and neither XID_Continue nor
    /// White_Space: a symbol, an emoji, punctuation, a format
    /// control. A byte that is not UTF-8 ends the run: it decodes
    /// as one byte, and validate_utf8 has reported it.
    priv fn illegal_run(self, p: kairo::std::ConstPtr<u8>, end: kairo::std::ConstPtr<u8>) -> usize {
        var n:     usize = 0
        var first: u32   = 0
        while p + n < end {
            var d = Lexer::decode_at(p + n, (end - (p + n)) as usize)
            if d.len <= 1
                || Lexer::in_ranges(
                    UnicodeTables::XID_CONTINUE,
                    XID_CONTINUE_LEN,
                    d.chr as u32,
                )
                || Lexer::in_ranges(
                    UnicodeTables::WHITE_SPACE,
                    WHITE_SPACE_LEN,
                    d.chr as u32,
                ) {
                break
            }

            if n == 0 {
                first = d.chr as u32
            }

            n += (d.len as usize)
        }

        if n == 0 {
            return 0
        }

        var at    = ((p - self.file_data()) as usize)
        var range = self.create_source_range(at, at + n)
        self._diag->report(
            DiagCode(DiagID::S011E),
            range.start,
            f"character U+{Lexer::hex4(first)} cannot appear in an identifier, or anywhere outside a string, a character literal or a comment",
        ).first(range)->emit()
        return n
    }

    /// The low byte of `v` as two lower-case hex digits: the `NN` of `\xNN`.
    static fn hex2(v: u32) -> string {
        var out = ""
        for var shift: u32 = 8; shift > 0; shift -= 4 {
            var nib = ((v >> (shift - 4)) & 0xF) as u8
            if nib < 10 {
                out.push(('0' as u8) + nib)
            } else {
                out.push(('a' as u8) + (nib - 10))
            }
        }

        return out
    }

    /// `c` in upper-case hex, at least four digits: the `XXXX` of `U+XXXX`.
    static fn hex4(c: u32) -> string {
        var out        = ""
        var shift: u32 = 24
        while shift > 0 {
            shift -= 4
            var nib = ((c >> shift) & 0xF) as u8
            if nib == 0 && out.size() == 0 && shift > 12 {
                continue
            }

            if nib < 10 {
                out.push(('0' as u8) + nib)
            } else {
                out.push(('A' as u8) + (nib - 10))
            }
        }

        return out
    }

    priv inline fn lex_whitespace(self,
                                  start:       SourceLocation,
                                  first_char:  char,
                                  first_len:   usize,
                                  first_class: CharClass) -> Token {
        /// we consume all whitespace and newlines here
        /// we can batch spaces and newlines into a single new line
        /// we also batch just spaces into a single space token
        /// mixing spaces and newlines creates a new line token
        /// newlines do need to be tracked for line endings since `;` are optional
        /// at the end of lines in Kairo.

        var token:    Token = Token()
        var nl_count: usize = 0

        match first_class {
            case CharClass::Whitespace {
                token.set_kind(TokenKind::TkWhitespace)
            } case CharClass::NewLine {
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
        var p: kairo::std::ConstPtr<u8> = base + self._cursor + first_len

        while p < end {
            var current_char      = Lexer::decode_at(p, (end - p) as usize)
            var c:           char = normalize_char32(current_char.chr)

            match self.classify(c) {
                case CharClass::Whitespace {
                    if token != TokenKind::TkNewLine {
                        token.set_kind(TokenKind::TkWhitespace)
                    }
                } case CharClass::NewLine {
                    token.set_kind(TokenKind::TkNewLine)
                    ++nl_count
                } default {
                    // the run ends BEFORE this character; it is not consumed.
                    self.commit_cursor(base, p)
                    token.set_range(self.create_source_range(start))
                    token.imm = (nl_count as u32)
                    return token
                }
            }

            p += current_char.len
        }

        self.commit_cursor(base, p)
        token.set_range(self.create_source_range(start))
        token.imm = (nl_count as u32)
        return token
    }

    /// table lookup (ASCII_LEX_FLAGS): one load and a mask.
    inline static fn is_valid_symbol(c: DecodeResult) -> bool {
        return is_operator_char(c.chr, c.len)
    }

    /// classifies a character for identifier/keyword scanning.
    ///
    /// ### Returns
    /// 0 not a name character, 1 keyword-safe ASCII, 2 identifier-only.
    ///
    /// table lookup (ASCII_LEX_FLAGS). This is called once per
    /// character by lex_name's scan loop, so the body must stay small
    /// enough to inline into it.
    ///
    ///          One byte is ASCII, the end of the buffer, or a byte that is
    ///          not UTF-8 (name_char_kind keeps that one in the name). A
    ///          longer character is a name character when it is
    ///          XID_Continue.
    inline static fn is_valid_name(c: DecodeResult) -> u8 {
        if c.len <= 1 {
            return name_char_kind(c.chr, c.len)
        }

        if Lexer::in_ranges(
            UnicodeTables::XID_CONTINUE,
            XID_CONTINUE_LEN,
            c.chr as u32,
        ) {
            return 2
        }

        return 0
    }

    /// checks the escape after the backslash at `start` and moves the
    /// cursor past it; false once an error is reported.
    ///
    /// What each escape means is Immediate::Escape's, the table the
    /// literal decoders read too, so the lexer accepts exactly what
    /// they decode. Escape reads bytes, so a non-ASCII character ends
    /// a digit run and is not a digit.
    priv inline fn is_valid_escape(self,
                                   start:     SourceLocation,
                                   is_byte:   bool,
                                   is_format: bool) -> bool {
        var remain = self.remaining_bytes()
        var letter = if remain > 0 => self.current_data()[0] else => (0 as u8)
        var e      = Immediate::Escape(self.current_data(), remain)

        match e.kind {
            case Immediate::EscapeKind::Char {
                self.advance_cursor(e.len)
                if letter != ('b' as u8) || !is_byte {
                    return true
                }

                var range = SourceRange::from_bounds(
                    start,
                    self.get_source_location(),
                )

                self._diag->report(
                    DiagCode(DiagID::S032E),
                    range.start,
                    f"'\\b' (backspace) escape is not valid in a byte string; use '\\x08' instead",
                ).first(range)->emit()
                return false
            } case Immediate::EscapeKind::Brace {
                self.advance_cursor(e.len)
                if is_format {
                    return true
                }

                var range = SourceRange::from_bounds(
                    start,
                    self.get_source_location(),
                )

                // A warning: the literal stands, and the escape is the brace
                // (Immediate::Escape's value), as every decoder reads it.
                self._diag->report(
                    DiagCode(DiagID::S022W),
                    range.start,
                    "'\\{' and '\\}' escapes are only valid inside format strings (f\"...\"); remove the backslash or use an f-string prefix",
                ).first(range)->remove(
                    SourceRange::from_bounds(start, 1u32),
                    "remove the backslash",
                )->emit()
                return true
            } case Immediate::EscapeKind::Hex, Immediate::EscapeKind::Unicode {
                // \xHH, \uHHHH, \UHHHHHHHH: exactly 2, 4 or 8 hex digits
                self.advance_cursor(e.len)
                var is_hex = e.kind == Immediate::EscapeKind::Hex
                var name   = if e.want == 4 => "u" else => "U"
                if e.digits < e.want {
                    var range = SourceRange::from_bounds(
                        start,
                        self.get_source_location(),
                    )

                    // the character that is not a digit is consumed with the escape
                    self.advance_cursor((self.peek_char32().len as usize))
                    if is_hex {
                        self._diag->report(
                            DiagCode(DiagID::S023E),
                            range.start,
                            f"invalid '\\x' hex escape '{self._sm->get_text(range)}': expected exactly 2 hex digits (0-9, a-f, A-F)",
                        ).first(range)->emit()
                    } else {
                        self._diag->report(
                            DiagCode(DiagID::S028E),
                            range.start,
                            f"invalid '\\{name}' unicode escape '{self._sm->get_text(range)}': expected exactly {e.want} hex digits (0-9, a-f, A-F)",
                        ).first(range)->emit()
                    }

                    return false
                }

                if is_hex {
                    return true
                }

                if is_byte {
                    var range = SourceRange::from_bounds(
                        start,
                        self.get_source_location(),
                    )

                    self._diag->report(
                        DiagCode(DiagID::S029E),
                        range.start,
                        f"unicode escape '\\{name}' is not valid in a byte string; use '\\x' for raw byte values",
                    ).first(range)->emit()
                    return false
                }

                // \u's four digits never pass U+10FFFF; \U's eight can
                if e.value > 0x10FFFF {
                    var range = SourceRange::from_bounds(
                        start,
                        self.get_source_location(),
                    )

                    self._diag->report(
                        DiagCode(DiagID::S030E),
                        range.start,
                        f"unicode escape '{self._sm->get_text(range)}' is out of the valid unicode range (U+0000-U+10FFFF)",
                    ).first(range)->emit()
                    return false
                }

                // Surrogate halves are invalid Unicode scalar values
                if e.value >= 0xD800 && e.value <= 0xDFFF {
                    var range = SourceRange::from_bounds(
                        start,
                        self.get_source_location(),
                    )

                    self._diag->report(
                        DiagCode(DiagID::S031E),
                        range.start,
                        f"unicode escape '{self._sm->get_text(range)}' encodes a surrogate code point (U+D800-U+DFFF), which is not a valid unicode scalar value",
                    ).first(range)->emit()
                    return false
                }
            } case Immediate::EscapeKind::Octal {
                // \o, \oo, \ooo
                self.advance_cursor(e.len)
                if !is_byte {
                    var range = SourceRange::from_bounds(
                        start,
                        self.get_source_location(),
                    )

                    // The hex escape is the same character: `\x` is a code
                    // point here too. Above 0xFF there is none, and S027E
                    // follows.
                    var text = self._sm->get_text(range)
                    var hex  = f"\\x{Lexer::hex2(e.value)}"
                    var msg = f"octal escape '{text}' outside a byte string; octal escapes are for byte strings (b\"...\")"
                    if e.value <= 0xFF {
                        msg = f"octal escape '{text}' outside a byte string; write '{hex}' (octal escapes are for byte strings, b\"...\")"
                    }

                    var w = self._diag->report(
                        DiagCode(DiagID::S025W),
                        range.start,
                        msg.copy(),
                    )

                    w.first(range)
                    if e.value <= 0xFF {
                        w.fix(range, hex, "write the hex escape")
                    }

                    w.emit()
                }

                // three octal digits reach 0o777
                if e.value > 0xFF {
                    var range = SourceRange::from_bounds(
                        start,
                        self.get_source_location(),
                    )

                    self._diag->report(
                        DiagCode(DiagID::S027E),
                        range.start,
                        f"octal escape '{self._sm->get_text(range)}' is out of byte range (0-255, i.e., \\0-\\377)",
                    ).first(range)->emit()
                    return false
                }
            } default {
                // the whole character, which may be more than the one byte
                // Escape looked at
                self.advance_cursor((self.peek_char32().len as usize))

                var range = SourceRange::from_bounds(
                    start,
                    self.get_source_location(),
                )

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

    /// errors emitted by THIS lexer's most recent lex() run.
    ///
    /// the DiagEngine is shared across the whole compilation, so its
    /// raw counts are cumulative; comparing against the baseline
    /// captured at lex() entry gives the per-run delta. Anything else
    /// makes one file's (or one test's) errors bleed into the next.
    inline fn has_errors(self) -> bool {
        return self.error_count() > 0
    }

    inline fn error_count(self) -> u32 {
        return self._diag->error_count() - self._err_base
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

// TODO(replace with kairo test blocks)
/// `bench` also runs the hot-loop benchmark, which lexes two 1 GiB buffers.
pub fn Test(bench: bool = false) -> i32 {
    io::println("=== Lexer Test Suite ===\n ")

    var test_diag = DiagEngine()
    // The test lambdas below capture by copy (stage1 semantics), and a
    // DiagEngine is not copyable: they share the engine through this pointer.
    var unsafe *test_diag_p = unsafe &test_diag
    var unsafe *pool        = kairo::std::create<ThreadPool>(4)
    var unsafe *vfm = kairo::std::create<VirtualFileManager>(test_diag_p)
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
        var temp_data = content.copy()
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

        var unsafe *lexer = kairo::std::create<Lexer>(
            lsm,
            lpool,
            diag,
            test_imm,
        )

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

        var unsafe *lexer = kairo::std::create<Lexer>(
            lsm,
            lpool,
            diag,
            test_imm,
        )

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
            var res = create_lexer_from_string_with_diag(
                " ",
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
            var res = create_lexer_from_string_with_diag(
                "foo",
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
            var res = create_lexer_from_string_with_diag(
                "foo#bar my#ident",
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
            var res = create_lexer_from_string_with_diag(
                "{ } ( ) [ ]",
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

                var unsafe *imm = lexer->get_imm<Immediate::IntData>(
                    tokens->get(i)->imm,
                )

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

                var unsafe *imm = lexer->get_imm<Immediate::IntData>(
                    tokens->get(i)->imm,
                )

                imm->evaluate(sm, lexer->get_imm_tbl())

                const base_16: u8 = (16)
                if imm->base != base_16 {
                    return f"token {i}: expected base 16, got base {imm->base}"
                }

                if imm->value_lo != expected_values[i] {
                    return f"token {i}: expected value 0x{to_hex_string(((expected_values[i]) as usize))}, got 0x{to_hex_string(((imm->value_lo) as usize))}"
                }

                if !imm->has_flag(Immediate::IntFlags::HasPrefix) {
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

                var unsafe *imm = lexer->get_imm<Immediate::IntData>(
                    tokens->get(i)->imm,
                )

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

                var unsafe *imm = lexer->get_imm<Immediate::IntData>(
                    tokens->get(i)->imm,
                )

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

                var unsafe *imm = lexer->get_imm<Immediate::IntData>(
                    tokens->get(i)->imm,
                )

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

                var unsafe *imm = lexer->get_imm<Immediate::IntData>(
                    tokens->get(i)->imm,
                )

                if !imm->has_flag(Immediate::IntFlags::HasSuffix) {
                    return f"token {i}: expected has_suffix flag (bit3) to be set, flags={imm->flags}"
                }

                imm->evaluate(sm, lexer->get_imm_tbl())

                if imm->value_lo != expected_values[i] {
                    return f"token {i}: expected value {expected_values[i]}, got {imm->value_lo}"
                }

                if imm->bits != expected_bits[i] {
                    return f"token {i}: expected bits {expected_bits[i]}, got {imm->bits}"
                }

                var is_unsigned = imm->has_flag(Immediate::IntFlags::Unsigned)
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

            var unsafe *imm = lexer->get_imm<Immediate::IntData>(
                tokens->get(0)->imm,
            )

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

            var unsafe *imm = lexer->get_imm<Immediate::IntData>(
                tokens->get(0)->imm,
            )

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

            var unsafe *imm = lexer->get_imm<Immediate::IntData>(
                tokens->get(0)->imm,
            )

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

            var unsafe *imm = lexer->get_imm<Immediate::IntData>(
                tokens->get(0)->imm,
            )

            imm->evaluate(sm, lexer->get_imm_tbl())

            // should have is_big flag set
            if !imm->has_flag(Immediate::IntFlags::IsBig) {
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
                var unsafe *imm = lexer->get_imm<Immediate::IntData>(
                    tokens->get(i)->imm,
                )

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

                var unsafe *imm = lexer->get_imm<Immediate::FloatData>(
                    tokens->get(i)->imm,
                )

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
            var res = create_lexer_from_string_with_diag(
                ".5, .123, .0",
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
            // A `.` + digit is a leading-dot float only where a value starts
            // (after a value it is member access, `t.0`), so commas separate them.
            const expected_count: usize = (3)
            if content_count(tokens) != expected_count * 2 - 1 {
                return dump_tokens(tokens, expected_count * 2 - 1)
            }

            var expected_values = cxx::std::vector<f64>()
            expected_values.push_back(0.5 as f64)
            expected_values.push_back(0.123 as f64)
            expected_values.push_back(0.0 as f64)

            for var i: usize = 0; i < expected_count; ++i {
                if tokens->get(i * 2)->kind != TokenKind::LitFloat {
                    return f"token {i * 2}: expected LitFloat, got {token_kind_to_readable_string(tokens->get(i * 2)->kind)}"
                }

                var unsafe *imm = lexer->get_imm<Immediate::FloatData>(
                    tokens->get(i * 2)->imm,
                )

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

                var unsafe *imm = lexer->get_imm<Immediate::FloatData>(
                    tokens->get(i)->imm,
                )

                if !imm->has_flag(Immediate::FloatFlags::HasExponent) {
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

                var unsafe *imm = lexer->get_imm<Immediate::FloatData>(
                    tokens->get(i)->imm,
                )

                if !imm->has_flag(Immediate::FloatFlags::IsHex) {
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
            var res = create_lexer_from_string_with_diag(
                "0xA.Bp+2 0xC.8p-1",
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
                var unsafe *imm = lexer->get_imm<Immediate::FloatData>(
                    tokens->get(i)->imm,
                )

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

                var unsafe *imm = lexer->get_imm<Immediate::FloatData>(
                    tokens->get(i)->imm,
                )

                if !imm->has_flag(Immediate::FloatFlags::HasSuffix) {
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
                var unsafe *imm = lexer->get_imm<Immediate::FloatData>(
                    tokens->get(i)->imm,
                )

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
            var res = create_lexer_from_string_with_diag(
                "foo.bar, .5",
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
            // `bar .5` would be member access (`t .0`): the float follows a comma.
            const expected_count: usize = (5)
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

            if tokens->get(4)->kind != TokenKind::LitFloat {
                return f"token 4: expected LitFloat (.5), got {token_kind_to_readable_string(tokens->get(4)->kind)}"
            }

            // verify the float value
            var unsafe *imm = lexer->get_imm<Immediate::FloatData>(
                tokens->get(4)->imm,
            )

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
            var res = create_lexer_from_string_with_diag(
                "1e0 1e+0 1e-0 0e0",
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

            // all should evaluate to their base value (exponent is 0)
            var expected_values = cxx::std::vector<f64>()
            expected_values.push_back(1.0 as f64)
            expected_values.push_back(1.0 as f64)
            expected_values.push_back(1.0 as f64)
            expected_values.push_back(0.0 as f64)

            for var i: usize = 0; i < expected_count; ++i {
                var unsafe *imm = lexer->get_imm<Immediate::FloatData>(
                    tokens->get(i)->imm,
                )

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
            var res = create_lexer_from_string_with_diag(
                "0..10 0.5 1..2",
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
            var unsafe *int0 = lexer->get_imm<Immediate::IntData>(
                tokens->get(0)->imm,
            )

            int0->evaluate(sm, lexer->get_imm_tbl())
            const zero_u64: u64 = (0)
            if int0->value_lo != zero_u64 {
                return f"token 0: expected value 0, got {int0->value_lo}"
            }

            var unsafe *int2 = lexer->get_imm<Immediate::IntData>(
                tokens->get(2)->imm,
            )

            int2->evaluate(sm, lexer->get_imm_tbl())
            const ten_u64: u64 = (10)
            if int2->value_lo != ten_u64 {
                return f"token 2: expected value 10, got {int2->value_lo}"
            }

            var unsafe *float3 = lexer->get_imm<Immediate::FloatData>(
                tokens->get(3)->imm,
            )

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
            var res = create_lexer_from_string_with_diag(
                "1e308 1e-308",
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
            const      expected_count: usize = (2)
            if content_count(tokens) != expected_count {
                return dump_tokens(tokens, expected_count)
            }

            for var i: usize = 0; i < expected_count; ++i {
                if tokens->get(i)->kind != TokenKind::LitFloat {
                    return f"token {i}: expected LitFloat, got {token_kind_to_readable_string(tokens->get(i)->kind)}"
                }

                var unsafe *imm = lexer->get_imm<Immediate::FloatData>(
                    tokens->get(i)->imm,
                )

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
            var res = create_lexer_from_string_with_diag(
                "\"hello world\"",
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
        "lex empty string",
        "pass",
        fn () -> string {
            var res = create_lexer_from_string_with_diag(
                "\"\"",
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
            var res = create_lexer_from_string_with_diag(
                "\"\\U0001F600\"",
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
        "lex f-string simple",
        "pass",
        fn () -> string {
            var res = create_lexer_from_string_with_diag(
                "f\"hello {name}\"",
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

            var unsafe *imm = lexer->get_imm<Immediate::StringData>(
                tokens->get(0)->imm,
            )

            if !imm->prefix_kind.equals(
                FlagSet<Immediate::TextPrefixKind, u8>(
                    Immediate::TextPrefixKind::Format,
                ),
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

            var unsafe *imm = lexer->get_imm<Immediate::StringData>(
                tokens->get(0)->imm,
            )

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
            var res = create_lexer_from_string_with_diag(
                "r\"hello\"",
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

            var unsafe *imm = lexer->get_imm<Immediate::StringData>(
                tokens->get(0)->imm,
            )

            if !imm->prefix_kind.equals(
                FlagSet<Immediate::TextPrefixKind, u8>(
                    Immediate::TextPrefixKind::Raw,
                ),
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
            var res = create_lexer_from_string_with_diag(
                "fr\"value: {x}\"",
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

            var unsafe *imm = lexer->get_imm<Immediate::StringData>(
                tokens->get(0)->imm,
            )

            var want = FlagSet<Immediate::TextPrefixKind, u8>(
                Immediate::TextPrefixKind::Raw,
            ).plus(Immediate::TextPrefixKind::Format)

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
            var res = create_lexer_from_string_with_diag(
                "'a' 'Z' '0'",
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
            var res = create_lexer_from_string_with_diag(
                "foo */ bar",
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
    // Balance tracking lives in the preprocessor, which tracks it on the post-PP stream.

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
            var res = create_lexer_from_string_with_diag(
                "café αβγ 日本語",
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
            var res = create_lexer_from_string_with_diag(
                "a+-b",
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
            var res = create_lexer_from_string_with_diag(
                "Vec::<i32>",
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
            var res = create_lexer_from_string_with_diag(
                "0..10 0..=10",
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
            var res = create_lexer_from_string_with_diag(
                "2^^8",
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
            var res = create_lexer_from_string_with_diag(
                "a <=> b",
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
            var res = create_lexer_from_string_with_diag(
                "a === b",
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
            var res = create_lexer_from_string_with_diag(
                "null",
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
            var res = create_lexer_from_string_with_diag(
                "true false",
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
            var res = create_lexer_from_string_with_diag(
                "foo bar foo",
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
            // An engine of its own each run: the shared one drops a report
            // it already delivered at that location, so every run after
            // the first would see no error.
            var diag = DiagEngine()
            var res = create_lexer_from_string_with_diag(
                "\"hello\\qworld\"",
                sm,
                pool,
                unsafe &diag,
            )

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

    // `b"..."` is one string token with the Bytes prefix kind, and a
    // unicode escape in it is an error (S029E).
    suite.equal<string>(
        "byte string prefix",
        "pass",
        fn () -> string {
            var res = create_lexer_from_string_with_diag(
                "b\"\\x41\"",
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
                return f"expected LitString, got {token_kind_to_readable_string(tokens->get(0)->kind)}"
            }

            var unsafe *imm = lexer->get_imm<Immediate::StringData>(
                tokens->get(0)->imm,
            )

            if !imm->prefix_kind.has(Immediate::TextPrefixKind::Bytes) {
                return "expected prefix_kind Bytes"
            }

            if lexer->has_errors() {
                return f"lexer reported {lexer->error_count()} error(s) for a valid byte string"
            }

            return "pass"
        },
        10,
    )

    suite.equal<string>(
        "unicode escape in a byte string is an error",
        "pass",
        fn () -> string {
            // An engine of its own each run: the shared one drops a report
            // it already delivered at that location, so every run after
            // the first would see no error.
            var diag = DiagEngine()
            var res = create_lexer_from_string_with_diag(
                "b\"\\u0041\"",
                sm,
                pool,
                unsafe &diag,
            )

            var unsafe *lexer = res.0
            var        fid    = res.1

            finally {
                kairo::std::destroy(lexer)
            }

            lexer->lex(fid)
            if !lexer->has_errors() {
                return "expected S029E for '\\u' in a byte string, but no errors found"
            }

            return "pass"
        },
        10,
    )

    suite.equal<string>(
        "error on surrogate in unicode escape",
        "pass",
        fn () -> string {
            // An engine of its own each run: the shared one drops a report
            // it already delivered at that location, so every run after
            // the first would see no error.
            var diag = DiagEngine()
            var res = create_lexer_from_string_with_diag(
                "\"\\uD800\"",
                sm,
                pool,
                unsafe &diag,
            )

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

            var res = create_lexer_from_string_with_diag(
                code.copy(),
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

    if suite.failures() != 0 {
        return 1
    }

    if !bench {
        return 0
    }

    // THROUGHPUT MEASUREMENT

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
            " +/// \\returns the resolved declaration, or null when lookup fails outright\n" + f"inline priv fn resolve_declaration_reference_{i}(\n" + "    self,\n" + "    @inout resolution_context: NameResolutionContext,\n" + "    candidate_reference: obs::<UnresolvedIdentifierExpr>\n" + ") -> own::<ResolvedDeclaration> {\n" + "    var enclosing_lexical_scope = resolution_context.scope_chain().innermost();\n" + "\n" + "    if enclosing_lexical_scope == &null {\n" + "        self.diagnostic_engine->report(DiagCode(DiagID::R001E),\n" + "            candidate_reference->range.start,\n" + "            f\"unresolved identifier {candidate_reference} in this scope\")\n" + "            .first(candidate_reference->range).emit();\n" + "        return &null;\n" + "    }\n" + "\n" + "    var depth = enclosing_lexical_scope->depth() + 1;\n" + "    if (depth > 0) && (depth < 64) && !candidate_reference->is_synthetic {\n" + "        resolution_context.record(candidate_reference, depth * 2 - 1);\n" + "    }\n" + "\n" + "    switch candidate_reference->lookup_kind {\n" + "        case LookupKind::Ordinary {\n" + "            return enclosing_lexical_scope->lookup_ordinary::<ResolvedDeclaration>(\n" + "                candidate_reference->qualified_name);\n" + "        } case LookupKind::Qualified {\n" + "            return enclosing_lexical_scope->lookup_qualified::<ResolvedDeclaration>(\n" + "                candidate_reference->qualified_name);\n" + "        } default {\n" + "            return &null;\n" + "        }\n" + "    }\n" + "}\n" + "\n"
        }

        return kairo::std::to_std_string(wide)
    }

    var mismatch = false
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
        var hot_res = create_lexer_from_bytes(
            cxx::std::move(hot_code),
            sm,
            pool,
            test_diag_p,
        )

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
                    mismatch = true
                    io::println(
                        f"[{label}] MISMATCH: run1 {run1_count} tokens, run2 {count} tokens -- open() is not restoring state from close()\n",
                    )
                }
            }
        }

        kairo::std::destroy(hot_lexer)
    }

    return if mismatch => (1) else => 0
}
