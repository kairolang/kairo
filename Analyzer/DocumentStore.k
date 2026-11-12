

import Json::*
import Protocol::*

/// \brief `file://` URI -> filesystem path (percent-decoded).
///
/// \details A Windows URI is `file:///C:/x`: the path is what follows the
///          third slash, so the leading `/` goes when a drive letter follows.
///          Anything that is not a file URI comes back unchanged, which keeps
///          `untitled:` buffers addressable by the same key.
pub fn uri_to_path(const uri: string) -> string {
    var prefix = "file://"
    if !uri.starts_with(prefix) {
        return uri
    }

    var out = string()
    var i   = prefix.size()
    while i < uri.size() {
        var c = uri[i]
        if (c == ('%' as u8)) && ((i + 2) < uri.size()) {
            var hi = hex_val(uri[i + 1])
            var lo = hex_val(uri[i + 2])
            if (hi < 16) && (lo < 16) {
                out.push_back(((hi << 4) | lo) as u8)
                i += 3
                continue
            }
        }

        out.push_back(c)
        i += 1
    }

    if (out.size() >= 3) && (out[0] == ('/' as u8)) && (out[2] == (':' as u8)) {
        out = out.subslice(1, out.size() - 1)
    }

    return out
}

/// \brief filesystem path -> `file://` URI. Inverse of uri_to_path.
pub fn path_to_uri(const path: string) -> string {
    var hex = "0123456789ABCDEF"
    var out: string = "file://"
    if (path.size() >= 2) && (path[1] == (':' as u8)) {
        out.push_back('/' as u8)
    }

    for var i: usize = 0; i < path.size(); ++i {
        var c = path[i]
        if c == ('\\' as u8) {
            // Windows separators are `/` inside a URI.
            out.push_back('/' as u8)
            continue
        }

        var plain = ((c >= ('a' as u8)) && (c <= ('z' as u8))) || ((c >= ('A' as u8)) && (c <= ('Z' as u8))) || ((c >= ('0' as u8)) && (c <= ('9' as u8)))
            || (c == ('/' as u8)) || (c == ('-' as u8)) || (c == ('.' as u8)) || (c == ('_' as u8)) || (c == ('~' as u8)) || (c == (':' as u8))
        if plain {
            out.push_back(c)
        } else {
            out.push_back('%' as u8)
            out.push_back(hex[(c >> 4) as usize])
            out.push_back(hex[(c & 15) as usize])
        }
    }

    return out
}

pub fn hex_val(c: u8) -> u32 {
    if (c >= ('0' as u8)) && (c <= ('9' as u8)) {
        return c - 48
    }

    if (c >= ('a' as u8)) && (c <= ('f' as u8)) {
        return c - 87
    }

    if (c >= ('A' as u8)) && (c <= ('F' as u8)) {
        return c - 55
    }

    return 16
}

/// \class LineMap
/// \brief byte offset <-> LSP position for one text.
///
/// \details LSP columns count UTF-16 code units unless the client agreed to
///          UTF-8 at initialize (`utf8` below). The compiler counts bytes.
///          Every position that crosses the protocol goes through here, in
///          one direction or the other; nothing else in the server converts.
pub class LineMap {
    pub var starts: [usize]       ///< byte offset of each line's first byte
    pub var size:   usize = 0

    fn LineMap(self) = default

    fn build(self, const text: string) {
        self.starts.clear()
        self.starts.push_back(0)
        self.size = text.size()
        for var i: usize = 0; i < text.size(); ++i {
            if text[i] == ('\n' as u8) {
                self.starts.push_back(i + 1)
            }
        }
    }

    fn line_count(const self) -> usize {
        return self.starts.size()
    }

    /// Offset one past the last byte of \p line, its terminator excluded.
    fn line_end(const self, const text: string, line: usize) -> usize {
        var end = self.size
        if (line + 1) < self.starts.size() {
            end = self.starts[line + 1] - 1
            if (end > self.starts[line]) && (text[end - 1] == ('\r' as u8)) {
                end -= 1
            }
        }

        return end
    }

