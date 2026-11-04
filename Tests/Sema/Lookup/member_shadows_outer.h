// Corpus for member_shadows_outer.k: free C functions whose names collide with
// methods of the Kairo class that calls them.
#pragma once
int ext_open(const char *path);
int ext_close(int fd);
