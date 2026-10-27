/// --- The Kairo Project ---------------------------- Command/Command.k --- ///
///
///   <short description>
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
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

import Support::Timer::*;
import Support::Assert::*;
import Diagnostic::Engine::*;
import Command::ParsedArgs::*;

class Command {

    // compile-time long-single-dash prefix table
    //
    // When argv[i] starts with "-X" and IS_LONG_FLAG[X] is true, the parser
    // collects the entire run of characters as one flag name, then splits for
    // a joined value.  This is how -Wall, -O2, -fsanitize, -march=... work.

    eval fn _build_long_flag_table(self) -> array::<bool, 256> {
        var t: array::<bool, 256> = array::<bool, 256>();

        t['W'] = true; // -Wall  -Wextra  -Wno-...         (warnings)
        t['O'] = true; // -O0  -O1  -O2  -O3  -Os  -Oz   (optimization)
        t['f'] = true; // -funsafe  -fno-...  -fPIC  -fPIE  (feature toggles + codegen)
        t['m'] = true; // -march  -mcpu  -mabi  -mtune    (machine/target)
        t['X'] = true; // -Xcxx  -Xlinker  -Xassembler    (passthrough)
        t['s'] = true; // -std=...                           (language standard, single-dash form)
        t['D'] = true; // -DFOO  -DFOO=BAR                (macro defines)
        t['A'] = true; // -Afoo                            (allow/silence diagnostic)
        t['E'] = true; // -Efoo                            (promote diagnostic to error)
        t['F'] = true; // -Ffoo                            (forbid diagnostic)
        t['g'] = true; // -g  -g0  -gdwarf-4              (debug info, single-dash long form)
        t['I'] = true; // -I./include  -I/usr/include      (include paths, inline value)
        t['L'] = true; // -Lpath/to/lib                   (library search paths, inline value)
        t['l'] = true; // -lssl  -lcrypto  -l static:foo  (link libraries, inline value)
        t['Z'] = true; // -Zunstable-flag                  (unstable internal flags)

        return t;
    }

    var IS_LONG_FLAG: array::<bool, 256> = _build_long_flag_table();


    enum GlobalState derives u8 {
        Normal,     ///< nothing pending
        AwaitValue, ///< last flag needs the next element as its value
        PathsOnly,  ///< bare `--` seen; everything remaining is a file
    }


    priv var _args:  vec::<string>; ///< copy of argv for parsing (owned by Command)
    priv var _table: vec::<FlagDef>;
    priv var _diag:  obs::<DiagEngine>;
    /// The flag whose current value tags every positional input (the -x
    /// language). "" = no tagging. Positional order is lost once files are a
    /// flat list, and -x applies to the inputs AFTER it, so the tag is taken
    /// at the moment each file is seen; see _push_file.
    priv var _tag_key:   string;
    /// Set when the tag flag is applied, cleared by the next input: still set
    /// at the end means a trailing -x that tagged nothing.
    priv var _tag_dirty: bool = false;


    fn Command(self, argc: i32, argv: *(*kairo::std::Legacy::char), diag: *DiagEngine) {
        self._diag = diag;
        self._table.reserve(64); // typical CLI has ~20 flags, reserve a bit more
        self._args.reserve(usize(argc));
        for var i: i32 = 0; i < argc; ++i {
            self._args.emplace_back(string(argv[i], libcxx::strlen(argv[i])));
        }
    }

    fn Command(self, diag: *DiagEngine) { // ONLY FOR TESTING
        // INLINE(preproc)
        __inline_cpp("#warning \"CommandCommand::Command(diag) is only for testing; use Command(argc, argv, diag) in production\"");
        self._diag = diag;
        self._table.reserve(64);
    }


    fn define(self, def: FlagDef) -> ref!(Command) {
        self._table.push_back(def);
        return self;
    }


    fn <T: FlagKind> define(self, key: string, help: string) -> ref!(Command) {
        static_assert((T == FlagKind::PathList) || (T == FlagKind::Feature),
            r"only PathList and Feature can omit short/long/default");
        eval if (T == FlagKind::PathList) {
            return self.define(FlagDef::files_(key, help));
        } else if (T == FlagKind::Feature) {
            return self.define(FlagDef::feature_(key, help));
        }
        return self;
    }

    fn <T: FlagKind> define(self, key: string, short_: string, long_: string, help: string) -> ref!(Command) {
        static_assert((T == FlagKind::String) || (T == FlagKind::Path) || (T == FlagKind::StringList) || (T == FlagKind::PathList),
            r"only String, Path, and StringList can omit default");
        eval if (T == FlagKind::String) {
            return self.define(FlagDef::str_(key, short_, long_, help));
        } else if (T == FlagKind::Path) {
            return self.define(FlagDef::file_(key, short_, long_, help));
        } else if (T == FlagKind::StringList) {
            return self.define(FlagDef::list_(key, short_, long_, help));
        }
        return self;
    }


    fn <T: FlagKind> define(self, key: string, short_: string, long_: string, help: string, dfl: bool) -> ref!(Command) {
        static_assert(T == FlagKind::Bool, r"bool default requires FlagKind::Bool");
        return self.define(FlagDef::bool_(key, short_, long_, help, dfl));
    }

    fn <T: FlagKind> define(self, key: string, short_: string, long_: string, help: string, dfl: string) -> ref!(Command) {
        static_assert(T == FlagKind::String, r"string default requires FlagKind::String");
        return self.define(FlagDef::str_d(key, short_, long_, help, dfl));
    }

    fn <T: FlagKind> define(self, key: string, short_: string, long_: string, help: string, dfl: i32) -> ref!(Command) {
        static_assert(T == FlagKind::I32, r"i32 default requires FlagKind::I32");
        return self.define(FlagDef::i32_(key, short_, long_, help, dfl));
    }

