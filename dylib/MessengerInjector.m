/**
 * MessengerInjector.dylib v2.0
 *
 * Crash-safe SQLite schema dump + sample + conversation injection + thread list.
 *
 * Triggers (NSDistributedNotificationCenter):
 *   IN:  com.messenger.injector.send        — UI-automation send (v1.0)
 *   IN:  com.messenger.injector.dump        — view hierarchy dump
 *   IN:  com.messenger.injector.findDB      — find lightspeed-*.db path
 *   IN:  com.messenger.injector.dumpSchema  — dump all table definitions
 *   IN:  com.messenger.injector.dumpSample  — dump sample rows
 *   IN:  com.messenger.injector.threadList  — list recent threads (NEW v2.0)
 *   IN:  com.messenger.injector.inject     — batch conversation injection (NEW v2.0)
 *   OUT: com.messenger.injector.ready       — dylib loaded
 *   OUT: com.messenger.injector.result     — {tag, text} results display
 *
 * Inject payload:
 *   {threadId: "user_id", messages: [{s:"me"|"them", t:"text", m:minutesAgo}, ...]}
 *
 * Crash diagnostics:
 *   /tmp/mi_crash.txt    — last crash info (exception/signal + backtrace)
 *   /tmp/mi_progress.txt — step-by-step progress markers (append mode)
 *
 * Build:
 *   xcrun clang -dynamiclib -arch arm64 \
 *     -isysroot $(xcrun --sdk iphoneos --show-sdk-path) \
 *     -miphoneos-version-min=15.0 \
 *     -framework Foundation -framework UIKit \
 *     -lsqlite3 -ObjC -fobjc-arc -O2 \
 *     -o libMessengerInjector.dylib MessengerInjector.m
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <signal.h>
#import <execinfo.h>
#import <sqlite3.h>

#pragma clang diagnostic ignored "-Wdeprecated-declarations"

@interface NSDistributedNotificationCenter : NSObject
+ (instancetype)defaultCenter;
- (void)addObserverForName:(NSNotificationName)aName
                    object:(id)object
                     queue:(NSOperationQueue *)queue
                usingBlock:(void (^)(NSNotification *note))block;
- (void)postNotificationName:(NSNotificationName)aName
                      object:(id)object
                    userInfo:(NSDictionary <NSObject *, NSObject *> * _Nullable)userInfo
        deliverImmediately:(BOOL)deliverImmediately;
@end

// ============================================================
// Constants
// ============================================================
static NSString *const kNotifySend       = @"com.messenger.injector.send";
static NSString *const kNotifyDump      = @"com.messenger.injector.dump";
static NSString *const kNotifyReady    = @"com.messenger.injector.ready";
static NSString *const kNotifyResult   = @"com.messenger.injector.result";
static NSString *const kNotifyFindDB    = @"com.messenger.injector.findDB";
static NSString *const kNotifySchema  = @"com.messenger.injector.dumpSchema";
static NSString *const kNotifySample  = @"com.messenger.injector.dumpSample";
static NSString *const kNotifyThreads = @"com.messenger.injector.threadList";
static NSString *const kNotifyInject  = @"com.messenger.injector.inject";

static NSString *const kKeyMessage   = @"message";
static NSString *const kKeyThreadID = @"threadId";
static NSString *const kKeyIsGroup  = @"isGroup";
static NSString *const kKeyDelay    = @"delay";
static NSString *const kKeyMessages = @"messages";

static NSString *gLastThreadID = nil;
static NSString *gFoundDBPath  = nil;
static NSString *gLocalUserID  = nil;

static NSString *MI_progressFile(void) {
    return [NSTemporaryDirectory() stringByAppendingPathComponent:@"mi_progress.txt"];
}
static NSString *MI_crashFile(void) {
    return [NSTemporaryDirectory() stringByAppendingPathComponent:@"mi_crash.txt"];
}

// ============================================================
// Crash + progress diagnostics
// ============================================================
static void MI_log(NSString *fmt, ...);

static void MI_progress(NSString *step) {
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], step];
    // Append to progress file
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:MI_progressFile()];
    if (!fh) {
        [[[NSString stringWithFormat:@"\n=== Session %@ ===\n", [NSDate date]] dataUsingEncoding:NSUTF8StringEncoding] writeToFile:MI_progressFile() atomically:YES];
        fh = [NSFileHandle fileHandleForWritingAtPath:MI_progressFile()];
    }
    if (fh) {
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    }
    MI_log(@"%@", line); // also NSLog
}

static void MI_writeCrash(NSString *info) {
    NSString *msg = [NSString stringWithFormat:@"[%@] CRASH: %@\n", [NSDate date], info];
    [msg writeToFile:MI_crashFile() atomically:YES encoding:NSUTF8StringEncoding error:nil];
    MI_log(@"CRASH: %@", info);
}

static void MI_crashHandler(NSException *exc) {
    NSArray *stack = [exc callStackSymbols];
    NSString *stackStr = [stack componentsJoinedByString:@"\n"];
    MI_writeCrash([NSString stringWithFormat:@"%@\nReason: %@\nStack:\n%@",
                   exc.name, exc.reason, stackStr]);
}

static void MI_signalHandler(int sig) {
    void *callstack[32];
    int frames = backtrace(callstack, 32);
    char **symbols = backtrace_symbols(callstack, frames);
    NSMutableString *bt = [NSMutableString string];
    for (int i = 0; i < frames; i++) {
        [bt appendFormat:@"%s\n", symbols ? symbols[i] : "?"];
    }
    free(symbols);
    MI_writeCrash([NSString stringWithFormat:@"Signal %d\nBacktrace:\n%@", sig, bt]);
    signal(sig, SIG_DFL);
    raise(sig);
}

// ============================================================
// Helpers
// ============================================================
static void MI_log(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt locale:nil arguments:args];
    va_end(args);
    NSLog(@"[MI] %@", msg);
}

static BOOL MI_contains(NSString *hay, NSString *needle) {
    if (!hay.length || !needle.length) return NO;
    return [hay rangeOfString:needle options:NSCaseInsensitiveSearch].location != NSNotFound;
}

static void MI_write(NSFileHandle *fh, NSString *str) {
    NSData *d = [str dataUsingEncoding:NSUTF8StringEncoding];
    if (d && fh) [fh writeData:d];
}

static NSString *MI_cstr(const unsigned char *p) {
    return p ? [NSString stringWithUTF8String:(const char *)p] : @"NULL";
}

static BOOL MI_isSQLiteFile(NSString *path) {
    // Check SQLite magic header: "SQLite format 3\000"
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!fh) return NO;
    NSData *header = [fh readDataOfLength:16];
    [fh closeFile];
    if (header.length < 15) return NO;
    const char *bytes = header.bytes;
    return strncmp(bytes, "SQLite format 3", 15) == 0;
}

static NSString *MI_esc(NSString *s) {
    if (!s) return @"";
    return [s stringByReplacingOccurrencesOfString:@"'" withString:@"''"];
}

// ============================================================
// Forward declarations
// ============================================================
static NSString *MI_findDatabase(void);
static void MI_dumpSchema(NSString *dbPath);
static void MI_dumpSample(NSString *dbPath);
static void MI_dumpViewTree(UIView *v, NSInteger lvl, NSFileHandle *fh);
static void MI_dumpViewFile(UIView *root);
static UIView *MI_firstOf(UIView *root, Class cls);
static UIView *MI_customInput(UIView *v);
static UIView *MI_findInput(UIView *root);
static void MI_collectSend(UIView *v, NSMutableArray<UIView *> *out, UIWindow *win, CGFloat mx, CGFloat my);
static UIView *MI_findSend(UIView *root);
static void MI_typeSend(NSString *msg);
static void MI_send(NSString *msg, NSString *tid, BOOL grp, NSString *dly);
static void MI_hDump(void);
static void MI_hFindDB(void);
static void MI_hSchema(void);
static void MI_hSample(void);
static void MI_hThreads(void);
static void MI_hInject(NSString *threadId, NSArray *messages);
static void MI_postResult(NSString *tag, NSString *text);

// ============================================================
// Post result (thread-safe, called from any queue)
// ============================================================
static void MI_postResult(NSString *tag, NSString *text) {
    MI_log(@"%@: %@", tag, text.length > 200 ? [text substringToIndex:200] : text);
    NSString *safeText = text ?: @"(null)";
    if (safeText.length > 12000) safeText = [safeText substringToIndex:12000];
    [[NSDistributedNotificationCenter defaultCenter]
        postNotificationName:kNotifyResult
                      object:nil
                    userInfo:@{@"tag": tag, @"text": safeText}
            deliverImmediately:YES];
}

// ============================================================
// Database discovery
// ============================================================
static NSString *MI_findDatabase(void) {
    if (gFoundDBPath.length > 0) return gFoundDBPath;
    MI_progress(@"findDB: start");

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *home = NSHomeDirectory();
    MI_progress([NSString stringWithFormat:@"findDB: home=%@", home]);

    NSMutableArray<NSString *> *allDBs = [NSMutableArray array];

    NSArray *searchRoots = @[
        [home stringByAppendingPathComponent:@"Library"],
        [home stringByAppendingPathComponent:@"Documents"],
        home
    ];

    for (NSString *root in searchRoots) {
        if (![fm fileExistsAtPath:root]) continue;
        NSDirectoryEnumerator *dirEnum = [fm enumeratorAtPath:root];
        NSString *rel;
        while ((rel = [dirEnum nextObject])) {
            // Only match actual SQLite database file extensions
            BOOL isDB = [rel hasSuffix:@".db"] || [rel hasSuffix:@".sqlite"] || [rel hasSuffix:@".sqlite3"];
            if (!isDB) continue;
            NSString *full = [root stringByAppendingPathComponent:rel];
            // Verify it's actually a SQLite file (has magic header)
            if (!MI_isSQLiteFile(full)) continue;
            [allDBs addObject:full];
        }
        MI_progress([NSString stringWithFormat:@"findDB: scanned %@ (%d total)", root, (int)allDBs.count]);
    }

    // Also search AppGroup shared containers (try known FB group IDs + directory listing)
    NSMutableArray<NSString *> *appGroupPaths = [NSMutableArray array];

    // Try known Facebook AppGroup identifiers
    NSArray *fbGroupIDs = @[
        @"group.com.facebook.Messenger",
        @"group.com.facebook.Messenger.group",
        @"group.com.facebook.Messenger.shared",
        @"group.com.facebook.Messenger.files",
        @"group.com.facebook.Messenger.internal",
        @"group.com.facebook.Messenger.LightSpeed",
        @"group.com.facebook.lightspeed",
        @"group.com.facebook",
        @"group.com.facebook.Messenger.uploadtasks"
    ];
    for (NSString *gid in fbGroupIDs) {
        NSURL *url = [fm containerURLForSecurityApplicationGroupIdentifier:gid];
        if (url) {
            MI_progress([NSString stringWithFormat:@"findDB: AppGroup %@ -> %@", gid, url.path]);
            [appGroupPaths addObject:url.path];
        }
    }

    // Also try directory listing
    @try {
        NSString *sharedBase = @"/var/mobile/Containers/Shared/AppGroup";
        NSArray *groups = [fm contentsOfDirectoryAtPath:sharedBase error:nil];
        MI_progress([NSString stringWithFormat:@"findDB: %d AppGroups in shared dir", (int)groups.count]);
        for (NSString *g in groups) {
            NSString *gp = [sharedBase stringByAppendingPathComponent:g];
            if (![appGroupPaths containsObject:gp]) [appGroupPaths addObject:gp];
        }
    } @catch (NSException *e) {
        MI_progress([NSString stringWithFormat:@"findDB: shared AppGroup dir failed: %@", e.name]);
    }

    for (NSString *gp in appGroupPaths) {
        @try {
            NSDirectoryEnumerator *dirEnum = [fm enumeratorAtPath:gp];
            NSString *rel;
            while ((rel = [dirEnum nextObject])) {
                BOOL isDB = [rel hasSuffix:@".db"] || [rel hasSuffix:@".sqlite"] || [rel hasSuffix:@".sqlite3"];
                if (!isDB) continue;
                NSString *full = [gp stringByAppendingPathComponent:rel];
                if (!MI_isSQLiteFile(full)) continue;
                [allDBs addObject:full];
            }
        } @catch (NSException *e) {
            MI_progress([NSString stringWithFormat:@"findDB: skip group %@ (%@)", gp, e.name]);
        }
    }

    MI_progress([NSString stringWithFormat:@"findDB: %d .db files total", (int)allDBs.count]);
    for (NSString *db in allDBs) {
        NSDictionary *attrs = [fm attributesOfItemAtPath:db error:nil];
        unsigned long long sz = [attrs[NSFileSize] unsignedLongLongValue];
        MI_progress([NSString stringWithFormat:@"  DB: %@ (%.1f KB)", db, sz / 1024.0]);
    }

    // Priority: lightspeed-*.db > msys*.db > messaging*.db > largest .db
    NSString *best = nil;
    for (NSString *db in allDBs) {
        if ([db containsString:@"lightspeed"]) { best = db; break; }
    }
    if (!best) for (NSString *db in allDBs) {
        if ([db containsString:@"msys"]) { best = db; break; }
    }
    if (!best) for (NSString *db in allDBs) {
        if ([db containsString:@"messaging"] || [db containsString:@"message"]) { best = db; break; }
    }
    if (!best && allDBs.count > 0) {
        unsigned long long maxSz = 0;
        for (NSString *db in allDBs) {
            NSDictionary *attrs = [fm attributesOfItemAtPath:db error:nil];
            unsigned long long sz = [attrs[NSFileSize] unsignedLongLongValue];
            if (sz > maxSz) { maxSz = sz; best = db; }
        }
    }

    if (best) {
        gFoundDBPath = best;
        NSDictionary *attrs = [fm attributesOfItemAtPath:best error:nil];
        unsigned long long sz = [attrs[NSFileSize] unsignedLongLongValue];
        MI_progress([NSString stringWithFormat:@"findDB: selected %@ (%.1f MB)", best, sz / 1048576.0]);

        // Parse local user ID from filename: lightspeed-<userid>.db
        NSString *fname = [best lastPathComponent];
        NSRange dashRange = [fname rangeOfString:@"-"];
        if (dashRange.location != NSNotFound) {
            NSRange dotRange = [fname rangeOfString:@"."];
            NSUInteger end = (dotRange.location != NSNotFound) ? dotRange.location : fname.length;
            NSString *uid = [fname substringWithRange:NSMakeRange(dashRange.location + 1, end - dashRange.location - 1)];
            if (uid.length > 0 && uid.longLongValue > 0) {
                gLocalUserID = uid;
                MI_progress([NSString stringWithFormat:@"findDB: localUserID=%@", uid]);
            }
        }
    } else {
        MI_progress(@"findDB: NO .db files found");
    }
    MI_progress(@"findDB: done");
    return gFoundDBPath;
}

// ============================================================
// Schema dump
// ============================================================
static void MI_dumpSchema(NSString *dbPath) {
    MI_progress(@"schema: start");
    if (!dbPath.length) { MI_progress(@"schema: no DB path"); return; }

    sqlite3 *db = NULL;
    if (sqlite3_open_v2(dbPath.UTF8String, &db, SQLITE_OPEN_READONLY, NULL) != SQLITE_OK) {
        MI_progress([NSString stringWithFormat:@"schema: open failed: %s", db ? sqlite3_errmsg(db) : "null"]);
        if (db) sqlite3_close(db);
        return;
    }
    sqlite3_busy_timeout(db, 5000);
    MI_progress(@"schema: DB opened");

    NSString *out = [NSTemporaryDirectory() stringByAppendingPathComponent:@"mi_schema.txt"];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createFileAtPath:out contents:nil attributes:nil];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:out];
    if (!fh) { sqlite3_close(db); MI_progress(@"schema: file handle failed"); return; }

    MI_write(fh, [NSString stringWithFormat:@"=== Messenger DB Schema ===\nDB: %@\nDate: %@\n\n", dbPath, [NSDate date]]);

    // Table definitions
    sqlite3_stmt *st = NULL;
    if (sqlite3_prepare_v2(db, "SELECT type, name, sql FROM sqlite_master WHERE sql IS NOT NULL ORDER BY type,name", -1, &st, NULL) != SQLITE_OK) {
        MI_write(fh, [NSString stringWithFormat:@"PREPARE ERROR: %s\n", sqlite3_errmsg(db)]);
        [fh closeFile]; sqlite3_close(db); return;
    }
    MI_progress(@"schema: querying sqlite_master");

    int tc = 0, ic = 0, trg = 0, vc = 0;
    while (sqlite3_step(st) == SQLITE_ROW) {
        NSString *type = MI_cstr(sqlite3_column_text(st, 0));
        NSString *name = MI_cstr(sqlite3_column_text(st, 1));
        NSString *sql  = MI_cstr(sqlite3_column_text(st, 2));
        MI_write(fh, [NSString stringWithFormat:@"--- %@: %@ ---\n%@\n\n", type, name, sql]);
        if ([type isEqualToString:@"table"]) tc++;
        else if ([type isEqualToString:@"index"]) ic++;
        else if ([type isEqualToString:@"trigger"]) trg++;
        else if ([type isEqualToString:@"view"]) vc++;
    }
    sqlite3_finalize(st);
    MI_progress([NSString stringWithFormat:@"schema: %d tables, %d indexes", tc, ic]);

    MI_write(fh, [NSString stringWithFormat:@"\n=== Summary: %d tables, %d indexes, %d triggers, %d views ===\n\n", tc, ic, trg, vc]);

    // Table row counts
    MI_write(fh, @"=== Table Row Counts ===\n\n");
    NSMutableArray<NSString *> *tableNames = [NSMutableArray array];
    st = NULL;
    if (sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name", -1, &st, NULL) == SQLITE_OK) {
        while (sqlite3_step(st) == SQLITE_ROW) {
            [tableNames addObject:MI_cstr(sqlite3_column_text(st, 0))];
        }
        sqlite3_finalize(st);
    }
    MI_progress([NSString stringWithFormat:@"schema: counting %d tables", (int)tableNames.count]);

    for (NSString *tn in tableNames) {
        NSString *cq = [NSString stringWithFormat:@"SELECT count(*) FROM '%@'", MI_esc(tn)];
        sqlite3_stmt *cs = NULL;
        if (sqlite3_prepare_v2(db, cq.UTF8String, -1, &cs, NULL) == SQLITE_OK) {
            if (sqlite3_step(cs) == SQLITE_ROW) {
                long long cnt = sqlite3_column_int64(cs, 0);
                MI_write(fh, [NSString stringWithFormat:@"%-40s %lld rows\n", tn.UTF8String, cnt]);
            }
            sqlite3_finalize(cs);
        } else {
            MI_write(fh, [NSString stringWithFormat:@"%-40s (error)\n", tn.UTF8String]);
        }
    }

    [fh closeFile];
    sqlite3_close(db);
    MI_progress(@"schema: done");
}

// ============================================================
// Sample data dump
// ============================================================
static void MI_dumpSample(NSString *dbPath) {
    MI_progress(@"sample: start");
    if (!dbPath.length) { MI_progress(@"sample: no DB"); return; }

    sqlite3 *db = NULL;
    if (sqlite3_open_v2(dbPath.UTF8String, &db, SQLITE_OPEN_READONLY, NULL) != SQLITE_OK) {
        MI_progress([NSString stringWithFormat:@"sample: open failed: %s", db ? sqlite3_errmsg(db) : "null"]);
        if (db) sqlite3_close(db);
        return;
    }
    sqlite3_busy_timeout(db, 5000);
    MI_progress(@"sample: DB opened");

    NSString *out = [NSTemporaryDirectory() stringByAppendingPathComponent:@"mi_sample.txt"];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createFileAtPath:out contents:nil attributes:nil];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:out];
    if (!fh) { sqlite3_close(db); MI_progress(@"sample: file handle failed"); return; }

    MI_write(fh, [NSString stringWithFormat:@"=== Sample Data ===\nDB: %@\nDate: %@\n\n", dbPath, [NSDate date]]);

    NSMutableArray<NSString *> *tables = [NSMutableArray array];
    sqlite3_stmt *st = NULL;
    if (sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name", -1, &st, NULL) == SQLITE_OK) {
        while (sqlite3_step(st) == SQLITE_ROW) [tables addObject:MI_cstr(sqlite3_column_text(st, 0))];
        sqlite3_finalize(st);
    }
    MI_progress([NSString stringWithFormat:@"sample: %d tables", (int)tables.count]);

    // Candidate tables for message data
    NSArray *candidates = @[@"messages",@"message",@"chat_messages",@"messaging_messages",
                             @"threads",@"thread",@"chat_threads",@"messaging_threads",
                             @"chat_bubbles",@"bubbles",@"sync_message",@"sync_messages"];

    for (NSString *tn in candidates) {
        if (![tables containsObject:tn]) continue;
        MI_progress([NSString stringWithFormat:@"sample: dumping %@", tn]);

        MI_write(fh, [NSString stringWithFormat:@"\n=== %@ (5 rows) ===\n", tn]);
        NSString *q = [NSString stringWithFormat:@"SELECT * FROM \"%@\" LIMIT 5", tn];
        sqlite3_stmt *s = NULL;
        if (sqlite3_prepare_v2(db, q.UTF8String, -1, &s, NULL) != SQLITE_OK) {
            MI_write(fh, [NSString stringWithFormat:@"ERR: %s\n", sqlite3_errmsg(db)]);
            continue;
        }
        int cc = sqlite3_column_count(s);
        for (int c = 0; c < cc; c++) {
            MI_write(fh, [NSString stringWithFormat:@"%@%@", @(sqlite3_column_name(s, c)) ?: @"?",
                         c < cc - 1 ? @" | " : @""]);
        }
        MI_write(fh, @"\n---\n");
        int rn = 0;
        while (sqlite3_step(s) == SQLITE_ROW && rn < 5) {
            for (int c = 0; c < cc; c++) {
                MI_write(fh, [NSString stringWithFormat:@"%@%@", MI_cstr(sqlite3_column_text(s, c)),
                              c < cc - 1 ? @" | " : @""]);
            }
            MI_write(fh, @"\n");
            rn++;
        }
        sqlite3_finalize(s);
    }

    // Any table with message/thread/chat in name (not already covered)
    for (NSString *tn in tables) {
        BOOL match = MI_contains(tn, @"message") || MI_contains(tn, @"thread") || MI_contains(tn, @"chat");
        if (!match) continue;
        if ([candidates containsObject:tn]) continue;

        MI_progress([NSString stringWithFormat:@"sample: dumping %@ (name match)", tn]);
        MI_write(fh, [NSString stringWithFormat:@"\n=== %@ (3 rows, name match) ===\n", tn]);
        NSString *q = [NSString stringWithFormat:@"SELECT * FROM \"%@\" LIMIT 3",
                       [tn stringByReplacingOccurrencesOfString:@"\"" withString:@"\"\""]];
        sqlite3_stmt *s = NULL;
        if (sqlite3_prepare_v2(db, q.UTF8String, -1, &s, NULL) != SQLITE_OK) continue;
        int cc = sqlite3_column_count(s);
        while (sqlite3_step(s) == SQLITE_ROW) {
            for (int c = 0; c < cc; c++) {
                MI_write(fh, [NSString stringWithFormat:@"%@%@", MI_cstr(sqlite3_column_text(s, c)),
                              c < cc - 1 ? @" | " : @""]);
            }
            MI_write(fh, @"\n");
        }
        sqlite3_finalize(s);
    }

    [fh closeFile];
    sqlite3_close(db);
    MI_progress(@"sample: done");
}

// ============================================================
// Thread list (NEW v2.0)
// ============================================================
static void MI_hThreads(void) {
    MI_progress(@"threads: start");
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @try {
            NSString *dbPath = MI_findDatabase();
            if (!dbPath.length) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    MI_postResult(@"threads", @"No database found. Run Find Database first.");
                });
                return;
            }

            sqlite3 *db = NULL;
            if (sqlite3_open_v2(dbPath.UTF8String, &db, SQLITE_OPEN_READONLY, NULL) != SQLITE_OK) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    MI_postResult(@"threads", [NSString stringWithFormat:@"DB open failed: %s", db ? sqlite3_errmsg(db) : "null"]);
                });
                if (db) sqlite3_close(db);
                return;
            }
            sqlite3_busy_timeout(db, 5000);
            MI_progress(@"threads: DB opened");

            NSMutableString *result = [NSMutableString string];
            [result appendFormat:@"=== Threads ===\nDB: %@\n\n", dbPath];

            // Try to list threads from various possible table names
            NSArray *threadTables = @[@"threads", @"thread", @"messaging_threads", @"chat_threads"];
            BOOL found = NO;

            for (NSString *table in threadTables) {
                sqlite3_stmt *s = NULL;
                NSString *q = [NSString stringWithFormat:@"SELECT * FROM \"%@\" LIMIT 20", table];
                if (sqlite3_prepare_v2(db, q.UTF8String, -1, &s, NULL) != SQLITE_OK) continue;
                found = YES;
                MI_progress([NSString stringWithFormat:@"threads: found table %@", table]);

                [result appendFormat:@"--- Table: %@ ---\n", table];
                int cc = sqlite3_column_count(s);
                for (int c = 0; c < cc; c++) {
                    [result appendFormat:@"%@%@", @(sqlite3_column_name(s, c)) ?: @"?", c < cc - 1 ? @" | " : @""];
                }
                [result appendString:@"\n---\n"];
                int rn = 0;
                while (sqlite3_step(s) == SQLITE_ROW && rn < 20) {
                    for (int c = 0; c < cc; c++) {
                        [result appendFormat:@"%@%@", MI_cstr(sqlite3_column_text(s, c)), c < cc - 1 ? @" | " : @""];
                    }
                    [result appendString:@"\n"];
                    rn++;
                }
                sqlite3_finalize(s);
                [result appendString:@"\n"];
            }

            // Also try: list distinct thread_key + sender_id from messages
            if (!found) {
                sqlite3_stmt *s = NULL;
                if (sqlite3_prepare_v2(db, "SELECT DISTINCT thread_key FROM messages LIMIT 20", -1, &s, NULL) == SQLITE_OK) {
                    [result appendString:@"--- Distinct thread_keys from messages ---\n"];
                    int rn = 0;
                    while (sqlite3_step(s) == SQLITE_ROW && rn < 20) {
                        [result appendFormat:@"%@\n", MI_cstr(sqlite3_column_text(s, 0))];
                        rn++;
                    }
                    sqlite3_finalize(s);
                    [result appendString:@"\n"];
                }
            }

            // List distinct senders from messages
            {
                sqlite3_stmt *s = NULL;
                if (sqlite3_prepare_v2(db, "SELECT DISTINCT sender_id FROM messages LIMIT 20", -1, &s, NULL) == SQLITE_OK) {
                    [result appendString:@"--- Distinct sender_ids from messages ---\n"];
                    int rn = 0;
                    while (sqlite3_step(s) == SQLITE_ROW && rn < 20) {
                        [result appendFormat:@"%@\n", MI_cstr(sqlite3_column_text(s, 0))];
                        rn++;
                    }
                    sqlite3_finalize(s);
                }
            }

            sqlite3_close(db);

            if (result.length == 0) {
                [result appendString:@"No thread data found."];
            }

            NSString *res = [result copy];
            dispatch_async(dispatch_get_main_queue(), ^{
                MI_postResult(@"threads", res);
            });
        } @catch (NSException *e) {
            dispatch_async(dispatch_get_main_queue(), ^{
                MI_postResult(@"threads", [NSString stringWithFormat:@"Exception: %@ - %@", e.name, e.reason]);
            });
        }
    });
    MI_progress(@"threads: dispatched");
}

// ============================================================
// Conversation injection (NEW v2.0)
// ============================================================
static void MI_hInject(NSString *threadId, NSArray *messages) {
    MI_progress([NSString stringWithFormat:@"inject: start threadId=%@ msgCount=%d", threadId, (int)messages.count]);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @try {
            if (!threadId.length || messages.count == 0) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    MI_postResult(@"inject", @"Missing threadId or messages.");
                });
                return;
            }

            NSString *dbPath = MI_findDatabase();
            if (!dbPath.length) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    MI_postResult(@"inject", @"No database found. Run Find Database first.");
                });
                return;
            }
            MI_progress([NSString stringWithFormat:@"inject: dbPath=%@", dbPath]);

            sqlite3 *db = NULL;
            if (sqlite3_open_v2(dbPath.UTF8String, &db, SQLITE_OPEN_READWRITE, NULL) != SQLITE_OK) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    MI_postResult(@"inject", [NSString stringWithFormat:@"DB open (RW) failed: %s", db ? sqlite3_errmsg(db) : "null"]);
                });
                if (db) sqlite3_close(db);
                return;
            }
            sqlite3_busy_timeout(db, 5000);
            MI_progress(@"inject: DB opened RW");

            NSMutableString *report = [NSMutableString string];

            // Step 1: Resolve thread_key from existing messages
            MI_progress(@"inject: resolving thread_key");
            NSString *threadKey = nil;
            {
                sqlite3_stmt *s = NULL;
                // Try exact match on thread_key
                NSString *q = [NSString stringWithFormat:@"SELECT DISTINCT thread_key FROM messages WHERE thread_key LIKE '%%%@%%' LIMIT 1", MI_esc(threadId)];
                if (sqlite3_prepare_v2(db, q.UTF8String, -1, &s, NULL) == SQLITE_OK) {
                    if (sqlite3_step(s) == SQLITE_ROW) {
                        threadKey = MI_cstr(sqlite3_column_text(s, 0));
                    }
                    sqlite3_finalize(s);
                }
            }

            // If no match, try sender_id or thread_key = threadId directly
            if (!threadKey) {
                sqlite3_stmt *s = NULL;
                NSString *q = [NSString stringWithFormat:@"SELECT DISTINCT thread_key FROM messages WHERE thread_key = '%@' LIMIT 1", MI_esc(threadId)];
                if (sqlite3_prepare_v2(db, q.UTF8String, -1, &s, NULL) == SQLITE_OK) {
                    if (sqlite3_step(s) == SQLITE_ROW) {
                        threadKey = MI_cstr(sqlite3_column_text(s, 0));
                    }
                    sqlite3_finalize(s);
                }
            }

            // If still no match, use threadId as the thread_key directly
            if (!threadKey) {
                threadKey = threadId;
                [report appendFormat:@"Note: thread_key not found in existing rows, using threadId as thread_key: %@\n", threadId];
            }
            MI_progress([NSString stringWithFormat:@"inject: threadKey=%@", threadKey]);
            [report appendFormat:@"Thread key: %@\n", threadKey];

            // Step 2: Find sender_ids from existing messages in this thread
            MI_progress(@"inject: finding sender_ids");
            NSMutableArray<NSString *> *senderIds = [NSMutableArray array];
            {
                sqlite3_stmt *s = NULL;
                NSString *q = [NSString stringWithFormat:@"SELECT DISTINCT sender_id FROM messages WHERE thread_key LIKE '%%%@%%' LIMIT 10", MI_esc(threadId)];
                if (sqlite3_prepare_v2(db, q.UTF8String, -1, &s, NULL) == SQLITE_OK) {
                    while (sqlite3_step(s) == SQLITE_ROW) {
                        NSString *sid = MI_cstr(sqlite3_column_text(s, 0));
                        if (sid && ![sid isEqualToString:@"NULL"]) [senderIds addObject:sid];
                    }
                    sqlite3_finalize(s);
                }
            }

            // Step 3: Determine local user ID and other party ID
            NSString *localUid = gLocalUserID;
            if (!localUid.length) {
                // Parse from DB filename
                NSString *fname = [dbPath lastPathComponent];
                NSRange dash = [fname rangeOfString:@"-"];
                if (dash.location != NSNotFound) {
                    NSRange dot = [fname rangeOfString:@"."];
                    NSUInteger end = (dot.location != NSNotFound) ? dot.location : fname.length;
                    NSString *uid = [fname substringWithRange:NSMakeRange(dash.location + 1, end - dash.location - 1)];
                    if (uid.length > 0 && uid.longLongValue > 0) {
                        localUid = uid;
                        gLocalUserID = uid;
                    }
                }
            }
            // If still no local UID, try to find it: the sender_id that appears most in outgoing messages
            if (!localUid.length && senderIds.count > 0) {
                localUid = senderIds.firstObject;
            }

            // Other party ID: any sender_id that's not the local user
            NSString *otherUid = nil;
            for (NSString *sid in senderIds) {
                if (![sid isEqualToString:localUid]) {
                    otherUid = sid;
                    break;
                }
            }
            // If no other party found, use threadId itself
            if (!otherUid.length) otherUid = threadId;

            MI_progress([NSString stringWithFormat:@"inject: localUid=%@ otherUid=%@", localUid, otherUid]);
            [report appendFormat:@"Local user: %@\nOther party: %@\n", localUid, otherUid];
            [report appendFormat:@"Senders found: %@\n", [senderIds componentsJoinedByString:@", "]];

            // Step 4: Find max message_id to derive format
            MI_progress(@"inject: finding max message_id");
            long long maxMsgId = 0;
            int msgIdColType = 0; // 0=integer, 1=text
            {
                sqlite3_stmt *s = NULL;
                if (sqlite3_prepare_v2(db, "SELECT MAX(CAST(message_id AS INTEGER)) FROM messages", -1, &s, NULL) == SQLITE_OK) {
                    if (sqlite3_step(s) == SQLITE_ROW) {
                        maxMsgId = sqlite3_column_int64(s, 0);
                        if (sqlite3_column_type(s, 0) == SQLITE_TEXT) msgIdColType = 1;
                    }
                    sqlite3_finalize(s);
                }
            }
            MI_progress([NSString stringWithFormat:@"inject: maxMsgId=%lld colType=%d", maxMsgId, msgIdColType]);
            [report appendFormat:@"Max existing message_id: %lld (type: %@)\n", maxMsgId, msgIdColType ? @"TEXT" : @"INTEGER"];

            // Step 5: Get column names from messages table
            MI_progress(@"inject: getting columns");
            NSMutableArray<NSString *> *msgCols = [NSMutableArray array];
            {
                sqlite3_stmt *s = NULL;
                if (sqlite3_prepare_v2(db, "SELECT * FROM messages LIMIT 1", -1, &s, NULL) == SQLITE_OK) {
                    int cc = sqlite3_column_count(s);
                    for (int c = 0; c < cc; c++) {
                        [msgCols addObject:@(sqlite3_column_name(s, c))];
                    }
                    sqlite3_finalize(s);
                }
            }
            [report appendFormat:@"Columns: %@\n", [msgCols componentsJoinedByString:@", "]];
            MI_progress([NSString stringWithFormat:@"inject: columns=%@", [msgCols componentsJoinedByString:@","]]);

            // Step 6: INSERT messages
            MI_progress(@"inject: starting transaction");
            sqlite3_exec(db, "BEGIN TRANSACTION", NULL, NULL, NULL);

            int inserted = 0;
            int errors = 0;
            long long nextMsgId = maxMsgId + 1;
            long long nowMs = (long long)([NSDate date].timeIntervalSince1970 * 1000);

            for (int i = 0; i < (int)messages.count; i++) {
                NSDictionary *msg = messages[i];
                NSString *side = msg[@"s"];
                NSString *text = msg[@"t"];
                NSNumber *minAgo = msg[@"m"];
                long long minutesAgo = minAgo ? minAgo.longLongValue : (messages.count - i);
                long long ts = nowMs - (minutesAgo * 60 * 1000);
                NSString *senderId = [side isEqualToString:@"me"] ? localUid : otherUid;

                // Build message_id: use nextMsgId (server-format, non-zero = already synced)
                NSString *msgIdStr = [NSString stringWithFormat:@"%lld", nextMsgId];

                // INSERT OR IGNORE
                NSString *sql = [NSString stringWithFormat:
                    @"INSERT OR IGNORE INTO messages (message_id, timestamp_ms, sender_id, thread_key, text, is_admin_message) "
                    @"VALUES ('%@', %lld, '%@', '%@', '%@', 0)",
                    MI_esc(msgIdStr), ts, MI_esc(senderId), MI_esc(threadKey), MI_esc(text)];

                char *errMsg = NULL;
                int rc = sqlite3_exec(db, sql.UTF8String, NULL, NULL, &errMsg);
                if (rc == SQLITE_OK) {
                    inserted++;
                    [report appendFormat:@"  [%d] %@: \"%@\" → msg_id=%@ ts=%lld\n", i+1, side, text, msgIdStr, ts];
                } else {
                    errors++;
                    [report appendFormat:@"  [%d] ERROR: %s\n  SQL: %@\n", i+1, errMsg ? errMsg : "?", sql];
                    if (errMsg) sqlite3_free(errMsg);
                }
                nextMsgId++;
            }

            sqlite3_exec(db, "COMMIT", NULL, NULL, NULL);
            MI_progress([NSString stringWithFormat:@"inject: %d inserted, %d errors", inserted, errors]);

            sqlite3_close(db);

            [report appendFormat:@"\n=== Result: %d inserted, %d errors ===\n", inserted, errors];
            [report appendString:@"\n⚠️ Kill and reopen Messenger to see new messages (cold start reads fresh DB).\n"];

            NSString *res = [report copy];
            dispatch_async(dispatch_get_main_queue(), ^{
                MI_postResult(@"inject", res);
            });
        } @catch (NSException *e) {
            MI_progress([NSString stringWithFormat:@"inject: EXCEPTION %@ - %@", e.name, e.reason]);
            dispatch_async(dispatch_get_main_queue(), ^{
                MI_postResult(@"inject", [NSString stringWithFormat:@"Exception: %@\n%@", e.name, e.reason]);
            });
        }
    });
    MI_progress(@"inject: dispatched");
}

// ============================================================
// View hierarchy (v1.0)
// ============================================================
static void MI_dumpViewTree(UIView *v, NSInteger lvl, NSFileHandle *fh) {
    if (!v || lvl > 25) return;
    NSString *ind = [@"" stringByPaddingToLength:(lvl * 2) withString:@" " startingAtIndex:0];
    MI_write(fh, [NSString stringWithFormat:@"%@%@ fr=%@ acc=\"%@\"\n",
                  ind, NSStringFromClass([v class]),
                  NSStringFromCGRect(v.frame), v.accessibilityLabel ?: @""]);
    for (UIView *s in v.subviews) MI_dumpViewTree(s, lvl + 1, fh);
}

static void MI_dumpViewFile(UIView *root) {
    if (!root) return;
    NSString *p = [NSTemporaryDirectory() stringByAppendingPathComponent:@"mi_hierarchy.txt"];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:p]) [fm createFileAtPath:p contents:nil attributes:nil];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:p];
    if (!fh) return;
    [fh seekToEndOfFile];
    MI_write(fh, [NSString stringWithFormat:@"\n--- %@ ---\n", [NSDate date]]);
    MI_dumpViewTree(root, 0, fh);
    MI_write(fh, @"=== end ===\n");
    [fh closeFile];
    MI_log(@"View dump: %@", p);
}

static UIView *MI_firstOf(UIView *r, Class c) {
    if (!r) return nil;
    if ([r isKindOfClass:c]) return r;
    for (UIView *s in r.subviews) { UIView *x = MI_firstOf(s, c); if (x) return x; }
    return nil;
}

static UIView *MI_customInput(UIView *v) {
    if (!v) return nil;
    if ([v isKindOfClass:[UITextView class]] || [v isKindOfClass:[UITextField class]]) return nil;
    if ([v respondsToSelector:@selector(setText:)] && [v respondsToSelector:@selector(becomeFirstResponder)] && v.isUserInteractionEnabled) {
        UIWindow *w = [UIApplication sharedApplication].keyWindow;
        if (w) { CGRect r = [v convertRect:v.bounds toView:w]; if (r.origin.y > w.bounds.size.height * 0.5) return v; }
    }
    for (UIView *s in v.subviews) { UIView *x = MI_customInput(s); if (x) return x; }
    return nil;
}

static UIView *MI_findInput(UIView *r) {
    if (!r) return nil;
    UIView *x;
    if ((x = MI_firstOf(r, [UITextView class])))  { MI_log(@"Input: UITextView"); return x; }
    if ((x = MI_firstOf(r, [UITextField class]))) { MI_log(@"Input: UITextField"); return x; }
    if ((x = MI_customInput(r)))                   { MI_log(@"Input: custom %@", NSStringFromClass([x class])); return x; }
    return nil;
}

static void MI_collectSend(UIView *v, NSMutableArray<UIView *> *out, UIWindow *w, CGFloat mx, CGFloat my) {
    if (!v) return;
    if ([v isKindOfClass:[UIControl class]] && v.isUserInteractionEnabled) {
        CGRect f = [v convertRect:v.bounds toView:w];
        if (f.origin.y > my && f.origin.x > mx * 0.3) [out addObject:v];
    }
    for (UIView *s in v.subviews) MI_collectSend(s, out, w, mx, my);
}

static UIView *MI_findSend(UIView *r) {
    if (!r) return nil;
    UIWindow *w = [UIApplication sharedApplication].keyWindow;
    if (!w) return nil;
    CGRect wb = w.bounds;
    NSMutableArray<UIView *> *cands = [NSMutableArray array];
    MI_collectSend(r, cands, w, wb.size.width * 0.4, wb.size.height * 0.5);
    if (cands.count == 0) return nil;
    UIView *best = nil; CGFloat bs = -1;
    for (UIView *c in cands) {
        CGRect f = [c convertRect:c.bounds toView:w];
        CGFloat cx = f.origin.x + f.size.width / 2, cy = f.origin.y + f.size.height / 2;
        CGFloat sz = MAX(f.size.width, f.size.height);
        CGFloat sc = 0;
        if (cx > wb.size.width * 0.4) sc += 10;
        if (cy > wb.size.height * 0.5) sc += 10;
        if (sz < 50) sc += 25; else if (sz < 80) sc += 15; else if (sz < 120) sc += 5;
        if ([c isKindOfClass:[UIButton class]]) sc += 20;
        else if ([c isKindOfClass:[UIControl class]]) sc += 10;
        if (MI_contains(NSStringFromClass([c class]), @"send") || MI_contains(c.accessibilityLabel ?: @"", @"send")) sc += 50;
        if (sc > bs) { bs = sc; best = c; }
    }
    if (best) MI_log(@"Send: %@", NSStringFromClass([best class]));
    return best;
}

static void MI_typeSend(NSString *msg) {
    UIView *r = [UIApplication sharedApplication].keyWindow.rootViewController.view;
    if (!r) { MI_log(@"No root view"); return; }
    UIView *inp = MI_findInput(r);
    if (!inp) { MI_log(@"No input. Dumping..."); MI_dumpViewFile(r); return; }
    if ([inp isKindOfClass:[UITextView class]]) {
        UITextView *tv = (UITextView *)inp;
        [tv becomeFirstResponder]; [tv setText:msg];
        [[NSNotificationCenter defaultCenter] postNotificationName:UITextViewTextDidChangeNotification object:tv];
    } else if ([inp isKindOfClass:[UITextField class]]) {
        UITextField *tf = (UITextField *)inp;
        [tf becomeFirstResponder]; [tf setText:msg];
        [[NSNotificationCenter defaultCenter] postNotificationName:UITextFieldTextDidChangeNotification object:tf];
    } else if ([inp respondsToSelector:@selector(setText:)]) {
        [inp performSelector:@selector(setText:) withObject:msg];
        [inp performSelector:@selector(becomeFirstResponder)];
    } else { MI_dumpViewFile(r); return; }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIView *snd = MI_findSend(r);
        if (snd && [snd isKindOfClass:[UIControl class]]) {
            [(UIControl *)snd sendActionsForControlEvents:UIControlEventTouchUpInside];
            MI_log(@"SENT: \"%@\" to %@", msg, gLastThreadID);
        } else { MI_log(@"No send btn. Dumping..."); MI_dumpViewFile(r); }
    });
}

static void MI_send(NSString *msg, NSString *tid, BOOL grp, NSString *dly) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *u = grp
            ? [NSString stringWithFormat:@"fb-messenger://group-thread/%@", tid]
            : [NSString stringWithFormat:@"fb-messenger://user-thread/%@", tid];
        NSURL *url = [NSURL URLWithString:u];
        if (!url) { MI_log(@"Bad URL %@", u); return; }
        MI_log(@"Open: %@", u);
        double d = dly.length > 0 ? MAX([dly doubleValue], 0.5) : 2.5;
        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:^(BOOL ok) {
            if (!ok) { MI_log(@"openURL failed"); return; }
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ MI_typeSend(msg); });
        }];
    });
}

// ============================================================
// Handlers
// ============================================================
static void MI_hDump(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *r = [UIApplication sharedApplication].keyWindow.rootViewController.view;
        if (!r) { MI_log(@"DUMP: no root"); return; }
        MI_dumpViewFile(r);
    });
}

static void MI_hFindDB(void) {
    MI_progress(@"hFindDB: start");
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @try {
            NSString *path = MI_findDatabase();
            dispatch_async(dispatch_get_main_queue(), ^{
                if (path) {
                    NSFileManager *fm = [NSFileManager defaultManager];
                    NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
                    unsigned long long sz = [attrs[NSFileSize] unsignedLongLongValue];
                    MI_postResult(@"findDB", [NSString stringWithFormat:@"SELECTED: %@\nSize: %.1f MB", path, sz / 1048576.0]);
                } else {
                    MI_postResult(@"findDB", @"No .db files found.");
                }
            });
        } @catch (NSException *e) {
            dispatch_async(dispatch_get_main_queue(), ^{
                MI_postResult(@"findDB", [NSString stringWithFormat:@"Exception: %@ - %@", e.name, e.reason]);
            });
        }
    });
}

static void MI_hSchema(void) {
    MI_progress(@"hSchema: start");
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @try {
            NSString *dbPath = MI_findDatabase();
            if (!dbPath.length) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    MI_postResult(@"schema", @"No database found.");
                });
                return;
            }
            MI_dumpSchema(dbPath);
            NSString *out = [NSTemporaryDirectory() stringByAppendingPathComponent:@"mi_schema.txt"];
            NSString *content = [NSString stringWithContentsOfFile:out encoding:NSUTF8StringEncoding error:nil];
            dispatch_async(dispatch_get_main_queue(), ^{
                MI_postResult(@"schema", content.length > 0 ? content : @"Schema file empty.");
            });
        } @catch (NSException *e) {
            dispatch_async(dispatch_get_main_queue(), ^{
                MI_postResult(@"schema", [NSString stringWithFormat:@"Exception: %@ - %@", e.name, e.reason]);
            });
        }
    });
}

static void MI_hSample(void) {
    MI_progress(@"hSample: start");
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @try {
            NSString *dbPath = MI_findDatabase();
            if (!dbPath.length) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    MI_postResult(@"sample", @"No database found.");
                });
                return;
            }
            MI_dumpSample(dbPath);
            NSString *out = [NSTemporaryDirectory() stringByAppendingPathComponent:@"mi_sample.txt"];
            NSString *content = [NSString stringWithContentsOfFile:out encoding:NSUTF8StringEncoding error:nil];
            dispatch_async(dispatch_get_main_queue(), ^{
                MI_postResult(@"sample", content.length > 0 ? content : @"Sample file empty.");
            });
        } @catch (NSException *e) {
            dispatch_async(dispatch_get_main_queue(), ^{
                MI_postResult(@"sample", [NSString stringWithFormat:@"Exception: %@ - %@", e.name, e.reason]);
            });
        }
    });
}

// ============================================================
// Crash dump handler (returns crash log if exists)
// ============================================================
static void MI_hGetCrashLog(void);
static void MI_hListFiles(void);

// ============================================================
// List files (dump directory tree of key dirs)
// ============================================================
static void MI_hListFiles(void) {
    MI_progress(@"listFiles: start");
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @try {
            NSFileManager *fm = [NSFileManager defaultManager];
            NSString *home = NSHomeDirectory();
            NSMutableString *result = [NSMutableString string];
            [result appendFormat:@"=== File Listing ===\nHome: %@\n\n", home];

            NSArray *dirs = @[
                [home stringByAppendingPathComponent:@"Library/Application Support"],
                [home stringByAppendingPathComponent:@"Library/Application Support/Papaya"],
                [home stringByAppendingPathComponent:@"Documents"],
            ];
            for (NSString *dir in dirs) {
                [result appendFormat:@"\n--- %@ ---\n", dir];
                if (![fm fileExistsAtPath:dir]) { [result appendString:@"(not found)\n"]; continue; }
                NSDirectoryEnumerator *en = [fm enumeratorAtPath:dir];
                NSString *rel;
                int count = 0;
                while ((rel = [en nextObject]) && count < 200) {
                    NSString *full = [dir stringByAppendingPathComponent:rel];
                    NSDictionary *attrs = [fm attributesOfItemAtPath:full error:nil];
                    NSString *type = attrs[NSFileType];
                    unsigned long long sz = [attrs[NSFileSize] unsignedLongLongValue];
                    if ([type isEqualToString:NSFileTypeDirectory]) {
                        [result appendFormat:@"[DIR]  %@\n", rel];
                    } else {
                        [result appendFormat:@"       %@ (%llu B)\n", rel, sz];
                    }
                    count++;
                }
                if (count >= 200) [result appendString:@"... (truncated at 200 entries)\n"];
            }

            // AppGroup directories
            NSMutableArray<NSString *> *appGroupPaths = [NSMutableArray array];
            NSArray *fbGroupIDs = @[
                @"group.com.facebook.Messenger", @"group.com.facebook.Messenger.group",
                @"group.com.facebook.Messenger.shared", @"group.com.facebook.Messenger.files",
                @"group.com.facebook.Messenger.internal", @"group.com.facebook.Messenger.LightSpeed",
                @"group.com.facebook.lightspeed", @"group.com.facebook",
                @"group.com.facebook.Messenger.uploadtasks"
            ];
            for (NSString *gid in fbGroupIDs) {
                NSURL *url = [fm containerURLForSecurityApplicationGroupIdentifier:gid];
                if (url) [appGroupPaths addObject:url.path];
            }
            NSString *sharedBase = @"/var/mobile/Containers/Shared/AppGroup";
            NSArray *groups = [fm contentsOfDirectoryAtPath:sharedBase error:nil];
            for (NSString *g in groups) {
                NSString *gp = [sharedBase stringByAppendingPathComponent:g];
                if (![appGroupPaths containsObject:gp]) [appGroupPaths addObject:gp];
            }

            for (NSString *gp in appGroupPaths) {
                [result appendFormat:@"\n--- AppGroup: %@ ---\n", gp];
                if (![fm fileExistsAtPath:gp]) { [result appendString:@"(not found)\n"]; continue; }
                NSDirectoryEnumerator *en = [fm enumeratorAtPath:gp];
                NSString *rel;
                int count = 0;
                while ((rel = [en nextObject]) && count < 200) {
                    NSString *full = [gp stringByAppendingPathComponent:rel];
                    NSDictionary *attrs = [fm attributesOfItemAtPath:full error:nil];
                    NSString *type = attrs[NSFileType];
                    unsigned long long sz = [attrs[NSFileSize] unsignedLongLongValue];
                    if ([type isEqualToString:NSFileTypeDirectory]) {
                        [result appendFormat:@"[DIR]  %@\n", rel];
                    } else {
                        [result appendFormat:@"       %@ (%llu B)\n", rel, sz];
                    }
                    count++;
                }
                if (count >= 200) [result appendString:@"... (truncated at 200 entries)\n"];
            }

            NSString *res = [result copy];
            dispatch_async(dispatch_get_main_queue(), ^{
                MI_postResult(@"listFiles", res);
            });
        } @catch (NSException *e) {
            dispatch_async(dispatch_get_main_queue(), ^{
                MI_postResult(@"listFiles", [NSString stringWithFormat:@"Exception: %@ - %@", e.name, e.reason]);
            });
        }
    });
    MI_progress(@"listFiles: dispatched");
}

static void MI_hGetCrashLog(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *crash = [NSString stringWithContentsOfFile:MI_crashFile() encoding:NSUTF8StringEncoding error:nil];
        NSString *progress = [NSString stringWithContentsOfFile:MI_progressFile() encoding:NSUTF8StringEncoding error:nil];
        NSMutableString *result = [NSMutableString string];
        if (crash.length > 0) {
            [result appendFormat:@"=== CRASH LOG ===\n%@\n\n", crash];
        } else {
            [result appendString:@"No crash log found.\n\n"];
        }
        if (progress.length > 0) {
            // Extract only DB: lines and key progress lines (not truncated)
            NSArray *lines = [progress componentsSeparatedByString:@"\n"];
            NSMutableString *dbList = [NSMutableString string];
            NSMutableString *keyLog = [NSMutableString string];
            for (NSString *line in lines) {
                if ([line containsString:@"  DB:"]) {
                    [dbList appendFormat:@"%@\n", line];
                } else if ([line containsString:@"findDB:"] || [line containsString:@"AppGroup"] || [line containsString:@"ERROR"] || [line containsString:@"selected"] || [line containsString:@"scanned"]) {
                    [keyLog appendFormat:@"%@\n", line];
                }
            }
            [result appendFormat:@"=== KEY LOG ===\n%@", keyLog];
            [result appendFormat:@"\n=== DB LIST ===\n%@", dbList.length > 0 ? dbList : @"(no DBs found)"];
        } else {
            [result appendString:@"No progress log found."];
        }
        MI_postResult(@"crashlog", result);
    });
}

// ============================================================
// Constructor
// ============================================================
__attribute__((constructor))
static void MI_ctor(void) {
    // Install crash handlers immediately
    NSSetUncaughtExceptionHandler(MI_crashHandler);
    signal(SIGABRT, MI_signalHandler);
    signal(SIGSEGV, MI_signalHandler);
    signal(SIGBUS, MI_signalHandler);
    signal(SIGILL, MI_signalHandler);
    signal(SIGFPE, MI_signalHandler);

    MI_progress(@"ctor: dylib loaded, crash handlers installed");

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSDistributedNotificationCenter *dnc = [NSDistributedNotificationCenter defaultCenter];

        [dnc addObserverForName:kNotifySend object:nil queue:[NSOperationQueue mainQueue]
            usingBlock:^(NSNotification *n) {
                @try {
                    NSString *m = n.userInfo[kKeyMessage], *t = n.userInfo[kKeyThreadID];
                    BOOL g = [n.userInfo[kKeyIsGroup] boolValue];
                    if (!m.length || !t.length) { MI_log(@"Missing msg/tid"); return; }
                    gLastThreadID = t;
                    MI_send(m, t, g, n.userInfo[kKeyDelay]);
                } @catch (NSException *e) {
                    MI_progress([NSString stringWithFormat:@"send: EXCEPTION %@ - %@", e.name, e.reason]);
                }
            }];
        [dnc addObserverForName:kNotifyDump object:nil queue:[NSOperationQueue mainQueue]
            usingBlock:^(NSNotification *n) { @try { MI_hDump(); } @catch (NSException *e) { MI_progress([NSString stringWithFormat:@"dump: %@", e.name]); } }];
        [dnc addObserverForName:kNotifyFindDB object:nil queue:[NSOperationQueue mainQueue]
            usingBlock:^(NSNotification *n) { @try { MI_hFindDB(); } @catch (NSException *e) { MI_progress([NSString stringWithFormat:@"findDB: %@", e.name]); } }];
        [dnc addObserverForName:kNotifySchema object:nil queue:[NSOperationQueue mainQueue]
            usingBlock:^(NSNotification *n) { @try { MI_hSchema(); } @catch (NSException *e) { MI_progress([NSString stringWithFormat:@"schema: %@", e.name]); } }];
        [dnc addObserverForName:kNotifySample object:nil queue:[NSOperationQueue mainQueue]
            usingBlock:^(NSNotification *n) { @try { MI_hSample(); } @catch (NSException *e) { MI_progress([NSString stringWithFormat:@"sample: %@", e.name]); } }];
        [dnc addObserverForName:kNotifyThreads object:nil queue:[NSOperationQueue mainQueue]
            usingBlock:^(NSNotification *n) { @try { MI_hThreads(); } @catch (NSException *e) { MI_progress([NSString stringWithFormat:@"threads: %@", e.name]); } }];
        [dnc addObserverForName:kNotifyInject object:nil queue:[NSOperationQueue mainQueue]
            usingBlock:^(NSNotification *n) {
                @try {
                    NSString *tid = n.userInfo[kKeyThreadID];
                    NSArray *msgs = n.userInfo[kKeyMessages];
                    if (!tid.length || !msgs.count) {
                        MI_postResult(@"inject", @"Missing threadId or messages.");
                        return;
                    }
                    MI_hInject(tid, msgs);
                } @catch (NSException *e) {
                    MI_progress([NSString stringWithFormat:@"inject block: %@", e.name]);
                }
            }];
        [dnc addObserverForName:@"com.messenger.injector.crashLog" object:nil queue:[NSOperationQueue mainQueue]
            usingBlock:^(NSNotification *n) { @try { MI_hGetCrashLog(); } @catch (NSException *e) {} }];
        [dnc addObserverForName:@"com.messenger.injector.listFiles" object:nil queue:[NSOperationQueue mainQueue]
            usingBlock:^(NSNotification *n) { @try { MI_hListFiles(); } @catch (NSException *e) {} }];

        [dnc postNotificationName:kNotifyReady object:nil
            userInfo:@{@"dylib":@"MessengerInjector",@"version":@"2.0"}
            deliverImmediately:YES];
        MI_progress(@"ctor: v2.0 ready — send, dump, findDB, schema, sample, threads, inject, crashLog");
    });
}
