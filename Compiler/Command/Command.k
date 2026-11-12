/// --- The Kairo Project ---------------------------- Command/Command.k --- ///
///
///   The command-line parser: flag definitions, matching and suggestions,
///   and the ParsedArgs it produces.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

/// Command
/// =======
///
/// Usage (matches rest of compiler)
/// ---------------------------------
///   var diag    = DiagEngine();
///   var cmd     = Command(&diag);        // stack-allocated, like SourceManager
///   register_test_flags(&cmd);          // the ONE place to add/remove flags
///   var args    = cmd.parse(argv_vec);   // argv_vec: vec::<string> from main
///   var &args   = args;                  // pass &args to any subsystem
///
/// Adding a flag - the only file you need to touch
/// ------------------------------------------------
///   cmd.define(FlagDef::bool_  ("verbose", "v", "verbose", "verbose output",       false));
///   cmd.define(FlagDef::str_   ("output",  "o", "output",  "output file path")); // required
///   cmd.define(FlagDef::i32_b  ("opt",     "O", "",        "opt level", 0, 0, 3));
///   cmd.define(FlagDef::list_  ("include", "I", "include", "add include dir"));
///   cmd.define(FlagDef::files_ ("files",   "input source files"));
///
/// Supported flag styles
/// ---------------------
///   -f              short bool flag
///   -abc            short cluster -> -a -b -c
///   -cfoo           short non-bool with joined value
///   -Wall           long single-dash (IS_LONG_FLAG prefix char)
///   -O2             long single-dash with joined value -> "O" + "2"
///   -fsanitize=addr long single-dash with = value
///   --flag          double-dash boolean
///   --flag=value    inline value
///   --flag value    space-separated value (AwaitValue global state)
///   /flag  /Wall    Windows-style
///   --              end-of-options; everything after is a file
///   -               bare stdin sentinel; becomes a file path
///
/// Input
/// -----
///   Takes vec::<string> (libcxx::vector<string>) - the shell already
///   split the command line; the driver builds this from argc/argv once.

ffi "c++" import "Native/Types.hh"
ffi "c++" import "array"
ffi "c++" import "vector"
ffi "c++" import "cstring"
ffi "c++" import "cstdlib"
ffi "c++" import "limits"

import Command::FlagUtils::{
    FlagDef,
    FlagKind,
}
import Command::ParsedArgs::ParsedArgs
import Diagnostic::Code::DiagCode
import Diagnostic::Engine::DiagEngine
import Diagnostic::Registry::DiagID
import std::c_char
import std::io

pub class Command {
    // compile-time long-single-dash prefix table
    //
    // When argv[i] starts with "-X" and IS_LONG_FLAG[X] is true, the parser
    // collects the entire run of characters as one flag name, then splits for
    // a joined value.  This is how -Wall, -O2, -fsanitize, -march=... work.

    static fn _build_long_flag_table() -> cxx::std::array<bool, 256> {
        var t: cxx::std::array<bool, 256> = cxx::std::array<bool, 256>()

        t['W' as u8] = true // -Wall  -Wextra  -Wno-...         (warnings)
        t['O' as u8] = true // -O0  -O1  -O2  -O3  -Os  -Oz   (optimization)
        t['f' as u8] = true // -funsafe  -fno-...  -fPIC  -fPIE  (feature toggles + codegen)
        t['m' as u8] = true // -march  -mcpu  -mabi  -mtune    (machine/target)
        t['X' as u8] = true // -Xcxx  -Xlinker  -Xassembler    (passthrough)
        t['s' as u8] = true // -std=...                           (language standard, single-dash form)
        t['D' as u8] = true // -DFOO  -DFOO=BAR                (macro defines)
        t['A' as u8] = true // -Afoo                            (allow/silence diagnostic)
        t['E' as u8] = true // -Efoo                            (promote diagnostic to error)
        t['F' as u8] = true // -Ffoo                            (forbid diagnostic)
        t['g' as u8] = true // -g  -g0  -gdwarf-4              (debug info, single-dash long form)
        t['I' as u8] = true // -I./include  -I/usr/include      (include paths, inline value)
        t['L' as u8] = true // -Lpath/to/lib                   (library search paths, inline value)
        t['l' as u8] = true // -lssl  -lcrypto  -l static:foo  (link libraries, inline value)
        t['Z' as u8] = true // -Zunstable-flag                  (unstable internal flags)

        return t
    }

    var IS_LONG_FLAG: cxx::std::array<bool, 256> = _build_long_flag_table()


    enum GlobalState derives u8 {
        Normal,     ///< nothing pending
        AwaitValue, ///< last flag needs the next element as its value
        PathsOnly,  ///< bare `--` seen; everything remaining is a file
    }


    priv var _args:  cxx::std::vector<string>  ///< copy of argv for parsing (owned by Command)
    priv var _table: cxx::std::vector<FlagDef>
    priv var _diag:  unsafe *DiagEngine
    /// The flag whose current value tags every positional input (the -x
    /// language). "" = no tagging. Positional order is lost once files are a
    /// flat list, and -x applies to the inputs AFTER it, so the tag is taken
    /// at the moment each file is seen; see _push_file.
    priv var _tag_key: string
    /// Set when the tag flag is applied, cleared by the next input: still set
    /// at the end means a trailing -x that tagged nothing.
    priv var _tag_dirty: bool = false


    fn Command(self, argc: i32, argv: unsafe *(unsafe *c_char), diag: unsafe *DiagEngine) {
        self._diag = diag
        self._table.reserve(64) // typical CLI has ~20 flags, reserve a bit more
        self._args.reserve(argc as usize)
        for var i: i32 = 0; i < argc; ++i {
            self._args.emplace_back(
                string(
                    unsafe ((argv[i] as unsafe *const u8) as *const u8),
                    cxx::std::strlen(argv[i]),
                ),
            )
        }
    }

    // ONLY FOR TESTING: production code uses Command(argc, argv, diag).
    fn Command(self, diag: unsafe *DiagEngine) {
        self._diag = diag
        self._table.reserve(64)
    }


    fn define(self, const def: FlagDef) -> unsafe *Self {
        self._table.push_back(def)
        return unsafe &self
    }


