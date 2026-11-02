/* A host library built against a glibc newer than the floor: its
   VERNEED names libc.so.6 GLIBC_2.34. */
void floor_new_api(void);
int floor_probe(void) { floor_new_api(); return 7; }
