// ===========================================================================
//  kcc #include "foo.k" via patched Clang (FileTokenizer hook).
//
//  The patch added a third lexer-content mode to Clang: when EnterSourceFile
//  builds a Lexer for a FileID, it consults Preprocessor::FileTokenizerHook; if
//  that returns a token vector, the Lexer yields those tokens (mode
//  CLK_PrebuiltTokenLexer / Lexer::LexPrebuiltToken) instead of lexing the buffer,
//  and on exhaustion routes through HandleEndOfFile so the include stack pops
//  normally. .k includes traverse the NORMAL include path -> work inside #if,
//  mid-function, anywhere -> full PP fidelity. Locations are native into the
//  real foo.k FileID -> column-accurate, no #line, no source map, no proxy.
//
//  Both foo.cc and foo.k MUST preexist on disk:
//    foo.cc:  #include <iostream>
//             #include "foo.k"
//             int main(){ std::cout << add("2",3) << "\n"; return add(2,"10")==5?0:1; }
//
//    foo.k:   fn add(a:i32,b:i32)->i32{a+b}
// ===========================================================================

#include "clang/Basic/Diagnostic.h"
#include "clang/Basic/DiagnosticOptions.h"
#include "clang/Basic/SourceManager.h"
#include "clang/Basic/FileManager.h"
#include "clang/Basic/TargetInfo.h"
#include "clang/Basic/TokenKinds.h"
#include "clang/Frontend/CompilerInstance.h"
#include "clang/Frontend/CompilerInvocation.h"
#include "clang/Frontend/FrontendActions.h"
#include "clang/Frontend/TextDiagnosticPrinter.h"
#include "clang/Lex/Preprocessor.h"
#include "clang/Lex/Token.h"
#include "clang/CodeGen/CodeGenAction.h"

#include "llvm/Support/MemoryBuffer.h"
#include "llvm/Support/VirtualFileSystem.h"
#include "llvm/Support/TargetSelect.h"
#include "llvm/Support/raw_ostream.h"
#include "llvm/TargetParser/Host.h"
#include "llvm/Support/Program.h"
#include "lld/Common/Driver.h"

#include <memory>
#include <optional>
#include <string>
#include <vector>

LLD_HAS_DRIVER(elf)

struct SpikeState {
    bool getter_fired = false;
    unsigned add_def_offset = 0;
    clang::SourceLocation add_def_loc;
    bool add_def_loc_captured = false;
    clang::FileID kfid;
    std::vector<clang::Token> token_storage;
};

// ---------------------------------------------------------------------------
//  Build lowered Kairo tokens for a .k FileID, located into that FileID.
//  IMPORTANT: no trailing eof token, the patched Lexer::LexPrebuiltToken emits
//  eof via HandleEndOfFile when this vector is exhausted, which pops the
//  include stack the normal way. Appending an eof here would terminate the TU.
// ---------------------------------------------------------------------------
static void
build_kairo_tokens(clang::Preprocessor &pp, clang::SourceManager &sm,
                   clang::FileID fid, SpikeState *st) {
    auto loc = [&](unsigned off) {
        unsigned sz = sm.getFileIDSize(fid);
        if (off > sz) off = sz;
        return sm.getComposedLoc(fid, off);
    };
    auto &toks = st->token_storage;          // fill the OWNED vector
    toks.clear();
    auto kw = [&](clang::tok::TokenKind k, unsigned off, unsigned len) {
        clang::Token t; t.startToken();
        t.setKind(k); t.setLocation(loc(off)); t.setLength(len);
        toks.push_back(t);
    };
    auto id = [&](const char *n, unsigned off) {
        clang::Token t; t.startToken();
        t.setKind(clang::tok::identifier);
        t.setIdentifierInfo(pp.getIdentifierInfo(n));
        t.setLocation(loc(off)); t.setLength((unsigned)std::string(n).size());
        toks.push_back(t);
    };

    st->add_def_offset = 3;
    kw(clang::tok::kw_inline, 0, 2);
    kw(clang::tok::kw_int, 0, 2);
    size_t add_idx = toks.size();
    id("add", 3);
    kw(clang::tok::l_paren, 6, 1);
    kw(clang::tok::kw_int, 7, 1);
    id("a", 7);
    kw(clang::tok::comma, 12, 1);
    kw(clang::tok::kw_int, 13, 1);
    id("b", 13);
    kw(clang::tok::r_paren, 18, 1);
    kw(clang::tok::l_brace, 24, 1);
    kw(clang::tok::kw_return, 25, 1);
    id("a", 25);
    kw(clang::tok::plus, 26, 1);
    id("b", 27);
    kw(clang::tok::semi, 28, 1);
    kw(clang::tok::r_brace, 28, 1);
    // NO eof.

    st->add_def_loc = toks[add_idx].getLocation();
    st->add_def_loc_captured = true;
    st->kfid = fid;
}

