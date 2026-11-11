/// --- The Kairo Project ------------------------------ Analyzer/Json.k --- ///
///
///   JSON for the language server: a flat parsed document and a text writer.
///
///   Two halves, deliberately not one tree type:
///
///     JsonDoc     what arrives (a request, kairo_compile.json, an index the
///                 worker wrote). Parsed once into ONE node array; a value is
///                 an index into it. Nothing is copied to read a field.
///     JsonWriter  what leaves. Appends text; there is no tree to build first.
///
///   WHY NOT A RECURSIVE VALUE CLASS: `class Json { var items: [Json] }` does
///   not compile today (P796: the vector's copy constraint is checked while
///   the element type is still incomplete, so the class loses its copy
///   constructor). The flat form is also what an LSP wants: a 2 MB index is
///   one allocation per string, not one per value.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

pub enum JsonKind derives u8 {
    Null,
    Bool,
    Number,
    String,
    Array,
    Object,
}

/// "No node": what every lookup returns for a missing key or a wrong kind.
/// Every accessor accepts it and answers with the empty value, so a chain of
/// lookups (`d.get(d.get(root, "a"), "b")`) needs no check until the end.
pub fn JSON_NONE() -> u32 {
    return u32::MAX
}

/// One value. Children of an array or object are a linked list through
/// `next`; an object member carries its key in `key`.
pub struct JsonNode {
    var kind:  JsonKind = JsonKind::Null
    var flag:  bool     = false     ///< Bool: the value. Number: true when integral.
    var num:   f64      = 0.0
    var ival:  i64      = 0
    var text:  string   = ""        ///< String: the decoded value.
    var key:   string   = ""        ///< set when this node is an object member
    var first: u32      = u32::MAX  ///< first child (Array, Object)
    var next:  u32      = u32::MAX  ///< next sibling
    var count: u32      = 0         ///< number of children
}

pub class JsonDoc {
    pub var nodes: [JsonNode]
    pub var root:  u32    = u32::MAX
    pub var error: string = ""       ///< empty when the parse succeeded

    priv var src_: string = ""
    priv var pos_: usize  = 0

    fn JsonDoc(self) = default

    /// Parses \p text. On failure `error` says why and `root` is JSON_NONE.
    fn parse(self, const text: string) -> bool {
        self.nodes.clear()
        self.error = ""
        self.src_  = text
        self.pos_  = 0
        self.root  = self.value_(0)
        if self.error.empty() {
            self.ws_()
            if self.pos_ < self.src_.size() {
                self.fail_("trailing characters after the value")
            }
        }

        if !self.error.empty() {
            self.root = JSON_NONE()
            return false
        }

        return true
    }

    // --- reading ---------------------------------------------------------

    fn kind(const self, n: u32) -> JsonKind {
        if n == JSON_NONE() {
            return JsonKind::Null
        }

        return self.nodes[n as usize].kind
    }

    fn is_null(const self, n: u32) -> bool {
        return self.kind(n) == JsonKind::Null
    }

    fn is_string(const self, n: u32) -> bool {
        return self.kind(n) == JsonKind::String
    }

    fn is_number(const self, n: u32) -> bool {
        return self.kind(n) == JsonKind::Number
    }

    fn is_object(const self, n: u32) -> bool {
        return self.kind(n) == JsonKind::Object
    }

    fn is_array(const self, n: u32) -> bool {
        return self.kind(n) == JsonKind::Array
    }

    /// Member \p key of object \p n, or JSON_NONE.
    fn get(const self, n: u32, const key: string) -> u32 {
        if self.kind(n) != JsonKind::Object {
            return JSON_NONE()
        }

        var c = self.nodes[n as usize].first
        while c != JSON_NONE() {
            if self.nodes[c as usize].key == key {
                return c
            }

            c = self.nodes[c as usize].next
        }

        return JSON_NONE()
    }

    /// First child of an array or object; walk on with next().
    fn first(const self, n: u32) -> u32 {
        if n == JSON_NONE() {
            return JSON_NONE()
        }

        return self.nodes[n as usize].first
    }

    fn next(const self, n: u32) -> u32 {
        if n == JSON_NONE() {
            return JSON_NONE()
        }

        return self.nodes[n as usize].next
    }

