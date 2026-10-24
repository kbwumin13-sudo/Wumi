#include "miji_names.h"
#include <string.h>
#include <dispatch/dispatch.h>

static int word_byte(uint8_t c) { return (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9'); }
/* Only used for long ASCII full keys after a literal miss. memchr skips whole
 * noncandidate spans; no initials are derived and no key is materialized. */
static int ascii_full_contains(const uint8_t *name, size_t len, const MijiNameTerm *t) {
    if (!t->length) {
        for (size_t i = 0; i < len; i++) if (word_byte(name[i])) return 1;
        return 0;
    }
    /* Necessary-byte probes cheaply reject common long-name misses before
     * walking candidates (e.g. rnt without n, shuxue without h). */
    if (t->length > 1 && !memchr(name, t->needle[1], len)) return 0;
    if (t->length > 3 && !memchr(name, t->needle[t->length / 2], len)) return 0;
    const uint8_t *end = name + len, *candidate = name;
    while ((size_t)(end - candidate) >= t->length) {
        candidate = memchr(candidate, t->needle[0], (size_t)(end - candidate));
        if (!candidate) return 0;
        const uint8_t *p = candidate + 1;
        size_t j = 1;
        while (p < end && j < t->length) {
            if (word_byte(*p)) {
                if (*p != t->needle[j]) break;
                j++;
            }
            p++;
        }
        if (j == t->length) return 1;
        candidate++;
    }
    return 0;
}

size_t miji_match_names(const uint8_t *names, const uint32_t *name_off,
                        const uint8_t *full, const uint32_t *full_off,
                        const uint8_t *initials, const uint32_t *initial_off,
                        const uint8_t *live,
                        const uint8_t *aliases,
                        uint32_t first, uint32_t end,
                        const MijiNameTerm *terms, size_t term_count,
                        uint32_t *ids, int32_t *scores) {
    size_t count = 0;
    for (uint32_t i = first; i < end; i++) {
        if (!live[i]) continue;
        int32_t score = 0;
        int accepted = 1;
        for (size_t j = 0; j < term_count; j++) {
            const MijiNameTerm *t = &terms[j];
            int a = sift_contains(names + name_off[i], name_off[i+1] - name_off[i], t->needle, t->length, 1);
            if (t->excluded && a) { accepted = 0; break; }
            size_t full_len = aliases[i] & 18 ? name_off[i+1] - name_off[i] : full_off[i+1] - full_off[i];
            /* ASCII aliases contain only lowercase letters/digits. An empty
             * needle historically matches them only if there is a word. */
            int keys = !(aliases[i] & 1) || (t->ascii_key && (t->length || full_len));
            int b = keys && (aliases[i] & 2 ? a : aliases[i] & 16
                  ? (a || ascii_full_contains(names + name_off[i], full_len, t))
                  : sift_contains(full + full_off[i], full_len, t->needle, t->length, 1));
            if (t->excluded && b) { accepted = 0; break; }
            int c = keys && (aliases[i] & 4 ? a : aliases[i] & 8 ? b
                  : sift_contains(initials + initial_off[i], initial_off[i+1] - initial_off[i], t->needle, t->length, 1));
            if (t->excluded ? (a || b || c) : !(a || b || c)) { accepted = 0; break; }
            if (!t->excluded) score += a * 100 + b * 70 + c * 70;
        }
        if (accepted) { ids[count] = i; scores[count++] = score; }
    }
    return count;
}

enum { MIJI_SCAN_ROWS = 8192, MIJI_SCAN_WORKERS = 4 };
typedef struct {
    const uint8_t *names, *full, *initials, *live, *aliases;
    const uint32_t *name_off, *full_off, *initial_off;
    uint32_t first, end;
    const MijiNameTerm *terms;
    size_t term_count, counts[MIJI_SCAN_WORKERS];
    uint32_t *ids;
    int32_t *scores;
} MatchBatch;

static void match_lane(void *context, size_t lane) {
    MatchBatch *b = context;
    size_t offset = lane * MIJI_SCAN_ROWS;
    uint32_t first = b->first + (uint32_t)offset;
    uint32_t end = first + (b->end - first < MIJI_SCAN_ROWS ? b->end - first : MIJI_SCAN_ROWS);
    b->counts[lane] = miji_match_names(b->names, b->name_off, b->full, b->full_off,
                                     b->initials, b->initial_off, b->live, b->aliases,
                                     first, end, b->terms, b->term_count,
                                     b->ids + offset, b->scores + offset);
}

size_t miji_match_names_batch(const uint8_t *names, const uint32_t *name_off,
                              const uint8_t *full, const uint32_t *full_off,
                              const uint8_t *initials, const uint32_t *initial_off,
                              const uint8_t *live, const uint8_t *aliases,
                              uint32_t first, uint32_t end,
                              const MijiNameTerm *terms, size_t term_count,
                              uint32_t *ids, int32_t *scores) {
    size_t rows = end - first;
    /* Empty/filter-only searches spend their time in the serial callback.
     * Avoid dispatch overhead for them and for small fixtures. */
    if (!term_count || rows <= MIJI_SCAN_ROWS || rows > MIJI_SCAN_ROWS * MIJI_SCAN_WORKERS)
        return miji_match_names(names, name_off, full, full_off, initials, initial_off,
                               live, aliases, first, end, terms, term_count, ids, scores);
    MatchBatch b = { .names = names, .name_off = name_off, .full = full, .full_off = full_off,
                    .initials = initials, .initial_off = initial_off, .live = live, .aliases = aliases,
                    .first = first, .end = end, .terms = terms, .term_count = term_count,
                    .ids = ids, .scores = scores };
    size_t lanes = (rows + MIJI_SCAN_ROWS - 1) / MIJI_SCAN_ROWS;
    dispatch_apply_f(lanes, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), &b, match_lane);
    size_t count = 0;
    for (size_t lane = 0; lane < lanes; lane++) {
        size_t offset = lane * MIJI_SCAN_ROWS, n = b.counts[lane];
        memmove(ids + count, ids + offset, n * sizeof(*ids));
        memmove(scores + count, scores + offset, n * sizeof(*scores));
        count += n;
    }
    return count;
}