class Spike : public clang::EmitObjAction {
public:
    explicit Spike(SpikeState *st) : st_(st) {}

protected:
    bool BeginSourceFileAction(clang::CompilerInstance &ci) override {
        if (!clang::EmitObjAction::BeginSourceFileAction(ci)) return false;
        clang::Preprocessor &pp = ci.getPreprocessor();
        clang::SourceManager &sm = ci.getSourceManager();
        SpikeState *st = st_;

        pp.setFileTokenizer([&pp, &sm, st](clang::FileID fid)
                -> std::optional<llvm::ArrayRef<clang::Token>> {
            llvm::StringRef name =
                sm.getBufferName(sm.getLocForStartOfFile(fid), nullptr);
            if (!name.ends_with(".k")) return std::nullopt;
            st->getter_fired = true;
            build_kairo_tokens(pp, sm, fid, st);   // fills st->token_storage
            return llvm::ArrayRef<clang::Token>(st->token_storage); // view into owned
        });
        return true;
    }

private:
    SpikeState *st_;
};

// Sysroot + resource dirs for x86_64-linux-musl (mirrors spike 1 / emit_object).
std::string sysroot  = "build/x86_64-linux-gnu/release/sys/x86_64-linux-musl";
std::string resource = "build/llvm/lib/clang/22";   // adjust: ls build/llvm/lib/clang/
std::string triple   = "x86_64-linux-musl";

std::string cxxinc = sysroot + "/include/c++/v1";
std::string resinc = resource + "/include";
std::string sysinc = sysroot + "/include";

std::vector<const char *> cc1 = {
    "-triple",            triple.c_str(),
    "-emit-obj",
    "-mrelocation-model", "pic", "-pic-level", "2",
    "-mframe-pointer=none",
    "-funwind-tables=2",
    "-mconstructor-aliases",
    "-fno-use-init-array",
    "-target-cpu",        "x86-64",
    "-nostdsysteminc",
    "-nostdinc++",
    "-resource-dir",      resource.c_str(),
    "-isystem",           cxxinc.c_str(),
    "-isystem",           resinc.c_str(),
    "-isystem",           sysinc.c_str(),
    "-isysroot",          sysroot.c_str(),
    "-internal-isystem",  resinc.c_str(),
    "-std=c++23",
    "-fcxx-exceptions", "-fexceptions",
    "-x", "c++", "foo.cc",
};

// ---------------------------------------------------------------------------
//  Link prog.o -> prog via the system linker (subprocess). Linux/ELF, host.
//  We shell out to clang++ as the link driver so it pulls the correct crt,
//  libc++/libstdc++, and libc for the host automatically, no hand-assembled
//  chain. (kcc later swaps this for in-process lld::lldMain behind the same
//  interface, once you ship lld archives.)
// ---------------------------------------------------------------------------
static bool link_musl(const std::string &obj, const std::string &exe,
                      const std::string &sysroot) {
    std::string L    = "-L" + sysroot + "/lib";
    std::string crt1 = sysroot + "/lib/crt1.o";
    std::string crti = sysroot + "/lib/crti.o";
    std::string crtn = sysroot + "/lib/crtn.o";
    std::vector<const char *> args = {
        "ld.lld", "-o", exe.c_str(), "-static",
        crt1.c_str(), crti.c_str(), obj.c_str(), L.c_str(),
        "-lc++", "-lc++abi", "-lunwind", "-lc", crtn.c_str(),
    };
    lld::Result r = lld::lldMain(args, llvm::outs(), llvm::errs(),
                                 {{lld::Gnu, &lld::elf::link}});
    return r.retCode == 0;
}

