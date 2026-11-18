#include "packet_whole.k"
#include <concepts>
#include <iostream>

template <typename B>
concept ScorableBatch = requires(B& b, const B& cb) {
    { cb.score() } -> std::same_as<int>;
    { b[0] }; // Kairo place operator `op [] -> *Frame<i32>` maps to C++ `Frame<int>&`!
};

template <ScorableBatch B>
int run_from_cxx(B& b) {
    b[0] = packet_whole::make_burst(20, 4); // Mutate Kairo ADT in-place from C++ through `op []`!
    return b.score() + packet_whole::sum_burst(b[0]);
}

int main() {
    std::cout << std::unitbuf;
    packet_whole::Batch batch(10, 204); // Instantiates Kairo class holding Kairo ADT & Nullable `i32?`
    std::cout << "[C++] Total = " << run_from_cxx(batch) << "\n";
} // <-- `batch` leaves C++ scope here, firing Kairo's `fn op delete(self)`!