#include "cxx_math.hh"
#include "ring.k"
#include <iostream>

int main() {
    // Unbuffered: Kairo's println writes the fd directly, so a buffered
    // cout would print its lines out of order with Kairo's.
    std::cout << std::unitbuf;
    std::cout << "=== Starting C++ <-> Kairo Ping-Pong ===\n";
    {
        // 1. Instantiate Kairo generic class in C++
        ring::RingBuf<int> kb;
        kb.push(1);
        kb.push(2);
        kb.push(3);
        kb.push(4);

        // 2. Mutate Kairo object in C++ via Kairo's `op []` place operator
        kb[0] = 10;

        // 3. Pass Kairo generic class to C++20 Concept-constrained template in C++
        int cxx_sum = cxx_scale_and_sum(kb, 2);
        std::cout << "[C++] After 2x scale in C++, sum = " << cxx_sum
                  << " (kb[0] = " << kb[0] << ")\n";

        // 4. Pass C++-instantiated Kairo object into Kairo `@inout` function,
        //    which calls back into C++ templates & reference-returning methods!
        int final_score = ring::run_kairo_side(kb);
        std::cout << "[C++] Final combined score from Kairo = " << final_score << "\n";
    } // <-- kb leaves C++ scope here, triggering Kairo's `fn op delete(self)`!
    std::cout << "=== Done ===\n";
    return 0;
}