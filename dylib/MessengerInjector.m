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
#import <fcntl.h>
#import <unistd.h>
#import <string.h>
#import <ctype.h>
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
static NSString *const kNotifyResearch = @"com.messenger.injector.research";
static NSString *const kNotifyInject  = @"com.messenger.injector.inject";
static NSString *const kNotifySniff   = @"com.messenger.injector.sniff";
static NSString *const kNotifyDeepScan = @"com.messenger.injector.deepscan";
static NSString *const kNotifyThreadRow = @"com.messenger.injector.threadrow";

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
// Static C buffer for signal handler (async-signal-safe, no ObjC)
static char g_crashFilePath[1024] = {0};

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
    // Async-signal-safe: only use write() and backtrace (no ObjC messaging)
    void *callstack[32];
    int frames = backtrace(callstack, 32);
    // Write to crash file if path was set by constructor
    if (g_crashFilePath[0] != 0) {
        int fd = open(g_crashFilePath, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (fd >= 0) {
            char buf[256];
            int len = snprintf(buf, sizeof(buf), "Signal %d\nBacktrace:\n", sig);
            write(fd, buf, len);
            backtrace_symbols_fd(callstack, frames, fd);
            close(fd);
        }
    }
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

static BOOL MI_hasMessagesTable(NSString *path) {
    // Check if DB has a 'messages' table
    sqlite3 *db = NULL;
    if (sqlite3_open_v2(path.UTF8String, &db, SQLITE_OPEN_READONLY, NULL) != SQLITE_OK) {
        if (db) sqlite3_close(db);
        return NO;
    }
    sqlite3_busy_timeout(db, 2000);
    sqlite3_stmt *st = NULL;
    BOOL found = NO;
    if (sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type='table' AND name='messages' LIMIT 1", -1, &st, NULL) == SQLITE_OK) {
        if (sqlite3_step(st) == SQLITE_ROW) found = YES;
        sqlite3_finalize(st);
    }
    sqlite3_close(db);
    return found;
}

static NSString *MI_esc(NSString *s) {
    if (!s) return @"";
    return [s stringByReplacingOccurrencesOfString:@"'" withString:@"''"];
}

// Dummy SQLite function: returns 0 (Messenger registers custom functions on its connection;
// our external connection doesn't have them, so triggers fail on INSERT)
static void MI_dummy_zero(sqlite3_context *ctx, int argc, sqlite3_value **argv) {
    sqlite3_result_int(ctx, 0);
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
static void MI_hResearch(NSString *threadId, NSString *mode);
static void MI_hInject(NSString *threadId, NSArray *messages);
static void MI_hSniff(NSString *threadId);
static void MI_hDeepScan(NSString *needle);
static void MI_hThreadRow(NSString *threadId);
static void MI_sniffInto(sqlite3 *db, NSString *threadId, long long threadPk, NSMutableString *r);
static void MI_compareRealVsInjected(sqlite3 *db, NSMutableString *r);
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

    MI_progress([NSString stringWithFormat:@"findDB: %d SQLite .db files total", (int)allDBs.count]);
    for (NSString *db in allDBs) {
        NSDictionary *attrs = [fm attributesOfItemAtPath:db error:nil];
        unsigned long long sz = [attrs[NSFileSize] unsignedLongLongValue];
        MI_progress([NSString stringWithFormat:@"  DB: %@ (%.1f KB)", db, sz / 1024.0]);
    }

    // PRIORITY 1: DB named lightspeed-<digits>.db at root of AppGroup (real messages DB)
    NSString *best = nil;
    for (NSString *db in allDBs) {
        NSString *fname = [db lastPathComponent];
        // Match lightspeed-<digits>.db exactly (not lightspeed-imageCache, lightspeed-TAMStorage, etc.)
        if ([fname hasPrefix:@"lightspeed-"] && [fname hasSuffix:@".db"]) {
            // Extract middle part and check if it's all digits
            NSString *mid = [fname substringWithRange:NSMakeRange(11, fname.length - 14)]; // skip "lightspeed-" and ".db"
            BOOL allDigits = mid.length > 0;
            for (NSUInteger i = 0; i < mid.length; i++) {
                if (!isdigit([mid characterAtIndex:i])) { allDigits = NO; break; }
            }
            if (allDigits) {
                best = db;
                MI_progress([NSString stringWithFormat:@"findDB: matched lightspeed-<digits>.db pattern: %@", db]);
                break;
            }
        }
    }

    // PRIORITY 2: DB with both 'messages' AND 'contacts' tables (msys schema)
    if (!best) {
        MI_progress(@"findDB: checking for messages+contacts tables...");
        for (NSString *db in allDBs) {
            if (MI_hasMessagesTable(db)) {
                // Also check for contacts table
                sqlite3 *cdb = NULL;
                if (sqlite3_open_v2(db.UTF8String, &cdb, SQLITE_OPEN_READONLY, NULL) == SQLITE_OK) {
                    sqlite3_stmt *cs = NULL;
                    if (sqlite3_prepare_v2(cdb, "SELECT name FROM sqlite_master WHERE type='table' AND name='contacts' LIMIT 1", -1, &cs, NULL) == SQLITE_OK) {
                        if (sqlite3_step(cs) == SQLITE_ROW) {
                            best = db;
                            MI_progress([NSString stringWithFormat:@"findDB: FOUND messages+contacts in %@", db]);
                        }
                        sqlite3_finalize(cs);
                    }
                    sqlite3_close(cdb);
                }
                if (best) break;
            }
        }
    }

    // PRIORITY 3: DB with 'messages' table only
    if (!best) {
        MI_progress(@"findDB: checking for messages table only...");
        for (NSString *db in allDBs) {
            if (MI_hasMessagesTable(db)) {
                best = db;
                MI_progress([NSString stringWithFormat:@"findDB: FOUND messages table in %@", db]);
                break;
            }
        }
    }

    // PRIORITY 4: lightspeed > msys > MDCore > messaging > largest
    if (!best) for (NSString *db in allDBs) {
        if ([db containsString:@"lightspeed"]) { best = db; break; }
    }
    if (!best) for (NSString *db in allDBs) {
        if ([db containsString:@"msys"]) { best = db; break; }
    }
    if (!best) for (NSString *db in allDBs) {
        if ([db containsString:@"MDCore"] || [db containsString:@"mdcore"]) { best = db; break; }
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

        // Parse local user ID from filename:
        //   - lightspeed-<userid>.db (old pattern)
        //   - <userid>.db in lightspeed-userDatabases/ dir (current pattern)
        NSString *fname = [best lastPathComponent];
        NSString *withoutExt = [fname stringByDeletingPathExtension];
        
        // Check if filename is all digits (userDatabases/<userid>.db pattern)
        BOOL allDigits = withoutExt.length > 0;
        for (NSUInteger i = 0; i < withoutExt.length; i++) {
            if (!isdigit([withoutExt characterAtIndex:i])) { allDigits = NO; break; }
        }
        
        if (allDigits) {
            gLocalUserID = withoutExt;
            MI_progress([NSString stringWithFormat:@"findDB: localUserID=%@ (from filename)", withoutExt]);
        } else {
            // Try lightspeed-<userid>.db pattern
            NSRange dashRange = [fname rangeOfString:@"-"];
            if (dashRange.location != NSNotFound) {
                NSRange dotRange = [fname rangeOfString:@"."];
                NSUInteger end = (dotRange.location != NSNotFound) ? dotRange.location : fname.length;
                NSString *uid = [fname substringWithRange:NSMakeRange(dashRange.location + 1, end - dashRange.location - 1)];
                if (uid.length > 0 && uid.longLongValue > 0) {
                    gLocalUserID = uid;
                    MI_progress([NSString stringWithFormat:@"findDB: localUserID=%@ (from lightspeed- prefix)", uid]);
                }
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
// Thread list — scan + return JSON for helper UI
// ============================================================
static void MI_hThreads(void) {
    MI_progress(@"threads: start");
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @try {
            NSString *dbPath = MI_findDatabase();
            if (!dbPath.length) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    MI_postResult(@"threads", @"No database found.");
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

            // Local user id from DB filename (<uid>.db)
            NSString *fname = dbPath.lastPathComponent ?: @"";
            NSString *localUid = @"";
            { NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"^([0-9]+)\\.db$" options:0 error:NULL];
              NSTextCheckingResult *m = [re firstMatchInString:fname options:0 range:NSMakeRange(0, fname.length)];
              if (m.numberOfRanges > 1) localUid = [fname substringWithRange:[m rangeAtIndex:1]]; }

            // PASS 1 (single scan): for each client thread, who (non-local) sent the most
            // messages. Proven resolver: other party of a 1-on-1 = top non-local sender.
            NSMutableDictionary *bestSender = [NSMutableDictionary dictionary]; // pk -> @{id,n}
            {
                sqlite3_stmt *s1 = NULL;
                NSString *q1 = nil;
                if (localUid.length > 0) {
                    q1 = [NSString stringWithFormat:
                        @"SELECT thread_pk, sender_contact_pk, COUNT(*) c FROM client_messages "
                         "WHERE sender_contact_pk IS NOT NULL AND sender_contact_pk != %@ "
                         "GROUP BY thread_pk, sender_contact_pk ORDER BY c DESC LIMIT 4000", localUid];
                } else {
                    q1 = @"SELECT thread_pk, sender_contact_pk, COUNT(*) c FROM client_messages "
                          "WHERE sender_contact_pk IS NOT NULL "
                          "GROUP BY thread_pk, sender_contact_pk ORDER BY c DESC LIMIT 4000";
                }
                if (sqlite3_prepare_v2(db, q1.UTF8String, -1, &s1, NULL) == SQLITE_OK) {
                    while (sqlite3_step(s1) == SQLITE_ROW) {
                        long long pk = sqlite3_column_int64(s1, 0);
                        long long sid = sqlite3_column_int64(s1, 1);
                        long long n = sqlite3_column_int64(s1, 2);
                        NSString *key = [NSString stringWithFormat:@"%lld", pk];
                        if (bestSender[key] == nil && n >= 3) { // n>=3 skips leftover test injections
                            bestSender[key] = [NSMutableDictionary dictionary];
                            bestSender[key][@"id"] = [NSString stringWithFormat:@"%lld", sid];
                            bestSender[key][@"n"] = @(n);
                        }
                    }
                    sqlite3_finalize(s1);
                }
            }
            MI_progress([NSString stringWithFormat:@"threads: senders mapped (%d)", (int)bestSender.count]);

            // PASS 2: all materialized chats with names
            NSMutableArray *threads = [NSMutableArray array];
            {
                sqlite3_stmt *s2 = NULL;
                if (sqlite3_prepare_v2(db, "SELECT pk, default_thread_name FROM client_threads ORDER BY pk LIMIT 300", -1, &s2, NULL) == SQLITE_OK) {
                    while (sqlite3_step(s2) == SQLITE_ROW) {
                        long long pk = sqlite3_column_int64(s2, 0);
                        NSString *name = MI_cstr(sqlite3_column_text(s2, 1));
                        if (name.length == 0 || [name isEqualToString:@"NULL"]) name = [NSString stringWithFormat:@"Thread %lld", pk];
                        NSString *key = [NSString stringWithFormat:@"%lld", pk];
                        NSDictionary *bs = bestSender[key];
                        NSMutableDictionary *t = [NSMutableDictionary dictionary];
                        t[@"k"] = bs[@"id"] ?: @"";
                        t[@"n"] = name;
                        t[@"p"] = [NSString stringWithFormat:@"%lld", pk];
                        t[@"t"] = bs[@"n"] ?: @(0);
                        [threads addObject:t];
                    }
                    sqlite3_finalize(s2);
                }
            }

            // PASS 3: chats without a resolved FB ID -> try entity_id in profile URL columns
            for (NSMutableDictionary *t in threads) {
                if ([t[@"k"] length] > 0) continue;
                sqlite3_stmt *s3 = NULL;
                NSString *q3 = [NSString stringWithFormat:
                    @"SELECT default_other_participant_profile_picture_fallback_url_list, "
                     "default_other_participant_profile_picture_url_list FROM client_threads WHERE pk = %@ LIMIT 1", t[@"p"]];
                if (sqlite3_prepare_v2(db, q3.UTF8String, -1, &s3, NULL) == SQLITE_OK) {
                    if (sqlite3_step(s3) == SQLITE_ROW) {
                        NSMutableString *urls = [NSMutableString string];
                        for (int c = 0; c < 2; c++) { NSString *v = MI_cstr(sqlite3_column_text(s3, c)); if (v.length > 0) [urls appendString:v]; }
                        NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"entity_id=([0-9]+)" options:0 error:NULL];
                        NSTextCheckingResult *m = [re firstMatchInString:urls options:0 range:NSMakeRange(0, urls.length)];
                        if (m.numberOfRanges > 1) t[@"k"] = [urls substringWithRange:[m rangeAtIndex:1]];
                    }
                    sqlite3_finalize(s3);
                }
            }

            sqlite3_close(db);

            // Sort by name
            [threads sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
                return [a[@"n"] compare:b[@"n"] options:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch];
            }];

            NSData *jsonData = [NSJSONSerialization dataWithJSONObject:threads options:0 error:nil];
            NSString *jsonStr = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];

            dispatch_async(dispatch_get_main_queue(), ^{
                MI_postResult(@"threadList", jsonStr ?: @"[]");
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
// Bounded thread_pk bridge + query deadline guard
// ============================================================
// The old approach JOINed client_messages × messages on a CAST key:
// unindexed full cross-scan (O(N×M)) → hung the inject for minutes.
// Bounded approach: collect ≤N offline_threading_ids for the thread,
// then ONE IN-list lookup in client_messages (single pass max).

struct MIQueryDeadline { double deadline; };
static int MI_progress_cb(void *ud) {
    struct MIQueryDeadline *d = (struct MIQueryDeadline *)ud;
    return (CFAbsoluteTimeGetCurrent() > d->deadline) ? 1 : 0;
}
// NOTE: d must outlive the queries that run while armed (caller-owned).
static void MI_armDeadline(sqlite3 *db, struct MIQueryDeadline *d, double seconds) {
    d->deadline = CFAbsoluteTimeGetCurrent() + seconds;
    sqlite3_progress_handler(db, 10000, MI_progress_cb, d);
}
static void MI_disarmDeadline(sqlite3 *db) {
    sqlite3_progress_handler(db, 0, NULL, NULL);
}

static long long MI_bridgeResolve(sqlite3 *db, NSString *threadKey, long long limit, NSString **outDetail) {
    struct MIQueryDeadline dl;
    MI_armDeadline(db, &dl, 10.0);
    long long bestPk = 0;
    NSMutableArray *ids = [NSMutableArray array];
    sqlite3_stmt *s1 = NULL;
    NSString *q1 = [NSString stringWithFormat:
        @"SELECT offline_threading_id FROM messages WHERE thread_key = '%@' LIMIT %lld",
        MI_esc(threadKey), limit];
    if (sqlite3_prepare_v2(db, q1.UTF8String, -1, &s1, NULL) == SQLITE_OK) {
        while (sqlite3_step(s1) == SQLITE_ROW) {
            [ids addObject:[NSString stringWithFormat:@"%lld", sqlite3_column_int64(s1, 0)]];
        }
        sqlite3_finalize(s1);
    }
    if (ids.count == 0) {
        MI_disarmDeadline(db);
        *outDetail = @"no messages for thread";
        return 0;
    }
    NSMutableArray *vals = [NSMutableArray array];
    for (NSString *i in ids) [vals addObject:[NSString stringWithFormat:@"'%@'", i]];
    NSString *q2 = [NSString stringWithFormat:
        @"SELECT thread_pk, COUNT(*) FROM client_messages WHERE resonance_offline_threading_id IN (%@) "
        @"GROUP BY thread_pk ORDER BY COUNT(*) DESC LIMIT 3", [vals componentsJoinedByString:@","]];
    sqlite3_stmt *s2 = NULL;
    if (sqlite3_prepare_v2(db, q2.UTF8String, -1, &s2, NULL) == SQLITE_OK) {
        NSMutableArray *det = [NSMutableArray array];
        while (sqlite3_step(s2) == SQLITE_ROW) {
            long long pk = sqlite3_column_int64(s2, 0);
            long long n = sqlite3_column_int64(s2, 1);
            [det addObject:[NSString stringWithFormat:@"pk=%lld(n=%lld)", pk, n]];
            if (bestPk == 0) bestPk = pk;
        }
        sqlite3_finalize(s2);
        *outDetail = det.count > 0 ? [det componentsJoinedByString:@", "] : @"no client match";
    } else {
        *outDetail = [NSString stringWithFormat:@"SQL: %s", sqlite3_errmsg(db)];
    }
    MI_disarmDeadline(db);
    return bestPk;
}

// Normalize a display name for comparison: fold case + strip diacritics.
// "Trứnh Đừc Linh" -> "trinh duc linh"; "Trinh Duc Linh" -> "trinh duc linh"
static NSString *MI_normalizeName(NSString *s) {
    if (s.length == 0) return @"";
    CFMutableStringRef cf = CFStringCreateMutableCopy(NULL, s.length + 16, (__bridge CFStringRef)s);
    CFStringTransform(cf, NULL, kCFStringTransformToLatin, false);
    CFStringTransform(cf, NULL, kCFStringTransformStripDiacritics, false);
    NSString *out = CFBridgingRelease(cf);
    return [[out stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] lowercaseString];
}

static void MI_hResearch(NSString *threadIdIn, NSString *mode) {
    __block NSString *threadId = threadIdIn;
    MI_progress([NSString stringWithFormat:@"research(%@): start %@", mode ?: @"map", threadId ?: @"-"]);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @try {
            NSMutableString *r = [NSMutableString string];
            NSString *dbPath = MI_findDatabase();
            if (!dbPath.length) { MI_postResult(@"research", @"No database found."); return; }
            sqlite3 *db = NULL;
            if (sqlite3_open_v2(dbPath.UTF8String, &db, SQLITE_OPEN_READONLY, NULL) != SQLITE_OK) {
                MI_postResult(@"research", [NSString stringWithFormat:@"DB open failed: %s", db ? sqlite3_errmsg(db) : "null"]);
                if (db) sqlite3_close(db);
                return;
            }
            sqlite3_busy_timeout(db, 5000);

            if ([mode isEqualToString:@"sql"]) {
                [r appendString:@"=== SQL LOGIC (app's own views/triggers/indexes) ===\n"];
                {
                    sqlite3_stmt *s0=NULL;
                    if (sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name", -1, &s0, NULL)==SQLITE_OK){
                        [r appendString:@"TABLES: "]; int n0=0;
                        while(sqlite3_step(s0)==SQLITE_ROW && n0<120){ [r appendFormat:@"%@ ", MI_cstr(sqlite3_column_text(s0,0)) ?: @"?"]; n0++; }
                        sqlite3_finalize(s0); [r appendString:@"\n"]; }
                    sqlite3_stmt *s2=NULL; int n=0;
                    if (sqlite3_prepare_v2(db, "SELECT name, sql FROM sqlite_master WHERE type='view' AND sql IS NOT NULL ORDER BY name", -1, &s2, NULL)==SQLITE_OK){
                        while(sqlite3_step(s2)==SQLITE_ROW && n<12){ NSString *vs=MI_cstr(sqlite3_column_text(s2,1)) ?: @""; if (vs.length>130) vs=[vs substringToIndex:130]; [r appendFormat:@"[view %@] %@\n", MI_cstr(sqlite3_column_text(s2,0)) ?: @"?", vs]; n++; }
                        sqlite3_finalize(s2); if(!n) [r appendString:@"(no views)\n"]; }
                    sqlite3_stmt *st=NULL;
                    if (sqlite3_prepare_v2(db, "SELECT name, sql FROM sqlite_master WHERE type='trigger' AND sql IS NOT NULL ORDER BY name", -1, &st, NULL)==SQLITE_OK){
                        int n2=0; while(sqlite3_step(st)==SQLITE_ROW && n2<12){ NSString *ts=MI_cstr(sqlite3_column_text(st,1)) ?: @""; if (ts.length>130) ts=[ts substringToIndex:130]; [r appendFormat:@"[trigger %@] %@\n", MI_cstr(sqlite3_column_text(st,0)) ?: @"?", ts]; n2++; }
                        sqlite3_finalize(st); if(!n2) [r appendString:@"(no triggers)\n"]; }
                    sqlite3_stmt *si2=NULL;
                    if (sqlite3_prepare_v2(db, "SELECT tbl_name, name FROM sqlite_master WHERE type='index' AND sql IS NOT NULL AND tbl_name IN ('client_threads','client_messages','client_contacts','messages','threads','contacts') ORDER BY tbl_name LIMIT 25", -1, &si2, NULL)==SQLITE_OK){
                        int n3=0; while(sqlite3_step(si2)==SQLITE_ROW && n3<25){ [r appendFormat:@"[idx] %@.%@\n", MI_cstr(sqlite3_column_text(si2,0)) ?: @"?", MI_cstr(sqlite3_column_text(si2,1)) ?: @"?"]; n3++; }
                        sqlite3_finalize(si2); if(!n3) [r appendString:@"(no user indexes)\n"]; }
                }
            } else {
                // ---------- MODE: map (default) ----------
                [r appendFormat:@"=== MAPPING RESEARCH (target: %@) ===\n", threadId ?: @"(none)"];
                // name input support (same logic as inject Step 0)
                {
                    static NSRegularExpression *digitsOnly2;
                    static dispatch_once_t onceTok2;
                    dispatch_once(&onceTok2, ^{ digitsOnly2 = [NSRegularExpression regularExpressionWithPattern:@"^[0-9]+$" options:0 error:NULL]; });
                    if (threadId.length > 0 && [digitsOnly2 firstMatchInString:threadId options:0 range:NSMakeRange(0, threadId.length)] == nil) {
                        NSString *want = MI_normalizeName(threadId);
                        NSMutableArray *ids = [NSMutableArray array];
                        sqlite3_stmt *sn = NULL;
                        if (sqlite3_prepare_v2(db, "SELECT id, name FROM contacts", -1, &sn, NULL) == SQLITE_OK) {
                            while (sqlite3_step(sn) == SQLITE_ROW) {
                                NSString *id = MI_cstr(sqlite3_column_text(sn, 0));
                                NSString *nm = MI_cstr(sqlite3_column_text(sn, 1));
                                if (id.length > 0 && nm.length > 0 && [MI_normalizeName(nm) isEqualToString:want]) { if (![ids containsObject:id]) [ids addObject:id]; [r appendFormat:@"contact match: %@ = %@\n", nm, id]; }
                            }
                            sqlite3_finalize(sn);
                        }
                        sqlite3_stmt *sc = NULL;
                        if (sqlite3_prepare_v2(db, "SELECT contact_id, displayed_name FROM client_contacts", -1, &sc, NULL) == SQLITE_OK) {
                            while (sqlite3_step(sc) == SQLITE_ROW) {
                                NSString *id = MI_cstr(sqlite3_column_text(sc, 0));
                                NSString *nm = MI_cstr(sqlite3_column_text(sc, 1));
                                if (id.length > 0 && nm.length > 0 && [MI_normalizeName(nm) isEqualToString:want]) { if (![ids containsObject:id]) [ids addObject:id]; [r appendFormat:@"client_contact match: %@ = %@\n", nm, id]; }
                            }
                            sqlite3_finalize(sc);
                        }
                        if (ids.count == 1) { threadId = ids.firstObject; [r appendFormat:@"name resolved to ID: %@\n", threadId]; }
                        else if (ids.count == 0) { [r appendString:@"NO contact with this name — check spelling.\n"]; }
                        else { [r appendFormat:@"MULTIPLE matches: %@ — use the numeric ID.\n", [ids componentsJoinedByString:@", "]]; }
                    }
                }
                {
                    sqlite3_stmt *s2=NULL; int total=0;
                    if (sqlite3_prepare_v2(db, "SELECT pk, default_thread_name FROM client_threads ORDER BY pk LIMIT 200", -1, &s2, NULL)==SQLITE_OK) {
                        while (sqlite3_step(s2)==SQLITE_ROW) { [r appendFormat:@"%lld | %@\n", sqlite3_column_int64(s2,0), MI_cstr(sqlite3_column_text(s2,1)) ?: @"NULL"]; total++; }
                        sqlite3_finalize(s2);
                    }
                    [r appendFormat:@"(client_threads rows: %d)\n", total];
                }
                if (threadId.length > 0) {
                    NSMutableArray *cols=[NSMutableArray array];
                    sqlite3_stmt *ps=NULL;
                    if (sqlite3_prepare_v2(db, "PRAGMA table_info(client_threads)", -1, &ps, NULL)==SQLITE_OK) { while (sqlite3_step(ps)==SQLITE_ROW){ NSString *c=MI_cstr(sqlite3_column_text(ps,1)); if (c.length) [cols addObject:c]; } sqlite3_finalize(ps); }
                    NSMutableArray *conds=[NSMutableArray array];
                    for (NSString *c in cols) [conds addObject:[NSString stringWithFormat:@"\"%@\" LIKE '%%%@%%'", c, threadId]];
                    sqlite3_stmt *hs=NULL; NSMutableArray *pks=[NSMutableArray array];
                    if (conds.count>0) {
                        NSString *hq=[NSString stringWithFormat:@"SELECT pk FROM client_threads WHERE %@ LIMIT 5", [conds componentsJoinedByString:@" OR "]];
                        if (sqlite3_prepare_v2(db, hq.UTF8String, -1, &hs, NULL)==SQLITE_OK) { while (sqlite3_step(hs)==SQLITE_ROW) [pks addObject:[NSString stringWithFormat:@"%lld", sqlite3_column_int64(hs,0)]]; sqlite3_finalize(hs); }
                    }
                    [r appendFormat:@"row_scan(target): %@\n", pks.count?[pks componentsJoinedByString:@","]:(@"NO MATCH")];
                }
                {
                    NSMutableArray *det=[NSMutableArray array]; sqlite3_stmt *s2=NULL;
                    NSString *q=@"SELECT thread_pk, COUNT(*) c FROM client_messages WHERE sender_contact_pk = 1002754957 GROUP BY thread_pk ORDER BY c DESC LIMIT 3";
                    if (sqlite3_prepare_v2(db, q.UTF8String, -1, &s2, NULL)==SQLITE_OK){ while (sqlite3_step(s2)==SQLITE_ROW) [det addObject:[NSString stringWithFormat:@"pk=%lld(n=%lld)", sqlite3_column_int64(s2,0), sqlite3_column_int64(s2,1)]]; sqlite3_finalize(s2); }
                    [r appendFormat:@"sender GT 1002754957: %@ (expect pk=410725001)\n", det.count?[det componentsJoinedByString:@","]:(@"none")];
                }
                if (threadId.length > 0) {
                    NSMutableArray *det=[NSMutableArray array]; sqlite3_stmt *s2=NULL;
                    NSString *q=[NSString stringWithFormat:@"SELECT thread_pk, COUNT(*) c FROM client_messages WHERE sender_contact_pk = %lld GROUP BY thread_pk ORDER BY c DESC LIMIT 3", threadId.longLongValue];
                    if (sqlite3_prepare_v2(db, q.UTF8String, -1, &s2, NULL)==SQLITE_OK){ while (sqlite3_step(s2)==SQLITE_ROW) [det addObject:[NSString stringWithFormat:@"pk=%lld(n=%lld)", sqlite3_column_int64(s2,0), sqlite3_column_int64(s2,1)]]; sqlite3_finalize(s2); }
                    [r appendFormat:@"sender target: %@\n", det.count?[det componentsJoinedByString:@","]:(@"none")];
                }
                if (threadId.length > 0) {
                    NSString *nm=@"NOT FOUND";
                    sqlite3_stmt *s2=NULL;
                    if (sqlite3_prepare_v2(db, [NSString stringWithFormat:@"SELECT name FROM contacts WHERE id='%@'", MI_esc(threadId)].UTF8String, -1, &s2, NULL)==SQLITE_OK){ if (sqlite3_step(s2)==SQLITE_ROW) nm=MI_cstr(sqlite3_column_text(s2,0)) ?: @"NULL"; sqlite3_finalize(s2); }
                    [r appendFormat:@"sync contact name: %@\n", nm];
                    sqlite3_stmt *s3=NULL; int cc=0;
                    NSString *q2=[NSString stringWithFormat:@"SELECT pk, contact_id, displayed_name FROM client_contacts WHERE contact_id='%@' LIMIT 3", MI_esc(threadId)];
                    if (sqlite3_prepare_v2(db, q2.UTF8String, -1, &s3, NULL)==SQLITE_OK){ while(sqlite3_step(s3)==SQLITE_ROW && cc<3){ [r appendFormat:@"client_contact: pk=%lld id=%@ name=%@\n", sqlite3_column_int64(s3,0), MI_cstr(sqlite3_column_text(s3,1)) ?: @"NULL", MI_cstr(sqlite3_column_text(s3,2)) ?: @"NULL"]; cc++; } sqlite3_finalize(s3); if(!cc) [r appendString:@"client_contact: NOT FOUND\n"]; }
                }
                if (threadId.length > 0) {
                    NSMutableArray *names=[NSMutableArray array];
                    sqlite3_stmt *sn=NULL;
                    NSString *qn=[NSString stringWithFormat:@"SELECT name FROM contacts WHERE id='%@' LIMIT 1", MI_esc(threadId)];
                    if (sqlite3_prepare_v2(db, qn.UTF8String, -1, &sn, NULL)==SQLITE_OK){ if (sqlite3_step(sn)==SQLITE_ROW) { NSString *nm=MI_cstr(sqlite3_column_text(sn,0)); if (nm.length) [names addObject:nm]; } sqlite3_finalize(sn); }
                    sqlite3_stmt *sn2=NULL;
                    NSString *qn2=[NSString stringWithFormat:@"SELECT displayed_name FROM client_contacts WHERE contact_id='%@' LIMIT 1", MI_esc(threadId)];
                    if (sqlite3_prepare_v2(db, qn2.UTF8String, -1, &sn2, NULL)==SQLITE_OK){ if (sqlite3_step(sn2)==SQLITE_ROW) { NSString *nm=MI_cstr(sqlite3_column_text(sn2,0)); if (nm.length) [names addObject:nm]; } sqlite3_finalize(sn2); }
                    NSString *result=@"no name found";
                    for (NSString *nm in names) {
                        NSString *want=MI_normalizeName(nm);
                        if (want.length<3) continue;
                        sqlite3_stmt *sa=NULL; NSMutableArray *hits=[NSMutableArray array];
                        if (sqlite3_prepare_v2(db, "SELECT pk, default_thread_name FROM client_threads LIMIT 500", -1, &sa, NULL)==SQLITE_OK) {
                            while (sqlite3_step(sa)==SQLITE_ROW) {
                                NSString *n1=MI_cstr(sqlite3_column_text(sa,1));
                                if (n1.length>0 && [MI_normalizeName(n1) isEqualToString:want]) [hits addObject:[NSString stringWithFormat:@"pk=%lld(%@)", sqlite3_column_int64(sa,0), n1]];
                            }
                            sqlite3_finalize(sa);
                        }
                        if (hits.count>0) { result=[NSString stringWithFormat:@"%@ -> %@", nm, [hits componentsJoinedByString:@","]]; break; }
                    }
                    [r appendFormat:@"name-match dry run: %@\n", result];
                }
                {
                    int c1=0,c2=0,c3=0;
                    sqlite3_stmt *s2=NULL;
                    if (sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM messages WHERE thread_key='1002754957'", -1, &s2, NULL)==SQLITE_OK){ if(sqlite3_step(s2)==SQLITE_ROW) c1=sqlite3_column_int(s2,0); sqlite3_finalize(s2); }
                    if (threadId.length>0) {
                        s2=NULL;
                        NSString *q=[NSString stringWithFormat:@"SELECT COUNT(*) FROM messages WHERE thread_key='%@'", MI_esc(threadId)];
                        if (sqlite3_prepare_v2(db, q.UTF8String, -1, &s2, NULL)==SQLITE_OK){ if(sqlite3_step(s2)==SQLITE_ROW) c2=sqlite3_column_int(s2,0); sqlite3_finalize(s2); }
                    }
                    if (sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM client_messages WHERE thread_pk=410725001", -1, &s2, NULL)==SQLITE_OK){ if(sqlite3_step(s2)==SQLITE_ROW) c3=sqlite3_column_int(s2,0); sqlite3_finalize(s2); }
                    [r appendFormat:@"counts: msgs(GT)=%d msgs(target)=%d client_msgs(GT pk)=%d\n", c1, c2, c3];
                }
            }
            sqlite3_close(db);
            MI_postResult(@"research", r);
        } @catch (NSException *e) {
            MI_postResult(@"research", [NSString stringWithFormat:@"Exception: %@\n%@", e.reason, e.callStackSymbols.description]);
        }
    });
}

// ============================================================
// Conversation injection (NEW v2.0)
// ============================================================
// ============================================================
// Snippet-source sniffer: dump EVERY table that holds snippet-like
// or last-activity data for the target thread, plus the top messages
// rows exactly as a renderer would order them. Decisive diagnostics.
// ============================================================
static void MI_hSniff(NSString *threadId) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @try {
            NSMutableString *r = [NSMutableString string];
            [r appendFormat:@"=== SNIFF (thread %@) ===\\n", threadId];
            NSString *dbPath = MI_findDatabase();
            if (!dbPath.length) { MI_postResult(@"progress", @"sniff: no DB"); return; }
            sqlite3 *db = NULL;
            if (sqlite3_open_v2(dbPath.UTF8String, &db, SQLITE_OPEN_READONLY, NULL) != SQLITE_OK) {
                MI_postResult(@"progress", @"sniff: DB open failed");
                if (db) sqlite3_close(db);
                return;
            }
            sqlite3_busy_timeout(db, 3000);

            // A) sync-layer threads rows (ALL matches)
            {
                sqlite3_stmt *st = NULL;
                if (sqlite3_prepare_v2(db, "SELECT thread_key, folder_name, substr(snippet,1,40), snippet_sender_contact_id, last_activity_timestamp_ms FROM threads WHERE thread_key = ? LIMIT 4", -1, &st, NULL) == SQLITE_OK) {
                    sqlite3_bind_text(st, 1, threadId.UTF8String, -1, SQLITE_TRANSIENT);
                    int n = 0;
                    while (sqlite3_step(st) == SQLITE_ROW && n < 4) {
                        [r appendFormat:@"threads[key=%@]: folder=%@ snippet='%@' sender=%@ lastAct=%lld\\n",
                            MI_cstr(sqlite3_column_text(st,0)) ?: @"?", MI_cstr(sqlite3_column_text(st,1)) ?: @"NULL",
                            MI_cstr(sqlite3_column_text(st,2)) ?: @"NULL", MI_cstr(sqlite3_column_text(st,3)) ?: @"NULL",
                            sqlite3_column_int64(st,4)];
                        n++;
                    }
                    sqlite3_finalize(st);
                    if (n == 0) [r appendString:@"threads: NO ROW for this key\\n"];
                }
            }

            // B) top sync messages as a renderer would pick (primary_sort_key DESC)
            {
                sqlite3_stmt *st = NULL;
                if (sqlite3_prepare_v2(db, "SELECT substr(text,1,25), sender_id, timestamp_ms, primary_sort_key, send_status, send_status_v3, local_data_id, message_rendering_type, is_hidden FROM messages WHERE thread_key = ? ORDER BY primary_sort_key DESC LIMIT 4", -1, &st, NULL) == SQLITE_OK) {
                    sqlite3_bind_text(st, 1, threadId.UTF8String, -1, SQLITE_TRANSIENT);
                    int n = 0;
                    while (sqlite3_step(st) == SQLITE_ROW && n < 4) {
                        [r appendFormat:@"msg#%d: '%@' sender=%@ ts=%lld psk=%lld ss=%d v3=%@ ldi=%@ mrt=%d hid=%@\\n",
                            n+1, MI_cstr(sqlite3_column_text(st,0)) ?: @"", MI_cstr(sqlite3_column_text(st,1)) ?: @"?",
                            sqlite3_column_int64(st,2), sqlite3_column_int64(st,3), sqlite3_column_int(st,4),
                            sqlite3_column_type(st,5)==SQLITE_NULL?@"NULL":@(sqlite3_column_int64(st,5)).stringValue,
                            sqlite3_column_type(st,6)==SQLITE_NULL?@"NULL":@(sqlite3_column_int64(st,6)).stringValue,
                            sqlite3_column_int(st,7),
                            sqlite3_column_type(st,8)==SQLITE_NULL?@"NULL":@(sqlite3_column_int64(st,8)).stringValue];
                        n++;
                    }
                    sqlite3_finalize(st);
                    if (n == 0) [r appendString:@"messages: NO ROWS\\n"];
                }
            }

            // C) resolve pk(s) then client layer
            NSMutableArray *pks = [NSMutableArray array];
            {
                // C1: row_scan (entity_id)
                sqlite3_stmt *ps = NULL;
                NSMutableArray *cols = [NSMutableArray array];
                if (sqlite3_prepare_v2(db, "PRAGMA table_info(client_threads)", -1, &ps, NULL) == SQLITE_OK) {
                    while (sqlite3_step(ps) == SQLITE_ROW) { NSString *c = MI_cstr(sqlite3_column_text(ps,1)); if (c.length > 0) [cols addObject:c]; }
                    sqlite3_finalize(ps);
                }
                if (cols.count > 0) {
                    NSMutableArray *conds = [NSMutableArray array];
                    for (NSString *c in cols) [conds addObject:[NSString stringWithFormat:@"\"%@\" LIKE '%%%@%%'", c, threadId]];
                    sqlite3_stmt *hs = NULL;
                    NSString *hq = [NSString stringWithFormat:@"SELECT pk FROM client_threads WHERE %@ LIMIT 3", [conds componentsJoinedByString:@" OR "]];
                    if (sqlite3_prepare_v2(db, hq.UTF8String, -1, &hs, NULL) == SQLITE_OK) {
                        while (sqlite3_step(hs) == SQLITE_ROW) [pks addObject:@(sqlite3_column_int64(hs,0))];
                        sqlite3_finalize(hs);
                    }
                }
                // C2: fallback - top sender thread
                if (pks.count == 0) {
                    sqlite3_stmt *hs = NULL;
                    NSString *hq = [NSString stringWithFormat:@"SELECT thread_pk FROM client_messages WHERE sender_contact_pk = ? GROUP BY thread_pk ORDER BY COUNT(*) DESC LIMIT 1"];
                    if (sqlite3_prepare_v2(db, hq.UTF8String, -1, &hs, NULL) == SQLITE_OK) {
                        sqlite3_bind_text(hs, 1, threadId.UTF8String, -1, SQLITE_TRANSIENT);
                        if (sqlite3_step(hs) == SQLITE_ROW) [pks addObject:@(sqlite3_column_int64(hs,0))];
                        sqlite3_finalize(hs);
                    }
                }
                [r appendFormat:@"resolved pk(s): %@\\n", pks.count > 0 ? [pks componentsJoinedByString:@","] : @"NONE"];
            }
            for (NSNumber *pk in pks) {
                sqlite3_stmt *st = NULL;
                NSString *q = [NSString stringWithFormat:
                    @"SELECT substr(snippet,1,40), snippet_message_pk, last_activity_timestamp_ms, default_thread_name FROM client_threads WHERE pk = %@", pk];
                if (sqlite3_prepare_v2(db, q.UTF8String, -1, &st, NULL) == SQLITE_OK) {
                    if (sqlite3_step(st) == SQLITE_ROW) {
                        [r appendFormat:@"client_threads[pk=%@]: snippet='%@' msgPk=%lld lastAct=%lld name=%@\\n",
                            pk, MI_cstr(sqlite3_column_text(st,0)) ?: @"NULL", sqlite3_column_int64(st,1),
                            sqlite3_column_int64(st,2), MI_cstr(sqlite3_column_text(st,3)) ?: @"NULL"];
                    }
                    sqlite3_finalize(st);
                }
                // top client_messages rows
                sqlite3_stmt *cm = NULL;
                NSString *q2 = [NSString stringWithFormat:@"SELECT substr(text,1,25), sender_contact_pk, authoritative_ts_ms, sort_order FROM client_messages WHERE thread_pk = %@ ORDER BY authoritative_ts_ms DESC LIMIT 3", pk];
                if (sqlite3_prepare_v2(db, q2.UTF8String, -1, &cm, NULL) == SQLITE_OK) {
                    int n = 0;
                    while (sqlite3_step(cm) == SQLITE_ROW && n < 3) {
                        [r appendFormat:@"cmsg#%d: '%@' sender=%@ ts=%lld so=%lld\\n", n+1,
                            MI_cstr(sqlite3_column_text(cm,0)) ?: @"", MI_cstr(sqlite3_column_text(cm,1)) ?: @"?",
                            sqlite3_column_int64(cm,2), sqlite3_column_int64(cm,3)];
                        n++;
                    }
                    sqlite3_finalize(cm);
                }
            }

            // D) EVERY other table with a snippet-ish column, matched to this thread
            {
                sqlite3_stmt *ts = NULL;
                NSMutableArray *tables = [NSMutableArray array];
                if (sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'", -1, &ts, NULL) == SQLITE_OK) {
                    while (sqlite3_step(ts) == SQLITE_ROW) { NSString *n = MI_cstr(sqlite3_column_text(ts,0)); if (n.length > 0) [tables addObject:n]; }
                    sqlite3_finalize(ts);
                }
                for (NSString *tbl in tables) {
                    sqlite3_stmt *pi = NULL;
                    NSMutableArray *snipCols = [NSMutableArray array];
                    NSString *keyCol = nil;
                    NSString *q = [NSString stringWithFormat:@"PRAGMA table_info(\"%@\")", tbl];
                    if (sqlite3_prepare_v2(db, q.UTF8String, -1, &pi, NULL) == SQLITE_OK) {
                        while (sqlite3_step(pi) == SQLITE_ROW) {
                            NSString *c = MI_cstr(sqlite3_column_text(pi,1));
                            if (!c.length) continue;
                            NSString *lc = c.lowercaseString;
                            if ([lc containsString:@"snippet"]) [snipCols addObject:c];
                            if (!keyCol && ([lc isEqualToString:@"thread_key"] || [lc isEqualToString:@"thread_pk"])) keyCol = c;
                        }
                        sqlite3_finalize(pi);
                    }
                    if (snipCols.count == 0 || !keyCol || [tbl isEqualToString:@"threads"] || [tbl isEqualToString:@"client_threads"]) continue;
                    // this table holds snippet data keyed by thread -> dump its row
                    sqlite3_stmt *rs = NULL;
                    NSMutableString *sel = [NSMutableString string];
                    for (NSString *c in snipCols) [sel appendFormat:@"substr(\"%@\",1,30), ", c];
                    NSString *rq = [NSString stringWithFormat:@"SELECT %@ \"%@\" FROM \"%@\" WHERE \"%@\" = ? LIMIT 2", sel, keyCol, tbl, keyCol];
                    if (sqlite3_prepare_v2(db, rq.UTF8String, -1, &rs, NULL) == SQLITE_OK) {
                        sqlite3_bind_text(rs, 1, threadId.UTF8String, -1, SQLITE_TRANSIENT);
                        while (sqlite3_step(rs) == SQLITE_ROW) {
                            NSMutableString *vals = [NSMutableString string];
                            for (int c = 0; c < (int)snipCols.count; c++) [vals appendFormat:@"%@='%@' ", snipCols[c], MI_cstr(sqlite3_column_text(rs,c)) ?: @"NULL"];
                            [r appendFormat:@"[%@] %@\\n", tbl, vals];
                        }
                        sqlite3_finalize(rs);
                    }
                }
            }

            sqlite3_close(db);
            NSString *out = r;
            dispatch_async(dispatch_get_main_queue(), ^{ MI_postResult(@"progress", out); });
        } @catch (NSException *e) {
            MI_postResult(@"progress", [NSString stringWithFormat:@"sniff exception: %@", e.reason]);
        }
    });
}

// Compact snippet-source scan appended to the inject report.
static void MI_sniffInto(sqlite3 *db, NSString *threadId, long long threadPk, NSMutableString *r) {
    // sync threads rows
    {
        sqlite3_stmt *st = NULL;
        if (sqlite3_prepare_v2(db, "SELECT folder_name, substr(snippet,1,30), last_activity_timestamp_ms FROM threads WHERE thread_key = ? LIMIT 3", -1, &st, NULL) == SQLITE_OK) {
            sqlite3_bind_text(st, 1, threadId.UTF8String, -1, SQLITE_TRANSIENT);
            int n = 0;
            while (sqlite3_step(st) == SQLITE_ROW && n < 3) {
                [r appendFormat:@"sniff threads: folder=%@ snippet='%@' lastAct=%lld\n",
                    MI_cstr(sqlite3_column_text(st,0)) ?: @"NULL", MI_cstr(sqlite3_column_text(st,1)) ?: @"NULL", sqlite3_column_int64(st,2)];
                n++;
            }
            sqlite3_finalize(st);
            if (n == 0) [r appendString:@"sniff threads: NO ROW\n"];
        }
    }
    // top sync messages (renderer order)
    {
        sqlite3_stmt *st = NULL;
        if (sqlite3_prepare_v2(db, "SELECT substr(text,1,20), sender_id, primary_sort_key, send_status, message_rendering_type FROM messages WHERE thread_key = ? ORDER BY primary_sort_key DESC LIMIT 3", -1, &st, NULL) == SQLITE_OK) {
            sqlite3_bind_text(st, 1, threadId.UTF8String, -1, SQLITE_TRANSIENT);
            int n = 0;
            while (sqlite3_step(st) == SQLITE_ROW && n < 3) {
                [r appendFormat:@"sniff msg#%d: '%@' sender=%@ psk=%lld ss=%d mrt=%d\n", n+1,
                    MI_cstr(sqlite3_column_text(st,0)) ?: @"", MI_cstr(sqlite3_column_text(st,1)) ?: @"?",
                    sqlite3_column_int64(st,2), sqlite3_column_int(st,3), sqlite3_column_int(st,4)];
                n++;
            }
            sqlite3_finalize(st);
        }
    }
    // Message-range tables: server-declared validity windows per thread
    {
        sqlite3_stmt *ts = NULL;
        NSMutableArray *rt = [NSMutableArray array];
        if (sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type='table' AND (name LIKE '%range%' OR name LIKE '%window%')", -1, &ts, NULL) == SQLITE_OK) {
            while (sqlite3_step(ts) == SQLITE_ROW) { NSString *n = MI_cstr(sqlite3_column_text(ts,0)); if (n.length > 0) [rt addObject:n]; }
            sqlite3_finalize(ts);
        }
        for (NSString *tbl in rt) {
            sqlite3_stmt *rs = NULL;
            NSString *rq = [NSString stringWithFormat:@"SELECT * FROM \"%@\" LIMIT 4", tbl];
            if (sqlite3_prepare_v2(db, rq.UTF8String, -1, &rs, NULL) == SQLITE_OK) {
                int cc = sqlite3_column_count(rs);
                int rn = 0;
                while (sqlite3_step(rs) == SQLITE_ROW && rn < 4) {
                    NSMutableString *row = [NSMutableString string];
                    for (int c = 0; c < cc && c < 10; c++) {
                        NSString *v;
                        if (sqlite3_column_type(rs, c) == SQLITE_NULL) v = @"N";
                        else if (sqlite3_column_type(rs, c) == SQLITE_TEXT) { v = MI_cstr(sqlite3_column_text(rs,c)) ?: @""; if (v.length > 16) v = [v substringToIndex:16]; }
                        else v = [NSString stringWithFormat:@"%lld", sqlite3_column_int64(rs,c)];
                        [row appendFormat:@"%s=%@ ", sqlite3_column_name(rs,c), v];
                    }
                    [r appendFormat:@"[range %@] %@
", tbl, row];
                    rn++;
                }
                sqlite3_finalize(rs);
            }
        }
    }
    // EVERY other table with a snippet column, matched to this thread
    {
        sqlite3_stmt *ts = NULL;
        NSMutableArray *tables = [NSMutableArray array];
        if (sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'", -1, &ts, NULL) == SQLITE_OK) {
            while (sqlite3_step(ts) == SQLITE_ROW) { NSString *n = MI_cstr(sqlite3_column_text(ts,0)); if (n.length > 0) [tables addObject:n]; }
            sqlite3_finalize(ts);
        }
        for (NSString *tbl in tables) {
            if ([tbl isEqualToString:@"messages"]) continue;
            sqlite3_stmt *pi = NULL;
            NSMutableArray *snipCols = [NSMutableArray array];
            NSString *keyCol = nil;
            NSString *q = [NSString stringWithFormat:@"PRAGMA table_info(\"%@\")", tbl];
            if (sqlite3_prepare_v2(db, q.UTF8String, -1, &pi, NULL) == SQLITE_OK) {
                while (sqlite3_step(pi) == SQLITE_ROW) {
                    NSString *c = MI_cstr(sqlite3_column_text(pi,1));
                    if (!c.length) continue;
                    NSString *lc = c.lowercaseString;
                    if ([lc containsString:@"snippet"]) [snipCols addObject:c];
                    if (!keyCol && ([lc isEqualToString:@"thread_key"] || [lc isEqualToString:@"thread_pk"])) keyCol = c;
                }
                sqlite3_finalize(pi);
            }
            if (snipCols.count == 0 || !keyCol || [tbl isEqualToString:@"threads"] || [tbl isEqualToString:@"client_threads"]) continue;
            sqlite3_stmt *rs = NULL;
            NSMutableString *sel = [NSMutableString string];
            for (NSString *c in snipCols) [sel appendFormat:@"substr(\"%@\",1,25), ", c];
            NSString *rq = [NSString stringWithFormat:@"SELECT %@ \"%@\" FROM \"%@\" WHERE \"%@\" = ? LIMIT 1", sel, keyCol, tbl, keyCol];
            if (sqlite3_prepare_v2(db, rq.UTF8String, -1, &rs, NULL) == SQLITE_OK) {
                sqlite3_bind_text(rs, 1, threadId.UTF8String, -1, SQLITE_TRANSIENT);
                if (sqlite3_step(rs) == SQLITE_ROW) {
                    NSMutableString *vals = [NSMutableString string];
                    for (int c = 0; c < (int)snipCols.count; c++) [vals appendFormat:@"%@='%@' ", snipCols[c], MI_cstr(sqlite3_column_text(rs,c)) ?: @"NULL"];
                    [r appendFormat:@"sniff [%@] %@\n", tbl, vals];
                }
                sqlite3_finalize(rs);
            }
        }
    }
}

// ============================================================
// Deep storage scan: search EVERY SQLite file in every Messenger
// container for a given text fragment -> finds which file/table
// actually stores the rendered inbox preview.
// ============================================================
static volatile int MI_ds_files = 0, MI_ds_matches = 0;

static void MI_deepScanFile(NSString *path, NSString *needle, NSMutableString *r) {
    if (MI_ds_matches >= 25) return;
    // must be SQLite
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!fh) return;
    NSData *hdr = [fh readDataOfLength:16];
    [fh closeFile];
    if (hdr.length < 16 || strncmp(hdr.bytes, "SQLite format 3", 15) != 0) return;

    sqlite3 *db = NULL;
    if (sqlite3_open_v2(path.UTF8String, &db, SQLITE_OPEN_READONLY, NULL) != SQLITE_OK) {
        if (db) sqlite3_close(db);
        return;
    }
    sqlite3_busy_timeout(db, 800);
    MI_ds_files++;

    NSMutableArray *tables = [NSMutableArray array];
    sqlite3_stmt *ts = NULL;
    if (sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'", -1, &ts, NULL) == SQLITE_OK) {
        while (sqlite3_step(ts) == SQLITE_ROW) { NSString *n = MI_cstr(sqlite3_column_text(ts,0)); if (n.length) [tables addObject:n]; }
        sqlite3_finalize(ts);
    }
    for (NSString *tbl in tables) {
        if (MI_ds_matches >= 25) break;
        sqlite3_stmt *pi = NULL;
        NSMutableArray *cols = [NSMutableArray array]; // [name]
        NSString *q = [NSString stringWithFormat:@"PRAGMA table_info(%@)", tbl];
        if (sqlite3_prepare_v2(db, q.UTF8String, -1, &pi, NULL) == SQLITE_OK) {
            while (sqlite3_step(pi) == SQLITE_ROW) {
                int ctype = sqlite3_column_int(pi, 2);
                NSString *cn = MI_cstr(sqlite3_column_text(pi,1));
                if (cn.length && (ctype == SQLITE_TEXT || ctype == 0)) [cols addObject:cn];
            }
            sqlite3_finalize(pi);
        }
        for (NSString *col in cols) {
            if (MI_ds_matches >= 25) break;
            sqlite3_stmt *rs = NULL;
            NSString *rq = [NSString stringWithFormat:@"SELECT rowid FROM \"%@\" WHERE \"%@\" LIKE ? LIMIT 2", tbl, col];
            if (sqlite3_prepare_v2(db, rq.UTF8String, -1, &rs, NULL) != SQLITE_OK) continue;
            NSString *pat = [NSString stringWithFormat:@"%%%@%%", needle];
            sqlite3_bind_text(rs, 1, pat.UTF8String, -1, SQLITE_TRANSIENT);
            if (sqlite3_step(rs) == SQLITE_ROW) {
                MI_ds_matches++;
                NSString *base = path.lastPathComponent ?: path;
                [r appendFormat:@"HIT %@.%@.%@ rowid=%lld\n", base, tbl, col, sqlite3_column_int64(rs,0)];
            }
            sqlite3_finalize(rs);
        }
    }
    sqlite3_close(db);
}

static void MI_hDeepScan(NSString *needle) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @try {
            NSMutableString *r = [NSMutableString string];
            [r appendFormat:@"=== DEEP SCAN '%@' ===\n", needle];

            // TIGHT SCOPE: only the app-group that contains the known Messenger DB.
            NSFileManager *fm = [NSFileManager defaultManager];
            NSString *knownDB = MI_findDatabase();
            NSString *root = nil;
            if (knownDB.length > 0) {
                NSRange asRange = [knownDB rangeOfString:@"Application Support"];
                if (asRange.location != NSNotFound) root = [knownDB substringToIndex:asRange.location]; // app-group root
            }
            if (root.length == 0) { [r appendString:@"no messenger appgroup found\n"]; }
            else {
                NSMutableArray *files = [NSMutableArray array];
                NSDirectoryEnumerator *en = [fm enumeratorAtURL:[NSURL fileURLWithPath:root]
                                     includingPropertiesForKeys:@[NSURLIsRegularFileKey, NSURLFileSizeKey]
                                                        options:NSDirectoryEnumerationSkipsPackageDescendants
                                                   errorHandler:nil];
                CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
                for (NSURL *u in en) {
                    if (CFAbsoluteTimeGetCurrent() - t0 > 10.0) { [r appendString:@"(time-capped)\n"]; break; }
                    NSNumber *isReg = nil;
                    [u getResourceValue:&isReg forKey:NSURLIsRegularFileKey error:nil];
                    if (![isReg boolValue]) continue;
                    NSDictionary *sz = [u resourceValuesForKeys:@[NSURLFileSizeKey] error:nil];
                    unsigned long long fsz = [sz[NSURLFileSizeKey] unsignedLongLongValue];
                    if (fsz == 0 || fsz > 80*1024*1024) continue;
                    NSString *name = u.lastPathComponent.lowercaseString;
                    BOOL looksDB = [name hasSuffix:@".db"] || [name hasSuffix:@".sqlite"] || [name hasSuffix:@".store"] || [name containsString:@"lightspeed"];
                    if (!looksDB) continue;
                    [files addObject:u.path];
                }
                [r appendFormat:@"scope %@ -> %d candidate files\n", root.lastPathComponent ?: root, (int)files.count];
                for (NSString *f in files) {
                    if (MI_ds_matches >= 15 || CFAbsoluteTimeGetCurrent() - t0 > 20.0) break;
                    @autoreleasepool {
                        MI_deepScanFile(f, needle, r);
                    }
                }
            }
            [r appendFormat:@"scanned=%d files hits=%d\n", MI_ds_files, MI_ds_matches];
            dispatch_async(dispatch_get_main_queue(), ^{ MI_postResult(@"progress", r); });
        } @catch (NSException *e) {
            MI_postResult(@"progress", [NSString stringWithFormat:@"deepscan exception: %@", e.reason]);
        }
    });
}