    fn <T: FlagKind> define(self, key: string, short_: string, long_: string, help: string, dfl: f64) -> ref!(Command) {
        static_assert(T == FlagKind::F64, r"f64 default requires FlagKind::F64");
        return self.define(FlagDef::f64_(key, short_, long_, help, dfl));
    }


    fn <T: FlagKind> define(self, key: string, short_: string, long_: string, help: string, dfl: i32, min: i32, max: i32) -> ref!(Command) {
        static_assert(T == FlagKind::I32, r"i32 bounds requires FlagKind::I32");
        return self.define(FlagDef::i32_b(key, short_, long_, help, dfl, min, max));
    }

    fn <T: FlagKind> define(self, key: string, short_: string, long_: string, help: string, dfl: f64, min: f64, max: f64) -> ref!(Command) {
        static_assert(T == FlagKind::F64, r"f64 bounds requires FlagKind::F64");
        return self.define(FlagDef::f64_b(key, short_, long_, help, dfl, min, max));
    }


    fn <T: FlagKind> define_cfg(self, key: string, help: string) -> ref!(Command) {
        static_assert(T == FlagKind::String, r"only String can omit default in cfg");
        return self.define(FlagDef::cfg_str_(key, help));
    }


    fn <T: FlagKind> define_cfg(self, key: string, help: string, dfl: bool) -> ref!(Command) {
        static_assert(T == FlagKind::Bool, r"bool default requires FlagKind::Bool");
        return self.define(FlagDef::cfg_bool_(key, help, dfl));
    }

    fn <T: FlagKind> define_cfg(self, key: string, help: string, dfl: string) -> ref!(Command) {
        static_assert(T == FlagKind::String, r"string default requires FlagKind::String");
        return self.define(FlagDef::cfg_str_d(key, help, dfl));
    }

    fn <T: FlagKind> define_cfg(self, key: string, help: string, dfl: i32) -> ref!(Command) {
        static_assert(T == FlagKind::I32, r"i32 default requires FlagKind::I32");
        return self.define(FlagDef::cfg_i32_(key, help, dfl));
    }


    fn <T: FlagKind> define_cfg(self, key: string, help: string, dfl: i32, min: i32, max: i32) -> ref!(Command) {
        static_assert(T == FlagKind::I32, r"i32 bounds requires FlagKind::I32");
        return self.define(FlagDef::cfg_i32_b(key, help, dfl, min, max));
    }

    fn <T: FlagKind> define_cfg(self, key: string, help: string, dfl: f64, min: f64, max: f64) -> ref!(Command) {
        static_assert(T == FlagKind::F64, r"f64 bounds requires FlagKind::F64");
        return self.define(FlagDef::cfg_f64_b(key, help, dfl, min, max));
    }


    /// Flag the def stored under `key` as parsed-but-consumed-by-nothing. Cfg
    /// flags are stored as "c:{name}", so pass that form for them; a Feature's
    /// key is its bare feature name. An unknown key is ignored on purpose: the
    /// list lives in the registry, and a typo there must not abort the compiler.
    /// \brief tags every positional input with the value \p key has when the
    ///        input is seen, in ParsedArgs::file_langs (parallel to files).
    ///        clang's -x semantics: it applies to the inputs that FOLLOW it.
    fn tag_positionals_with(self, key: string) {
        self._tag_key = key;
    }

    fn mark_unimplemented(self, key: string) {
        for var i: usize = 0; i < self._table.size(); ++i {
            var def = &(self._table[i]);
            if def->key == key { def->unimplemented = true; }
        }
    }

    /// One U005W per unimplemented flag the user actually set. Warning only:
    /// the flag parsed fine, it just has no effect yet.
    priv fn _warn_unimplemented(self, result: *ParsedArgs) {
        for var i: usize = 0; i < self._table.size(); ++i {
            var def = &(self._table[i]);
            if (!def->unimplemented) || (!result->is_set(def->key)) { continue; }

            var nm: string = "";
            if def->kind == FlagKind::Feature {
                nm = (f"-f{def->key}") if (result->get_feature(def->key) == 1) else (f"-fno-{def->key}");
            } else if (def->key.length() > 2) && (def->key[0] == 'c') && (def->key[1] == ':') {
                var bare = def->key.subslice(2, def->key.size());
                nm = f"--c{bare}";
            } else if def->long_.length() > 0 {
                nm = f"--{def->long_}";
            } else if def->short_.length() > 0 {
                nm = f"-{def->short_}";
            } else {
                nm = f"--{def->key}";
            }
            self._diag->report(DiagCode(DiagID::U005W),
                f"flag '{nm}\x27 is accepted but not yet implemented; it has no effect")
                .emit();
        }
    }

    /// linear scan by short, long, or key - fine for CLI-sized tables
    /// key fallback lets --opt=2 find a flag defined with long_=""
    priv fn _find(self, name: string) -> *FlagDef {
        for var i: usize = 0; i < self._table.size(); ++i {
            var def = &(self._table[i]);
            if def->kind == FlagKind::PathList { continue; }
            if def->kind == FlagKind::Feature  { continue; } // handled by _find_feature
            if def->short_ == name { return def; }
            if def->long_  == name { return def; }
            if def->long_.length() == 0 && def->key == name { return def; } // key as long fallback
        }
        return &null;
    }

    /// find a Feature flag by feature key (without the 'f' / 'fno-' prefix)
    priv fn _find_feature(self, name: string) -> *FlagDef {
        for var i: usize = 0; i < self._table.size(); ++i {
            var def = &(self._table[i]);
            if def->kind != FlagKind::Feature { continue; }
            if def->key == name { return def; }
        }
        return &null;
    }