    fn count(const self, n: u32) -> usize {
        if n == JSON_NONE() {
            return 0
        }

        return self.nodes[n as usize].count as usize
    }

    /// The key of an object member (empty for anything else).
    fn key(const self, n: u32) -> string {
        if n == JSON_NONE() {
            return ""
        }

        return self.nodes[n as usize].key
    }

    fn str(const self, n: u32) -> string {
        if self.kind(n) != JsonKind::String {
            return ""
        }

        return self.nodes[n as usize].text
    }

    fn as_int(const self, n: u32) -> i64 {
        if self.kind(n) != JsonKind::Number {
            return 0
        }

        return self.nodes[n as usize].ival
    }

    fn num(const self, n: u32) -> f64 {
        if self.kind(n) != JsonKind::Number {
            return 0.0
        }

        return self.nodes[n as usize].num
    }

    fn boolean(const self, n: u32) -> bool {
        if self.kind(n) != JsonKind::Bool {
            return false
        }

        return self.nodes[n as usize].flag
    }

    fn get_str(const self, n: u32, const key: string) -> string {
        return self.str(self.get(n, key))
    }

    fn get_int(const self, n: u32, const key: string) -> i64 {
        return self.as_int(self.get(n, key))
    }

    fn get_bool(const self, n: u32, const key: string) -> bool {
        return self.boolean(self.get(n, key))
    }

    /// Re-serializes the value at \p n. A request id is echoed with this: it
    /// may be a number or a string and has to go back as the kind it came.
    fn dump(const self, n: u32) -> string {
        var w = JsonWriter()
        self.dump_(n, &w)
        return w.out
    }

    priv fn dump_(const self, n: u32, w: *JsonWriter) {
        var k = self.kind(n)
        if k == JsonKind::Null {
            w->nul()
            return
        }

        if k == JsonKind::Bool {
            w->boolean(self.nodes[n as usize].flag)
            return
        }

        if k == JsonKind::Number {
            if self.nodes[n as usize].flag {
                w->integer(self.nodes[n as usize].ival)
            } else {
                w->num(self.nodes[n as usize].num)
            }

            return
        }

        if k == JsonKind::String {
            w->str(self.nodes[n as usize].text)
            return
        }

        if k == JsonKind::Array {
            w->begin_array()
            var c = self.nodes[n as usize].first
            while c != JSON_NONE() {
                self.dump_(c, w)
                c = self.nodes[c as usize].next
            }

            w->end_array()
            return
        }

        w->begin_object()
        var c = self.nodes[n as usize].first
        while c != JSON_NONE() {
            w->key(self.nodes[c as usize].key)
            self.dump_(c, w)
            c = self.nodes[c as usize].next
        }

        w->end_object()
    }

    // --- parsing ---------------------------------------------------------

    priv fn fail_(self, const why: string) {
        // The FIRST failure is the cause; everything after it is the parser
        // unwinding through input it no longer understands.
        if self.error.empty() {
            self.error = f"JSON: {why} at byte {self.pos_}"
        }
    }

    priv fn ws_(self) {
        while self.pos_ < self.src_.size() {
            var c = self.src_[self.pos_]
            if (c != 32) && (c != 9) && (c != 10) && (c != 13) {
                return
            }

            self.pos_ += 1
        }
    }

    priv fn new_(self, kind: JsonKind) -> u32 {
        var n = JsonNode{}
        n.kind = kind
        self.nodes.push_back(n)
        return (self.nodes.size() - 1) as u32
    }

    priv fn literal_(self, const word: string) -> bool {
        if (self.pos_ + word.size()) > self.src_.size() {
            return false
        }

        for var i: usize = 0; i < word.size(); ++i {
            if self.src_[self.pos_ + i] != word[i] {
                return false
            }
        }

        self.pos_ += word.size()
        return true
    }

