#pragma once
#include <cstdlib>
#ifdef _WIN32
inline void* olrAlignedAllocate(size_t alignment, size_t size) { return olr_windows::alignedAllocate(alignment, size); }
inline void olrAlignedRelease(void* address) { olr_windows::alignedRelease(address); }
#else
#include <fcntl.h>
inline int olrOpen(const char* path, int flags, int mode = 0) { return open(path, flags, mode); }
inline void* olrAlignedAllocate(size_t alignment, size_t size) { return aligned_alloc(alignment, size); }
inline void olrAlignedRelease(void* address) { free(address); }
#endif