    /// 0-based line holding byte \p off.
    fn line_of(const self, off: usize) -> usize {
        var lo: usize = 0
        var hi = self.starts.size()
        while (lo + 1) < hi {
            var mid = (lo + hi) / 2
            if self.starts[mid] <= off {
                lo = mid
            } else {
                hi = mid
            }
        }

        return lo
    }

    /// Byte offset of (line, character). Out-of-range values clamp, because a
    /// client and server one edit apart must not turn into an out-of-bounds
    /// read.
    fn offset(const self, const text: string, line: usize, character: usize, utf8: bool) -> usize {
        if line >= self.starts.size() {
            return self.size
        }

        var i   = self.starts[line]
        var end = self.line_end(text, line)
        if utf8 {
            if (i + character) > end {
                return end
            }

            return i + character
        }

        var units: usize = 0
        while (i < end) && (units < character) {
            var c = text[i]
            var n: usize = 1
            var u: usize = 1
            if c >= 0xF0 {
                n = 4
                u = 2 // outside the BMP: a surrogate pair
            } else if c >= 0xE0 {
                n = 3
            } else if c >= 0xC0 {
                n = 2
            }

            i     += n
            units += u
        }

        if i > end {
            return end
        }

        return i
    }

    /// LSP character of byte \p off within its line.
    fn character(const self, const text: string, off: usize, utf8: bool) -> usize {
        var line = self.line_of(off)
        var i    = self.starts[line]
        if utf8 {
            return off - i
        }

        var units: usize = 0
        while (i < off) && (i < text.size()) {
            var c = text[i]
            if c >= 0xF0 {
                i     += 4
                units += 2
            } else if c >= 0xE0 {
                i     += 3
                units += 1
            } else if c >= 0xC0 {
                i     += 2
                units += 1
            } else {
                i     += 1
                units += 1
            }
        }

        return units
    }
}

/// \class GapText
/// \brief a buffer's bytes and line starts, editable in time proportional to
///        the edit.
///
/// \details A didChange used to rebuild the whole string and its line table:
///          on a 1 MB file that is a megabyte copied and scanned per
///          keystroke. Here both the bytes and the line starts are gap
///          buffers. Edits cluster where the cursor is, so moving a gap is
///          short; an edit costs its own size, the lines it adds or removes,
///          and the distance from the previous edit.
///
///          Bytes: [0, gs) and [ge, buf.size()) hold the text, the gap
///          between them is free.
///
///          Line starts: entries [0, lgs) are ABSOLUTE offsets of lines that
///          start at or before the last edit; entries [lge, ls.size()) are
///          stored as `size - start`, the distance from the END of the text.
///          An edit only shifts what lies after it, and a distance from the
///          end does not change when text before it grows or shrinks, so no
///          entry past the edit is touched. Moving the gap converts the
///          entries it crosses.
pub class GapText {
    priv var buf: [u8]
    priv var gs:  usize = 0
    priv var ge:  usize = 0
    priv var ls:  [usize]
    priv var lgs: usize = 0
    priv var lge: usize = 0

    pub var size: usize = 0

    fn GapText(self) = default

    fn assign(self, const text: string) {
        self.size = text.size()
        var cap = text.size() + 4096
        self.buf.clear()
        self.buf.resize(cap)
        for var i: usize = 0; i < text.size(); ++i {
            self.buf[i] = text[i]
        }

        self.gs = text.size()
        self.ge = cap

        var n: usize = 1
        for var i: usize = 0; i < text.size(); ++i {
            if text[i] == ('\n' as u8) {
                n += 1
            }
        }

        self.ls.clear()
        self.ls.resize(n + 256)
        self.ls[0] = 0
        var k: usize = 1
        for var i: usize = 0; i < text.size(); ++i {
            if text[i] == ('\n' as u8) {
                self.ls[k] = i + 1
                k += 1
            }
        }

        self.lgs = n
        self.lge = self.ls.size()
    }

