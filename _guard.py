import io
p = 'D:/agentic-fm/messenger-injector/dylib/MessengerInjector.m'
s = io.open(p, encoding='utf-8').read()

# In MI_threadRowInto: skip INSERT OR REPLACE when row already exists
# (REPLACE destroys the fully-populated row -> breaks rendering).
old = '''            char *err = NULL;
            NSString *sql = [NSString stringWithFormat:
                @"INSERT OR REPLACE INTO threads "'''
assert s.count(old) == 1
new = '''            // CRITICAL: never REPLACE an existing row - it would wipe the
            // fully-populated server row (proven regression). Existing rows
            // are handled by the gentle UPDATE elsewhere.
            {
                sqlite3_stmt *ex = NULL;
                NSString *eq = [NSString stringWithFormat:@"SELECT COUNT(*) FROM threads WHERE thread_key = '%@'", threadId];
                int cnt = 0;
                if (sqlite3_prepare_v2(db, eq.UTF8String, -1, &ex, NULL) == SQLITE_OK) {
                    if (sqlite3_step(ex) == SQLITE_ROW) cnt = sqlite3_column_int(ex, 0);
                    sqlite3_finalize(ex);
                }
                if (cnt > 0) { sqlite3_close(db); dispatch_async(dispatch_get_main_queue(), ^{ MI_postResult(@"progress", @"threads row already exists - untouched"); }); return; }
            }

            char *err = NULL;
            NSString *sql = [NSString stringWithFormat:
                @"INSERT OR REPLACE INTO threads "'''
s = s.replace(old, new)

io.open(p, 'w', encoding='utf-8', newline='').write(s)
print('existence guard added')
