#pragma once
#include <sqlite3.h>

/// Turns on SQLITE_DBCONFIG_DEFENSIVE (binder-v0 §7.2). sqlite3_db_config is variadic, which Swift cannot call.
/// Returns SQLITE_OK, or an error code.
int sprava_sqlite_defensive(sqlite3 *db);
