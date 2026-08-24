import io
p = 'D:/agentic-fm/messenger-injector/dylib/MessengerInjector.m'
s = io.open(p, encoding='utf-8').read()

# Add client_messages_extensions probe to marktest output
old = '''            sqlite3_busy_timeout(db, 250);
            sqlite3_wal_checkpoint_v2(db, "main", SQLITE_CHECKPOINT_TRUNCATE, NULL, NULL);
            sqlite3_close(db);'''
assert s.count(old) == 1
new = '''            // Dump client_messages_extensions for our thread (grouping/rendering metadata?)
            {
                sqlite3_stmt *es = NULL;
                NSString *eq = [NSString stringWithFormat:
                    @"SELECT e.* FROM client_messages_extensions e "
                     "JOIN client_messages c ON c.pk = e.message_pk "
                     "WHERE c.thread_pk IN (SELECT pk FROM client_threads WHERE default_other_participant_profile_picture_fallback_url_list LIKE '%%entity_id=%@%%') "
                     "LIMIT 3", tKey];
                if (sqlite3_prepare_v2(db, eq.UTF8String, -1, &es, NULL) == SQLITE_OK) {
                    int cc = sqlite3_column_count(es);
                    NSMutableString *colS = [NSMutableString string];
                    for (int c = 0; c < cc; c++) [colS appendFormat:@"%s ", sqlite3_column_name(es,c)];
                    [r appendFormat:@"\\n[extensions] cols(%d): %@\\n", cc, colS];
                    int rn = 0;
                    while (sqlite3_step(es) == SQLITE_ROW && rn < 3) {
                        NSMutableString *rowS = [NSMutableString string];
                        for (int c = 0; c < cc && c < 10; c++) {
                            int ct = sqlite3_column_type(es, c);
                            if (ct == SQLITE_NULL) continue;
                            NSString *v;
                            if (ct == SQLITE_TEXT || ct == SQLITE_BLOB) {
                                v = MI_cstr(sqlite3_column_text(es,c)) ?: @"";
                                if (v.length > 30) v = [v substringToIndex:30];
                            } else v = [NSString stringWithFormat:@"%lld", sqlite3_column_int64(es,c)];
                            [rowS appendFormat:@"%s=%@ ", sqlite3_column_name(es,c), v];
                        }
                        [r appendFormat:@"  ext_row: %@\\n", rowS];
                        rn++;
                    }
                    if (rn == 0) [r appendFormat:@"  (empty)\\n"];
                    sqlite3_finalize(es);
                }
            }
            sqlite3_busy_timeout(db, 250);
            sqlite3_wal_checkpoint_v2(db, "main", SQLITE_CHECKPOINT_TRUNCATE, NULL, NULL);
            sqlite3_close(db);'''
s = s.replace(old, new)

io.open(p, 'w', encoding='utf-8', newline='').write(s)
print('extensions probe added')
