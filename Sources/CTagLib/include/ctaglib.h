// Minimal C interface to TagLib: the fields Harmonizer reads and writes.
#ifndef CTAGLIB_H
#define CTAGLIB_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    char title[512];
    char artist[512];
    char key[64];
    double bpm;          // 0 when absent
    double duration;     // seconds, 0 when unknown
    int ok;              // 0 = file could not be read
} ctag_info;

/// Read title, artist, initial key, BPM and duration.
ctag_info ctag_read(const char *path);

/// Write key (NULL = leave unchanged) and BPM (<= 0 = leave unchanged).
/// Returns 1 on success.
int ctag_write(const char *path, const char *key, double bpm);

#ifdef __cplusplus
}
#endif

#endif
