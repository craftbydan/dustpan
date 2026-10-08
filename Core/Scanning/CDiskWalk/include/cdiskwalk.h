// CDiskWalk — lists one directory with getattrlistbulk(2). Original code for Dustpan.
#ifndef CDISKWALK_H
#define CDISKWALK_H

#include <stddef.h>
#include <stdint.h>

/// Object types reported for an entry.
enum {
    DW_OTHER = 0,
    DW_FILE = 1,
    DW_DIR = 2,
    DW_LINK = 3,
};

/// Entry flags.
enum {
    /// The directory is a mount point (another volume is mounted on it).
    DW_FLAG_MOUNTPOINT = 1,
    /// The file system reported an error for this entry; sizes are 0.
    DW_FLAG_ERROR = 2,
};

typedef struct dw_entry {
    uint64_t file_id;
    /// Allocated bytes on disk (all forks), from ATTR_FILE_ALLOCSIZE / ATTR_DIR_ALLOCSIZE.
    int64_t alloc_size;
    /// Byte offset of the name in `dw_listing.names` (UTF-8, no NUL).
    uint32_t name_offset;
    uint32_t name_length;
    uint32_t link_count;
    int32_t device;
    uint8_t type;
    uint8_t flags;
} dw_entry;

/// Growable result of one listing. Zero-initialise; reuse between calls; free with
/// `dw_listing_free`.
typedef struct dw_listing {
    dw_entry *entries;
    size_t count;
    size_t capacity;
    char *names;
    size_t names_length;
    size_t names_capacity;
} dw_listing;

/// Opens `path` with O_RDONLY | O_DIRECTORY | O_NOFOLLOW and reads every entry with
/// getattrlistbulk into `out` (cleared first) using a 128 KB per-thread buffer. Symbolic links
/// are reported, never followed. `out_device` receives the directory's own st_dev.
/// Returns 0, or an errno value (the listing may then be partial).
int dw_list_directory(const char *path, dw_listing *out, int32_t *out_device);

void dw_listing_free(dw_listing *listing);

#endif