    inline fn at(const self, i: usize) -> u8 {
        if i < self.gs {
            return self.buf[i]
        }

        return self.buf[i + (self.ge - self.gs)]
    }

    inline fn line_count(const self) -> usize {
        return self.lgs + (self.ls.size() - self.lge)
    }

    inline fn start(const self, line: usize) -> usize {
        if line < self.lgs {
            return self.ls[line]
        }

        return self.size - self.ls[self.lge + (line - self.lgs)]
    }

    /// Offset one past the last byte of \p line, its terminator excluded.
    fn line_end(const self, line: usize) -> usize {
        if (line + 1) >= self.line_count() {
            return self.size
        }

        var end = self.start(line + 1) - 1
        if (end > self.start(line)) && (self.at(end - 1) == ('\r' as u8)) {
            end -= 1
        }

        return end
    }

    /// 0-based line holding byte \p off.
    fn line_of(const self, off: usize) -> usize {
        var lo: usize = 0
        var hi = self.line_count()
        while (lo + 1) < hi {
            var mid = (lo + hi) / 2
            if self.start(mid) <= off {
                lo = mid
            } else {
                hi = mid
            }
        }

        return lo
    }

    /// Byte offset of (line, character), clamped like LineMap::offset.
    fn offset(const self, line: usize, character: usize, utf8: bool) -> usize {
        if line >= self.line_count() {
            return self.size
        }

        var i   = self.start(line)
        var end = self.line_end(line)
        if utf8 {
            if (i + character) > end {
                return end
            }

            return i + character
        }

        var units: usize = 0
        while (i < end) && (units < character) {
            var c = self.at(i)
            var n: usize = 1
            var u: usize = 1
            if c >= 0xF0 {
                n = 4
                u = 2 // outside the BMP: a surrogate pair
            } else if c >= 0xE0 {
                n = 3
            } else if c >= 0xC0 {
                n = 2
            }

            i     += n
            units += u
        }

        if i > end {
            return end
        }

        return i
    }

    /// The text as one string: what a worker or a text scanner reads. O(size),
    /// so it is asked for once per use, never per keystroke.
    fn str(const self) -> string {
        var out = string()
        out.reserve(self.size)
        for var i: usize = 0; i < self.gs; ++i {
            out.push_back(self.buf[i])
        }

        for var i: usize = self.ge; i < self.buf.size(); ++i {
            out.push_back(self.buf[i])
        }

        return out
    }

    /// Moves the byte gap to \p pos.
    priv fn move_gap_(self, pos: usize) {
        if pos < self.gs {
            var n = self.gs - pos
            __builtin_move_mem(unsafe &self.buf[self.ge - n], unsafe &self.buf[pos], n)
            self.gs = pos
            self.ge -= n
        } else if pos > self.gs {
            var n = pos - self.gs
            __builtin_move_mem(unsafe &self.buf[self.gs], unsafe &self.buf[self.ge], n)
            self.gs += n
            self.ge += n
        }
    }

    /// Makes room for \p need more bytes in the gap.
    priv fn grow_(self, need: usize) {
        if (self.ge - self.gs) >= need {
            return
        }

        var tail    = self.buf.size() - self.ge
        var new_cap = (self.buf.size() * 2) + need + 4096
        var nb: [u8]
        nb.resize(new_cap)
        if self.gs > 0 {
            __builtin_copy(unsafe &nb[0], unsafe &self.buf[0], self.gs)
        }

        if tail > 0 {
            __builtin_copy(unsafe &nb[new_cap - tail], unsafe &self.buf[self.ge], tail)
        }

        self.buf = nb
        self.ge  = new_cap - tail
    }

    /// Moves the line gap so that [0, lgs) are exactly the lines that start
    /// at or before \p line's start (lines 0..=line).
    priv fn move_line_gap_(self, line: usize) {
        var want = line + 1
        while self.lgs > want {
            // Line lgs-1 crosses to the right: store its distance from the end.
            self.lgs -= 1
            self.lge -= 1
            self.ls[self.lge] = self.size - self.ls[self.lgs]
        }

        while self.lgs < want {
            self.ls[self.lgs] = self.size - self.ls[self.lge]
            self.lgs += 1
            self.lge += 1
        }
    }