    fn <eval T: FlagKind> define(self, key: string, help: string) -> unsafe *Self {
        assert static (T == FlagKind::PathList) || T == FlagKind::Feature,
            r"only PathList and Feature can omit short/long/default"
        eval if T == FlagKind::PathList {
            return self.define(FlagDef::files_(key, help))
        } else if T == FlagKind::Feature {
            return self.define(FlagDef::feature_(key, help))
        }

        return unsafe &self
    }

    fn <eval T: FlagKind> define(self,
                                 key:    string,
                                 short_: string,
                                 long_:  string,
                                 help:   string) -> unsafe *Self {
        assert static (T == FlagKind::String) || T == FlagKind::Path || T == FlagKind::StringList || T == FlagKind::PathList,
            r"only String, Path, and StringList can omit default"
        eval if T == FlagKind::String {
            return self.define(FlagDef::str_(key, short_, long_, help))
        } else if T == FlagKind::Path {
            return self.define(FlagDef::file_(key, short_, long_, help))
        } else if T == FlagKind::StringList {
            return self.define(FlagDef::list_(key, short_, long_, help))
        }

        return unsafe &self
    }


    fn <eval T: FlagKind> define(self,
                                 key:    string,
                                 short_: string,
                                 long_:  string,
                                 help:   string,
                                 dfl:    bool) -> unsafe *Self {
        assert static T == FlagKind::Bool, r"bool default requires FlagKind::Bool"
        return self.define(FlagDef::bool_(key, short_, long_, help, dfl))
    }

    fn <eval T: FlagKind> define(self,
                                 key:    string,
                                 short_: string,
                                 long_:  string,
                                 help:   string,
                                 dfl:    string) -> unsafe *Self {
        assert static T == FlagKind::String, r"string default requires FlagKind::String"
        return self.define(FlagDef::str_d(key, short_, long_, help, dfl))
    }

    fn <eval T: FlagKind> define(self,
                                 key:    string,
                                 short_: string,
                                 long_:  string,
                                 help:   string,
                                 dfl:    i32) -> unsafe *Self {
        assert static T == FlagKind::I32, r"i32 default requires FlagKind::I32"
        return self.define(FlagDef::i32_(key, short_, long_, help, dfl))
    }

    fn <eval T: FlagKind> define(self,
                                 key:    string,
                                 short_: string,
                                 long_:  string,
                                 help:   string,
                                 dfl:    f64) -> unsafe *Self {
        assert static T == FlagKind::F64, r"f64 default requires FlagKind::F64"
        return self.define(FlagDef::f64_(key, short_, long_, help, dfl))
    }


    fn <eval T: FlagKind> define(self,
                                 key:    string,
                                 short_: string,
                                 long_:  string,
                                 help:   string,
                                 dfl:    i32,
                                 min:    i32,
                                 max:    i32) -> unsafe *Self {
        assert static T == FlagKind::I32, r"i32 bounds requires FlagKind::I32"
        return self.define(FlagDef::i32_b(key, short_, long_, help, dfl, min, max))
    }

    fn <eval T: FlagKind> define(self,
                                 key:    string,
                                 short_: string,
                                 long_:  string,
                                 help:   string,
                                 dfl:    f64,
                                 min:    f64,
                                 max:    f64) -> unsafe *Self {
        assert static T == FlagKind::F64, r"f64 bounds requires FlagKind::F64"
        return self.define(FlagDef::f64_b(key, short_, long_, help, dfl, min, max))
    }


    fn <eval T: FlagKind> define_cfg(self, key: string, help: string) -> unsafe *Self {
        assert static T == FlagKind::String, r"only String can omit default in cfg"
        return self.define(FlagDef::cfg_str_(key, help))
    }


    fn <eval T: FlagKind> define_cfg(self, key: string, help: string, dfl: bool) -> unsafe *Self {
        assert static T == FlagKind::Bool, r"bool default requires FlagKind::Bool"
        return self.define(FlagDef::cfg_bool_(key, help, dfl))
    }

    fn <eval T: FlagKind> define_cfg(self, key: string, help: string, dfl: string) -> unsafe *Self {
        assert static T == FlagKind::String, r"string default requires FlagKind::String"
        return self.define(FlagDef::cfg_str_d(key, help, dfl))
    }

    fn <eval T: FlagKind> define_cfg(self, key: string, help: string, dfl: i32) -> unsafe *Self {
        assert static T == FlagKind::I32, r"i32 default requires FlagKind::I32"
        return self.define(FlagDef::cfg_i32_(key, help, dfl))
    }


    fn <eval T: FlagKind> define_cfg(self,
                                     key:  string,
                                     help: string,
                                     dfl:  i32,
                                     min:  i32,
                                     max:  i32) -> unsafe *Self {
        assert static T == FlagKind::I32, r"i32 bounds requires FlagKind::I32"
        return self.define(FlagDef::cfg_i32_b(key, help, dfl, min, max))
    }

    fn <eval T: FlagKind> define_cfg(self,
                                     key:  string,
                                     help: string,
                                     dfl:  f64,
                                     min:  f64,
                                     max:  f64) -> unsafe *Self {
        assert static T == FlagKind::F64, r"f64 bounds requires FlagKind::F64"
        return self.define(FlagDef::cfg_f64_b(key, help, dfl, min, max))
    }


    /// Flag the def stored under `key` as parsed-but-consumed-by-nothing. Cfg
    /// flags are stored as "c:{name}", so pass that form for them; a Feature's
    /// key is its bare feature name. An unknown key is ignored on purpose: the
    /// list lives in the registry, and a typo there must not abort the compiler.
    /// \brief tags every positional input with the value \p key has when the
    ///        input is seen, in ParsedArgs::file_langs (parallel to files).
    ///        clang's -x semantics: it applies to the inputs that FOLLOW it.
    fn tag_positionals_with(self, const key: string) {
        self._tag_key = key
    }

    fn mark_unimplemented(self, const key: string) {
        for var i: usize = 0; i < self._table.size(); ++i {
            var *def = &self._table[i]
            if def->key == key {
                def->unimplemented = true
            }
        }
    }

    /// Keep the def stored under `key` (same key forms as mark_unimplemented)
    /// out of --help. It still parses: hiding is about what users are offered,
    /// and the build that relies on it must not break.
    fn mark_hidden(self, const key: string) {
        for var i: usize = 0; i < self._table.size(); ++i {
            var *def = &self._table[i]
            if def->key == key {
                def->hidden = true
            }
        }
    }

