/// --- The Kairo Project ----------------------- Support/TermRenderer.k --- ///
///
///   A simple terminal renderer for displaying markdown formatted text.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

class TermRenderer {
    priv var _color: bool;
    priv var _width: u32;
    priv var _keywords: vec::<string>;

    const RESET:     string = "\x1b[0m";
    const BOLD:      string = "\x1b[1m";
    const DIM:       string = "\x1b[2m";
    const UNDERLINE: string = "\x1b[4m";
    const RED:       string = "\x1b[31m";
    const YELLOW:    string = "\x1b[33m";
    const CYAN:      string = "\x1b[36m";
    const GREEN:     string = "\x1b[32m";
    const MAGENTA:   string = "\x1b[35m";
    const WHITE:     string = "\x1b[37m";
    const BG_GRAY:   string = "\x1b[48;5;236m";

    // Syntax highlighting palette (truecolor)
    const HL_KEYWORD:   string = "\x1b[38;2;250;121;112m"; // #fa7970
    const HL_TYPE:      string = "\x1b[38;2;250;163;86m";  // #faa356
    const HL_STRING:    string = "\x1b[38;2;124;227;139m"; // #7ce38b
    const HL_NUMBER:    string = "\x1b[38;2;162;210;251m"; // #a2d2fb
    const HL_FUNC:      string = "\x1b[38;2;206;165;251m"; // #cea5fb
    const HL_COMMENT:   string = "\x1b[38;2;137;146;155m"; // #89929b
    const HL_ATTRIBUTE: string = "\x1b[38;2;124;227;139m"; // #7ce38b

    struct CodeBlockInfo {
        var lang: string;
        var file: string;
    }

    fn TermRenderer(self, color: bool = true, width: u32 = 80) {
        self._color = color;
        self._width = width;
        self.init_keywords();
    }

    fn style(self, code: string) -> string {
        return (code) if self._color else "";
    }

    priv fn clip_to_width(self, s: string, max_cols: u32) -> string {
        var w: u32 = 0;
        var i: usize = 0;
        while i < s.length() {
            var b = static_cast::<u8>(s[i]);
            var step: usize = 1;
            var cols: u32 = 1;
            if      (b & 0x80) == 0x00 { step = 1; cols = 1; }
            else if (b & 0xE0) == 0xC0 { step = 2; cols = 1; }
            else if (b & 0xF0) == 0xE0 { step = 3; cols = 1; }
            else if (b & 0xF8) == 0xF0 { step = 4; cols = 2; }

            if w + cols > max_cols { break; }
            w += cols;
            i += step;
        }
        return s.raw_string().substr(0, i);
    }

    priv fn visible_width(self, s: string) -> u32 {
        var w: u32 = 0;
        var i: usize = 0;
        while i < s.length() {
            var b = static_cast::<u8>(s[i]);
            if b < 0x80 {
                w += 1; i += 1;
            } else if (b & 0xE0) == 0xC0 {
                w += 1; i += 2;
            } else if (b & 0xF0) == 0xE0 {
                w += 1; i += 3;   // most BMP glyphs are 1 column (→, │, ┌ etc.)
            } else if (b & 0xF8) == 0xF0 {
                w += 2; i += 4;   // assume emoji/CJK supplementary are 2 columns
            } else {
                w += 1; i += 1;   // garbage byte, don't loop forever
            }
        }
        return w;
    }