    priv fn value_(self, depth: u32) -> u32 {
        // A request is client input: bound the recursion so a hostile or
        // broken `[[[[...` cannot run the server out of stack.
        if depth > 256 {
            self.fail_("nesting too deep")
            return JSON_NONE()
        }

        self.ws_()
        if self.pos_ >= self.src_.size() {
            self.fail_("unexpected end of input")
            return JSON_NONE()
        }

        var c = self.src_[self.pos_]
        if c == 123 {
            return self.object_(depth)
        }

        if c == 91 {
            return self.array_(depth)
        }

        if c == 34 {
            var n = self.new_(JsonKind::String)
            var s = self.string_()
            self.nodes[n as usize].text = s
            return n
        }

        if c == 116 {
            if !self.literal_("true") {
                self.fail_("invalid literal")
                return JSON_NONE()
            }

            var n = self.new_(JsonKind::Bool)
            self.nodes[n as usize].flag = true
            return n
        }

        if c == 102 {
            if !self.literal_("false") {
                self.fail_("invalid literal")
                return JSON_NONE()
            }

            return self.new_(JsonKind::Bool)
        }

        if c == 110 {
            if !self.literal_("null") {
                self.fail_("invalid literal")
                return JSON_NONE()
            }

            return self.new_(JsonKind::Null)
        }

        if (c == 45) || ((c >= 48) && (c <= 57)) {
            return self.number_()
        }

        self.fail_("unexpected character")
        return JSON_NONE()
    }

    priv fn object_(self, depth: u32) -> u32 {
        var obj = self.new_(JsonKind::Object)
        self.pos_ += 1
        var last = JSON_NONE()

        self.ws_()
        if (self.pos_ < self.src_.size()) && (self.src_[self.pos_] == 125) {
            self.pos_ += 1
            return obj
        }

        while self.error.empty() {
            self.ws_()
            if (self.pos_ >= self.src_.size()) || (self.src_[self.pos_] != 34) {
                self.fail_("expected a member name")
                break
            }

            var k = self.string_()
            self.ws_()
            if (self.pos_ >= self.src_.size()) || (self.src_[self.pos_] != 58) {
                self.fail_("expected ':'")
                break
            }

            self.pos_ += 1
            var v = self.value_(depth + 1)
            if v == JSON_NONE() {
                break
            }

            self.nodes[v as usize].key = k
            if last == JSON_NONE() {
                self.nodes[obj as usize].first = v
            } else {
                self.nodes[last as usize].next = v
            }

            last = v
            self.nodes[obj as usize].count += 1

            self.ws_()
            if self.pos_ >= self.src_.size() {
                self.fail_("unterminated object")
                break
            }

            var c = self.src_[self.pos_]
            self.pos_ += 1
            if c == 125 {
                break
            }

            if c != 44 {
                self.fail_("expected ',' or '}'")
                break
            }
        }

        return obj
    }

    priv fn array_(self, depth: u32) -> u32 {
        var arr = self.new_(JsonKind::Array)
        self.pos_ += 1
        var last = JSON_NONE()

        self.ws_()
        if (self.pos_ < self.src_.size()) && (self.src_[self.pos_] == 93) {
            self.pos_ += 1
            return arr
        }

        while self.error.empty() {
            var v = self.value_(depth + 1)
            if v == JSON_NONE() {
                break
            }

            if last == JSON_NONE() {
                self.nodes[arr as usize].first = v
            } else {
                self.nodes[last as usize].next = v
            }

            last = v
            self.nodes[arr as usize].count += 1

            self.ws_()
            if self.pos_ >= self.src_.size() {
                self.fail_("unterminated array")
                break
            }

            var c = self.src_[self.pos_]
            self.pos_ += 1
            if c == 93 {
                break
            }

            if c != 44 {
                self.fail_("expected ',' or ']'")
                break
            }
        }

        return arr
    }

    priv fn hex4_(self) -> u32 {
        var v: u32 = 0
        for var i: usize = 0; i < 4; ++i {
            if self.pos_ >= self.src_.size() {
                self.fail_("truncated \\u escape")
                return 0
            }

            var c = self.src_[self.pos_] as u32
            self.pos_ += 1
            var d: u32 = 0
            if (c >= 48) && (c <= 57) {
                d = c - 48
            } else if (c >= 97) && (c <= 102) {
                d = c - 87
            } else if (c >= 65) && (c <= 70) {
                d = c - 55
            } else {
                self.fail_("invalid \\u escape")
                return 0
            }

            v = (v << 4) | d
        }

        return v
    }

