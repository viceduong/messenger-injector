import io
p = 'D:/agentic-fm/messenger-injector/dylib/MessengerInjector.m'
s = io.open(p, encoding='utf-8').read()

# notification + fwd decl + handler: write ZZTESTMARK snippet into selected chat's sync row
old1 = 'static NSString *const kNotifySniff   = @"com.messenger.injector.sniff";'
assert s.count(old1) == 1
s = s.replace(old1, old1 + '\nstatic NSString *const kNotifyMark    = @"com.messenger.injector.mark";')

old2 = 'static void MI_probeStores(sqlite3 *db, NSString *threadId, long long threadPk, NSMutableString *r);'
assert s.count(old2) == 1
s = s.replace(old2, old2 + '\nstatic void MI_hMark(NSString *threadId);')

anchor = 'static void MI_probeStores(sqlite3 *db, NSString *threadId, long long threadPk, NSMutableString *r) {'
fn = '''// Write a unique marker snippet into the EXISTING sync threads row.
// Decisive test: does the inbox list render threads.snippet?
static void MI_hMark(NSString *threadId) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @try {
            NSString *dbPath = MI_findDatabase();
            if (!dbPath.length) { MI_postResult(@"progress", @"mark: no DB"); return; }
            sqlite3 *db = NULL;
            if (sqlite3_open_v2(dbPath.UTF8String, &db, SQLITE_OPEN_READWRITE, NULL) != SQLITE_OK) {
                MI_postResult(@"progress", @"mark: DB open failed");
                if (db) sqlite3_close(db);
                return;
            }
            sqlite3_busy_timeout(db, 5000);
            char *err = NULL;
            NSString *q = [NSString stringWithFormat:
                @"UPDATE threads SET snippet = 'ZZTESTMARK-%@' WHERE thread_key = '%@'",
                [[NSUUID UUID] UUIDString], threadId];
            BOOL ok = sqlite3_exec(db, q.UTF8String, NULL, NULL, &err) == SQLITE_OK;
            int ch = sqlite3_changes(db);
            NSString *msg = ok ? [NSString stringWithFormat:@"mark written (%d row(s)) - relaunch Messenger and check this chat's preview", ch]
                               : [NSString stringWithFormat:@"mark failed: %s", err ? err : "?"];
            if (err) sqlite3_free(err);
            sqlite3_close(db);
            dispatch_async(dispatch_get_main_queue(), ^{ MI_postResult(@"progress", msg); });
        } @catch (NSException *e) {
            MI_postResult(@"progress", [NSString stringWithFormat:@"mark exception: %@", e.reason]);
        }
    });
}

'''
assert s.count(anchor) == 1
s = s.replace(anchor, fn + anchor)

# observer
old4 = '''        [dnc addObserverForName:kNotifySniff object:nil queue:[NSOperationQueue mainQueue]
            usingBlock:^(NSNotification *n) { @try { MI_hSniff(n.userInfo[@"threadId"] ?: @""); } @catch (NSException *e) { MI_progress([NSString stringWithFormat:@"sniff obs: %@", e.name]); } }];'''
assert s.count(old4) == 1
s = s.replace(old4, old4 + '''
        [dnc addObserverForName:kNotifyMark object:nil queue:[NSOperationQueue mainQueue]
            usingBlock:^(NSNotification *n) { @try { MI_hMark(n.userInfo[@"threadId"] ?: @""); } @catch (NSException *e) { MI_progress([NSString stringWithFormat:@"mark obs: %@", e.name]); } }];''')

# skeleton-null-count comparison in probe: count NULL cols for target vs em ke threads rows
old5 = '''        if (rn == 0) [rowOut appendString:@"(no matching rows)"];
        [r appendFormat:@"[%@] %@\\n", tbl, rowOut];'''
assert s.count(old5) >= 1
# add compact threads-row health check right after community_thread_sync_info loop ends:
old6 = '''    }
}

''' # end of probe fn? risky. skip for now.
io.open(p, 'w', encoding='utf-8', newline='').write(s)
print('mark handler added')