    fn render(self, text: string) -> string {
        var lines = self.split_lines(text);
        var out = string();
        var in_code_block = false;
        var code_block_info = CodeBlockInfo();

        var i: usize = 0;
        while i < lines.size() {
            var line = lines[i];
            var trimmed = self.trim(line);

            // -- fenced code block -------------------------------
            if self.starts_with(trimmed, "```") {
                if in_code_block {
                    // closing fence - draw bottom border
                    out += self.style(DIM);
                    out += "  └";
                    for _ in u32(0) .. self._width - 4 {
                        out += "-";
                    }
                    out += "┘";
                    out += self.style(RESET);
                    out += "\n";
                    in_code_block = false;
                    i += 1;
                    continue;
                }

                // opening fence
                var info = self.parse_fence(trimmed);
                in_code_block = true;
                code_block_info = info;

                // draw top border with lang/file
                out += self.style(DIM);
                out += "  ┌";

                var header = string();
                if info.lang.length() > 0 {
                    header += " " + info.lang + " ";
                }
                if info.file.length() > 0 {
                    if header.length() > 0 {
                        header += "· ";
                    } else {
                        header += " ";
                    }
                    header += info.file + " ";
                }

                if header.length() > 0 {
                    out += "-";
                    out += self.style(RESET + BOLD);
                    out += header;
                    out += self.style(RESET + DIM);
                    var remaining = self._width - 3 - static_cast::<u32>(header.length()) - 2;
                    for _ in u32(0) .. remaining {
                        out += "-";
                    }
                } else {
                    for _ in u32(0) .. self._width - 4 {
                        out += "-";
                    }
                }

                out += "┐";
                out += self.style(RESET);
                out += "\n";
                i += 1;
                continue;
            }

            if in_code_block {
                var inner = self._width - 5;                          // was: width - 4
                var clipped = self.clip_to_width(line, inner - 1);    // was: clip to inner

                out += self.style(DIM);
                out += "  │ ";
                out += self.style(RESET);
                out += self.highlight(clipped, code_block_info.lang);

                var used = self.visible_width(clipped);
                for _ in u32(0) .. inner - used {
                    out += " ";
                }
                out += self.style(DIM);
                out += "│";
                out += self.style(RESET);
                out += "\n";
                i += 1;
                continue;
            }

            if trimmed.length() == 0 {
                out += "\n";
                i += 1;
                continue;
            }

            var heading_level = self.heading_level(trimmed);
            if heading_level > 0 {
                var heading_text = self.trim(self.after_prefix(trimmed, heading_level));
                switch heading_level {
                    case 1 {
                        out += self.style(BOLD + UNDERLINE);
                        out += heading_text;
                        out += self.style(RESET);
                    }
                    case 2 {
                        out += self.style(BOLD);
                        out += heading_text;
                        out += self.style(RESET);
                    }
                    case 3 {
                        out += self.style(BOLD + DIM);
                        out += heading_text;
                        out += self.style(RESET);
                    }
                    default {
                        out += self.style(DIM);
                        out += heading_text;
                        out += self.style(RESET);
                    }
                }
                out += "\n";
                i += 1;
                continue;
            }

            if self.starts_with(trimmed, "- ") {
                var content = trimmed.raw_string().substr(2, trimmed.length() - 2);
                out += self.wrap_inline(content, 4, "  • ");
                i += 1;
                continue;
            }

            var num_prefix = self.numbered_prefix(trimmed);
            if num_prefix.length() > 0 {
                var content = trimmed.raw_string().substr(num_prefix.length(), trimmed.length() - num_prefix.length());
                var pad = string();
                for _ in usize(0) .. usize(num_prefix.length() + 2) {
                    pad += " ";
                }
                out += self.wrap_inline(content, static_cast::<u32>(pad.length()), "  " + num_prefix);
                i += 1;
                continue;
            }

            out += self.wrap_inline(trimmed, 2, "  ");
            i += 1;
        }

        return out;
    }

