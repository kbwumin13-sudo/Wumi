#ifndef MIJI_NAMES_H
#define MIJI_NAMES_H
#include "coilfind.h"

/* Miji adapter: literal AND/NOT terms, matching all three compact name columns.
 * Call with bounded chunks so cancellation and memory use stay bounded.
 * aliases bits: 1 = ASCII (alternate keys only match ascii_key terms),
 * 2 = full matches reuse name, 4 = initials reuses name, 8 = initials reuses full,
 * 16 = long ASCII full key verified in-place only after a literal miss.
 * Reused keys occupy no bytes in their respective alternate columns. */
typedef struct {
    const uint8_t *needle;
    size_t length;
    int excluded;
    int ascii_key;
} MijiNameTerm;
size_t miji_match_names(const uint8_t *names, const uint32_t *name_off,
                        const uint8_t *full, const uint32_t *full_off,
                        const uint8_t *initials, const uint32_t *initial_off,
                        const uint8_t *live,
                        const uint8_t *aliases,
                        uint32_t first, uint32_t end,
                        const MijiNameTerm *terms, size_t term_count,
                        uint32_t *ids, int32_t *scores);
/* Synchronous scan, at most four 8192-row lanes. Caller owns output buffers
 * sized for end-first rows. Results remain in ascending row order. No callbacks
 * or cancellation checks run on the dispatch workers. Larger ranges fall back
 * to the serial scan; CompactNameIndex always passes at most 32768 rows. */
size_t miji_match_names_batch(const uint8_t *names, const uint32_t *name_off,
                              const uint8_t *full, const uint32_t *full_off,
                              const uint8_t *initials, const uint32_t *initial_off,
                              const uint8_t *live, const uint8_t *aliases,
                              uint32_t first, uint32_t end,
                              const MijiNameTerm *terms, size_t term_count,
                              uint32_t *ids, int32_t *scores);
#endif