    /// find a config flag by its bare key (without the 'c' CLI prefix)
    /// internally these are stored with key = "c:{name}"
    priv fn _find_cfg(self, name: string) -> *FlagDef {
        var k = f"c:{name}";
        for var i: usize = 0; i < self._table.size(); ++i {
            var def = &(self._table[i]);
            if def->key == k { return def; }
        }
        return &null;
    }

    /// exact match, then longest-prefix split for joined values like -O2
    priv fn _find_split(self, name: string, out_value: *string) -> *FlagDef {
        var exact = self._find(name);
        if exact != &null { (*out_value) = ""; return exact; }

        var split: i32 = i32(name.length()) - 1;
        while split >= 1 {
            var prefix = name.subslice(usize(0), usize(split));
            var suffix = name.subslice(usize(split), name.size());
            var def    = self._find(prefix);
            if (def != &null) && (def->kind != FlagKind::Bool) {
                (*out_value) = suffix;
                return def;
            }
            split -= 1;
        }

        (*out_value) = "";
        return &null;
    }



    /// classic two-row Levenshtein; only ever runs on a failed lookup, so the
    /// O(n*m) over a CLI-sized table is free in practice
    priv fn _edit_distance(self, a: string, b: string) -> usize {
        var n = a.length();
        var m = b.length();
        if n == 0 { return m; }
        if m == 0 { return n; }

        var prev: vec::<usize>;
        var cur:  vec::<usize>;
        prev.resize(m + 1, usize(0));
        cur.resize(m + 1, usize(0));

        for var j: usize = 0; j <= m; ++j { prev[j] = j; }

        for var i: usize = 1; i <= n; ++i {
            cur[0] = i;
            for var j: usize = 1; j <= m; ++j {
                var cost: usize = (usize(0) if a[i - 1] == b[j - 1] else usize(1));
                var best = prev[j] + 1;                        // deletion
                var ins  = cur[j - 1] + 1;                     // insertion
                var sub  = prev[j - 1] + cost;                 // substitution
                if ins < best { best = ins; }
                if sub < best { best = sub; }
                cur[j] = best;
            }
            for var j: usize = 0; j <= m; ++j { prev[j] = cur[j]; }
        }
        return prev[m];
    }

    /// every spelling a user could legally type, as it would appear on the
    /// command line (prefix included)
    priv fn _spellings(self, out_names: *vec::<string>, out_disp: *vec::<string>) {
        for var i: usize = 0; i < self._table.size(); ++i {
            var def = &(self._table[i]);
            if def->kind == FlagKind::PathList { continue; }

            if def->kind == FlagKind::Feature {
                out_names->push_back(f"f{def->key}");
                out_disp->push_back(f"-f{def->key}");
                out_names->push_back(f"fno-{def->key}");
                out_disp->push_back(f"-fno-{def->key}");
                continue;
            }

            // config flags are stored as key = "c:{name}" and typed as --c{name}
            if (def->key.length() > 2) && (def->key.subslice(0, 2) == "c:") {
                var bare = def->key.subslice(2, def->key.size());
                out_names->push_back(f"c{bare}");
                out_disp->push_back(f"--c{bare}");
                continue;
            }

            if def->long_.length() > 0 {
                out_names->push_back(def->long_);
                out_disp->push_back(f"--{def->long_}");
            } else if def->key.length() > 0 {
                out_names->push_back(def->key);
                out_disp->push_back(f"--{def->key}");
            }

            // single-letter shorts are never useful suggestions - too many
            // of them sit one edit apart from each other
            if def->short_.length() > 1 {
                out_names->push_back(def->short_);
                out_disp->push_back(f"-{def->short_}");
            }
        }
    }

    /// nearest known flag to an unrecognised name, or "" if nothing is close
    /// enough to be worth printing. `name` is the bare text the user typed,
    /// without its '-' / '--' / '/' prefix.
    /// score sentinel: "no relationship at all"
    priv fn _no_match(self) -> usize { return usize(9999); }

    /// split a flag name on '-' into its words, dropping empties
    priv fn _split_words(self, s: string, out: *vec::<string>) {
        var n   = s.length();
        var b: usize = 0;
        for var i: usize = 0; i <= n; ++i {
            if (i == n) || (s[i] == '-') {
                if i > b { out->push_back(s.subslice(b, i - b)); }
                b = i + 1;
            }
        }
    }

    priv fn _starts_with(self, hay: string, pre: string) -> bool {
        if pre.length() > hay.length() { return false; }
        return hay.subslice(0, pre.length()) == pre;
    }

    /// how close is `cand` to what the user typed? lower is better,
    /// _no_match() means "do not suggest this". three independent routes:
    ///   - prefix:  --type-check   -> --type-check-only  (truncated flag)
    ///   - words:   --typse-check  -> --type-check-only  (typo in one word)
    ///   - edits:   --sytanx-only  -> --syntax-only      (typo anywhere)
    priv fn _score(self, name: string, cand: string) -> usize {
        var best = self._no_match();

        // route 1: one is a prefix of the other. a truncated flag is the most
        // common "wrong flag" there is, so it outranks everything else.
        if self._starts_with(cand, name) { return usize(0); }
        if self._starts_with(name, cand) { best = usize(1); }

        // route 2: word-by-word. every word the user typed must line up with
        // some word of the candidate; extra candidate words are free.
        var nw: vec::<string>;
        var cw: vec::<string>;
        self._split_words(name, &nw);
        self._split_words(cand, &cw);

        if (nw.size() > 0) && (cw.size() > 0) {
            var total: usize = 0;
            var ok: bool     = true;

            for var i: usize = 0; i < nw.size(); ++i {
                // tolerance per word, by that word's length
                var tol: usize = 2;
                if nw[i].length() <= 3      { tol = 0; }
                else if nw[i].length() <= 6 { tol = 1; }

                var wbest = self._no_match();
                for var j: usize = 0; j < cw.size(); ++j {
                    var d = self._edit_distance(nw[i], cw[j]);
                    if d < wbest { wbest = d; }
                }
                if wbest > tol { ok = false; break; }
                total += wbest;
            }

            // +1 so an exact prefix always wins over a word-level match
            if ok && ((total + 1) < best) { best = total + 1; }
        }

        // route 3: plain edit distance over the whole name
        var limit: usize = 3;
        if name.length() <= 3      { limit = 1; }
        else if name.length() <= 7 { limit = 2; }

        var d = self._edit_distance(name, cand);
        if (d <= limit) && (d < best) { best = d; }

        return best;
    }