    fn wrap_inline(self, text: string, indent: u32, first_prefix: string) -> string {
        var out = string();
        var col: u32 = 0;
        var pad = string();
        for _ in u32(0) .. indent {
            pad += " ";
        }

        out += first_prefix;
        col = static_cast::<u32>(first_prefix.length());

        var i: usize = 0;
        while i < text.length() {
            if text[i] == '`' {
                var close = self.find_char(text, '`', i + 1);
                if close > i {
                    var code_text = text.raw_string().substr(i + 1, close - i - 1);
                    var styled = self.style(CYAN) + code_text + self.style(RESET);

                    if col + static_cast::<u32>(code_text.length()) + 2 > self._width && col > indent {
                        out += "\n" + pad;
                        col = indent;
                    }

                    out += styled;
                    col += static_cast::<u32>(code_text.length());
                    i = close + 1;
                    continue;
                }
            }

            if text[i] == ' ' {
                // lookahead for next word length
                var next_end = self.find_word_end(text, i + 1);
                var next_len = static_cast::<u32>(next_end - (i + 1));

                if col + 1 + next_len > self._width && col > indent {
                    out += "\n" + pad;
                    col = indent;
                } else {
                    out += " ";
                    col += 1;
                }
                i += 1;
                continue;
            }

            out += text[i];
            col += 1;
            i += 1;
        }

        out += "\n";
        return out;
    }

    ///===----------------------------------------------------------------===///
    /// # Syntax highlighting
    ///===----------------------------------------------------------------===///

    priv fn is_digit(self, c: char) -> bool { return c >= '0' && c <= '9'; }
    priv fn is_alpha(self, c: char) -> bool {
        return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
    }
    priv fn is_upper(self, c: char) -> bool { return c >= 'A' && c <= 'Z'; }
    priv fn is_ident_start(self, c: char) -> bool {
        return self.is_alpha(c) || c == '_' || c == '#';
    }
    priv fn is_ident_char(self, c: char) -> bool {
        return self.is_alpha(c) || self.is_digit(c) || c == '_' || c == '#';
    }

    priv fn is_keyword(self, word: string) -> bool {
        for kw in self._keywords {
            if word == kw { return true; }
        }
        return false;
    }

    priv fn highlight(self, line: string, lang: string) -> string {
        if !self._color { return line; }
        if lang == "text" || lang == "txt" || lang == "plain" { return line; }

        var out = string();
        var i: usize = 0;
        var n = line.length();

        while i < n {
            var c = line[i];

            // whitespace - emit raw, preserves indentation
            if c == ' ' || c == '\t' { out += c; i += 1; continue; }

            // line comment
            if c == '/' && i + 1 < n && line[i + 1] == '/' {
                var rest = line.raw_string().substr(i, n - i);
                out += self.style(HL_COMMENT) + rest + self.style(RESET);
                i = n;
                continue;
            }

            // block comment (same-line only)
            if c == '/' && i + 1 < n && line[i + 1] == '*' {
                var j = i + 2;
                while j + 1 < n && !(line[j] == '*' && line[j + 1] == '/') { j += 1; }
                var end = (j + 2) if (j + 1 < n) else n;
                var seg = line.raw_string().substr(i, end - i);
                out += self.style(HL_COMMENT) + seg + self.style(RESET);
                i = end;
                continue;
            }

            // raw string  r"..."
            if (c == 'r' || c == 'R') && i + 1 < n && line[i + 1] == '\x22' {
                var j = i + 2;
                while j < n && line[j] != '\x22' { j += 1; }
                if j < n { j += 1; }
                var seg = line.raw_string().substr(i, j - i);
                out += self.style(HL_STRING) + seg + self.style(RESET);
                i = j;
                continue;
            }

            // string literal
            if c == '\x22' {
                var j = i + 1;
                while j < n && line[j] != '\x22' {
                    if line[j] == '\\' && j + 1 < n { j += 1; }
                    j += 1;
                }
                if j < n { j += 1; }
                var seg = line.raw_string().substr(i, j - i);
                out += self.style(HL_STRING) + seg + self.style(RESET);
                i = j;
                continue;
            }

            // char literal
            if c == '\'' {
                var j = i + 1;
                while j < n && line[j] != '\'' {
                    if line[j] == '\\' && j + 1 < n { j += 1; }
                    j += 1;
                }
                if j < n { j += 1; }
                var seg = line.raw_string().substr(i, j - i);
                out += self.style(HL_STRING) + seg + self.style(RESET);
                i = j;
                continue;
            }

            // number  (handles 0xFF, 0b1010, 1.5, 1e3 prefix)
            if self.is_digit(c) {
                var j = i;
                while j < n && (self.is_ident_char(line[j]) || line[j] == '.') { j += 1; }
                var seg = line.raw_string().substr(i, j - i);
                out += self.style(HL_NUMBER) + seg + self.style(RESET);
                i = j;
                continue;
            }

            // attributes (e.g., @property)
            if c == '@' {
                var j = i + 1;
                while j < n && self.is_ident_char(line[j]) { j += 1; }
                var seg = line.raw_string().substr(i, j - i);
                out += self.style(HL_ATTRIBUTE) + seg + self.style(RESET);
                i = j;
                continue;
            }

            // identifier / keyword / type / call
            if self.is_ident_start(c) {
                var j = i;
                while j < n && self.is_ident_char(line[j]) { j += 1; }
                var word = line.raw_string().substr(i, j - i);

                // peek next non-space for '(' -> function call
                var k = j;
                while k < n && (line[k] == ' ' || line[k] == '\t') { k += 1; }
                var is_call = k < n && line[k] == '(';

                if (word == "true".raw_string()) || (word == "false".raw_string()) || (word == "null".raw_string()) || (word == "self".raw_string()) || (word == "Self".raw_string()) {
                    out += self.style(HL_NUMBER) + word + self.style(RESET);
                } else if self.is_keyword(word) {
                    out += self.style(HL_KEYWORD) + word + self.style(RESET);
                } else if is_call {
                    out += self.style(HL_FUNC) + word + self.style(RESET);
                } else if self.is_upper(c) {
                    out += self.style(HL_TYPE) + word + self.style(RESET);
                } else {
                    out += word;
                }
                i = j;
                continue;
            }


            // operators / punctuation - left neutral
            out += c;
            i += 1;
        }

        return out;
    }

