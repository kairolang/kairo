/* A C struct with bit-fields, for bitfield.k: no reference binds one. */
struct Bits { int s : 5; unsigned u : 3; };
static inline struct Bits *pass_bits(struct Bits *b) { return b; }