    priv fn grow_lines_(self, need: usize) {
        if (self.lge - self.lgs) >= need {
            return
        }

        var tail    = self.ls.size() - self.lge
        var new_cap = (self.ls.size() * 2) + need + 256
        var nl: [usize]
        nl.resize(new_cap)
        for var i: usize = 0; i < self.lgs; ++i {
            nl[i] = self.ls[i]
        }

        for var i: usize = 0; i < tail; ++i {
            nl[new_cap - tail + i] = self.ls[self.lge + i]
        }

        self.ls  = nl
        self.lge = new_cap - tail
    }

    /// Replaces bytes [s, e) with \p insert.
    fn replace(self, start: usize, end: usize, const insert: string) {
        var s = start
        var e = end
        if s > self.size {
            s = self.size
        }

        if e > self.size {
            e = self.size
        }

        if e < s {
            e = s
        }

        // Lines: the ones starting inside (s, e] go, one per newline the
        // insert carries comes in. Everything after e keeps its entry.
        var sl = self.line_of(s)
        var el = self.line_of(e)
        self.move_line_gap_(sl)
        self.lge += el - sl

        // Bytes.
        self.move_gap_(s)
        self.ge += e - s
        self.grow_(insert.size())
        for var i: usize = 0; i < insert.size(); ++i {
            self.buf[self.gs + i] = insert[i]
        }

        self.gs   += insert.size()
        self.size  = self.size - (e - s) + insert.size()

        var nl: usize = 0
        for var i: usize = 0; i < insert.size(); ++i {
            if insert[i] == ('\n' as u8) {
                nl += 1
            }
        }

        if nl > 0 {
            self.grow_lines_(nl)
            for var i: usize = 0; i < insert.size(); ++i {
                if insert[i] == ('\n' as u8) {
                    self.ls[self.lgs] = s + i + 1
                    self.lgs += 1
                }
            }
        }
    }
}

/// Whether a buffer's syntax pass is in flight.
pub enum SynReq derives u8 {
    Idle,
    InFlight,
}

/// \class SyntaxState
/// \brief one buffer's syntax-only pass: the request, and the last result.
///
/// \details Both paths, the persistent syntax worker and a process per pass,
///          go through these transitions, so they apply one rule: a pass is
///          due when the buffer changed after the newest pass was started,
///          and an answer lands only for the text the buffer still holds
///          (an answer for an older text has the old text's positions).
pub class SyntaxState {
    pub var req:     SynReq = SynReq::Idle
    pub var started: u64    = 0     ///< the buffer's changed_at the newest pass was started for (0: none)

    /// The last pass that landed (valid when `landed`): the server
    /// revision it saw, whether the text parsed, its diagnostics (LSP
    /// Diagnostic objects, comma-joined) and its lexical tokens.
    pub var landed: bool   = false
    pub var at:     u64    = 0
    pub var parsed: bool   = true
    pub var diags:  string = ""
    pub var tokens: [i64]

    fn SyntaxState(self) = default

    /// Is a pass due for a buffer last changed at \p changed_at?
    fn due(const self, changed_at: u64) -> bool {
        return (self.req == SynReq::Idle) && (changed_at > self.started)
    }

    /// A pass of the text as changed at \p changed_at has started.
    fn begin(self, changed_at: u64) {
        self.req     = SynReq::InFlight
        self.started = changed_at
    }

    /// The pass in flight ended: its answer came, landed or not.
    fn finish(self) {
        self.req = SynReq::Idle
    }

    /// The pass in flight was lost (its worker died): due again.
    fn abandon(self) {
        self.req     = SynReq::Idle
        self.started = 0
    }

    /// Would an answer computed at server revision \p rev land, for a
    /// buffer last changed at \p changed_at? Not when the buffer changed
    /// after the pass was sent (stale), nor over a newer landed result.
    fn accepts(const self, rev: u64, changed_at: u64) -> bool {
        if changed_at > rev {
            return false
        }

        return (!self.landed) || (rev >= self.at)
    }

