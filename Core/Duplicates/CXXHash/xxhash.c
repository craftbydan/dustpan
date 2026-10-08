// Compiles the xxHash implementation (v0.8.4, BSD-2-Clause, see LICENSE in this folder).
// Mirrors upstream xxhash.c. Only the library is vendored; the xxhsum tool is deliberately not included.
#define XXH_STATIC_LINKING_ONLY  // access advanced declarations
#define XXH_IMPLEMENTATION       // access definitions
#include "xxhash.h"