    /// nearest known flag to an unrecognised name, or "" if nothing is close
    /// enough to be worth printing. `name` is the bare text the user typed,
    /// without its '-' / '--' / '/' prefix.
    priv fn _suggest(self, name: string) -> string {
        if name.length() < 2 { return ""; } // a one-char typo has no unique fix

        var names: vec::<string>;
        var disp:  vec::<string>;
        self._spellings(&names, &disp);

        var best: usize   = names.size(); // sentinel: nothing found
        var best_s: usize = self._no_match();

        for var i: usize = 0; i < names.size(); ++i {
            // never hand back the very spelling that was just rejected
            if names[i] == name { continue; }
            var sc = self._score(name, names[i]);
            if sc >= self._no_match() { continue; }
            // ties go to the shorter flag - it is the less surprising guess
            if (sc < best_s) || ((sc == best_s) && (best < names.size()) && (names[i].length() < names[best].length())) {
                best_s = sc;
                best   = i;
            }
        }

        if best >= names.size() { return ""; }
        return disp[best];
    }


    /// 0 = parsed, 1 = not an integer, 2 = integer outside the i32 range.
    /// The two failures need different messages: "expects an integer" for
    /// 99999999999 sends the user hunting for a typo that is not there.
    /// strtoll saturates at the i64 limits on overflow, which the i32 range
    /// check below also rejects, so errno is not needed.
    priv fn _parse_i32(self, s: string, out: *i32) -> i32 {
        // `char` is a byte (unsigned char); strtoll wants plain char, so parse
        // a std::string copy and point into that.
        var raw = s.std_string();
        var ptr: *std::Legacy::char = raw.data();

        var end: *std::Legacy::char = &null;
        var v: i64 = libcxx::strtoll(ptr, &end, 10);

        if end == ptr { return 1; }     // nothing parsed
        if (*end) != '\0' { return 1; }   // trailing garbage

        // INLINE(macro)
        if (v < __inline_cpp("(libcxx::numeric_limits<i32>::min)()")) || (v > __inline_cpp("(libcxx::numeric_limits<i32>::max)()")) {
            return 2;
        }

        (*out) = i32(v);
        return 0;
    }

    priv fn _parse_f64(self, s: string, out: *f64) -> bool {
        var raw = s.std_string();
        var ptr: *std::Legacy::char = raw.data();

        try {
            var end: *std::Legacy::char = &null;
            var v: f64 = libcxx::strtod(ptr, &end);

            if end == ptr { return false; }     // nothing parsed
            if (*end) != '\0' { return false; }   // trailing garbage

            // INLINE(macro)
            if (v < libcxx::numeric_limits::<f64>::lowest()) || (v > __inline_cpp("(libcxx::numeric_limits<f64>::max)()")) {
                return false;
            }

            (*out) = f64(v);
        } catch {
            return false;
        }

        return true;
    }


    /// how a flag is spelled in a diagnostic: `'--long'`, `'-s'`, or
    /// `'-s' / '--long'` when both exist; cfg flags are `'--c<name>'` and
    /// features `'-f<name>'`. Rendering `-{short}` unconditionally printed a
    /// bare `'-'` for every long-only flag.
    priv fn _flag_name(self, def: *FlagDef) -> string {
        if (def->key.length() > 2) && (def->key[0] == 'c') && (def->key[1] == ':') {
            var bare = def->key.subslice(2, def->key.size());
            return f"'--c{bare}\x27";
        }
        if def->kind == FlagKind::Feature { return f"'-f{def->key}\x27"; }

        var has_s = def->short_.length() > 0;
        var has_l = def->long_.length() > 0;
        if has_s && has_l { return f"'-{def->short_}' / '--{def->long_}\x27"; }
        if has_l { return f"'--{def->long_}\x27"; }
        if has_s { return f"'-{def->short_}\x27"; }
        return f"'--{def->key}\x27";
    }

    /// case-insensitive compare against an already-lowercase ASCII word.
    /// Works on code points so no char arithmetic is needed.
    priv fn _ieq_lower(self, raw: string, word: string) -> bool {
        if raw.length() != word.length() { return false; }
        for var k: usize = 0; k < raw.length(); ++k {
            var c: i32 = i32(raw[k]);
            if (c >= 65) && (c <= 90) { c += 32; }
            if c != i32(word[k]) { return false; }
        }
        return true;
    }

    /// an explicit `--flag=value` on a Bool flag. Anything outside the
    /// accepted set used to be read as true, so `--shared=false` enabled it.
    priv fn _apply_bool_value(self, def: *FlagDef, raw: string, result: *ParsedArgs) {
        var cell = result->_cell(def->key);
        if self._ieq_lower(raw, "true") || self._ieq_lower(raw, "1") || self._ieq_lower(raw, "yes") || self._ieq_lower(raw, "on") {
            cell->set_bool(true);
            return;
        }
        if self._ieq_lower(raw, "false") || self._ieq_lower(raw, "0") || self._ieq_lower(raw, "no") || self._ieq_lower(raw, "off") {
            cell->set_bool(false);
            return;
        }
        var nm = self._flag_name(def);
        self._diag->report(DiagCode(DiagID::U003E),
            f"invalid value '{raw}\x27 for flag {nm}; accepted: true, false, 1, 0, yes, no, on, off")
            .emit();
        result->ok = false;
    }