    /// One U005W per unimplemented flag the user actually set. Warning only:
    /// the flag parsed fine, it just has no effect yet.
    priv fn _warn_unimplemented(self, result: *ParsedArgs) {
        for var i: usize = 0; i < self._table.size(); ++i {
            var *def = &self._table[i]
            if !def->unimplemented || !result->is_set(def->key) {
                continue
            }

            var nm: string = ""
            if def->kind == FlagKind::Feature {
                nm = if (result->get_feature(def->key) == 1) => (f"-f{def->key}")
                     else => f"-fno-{def->key}"
            } else if def->key.length() > 2
                && def->key[0] == ('c' as u8)
                && def->key[1] == (':' as u8) {
                var bare = def->key.subslice(2, def->key.size())
                nm = f"--c{bare}"
            } else if def->long_.length() > 0 {
                nm = f"--{def->long_}"
            } else if def->short_.length() > 0 {
                nm = f"-{def->short_}"
            } else {
                nm = f"--{def->key}"
            }

            self._diag->report(
                DiagCode(DiagID::U005W),
                f"flag '{nm}' is accepted but not yet implemented; it has no effect",
            ).emit()
        }
    }

    /// linear scan by short, long, or key - fine for CLI-sized tables
    /// key fallback lets --opt=2 find a flag defined with long_=""
    priv fn _find(self, const name: string) -> unsafe *FlagDef {
        for var i: usize = 0; i < self._table.size(); ++i {
            var unsafe *def = unsafe &self._table[i]
            if def->kind == FlagKind::PathList {
                continue
            }

            if def->kind == FlagKind::Feature { // handled by _find_feature
                continue
            }

            if def->short_ == name {
                return def
            }

            if def->long_ == name {
                return def
            }

            if def->long_.length() == 0 && def->key == name { // key as long fallback
                return def
            }
        }

        return &null
    }

    /// find a Feature flag by feature key (without the 'f' / 'fno-' prefix)
    priv fn _find_feature(self, const name: string) -> unsafe *FlagDef {
        for var i: usize = 0; i < self._table.size(); ++i {
            var unsafe *def = unsafe &self._table[i]
            if def->kind != FlagKind::Feature {
                continue
            }

            if def->key == name {
                return def
            }
        }

        return &null
    }

    /// find a config flag by its bare key (without the 'c' CLI prefix)
    /// internally these are stored with key = "c:{name}"
    priv fn _find_cfg(self, const name: string) -> unsafe *FlagDef {
        var k = f"c:{name}"
        for var i: usize = 0; i < self._table.size(); ++i {
            var unsafe *def = unsafe &self._table[i]
            if def->key == k {
                return def
            }
        }

        return &null
    }

    /// exact match, then longest-prefix split for joined values like -O2
    priv fn _find_split(self, const name: string, @inout out_value: string) -> unsafe *FlagDef {
        var unsafe *exact = self._find(name)
        if exact != &null {
            (out_value) = ""
            return exact
        }

        var split: i32 = (name.length() as i32) - 1
        while split >= 1 {
            var        prefix = name.subslice(0, (split as usize))
            var        suffix = name.subslice(split as usize, name.size())
            var unsafe *def   = self._find(prefix)
            if def != &null && def->kind != FlagKind::Bool {
                (out_value) = suffix
                return def
            }

            split -= 1
        }

        (out_value) = ""
        return &null
    }



    /// classic two-row Levenshtein; only ever runs on a failed lookup, so the
    /// O(n*m) over a CLI-sized table is free in practice
    priv fn _edit_distance(self, const a: string, const b: string) -> usize {
        var n = a.length()
        var m = b.length()
        if n == 0 {
            return m
        }

        if m == 0 {
            return n
        }

        var prev: cxx::std::vector<usize>
        var cur:  cxx::std::vector<usize>
        prev.resize(m + 1, 0 as usize)
        cur.resize(m + 1, 0 as usize)

        for var j: usize = 0; j <= m; ++j {
            prev[j] = j
        }

        for var i: usize = 1; i <= n; ++i {
            cur[0] = i
            for var j: usize = 1; j <= m; ++j {
                var cost: usize = (if a[i - 1] == b[j - 1] => (0) else => (1))
                var best        = prev[j] + 1                                  // deletion
                var ins         = cur[j - 1] + 1                               // insertion
                var sub         = prev[j - 1] + cost                           // substitution
                if ins < best {
                    best = ins
                }

                if sub < best {
                    best = sub
                }

                cur[j] = best
            }

            for var j: usize = 0; j <= m; ++j {
                prev[j] = cur[j]
            }
        }

        return prev[m]
    }

    /// every spelling a user could legally type, as it would appear on the
    /// command line (prefix included)
    priv fn _spellings(self,
                       @inout out_names: cxx::std::vector<string>,
                       @inout out_disp:  cxx::std::vector<string>) {
        for var i: usize = 0; i < self._table.size(); ++i {
            var *def = &self._table[i]
            if def->kind == FlagKind::PathList {
                continue
            }

            if def->kind == FlagKind::Feature {
                out_names.push_back(f"f{def->key}")
                out_disp.push_back(f"-f{def->key}")
                out_names.push_back(f"fno-{def->key}")
                out_disp.push_back(f"-fno-{def->key}")
                continue
            }

            // config flags are stored as key = "c:{name}" and typed as --c{name}
            if def->key.length() > 2 && def->key.starts_with("c:") {
                var bare = def->key.subslice(2, def->key.size())
                out_names.push_back(f"c{bare}")
                out_disp.push_back(f"--c{bare}")
                continue
            }

            if def->long_.length() > 0 {
                out_names.push_back(def->long_)
                out_disp.push_back(f"--{def->long_}")
            } else if def->key.length() > 0 {
                out_names.push_back(def->key)
                out_disp.push_back(f"--{def->key}")
            }

            // single-letter shorts are never useful suggestions - too many
            // of them sit one edit apart from each other
            if def->short_.length() > 1 {
                out_names.push_back(def->short_)
                out_disp.push_back(f"-{def->short_}")
            }
        }
    }

    /// nearest known flag to an unrecognised name, or "" if nothing is close
    /// enough to be worth printing. `name` is the bare text the user typed,
    /// without its '-' / '--' / '/' prefix.
    /// score sentinel: "no relationship at all"
    priv fn _no_match(self) -> usize {
        return 9999
    }