// ============================================================
// Insert-or-replace the sync-layer `threads` row for a chat.
// Research: inbox UI reflects DB tables; fresh chats lack this row,
// so the list has no local snippet source. Requires trigger stubs.
// ============================================================
// Core: insert-or-replace the sync threads row (used by inject + Sync header).
static void MI_threadRowInto(sqlite3 *db, NSString *threadId, NSMutableString *r) {
    @try {
            long long now = (long long)([[NSDate date] timeIntervalSince1970] * 1000.0);

            // resolve pk + name from client layer for fallback values
            long long pk = 0;
            NSString *name = @"";
            {
                NSMutableArray *pks = [NSMutableArray array];
                sqlite3_stmt *hs = NULL;
                NSString *hq = [NSString stringWithFormat:@"SELECT pk FROM client_threads WHERE default_other_participant_profile_picture_fallback_url_list LIKE '%%entity_id=%@%%' LIMIT 1", threadId];
                if (sqlite3_prepare_v2(db, hq.UTF8String, -1, &hs, NULL) == SQLITE_OK) {
                    if (sqlite3_step(hs) == SQLITE_ROW) [pks addObject:@(sqlite3_column_int64(hs,0))];
                    sqlite3_finalize(hs);
                }
                if (pks.count == 0) {
                    sqlite3_stmt *hs2 = NULL;
                    NSString *hq2 = [NSString stringWithFormat:@"SELECT thread_pk FROM client_messages WHERE sender_contact_pk = %@ GROUP BY thread_pk ORDER BY COUNT(*) DESC LIMIT 1", threadId];
                    if (sqlite3_prepare_v2(db, hq2.UTF8String, -1, &hs2, NULL) == SQLITE_OK) {
                        if (sqlite3_step(hs2) == SQLITE_ROW) [pks addObject:@(sqlite3_column_int64(hs2,0))];
                        sqlite3_finalize(hs2);
                    }
                }
                if (pks.count > 0) pk = [pks[0] longLongValue];
                sqlite3_stmt *ns = NULL;
                NSString *nq = [NSString stringWithFormat:@"SELECT default_thread_name FROM client_threads WHERE pk = %lld", pk];
                if (sqlite3_prepare_v2(db, nq.UTF8String, -1, &ns, NULL) == SQLITE_OK) {
                    if (sqlite3_step(ns) == SQLITE_ROW) name = MI_cstr(sqlite3_column_text(ns,0)) ?: @"";
                    sqlite3_finalize(ns);
                }
            }

            // top message text as snippet (from messages table)
            NSString *snip = @"";
            NSString *snipSender = @"";
            {
                sqlite3_stmt *ms = NULL;
                NSString *mq = [NSString stringWithFormat:@"SELECT substr(text,1,120), sender_id FROM messages WHERE thread_key = '%@' ORDER BY primary_sort_key DESC LIMIT 1", threadId];
                if (sqlite3_prepare_v2(db, mq.UTF8String, -1, &ms, NULL) == SQLITE_OK) {
                    if (sqlite3_step(ms) == SQLITE_ROW) {
                        snip = MI_cstr(sqlite3_column_text(ms,0)) ?: @"";
                        snipSender = MI_cstr(sqlite3_column_text(ms,1)) ?: @"";
                    }
                    sqlite3_finalize(ms);
                }
            }

            char *err = NULL;
            NSString *sql = [NSString stringWithFormat:
                @"INSERT OR REPLACE INTO threads "
                 "(thread_key, thread_type, folder_name, thread_picture_url_fallback, "
                 "last_activity_timestamp_ms, last_read_watermark_timestamp_ms, remove_watermark_timestamp_ms, "
                 "mute_expire_time_ms, snippet, is_admin_snippet, snippet_sender_contact_id, authority_level, "
                 "ongoing_call_state, parent_thread_key, snippet_has_emoji, has_persistent_menu, disable_composer_input, "
                 "cannot_unsend_reason, custom_emoji_image_url, viewed_plugin_key, viewed_plugin_context, "
                 "mailbox_type, unsend_limit_ms, mute_calls_expire_time_ms, mute_mention_expire_time_ms, "
                 "last_message_attachment_fbid, is_hidden, is_all_unread_message_missed_call_xma, "
                 "thread_invites_enabled, thread_invites_enabled_v2, num_unread_subthreads, read_receipts_disabled_v2, "
                 "sync_group, deletion_watermark_timestamp_ms, unread_message_count, is_suspended, "
                 "contains_out_of_band_messages, typing_indicator_disabled, is_get_started_button_eligible, "
                 "is_custom_thread_picture, is_disappearing_mode, unread_disappearing_message_count, "
                 "should_round_thread_picture, is_tombstoned, is_placeholder, group_member_add_mode, "
                 "capabilities, capabilities_2, capabilities_3, capabilities_4, capabilities_5, capabilities_6) "
                 "VALUES "
                 "('%@', 1, 'inbox', '/messaging/lightspeed/media_fallback/?entity_id=%@&entity_type=10&width=300&height=300', "
                 "%lld, %lld, 0, 0, '%@', 0, '%@', 80, 0, -17, 0, 0, 0, 0, '', NULL, NULL, "
                 "0, -1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, NULL, 0, 0, 0, "
                 "990792246600587262, 438433287420077057, 108156794884325379, 4303355924, 603632718068193285, 0)",
                 threadId, threadId, now, now, MI_esc(snip), snipSender];
            if (sqlite3_exec(db, sql.UTF8String, NULL, NULL, &err) == SQLITE_OK) {
                [r appendFormat:@"threads row written (matched %d), snippet='%@'\n", sqlite3_changes(db), snip];
            } else {
                [r appendFormat:@"threads INSERT error: %s\n", err ? err : "?"];
                if (err) sqlite3_free(err);
            }

    } @catch (NSException *e) {
        [r appendFormat:@"syncrow exception: %@\n", e.reason];
    }
}

