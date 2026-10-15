#include "SQLiteDefensive.h"

int sprava_sqlite_defensive(sqlite3 *db) {
    int on = 0, code = sqlite3_db_config(db, SQLITE_DBCONFIG_DEFENSIVE, 1, &on);
    return code != SQLITE_OK ? code : on == 1 ? SQLITE_OK : SQLITE_ERROR;
}