    priv fn init_keywords(self) {
        var kws = vec::<string>();

        // control flow
        kws.push_back("return"); kws.push_back("break"); kws.push_back("continue");
        kws.push_back("panic"); kws.push_back("match"); kws.push_back("case");
        kws.push_back("default"); kws.push_back("catch"); kws.push_back("try");
        kws.push_back("finally"); kws.push_back("if"); kws.push_back("else");
        kws.push_back("while"); kws.push_back("for"); kws.push_back("assert");
        kws.push_back("loop");

        // declarations
        kws.push_back("var"); kws.push_back("const"); kws.push_back("fn");
        kws.push_back("op"); kws.push_back("class"); kws.push_back("union");
        kws.push_back("enum"); kws.push_back("type"); kws.push_back("struct");
        kws.push_back("interface"); kws.push_back("extend"); kws.push_back("module");
        kws.push_back("test"); kws.push_back("macro"); kws.push_back("import");
        kws.push_back("override"); kws.push_back("final"); kws.push_back("ffi");
        kws.push_back("impl"); kws.push_back("derives"); kws.push_back("where");
        kws.push_back("requires");

        // access / qualifiers
        kws.push_back("pub"); kws.push_back("priv"); kws.push_back("prot");
        kws.push_back("eval"); kws.push_back("unsafe"); kws.push_back("static");
        kws.push_back("async"); kws.push_back("inline"); kws.push_back("atomic");
        kws.push_back("volatile"); kws.push_back("virtual"); kws.push_back("self");

        // operators-as-words / unary
        kws.push_back("in"); kws.push_back("as"); kws.push_back("and");
        kws.push_back("or"); kws.push_back("not"); kws.push_back("xor");
        kws.push_back("and_eq"); kws.push_back("or_eq"); kws.push_back("xor_eq");
        kws.push_back("bitand"); kws.push_back("bitor"); kws.push_back("compl");
        kws.push_back("not_eq"); kws.push_back("await"); kws.push_back("thread");
        kws.push_back("spawn"); kws.push_back("delete"); kws.push_back("yield");
        kws.push_back("sizeof"); kws.push_back("alignof"); kws.push_back("typeof");

        // primitive types
        kws.push_back("void"); kws.push_back("bool"); kws.push_back("string");
        kws.push_back("char"); kws.push_back("usize"); kws.push_back("isize");
        kws.push_back("f16"); kws.push_back("f32"); kws.push_back("f64");
        kws.push_back("f80"); kws.push_back("f128"); kws.push_back("f256");
        kws.push_back("u8"); kws.push_back("u16"); kws.push_back("u32");
        kws.push_back("u64"); kws.push_back("u128"); kws.push_back("u256");
        kws.push_back("u512"); kws.push_back("i8"); kws.push_back("i16");
        kws.push_back("i32"); kws.push_back("i64"); kws.push_back("i128");
        kws.push_back("i256"); kws.push_back("i512");

        self._keywords = kws;
    }