static void MI_hThreadRow(NSString *threadId) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @try {
            NSMutableString *r = [NSMutableString string];
            [r appendFormat:@"=== SYNC ROW (%@) ===\n", threadId];
            NSString *dbPath = MI_findDatabase();
            if (!dbPath.length) { MI_postResult(@"progress", @"no DB"); return; }
            sqlite3 *db = NULL;
            if (sqlite3_open_v2(dbPath.UTF8String, &db, SQLITE_OPEN_READWRITE, NULL) != SQLITE_OK) {
                MI_postResult(@"progress", @"DB open failed");
                if (db) sqlite3_close(db);
                return;
            }
            sqlite3_busy_timeout(db, 5000);
            // register dummy trigger functions (same as inject path)
            sqlite3_create_function(db, "thread_read_status_triggers_enabled", 0, SQLITE_UTF8, NULL, MI_dummy_zero, NULL, NULL);
            sqlite3_create_function(db, "thread_read_status_triggers_enabled_v2", 0, SQLITE_UTF8, NULL, MI_dummy_zero, NULL, NULL);
            sqlite3_create_function(db, "actor_id_for_sync_group", -1, SQLITE_UTF8, NULL, MI_dummy_zero, NULL, NULL);

            long long now = (long long)([[NSDate date] timeIntervalSince1970] * 1000.0);

            // resolve pk + name from client layer for fallback values
            long long pk = 0;
            NSString *name = @"";
            {
                NSMutableArray *pks = [NSMutableArray array];
                sqlite3_stmt *hs = NULL;
                NSString *hq = [NSString stringWithFormat:@"SELECT pk FROM client_threads WHERE default_other_participant_profile_picture_fallback_url_list LIKE '%%entity_id=%@%%' LIMIT 1", threadId];
                if (sqlite3_prepare_v2(db, hq.UTF8String, -1, &hs, NULL) == SQLITE_OK) {
                    if (sqlite3_step(hs) == SQLITE_ROW) [pks addObject:@(sqlite3_column_int64(hs,0))];
                    sqlite3_finalize(hs);
                }
                if (pks.count == 0) {
                    sqlite3_stmt *hs2 = NULL;
                    NSString *hq2 = [NSString stringWithFormat:@"SELECT thread_pk FROM client_messages WHERE sender_contact_pk = %@ GROUP BY thread_pk ORDER BY COUNT(*) DESC LIMIT 1", threadId];
                    if (sqlite3_prepare_v2(db, hq2.UTF8String, -1, &hs2, NULL) == SQLITE_OK) {
                        if (sqlite3_step(hs2) == SQLITE_ROW) [pks addObject:@(sqlite3_column_int64(hs2,0))];
                        sqlite3_finalize(hs2);
                    }
                }
                if (pks.count > 0) pk = [pks[0] longLongValue];
                sqlite3_stmt *ns = NULL;
                NSString *nq = [NSString stringWithFormat:@"SELECT default_thread_name FROM client_threads WHERE pk = %lld", pk];
                if (sqlite3_prepare_v2(db, nq.UTF8String, -1, &ns, NULL) == SQLITE_OK) {
                    if (sqlite3_step(ns) == SQLITE_ROW) name = MI_cstr(sqlite3_column_text(ns,0)) ?: @"";
                    sqlite3_finalize(ns);
                }
            }

            // top message text as snippet (from messages table)
            NSString *snip = @"";
            NSString *snipSender = @"";
            {
                sqlite3_stmt *ms = NULL;
                NSString *mq = [NSString stringWithFormat:@"SELECT substr(text,1,120), sender_id FROM messages WHERE thread_key = '%@' ORDER BY primary_sort_key DESC LIMIT 1", threadId];
                if (sqlite3_prepare_v2(db, mq.UTF8String, -1, &ms, NULL) == SQLITE_OK) {
                    if (sqlite3_step(ms) == SQLITE_ROW) {
                        snip = MI_cstr(sqlite3_column_text(ms,0)) ?: @"";
                        snipSender = MI_cstr(sqlite3_column_text(ms,1)) ?: @"";
                    }
                    sqlite3_finalize(ms);
                }
            }

            char *err = NULL;
            NSString *sql = [NSString stringWithFormat:
                @"INSERT OR REPLACE INTO threads "
                 "(thread_key, thread_type, folder_name, thread_picture_url_fallback, "
                 "last_activity_timestamp_ms, last_read_watermark_timestamp_ms, remove_watermark_timestamp_ms, "
                 "mute_expire_time_ms, snippet, is_admin_snippet, snippet_sender_contact_id, authority_level, "
                 "ongoing_call_state, parent_thread_key, snippet_has_emoji, has_persistent_menu, disable_composer_input, "
                 "cannot_unsend_reason, custom_emoji_image_url, viewed_plugin_key, viewed_plugin_context, "
                 "mailbox_type, unsend_limit_ms, mute_calls_expire_time_ms, mute_mention_expire_time_ms, "
                 "last_message_attachment_fbid, is_hidden, is_all_unread_message_missed_call_xma, "
                 "thread_invites_enabled, thread_invites_enabled_v2, num_unread_subthreads, read_receipts_disabled_v2, "
                 "sync_group, deletion_watermark_timestamp_ms, unread_message_count, is_suspended, "
                 "contains_out_of_band_messages, typing_indicator_disabled, is_get_started_button_eligible, "
                 "is_custom_thread_picture, is_disappearing_mode, unread_disappearing_message_count, "
                 "should_round_thread_picture, is_tombstoned, is_placeholder, group_member_add_mode, "
                 "capabilities, capabilities_2, capabilities_3, capabilities_4, capabilities_5, capabilities_6) "
                 "VALUES "
                 "('%@', 1, 'inbox', '/messaging/lightspeed/media_fallback/?entity_id=%@&entity_type=10&width=300&height=300', "
                 "%lld, %lld, 0, 0, '%@', 0, '%@', 80, 0, -17, 0, 0, 0, 0, '', NULL, NULL, "
                 "0, -1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, NULL, 0, 0, 0, "
                 "990792246600587262, 438433287420077057, 108156794884325379, 4303355924, 603632718068193285, 0)",
                 threadId, threadId, now, now, MI_esc(snip), snipSender];
            if (sqlite3_exec(db, sql.UTF8String, NULL, NULL, &err) == SQLITE_OK) {
                [r appendFormat:@"threads row written (matched %d), snippet='%@'\n", sqlite3_changes(db), snip];
            } else {
                [r appendFormat:@"threads INSERT error: %s\n", err ? err : "?"];
                if (err) sqlite3_free(err);
            }

            sqlite3_close(db);
            dispatch_async(dispatch_get_main_queue(), ^{ MI_postResult(@"progress", r); });
        } @catch (NSException *e) {
            MI_postResult(@"progress", [NSString stringWithFormat:@"syncrow exception: %@", e.reason]);
        }
    });
}