    /// split a flag name on '-' into its words, dropping empties
    priv fn _split_words(self, const s: string, @inout out: cxx::std::vector<string>) {
        var n        = s.length()
        var b: usize = 0
        for var i: usize = 0; i <= n; ++i {
            if i == n || s[i] == ('-' as u8) {
                if i > b {
                    out.push_back(s.subslice(b, i - b))
                }

                b = i + 1
            }
        }
    }

    /// how close is `cand` to what the user typed? lower is better,
    /// _no_match() means "do not suggest this". three independent routes:
    ///   - prefix:  --type-check   -> --type-check-only  (truncated flag)
    ///   - words:   --typse-check  -> --type-check-only  (typo in one word)
    ///   - edits:   --sytanx-only  -> --syntax-only      (typo anywhere)
    priv fn _score(self, const name: string, const cand: string) -> usize {
        var best = self._no_match()

        // route 1: one is a prefix of the other. a truncated flag is the most
        // common "wrong flag" there is, so it outranks everything else.
        if cand.starts_with(name) {
            return 0
        }

        if name.starts_with(cand) {
            best = (1)
        }

        // route 2: word-by-word. every word the user typed must line up with
        // some word of the candidate; extra candidate words are free.
        var nw: cxx::std::vector<string>
        var cw: cxx::std::vector<string>
        self._split_words(name, &nw)
        self._split_words(cand, &cw)

        if nw.size() > 0 && cw.size() > 0 {
            var total: usize = 0
            var ok:    bool  = true

            for var i: usize = 0; i < nw.size(); ++i {
                // tolerance per word, by that word's length
                var tol: usize = 2
                if nw[i].length() <= 3 {
                    tol = 0
                } else if nw[i].length() <= 6 {
                    tol = 1
                }

                var wbest = self._no_match()
                for var j: usize = 0; j < cw.size(); ++j {
                    var d = self._edit_distance(nw[i], cw[j])
                    if d < wbest {
                        wbest = d
                    }
                }

                if wbest > tol {
                    ok = false
                    break
                }

                total += wbest
            }

            // +1 so an exact prefix always wins over a word-level match
            if ok && total + 1 < best {
                best = total + 1
            }
        }

        // route 3: plain edit distance over the whole name
        var limit: usize = 3
        if name.length() <= 3 {
            limit = 1
        } else if name.length() <= 7 {
            limit = 2
        }

        var d = self._edit_distance(name, cand)
        if d <= limit && d < best {
            best = d
        }

        return best
    }

    /// nearest known flag to an unrecognised name, or "" if nothing is close
    /// enough to be worth printing. `name` is the bare text the user typed,
    /// without its '-' / '--' / '/' prefix.
    priv fn _suggest(self, const name: string) -> string {
        if name.length() < 2 { // a one-char typo has no unique fix
            return ""
        }

        var names: cxx::std::vector<string>
        var disp:  cxx::std::vector<string>
        self._spellings(&names, &disp)

        var best:   usize = names.size()     // sentinel: nothing found
        var best_s: usize = self._no_match()

        for var i: usize = 0; i < names.size(); ++i {
            // never hand back the very spelling that was just rejected
            if names[i] == name {
                continue
            }

            var sc = self._score(name, names[i])
            if sc >= self._no_match() {
                continue
            }

            // ties go to the shorter flag - it is the less surprising guess
            if sc < best_s
                || sc == best_s && best < names.size() && names[i].length() < names[best].length() {
                best_s = sc
                best   = i
            }
        }

        if best >= names.size() {
            return ""
        }

        return disp[best]
    }


    /// 0 = parsed, 1 = not an integer, 2 = integer outside the i32 range.
    /// The two failures need different messages: "expects an integer" for
    /// 99999999999 sends the user hunting for a typo that is not there.
    /// strtoll saturates at the i64 limits on overflow, which the i32 range
    /// check below also rejects, so errno is not needed.
    priv fn _parse_i32(self, const s: string, out: unsafe *i32) -> i32 {
        // `char` is a byte (unsigned char); strtoll wants plain char, so parse
        // a std::string copy and point into that.
        var raw                 = kairo::std::to_std_string(s)
        var ptr: unsafe *c_char = raw.data()

        var end: unsafe *c_char = &null
        var v:   i64            = cxx::std::strtoll(ptr, unsafe &end, 10)

        if end == ptr { // nothing parsed
            return 1
        }

        if ((*end) as u8) != ('\x00' as u8) { // trailing garbage
            return 1
        }

        if v < cxx::std::numeric_limits<i32>::min() || v > cxx::std::numeric_limits<i32>::max() {
            return 2
        }

        *out = (v as i32)
        return 0
    }

    priv fn _parse_f64(self, const s: string, out: unsafe *f64) -> bool {
        var raw                 = kairo::std::to_std_string(s)
        var ptr: unsafe *c_char = raw.data()

        try {
            var end: unsafe *c_char = &null
            var v:   f64            = cxx::std::strtod(ptr, unsafe &end)

            if end == ptr { // nothing parsed
                return false
            }

            if ((*end) as u8) != ('\x00' as u8) { // trailing garbage
                return false
            }

            if v < cxx::std::numeric_limits<f64>::lowest()
                || v > cxx::std::numeric_limits<f64>::max() {
                return false
            }

            *out = (v)
        } catch {
            return false
        }

        return true
    }


    /// how a flag is spelled in a diagnostic: `'--long'`, `'-s'`, or
    /// `'-s' / '--long'` when both exist; cfg flags are `'--c<name>'` and
    /// features `'-f<name>'`. Rendering `-{short}` unconditionally printed a
    /// bare `'-'` for every long-only flag.
    priv fn _flag_name(self, def: unsafe *FlagDef) -> string {
        if def->key.length() > 2 && def->key[0] == ('c' as u8) && def->key[1] == (':' as u8) {
            var bare = def->key.subslice(2, def->key.size())
            return f"'--c{bare}'"
        }

        if def->kind == FlagKind::Feature {
            return f"'-f{def->key}'"
        }

        var has_s = def->short_.length() > 0
        var has_l = def->long_.length() > 0
        if has_s && has_l {
            return f"'-{def->short_}' / '--{def->long_}'"
        }

        if has_l {
            return f"'--{def->long_}'"
        }

        if has_s {
            return f"'-{def->short_}'"
        }

        return f"'--{def->key}'"
    }