int main() {
    llvm::InitializeNativeTarget();
    llvm::InitializeNativeTargetAsmPrinter();

    clang::DiagnosticOptions diag_opts;
    auto args_vfs = llvm::vfs::getRealFileSystem();
    auto diags = clang::CompilerInstance::createDiagnostics(
        *args_vfs, diag_opts,
        new clang::TextDiagnosticPrinter(llvm::errs(), diag_opts), true);

    // No -nostdsysteminc: we WANT <iostream> to resolve from the host C++
    // toolchain's include paths. clang-as-lib needs those configured; the
    // simplest reliable way is to let the driver compute them. Since we're
    // using cc1 directly, we add the host C++ include dirs. On Arch with
    // clang, the resource dir + /usr/include + the libstdc++ paths are needed.
    // To avoid hand-wiring, we pass -isysroot / rely on defaults; if <iostream>
    // isn't found, see the note below about feeding driver-computed -internal-isystem.
    auto inv = std::make_shared<clang::CompilerInvocation>();
    if (!clang::CompilerInvocation::CreateFromArgs(*inv, cc1, *diags)) {
        llvm::errs() << "CreateFromArgs failed\n"; return 1;
    }
    auto &fe = inv->getFrontendOpts();
    fe.Inputs.clear();
    fe.Inputs.push_back(clang::FrontendInputFile(
        "foo.cc", clang::InputKind(clang::Language::CXX)));
    fe.OutputFile = "prog.o";
    fe.ProgramAction = clang::frontend::EmitObj;
    inv->getCodeGenOpts().OptimizationLevel = 0;

    clang::CompilerInstance ci(inv);
    ci.createDiagnostics(
        new clang::TextDiagnosticPrinter(llvm::errs(), diag_opts), true);
    if (!ci.hasDiagnostics()) return 1;
    ci.setTarget(clang::TargetInfo::CreateTargetInfo(
        ci.getDiagnostics(), ci.getInvocation().getTargetOpts()));
    if (!ci.hasTarget()) return 1;

    SpikeState st;
    Spike action(&st);

    llvm::outs() << "[spike] patched-clang + iostream + link\n";
    llvm::outs() << "  triple=" << triple << "\n";

    bool emitted = ci.ExecuteAction(action);
    bool compile_ok = emitted && ci.getDiagnostics().getNumErrors() == 0;

    bool precision_ok = false;
    if (st.add_def_loc_captured) {
        auto &sm = ci.getSourceManager();
        auto dec = sm.getDecomposedLoc(st.add_def_loc);
        precision_ok = (dec.first == st.kfid) && (dec.second == st.add_def_offset);
        auto ploc = sm.getPresumedLoc(st.add_def_loc);
        llvm::outs() << "  [precision] add-def -> "
                     << (precision_ok ? "OK" : "MISMATCH");
        if (ploc.isValid())
            llvm::outs() << "  (" << ploc.getFilename() << ":"
                         << ploc.getLine() << ":" << ploc.getColumn() << ")";
        llvm::outs() << "\n";
    }

    llvm::outs() << "[getter] fired=" << st.getter_fired << "\n";
    llvm::outs() << "[test1] compiles (iostream + .k): "
                 << (compile_ok ? "PASS" : "FAIL") << "\n";
    llvm::outs() << "[test2] foo.k-precision: "
                 << (precision_ok ? "PASS" : "FAIL") << "\n";

    if (!(compile_ok && st.getter_fired && precision_ok)) {
        llvm::outs() << "=== COMPILE STAGE FAILED ===\n"; return 1;
    }

    llvm::outs() << "[link] prog.o -> prog ...\n";
    bool linked = link_musl("prog.o", "prog", sysroot);
    llvm::outs() << "[test3] link-produces-binary: "
                 << (linked ? "PASS" : "FAIL") << "\n";

    llvm::outs() << "\n=== " << (linked ? "ALL PASS" : "LINK FAILED")
                 << " ===\n";
    return linked ? 0 : 1;
}