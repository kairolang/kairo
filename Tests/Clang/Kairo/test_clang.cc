#include <clang/Lex/PreprocessorOptions.h>
#include "clang/Basic/Diagnostic.h"
#include "clang/Basic/DiagnosticOptions.h"
#include "clang/Basic/SourceManager.h"
#include "clang/Basic/FileManager.h"
#include "clang/Basic/TargetInfo.h"
#include "clang/Basic/TargetOptions.h"
#include "clang/Basic/TokenKinds.h"
#include "clang/Basic/LangStandard.h"
#include "clang/Lex/HeaderSearchOptions.h"
#include "clang/Lex/Preprocessor.h"
#include "clang/Lex/Token.h"
#include "clang/Frontend/CompilerInstance.h"
#include "clang/Frontend/CompilerInvocation.h"
#include "clang/Frontend/FrontendActions.h"
#include "clang/Frontend/TextDiagnosticPrinter.h"
#include "clang/CodeGen/CodeGenAction.h"
#include "lld/Common/Driver.h"

#include "llvm/Support/MemoryBuffer.h"
#include "llvm/Support/VirtualFileSystem.h"
#include "llvm/Support/TargetSelect.h"
#include "llvm/Support/raw_ostream.h"
#include "llvm/TargetParser/Host.h"

#include <functional>
#include <fstream>
#include <string>
#include <vector>
#include <unordered_map>
#include <memory>

#include "toml.hpp"

struct SysrootConfig {
    std::string triple, sysroot_path, resource;
    bool static_link = true;
    std::vector<std::string> include_dirs, lib_dirs;
    std::vector<std::string> crt_startup, crt_end;
    std::vector<std::string> libc_link, libcxx_link;
    std::vector<std::string> cc_isolation;
    std::string rtlib, unwindlib, linker, resource_dir_rel;
};

static SysrootConfig load_sysroot(const std::string &sysroot_dir) {
    auto toml_path = sysroot_dir + "/SYSROOT.toml";
    toml::table t = toml::parse_file(toml_path);   // throws on parse error

    SysrootConfig c;
    c.sysroot_path = sysroot_dir;
    c.triple       = t["triple"].value_or("");
    c.static_link  = t["static"].value_or(true);
    c.rtlib        = t["rtlib"].value_or("");
    c.unwindlib    = t["unwindlib"].value_or("");
    c.linker       = t["linker"].value_or("lld");
    c.resource_dir_rel = t["resource_dir"].value_or("");

    auto arr = [&](const char *key, std::vector<std::string> &out) {
        if (auto a = t[key].as_array())
            for (auto &el : *a)
                if (auto s = el.value<std::string>()) out.push_back(*s);
    };
    arr("include_dirs", c.include_dirs);
    arr("lib_dirs",     c.lib_dirs);
    arr("crt_startup",  c.crt_startup);
    arr("crt_end",      c.crt_end);
    arr("libc_link",    c.libc_link);
    arr("libcxx_link",  c.libcxx_link);
    arr("cc_isolation", c.cc_isolation);
    return c;
}

LLD_HAS_DRIVER(elf)
LLD_HAS_DRIVER(mingw)

// ===========================================================================
//  Arena: owns canonical C++ spellings for divergent literals, deduped.
//  One MemoryBuffer registered as a FileID; entries concatenated into `text`.
//  Must outlive the parse — owned by the Action.
// ===========================================================================
struct LiteralArena {
    std::string text;                              // concatenated C++ spellings
    std::unordered_map<std::string, unsigned> dedup; // spelling -> offset in text
    clang::FileID fid;                             // set once registered
    clang::SourceManager *sm = nullptr;

    // Intern a canonical C++ spelling; returns (offset, length) into the arena.
    // Dedups so repeated values share one slot. NOTE: this appends to `text`
    // BEFORE the buffer is registered, so call only during the build phase
    // (we register the buffer after the builder runs — see Action).
    std::pair<unsigned, unsigned> intern(const std::string &cxx_spelling) {
        auto it = dedup.find(cxx_spelling);
        if (it != dedup.end())
            return {it->second, (unsigned)cxx_spelling.size()};
        unsigned off = (unsigned)text.size();
        text += cxx_spelling;
        dedup.emplace(cxx_spelling, off);
        return {off, (unsigned)cxx_spelling.size()};
    }
};