    /// case-insensitive compare against an already-lowercase ASCII word.
    /// Works on code points so no char arithmetic is needed.
    priv fn _ieq_lower(self, const raw: string, const word: string) -> bool {
        if raw.length() != word.length() {
            return false
        }

        for var k: usize = 0; k < raw.length(); ++k {
            var c: i32 = (raw[k])
            if c >= ('A' as i32) && c <= ('Z' as i32) {
                c += ('a' as i32) - ('A' as i32)
            }

            if c != (word[k] as i32) {
                return false
            }
        }

        return true
    }

    /// an explicit `--flag=value` on a Bool flag. Anything outside the
    /// accepted set is an error (U003E), so `--shared=bogus` cannot read as
    /// true.
    priv fn _apply_bool_value(self, def: unsafe *FlagDef, const raw: string, result: *ParsedArgs) {
        var *cell = result->_cell(def->key)
        if self._ieq_lower(raw, "true")
            || self._ieq_lower(raw, "1")
            || self._ieq_lower(raw, "yes")
            || self._ieq_lower(raw, "on") {
            cell->set_bool(true)
            return
        }

        if self._ieq_lower(raw, "false")
            || self._ieq_lower(raw, "0")
            || self._ieq_lower(raw, "no")
            || self._ieq_lower(raw, "off") {
            cell->set_bool(false)
            return
        }

        var nm = self._flag_name(def)
        self._diag->report(
            DiagCode(DiagID::U003E),
            f"invalid value '{raw}' for flag {nm}; accepted: true, false, 1, 0, yes, no, on, off",
        ).emit()
        result->ok = false
    }

    /// `-fX=value`: a feature is a toggle pair, it takes no value.
    priv fn _reject_feature_value(self,
                                  def:       unsafe *FlagDef,
                                  const raw: string,
                                  result:    *ParsedArgs) {
        var nm = self._flag_name(def)
        self._diag->report(
            DiagCode(DiagID::U003E),
            f"invalid value '{raw}' for flag {nm}; a feature takes no value, use -f{def->key} or -fno-{def->key}",
        ).emit()
        result->ok = false
    }

    /// \brief true when a flag's help already states its default; the
    ///        renderer must not append a second "(default: X)"
    priv fn _contains(self, const hay: string, const needle: string) -> bool {
        var n = hay.length()
        var m = needle.length()
        if m > n {
            return false
        }

        for var i: usize = 0; i + m <= n; ++i {
            if hay.subslice(i, m) == needle {
                return true
            }
        }

        return false
    }

    priv fn _apply(self, def: unsafe *FlagDef, const raw: string, result: *ParsedArgs) {
        var *cell = result->_cell(def->key)
        if !self._tag_key.empty() && def->key == self._tag_key {
            self._tag_dirty = true
        }

        match def->kind {
            case FlagKind::Bool {
                cell->set_bool(true)
            } case FlagKind::String,
                 FlagKind::Path {
                if def->choices.size() > 0 {
                    var found        = false
                    var set:  string = ""
                    for var c: usize = 0; c < def->choices.size(); ++c {
                        if def->choices[c] == raw {
                            found = true
                        }

                        if c > 0 {
                            set += ", "
                        }

                        set += if (def->short_.length() > 0) => (f"-{def->short_}{def->choices[c]}")
                               else => def->choices[c]
                    }

                    if def->has_bare && def->short_.length() > 0 {
                        set += f", -{def->short_}"
                    }

                    if !found {
                        // A long-only flag has no `-X` spelling to name.
                        var nm = if (def->short_.length() > 0) => (f"'-{def->short_}' / '--{def->key}'")
                                 else => f"'--{def->key}'"
                        self._diag->report(
                            DiagCode(DiagID::U003E),
                            f"invalid value '{raw}' for flag {nm}; accepted: {set}",
                        ).emit()
                        result->ok = false
                        return
                    }
                }

                cell->set_string(raw)
            } case FlagKind::StringList {
                if def->choices.size() == 0 {
                    cell->push(raw)
                    return
                }

                // A restricted list: each comma-separated item must be a
                // choice.
                var items        = cxx::std::vector<string>()
                var start: usize = 0
                for var i: usize = 0; i <= raw.length(); ++i {
                    if i == raw.length() || raw[i] == (',' as u8) {
                        items.push_back(raw.subslice(start, i - start))
                        start = i + 1
                    }
                }

                for var k: usize = 0; k < items.size(); ++k {
                    var found        = false
                    var set:  string = ""
                    for var c: usize = 0; c < def->choices.size(); ++c {
                        if def->choices[c] == items[k] {
                            found = true
                        }

                        if c > 0 {
                            set += ", "
                        }

                        set += def->choices[c]
                    }

                    if !found {
                        self._diag->report(
                            DiagCode(DiagID::U003E),
                            f"invalid value '{items[k]}' for flag '--{def->key}'; accepted: {set}",
                        ).emit()
                        result->ok = false
                        return
                    }

                    cell->push(items[k])
                }
            } case FlagKind::I32 {
                var v:  i32 = 0
                var nm      = self._flag_name(def)
                var pst     = self._parse_i32(raw, unsafe &v)
                if pst == 1 {
                    self._diag->report(
                        DiagCode(DiagID::U003E),
                        f"flag {nm} expects an integer, got '{raw}'",
                    ).emit()
                    result->ok = false
                    return
                }

                if pst == 2 {
                    self._diag->report(
                        DiagCode(DiagID::U003E),
                        f"flag {nm} value '{raw}' is out of range for a 32-bit integer",
                    ).emit()
                    result->ok = false
                    return
                }

                if def->has_bounds && (v < def->min_i || v > def->max_i) {
                    self._diag->report(
                        DiagCode(DiagID::U003E),
                        f"flag {nm} value {v} is out of range [{def->min_i}, {def->max_i}]",
                    ).emit()
                    result->ok = false
                    return
                }

                cell->set_i32(v)
            } case FlagKind::F64 {
                var v: f64 = 0.0
                var nm     = self._flag_name(def)
                if !self._parse_f64(raw, unsafe &v) {
                    self._diag->report(
                        DiagCode(DiagID::U003E),
                        f"flag {nm} expects a number, got '{raw}'",
                    ).emit()
                    result->ok = false
                    return
                }

                if def->has_bounds && (v < def->min_f || v > def->max_f) {
                    self._diag->report(
                        DiagCode(DiagID::U003E),
                        f"flag {nm} value {v} is out of range [{def->min_f}, {def->max_f}]",
                    ).emit()
                    result->ok = false
                    return
                }

                cell->set_f64(v)
            } case FlagKind::Feature {
                // Feature is always applied via _apply_feature, not _apply.
                // This branch is a no-op safety guard.
            } default { }
        }
    }

