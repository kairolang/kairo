// Iterator chain rows (ops.toml, group "iter"): C++20 <ranges>, and beside
// each chain the loop a person would write by hand (`_loop`).
#include "bench.h"

#include <algorithm>
#include <iterator>
#include <ranges>
#include <vector>

namespace views = std::views;

// Function objects, not functions: a view stores what it is given, and a
// stored function pointer is called through, where a stored lambda inlines.
constexpr auto triple = [](int32_t x) { return x * 3; };
constexpr auto is_even = [](int32_t x) { return (x & 1) == 0; };
constexpr auto not_sentinel = [](int32_t x) { return x != 5000; };

// Values in [-1000, 1000]: no sum below leaves i32.
static std::vector<int32_t> input(uint64_t n) {
    BenchRng rng;
    std::vector<int32_t> v(n);
    for (int32_t& x : v) x = static_cast<int32_t>(rng.below(2001)) - 1000;
    return v;
}

enum Chain { MapFilterSum, EnumerateTake, RevTakeWhile, CollectMap };

static uint64_t chain(Chain which, const std::vector<int32_t>& v) {
    switch (which) {
    case MapFilterSum: {
        int32_t sum = 0;
        for (int32_t x : v | views::transform(triple) | views::filter(is_even)) sum += x;
        return static_cast<uint64_t>(static_cast<int64_t>(sum));
    }
    case EnumerateTake: {
        // C++20 has no views::enumerate; an index range is its spelling.
        int64_t sum = 0;
        for (size_t i : views::iota(size_t{0}, v.size()) | views::take(v.size() / 2))
            sum += static_cast<int64_t>(i) * v[i];
        return static_cast<uint64_t>(sum);
    }
    case RevTakeWhile:
        return static_cast<uint64_t>(std::ranges::distance(v | views::reverse | views::take_while(not_sentinel)));
    case CollectMap: {
        // A transform_view is an input range to the vector's iterator-pair
        // constructor, so the single allocation is asked for by hand.
        std::vector<int32_t> out;
        out.reserve(v.size());
        std::ranges::copy(v | views::transform(triple), std::back_inserter(out));
        bench_sink_ptr(out.data());
        return out.size() + static_cast<uint64_t>(static_cast<int64_t>(out[out.size() - 1]));
    }
    }
    return 0;
}

static uint64_t loop(Chain which, const std::vector<int32_t>& v) {
    const size_t n = v.size();
    switch (which) {
    case MapFilterSum: {
        int32_t sum = 0;
        for (size_t i = 0; i < n; ++i) {
            int32_t x = v[i] * 3;
            if ((x & 1) == 0) sum += x;
        }
        return static_cast<uint64_t>(static_cast<int64_t>(sum));
    }
    case EnumerateTake: {
        int64_t sum = 0;
        for (size_t i = 0; i < n / 2; ++i) sum += static_cast<int64_t>(i) * v[i];
        return static_cast<uint64_t>(sum);
    }
    case RevTakeWhile: {
        size_t i = n;
        while (i != 0 && v[i - 1] != 5000) --i;
        return n - i;
    }
    case CollectMap: {
        std::vector<int32_t> out;
        out.reserve(n);
        for (size_t i = 0; i < n; ++i) out.push_back(v[i] * 3);
        bench_sink_ptr(out.data());
        return out.size() + static_cast<uint64_t>(static_cast<int64_t>(out[n - 1]));
    }
    }
    return 0;
}

static void run(Chain which, bool by_hand, uint64_t n) {
    const uint64_t passes = (1ull << 22) / n;
    std::vector<int32_t> v = input(n);
    bench_begin((which == EnumerateTake ? n / 2 : n) * passes);
    while (bench_next()) {
        uint64_t acc = 0;
        bench_tic();
        for (uint64_t p = 0; p < passes; ++p) {
            bench_sink_ptr(v.data());
            acc += by_hand ? loop(which, v) : chain(which, v);
        }
        bench_toc(acc);
    }
    bench_end();
}

int main(int argc, char** argv) {
    bench_init(argc, argv);
    for (uint64_t n : {1000, 1000000}) {
        if (bench_want("iter.map_filter_sum", n)) run(MapFilterSum, false, n);
        if (bench_want("iter.map_filter_sum_loop", n)) run(MapFilterSum, true, n);
        if (bench_want("iter.enumerate_take", n)) run(EnumerateTake, false, n);
        if (bench_want("iter.enumerate_take_loop", n)) run(EnumerateTake, true, n);
        if (bench_want("iter.rev_take_while_count", n)) run(RevTakeWhile, false, n);
        if (bench_want("iter.rev_take_while_count_loop", n)) run(RevTakeWhile, true, n);
        if (bench_want("iter.collect_map", n)) run(CollectMap, false, n);
        if (bench_want("iter.collect_map_loop", n)) run(CollectMap, true, n);
    }
    return 0;
}
