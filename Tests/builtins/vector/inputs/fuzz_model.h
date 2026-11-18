// The reference model for vector_fuzz_run.k: a std::vector of the keys the
// Kairo vector under test should hold, changed by the same operation each
// step.
#ifndef VECTOR_FUZZ_MODEL_H
#define VECTOR_FUZZ_MODEL_H

#include <cstddef>
#include <cstdint>
#include <vector>

inline std::vector<int64_t>& model_v() noexcept {
    static std::vector<int64_t> v;
    return v;
}

inline void model_reset() noexcept { model_v().clear(); }
inline size_t model_size() noexcept { return model_v().size(); }
inline int64_t model_at(size_t i) noexcept { return model_v()[i]; }
inline void model_push(int64_t k) noexcept { model_v().push_back(k); }

inline int64_t model_pop() noexcept {
    int64_t k = model_v().back();
    model_v().pop_back();
    return k;
}

inline void model_insert(size_t i, int64_t k) noexcept { model_v().insert(model_v().begin() + i, k); }

inline int64_t model_remove(size_t i) noexcept {
    int64_t k = model_v()[i];
    model_v().erase(model_v().begin() + i);
    return k;
}

inline int64_t model_swap_remove(size_t i) noexcept {
    int64_t k = model_v()[i];
    model_v()[i] = model_v().back();
    model_v().pop_back();
    return k;
}

inline void model_truncate(size_t n) noexcept {
    if (n < model_v().size()) model_v().resize(n);
}

inline void model_set(size_t i, int64_t k) noexcept { model_v()[i] = k; }

// Appends a copy of [lo, hi) of the vector itself.
inline void model_extend_self(size_t lo, size_t hi) noexcept {
    std::vector<int64_t> part(model_v().begin() + lo, model_v().begin() + hi);
    model_v().insert(model_v().end(), part.begin(), part.end());
}

inline void model_erase(size_t lo, size_t hi) noexcept {
    model_v().erase(model_v().begin() + lo, model_v().begin() + hi);
}

// Keeps the keys for which the retain predicate `mode` holds.
inline bool model_keep(int mode, int64_t k) noexcept {
    switch (mode) {
    case 0: return k % 3 != 0;
    case 1: return k % 2 == 0;
    case 2: return false;
    default: return true;
    }
}

inline void model_retain(int mode) noexcept {
    std::vector<int64_t> out;
    for (int64_t k : model_v())
        if (model_keep(mode, k)) out.push_back(k);
    model_v() = out;
}

inline void model_dedup() noexcept {
    std::vector<int64_t> out;
    for (int64_t k : model_v())
        if (out.empty() || out.back() != k) out.push_back(k);
    model_v() = out;
}

inline void model_resize(size_t n, int64_t k) noexcept { model_v().resize(n, k); }

#endif