    /// \brief set a Feature flag cell to enabled (1) or disabled (0)
    priv fn _apply_feature(self, def: unsafe *FlagDef, enable: bool, result: *ParsedArgs) {
        var *cell = result->_cell(def->key)
        cell->set_i32(if enable => 1 else => 0)
    }

    /// One positional input, with the tag flag's value at this point.
    priv fn _push_file(self, result: *ParsedArgs, const path: string) {
        result->files.push_back(path)
        var lang = ""
        if !self._tag_key.empty() && result->has(self._tag_key) {
            lang = result->get_string(self._tag_key)
        }

        result->file_langs.push_back(lang)
        self._tag_dirty = false
    }

    priv fn _parse_impl(self, @inout args: cxx::std::vector<string>) -> ParsedArgs {
        var result = ParsedArgs()
        self._tag_dirty = false
        var gstate:  Self::GlobalState = Self::GlobalState::Normal
        var pending: unsafe *FlagDef   = &null

        eval if defined!(_WIN32) || defined!(_WIN64) {
            const _IS_WINDOWS: bool = true
        } else {
            const _IS_WINDOWS: bool = false
        }

        // seed result map with flag defaults
        for var t: usize = 0; t < self._table.size(); ++t {
            result._init(self._table[t].key, self._table[t].default_)
        }

        var i: usize = 1 // skip args[0] (program name)
        while i < args.size() {
            var elem = args[i]
            var elen = elem.length()

            if gstate == Self::GlobalState::PathsOnly {
                self._push_file(&result, elem)
                i += 1
                continue
            }

            if gstate == Self::GlobalState::AwaitValue {
                // A dash-led element is the next flag, not this one's value: taking it
                // would swallow `-o` in `--xray -o out` and then parse the old output as
                // a source file. Bare '-' stays a legal value (stdin); a value that
                // really starts with '-' is spelled `--flag=-value`.
                if elen > 1 && elem[0] == ('-' as u8) {
                    var pnm = self._flag_name(pending)
                    self._diag->report(
                        DiagCode(DiagID::U004E),
                        f"flag {pnm} requires a value but none was provided",
                    ).emit()
                    result.ok = false
                    gstate    = Self::GlobalState::Normal
                    pending   = &null
                    // fall through: reprocess this element as a flag
                } else {
                    self._apply(pending, elem, &result)
                    gstate  = Self::GlobalState::Normal
                    pending = &null
                    i += 1
                    continue
                }
            }

            if elen == 0 {
                i += 1
                continue
            }

            if elem[0] == ('-' as u8) {
                // bare '-' -> stdin file (POSIX convention)
                if elen == 1 {
                    self._push_file(&result, "-")
                    i += 1
                    continue
                }

                if elem[1] == ('-' as u8) { // '--'
                    // bare '--' -> end of options
                    if elen == 2 {
                        gstate = Self::GlobalState::PathsOnly
                        i += 1
                        continue
                    }

                    // '--flag' or '--flag=value'
                    var j: usize = 2
                    while j < elen && elem[j] != ('=' as u8) {
                        j += 1
                    }

                    var        name = elem.subslice(2, j - 2)
                    var unsafe *def = self._find(name)

                    // try config flag: --cmax-recursion-depth=128
                    if def == &null && name.length() > 1 && name[0] == ('c' as u8) {
                        def = self._find_cfg(name.subslice(1, name.size()))
                    }

                    if def == &null {
                        var hint = self._suggest(name)
                        var msg = if (hint.length() > 0) => (f"unknown flag '--{name}'; did you mean '{hint}'; run '--help' to see available options")
                                  else => f"unknown flag '--{name}'; run '--help' to see available options"
                        self._diag->report(DiagCode(DiagID::U002E), msg).emit()
                        result.ok = false
                        i += 1
                        continue
                    }

                    if j < elen { // '--flag=value'
                        if def->kind == FlagKind::Bool {
                            self._apply_bool_value(def, elem.subslice(j + 1, elem.size()), &result)
                        } else {
                            self._apply(def, elem.subslice(j + 1, elem.size()), &result)
                        }
                    } else if def->kind == FlagKind::Bool {
                        self._apply(def, "", &result)
                    } else {
                        pending = def
                        gstate  = Self::GlobalState::AwaitValue
                    }
                } else if self.IS_LONG_FLAG[elem[1]] { // '-Wall' / '-O2' / '-funsafe' / '-fno-unsafe'
                    var j: usize = 1
                    while j < elen && elem[j] != ('=' as u8) {
                        j += 1
                    }

                    var        name           = elem.subslice(1, j - 1)
                    var        joined: string
                    var unsafe *def           = self._find_split(name, &joined)

                    // try feature flag: -funsafe  -fno-unsafe
                    if def == &null && name.length() > 4 && name.starts_with("fno-") {
                        var unsafe *feat = self._find_feature(name.subslice(4, name.size()))
                        if feat != &null {
                            if j < elen {
                                self._reject_feature_value(
                                    feat,
                                    elem.subslice(j + 1, elem.size()),
                                    &result,
                                )

                                i += 1
                                continue
                            }

                            self._apply_feature(feat, false, &result) // -fno-X -> disable
                            i += 1
                            continue
                        }
                    }

                    if def == &null && name.length() > 1 && name[0] == ('f' as u8) {
                        var unsafe *feat = self._find_feature(name.subslice(1, name.size()))
                        if feat != &null {
                            if j < elen {
                                self._reject_feature_value(
                                    feat,
                                    elem.subslice(j + 1, elem.size()),
                                    &result,
                                )

                                i += 1
                                continue
                            }

                            self._apply_feature(feat, true, &result) // -fX -> enable
                            i += 1
                            continue
                        }
                    }

                    if def == &null {
                        var hint = self._suggest(name)
                        var msg = if (hint.length() > 0) => (f"unknown flag '-{name}'; did you mean '{hint}'; run '--help' to see available options")
                                  else => f"unknown flag '-{name}'; run '--help' to see available options"
                        self._diag->report(DiagCode(DiagID::U002E), msg).emit()
                        result.ok = false
                        i += 1
                        continue
                    }

                    if j < elen { // explicit '=value'
                        var evalue: string = elem.subslice(j + 1, elem.size())
                        if def->kind == FlagKind::Bool {
                            self._apply_bool_value(def, evalue, &result)
                        } else if joined.length() > 0
                            && (def->kind == FlagKind::String
                                || def->kind == FlagKind::StringList
                                || def->kind == FlagKind::Path) {
                            // `-DFOO=7` splits to `-D` + "FOO" and then `=7`: the pair is one
                            // value "FOO=7", not "7" overwriting the name.
                            self._apply(def, f"{joined}={evalue}", &result)
                        } else {
                            self._apply(def, evalue, &result)
                        }
                    } else if def->kind == FlagKind::Bool {
                        self._apply(def, "", &result)
                    } else if joined.length() > 0 { // joined value from prefix split, e.g. -O2
                        self._apply(def, joined, &result)
                    } else if def->has_bare { // bare '-O' means '-O1', never 'take the next argument'
                        self._apply(def, def->bare_, &result)
                    } else {
                        pending = def
                        gstate  = Self::GlobalState::AwaitValue
                    }
                } else { // short cluster: '-abc' = -a -b -c
                    var j: usize = 1
                    while j < elen {
                        var        ch   = elem.subslice(j, 1)
                        var unsafe *def = self._find(ch)

                        if def == &null {
                            self._diag->report(
                                DiagCode(DiagID::U002E),
                                f"unknown flag '-{ch}'; run '--help' to see available options",
                            ).emit()
                            result.ok = false
                            j += 1
                            continue
                        }

                        if def->kind == FlagKind::Bool {
                            self._apply(def, "", &result)
                            j += 1
                        } else {
                            // remaining chars are the inline value, or next element
                            if j + 1 < elen {
                                self._apply(def, elem.subslice(j + 1, elem.size()), &result)
                            } else {
                                pending = def
                                gstate  = Self::GlobalState::AwaitValue
                            }

                            break
                        }
                    }
                }
            } else if elem[0] == ('/' as u8) && _IS_WINDOWS {
                if elen == 1 {
                    i += 1
                    continue
                }

                if elem[1] == ('-' as u8) { // '/-' is invalid
                    self._diag->report(
                        DiagCode(DiagID::U003E),
                        "'/-' is not a valid flag prefix; use '-flag', '--flag', or '/flag'",
                    ).emit()
                    result.ok = false
                    i += 1
                    continue
                }

                if self.IS_LONG_FLAG[elem[1]] {
                    var j: usize = 1
                    while j < elen && elem[j] != ('=' as u8) {
                        j += 1
                    }

                    var        name           = elem.subslice(1, j - 1)
                    var        joined: string
                    var unsafe *def           = self._find_split(name, &joined)

                    if def == &null {
                        var hint = self._suggest(name)
                        var msg = if (hint.length() > 0) => (f"unknown flag '/{name}'; did you mean '{hint}'; run '--help' to see available options")
                                  else => f"unknown flag '/{name}'; run '--help' to see available options"
                        self._diag->report(DiagCode(DiagID::U002E), msg).emit()
                        result.ok = false
                    } else if j < elen {
                        var evalue: string = elem.subslice(j + 1, elem.size())
                        if def->kind == FlagKind::Bool {
                            self._apply_bool_value(def, evalue, &result)
                        } else if joined.length() > 0
                            && (def->kind == FlagKind::String
                                || def->kind == FlagKind::StringList
                                || def->kind == FlagKind::Path) {
                            self._apply(def, f"{joined}={evalue}", &result)
                        } else {
                            self._apply(def, evalue, &result)
                        }
                    } else if def->kind == FlagKind::Bool {
                        self._apply(def, "", &result)
                    } else if joined.length() > 0 {
                        self._apply(def, joined, &result)
                    } else if def->has_bare {
                        self._apply(def, def->bare_, &result)
                    } else {
                        pending = def
                        gstate  = Self::GlobalState::AwaitValue
                    }
                } else { // '/g' '/c' short cluster
                    var j: usize = 1
                    while j < elen {
                        var        ch   = elem.subslice(j, 1)
                        var unsafe *def = self._find(ch)

                        if def == &null {
                            self._diag->report(
                                DiagCode(DiagID::U002E),
                                f"unknown flag '/{ch}'",
                            ).emit()
                            result.ok = false
                            j += 1
                            continue
                        }

                        if def->kind == FlagKind::Bool {
                            self._apply(def, "", &result)
                            j += 1
                        } else {
                            if j + 1 < elen {
                                self._apply(def, elem.subslice(j + 1, elem.size()), &result)
                            } else {
                                pending = def
                                gstate  = Self::GlobalState::AwaitValue
                            }

                            break
                        }
                    }
                }
            } else {
                self._push_file(&result, elem)
            }

            i += 1
        }

        // A -x after the last input changes nothing; clang warns the same way
        // (-Wunused-command-line-argument).
        if self._tag_dirty {
            var tv = result.get_string(self._tag_key)
            self._diag->report(
                DiagCode(DiagID::U025W),
                f"'-x {tv}' after the last input has no effect",
            ).emit()
        }

        // dangling AwaitValue: ran out before the value arrived
        if gstate == Self::GlobalState::AwaitValue && pending != &null {
            var pnm = self._flag_name(pending)
            self._diag->report(
                DiagCode(DiagID::U004E),
                f"flag {pnm} requires a value but none was provided",
            ).emit()
            result.ok = false
        }

        for var t: usize = 0; t < self._table.size(); ++t {
            var *def = &self._table[t]
            if !def->default_.is_required {
                continue
            }

            if def->kind == FlagKind::PathList {
                if result.files.size() == 0 {
                    self._diag->report(
                        DiagCode(DiagID::U004E),
                        f"no input files ({def->help})",
                    ).emit()
                    result.ok = false
                }
            } else if !result.is_set(def->key) {
                var name = if (def->long_.length() > 0) => (f"--{def->long_}")
                           else => f"-{def->short_}"
                self._diag->report(
                    DiagCode(DiagID::U004E),
                    f"required flag '{name}' was not provided",
                ).emit()
                result.ok = false
            }
        }

        return result
    }

