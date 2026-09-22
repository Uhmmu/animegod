// The slice of libarchive AnimeGod uses, declared by hand.
//
// macOS ships libarchive (`/usr/lib/libarchive.dylib`, linkable through the
// SDK's `libarchive.tbd`) but not its headers, so the declarations live
// here. They are the stable libarchive 3.x C API; the only types crossing
// the boundary are opaque pointers and fixed-width integers, so there is
// nothing here that can drift out of step with the system library.
//
// Unpacking in-process rather than shelling out to `/usr/bin/bsdtar` is not
// a matter of taste: a child process inherits the App Sandbox but not the
// security-scoped extensions the app opened for the user's download folder,
// so an external helper would be denied access to the very files it was
// asked to read.

#ifndef CLIBARCHIVE_H
#define CLIBARCHIVE_H

#include <stddef.h>
#include <stdint.h>

struct archive;
struct archive_entry;

#define AG_ARCHIVE_OK 0
#define AG_ARCHIVE_EOF 1
#define AG_ARCHIVE_WARN (-20)
#define AG_ARCHIVE_FAILED (-25)
#define AG_ARCHIVE_FATAL (-30)

// archive_write_disk option flags.
#define AG_ARCHIVE_EXTRACT_TIME 0x0004
#define AG_ARCHIVE_EXTRACT_SECURE_SYMLINKS 0x0100
#define AG_ARCHIVE_EXTRACT_SECURE_NODOTDOT 0x0200
#define AG_ARCHIVE_EXTRACT_SECURE_NOABSOLUTEPATHS 0x4000

struct archive *archive_read_new(void);
int archive_read_support_filter_all(struct archive *);
int archive_read_support_format_all(struct archive *);
int archive_read_open_filename(struct archive *, const char *filename, size_t block_size);
int archive_read_next_header(struct archive *, struct archive_entry **);
int archive_read_data_block(struct archive *, const void **buffer, size_t *size, int64_t *offset);
int archive_read_close(struct archive *);
int archive_read_free(struct archive *);

struct archive *archive_write_disk_new(void);
int archive_write_disk_set_options(struct archive *, int flags);
int archive_write_disk_set_standard_lookup(struct archive *);
int archive_write_header(struct archive *, struct archive_entry *);
int archive_write_data_block(struct archive *, const void *buffer, size_t size, int64_t offset);
int archive_write_finish_entry(struct archive *);
int archive_write_close(struct archive *);
int archive_write_free(struct archive *);

const char *archive_error_string(struct archive *);

const char *archive_entry_pathname(struct archive_entry *);
void archive_entry_set_pathname(struct archive_entry *, const char *);
int64_t archive_entry_size(struct archive_entry *);

#endif
