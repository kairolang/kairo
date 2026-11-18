/* A stand-in for an object the Kairo compiler wrote: the ABI note's eight
   bytes (magic, format 1, the calling-convention bitset, the LLVM major),
   with the major and the bitset chosen by the test. kld finds the record
   by its bytes, so the section it sits in does not matter. */
__attribute__((used)) static const unsigned char kairo_abi_note[8] = {
    0x7f, 'K', 'A', 'B', 'I', 1, BITS, MAJOR
};
int FN(void) { return kairo_abi_note[7]; }