    /// \brief parse a vec::<string> as received from main's argv
    ///        args[0] is the program name and is skipped
    pub fn parse(self) -> ParsedArgs {
        if self._args.size() == 0 {
            self._diag->report(
                DiagCode(DiagID::U004E),
                "no command-line arguments were provided to Command::parse()",
            ).emit()
            var result = ParsedArgs()
            result.ok = false
            return result
        }

        var result = self._parse_impl(&self._args)
        self._warn_unimplemented(&result)
        return result
    }

    /// \brief parse words that did not come from main's argv (no program
    ///        name in front): the kairo words FlagTranslator::from_driver
    ///        makes of a clang command line. Same parser, same checks.
    pub fn parse_words(self, @inout words: cxx::std::vector<string>) -> ParsedArgs {
        var args: cxx::std::vector<string>
        args.push_back("kairo")
        for *w in words {
            args.push_back(*w)
        }

        var result = self._parse_impl(&args)
        self._warn_unimplemented(&result)
        return result
    }

    /// \brief split a space-separated string and parse (convenience for tests)
    fn parse_string(self, const cmdline: string) -> ParsedArgs {
        var args: cxx::std::vector<string>
        args.push_back("prog") // argv[0] placeholder

        var start: usize = 0
        for var i: usize = 0; i <= cmdline.length(); ++i {
            var at_end = i == cmdline.length()
            var is_sep = !at_end && cmdline[i] == (' ' as u8)
            if at_end || is_sep {
                if i > start {
                    args.push_back(cmdline.subslice(start, i - start))
                }

                start = i + 1
            }
        }

        var result = self._parse_impl(&args)
        self._warn_unimplemented(&result)
        return result
    }