    /// Reads a string token; `pos_` is at the opening quote.
    priv fn string_(self) -> string {
        var out = string()
        self.pos_ += 1
        while self.pos_ < self.src_.size() {
            var c = self.src_[self.pos_]
            self.pos_ += 1
            if c == 34 {
                return out
            }

            if c != 92 {
                out.push_back(c)
                continue
            }

            if self.pos_ >= self.src_.size() {
                break
            }

            var e = self.src_[self.pos_]
            self.pos_ += 1
            if e == 110 {
                out.push_back(10)
            } else if e == 116 {
                out.push_back(9)
            } else if e == 114 {
                out.push_back(13)
            } else if e == 98 {
                out.push_back(8)
            } else if e == 102 {
                out.push_back(12)
            } else if e == 117 {
                var cp = self.hex4_()
                // A high surrogate is half a character: its low half follows
                // as a second \u escape, and the pair is ONE code point.
                if (cp >= 0xD800) && (cp <= 0xDBFF) && ((self.pos_ + 1) < self.src_.size())
                    && (self.src_[self.pos_] == 92) && (self.src_[self.pos_ + 1] == 117) {
                    self.pos_ += 2
                    var lo = self.hex4_()
                    cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00)
                }

                utf8_append(&out, cp)
            } else {
                // `\"`, `\\`, `\/`: the escaped character is itself.
                out.push_back(e)
            }
        }

        self.fail_("unterminated string")
        return out
    }

    priv fn number_(self) -> u32 {
        var n     = self.new_(JsonKind::Number)
        var neg   = false
        var whole = true
        var mant: f64 = 0.0
        var ival: i64 = 0

        if self.src_[self.pos_] == 45 {
            neg = true
            self.pos_ += 1
        }

        while (self.pos_ < self.src_.size()) && (self.src_[self.pos_] >= 48) && (self.src_[self.pos_] <= 57) {
            var d = (self.src_[self.pos_] - 48) as i64
            ival = (ival * 10) + d
            mant = (mant * 10.0) + (d as f64)
            self.pos_ += 1
        }

        if (self.pos_ < self.src_.size()) && (self.src_[self.pos_] == 46) {
            whole = false
            self.pos_ += 1
            var scale: f64 = 0.1
            while (self.pos_ < self.src_.size()) && (self.src_[self.pos_] >= 48) && (self.src_[self.pos_] <= 57) {
                mant  = mant + (((self.src_[self.pos_] - 48) as f64) * scale)
                scale = scale * 0.1
                self.pos_ += 1
            }
        }

        if (self.pos_ < self.src_.size()) && ((self.src_[self.pos_] == 101) || (self.src_[self.pos_] == 69)) {
            whole = false
            self.pos_ += 1
            var eneg = false
            if (self.pos_ < self.src_.size()) && ((self.src_[self.pos_] == 45) || (self.src_[self.pos_] == 43)) {
                eneg = self.src_[self.pos_] == 45
                self.pos_ += 1
            }

            var ex: i32 = 0
            while (self.pos_ < self.src_.size()) && (self.src_[self.pos_] >= 48) && (self.src_[self.pos_] <= 57) {
                ex = (ex * 10) + ((self.src_[self.pos_] - 48) as i32)
                self.pos_ += 1
            }

            for var i: i32 = 0; i < ex; ++i {
                if eneg {
                    mant = mant / 10.0
                } else {
                    mant = mant * 10.0
                }
            }
        }

        if neg {
            mant = 0.0 - mant
            ival = 0 - ival
        }

        if !whole {
            ival = mant as i64
        }

        self.nodes[n as usize].flag = whole
        self.nodes[n as usize].num  = mant
        self.nodes[n as usize].ival = ival
        return n
    }
}