    ///===----------------------------------------------------------------===///
    /// # Helpers
    ///===----------------------------------------------------------------===///

    fn split_lines(self, text: string) -> vec::<string> {
        var lines = vec::<string>();
        var start: usize = 0;
        for i in usize(0) .. usize(text.length()) {
            if text[i] == '\n' {
                lines.push_back(text.raw_string().substr(start, i - start));
                start = i + 1;
            }
        }
        if start <= text.length() {
            lines.push_back(text.raw_string().substr(start, text.length() - start));
        }
        return lines;
    }

    fn highlight_snippet(self, code: string) -> string {
        return self.highlight(code, "kairo");
    }

    fn highlight_snippet(self, code: string, lang: string) -> string {
        return self.highlight(code, lang);
    }

    fn trim(self, s: string) -> string {
        var start: usize = 0;
        var end: usize = s.length();
        while start < end && (s[start] == ' ' || s[start] == '\t') { start += 1; }
        while end > start && (s[end - 1] == ' ' || s[end - 1] == '\t') { end -= 1; }
        return s.raw_string().substr(start, end - start);
    }

    fn starts_with(self, s: string, prefix: string) -> bool {
        if s.length() < prefix.length() { return false; }
        for i in usize(0) .. usize(prefix.length()) {
            if s[i] != prefix[i] { return false; }
        }
        return true;
    }

    fn heading_level(self, line: string) -> u32 {
        var level: u32 = 0;
        while level < 4 && static_cast::<usize>(level) < line.length() && line[level] == '#' {
            level += 1;
        }
        if level > 0 && static_cast::<usize>(level) < line.length() && line[level] == ' ' {
            return level;
        }
        return 0;
    }

    fn after_prefix(self, s: string, skip: u32) -> string {
        var start = static_cast::<usize>(skip);
        if start >= s.length() { return ""; }
        return s.raw_string().substr(start, s.length() - start);
    }

    fn numbered_prefix(self, line: string) -> string {
        // matches: "1. ", "12. ", "123. "
        var i: usize = 0;
        while i < line.length() && line[i] >= '0' && line[i] <= '9' {
            i += 1;
        }
        if i > 0 && i + 1 < line.length() && line[i] == '.' && line[i + 1] == ' ' {
            return line.raw_string().substr(0, i + 2);
        }
        return "";
    }

    fn find_char(self, s: string, ch: char, from: usize) -> usize {
        for i in usize(from) .. usize(s.length()) {
            if s[i] == ch { return i; }
        }
        return from; // not found, return start so caller knows
    }

    fn find_word_end(self, s: string, from: usize) -> usize {
        var i = from;
        while i < s.length() && s[i] != ' ' && s[i] != '`' && s[i] != '\n' {
            i += 1;
        }
        return i;
    }

    priv fn parse_fence(self, line: string) -> CodeBlockInfo {
        var info = CodeBlockInfo();
        var rest = self.trim(line.raw_string().substr(3, line.length() - 3));

        // split on spaces: ```kairo file=a.k
        var i: usize = 0;

        // language
        while i < rest.length() && rest[i] != ' ' {
            i += 1;
        }
        info.lang = rest.raw_string().substr(0, i);

        // remaining key=value pairs
        while i < rest.length() {
            while i < rest.length() && rest[i] == ' ' { i += 1; }
            var kv_start = i;
            while i < rest.length() && rest[i] != ' ' { i += 1; }
            var kv = string(rest.raw_string().substr(kv_start, i - kv_start));

            var eq = self.find_char(kv, '=', 0);
            if eq > 0 && eq < kv.length() - 1 {
                var key = string(kv.raw_string().substr(0, eq));
                var val = string(kv.raw_string().substr(eq + 1, kv.length() - eq - 1));
                if key == "file" {
                    info.file = val;
                }
            }
        }

        return info;
    }
}

