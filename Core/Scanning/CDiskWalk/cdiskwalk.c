// CDiskWalk — lists one directory with getattrlistbulk(2). Original code for Dustpan.
#include "include/cdiskwalk.h"

#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/attr.h>
#include <sys/stat.h>
#include <sys/vnode.h>
#include <unistd.h>

#define DW_BUFFER_SIZE (128 * 1024)

static _Thread_local char dw_buffer[DW_BUFFER_SIZE] __attribute__((aligned(8)));

static int dw_reserve(dw_listing *out, size_t name_bytes) {
    if (out->count == out->capacity) {
        size_t capacity = out->capacity ? out->capacity * 2 : 64;
        dw_entry *grown = realloc(out->entries, capacity * sizeof(dw_entry));
        if (!grown) return ENOMEM;
        out->entries = grown;
        out->capacity = capacity;
    }
    if (out->names_length + name_bytes > out->names_capacity) {
        size_t capacity = out->names_capacity ? out->names_capacity * 2 : 2048;
        while (capacity < out->names_length + name_bytes) capacity *= 2;
        char *grown = realloc(out->names, capacity);
        if (!grown) return ENOMEM;
        out->names = grown;
        out->names_capacity = capacity;
    }
    return 0;
}

int dw_list_directory(const char *path, dw_listing *out, int32_t *out_device) {
    out->count = 0;
    out->names_length = 0;

    int fd;
    do {
        fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    } while (fd < 0 && errno == EINTR);
    if (fd < 0) return errno;

    struct stat info;
    if (fstat(fd, &info) != 0) {
        int error = errno;
        close(fd);
        return error;
    }
    if (out_device) *out_device = (int32_t)info.st_dev;

    struct attrlist request;
    memset(&request, 0, sizeof(request));
    request.bitmapcount = ATTR_BIT_MAP_COUNT;
    request.commonattr = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_NAME | ATTR_CMN_ERROR | ATTR_CMN_DEVID
        | ATTR_CMN_OBJTYPE | ATTR_CMN_FILEID;
    request.dirattr = ATTR_DIR_MOUNTSTATUS | ATTR_DIR_ALLOCSIZE;
    request.fileattr = ATTR_FILE_LINKCOUNT | ATTR_FILE_ALLOCSIZE;

    int result = 0;
    for (;;) {
        int count = getattrlistbulk(fd, &request, dw_buffer, sizeof(dw_buffer), 0);
        if (count < 0) {
            if (errno == EINTR) continue;
            result = errno;
            break;
        }
        if (count == 0) break;

        char *const buffer_end = dw_buffer + sizeof(dw_buffer);
        char *entry = dw_buffer;
        for (int i = 0; i < count; i++) {
            char *field = entry;
            uint32_t length;
            if (entry + sizeof(uint32_t) > buffer_end) {
                result = EIO;
                break;
            }
            memcpy(&length, field, sizeof(length));
            // An entry must at least hold its length, the returned-attributes set and a name
            // reference, and must end inside the buffer.
            if (length < sizeof(uint32_t) + sizeof(attribute_set_t) + sizeof(attrreference_t)
                || length > (size_t)(buffer_end - entry)) {
                result = EIO;
                break;
            }
            field += sizeof(uint32_t);
            char *next = entry + length;

            attribute_set_t returned;
            memcpy(&returned, field, sizeof(returned));
            field += sizeof(attribute_set_t);

            uint32_t error = 0;
            if (returned.commonattr & ATTR_CMN_ERROR) {
                memcpy(&error, field, sizeof(error));
                field += sizeof(uint32_t);
            }
            const char *name = NULL;
            uint32_t name_length = 0;
            if (returned.commonattr & ATTR_CMN_NAME) {
                attrreference_t reference;
                memcpy(&reference, field, sizeof(reference));
                name = field + reference.attr_dataoffset;
                name_length = reference.attr_length > 0 ? reference.attr_length - 1 : 0;  // drop the NUL
                // The name must lie inside this entry.
                if (reference.attr_dataoffset < 0 || name < field || name + reference.attr_length > next
                    || (ptrdiff_t)reference.attr_length > next - field) {
                    name = NULL;
                    name_length = 0;
                }
                field += sizeof(attrreference_t);
            }
            if (!name || name_length == 0) {
                entry = next;
                continue;
            }

            dw_entry item;
            memset(&item, 0, sizeof(item));
            if (returned.commonattr & ATTR_CMN_DEVID) {
                dev_t device;
                memcpy(&device, field, sizeof(device));
                item.device = (int32_t)device;
                field += sizeof(dev_t);
            }
            fsobj_type_t type = VNON;
            if (returned.commonattr & ATTR_CMN_OBJTYPE) {
                memcpy(&type, field, sizeof(type));
                field += sizeof(fsobj_type_t);
            }
            if (returned.commonattr & ATTR_CMN_FILEID) {
                memcpy(&item.file_id, field, sizeof(uint64_t));
                field += sizeof(uint64_t);
            }
            if (returned.dirattr & ATTR_DIR_MOUNTSTATUS) {
                uint32_t status;
                memcpy(&status, field, sizeof(status));
                if (status & DIR_MNTSTATUS_MNTPOINT) item.flags |= DW_FLAG_MOUNTPOINT;
                field += sizeof(uint32_t);
            }
            if (returned.dirattr & ATTR_DIR_ALLOCSIZE) {
                off_t size;
                memcpy(&size, field, sizeof(size));
                item.alloc_size = size;
                field += sizeof(off_t);
            }
            if (returned.fileattr & ATTR_FILE_LINKCOUNT) {
                memcpy(&item.link_count, field, sizeof(uint32_t));
                field += sizeof(uint32_t);
            }
            if (returned.fileattr & ATTR_FILE_ALLOCSIZE) {
                off_t size;
                memcpy(&size, field, sizeof(size));
                item.alloc_size = size;
                field += sizeof(off_t);
            }
            if (field > next) {
                // Fixed-size attributes ran past the entry: skip it rather than trust it.
                entry = next;
                continue;
            }

            switch (type) {
                case VREG: item.type = DW_FILE; break;
                case VDIR: item.type = DW_DIR; break;
                case VLNK: item.type = DW_LINK; break;
                default: item.type = DW_OTHER; break;
            }
            if (error != 0) {
                item.flags |= DW_FLAG_ERROR;
                item.alloc_size = 0;
            }

            int reserve = dw_reserve(out, name_length);
            if (reserve != 0) {
                close(fd);
                return reserve;
            }
            item.name_offset = (uint32_t)out->names_length;
            item.name_length = name_length;
            memcpy(out->names + out->names_length, name, name_length);
            out->names_length += name_length;
            out->entries[out->count++] = item;
            entry = next;
        }
        if (result != 0) break;
    }
    close(fd);
    return result;
}

void dw_listing_free(dw_listing *listing) {
    free(listing->entries);
    free(listing->names);
    listing->entries = NULL;
    listing->names = NULL;
    listing->count = listing->capacity = 0;
    listing->names_length = listing->names_capacity = 0;
}