    /// The landed result is of the text as changed at \p changed_at.
    fn current(const self, changed_at: u64) -> bool {
        return self.landed && (self.at >= changed_at)
    }

    /// Lands an answer; false (nothing changes) when accepts() refuses it.
    fn land(self, rev: u64, changed_at: u64, parsed: bool, const diags: string, @inout tokens: [i64]) -> bool {
        if !self.accepts(rev, changed_at) {
            return false
        }

        self.landed = true
        self.at     = rev
        self.parsed = parsed
        self.diags  = diags
        self.tokens = tokens
        return true
    }
}

/// \class Document
/// \brief one open buffer: the editor's text, which wins over the disk.
///
/// \details The text lives in `buf` (GapText). `text` and `lines` are a
///          materialised copy for the code that scans whole strings (the
///          text scanners, formatting, a worker's overlay file); sync() makes
///          them current, and only those requests call it, so a keystroke
///          never pays for the whole document.
pub class Document {
    pub var uri:     string  = ""
    pub var path:    string  = ""
    pub var version: i64     = 0
    pub var buf:     GapText
    pub var text:    string  = ""
    pub var lines:   LineMap
    pub var text_rev: u64    = u64::MAX  ///< revision `text` was materialised at

    /// Its syntax-only pass (Server/Diagnostics.k, Server/SyntaxWorker.k):
    /// the request in flight and the last result that landed.
    pub var syn: SyntaxState

    /// Bumped on every content change. A snapshot records the revision it
    /// was computed from; equal revisions mean its positions are exact.
    pub var revision: u64 = 0

    /// Stable for the life of the buffer (indices shift when another closes);
    /// names the files its text is handed to a worker in.
    pub var slot: u64 = 0

    /// Where this buffer's text was last written for a worker, and which
    /// revision that was. Empty until the first analysis needs it.
    /// The server's revision counter when this buffer last changed: a
    /// snapshot computed at or after it has this buffer's exact positions.
    pub var changed_at: u64 = 0
    pub var changed_ms: i64 = 0  ///< wall time of that change (now_ms): the publish coalescing

    pub var tmp_path: string = ""
    pub var tmp_rev:  u64    = 0

    /// Is this buffer's syntax pass due (SyntaxState::due)?
    fn syn_due(const self) -> bool {
        return self.syn.due(self.changed_at)
    }

    /// The text this buffer's file was last INDEXED from: the overlay a run
    /// read (Job::texts), or the disk text a buffer opened unchanged. The
    /// index outlives edits that stop the file parsing, and a request at a
    /// position on a line that is the same in both texts is answered from
    /// it (Server::line_shift; LanguageServer.md section 9). Valid only for
    /// the index of `idx_entry` computed at `idx_rev`: an empty entry means
    /// no such text is known, and the requests answer as on any stale index.
    pub var idx_text:  string = ""
    pub var idx_lines: LineMap
    pub var idx_rev:   u64    = 0
    pub var idx_entry: string = ""

    /// What a live index worker found when it tried this buffer's text
    /// without keeping it (Server/LiveIndex.k: a buffer that does not
    /// parse): the file's diagnostics (LSP Diagnostic objects, comma-joined)
    /// and their number, for the text as changed at `side_at`. `side_state`
    /// is the worker's word for it: `partial` (checked without the function
    /// bodies its syntax errors are in) or `unchecked`. Used while the
    /// buffer has not changed since (side_current).
    /// The file `idx_text` was last written to for a live worker that is to
    /// keep it (the buffer does not parse), and the `idx_rev` it was.
    pub var held_tmp: string = ""
    pub var held_rev: u64    = 0

    pub var side_has:   bool   = false
    pub var side_at:    u64    = 0
    pub var side_state: string = ""
    pub var side_diags: string = ""
    pub var side_n:     usize  = 0

    fn side_current(const self) -> bool {
        return self.side_has && (self.side_at >= self.changed_at)
    }

    fn Document(self) = default