// ===========================================================================
//  Token-builder context. Borrowed-loc helpers (punct/id/str_lit/num) plus
//  the divergent-literal arena helpers (num_arena/str_arena).
// ===========================================================================
struct TokenBuildCtx {
    clang::Preprocessor &pp;
    clang::SourceManager &sm;
    clang::FileID kfid;
    LiteralArena &arena;
    std::vector<clang::Token> &out;

    clang::SourceLocation kloc(unsigned off) const {
        unsigned size = sm.getFileIDSize(kfid);
        if (size == 0) size = 1;
        if (off >= size) off = size - 1;
        return sm.getComposedLoc(kfid, off);
    }

    void punct(clang::tok::TokenKind k, unsigned off, unsigned len) {
        clang::Token t; t.startToken();
        t.setKind(k); t.setLocation(kloc(off)); t.setLength(len);
        out.push_back(t);
    }
    void id(const char *name, unsigned off) {
        clang::Token t; t.startToken();
        t.setKind(clang::tok::identifier);
        t.setIdentifierInfo(pp.getIdentifierInfo(name));
        t.setLocation(kloc(off)); t.setLength((unsigned)std::string(name).size());
        out.push_back(t);
    }
    // Text-identical literal: borrow .kro loc, parse from real source bytes.
    void str_lit(const char *spelling_with_quotes, unsigned off) {
        clang::Token t; t.startToken();
        t.setKind(clang::tok::string_literal);
        pp.CreateString(spelling_with_quotes, t, kloc(off), kloc(off));
        out.push_back(t);
    }
    void num(const char *spelling, unsigned off) {
        clang::Token t; t.startToken();
        t.setKind(clang::tok::numeric_constant);
        pp.CreateString(spelling, t, kloc(off), kloc(off));
        out.push_back(t);
    }

    // --- Divergent-literal helpers (arena spelling, .kro expansion loc) ---
    // These DEFER the SourceLocation construction: we record the arena offset
    // and the .kro span now, but the arena FileID isn't registered until after
    // the builder finishes (so the buffer is contiguous). The Action patches
    // the real locations in a second pass. We stash that intent here.
    struct PendingArenaTok {
        size_t tok_index;       // index into `out`
        unsigned arena_off;     // offset into arena.text
        unsigned arena_len;     // length of the C++ spelling
        unsigned kro_off;       // .kro expansion start
        unsigned kro_len;       // .kro span length
    };
    std::vector<PendingArenaTok> *pending = nullptr;

    // Kairo numeric with separators/suffix -> canonical C++ value text.
    // cxx_value e.g. "1000000" for Kairo "1_000_000"; kro_off/len locate the
    // ORIGINAL Kairo literal for diagnostics.
    void num_arena(const std::string &cxx_value,
                   unsigned kro_off, unsigned kro_len) {
        auto [aoff, alen] = arena.intern(cxx_value);
        clang::Token t; t.startToken();
        t.setKind(clang::tok::numeric_constant);
        // location patched later; placeholder for now
        t.setLength(alen);
        out.push_back(t);
        pending->push_back({out.size() - 1, aoff, alen, kro_off, kro_len});
    }
    // Kairo string whose C++ spelling diverges (prefix/suffix lowering).
    // cxx_spelling INCLUDES quotes, e.g. "\"foo %i32%\"".
    void str_arena(const std::string &cxx_spelling,
                   unsigned kro_off, unsigned kro_len) {
        auto [aoff, alen] = arena.intern(cxx_spelling);
        clang::Token t; t.startToken();
        t.setKind(clang::tok::string_literal);
        t.setLength(alen);
        out.push_back(t);
        pending->push_back({out.size() - 1, aoff, alen, kro_off, kro_len});
    }

    void eof(unsigned off) {
        clang::Token t; t.startToken();
        t.setKind(clang::tok::eof); t.setLocation(kloc(off)); t.setLength(0);
        out.push_back(t);
    }
};

using TokenBuilder = std::function<void(TokenBuildCtx &)>;

// ===========================================================================
//  Driver: source string + filename + -o output -> executable.
// ===========================================================================
class KairoDriver {
public:
    struct Config {
        std::string sysroot   = "build/x86_64-linux-gnu/release/sys/x86_64-linux-musl";
        std::string resource  = "build/llvm/lib/clang/22";
        std::string triple    = "x86_64-linux-musl";
        std::vector<std::string> includes = {"iostream"};
    };