    /// `-fX=value`: a feature is a toggle pair, it takes no value.
    priv fn _reject_feature_value(self, def: *FlagDef, raw: string, result: *ParsedArgs) {
        var nm = self._flag_name(def);
        self._diag->report(DiagCode(DiagID::U003E),
            f"invalid value '{raw}\x27 for flag {nm}; a feature takes no value, use -f{def->key} or -fno-{def->key}")
            .emit();
        result->ok = false;
    }

    /// \brief true when a flag's help already states its default; the
    ///        renderer must not append a second "(default: X)"
    priv fn _contains(self, hay: string, needle: string) -> bool {
        var n = hay.length();
        var m = needle.length();
        if m > n { return false; }
        for var i: usize = 0; i + m <= n; ++i {
            if hay.subslice(i, m) == needle { return true; }
        }
        return false;
    }

    priv fn _apply(self, def: *FlagDef, raw: string, result: *ParsedArgs) {
        var cell = result->_cell(def->key);
        if (!self._tag_key.empty()) && (def->key == self._tag_key) { self._tag_dirty = true; }

        switch def->kind {
            case FlagKind::Bool {
                cell->set_bool(true);
            }
            case FlagKind::String:
            case FlagKind::Path {
                if def->choices.size() > 0 {
                    var found = false;
                    var set: string = "";
                    for var c: usize = 0; c < def->choices.size(); ++c {
                        if def->choices[c] == raw { found = true; }
                        if c > 0 { set += ", "; }
                        set += (f"-{def->short_}{def->choices[c]}") if (def->short_.length() > 0) else (def->choices[c]);
                    }
                    if def->has_bare && (def->short_.length() > 0) { set += f", -{def->short_}"; }
                    if !found {
                        // A long-only flag has no `-X` spelling to name.
                        var nm = (f"'-{def->short_}' / '--{def->key}\x27") if (def->short_.length() > 0) else (f"'--{def->key}\x27");
                        self._diag->report(DiagCode(DiagID::U003E),
                            f"invalid value '{raw}' for flag {nm}; accepted: {set}")
                            .emit();
                        result->ok = false;
                        return;
                    }
                }
                cell->set_string(raw);
            }
            case FlagKind::StringList {
                if def->choices.size() == 0 { cell->push(raw); return; }
                // A restricted list: each comma-separated item must be a
                // choice. MIGRATE(raw_string): a char loop, no substr.
                var item: string = "";
                var items = vec::<string>();
                for var i: usize = 0; i < raw.length(); ++i {
                    var ch = raw.subslice(i, 1);
                    if ch == "," { items.push_back(item); item = ""; continue; }
                    item += ch;
                }
                items.push_back(item);
                for var k: usize = 0; k < items.size(); ++k {
                    var found = false;
                    var set: string = "";
                    for var c: usize = 0; c < def->choices.size(); ++c {
                        if def->choices[c] == items[k] { found = true; }
                        if c > 0 { set += ", "; }
                        set += def->choices[c];
                    }
                    if !found {
                        self._diag->report(DiagCode(DiagID::U003E),
                            f"invalid value '{items[k]}\x27 for flag '--{def->key}\x27; accepted: {set}")
                            .emit();
                        result->ok = false;
                        return;
                    }
                    cell->push(items[k]);
                }
            }
            case FlagKind::I32 {
                var v: i32 = 0;
                var nm = self._flag_name(def);
                var pst = self._parse_i32(raw, &v);
                if pst == 1 {
                    self._diag->report(DiagCode(DiagID::U003E),
                        f"flag {nm} expects an integer, got '{raw}\x27")
                        .emit();
                    result->ok = false;
                    return;
                }
                if pst == 2 {
                    self._diag->report(DiagCode(DiagID::U003E),
                        f"flag {nm} value '{raw}\x27 is out of range for a 32-bit integer")
                        .emit();
                    result->ok = false;
                    return;
                }
                if def->has_bounds && ((v < def->min_i) || (v > def->max_i)) {
                    self._diag->report(DiagCode(DiagID::U003E),
                        f"flag {nm} value {v} is out of range [{def->min_i}, {def->max_i}]")
                        .emit();
                    result->ok = false;
                    return;
                }
                cell->set_i32(v);
            }
            case FlagKind::F64 {
                var v: f64 = 0.0;
                var nm = self._flag_name(def);
                if !self._parse_f64(raw, &v) {
                    self._diag->report(DiagCode(DiagID::U003E),
                        f"flag {nm} expects a number, got '{raw}\x27")
                        .emit();
                    result->ok = false;
                    return;
                }
                if def->has_bounds && ((v < def->min_f) || (v > def->max_f)) {
                    self._diag->report(DiagCode(DiagID::U003E),
                        f"flag {nm} value {v} is out of range [{def->min_f}, {def->max_f}]")
                        .emit();
                    result->ok = false;
                    return;
                }
                cell->set_f64(v);
            }
            case FlagKind::Feature {
                // Feature is always applied via _apply_feature, not _apply.
                // This branch is a no-op safety guard.
                0;
            }
            default { 0; }
        }
    }

    /// \brief set a Feature flag cell to enabled (1) or disabled (0)
    priv fn _apply_feature(self, def: *FlagDef, enable: bool, result: *ParsedArgs) {
        var cell = result->_cell(def->key);
        cell->set_i32(1 if enable else 0);
    }

