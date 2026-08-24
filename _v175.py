import io
p = 'D:/agentic-fm/messenger-injector/dylib/MessengerInjector.m'
s = io.open(p, encoding='utf-8').read()

# Add full column-by-column diff: REAL consecutive pair vs OUR injected pair
# for the SAME thread, same sender. This will show EVERY field difference.
old = '''            sqlite3_busy_timeout(db, 250);
            sqlite3_wal_checkpoint_v2(db, "main", SQLITE_CHECKPOINT_TRUNCATE, NULL, NULL);
            sqlite3_close(db);
            [r appendString:@"-> kill+reopen Messenger, check EM KE preview"];'''
assert s.count(old) == 1

new = '''            sqlite3_busy_timeout(db, 250);
            sqlite3_wal_checkpoint_v2(db, "main", SQLITE_CHECKPOINT_TRUNCATE, NULL, NULL);

            // COLUMN-BY-COLUMN DIFF: real vs injected (same thread, same sender)
            {
                // Find any thread_pk that has BOTH real and injected messages
                long long probePk = 0;
                sqlite3_stmt *fp = NULL;
                NSString *fq = [NSString stringWithFormat:
                    @"SELECT DISTINCT c1.thread_pk FROM client_messages c1 "
                     "JOIN client_messages c2 ON c1.thread_pk = c2.thread_pk "
                     "WHERE c1.message_creation_type = 5 AND c2.message_creation_type != 5 LIMIT 1"];
                if (sqlite3_prepare_v2(db, fq.UTF8String, -1, &fp, NULL) == SQLITE_OK) {
                    if (sqlite3_step(fp) == SQLITE_ROW) probePk = sqlite3_column_int64(fp, 0);
                    sqlite3_finalize(fp);
                }
                [r appendFormat:@"\\n[DIFF] probe thread_pk=%lld\\n", probePk];
                if (probePk > 0) {
                    // Get one REAL and one OURS from same thread+sender
                    NSString *queries[2] = {
                        [NSString stringWithFormat:
                            @"SELECT * FROM client_messages WHERE thread_pk = %lld AND message_creation_type = 5 "
                             "ORDER BY authoritative_ts_ms DESC LIMIT 1", probePk],
                        [NSString stringWithFormat:
                            @"SELECT * FROM client_messages WHERE thread_pk = %lld AND message_creation_type != 5 "
                             "ORDER BY authoritative_ts_ms DESC LIMIT 1", probePk]
                    };
                    const char *labels[2] = { "REAL", "OURS" };
                    for (int qi = 0; qi < 2; qi++) {
                        sqlite3_stmt *st = NULL;
                        if (sqlite3_prepare_v2(db, queries[qi].UTF8String, -1, &st, NULL) != SQLITE_OK) continue;
                        if (sqlite3_step(st) == SQLITE_ROW) {
                            int cc = sqlite3_column_count(st);
                            [r appendFormat:@"--- %s ---\\n", labels[qi]];
                            for (int c = 0; c < cc; c++) {
                                int ct = sqlite3_column_type(st, c);
                                const char *cn = sqlite3_column_name(st, c);
                                if (ct == SQLITE_NULL) { [r appendFormat:@"%s=NULL\\n", cn]; continue; }
                                NSString *v;
                                if (ct == SQLITE_TEXT || ct == SQLITE_BLOB) {
                                    v = MI_cstr(sqlite3_column_text(st,c)) ?: @"";
                                    if (v.length > 24) v = [v substringToIndex:24];
                                } else v = [NSString stringWithFormat:@"%lld", sqlite3_column_int64(st,c)];
                                [r appendFormat:@"%s=%@\\n", cn, v];
                            }
                        } else {
                            [r appendFormat:@"--- %s --- NO ROW\\n", labels[qi]];
                        }
                        sqlite3_finalize(st);
                    }
                }
            }

            sqlite3_close(db);
            [r appendString:@"-> kill+reopen Messenger, check EM KE preview"];'''
s = s.replace(old, new)

io.open(p, 'w', encoding='utf-8', newline='').write(s)
print('column diff added')
