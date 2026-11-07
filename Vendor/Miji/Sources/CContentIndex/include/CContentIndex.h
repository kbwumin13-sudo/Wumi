#ifndef MIJI_CONTENT_INDEX_H
#define MIJI_CONTENT_INDEX_H
#include <sqlite3.h>
#ifdef __cplusplus
extern "C" {
#endif
/* Register on each connection before using FTS5 tables with miji_grams.
 * Documents must be valid, normalized UTF-8. Query tokens are g + lowercase
 * hex UTF-8 bytes, as produced by ContentCodec.matchExpression. */
int miji_register_tokenizer(sqlite3 *db);
#ifdef __cplusplus
}
#endif
#endif