    /// One positional input, with the tag flag's value at this point.
    priv fn _push_file(self, result: *ParsedArgs, path: string) {
        result->files.push_back(path);
        var lang = "";
        if (!self._tag_key.empty()) && result->has(self._tag_key) {
            lang = result->get_string(self._tag_key);
        }
        result->file_langs.push_back(lang);
        self._tag_dirty = false;
    }

    priv fn _parse_impl(self, args: ref!(vec::<string>)) -> ParsedArgs {
        var result  = ParsedArgs();
        self._tag_dirty = false;
        var gstate: GlobalState = GlobalState::Normal;
        var pending: *FlagDef  = &null;

        const eval if defined(_WIN32) || defined(_WIN64) {
            const var _IS_WINDOWS: bool = true;
        } else {
            const var _IS_WINDOWS: bool = false;
        }

        // seed result map with flag defaults
        for var t: usize = 0; t < self._table.size(); ++t {
            result._init(self._table[t].key, self._table[t].default_);
        }

        var i: usize = 1; // skip args[0] (program name)
        while i < args.size() {
            var elem  = args[i];
            var elen  = elem.length();

            if gstate == GlobalState::PathsOnly {
                self._push_file(&result, elem);
                i += 1; continue;
            }

            if gstate == GlobalState::AwaitValue {
                // A dash-led element is the next flag, not this one's value: taking it
                // swallowed `-o` in `--xray -o out` and then parsed the old output as
                // a source file. Bare '-' stays a legal value (stdin); a value that
                // really starts with '-' is spelled `--flag=-value`.
                if (elen > 1) && (elem[0] == '-') {
                    var pnm = self._flag_name(pending);
                    self._diag->report(DiagCode(DiagID::U004E),
                        f"flag {pnm} requires a value but none was provided")
                        .emit();
                    result.ok = false;
                    gstate  = GlobalState::Normal;
                    pending = &null;
                    // fall through: reprocess this element as a flag
                } else {
                    self._apply(pending, elem, &result);
                    gstate  = GlobalState::Normal;
                    pending = &null;
                    i += 1; continue;
                }
            }

            if elen == 0 { i += 1; continue; }

            if elem[0] == '-' {

                // bare '-' -> stdin file (POSIX convention)
                if elen == 1 { self._push_file(&result, "-"); i += 1; continue; }

                if elem[1] == '-' { // '--'
                    // bare '--' -> end of options
                    if elen == 2 { gstate = GlobalState::PathsOnly; i += 1; continue; }

                    // '--flag' or '--flag=value'
                    var j: usize = 2;
                    while j < elen && elem[j] != '=' { j += 1; }

                    var name = elem.subslice(2, j - 2);
                    var def  = self._find(name);

                    // try config flag: --cmax-recursion-depth=128
                    if (def == &null) && (name.length() > 1) && (name[0] == 'c') {
                        def = self._find_cfg(name.subslice(1, name.size()));
                    }

                    if def == &null {
                        var hint = self._suggest(name);
                        var msg  = (f"unknown flag '--{name}'; did you mean '{hint}\x27; run '--help' to see available options")
                                   if (hint.length() > 0) else
                                   (f"unknown flag '--{name}'; run '--help' to see available options");
                        self._diag->report(DiagCode(DiagID::U002E), msg).emit();
                        result.ok = false;
                        i += 1; continue;
                    }

                    if j < elen { // '--flag=value'
                        if def->kind == FlagKind::Bool {
                            self._apply_bool_value(def, elem.subslice(j + 1, elem.size()), &result);
                        } else {
                            self._apply(def, elem.subslice(j + 1, elem.size()), &result);
                        }
                    } else if def->kind == FlagKind::Bool {
                        self._apply(def, "", &result);
                    } else {
                        pending = def;
                        gstate  = GlobalState::AwaitValue;
                    }

                } else if IS_LONG_FLAG[u8(elem[1])] { // '-Wall' / '-O2' / '-funsafe' / '-fno-unsafe'
                    var j: usize = 1;
                    while j < elen && elem[j] != '=' { j += 1; }

                    var name    = elem.subslice(1, j - 1);
                    var joined: string;
                    var def     = self._find_split(name, &joined);

                    // try feature flag: -funsafe  -fno-unsafe
                    if (def == &null) && (name.length() > 4) && (name.subslice(0, 4) == "fno-") {
                        var feat = self._find_feature(name.subslice(4, name.size()));
                        if feat != &null {
                            if j < elen { self._reject_feature_value(feat, elem.subslice(j + 1, elem.size()), &result); i += 1; continue; }
                            self._apply_feature(feat, false, &result); // -fno-X -> disable
                            i += 1; continue;
                        }
                    }
                    if (def == &null) && (name.length() > 1) && (name[0] == 'f') {
                        var feat = self._find_feature(name.subslice(1, name.size()));
                        if feat != &null {
                            if j < elen { self._reject_feature_value(feat, elem.subslice(j + 1, elem.size()), &result); i += 1; continue; }
                            self._apply_feature(feat, true, &result); // -fX -> enable
                            i += 1; continue;
                        }
                    }

                    if def == &null {
                        var hint = self._suggest(name);
                        var msg  = (f"unknown flag '-{name}'; did you mean '{hint}\x27; run '--help' to see available options")
                                   if (hint.length() > 0) else
                                   (f"unknown flag '-{name}'; run '--help' to see available options");
                        self._diag->report(DiagCode(DiagID::U002E), msg).emit();
                        result.ok = false;
                        i += 1; continue;
                    }

                    if j < elen { // explicit '=value'
                        var evalue: string = elem.subslice(j + 1, elem.size());
                        if def->kind == FlagKind::Bool {
                            self._apply_bool_value(def, evalue, &result);
                        } else if (joined.length() > 0) && ((def->kind == FlagKind::String) || (def->kind == FlagKind::StringList) || (def->kind == FlagKind::Path)) {
                            // `-DFOO=7` splits to `-D` + "FOO" and then `=7`: the pair is one
                            // value "FOO=7", not "7" overwriting the name.
                            self._apply(def, f"{joined}={evalue}", &result);
                        } else {
                            self._apply(def, evalue, &result);
                        }
                    } else if def->kind == FlagKind::Bool {
                        self._apply(def, "", &result);
                    } else if joined.length() > 0 { // joined value from prefix split, e.g. -O2
                        self._apply(def, joined, &result);
                    } else if def->has_bare { // bare '-O' means '-O1', never 'take the next argument'
                        self._apply(def, def->bare_, &result);
                    } else {
                        pending = def;
                        gstate  = GlobalState::AwaitValue;
                    }

                } else { // short cluster: '-abc' = -a -b -c
                    var j: usize = 1;
                    while j < elen {
                        var ch  = elem.subslice(j, 1);
                        var def = self._find(ch);

                        if def == &null {
                            self._diag->report(DiagCode(DiagID::U002E),
                                f"unknown flag '-{ch}'; run '--help' to see available options")
                                .emit();
                            result.ok = false;
                            j += 1; continue;
                        }

                        if def->kind == FlagKind::Bool {
                            self._apply(def, "", &result);
                            j += 1;
                        } else {
                            // remaining chars are the inline value, or next element
                            if j + 1 < elen {
                                self._apply(def, elem.subslice(j + 1, elem.size()), &result);
                            } else {
                                pending = def;
                                gstate  = GlobalState::AwaitValue;
                            }
                            break;
                        }
                    }
                }

            } else if elem[0] == '/' && _IS_WINDOWS {
                if elen == 1 { i += 1; continue; }

                if elem[1] == '-' { // '/-' is invalid
                    self._diag->report(DiagCode(DiagID::U003E),
                        "'/-' is not a valid flag prefix; use '-flag', '--flag', or '/flag\x27")
                        .emit();
                    result.ok = false;
                    i += 1; continue;
                }

                if IS_LONG_FLAG[u8(elem[1])] {
                    var j: usize = 1;
                    while j < elen && elem[j] != '=' { j += 1; }
                    var name    = elem.subslice(1, j - 1);
                    var joined: string;
                    var def     = self._find_split(name, &joined);

                    if def == &null {
                        var hint = self._suggest(name);
                        var msg  = (f"unknown flag '/{name}'; did you mean '{hint}\x27; run '--help' to see available options")
                                   if (hint.length() > 0) else
                                   (f"unknown flag '/{name}'; run '--help' to see available options");
                        self._diag->report(DiagCode(DiagID::U002E), msg).emit();
                        result.ok = false;
                    } else if j < elen {
                        var evalue: string = elem.subslice(j + 1, elem.size());
                        if def->kind == FlagKind::Bool {
                            self._apply_bool_value(def, evalue, &result);
                        } else if (joined.length() > 0) && ((def->kind == FlagKind::String) || (def->kind == FlagKind::StringList) || (def->kind == FlagKind::Path)) {
                            self._apply(def, f"{joined}={evalue}", &result);
                        } else {
                            self._apply(def, evalue, &result);
                        }
                    } else if def->kind == FlagKind::Bool {
                        self._apply(def, "", &result);
                    } else if joined.length() > 0 {
                        self._apply(def, joined, &result);
                    } else if def->has_bare {
                        self._apply(def, def->bare_, &result);
                    } else {
                        pending = def;
                        gstate  = GlobalState::AwaitValue;
                    }

                } else { // '/g' '/c' short cluster
                    var j: usize = 1;
                    while j < elen {
                        var ch  = elem.subslice(j, 1);
                        var def = self._find(ch);

                        if def == &null {
                            self._diag->report(DiagCode(DiagID::U002E),
                                f"unknown flag '/{ch}\x27").emit();
                            result.ok = false;
                            j += 1; continue;
                        }

                        if def->kind == FlagKind::Bool {
                            self._apply(def, "", &result);
                            j += 1;
                        } else {
                            if j + 1 < elen {
                                self._apply(def, elem.subslice(j + 1, elem.size()), &result);
                            } else {
                                pending = def;
                                gstate  = GlobalState::AwaitValue;
                            }
                            break;
                        }
                    }
                }

            } else {
                self._push_file(&result, elem);
            }

            i += 1;
        }

        // A -x after the last input changes nothing; clang warns the same way
        // (-Wunused-command-line-argument).
        if self._tag_dirty {
            var tv = result.get_string(self._tag_key);
            self._diag->report(DiagCode(DiagID::U001W),
                f"'-x {tv}\x27 after the last input has no effect")
                .emit();
        }

        // dangling AwaitValue: ran out before the value arrived
        if gstate == GlobalState::AwaitValue && pending != &null {
            var pnm = self._flag_name(pending);
            self._diag->report(DiagCode(DiagID::U004E),
                f"flag {pnm} requires a value but none was provided")
                .emit();
            result.ok = false;
        }

        for var t: usize = 0; t < self._table.size(); ++t {
            var def = &(self._table[t]);
            if !def->default_.is_required { continue; }

            if def->kind == FlagKind::PathList {
                if result.files.size() == 0 {
                    self._diag->report(DiagCode(DiagID::U004E),
                        f"no input files ({def->help})")
                        .emit();
                    result.ok = false;
                }
            } else if !result.is_set(def->key) {
                var name = (f"--{def->long_}") if (def->long_.length() > 0)
                           else (f"-{def->short_}");
                self._diag->report(DiagCode(DiagID::U004E),
                    f"required flag '{name}' was not provided")
                    .emit();
                result.ok = false;
            }
        }

        return result;
    }