    /// Records \p text as what entry \p entry's index of revision \p rev
    /// read for this buffer.
    fn set_indexed(self, const text: string, rev: u64, const entry: string) {
        self.idx_text  = text
        self.idx_lines.build(text)
        self.idx_rev   = rev
        self.idx_entry = entry
    }

    fn set_text(self, const text: string) {
        self.buf.assign(text)
        self.revision += 1
    }

    /// Replaces [start, end) (byte offsets) with \p insert.
    fn splice(self, start: usize, end: usize, const insert: string) {
        self.buf.replace(start, end, insert)
        self.revision += 1
    }

    /// Makes `text` and `lines` the current text. O(document) when it
    /// changed since the last call, nothing otherwise.
    fn sync(self) {
        if self.text_rev == self.revision {
            return
        }

        self.text = self.buf.str()
        self.lines.build(self.text)
        self.text_rev = self.revision
    }
}

/// FNV-1a over \p text: the `$/kals/text` debug answer, which a test compares
/// with its own copy of the buffer.
pub fn fnv1a(const text: string) -> u64 {
    var h: u64 = 14695981039346656037
    for var i: usize = 0; i < text.size(); ++i {
        h = h ^ (text[i] as u64)
        h = h * 1099511628211
    }

    return h
}

/// \class DocumentStore
/// \brief the open buffers, by URI.
///
/// \details A linear list: an editor has a handful of buffers open, and a
///          lookup happens once per message.
pub class DocumentStore {
    pub var docs: [Document]

    /// The client agreed to UTF-8 positions at initialize.
    pub var utf8: bool = false

    pub var next_slot: u64 = 0

    fn DocumentStore(self) = default

    fn index_of(const self, const uri: string) -> usize {
        for var i: usize = 0; i < self.docs.size(); ++i {
            if self.docs[i].uri == uri {
                return i
            }
        }

        return usize::MAX
    }

    fn index_of_path(const self, const path: string) -> usize {
        for var i: usize = 0; i < self.docs.size(); ++i {
            if self.docs[i].path == path {
                return i
            }
        }

        return usize::MAX
    }

    /// Materialises every buffer that changed: for the requests that scan
    /// whole texts (Document::sync).
    fn sync_all(self) {
        for var i: usize = 0; i < self.docs.size(); ++i {
            self.docs[i].sync()
        }
    }

    fn open(self, const uri: string, version: i64, const text: string) -> usize {
        var i = self.index_of(uri)
        if i == usize::MAX {
            var d = Document()
            d.uri  = uri
            d.path = uri_to_path(uri)
            self.next_slot += 1
            d.slot = self.next_slot
            self.docs.push_back(d)
            i = self.docs.size() - 1
        }

        self.docs[i].version = version
        self.docs[i].set_text(text)
        return i
    }

    fn close(self, const uri: string) {
        var i = self.index_of(uri)
        if i == usize::MAX {
            return
        }

        self.docs.erase(&self.docs[i])
    }

    /// Applies a didChange `contentChanges` array (node \p changes of \p msg)
    /// in order. Each change is either a range replacement or the full text.
    fn change(self, i: usize, version: i64, msg: *const JsonDoc, changes: u32) {
        self.docs[i].version = version
        var c = msg->first(changes)
        while c != JSON_NONE() {
            var range = msg->get(c, K_RANGE)
            var text  = msg->get_str(c, K_TEXT)
            if msg->is_object(range) {
                var s = msg->get(range, K_START)
                var e = msg->get(range, K_END)
                var so = self.docs[i].buf.offset(
                    msg->get_int(s, K_LINE) as usize,
                    msg->get_int(s, K_CHARACTER) as usize,
                    self.utf8,
                )

                var eo = self.docs[i].buf.offset(
                    msg->get_int(e, K_LINE) as usize,
                    msg->get_int(e, K_CHARACTER) as usize,
                    self.utf8,
                )

                self.docs[i].splice(so, eo, text)
            } else {
                self.docs[i].set_text(text)
            }

            c = msg->next(c)
        }
    }
}