// Dump ALL non-null columns of one REAL vs one INJECTED message (em kè GT
// thread has both). Any systematic difference = the field the UI filters on.
static void MI_compareRealVsInjected(sqlite3 *db, NSMutableString *r) {
    const char *gtPk = "410725001";
    // newest real message (from other party) vs newest injected (local, recent ts)
    const char *queries[2] = {
        "SELECT * FROM client_messages WHERE thread_pk = 410725001 AND sender_contact_pk = 1002754957 AND text IS NOT NULL ORDER BY authoritative_ts_ms DESC LIMIT 1",
        "SELECT * FROM client_messages WHERE thread_pk = 410725001 AND sender_contact_pk = 100003506470529 AND authoritative_ts_ms > 1700000000000 ORDER BY authoritative_ts_ms DESC LIMIT 1"
    };
    const char *labels[2] = { "REAL", "OURS" };
    for (int qi = 0; qi < 2; qi++) {
        sqlite3_stmt *st = NULL;
        if (sqlite3_prepare_v2(db, queries[qi], -1, &st, NULL) != SQLITE_OK) continue;
        if (sqlite3_step(st) == SQLITE_ROW) {
            int cc = sqlite3_column_count(st);
            [r appendFormat:@"--- %s client_messages ---\n", labels[qi]];
            for (int c = 0; c < cc; c++) {
                if (sqlite3_column_type(st, c) == SQLITE_NULL) continue;
                const char *cn = sqlite3_column_name(st, c);
                NSString *val;
                int ct = sqlite3_column_type(st, c);
                if (ct == SQLITE_TEXT || ct == SQLITE_BLOB) {
                    val = MI_cstr(sqlite3_column_text(st, c)) ?: @"";
                    if (val.length > 28) val = [val substringToIndex:28];
                } else {
                    val = [NSString stringWithFormat:@"%lld", sqlite3_column_int64(st, c)];
                }
                [r appendFormat:@"%s=%@\n", cn, val];
            }
        }
        sqlite3_finalize(st);
    }
}

