import io
p = 'D:/agentic-fm/messenger-injector/dylib/MessengerInjector.m'
s = io.open(p, encoding='utf-8').read()

# Add compact store-probe function + call it in inject path
anchor = '''            // Deep clean: purge EVERY injected-looking row for this thread.'''
assert s.count(anchor) == 1

probe_fn = '''// Probe unexplored stores that may back the inbox list hydration.
static void MI_probeStores(sqlite3 *db, NSString *threadId, long long threadPk, NSMutableString *r) {
    NSArray *tables = @[@"cutover_threads", @"cutover_messages", @"advanced_crypto_transport_threads",
                        @"local_thread_persistence_store", @"local_message_persistence_store_pending_payload",
                        @"mailbox_metadata", @"inbox_folder_metadata", @"client_composer_state",
                        @"cutover_pending_tasks", @"community_thread_sync_info"];
    for (NSString *tbl in tables) {
        sqlite3_stmt *pi = NULL;
        NSMutableArray *cols = [NSMutableArray array];
        NSString *q = [NSString stringWithFormat:@"PRAGMA table_info(\\"%@\\")", tbl];
        if (sqlite3_prepare_v2(db, q.UTF8String, -1, &pi, NULL) != SQLITE_OK) continue;
        while (sqlite3_step(pi) == SQLITE_ROW) {
            NSString *cn = MI_cstr(sqlite3_column_text(pi,1));
            if (cn.length > 0) [cols addObject:cn];
        }
        sqlite3_finalize(pi);
        if (cols.count == 0) { [r appendFormat:@"[%@] MISSING\\n", tbl]; continue; }
        // pick a key col matching our ids if possible
        NSString *keyCol = nil;
        for (NSString *cand in @[@"thread_key", @"thread_pk", @"otid", @"client_otid"]) {
            for (NSString *c in cols) if ([c.lowercaseString isEqualToString:cand]) { keyCol = c; break; }
            if (keyCol) break;
        }
        NSMutableString *rowOut = [NSMutableString string];
        int rn = 0;
        sqlite3_stmt *rs = NULL;
        NSString *rq;
        if (keyCol.length > 0) rq = [NSString stringWithFormat:@"SELECT * FROM \\"%@\\" WHERE \\"%@\\" IN ('%@', %@) LIMIT 2", tbl, keyCol, threadId, @(threadPk)];
        else rq = [NSString stringWithFormat:@"SELECT * FROM \\"%@\\" LIMIT 2", tbl];
        if (sqlite3_prepare_v2(db, rq.UTF8String, -1, &rs, NULL) == SQLITE_OK) {
            int cc = sqlite3_column_count(rs);
            while (sqlite3_step(rs) == SQLITE_ROW && rn < 2) {
                for (int c = 0; c < cc && c < 14; c++) {
                    NSString *v;
                    int ct = sqlite3_column_type(rs, c);
                    if (ct == SQLITE_NULL) continue;
                    if (ct == SQLITE_TEXT || ct == SQLITE_BLOB) {
                        v = MI_cstr(sqlite3_column_text(rs,c)) ?: @"";
                        if (v.length > 24) v = [v substringToIndex:24];
                    } else v = [NSString stringWithFormat:@"%lld", sqlite3_column_int64(rs,c)];
                    [rowOut appendFormat:@"%s=%@ ", sqlite3_column_name(rs,c), v];
                }
                rn++;
            }
            sqlite3_finalize(rs);
        }
        if (rn == 0) [rowOut appendString:@"(no matching rows)"];
        [r appendFormat:@"[%@] %@\\n", tbl, rowOut];
    }
}

'''
s = s.replace(anchor, probe_fn + anchor)

# call it right before checkpoint block
old_call = '''            // Force WAL checkpoint so changes are written to main DB file'''
assert s.count(old_call) == 1
s = s.replace(old_call, '''            MI_probeStores(db, threadId, threadPk, report);

''' + old_call)

io.open(p, 'w', encoding='utf-8', newline='').write(s)
print('store probe wired')
