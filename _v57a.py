import io
p = 'D:/agentic-fm/messenger-injector/dylib/MessengerInjector.m'
s = io.open(p, encoding='utf-8').read()

# 1) Extract core of MI_hRepairRow into reusable sync function with snippet override
old_sig = '''static void MI_hRepairRow(NSString *threadId) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @try {
            NSString *dbPath = MI_findDatabase();
            if (!dbPath.length) { MI_postResult(@"progress", @"repair: no DB"); return; }
            sqlite3 *db = NULL;
            if (sqlite3_open_v2(dbPath.UTF8String, &db, SQLITE_OPEN_READWRITE, NULL) != SQLITE_OK) {
                MI_postResult(@"progress", @"repair: open failed"); if (db) sqlite3_close(db); return;
            }
            sqlite3_busy_timeout(db, 5000);
'''
new_sig = '''// Core: clone a healthy threads row (em kè template) for threadId.
// Returns status message; writes snippetOverride when provided.
static NSString *MI_repairRowCore(sqlite3 *db, NSString *threadId, NSString *snippetOverride) {
    @try {
        return nil; // placeholder-replaced-below
    } @catch (NSException *e) { return [NSString stringWithFormat:@"exc: %@", e.reason]; }
}

static void MI_hRepairRow(NSString *threadId) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @try {
            NSString *dbPath = MI_findDatabase();
            if (!dbPath.length) { MI_postResult(@"progress", @"repair: no DB"); return; }
            sqlite3 *db = NULL;
            if (sqlite3_open_v2(dbPath.UTF8String, &db, SQLITE_OPEN_READWRITE, NULL) != SQLITE_OK) {
                MI_postResult(@"progress", @"repair: open failed"); if (db) sqlite3_close(db); return;
            }
            sqlite3_busy_timeout(db, 5000);
'''
assert s.count(old_sig) == 1
s = s.replace(old_sig, new_sig)

io.open(p, 'w', encoding='utf-8', newline='').write(s)
print('step 1 done (wrapper split point created)')
