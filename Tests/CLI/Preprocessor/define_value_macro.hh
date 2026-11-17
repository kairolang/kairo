#ifdef MODE
inline int header_saw_mode() { return 1; }
#else
inline int header_saw_mode() { return 0; }
#endif
