#include <array>
#include <iostream>
#include <string>
#include <vector>
#include <array>

// header-only
#pragma once
#include <cstdint>
#include <vector>
#include <string>
#include <sstream>

namespace hx {

struct SrcLoc {
    const char* file;     // emitted as literal by codegen
    uint32_t    line;     // source line
    const char* func;     // emitted as literal by codegen (mangled is fine)
};

// One node per active Helix frame, linked via thread-local head pointer.
struct HelixFrame {
    const SrcLoc* loc;
    const HelixFrame* prev;
};

inline thread_local const HelixFrame* g_tls_helix_head = nullptr;

// RAII scope to push/pop a frame for the current function activation.
struct HelixFrameScope {
    HelixFrame frame;
    explicit HelixFrameScope(const SrcLoc* loc) noexcept {
        frame = {loc, g_tls_helix_head};
        g_tls_helix_head = &frame;
    }
    ~HelixFrameScope() {
        g_tls_helix_head = frame.prev;
    }
};

// Macro your codegen inserts at function entry.
#define TRACE \
    static constexpr ::hx::SrcLoc _hx_loc{__FILE__, static_cast<uint32_t>(__LINE__), __PRETTY_FUNCTION__}; \
    ::hx::HelixFrameScope _hx_scope(&_hx_loc);

// Snapshot current Helix-only backtrace (top-most first).
inline std::vector<SrcLoc> helix_backtrace() {
    std::vector<SrcLoc> out;
    for (const HelixFrame* n = g_tls_helix_head; n; n = n->prev) {
        if (n->loc) out.push_back(*n->loc);
    }
    return out;
}

// Pretty-print helper (optional).
inline std::string format_helix_backtrace(const std::vector<SrcLoc>& frames) {
    std::ostringstream os;
    os << "Helix frames (most recent call first):\n";
    for (size_t i = 0; i < frames.size(); ++i) {
        const auto& f = frames[i];
        os << "  " << i << ") " << (f.func ? f.func : "?") << "\n";
        if (f.file && f.line) {
            os << "     at " << f.file << ":" << f.line << "\n";
        }
    }
    return os.str();
}

} // namespace hx

void bar() { TRACE
    std::cout << "In bar function" << std::endl;

    auto frames = hx::helix_backtrace();
    std::cout << hx::format_helix_backtrace(frames) << std::endl;

    std::cout << "Exiting bar function" << std::endl;
}

void foo() { TRACE
    std::cout << "In foo function" << std::endl;
    bar();

    std::cout << "Exiting foo function" << std::endl;
}

int main() { TRACE
    foo();
    auto frames = hx::helix_backtrace();
    std::cout << hx::format_helix_backtrace(frames) << std::endl;
    return 0;
}


/// ADD THIS  only in debug else nothinh