    /// --help: every flag a user is offered (an unimplemented one tagged).
    /// --help-hidden (\p hidden_only): the internal ones (mark_hidden) and the
    /// not-implemented-yet ones (mark_unimplemented), each tagged with which.
    pub fn print_help(self, hidden_only: bool = false) {
        var COL: usize = 36 // column where descriptions start

        var prog = (if (self._args.size() > 0) => (self._args[0]) else => "prog")

        var usage: string = f"USAGE: {prog} [options]"
        for var t: usize = 0; t < self._table.size(); ++t {
            if self._table[t].kind == FlagKind::PathList {
                usage += (if self._table[t].default_.is_required => " <files...>"
                          else => " [files...]")
                break
            }
        }

        io::println(f"{usage}")
        io::println("")
        io::println("OPTIONS:")

        for var t: usize = 0; t < self._table.size(); ++t {
            var *def = &self._table[t]
            if def->kind == FlagKind::PathList {
                continue
            }

            // --help: only the flags a user can use. --help-hidden: what a
            // user is not offered or cannot use yet, the internal and the
            // unimplemented ones (each tagged). Passing an unimplemented flag
            // still warns (U005W), so hiding it misleads no one.
            if hidden_only && !(def->hidden || def->unimplemented) {
                continue
            }

            if !hidden_only && (def->hidden || def->unimplemented) {
                continue
            }

            var lhs: string = "  "

            if def->kind == FlagKind::Feature {
                // -f[no-]<key>
                lhs += f"-f[no-]{def->key}"
            } else if def->key.length() > 2
                && def->key[0] == ('c' as u8)
                && def->key[1] == (':' as u8) {
                // config flag: --c<name>=<type>
                var name = def->key.subslice(2, def->key.size())
                lhs += f"--c{name}"
                match def->kind {
                    case FlagKind::String {
                        lhs += "=<value>"
                    } case FlagKind::Bool {
                        lhs += "=<bool>"
                    } case FlagKind::I32 {
                        lhs += if def->has_bounds => (f"=<{def->min_i}-{def->max_i}>")
                               else => "=<int>"
                    } case FlagKind::F64 {
                        lhs += if def->has_bounds => (f"=<{def->min_f:.2}-{def->max_f:.2}>")
                               else => "=<float>"
                    } default { }
                }
            } else {
                // regular flag: -s, --long <value>
                if def->short_.length() > 0 {
                    lhs += f"-{def->short_}"
                }

                if def->short_.length() > 0 && def->long_.length() > 0 {
                    lhs += ", "
                }

                if def->long_.length() > 0 {
                    lhs += f"--{def->long_}"
                }

                match def->kind {
                    case FlagKind::String,
                         FlagKind::Path {
                        lhs += " <value>"
                    } case FlagKind::StringList {
                        lhs += " <value>..."
                    } case FlagKind::I32 {
                        lhs += if def->has_bounds => (f" <{def->min_i}-{def->max_i}>")
                               else => " <int>"
                    } case FlagKind::F64 {
                        lhs += if def->has_bounds => (f" <{def->min_f:.2}-{def->max_f:.2}>")
                               else => " <float>"
                    } default { }
                }
            }

            var rhs: string = def->help
            // Many help strings already state their default ("(default: X)",
            // "-O0 (default)"); appending the rendered one printed it twice.
            var help_has_default = self._contains(def->help, "(default")
            if def->default_.is_required {
                rhs += " (required)"
            } else if !help_has_default {
                match def->kind {
                    case FlagKind::Bool {
                        // only note if default is non-obvious (true)
                        if def->default_.as_bool() {
                            rhs += " (default: on)"
                        }
                    } case FlagKind::String,
                         FlagKind::Path {
                        var dfl = def->default_.as_string()
                        if dfl.length() > 0 {
                            rhs += f" (default: {dfl})"
                        }
                    } case FlagKind::I32 {
                        rhs += f" (default: {def->default_.as_i32()})"
                    } case FlagKind::F64 {
                        rhs += f" (default: {def->default_.as_f64():.2})"
                    } default { } // Feature, StringList - no default shown
                }
            }

            if def->unimplemented {
                rhs += " [not implemented]"
            }

            if def->hidden {
                rhs += " [internal]"
            }

            if lhs.length() < COL {
                while lhs.length() < COL {
                    lhs.push_back(' ' as u8)
                }

                io::println(f"{lhs}{rhs}")
            } else {
                var pad: string = ""
                while pad.length() < COL {
                    pad.push_back(' ' as u8)
                }

                io::println(f"{lhs}")
                io::println(f"{pad}{rhs}")
            }
        }

        for var t: usize = 0; t < self._table.size(); ++t {
            var *def = &self._table[t]
            if def->kind != FlagKind::PathList {
                continue
            }

            io::println("")
            var lhs: string = "  <files...>"
            while lhs.length() < COL {
                lhs.push_back(' ' as u8)
            }

            io::println(
                f"{lhs}{def->help}{if def->default_.is_required => " (required)" else => " (optional)"}",
            )

            break
        }
    }
}