    /// \brief parse a vec::<string> as received from main's argv
    ///        args[0] is the program name and is skipped
    fn parse(self) -> ParsedArgs {
        if self._args.size() == 0 {
            self._diag->report(DiagCode(DiagID::U004E),
                "no command-line arguments were provided to Command::parse()")
                .emit();
            var result = ParsedArgs();
            result.ok = false;
            return result;
        }

        var result = self._parse_impl(self._args);
        self._warn_unimplemented(&result);
        return result;
    }
    
    /// \brief parse words that did not come from main's argv (no program
    ///        name in front): the kairo words FlagTranslator::from_driver
    ///        makes of a clang command line. Same parser, same checks.
    fn parse_words(self, words: ref!(vec::<string>)) -> ParsedArgs {
        var args: vec::<string>;
        args.push_back("kairo");
        for w: string in words { args.push_back(w); }
        var result = self._parse_impl(args);
        self._warn_unimplemented(&result);
        return result;
    }

    /// \brief split a space-separated string and parse (convenience for tests)
    fn parse_string(self, cmdline: string) -> ParsedArgs {
        var args: vec::<string>;
        args.push_back("prog"); // argv[0] placeholder

        var start: usize = 0;
        for var i: usize = 0; i <= cmdline.length(); ++i {
            var at_end = (i == cmdline.length());
            var is_sep = (!at_end) && (cmdline[i] == ' ');
            if at_end || is_sep {
                if i > start {
                    args.push_back(cmdline.subslice(start, i - start));
                }
                start = i + 1;
            }
        }

        var result = self._parse_impl(args);
        self._warn_unimplemented(&result);
        return result;
    }