    KairoDriver(Config cfg) : cfg_(std::move(cfg)) {}

    // Full pipeline: write .kro, inject -> codegen -> link -> executable at -o.
    bool build(const std::string &kairo_filename,
               const std::string &kairo_source,
               const std::string &out_exe,
               TokenBuilder builder) {
        // 1. Materialize the .kro.
        {
            std::ofstream f(kairo_filename, std::ios::binary | std::ios::trunc);
            if (!f) { llvm::errs() << "cannot write " << kairo_filename << "\n"; return false; }
            f << kairo_source;
        }

        std::string obj = out_exe + ".o";
        if (!emit_object(kairo_filename, obj, std::move(builder))) {
            llvm::errs() << "codegen failed\n"; return false;
        }
        if (!link(obj, out_exe)) {
            llvm::errs() << "link failed\n"; return false;
        }
        return true;
    }

private:
    Config cfg_;

    class Action : public clang::EmitObjAction {
    public:
        Action(std::string kf, TokenBuilder b)
            : kfile_(std::move(kf)), builder_(std::move(b)) {}
    protected:
        bool BeginSourceFileAction(clang::CompilerInstance &ci) override {
            if (!clang::EmitObjAction::BeginSourceFileAction(ci)) return false;

            clang::Preprocessor &pp = ci.getPreprocessor();
            clang::SourceManager &sm = ci.getSourceManager();

            auto fref = ci.getFileManager().getFileRef(kfile_, true);
            if (!fref) { llvm::errs() << "cannot open " << kfile_ << "\n"; return false; }
            clang::FileID kfid = sm.createFileID(
                *fref, clang::SourceLocation(), clang::SrcMgr::C_User);

            // Build tokens. Arena text accumulates during the builder; arena
            // FileID is registered AFTER, then pending locations are patched.
            arena_.sm = &sm;
            std::vector<TokenBuildCtx::PendingArenaTok> pending;
            std::vector<clang::Token> toks;
            TokenBuildCtx ctx{.pp=pp, .sm=sm, .kfid=kfid, .arena=arena_, .out=toks};
            ctx.pending = &pending;
            builder_(ctx);

            // Register the now-complete arena buffer as a FileID. It must
            // outlive the parse, so arena_.text (a member) stays alive.
            clang::FileID afid;
            if (!arena_.text.empty()) {
                auto buf = llvm::MemoryBuffer::getMemBuffer(
                    arena_.text, "<kairo-literals>", /*RequiresNullTerminator=*/false);
                afid = sm.createFileID(std::move(buf), clang::SrcMgr::C_User);
            }

            // Second pass: patch arena-token locations now that afid exists.
            auto kloc = [&](unsigned off) {
                unsigned sz = sm.getFileIDSize(kfid);
                if (off >= sz) off = sz ? sz - 1 : 0;
                return sm.getComposedLoc(kfid, off);
            };
            for (auto &p : pending) {
                clang::SourceLocation spelling = sm.getComposedLoc(afid, p.arena_off);
                clang::SourceLocation loc = sm.createExpansionLoc(
                    spelling,
                    kloc(p.kro_off),
                    kloc(p.kro_off + p.kro_len),
                    p.arena_len,            // length in ARENA spelling
                    /*ExpansionIsTokenRange=*/true);
                toks[p.tok_index].setLocation(loc);
                toks[p.tok_index].setLength(p.arena_len);
            }

            auto arr = std::make_unique<clang::Token[]>(toks.size());
            for (size_t i = 0; i < toks.size(); ++i) arr[i] = toks[i];
            pp.EnterTokenStream(std::move(arr), toks.size(), true, false);
            return true;
        }
    private:
        std::string kfile_;
        TokenBuilder builder_;
        LiteralArena arena_;   // owns arena text for the parse's lifetime
    };

