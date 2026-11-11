

import Json::*

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
        if (c == 37) && ((i + 2) < uri.size()) {
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

    if (out.size() >= 3) && (out[0] == 47) && (out[2] == 58) {
        out = out.subslice(1, out.size() - 1)
    }

    return out
}

/// \brief filesystem path -> `file://` URI. Inverse of uri_to_path.
pub fn path_to_uri(const path: string) -> string {
    var hex = "0123456789ABCDEF"
    var out: string = "file://"
    if (path.size() >= 2) && (path[1] == 58) {
        out.push_back(47)
    }

    for var i: usize = 0; i < path.size(); ++i {
        var c = path[i]
        if c == 92 {
            // Windows separators are `/` inside a URI.
            out.push_back(47)
            continue
        }

        var plain = ((c >= 97) && (c <= 122)) || ((c >= 65) && (c <= 90)) || ((c >= 48) && (c <= 57))
            || (c == 47) || (c == 45) || (c == 46) || (c == 95) || (c == 126) || (c == 58)
        if plain {
            out.push_back(c)
        } else {
            out.push_back(37)
            out.push_back(hex[(c >> 4) as usize])
            out.push_back(hex[(c & 15) as usize])
        }
    }

    return out
}

pub fn hex_val(c: u8) -> u32 {
    if (c >= 48) && (c <= 57) {
        return c - 48
    }

    if (c >= 97) && (c <= 102) {
        return c - 87
    }

    if (c >= 65) && (c <= 70) {
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
            if text[i] == 10 {
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
            if (end > self.starts[line]) && (text[end - 1] == 13) {
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

/// \class Document
/// \brief one open buffer: the editor's text, which wins over the disk.
pub class Document {
    pub var uri:     string  = ""
    pub var path:    string  = ""
    pub var version: i64     = 0
    pub var text:    string  = ""
    pub var lines:   LineMap

    /// Bumped on every content change. A snapshot records the revision it
    /// was computed from; equal revisions mean its positions are exact.
    pub var revision: u64 = 0

    /// Stable for the life of the buffer (indices shift when another closes);
    /// names the files its text is handed to a worker in.
    pub var slot: u64 = 0

    /// Where this buffer's text was last written for a worker, and which
    /// revision that was. Empty until the first analysis needs it.
    pub var tmp_path: string = ""
    pub var tmp_rev:  u64    = 0

    fn Document(self) = default

    fn set_text(self, const text: string) {
        self.text = text
        self.lines.build(self.text)
        self.revision += 1
    }

    /// Replaces [start, end) (byte offsets) with \p insert.
    fn splice(self, start: usize, end: usize, const insert: string) {
        var s = start
        var e = end
        if s > self.text.size() {
            s = self.text.size()
        }

        if e > self.text.size() {
            e = self.text.size()
        }

        if e < s {
            e = s
        }

        var out = self.text.subslice(0, s)
        out += insert
        out += self.text.subslice(e, self.text.size() - e)
        self.set_text(out)
    }
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
            var range = msg->get(c, "range")
            var text  = msg->get_str(c, "text")
            if msg->is_object(range) {
                var s = msg->get(range, "start")
                var e = msg->get(range, "end")
                var so = self.docs[i].lines.offset(
                    self.docs[i].text,
                    msg->get_int(s, "line") as usize,
                    msg->get_int(s, "character") as usize,
                    self.utf8,
                )

                var eo = self.docs[i].lines.offset(
                    self.docs[i].text,
                    msg->get_int(e, "line") as usize,
                    msg->get_int(e, "character") as usize,
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