static void MI_hInject(NSString *threadIdIn, NSArray *messages) {
    __block NSString *threadId = threadIdIn;
    MI_progress([NSString stringWithFormat:@"inject: start threadId=%@ msgCount=%d", threadId, (int)messages.count]);
            dispatch_async(dispatch_get_main_queue(), ^{ MI_postResult(@"progress", @"[1] inject request received"); });
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
            // Register dummy functions that Messenger registers on its connection
            // (triggers reference them; without registration, INSERT fails)
            sqlite3_create_function(db, "thread_read_status_triggers_enabled", 0, SQLITE_UTF8, NULL, MI_dummy_zero, NULL, NULL);
            sqlite3_create_function(db, "thread_read_status_triggers_enabled_v2", 0, SQLITE_UTF8, NULL, MI_dummy_zero, NULL, NULL);
            sqlite3_create_function(db, "actor_id_for_sync_group", -1, SQLITE_UTF8, NULL, MI_dummy_zero, NULL, NULL);
            // Dynamically stub EVERY app-defined function referenced by DB triggers,
            // otherwise our writes fail with "no such function" when triggers fire.
            {
                sqlite3_stmt *ts = NULL;
                NSMutableSet *seen = [NSMutableSet setWithObjects:@"thread_read_status_triggers_enabled", @"thread_read_status_triggers_enabled_v2", @"actor_id_for_sync_group", nil];
                if (sqlite3_prepare_v2(db, "SELECT sql FROM sqlite_master WHERE sql IS NOT NULL AND type IN ('trigger','table','view')", -1, &ts, NULL) == SQLITE_OK) {
                    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"[a-zA-Z_][a-zA-Z0-9_]*[ ]*\\(" options:0 error:NULL];
                    while (sqlite3_step(ts) == SQLITE_ROW) {
                        NSString *sql = MI_cstr(sqlite3_column_text(ts, 0)) ?: @"";
                        [re enumerateMatchesInString:sql options:0 range:NSMakeRange(0, sql.length) usingBlock:^(NSTextCheckingResult *m, NSMatchingFlags flags, BOOL *stop) {
                            NSRange r = [m rangeAtIndex:0];
                            NSString *tok = [sql substringWithRange:NSMakeRange(r.location, r.length - 1)];
                            NSString *low = tok.lowercaseString;
                            static NSSet *kw;
                            static dispatch_once_t ot;
                            dispatch_once(&ot, ^{ kw = [NSSet setWithArray:@[@"if",@"not",@"exists",@"select",@"insert",@"or",@"ignore",@"into",@"values",@"update",@"set",@"where",@"delete",@"from",@"and",@"case",@"when",@"then",@"else",@"end",@"null",@"coalesce",@"cast",@"length",@"upper",@"lower",@"abs",@"max",@"min",@"sum",@"count",@"avg",@"total",@"round",@"typeof",@"instr",@"replace",@"substr",@"substring",@"trim",@"ltrim",@"rtrim",@"hex",@"quote",@"char",@"unicode",@"like",@"glob",@"printf",@"format",@"date",@"time",@"datetime",@"julianday",@"strftime",@"random",@"randomblob",@"last_insert_rowid",@"changes",@"total_changes",@"sqlite_source_id",@"sqlite_version",@"likely",@"unlikely",@"iif",@"sign"]]; });
                            if ([kw containsObject:low]) return;
                            if ([seen containsObject:tok]) return;
                            [seen addObject:tok];
                            sqlite3_create_function(db, tok.UTF8String, -1, SQLITE_UTF8, NULL, MI_dummy_zero, NULL, NULL);
                        }];
                    }
                    sqlite3_finalize(ts);
                }
            }
            MI_progress(@"inject: DB opened RW, dummy functions registered");

            NSMutableString *report = [NSMutableString string];

            // Step 0: NAME input support — if threadId is not all digits,
            // treat it as a chat name and resolve via contacts (normalized).
            // Research finding: user's target ID 1455922134493907 was actually
            // 'Điện Tử Thái Thắng', NOT the intended 'Trịnh Đức Linh' — typing
            // the NAME is far safer than a possibly-stale numeric ID.
            static NSRegularExpression *digitsOnly;
            static dispatch_once_t onceTok;
            dispatch_once(&onceTok, ^{ digitsOnly = [NSRegularExpression regularExpressionWithPattern:@"^[0-9]+$" options:0 error:NULL]; });
            if ([digitsOnly firstMatchInString:threadId options:0 range:NSMakeRange(0, threadId.length)] == nil) {
                NSString *want = MI_normalizeName(threadId);
                NSMutableArray *ids = [NSMutableArray array];
                NSMutableArray *found = [NSMutableArray array];
                sqlite3_stmt *sn = NULL;
                if (sqlite3_prepare_v2(db, "SELECT id, name FROM contacts", -1, &sn, NULL) == SQLITE_OK) {
                    while (sqlite3_step(sn) == SQLITE_ROW) {
                        NSString *id = MI_cstr(sqlite3_column_text(sn, 0));
                        NSString *nm = MI_cstr(sqlite3_column_text(sn, 1));
                        if (id.length > 0 && nm.length > 0 && [MI_normalizeName(nm) isEqualToString:want]) {
                            if (![ids containsObject:id]) [ids addObject:id];
                            [found addObject:[NSString stringWithFormat:@"%@ = %@", nm, id]];
                        }
                    }
                    sqlite3_finalize(sn);
                }
                sqlite3_stmt *sc = NULL;
                if (sqlite3_prepare_v2(db, "SELECT contact_id, displayed_name FROM client_contacts", -1, &sc, NULL) == SQLITE_OK) {
                    while (sqlite3_step(sc) == SQLITE_ROW) {
                        NSString *id = MI_cstr(sqlite3_column_text(sc, 0));
                        NSString *nm = MI_cstr(sqlite3_column_text(sc, 1));
                        if (id.length > 0 && nm.length > 0 && [MI_normalizeName(nm) isEqualToString:want]) {
                            if (![ids containsObject:id]) [ids addObject:id];
                            [found addObject:[NSString stringWithFormat:@"%@ = %@", nm, id]];
                        }
                    }
                    sqlite3_finalize(sc);
                }
                if (ids.count == 1) {
                    [report appendFormat:@"name resolved: %@\n", found.firstObject];
                    threadId = ids.firstObject;
                } else {
                    [report appendFormat:@"NAME LOOKUP FAILED for '%@': %@\n", threadId, ids.count == 0 ? @"no contact with this name" : [NSString stringWithFormat:@"multiple matches: %@", [found componentsJoinedByString:@", "]]];
                    [report appendString:@"ABORT: use the exact chat name, or a numeric thread ID.\n"];
                    [report appendFormat:@"@@MIRESULT|ok=0|inserted=0|errors=1|thread_pk=0|method=name_lookup|name=%@|thread_id=%@|reason=name_not_found|@@\n", threadId, threadId];
                    sqlite3_close(db);
                    MI_postResult(@"inject", report);
                    return;
                }
            }

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
                NSString *q = [NSString stringWithFormat:@"SELECT DISTINCT sender_id FROM messages WHERE thread_key = '%@' LIMIT 10", MI_esc(threadId)];
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
                // Parse from DB filename: <userid>.db or lightspeed-<userid>.db
                NSString *fname = [dbPath lastPathComponent];
                NSString *withoutExt = [fname stringByDeletingPathExtension];
                // Check if all digits
                BOOL allDigits = withoutExt.length > 0;
                for (NSUInteger i = 0; i < withoutExt.length; i++) {
                    if (!isdigit([withoutExt characterAtIndex:i])) { allDigits = NO; break; }
                }
                if (allDigits) {
                    localUid = withoutExt;
                    gLocalUserID = withoutExt;
                } else {
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
                } // end else
            } // end if (!localUid.length)
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

            // Step 6: Resolve thread_pk — RESEARCH BUILD
            // Strategy: test the offline_threading_id bridge on clean data and
            // VALIDATE it against a known-correct data point before trusting it.
            MI_progress(@"inject: resolving thread_pk (research mode)");

            // 6.0 Safety cleanup: remove any of OUR previously-injected rows.
            // Our generated message_ids contain UUID dashes; real server IDs never do.
            {
                char *clErr = NULL;
                sqlite3_exec(db, "DELETE FROM messages WHERE message_id LIKE '%-%-%-%-%'", NULL, NULL, &clErr);
                int msgDel = sqlite3_changes(db);
                if (clErr) { [report appendFormat:@"cleanup error: %s\n", clErr]; sqlite3_free(clErr); }
                if (msgDel > 0) [report appendFormat:@"cleanup: removed %d old test rows from messages\n", msgDel];
            }

            long long threadPk = 0;
            NSString *pkMethod = @"none";
            {
                // --- Method 1: FB ID anywhere in a client_threads row (entity_id URLs etc.)
                {
                    NSMutableArray *cols = [NSMutableArray array];
                    sqlite3_stmt *ps = NULL;
                    if (sqlite3_prepare_v2(db, "PRAGMA table_info(client_threads)", -1, &ps, NULL) == SQLITE_OK) {
                        while (sqlite3_step(ps) == SQLITE_ROW) {
                            NSString *c = MI_cstr(sqlite3_column_text(ps, 1));
                            if (c.length > 0) [cols addObject:c];
                        }
                        sqlite3_finalize(ps);
                    }
                    if (cols.count > 0) {
                        NSMutableArray *conds = [NSMutableArray array];
                        for (NSString *c in cols) {
                            [conds addObject:[NSString stringWithFormat:@"\"%@\" LIKE '%%%@%%'", c, threadId]];
                        }
                        NSString *q2 = [NSString stringWithFormat:@"SELECT pk, default_thread_name FROM client_threads WHERE %@ LIMIT 1",
                                       [conds componentsJoinedByString:@" OR "]];
                        sqlite3_stmt *s2 = NULL;
                        if (sqlite3_prepare_v2(db, q2.UTF8String, -1, &s2, NULL) == SQLITE_OK) {
                            if (sqlite3_step(s2) == SQLITE_ROW) {
                                threadPk = sqlite3_column_int64(s2, 0);
                                pkMethod = @"row_scan";
                                [report appendFormat:@"[research] row_scan hit: pk=%lld name=%@\n", threadPk, MI_cstr(sqlite3_column_text(s2,1))];
                            }
                            sqlite3_finalize(s2);
                        }
                    }
                }

                // --- Method 2: sender_contact_pk — threads where target actually sent messages
                if (threadPk == 0) {
                    sqlite3_stmt *s2b = NULL;
                    NSString *q2b = [NSString stringWithFormat:
                        @"SELECT thread_pk, COUNT(*) c FROM client_messages WHERE sender_contact_pk = %lld GROUP BY thread_pk ORDER BY c DESC LIMIT 5",
                        threadId.longLongValue];
                    if (sqlite3_prepare_v2(db, q2b.UTF8String, -1, &s2b, NULL) == SQLITE_OK) {
                        NSMutableArray *cands = [NSMutableArray array];
                        while (sqlite3_step(s2b) == SQLITE_ROW) {
                            long long pk = sqlite3_column_int64(s2b,0);
                            long long n = sqlite3_column_int64(s2b,1);
                            // n>=3: our own leftover test injections show up as tiny counts
                            if (n < 3) { [cands addObject:[NSString stringWithFormat:@"pk=%lld(n=%lld IGNORED-contamination)", pk, n]]; continue; }
                            [cands addObject:[NSString stringWithFormat:@"pk=%lld(n=%lld)", pk, n]];
                            if (threadPk == 0) { threadPk = pk; pkMethod = @"sender_contact_pk"; }
                        }
                        sqlite3_finalize(s2b);
                        [report appendFormat:@"[research] sender_contact_pk: %@\n", cands.count ? [cands componentsJoinedByString:@", "] : @"none"];
                    }
                }

                // --- Method 3: robust name match (exact -> case/diacritic-insensitive)
                // User-confirmed ground truth: 1455922134493907 = "Trinh Duc Linh" -> pk 410725020
                if (threadPk == 0) {
                    NSMutableArray *names = [NSMutableArray array];
                    {
                        sqlite3_stmt *sn = NULL;
                        NSString *qn = [NSString stringWithFormat:@"SELECT name FROM contacts WHERE id = '%@' LIMIT 1", MI_esc(threadId)];
                        if (sqlite3_prepare_v2(db, qn.UTF8String, -1, &sn, NULL) == SQLITE_OK) {
                            if (sqlite3_step(sn) == SQLITE_ROW) { NSString *nm = MI_cstr(sqlite3_column_text(sn,0)); if (nm.length > 0) [names addObject:nm]; }
                            sqlite3_finalize(sn);
                        }
                        sqlite3_stmt *sn2 = NULL;
                        NSString *qn2 = [NSString stringWithFormat:@"SELECT displayed_name FROM client_contacts WHERE contact_id = '%@' LIMIT 1", MI_esc(threadId)];
                        if (sqlite3_prepare_v2(db, qn2.UTF8String, -1, &sn2, NULL) == SQLITE_OK) {
                            if (sqlite3_step(sn2) == SQLITE_ROW) { NSString *nm = MI_cstr(sqlite3_column_text(sn2,0)); if (nm.length > 0) [names addObject:nm]; }
                            sqlite3_finalize(sn2);
                        }
                    }
                    [report appendFormat:@"[research] names for target: %@\n", names.count ? [names componentsJoinedByString:@", "] : @"NONE"];
                    for (NSString *nm in names) {
                        if (threadPk != 0) break;
                        sqlite3_stmt *se = NULL;
                        NSString *qe = [NSString stringWithFormat:@"SELECT pk FROM client_threads WHERE default_thread_name = '%@' OR default_thread_name_without_nickname = '%@' LIMIT 1", MI_esc(nm), MI_esc(nm)];
                        if (sqlite3_prepare_v2(db, qe.UTF8String, -1, &se, NULL) == SQLITE_OK) {
                            if (sqlite3_step(se) == SQLITE_ROW) { threadPk = sqlite3_column_int64(se,0); pkMethod = @"name_exact"; }
                            sqlite3_finalize(se);
                        }
                        if (threadPk == 0) {
                            NSString *want = MI_normalizeName(nm);
                            if (want.length >= 3) {
                                sqlite3_stmt *sa = NULL;
                                if (sqlite3_prepare_v2(db, "SELECT pk, default_thread_name, default_thread_name_without_nickname FROM client_threads LIMIT 500", -1, &sa, NULL) == SQLITE_OK) {
                                    NSMutableArray *near = [NSMutableArray array];
                                    while (sqlite3_step(sa) == SQLITE_ROW) {
                                        NSString *n1 = MI_cstr(sqlite3_column_text(sa,1));
                                        NSString *n2 = MI_cstr(sqlite3_column_text(sa,2));
                                        NSString *hit = nil;
                                        if (n1.length > 0 && [MI_normalizeName(n1) isEqualToString:want]) hit = n1;
                                        else if (n2.length > 0 && [MI_normalizeName(n2) isEqualToString:want]) hit = n2;
                                        if (hit.length > 0) { threadPk = sqlite3_column_int64(sa,0); pkMethod = @"name_normalized"; [near addObject:hit]; }
                                    }
                                    sqlite3_finalize(sa);
                                    if (near.count > 0) [report appendFormat:@"[research] normalized name hits: %@\n", [near componentsJoinedByString:@", "]];
                                }
                            }
                        }
                    }
                }

                // --- Last resort (WRONG chat risk — flagged)
                if (threadPk == 0) {
                    sqlite3_stmt *s4 = NULL;
                    if (sqlite3_prepare_v2(db, "SELECT DISTINCT thread_pk FROM client_messages LIMIT 1", -1, &s4, NULL) == SQLITE_OK) {
                        if (sqlite3_step(s4) == SQLITE_ROW) {
                            threadPk = sqlite3_column_int64(s4, 0);
                            pkMethod = @"LAST_RESORT_first_thread";
                        }
                        sqlite3_finalize(s4);
                    }
                }
            }
            MI_progress([NSString stringWithFormat:@"inject: threadPk=%lld (%@)", threadPk, pkMethod]);
            [report appendFormat:@"thread_pk: %lld (method: %@)%@\n", threadPk, pkMethod,
                [pkMethod isEqualToString:@"LAST_RESORT_first_thread"] ? @"  ⚠️ WRONG CHAT RISK" : @""];

            // Log resolved thread name for verification
            NSString *resolvedName = @"";
            {
                sqlite3_stmt *s = NULL;
                if (sqlite3_prepare_v2(db, "SELECT default_thread_name FROM client_threads WHERE pk = ?", -1, &s, NULL) == SQLITE_OK) {
                    sqlite3_bind_int64(s, 1, threadPk);
                    if (sqlite3_step(s) == SQLITE_ROW) {
                        resolvedName = MI_cstr(sqlite3_column_text(s, 0)) ?: @"";
                        [report appendFormat:@"resolved thread name: %@\n", resolvedName];
                    }
                    sqlite3_finalize(s);
                }
            }

            // sender_contact_pk = FB user ID directly
            long long localContactPk = localUid.longLongValue;
            long long otherContactPk = otherUid.longLongValue;
            [report appendFormat:@"sender_contact_pk: local=%lld, other=%lld\n", localContactPk, otherContactPk];

            // Find max pk in client_messages for sort_order
            long long maxClientPk = 0;
            {
                sqlite3_stmt *s = NULL;
                if (sqlite3_prepare_v2(db, "SELECT MAX(pk) FROM client_messages", -1, &s, NULL) == SQLITE_OK) {
                    if (sqlite3_step(s) == SQLITE_ROW) maxClientPk = sqlite3_column_int64(s, 0);
                    sqlite3_finalize(s);
                }
            }
            MI_progress([NSString stringWithFormat:@"inject: maxClientPk=%lld", maxClientPk]);

            // VERIFICATION GATE: the resolved thread's profile-picture URL columns contain
            // entity_id=<other person's FB ID>. If a DIFFERENT id is present, the resolved
            // thread is provably a chat with someone else → REFUSE to inject.
            {
                NSArray *urlCols = @[@"default_other_participant_profile_picture_url_list",
                                     @"default_other_participant_profile_picture_fallback_url_list",
                                     @"read_profile_picture_url_list_csv",
                                     @"read_profile_picture_fallback_url_list_csv"];
                NSMutableString *allUrls = [NSMutableString string];
                for (NSString *c in urlCols) {
                    sqlite3_stmt *vs = NULL;
                    NSString *vq = [NSString stringWithFormat:@"SELECT \"%@\" FROM client_threads WHERE pk = %lld", c, threadPk];
                    if (sqlite3_prepare_v2(db, vq.UTF8String, -1, &vs, NULL) == SQLITE_OK) {
                        if (sqlite3_step(vs) == SQLITE_ROW) {
                            NSString *v = MI_cstr(sqlite3_column_text(vs, 0));
                            if (v.length > 0) [allUrls appendString:v];
                        }
                        sqlite3_finalize(vs);
                    }
                }
                NSMutableSet *eids = [NSMutableSet set];
                NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"entity_id=(\\d+)" options:0 error:NULL];
                [re enumerateMatchesInString:allUrls options:0 range:NSMakeRange(0, allUrls.length) usingBlock:^(NSTextCheckingResult *m, NSMatchingFlags flags, BOOL *stop) {
                    [eids addObject:[allUrls substringWithRange:[m rangeAtIndex:1]]];
                }];
                // Also: does the target user have real (non-ours) messages in this thread?
                long long fromTarget = 0;
                sqlite3_stmt *vs2 = NULL;
                NSString *vq2 = [NSString stringWithFormat:
                    @"SELECT COUNT(*) FROM client_messages WHERE thread_pk = %lld AND sender_contact_pk = %lld", threadPk, threadId.longLongValue];
                if (sqlite3_prepare_v2(db, vq2.UTF8String, -1, &vs2, NULL) == SQLITE_OK) {
                    if (sqlite3_step(vs2) == SQLITE_ROW) fromTarget = sqlite3_column_int64(vs2, 0);
                    sqlite3_finalize(vs2);
                }
                if (eids.count > 0) {
                    if ([eids containsObject:threadId]) {
                        [report appendFormat:@"verify: VERIFIED ✅ (entity_id=%@ in thread) | target's msgs in thread: %lld\n", threadId, fromTarget];
                    } else {
                        [report appendFormat:@"verify: MISMATCH ❌ thread entity_id=%@ ≠ target %@ | target's msgs: %lld\n",
                            [eids allObjects].description, threadId, fromTarget];
                        [report appendString:@"ABORT: refusing to inject — resolved thread provably belongs to another person.\n"];
                        [report appendFormat:@"@@MIRESULT|ok=0|inserted=0|errors=1|thread_pk=%lld|method=%@|name=%@|thread_id=%@|reason=entity_id_mismatch|@@\n",
                            threadPk, pkMethod, resolvedName, threadId];
                        sqlite3_close(db);
                        MI_postResult(@"inject", report);
                        return;
                    }
                } else {
                    [report appendFormat:@"verify: unverified (no entity_id in thread) | target's msgs in thread: %lld\n", fromTarget];
                }
            }

            // Step 7: INSERT messages
            dispatch_async(dispatch_get_main_queue(), ^{ MI_postResult(@"progress", @"[5] reached insert step"); });
            MI_progress(@"inject: starting transaction");
            sqlite3_exec(db, "BEGIN TRANSACTION", NULL, NULL, NULL);

            // Find max offline_threading_id for generating new ones
            MI_progress(@"inject: finding max offline_threading_id");
            long long maxOtid = 0;
            {
                sqlite3_stmt *s = NULL;
                if (sqlite3_prepare_v2(db, "SELECT MAX(CAST(offline_threading_id AS INTEGER)) FROM messages", -1, &s, NULL) == SQLITE_OK) {
                    if (sqlite3_step(s) == SQLITE_ROW) {
                        maxOtid = sqlite3_column_int64(s, 0);
                    }
                    sqlite3_finalize(s);
                }
            }
            MI_progress([NSString stringWithFormat:@"inject: maxOtid=%lld", maxOtid]);

            int inserted = 0;
            int errors = 0;
            long long nextOtid = maxOtid + 1;
            long long nowMs = (long long)([NSDate date].timeIntervalSince1970 * 1000);

            for (int i = 0; i < (int)messages.count; i++) {
                NSDictionary *msg = messages[i];
                NSString *side = msg[@"s"];
                NSString *text = msg[@"t"];
                NSNumber *minAgo = msg[@"m"];
                long long minutesAgo = minAgo ? minAgo.longLongValue : (messages.count - i);
                long long ts = nowMs - (minutesAgo * 60 * 1000);
                NSString *senderId = [side isEqualToString:@"me"] ? localUid : otherUid;

                // Generate message_id in Messenger format: mid.$<random_base64_like>
                NSString *msgIdStr = [NSString stringWithFormat:@"mid.$cAAV21KjfFFKd8%@%lld",
                                       [[NSUUID UUID] UUIDString], ts];
                // Generate offline_threading_id (large integer)
                long long otid = nextOtid;

                // INSERT OR IGNORE with real schema columns
                // Required: thread_key, timestamp_ms, message_id, offline_threading_id, text, sender_id,
                //           is_admin_message, authority_level, send_status, send_status_v2, is_unsent,
                //           primary_sort_key, message_rendering_type
                NSString *sql = [NSString stringWithFormat:
                    @"INSERT OR IGNORE INTO messages ("
                    @"thread_key, timestamp_ms, message_id, offline_threading_id, text, sender_id, "
                    @"is_admin_message, authority_level, send_status, send_status_v2, is_unsent, "
                    @"primary_sort_key, message_rendering_type, has_quick_replies, is_forwarded, "
                    @"text_has_links, view_flags) "
                    @"VALUES ('%@', %lld, '%@', %lld, '%@', '%@', "
                    @"0, 80, 2, 2, 0, %lld, 2, 0, 0, 0, 0)",
                    MI_esc(threadKey), ts, MI_esc(msgIdStr), otid, MI_esc(text), MI_esc(senderId),
                    ts];

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

                // Also INSERT into client_messages (what the UI actually reads from)
                if (threadPk > 0 && (localContactPk > 0 || otherContactPk > 0)) {
                    long long contactPk = [side isEqualToString:@"me"] ? localContactPk : otherContactPk;
                    NSString *persistentId = [[NSUUID UUID] UUIDString].uppercaseString;
                    long long clientSortOrder = maxClientPk + i + 1;
                    NSString *clientSql = [NSString stringWithFormat:
                        @"INSERT OR IGNORE INTO client_messages ("
                        @"thread_pk, authoritative_ts_ms, sort_order, display_ts_ms, text, text_size, "
                        @"sender_contact_pk, send_status, is_hidden, is_tombstoned, is_reply_only, "
                        @"persistent_id, message_content_type, message_creation_type, primary_sort_key, "
                        @"should_bump_thread, resonance_offline_threading_id) "
                        @"VALUES (%lld, %lld, -1, %lld, '%@', 0, "
                        @"%lld, 2, 0, 0, 0, "
                        @"'%@', 0, 5, %lld, 1, %lld)",
                        threadPk, ts, ts, MI_esc(text), contactPk, MI_esc(persistentId), ts, otid];
                    char *err2 = NULL;
                    int rc2 = sqlite3_exec(db, clientSql.UTF8String, NULL, NULL, &err2);
                    if (rc2 == SQLITE_OK) {
                        [report appendFormat:@"       client_messages: inserted (pk~%lld)\n", clientSortOrder];
                    } else {
                        [report appendFormat:@"       client_messages ERROR: %s\n", err2 ? err2 : "?"];
                        if (err2) sqlite3_free(err2);
                    }
                }
                nextOtid++;
            }

            sqlite3_exec(db, "COMMIT", NULL, NULL, NULL);
            MI_progress([NSString stringWithFormat:@"inject: %d inserted, %d errors", inserted, errors]);
            dispatch_async(dispatch_get_main_queue(), ^{ MI_postResult(@"progress", [NSString stringWithFormat:@"[7] inserted=%d errors=%d", inserted, errors]); });

            // Verify rows were inserted
            {
                sqlite3_stmt *vs = NULL;
                if (sqlite3_prepare_v2(db, "SELECT count(*) FROM messages WHERE text IN ('A','B')", -1, &vs, NULL) == SQLITE_OK) {
                    if (sqlite3_step(vs) == SQLITE_ROW) {
                        long long cnt = sqlite3_column_int64(vs, 0);
                        [report appendFormat:@"Verify: %lld rows with text A/B found in messages table\n", cnt];
                        MI_progress([NSString stringWithFormat:@"inject: verify %lld rows found", cnt]);
                    }
                    sqlite3_finalize(vs);
                }
            }

            // Force WAL checkpoint so changes are written to main DB file
            // Exact v2.6-era flush (the archived-list-success window).
            // Short busy timeout prevents the historic indefinite hang;
            // worst case it returns busy and data stays WAL-committed.
            {
                sqlite3_busy_timeout(db, 300);
                sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE)", NULL, NULL, NULL);
                sqlite3_busy_timeout(db, 5000);
            }
            MI_progress(@"inject: WAL checkpoint done");
            dispatch_async(dispatch_get_main_queue(), ^{ MI_postResult(@"progress", @"[8] checkpoint done - sending result"); });
            if (threadPk > 0) {
                NSString *lastText = [messages.lastObject[@"t"] ?: @"" copy];
                long long lastTs = nowMs;
                // Get last inserted client_messages pk
                long long lastMsgPk = 0;
                {
                    sqlite3_stmt *s = NULL;
                    if (sqlite3_prepare_v2(db, "SELECT MAX(pk) FROM client_messages WHERE thread_pk = ?", -1, &s, NULL) == SQLITE_OK) {
                        sqlite3_bind_int64(s, 1, threadPk);
                        if (sqlite3_step(s) == SQLITE_ROW) lastMsgPk = sqlite3_column_int64(s, 0);
                        sqlite3_finalize(s);
                    }
                }
                NSString *updSql = [NSString stringWithFormat:
                    @"UPDATE client_threads SET "
                    @"last_activity_authoritative_ts_ms = %lld, "
                    @"last_activity_timestamp_ms = %lld, "
                    @"snippet = '%@', "
                    @"snippet_message_pk = %lld, "
                    @"last_activity_sort_order = %lld "
                    @"WHERE pk = %lld",
                    lastTs, lastTs, MI_esc(lastText), lastMsgPk, lastMsgPk, threadPk];
                char *upErr = NULL;
                int upRc = sqlite3_exec(db, updSql.UTF8String, NULL, NULL, &upErr);
                if (upRc == SQLITE_OK) {
                    [report appendFormat:@"client_threads updated: snippet=\"%@\" pk=%lld\n", lastText, lastMsgPk];
                    MI_progress(@"inject: client_threads updated");
                } else {
                    [report appendFormat:@"client_threads UPDATE error: %s\n", upErr ? upErr : "?"];
                    if (upErr) sqlite3_free(upErr);
                }
            }

            MI_sniffInto(db, threadId, threadPk, report);
            MI_threadRowInto(db, threadId, report);
            MI_compareRealVsInjected(db, report);

            // v2.8 technique (proven: archived-list success) - for chats WITH an
            // existing sync row, write our snippet into the sync layer itself.
            // Minimal column set only; full-row updates are crash-prone.
            {
                NSDictionary *lastMsg = messages.lastObject;
                NSString *lastText2 = lastMsg[@"t"] ?: @"";
                BOOL lastIsMe = [lastMsg[@"s"] isEqualToString:@"me"];
                NSString *snip = lastIsMe ? [NSString stringWithFormat:@"You: %@", lastText2] : lastText2;
                NSString *upd2 = [NSString stringWithFormat:
                    @"UPDATE threads SET snippet = '%@', snippet_sender_contact_id = '%@' "
                    @"WHERE thread_key = '%@'",
                    MI_esc(snip), lastIsMe ? localUid : threadId, MI_esc(threadId)];
                char *e2 = NULL;
                if (sqlite3_exec(db, upd2.UTF8String, NULL, NULL, &e2) == SQLITE_OK) {
                    [report appendFormat:@"threads (sync) updated (%d row(s))\n", sqlite3_changes(db)];
                } else {
                    [report appendFormat:@"threads UPDATE error: %s\n", e2 ? e2 : "?"];
                    if (e2) sqlite3_free(e2);
                }
            }

            sqlite3_close(db);
            [report appendFormat:@"\n=== Result: %d inserted, %d errors ===\n", inserted, errors];
            [report appendString:@"\n⚠️ Kill and reopen Messenger to see new messages (cold start reads fresh DB).\n"];

            // Machine-readable result line (helper parses this for the plain-English banner)
            BOOL okFinal = (errors == 0 && inserted > 0);
            [report appendFormat:@"@@MIRESULT|ok=%d|inserted=%d|errors=%d|thread_pk=%lld|method=%@|name=%@|thread_id=%@|@@\n",
                okFinal ? 1 : 0, inserted, errors, threadPk, pkMethod, resolvedName, threadId];

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
                while ((rel = [en nextObject]) && count < 400) {
                    // Skip cask (RTC models) and rtc_models — too many irrelevant files
                    if ([rel containsString:@"cask/"] || [rel containsString:@"rtc_models"]) continue;
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
                if (count >= 400) [result appendString:@"... (truncated at 400 entries)\n"];
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
                while ((rel = [en nextObject]) && count < 400) {
                    // Skip cask (RTC models) and rtc_models — too many irrelevant files
                    if ([rel containsString:@"cask/"] || [rel containsString:@"rtc_models"]) continue;
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
                if (count >= 400) [result appendString:@"... (truncated at 400 entries)\n"];
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
    // Set crash file path for signal handler (async-signal-safe C string)
    NSString *crashPath = MI_crashFile();
    strncpy(g_crashFilePath, crashPath.UTF8String ?: "", sizeof(g_crashFilePath) - 1);

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
        [dnc addObserverForName:kNotifyResearch object:nil queue:[NSOperationQueue mainQueue]
            usingBlock:^(NSNotification *n) { @try { MI_hResearch(n.userInfo[@"threadId"] ?: @"", n.userInfo[@"mode"] ?: @"map"); } @catch (NSException *e) { MI_progress([NSString stringWithFormat:@"research: %@", e.name]); } }];
        [dnc addObserverForName:kNotifySniff object:nil queue:[NSOperationQueue mainQueue]
            usingBlock:^(NSNotification *n) { @try { MI_hSniff(n.userInfo[@"threadId"] ?: @""); } @catch (NSException *e) { MI_progress([NSString stringWithFormat:@"sniff obs: %@", e.name]); } }];
        [dnc addObserverForName:kNotifyThreadRow object:nil queue:[NSOperationQueue mainQueue]
            usingBlock:^(NSNotification *n) { @try { MI_hThreadRow(n.userInfo[@"threadId"] ?: @""); } @catch (NSException *e) { MI_progress([NSString stringWithFormat:@"syncrow obs: %@", e.name]); } }];
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