    bool emit_object(const std::string &kfile, const std::string &obj,
                 TokenBuilder builder) {
        llvm::InitializeNativeTarget();
        llvm::InitializeNativeTargetAsmPrinter();

        auto vfs = llvm::vfs::getRealFileSystem();
        clang::DiagnosticOptions diag_opts;

        // Diagnostics engine first — CreateFromArgs needs one to parse the args.
        auto diags = clang::CompilerInstance::createDiagnostics(
            *vfs, diag_opts,
            new clang::TextDiagnosticPrinter(llvm::errs(), diag_opts),
            /*ShouldOwnClient=*/true);

        // Derived paths from the config.
        std::string cxxinc  = cfg_.sysroot + "/include/c++/v1";
        std::string resinc  = cfg_.resource + "/include";
        std::string sysinc  = cfg_.sysroot + "/include";

        // cc1 args matching what `clang --target=<triple> ... -###` emits for this
        // sysroot. This is the byte-identical-to-driver path: target setup,
        // predefines, header search, and (Windows) SEH exception model all come
        // from here instead of hand-set LangOptions/HeaderSearchOpts fields.
        std::vector<const char *> cc1 = {
            "-triple",            cfg_.triple.c_str(),
            "-emit-obj",
            "-mrelocation-model", "pic", "-pic-level", "2",
            "-mframe-pointer=none",
            "-funwind-tables=2",
            "-mconstructor-aliases",
            "-fno-use-init-array",
            "-fno-sized-deallocation",
            "-fno-use-cxa-atexit",
            "-target-cpu",        "x86-64",
            "-nostdsysteminc",    // == -nostdlibinc (cc1 spelling)
            "-nostdinc++",
            "-resource-dir",      cfg_.resource.c_str(),
            "-isystem",           cxxinc.c_str(),
            "-isystem",           resinc.c_str(),
            "-isystem",           sysinc.c_str(),
            "-isysroot",          cfg_.sysroot.c_str(),
            "-internal-isystem",  resinc.c_str(),   // builtin <stdint.h> -> uintptr_t
            "-std=c++23",
            "-fgnuc-version=4.2.1",
            "-fcxx-exceptions", "-fexceptions", "-exception-model=seh",
            "-x", "c++", "<injected>",
        };

        auto inv = std::make_shared<clang::CompilerInvocation>();
        if (!clang::CompilerInvocation::CreateFromArgs(*inv, cc1, *diags)) {
            llvm::errs() << "CreateFromArgs failed\n";
            return false;
        }

        // CreateFromArgs set up a file input named "<injected>" that isn't on disk
        // and a default action; override with our in-memory buffer + EmitObj.
        auto &fe = inv->getFrontendOpts();
        static const char *empty = "";
        auto mainbuf = llvm::MemoryBuffer::getMemBuffer(empty, "<injected>");
        fe.Inputs.clear();
        fe.Inputs.push_back(clang::FrontendInputFile(
            mainbuf->getMemBufferRef(), clang::InputKind(clang::Language::CXX)));
        fe.OutputFile = obj;
        fe.ProgramAction = clang::frontend::EmitObj;

        // The actual #include <iostream> via the predefines buffer (-include form).
        for (auto &inc : cfg_.includes)
            inv->getPreprocessorOpts().Includes.push_back(inc);

        inv->getCodeGenOpts().OptimizationLevel = 0;

        clang::CompilerInstance ci(inv);
        ci.setVirtualFileSystem(vfs);
        ci.createDiagnostics(
            new clang::TextDiagnosticPrinter(llvm::errs(), diag_opts),
            /*ShouldOwnClient=*/true);
        if (!ci.hasDiagnostics()) return false;

        llvm::errs() << "target triple = " << inv->getTargetOpts().Triple << "\n";
        ci.setTarget(clang::TargetInfo::CreateTargetInfo(
            ci.getDiagnostics(), ci.getInvocation().getTargetOpts()));
        llvm::errs() << "TargetInfo triple = " << ci.getTarget().getTriple().str() << "\n";
        if (!ci.hasTarget()) return false;
        ci.getTarget().adjust(ci.getDiagnostics(), ci.getLangOpts(), nullptr);

        Action action(kfile, std::move(builder));
        bool ok = ci.ExecuteAction(action);
        llvm::outs() << "[driver] errors=" << ci.getDiagnostics().getNumErrors()
                    << " emitted_object=" << (ok ? "yes" : "no") << "\n";
        return ok;
    }
    bool link(const std::string &obj, const std::string &exe) {
        std::string L    = "-L" + cfg_.sysroot + "/lib";
        std::string crt1 = cfg_.sysroot + "/lib/crt1.o";
        std::string crti = cfg_.sysroot + "/lib/crti.o";
        std::string crtn = cfg_.sysroot + "/lib/crtn.o";
        std::vector<const char *> args = {
            "ld.lld", "-o", exe.c_str(), "-static",
            crt1.c_str(), crti.c_str(), obj.c_str(), L.c_str(),
            "-lc++", "-lc++abi", "-lunwind", "-lc", crtn.c_str(),
        };
        lld::Result r = lld::lldMain(args, llvm::outs(), llvm::errs(),
                                     {{lld::Gnu, &lld::elf::link}});
        return r.retCode == 0;
    }
    // bool link(const std::string &obj, const std::string &exe) {
    //     SysrootConfig sc = load_sysroot(cfg_.sysroot);
    //     std::string L = "-L" + cfg_.sysroot + "/lib";