// fn Test() -> i32 {
//     var r = TermRenderer(true, 60);

//     var input = string(
//         "# Return Type Mismatch\n"
//         "\n"
//         "The function's declared return type does not match\n"
//         "the expression in the `return` statement.\n"
//         "\n"
//         "## Common causes\n"
//         "\n"
//         "1. The function signature says `void` but the body returns a value\n"
//         "2. The return expression type doesn't match\n"
//         "3. An implicit conversion is not available\n"
//         "\n"
//         "## Example\n"
//         "\n"
//         "```kairo\n"
//         "fn foo() -> void {\n"
//         "    return 42;  // error\n"
//         "}\n"
//         "```\n"
//         "\n"
//         "## Fixes\n"
//         "\n"
//         "- Change the return type to match the expression\n"
//         "- Remove the expression from the `return` statement\n"
//         "- Add an explicit cast\n"
//     );

//     var output = r.render(input);
//     std::print(output);

//     // --- individual checks ---
//     var errors: i32 = 0;

//     // heading detection
//     if r.heading_level("# Foo") != 1   { std::print("FAIL: h1\n"); errors += 1; }
//     if r.heading_level("## Foo") != 2  { std::print("FAIL: h2\n"); errors += 1; }
//     if r.heading_level("### Foo") != 3 { std::print("FAIL: h3\n"); errors += 1; }
//     if r.heading_level("no heading") != 0 { std::print("FAIL: no heading\n"); errors += 1; }
//     if r.heading_level("#nospace") != 0   { std::print("FAIL: no space after #\n"); errors += 1; }

//     // trim
//     if r.trim("  hello  ") != "hello"  { std::print("FAIL: trim\n"); errors += 1; }
//     if r.trim("") != ""               { std::print("FAIL: trim empty\n"); errors += 1; }

//     // starts_with
//     if !r.starts_with("- foo", "- ")   { std::print("FAIL: starts_with bullet\n"); errors += 1; }
//     if r.starts_with("foo", "- ")      { std::print("FAIL: starts_with negative\n"); errors += 1; }

//     // numbered prefix
//     if r.numbered_prefix("1. foo") != "1. "    { std::print("FAIL: num prefix 1\n"); errors += 1; }
//     if r.numbered_prefix("12. foo") != "12. "  { std::print("FAIL: num prefix 12\n"); errors += 1; }
//     if r.numbered_prefix("no number") != ""    { std::print("FAIL: num prefix none\n"); errors += 1; }

//     // code block toggle
//     var code_output = r.render(code_input);
//         std::print("FAIL: code block content missing\n");
//         errors += 1;
//     }

//     // inline code
//     var inline_input = string("use `foo` here\n");
//     var inline_output = r.render(inline_input);
//     if inline_output.raw_string().find("foo") == string::npos {
//         std::print("FAIL: inline code content missing\n");
//         errors += 1;
//     }

//     // word wrap -- check visible width, stripping ANSI
//     var long_line = string("this is a very long line that should definitely wrap when rendered at sixty columns wide\n");
//     var wrapped = r.render(long_line);
//     var wrap_lines = r.split_lines(wrapped);
//     for line in wrap_lines {
//         if line.length() > 62 {  // small margin for ansi codes
//             std::print(f"FAIL: line too long: {line.length()} chars\n");
//             errors += 1;
//         }
//     }

//     if errors == 0 {
//         std::print("\nAll tests passed.\n");
//     } else {
//         std::print(f"\n{errors} test(s) failed.\n");
//     }

//     return errors;
// }