    fn print_help(self) {
        var COL: usize = 36; // column where descriptions start

        var prog = ((self._args[0]) if (self._args.size() > 0) else ("prog"));

        var usage: string = f"USAGE: {prog} [options]";
        for var t: usize = 0; t < self._table.size(); ++t {
            if self._table[t].kind == FlagKind::PathList {
                usage += (" <files...>" if self._table[t].default_.is_required else " [files...]");
                break;
            }
        }
        std::print(usage);
        std::print("");
        std::print("OPTIONS:");

        for var t: usize = 0; t < self._table.size(); ++t {
            var def = &(self._table[t]);
            if def->kind == FlagKind::PathList { continue; }

            var lhs: string = "  ";

            if def->kind == FlagKind::Feature {
                // -f[no-]<key>
                lhs += f"-f[no-]{def->key}";
            } else if (def->key.length() > 2) && (def->key[0] == 'c') && (def->key[1] == ':') {
                // config flag: --c<name>=<type>
                var name = def->key.subslice(2, def->key.size());
                lhs += f"--c{name}";
                switch def->kind {
                    case FlagKind::String { lhs += "=<value>"; }
                    case FlagKind::Bool    { lhs += "=<bool>";  }
                    case FlagKind::I32 {
                        lhs += (f"=<{def->min_i}-{def->max_i}>") if def->has_bounds else "=<int>";
                    }
                    case FlagKind::F64 {
                        lhs += (f"=<{def->min_f:.2}-{def->max_f:.2}>") if def->has_bounds else "=<float>";
                    }
                    default {}
                }
            } else {
                // regular flag: -s, --long <value>
                if def->short_.length() > 0 { lhs += f"-{def->short_}"; }
                if (def->short_.length() > 0) && (def->long_.length() > 0) { lhs += ", "; }
                if def->long_.length()  > 0  { lhs += f"--{def->long_}"; }

                switch def->kind {
                    case FlagKind::String:
                    case FlagKind::Path       { lhs += " <value>";    }
                    case FlagKind::StringList { lhs += " <value>..."; }
                    case FlagKind::I32 {
                        lhs += (f" <{def->min_i}-{def->max_i}>") if def->has_bounds else " <int>";
                    }
                    case FlagKind::F64 {
                        lhs += (f" <{def->min_f:.2}-{def->max_f:.2}>") if def->has_bounds else " <float>";
                    }
                    default {}
                }
            }

            var rhs: string = def->help;
            // Many help strings already state their default ("(default: X)",
            // "-O0 (default)"); appending the rendered one printed it twice.
            var help_has_default = self._contains(def->help, "(default");
            if def->default_.is_required {
                rhs += " (required)";
            } else if !help_has_default {
                switch def->kind {
                    case FlagKind::Bool {
                        // only note if default is non-obvious (true)
                        if def->default_.as_bool() { rhs += " (default: on)"; }
                    }
                    case FlagKind::String:
                    case FlagKind::Path {
                        var dfl = def->default_.as_string();
                        if dfl.length() > 0 { rhs += f" (default: {dfl})"; }
                    }
                    case FlagKind::I32 { rhs += f" (default: {def->default_.as_i32()})";    }
                    case FlagKind::F64 { rhs += f" (default: {def->default_.as_f64():.2})"; }
                    default {} // Feature, StringList - no default shown
                }
            }
            if def->unimplemented { rhs += " [not implemented]"; }

            if lhs.length() < COL {
                while lhs.length() < COL { lhs += ' '; }
                std::print(f"{lhs}{rhs}");
            } else {
                var pad: string = "";
                while pad.length() < COL { pad += ' '; }
                std::print(lhs);
                std::print(f"{pad}{rhs}");
            }
        }

        for var t: usize = 0; t < self._table.size(); ++t {
            var def = &(self._table[t]);
            if def->kind != FlagKind::PathList { continue; }
            std::print("");
            var lhs: string = "  <files...>";
            while lhs.length() < COL { lhs += ' '; }
            std::print(f"{lhs}{def->help}{" (required)" if def->default_.is_required else " (optional)"}");
            break;
        }
    }
}