    //     // manual for now — the one thing not cleanly in the TOML
    //     std::string builtins = cfg_.sysroot + "/compiler-rt/lib/windows/libclang_rt.builtins-x86_64.a";

    //     std::vector<std::string> owned;   // keep strings alive for c_str()
    //     std::vector<const char*> args;
    //     auto push = [&](const std::string &s){ owned.push_back(s); };

    //     push("ld.lld"); push("-m"); push("i386pep"); push("-o"); push(exe);
    //     if (sc.static_link) push("-static");
    //     for (auto &o : sc.crt_startup) push(cfg_.sysroot + "/lib/" + o);
    //     push(obj);
    //     push(L);
    //     for (auto &l : sc.libcxx_link) push(l);   // -lc++ -lunwind  (from TOML)
    //     for (auto &l : sc.libc_link)   push(l);   // mingw chain     (from TOML)
    //     push(builtins);
    //     for (auto &o : sc.crt_end) push(cfg_.sysroot + "/lib/" + o);

    //     for (auto &s : owned) args.push_back(s.c_str());   // build after owned is stable

    //     lld::Result r = lld::lldMain(args, llvm::outs(), llvm::errs(),
    //                                 {{.f=lld::MinGW, .d=&lld::mingw::link}});
    //     return r.retCode == 0;
    // }
};

// ===========================================================================
//  Example: hello world with a divergent numeric literal, linked to a binary.
// ===========================================================================
int main(int argc, char **argv) {
    std::string out_exe = "prog";
    for (int i = 1; i < argc - 1; ++i)
        if (std::string(argv[i]) == "-o") out_exe = argv[i + 1];

    KairoDriver driver{KairoDriver::Config{
        .sysroot   = "/home/dhruvan/linux-dev/sysroots/staging/x86_64-linux-musl",
        .resource  = "build/llvm/lib/clang/22",
        .triple    = "x86_64-linux-musl",
        .includes = {"iostream"}
    }};

    // Kairo: fn main() -> i32 { std::cout << 1_000_000; return 0 }
    // The 1_000_000 is a divergent literal -> arena "1000000".
    std::string src =
        "fn main() -> i32 {\n"
        "    std::cout << 1_000_000 << \"\\n\"\n"
        "    return 0\n"
        "}\n";

    bool ok = driver.build("prog.k", src, out_exe, [](TokenBuildCtx &c) {
        c.punct(clang::tok::kw_int, 0, 3);
        c.id("main", 3);
        c.punct(clang::tok::l_paren, 7, 1);
        c.punct(clang::tok::r_paren, 8, 1);
        c.punct(clang::tok::l_brace, 17, 1);
        c.id("std", 23);
        c.punct(clang::tok::coloncolon, 26, 2);
        c.id("cout", 28);
        c.punct(clang::tok::lessless, 33, 2);
        // divergent numeric: Kairo "1_000_000" at offset 36, len 9 -> C++ "1000000"
        c.num_arena("1000000", 36, 9);
        c.punct(clang::tok::lessless, 33, 2);
        c.str_lit("\"\\n\"", 45);
        c.punct(clang::tok::semi, 45, 1);
        c.punct(clang::tok::kw_return, 51, 6);
        c.str_lit("\"0\"", 58);
        c.punct(clang::tok::semi, 59, 1);
        c.punct(clang::tok::r_brace, 61, 1);
        c.eof(62);
    });

    if (!ok) return 1;
    llvm::outs() << "built " << out_exe << "\n";
    return 0;
}