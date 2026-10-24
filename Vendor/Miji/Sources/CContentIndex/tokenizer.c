#include "CContentIndex.h"

/* Validate one Unicode scalar (reject overlong UTF-8, surrogates and > U+10FFFF).
 * NUL is an ordinary one-byte scalar: input length, never strlen, is authoritative. */
static int scalar_width(const unsigned char *s, int n) {
    if (n <= 0) return 0;
    unsigned char a = s[0];
    if (a < 0x80) return 1;
    int width = a >= 0xc2 && a <= 0xdf ? 2 :
                a >= 0xe0 && a <= 0xef ? 3 :
                a >= 0xf0 && a <= 0xf4 ? 4 : 0;
    if (!width || n < width) return 0;
    for (int i = 1; i < width; ++i)
        if ((s[i] & 0xc0) != 0x80) return 0;
    if ((a == 0xe0 && s[1] < 0xa0) || (a == 0xed && s[1] >= 0xa0) ||
        (a == 0xf0 && s[1] < 0x90) || (a == 0xf4 && s[1] >= 0x90)) return 0;
    return width;
}

static int grams_create(void *context, const char **args, int count, Fts5Tokenizer **out) {
    (void)context; (void)args;
    if (count != 0) return SQLITE_ERROR;
    /* One allocation per tokenizer instance, none per token. */
    *out = (Fts5Tokenizer *)sqlite3_malloc(1);
    return *out ? SQLITE_OK : SQLITE_NOMEM;
}

static void grams_delete(Fts5Tokenizer *tokenizer) { sqlite3_free(tokenizer); }

static int grams_tokenize(Fts5Tokenizer *tokenizer, void *context, int flags,
                          const char *text, int length,
                          int (*emit)(void *, int, const char *, int, int, int)) {
    (void)tokenizer;
    if (length < 0 || (!text && length)) return SQLITE_ERROR;
    if (flags & FTS5_TOKENIZE_QUERY) {
        /* FTS5 already parsed the quoted expression into an encoded token. */
        return length ? emit(context, 0, text, length, 0, length) : SQLITE_OK;
    }
    static const char hex[] = "0123456789abcdef";
    const unsigned char *bytes = (const unsigned char *)text;
    for (int start = 0; start < length;) {
        int end = start, first_width = 0;
        char token[25]; /* g + at most 3 * 4 UTF-8 bytes * 2 hex digits */
        token[0] = 'g';
        for (int gram = 0; gram < 3 && end < length; ++gram) {
            int width = scalar_width(bytes + end, length - end);
            if (!width) return SQLITE_ERROR;
            if (!gram) first_width = width;
            for (int i = 0; i < width; ++i) {
                unsigned char byte = bytes[end + i];
                int offset = 1 + (end + i - start) * 2;
                token[offset] = hex[byte >> 4];
                token[offset + 1] = hex[byte & 15];
            }
            end += width;
            int status = emit(context, 0, token, 1 + (end - start) * 2, start, end);
            if (status != SQLITE_OK) return status;
        }
        start += first_width;
    }
    return SQLITE_OK;
}

int miji_register_tokenizer(sqlite3 *db) {
    if (!db) return SQLITE_MISUSE;
    fts5_api *api = 0;
    sqlite3_stmt *statement = 0;
    int status = sqlite3_prepare_v2(db, "SELECT fts5(?1)", -1, &statement, 0);
    if (status == SQLITE_OK)
        status = sqlite3_bind_pointer(statement, 1, &api, "fts5_api_ptr", 0);
    if (status == SQLITE_OK) {
        int step = sqlite3_step(statement);
        status = step == SQLITE_ROW || step == SQLITE_DONE ? SQLITE_OK : step;
    }
    int final_status = sqlite3_finalize(statement);
    if (status != SQLITE_OK) return status;
    if (final_status != SQLITE_OK) return final_status;
    if (!api || api->iVersion < 2) return SQLITE_ERROR;
    fts5_tokenizer methods = { grams_create, grams_delete, grams_tokenize };
    return api->xCreateTokenizer(api, "miji_grams", 0, &methods, 0);
}
