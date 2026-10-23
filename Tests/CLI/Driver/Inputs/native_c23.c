/* `bool` is a keyword only from C23: an error under clang's default C
   standard, fine under --c-std=c23. */
bool yes(void) { return true; }
