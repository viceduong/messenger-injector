import io
p = 'D:/agentic-fm/messenger-injector/dylib/MessengerInjector.m'
s = io.open(p, encoding='utf-8').read()

# 1) existence guard in MI_threadRowInto (auto) before its INSERT OR REPLACE
old1 = '''            char *err = NULL;
            NSString *sql = [NSString stringWithFormat:
                @"INSERT OR REPLACE INTO threads "'''
assert s.count(old1) == 2, s.count(old1)
guard = '''            // Never REPLACE an existing row: it would wipe the fully-populated
            // server row (proven regression). Existing rows -> gentle UPDATE only.
            {
                sqlite3_stmt *ex = NULL;
                NSString *eq = [NSString stringWithFormat:@"SELECT COUNT(*) FROM threads WHERE thread_key = '%@'", threadId];
                int cnt = 0;
                if (sqlite3_prepare_v2(db, eq.UTF8String, -1, &ex, NULL) == SQLITE_OK) {
                    if (sqlite3_step(ex) == SQLITE_ROW) cnt = sqlite3_column_int(ex, 0);
                    sqlite3_finalize(ex);
                }
                if (cnt > 0) {
                    if (db_close_after) { sqlite3_close(db); }
                    return;
                }
            }

            char *err = NULL;
            NSString *sql = [NSString stringWithFormat:
                @"INSERT OR REPLACE INTO threads "'''
# We need distinct handling per site; do them one at a time with more context.
io.open(p, 'w', encoding='utf-8', newline='').write(s)
print('step pending - need site context')