/// Appends code point \p cp to \p out as UTF-8.
pub fn utf8_append(out: *string, cp: u32) {
    if cp < 0x80 {
        out->push_back(cp as u8)
    } else if cp < 0x800 {
        out->push_back((0xC0 | (cp >> 6)) as u8)
        out->push_back((0x80 | (cp & 0x3F)) as u8)
    } else if cp < 0x10000 {
        out->push_back((0xE0 | (cp >> 12)) as u8)
        out->push_back((0x80 | ((cp >> 6) & 0x3F)) as u8)
        out->push_back((0x80 | (cp & 0x3F)) as u8)
    } else {
        out->push_back((0xF0 | (cp >> 18)) as u8)
        out->push_back((0x80 | ((cp >> 12) & 0x3F)) as u8)
        out->push_back((0x80 | ((cp >> 6) & 0x3F)) as u8)
        out->push_back((0x80 | (cp & 0x3F)) as u8)
    }
}

/// \class JsonWriter
/// \brief appends JSON text; commas are placed by the writer.
///
/// \details Usage is strictly nested: begin_object, then key + one value per
///          member, end_object. `raw()` splices text that is already JSON (a
///          request id being echoed, a fragment the worker pre-rendered).
pub class JsonWriter {
    pub var out: string = ""

    /// One entry per open container: true once it holds a value, which is
    /// what decides whether the next value needs a comma in front.
    priv var has_: [bool]

    /// A key was just written, so the value that follows takes no comma.
    priv var after_key_: bool = false

    fn JsonWriter(self) = default

    priv fn sep_(self) {
        if self.after_key_ {
            self.after_key_ = false
            return
        }

        if self.has_.empty() {
            return
        }

        var top = self.has_.size() - 1
        if self.has_[top] {
            self.out.push_back(44)
        }

        self.has_[top] = true
    }

    fn begin_object(self) {
        self.sep_()
        self.out.push_back(123)
        self.has_.push_back(false)
    }

    fn end_object(self) {
        self.out.push_back(125)
        self.has_.pop_back()
    }

    fn begin_array(self) {
        self.sep_()
        self.out.push_back(91)
        self.has_.push_back(false)
    }

    fn end_array(self) {
        self.out.push_back(93)
        self.has_.pop_back()
    }

    fn key(self, const k: string) {
        self.sep_()
        self.quote_(k)
        self.out.push_back(58)
        self.after_key_ = true
    }

    fn str(self, const s: string) {
        self.sep_()
        self.quote_(s)
    }

    fn integer(self, v: i64) {
        self.sep_()
        self.out += f"{v}"
    }

    fn uint(self, v: usize) {
        self.sep_()
        self.out += f"{v}"
    }

    fn num(self, v: f64) {
        self.sep_()
        self.out += f"{v}"
    }

    fn boolean(self, v: bool) {
        self.sep_()
        if v {
            self.out += "true"
        } else {
            self.out += "false"
        }
    }

    fn nul(self) {
        self.sep_()
        self.out += "null"
    }

    /// Splices \p json, which must already be one complete JSON value.
    fn raw(self, const json: string) {
        self.sep_()
        self.out += json
    }

    // key + value in one call: the shape nearly every member has.

    fn field(self, const k: string, const v: string) {
        self.key(k)
        self.str(v)
    }

    fn field_int(self, const k: string, v: i64) {
        self.key(k)
        self.integer(v)
    }

    fn field_uint(self, const k: string, v: usize) {
        self.key(k)
        self.uint(v)
    }

    fn field_bool(self, const k: string, v: bool) {
        self.key(k)
        self.boolean(v)
    }

    fn field_raw(self, const k: string, const json: string) {
        self.key(k)
        self.raw(json)
    }

    priv fn quote_(self, const s: string) {
        var hex = "0123456789abcdef"
        self.out.push_back(34)
        for var i: usize = 0; i < s.size(); ++i {
            var c = s[i]
            if c == 34 {
                self.out += "\\\""
            } else if c == 92 {
                self.out += "\\\\"
            } else if c == 10 {
                self.out += "\\n"
            } else if c == 13 {
                self.out += "\\r"
            } else if c == 9 {
                self.out += "\\t"
            } else if c < 32 {
                // Every other control character must be escaped; bytes >= 0x80
                // are UTF-8 and pass through untouched.
                self.out += "\\u00"
                self.out.push_back(hex[(c >> 4) as usize])
                self.out.push_back(hex[(c & 15) as usize])
            } else {
                self.out.push_back(c)
            }
        }

        self.out.push_back(34)
    }
}
