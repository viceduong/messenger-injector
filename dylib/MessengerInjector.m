/**
 * MessengerInjector.dylib v1.1
 *
 * SQLite schema dump + sample data + v1.0 UI-automation message injection.
 *
 * Triggers (NSDistributedNotificationCenter):
 *   IN:  com.messenger.injector.send        — UI-automation send
 *   IN:  com.messenger.injector.dump        — view hierarchy dump
 *   IN:  com.messenger.injector.findDB      — find lightspeed-*.db path
 *   IN:  com.messenger.injector.dumpSchema  — dump all table definitions
 *   IN:  com.messenger.injector.dumpSample  — dump sample rows
 *   OUT: com.messenger.injector.ready       — dylib loaded
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
static NSString *const kNotifyDump       = @"com.messenger.injector.dump";
static NSString *const kNotifyReady      = @"com.messenger.injector.ready";
static NSString *const kNotifyResult     = @"com.messenger.injector.result";
static NSString *const kNotifyFindDB     = @"com.messenger.injector.findDB";
static NSString *const kNotifyDumpSchema = @"com.messenger.injector.dumpSchema";
static NSString *const kNotifyDumpSample = @"com.messenger.injector.dumpSample";

static NSString *const kKeyMessage  = @"message";
static NSString *const kKeyThreadID = @"threadId";
static NSString *const kKeyIsGroup  = @"isGroup";
static NSString *const kKeyDelay    = @"delay";

static NSString *gLastThreadID = nil;
static NSString *gFoundDBPath  = nil;

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

// ============================================================
// Database discovery
// ============================================================
static NSString *MI_findDatabase(void) {
    if (gFoundDBPath.length > 0) return gFoundDBPath;

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *home = NSHomeDirectory();
    MI_log(@"DB search: home=%@", home);

    NSMutableArray<NSString *> *allDBs = [NSMutableArray array];

    // Recursive search for .db files in the app's sandbox
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
            if (![rel hasSuffix:@".db"]) continue;
            NSString *full = [root stringByAppendingPathComponent:rel];
            [allDBs addObject:full];
        }
    }

    // Also search AppGroup shared containers
    NSString *sharedBase = @"/var/mobile/Containers/Shared/AppGroup";
    NSArray *groups = [fm contentsOfDirectoryAtPath:sharedBase error:nil];
    MI_log(@"DB search: %d AppGroups found", (int)groups.count);
    for (NSString *g in groups) {
        NSString *gp = [sharedBase stringByAppendingPathComponent:g];
        NSDirectoryEnumerator *dirEnum = [fm enumeratorAtPath:gp];
        NSString *rel;
        while ((rel = [dirEnum nextObject])) {
            if (![rel hasSuffix:@".db"]) continue;
            [allDBs addObject:[gp stringByAppendingPathComponent:rel]];
        }
    }

    MI_log(@"DB search: %d .db files total", (int)allDBs.count);
    for (NSString *db in allDBs) {
        NSDictionary *attrs = [fm attributesOfItemAtPath:db error:nil];
        unsigned long long sz = [attrs[NSFileSize] unsignedLongLongValue];
        MI_log(@"  DB: %@ (%.1f KB)", db, sz / 1024.0);
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
        // Pick the largest .db file
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
        MI_log(@"DB selected: %@ (%.1f MB)", best, sz / 1048576.0);
    } else {
        MI_log(@"DB: NO .db files found anywhere");
    }
    return gFoundDBPath;
}

// ============================================================
// Schema dump
// ============================================================
static void MI_dumpSchema(NSString *dbPath) {
    if (!dbPath.length) { MI_log(@"SCHEMA: no DB. Run findDB first."); return; }

    sqlite3 *db = NULL;
    if (sqlite3_open_v2(dbPath.UTF8String, &db, SQLITE_OPEN_READONLY, NULL) != SQLITE_OK) {
        MI_log(@"SCHEMA: open failed: %s", db ? sqlite3_errmsg(db) : "null");
        if (db) sqlite3_close(db);
        return;
    }
    sqlite3_busy_timeout(db, 10000); // wait up to 10s for locks

    NSString *out = [NSTemporaryDirectory() stringByAppendingPathComponent:@"mi_schema.txt"];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createFileAtPath:out contents:[@"\n" dataUsingEncoding:NSUTF8StringEncoding] attributes:nil];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:out];
    if (!fh) { sqlite3_close(db); return; }
    [fh seekToEndOfFile];

    MI_write(fh, [NSString stringWithFormat:@"=== Messenger DB Schema ===\nDB: %@\nDate: %@\n\n", dbPath, [NSDate date]]);

    // Table definitions
    sqlite3_stmt *st = NULL;
    if (sqlite3_prepare_v2(db, "SELECT type, name, sql FROM sqlite_master WHERE sql IS NOT NULL ORDER BY type,name", -1, &st, NULL) != SQLITE_OK) {
        MI_write(fh, [NSString stringWithFormat:@"PREPARE ERROR: %s\n", sqlite3_errmsg(db)]);
        [fh closeFile]; sqlite3_close(db); return;
    }

    int tc = 0, ic = 0, trg = 0, vc = 0;
    while (sqlite3_step(st) == SQLITE_ROW) {
        NSString *type = MI_cstr(sqlite3_column_text(st, 0));
        NSString *name = MI_cstr(sqlite3_column_text(st, 1));
        NSString *sql  = MI_cstr(sqlite3_column_text(st, 2));
        MI_write(fh, [NSString stringWithFormat:@"--- %@: %@ ---\n%s\n\n", type, name, sql]);
        if ([type isEqualToString:@"table"]) tc++;
        else if ([type isEqualToString:@"index"]) ic++;
        else if ([type isEqualToString:@"trigger"]) trg++;
        else if ([type isEqualToString:@"view"]) vc++;
    }
    sqlite3_finalize(st);

    MI_write(fh, [NSString stringWithFormat:@"\n=== Summary: %d tables, %d indexes, %d triggers, %d views ===\n\n", tc, ic, trg, vc]);

    // Table row counts (quick, no PRAGMA needed)
    MI_write(fh, @"=== Table Row Counts ===\n\n");
    st = NULL;
    if (sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name", -1, &st, NULL) == SQLITE_OK) {
        while (sqlite3_step(st) == SQLITE_ROW) {
            NSString *tn = MI_cstr(sqlite3_column_text(st, 0));
            sqlite3_finalize(st);
            st = NULL;

            NSString *cq = [NSString stringWithFormat:@"SELECT count(*) FROM '%@'",
                           [tn stringByReplacingOccurrencesOfString:@"'" withString:@"''"]];
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
            if (sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name", -1, &st, NULL) != SQLITE_OK) break;
        }
        if (st) sqlite3_finalize(st);
    }

    [fh closeFile];
    sqlite3_close(db);
    MI_log(@"SCHEMA: dumped to %@", out);
}

// ============================================================
// Sample data dump
// ============================================================
static void MI_dumpSample(NSString *dbPath) {
    if (!dbPath.length) { MI_log(@"SAMPLE: no DB. Run findDB first."); return; }

    sqlite3 *db = NULL;
    if (sqlite3_open_v2(dbPath.UTF8String, &db, SQLITE_OPEN_READONLY, NULL) != SQLITE_OK) {
        MI_log(@"SAMPLE: open failed");
        if (db) sqlite3_close(db);
        return;
    }
    sqlite3_busy_timeout(db, 10000);

    NSString *out = [NSTemporaryDirectory() stringByAppendingPathComponent:@"mi_sample.txt"];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createFileAtPath:out contents:[@"\n" dataUsingEncoding:NSUTF8StringEncoding] attributes:nil];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:out];
    if (!fh) { sqlite3_close(db); return; }
    [fh seekToEndOfFile];

    MI_write(fh, [NSString stringWithFormat:@"=== Sample Data ===\nDB: %@\nDate: %@\n\n", dbPath, [NSDate date]]);

    // All table names
    NSMutableArray<NSString *> *tables = [NSMutableArray array];
    sqlite3_stmt *st = NULL;
    if (sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name", -1, &st, NULL) == SQLITE_OK) {
        while (sqlite3_step(st) == SQLITE_ROW) [tables addObject:MI_cstr(sqlite3_column_text(st, 0))];
        sqlite3_finalize(st);
    }

    MI_write(fh, [NSString stringWithFormat:@"\n=== All %d Tables ===\n", (int)tables.count]);
    for (NSString *t in tables) MI_write(fh, [NSString stringWithFormat:@"%@\n", t]);

    // Candidate tables for message data
    const char *candidates[] = {"messages","message","chat_messages","messaging_messages",
                                 "threads","thread","chat_threads","messaging_threads",
                                 "chat_bubbles","bubbles","sync_message","sync_messages"};
    int ncand = sizeof(candidates) / sizeof(candidates[0]);

    for (int i = 0; i < ncand; i++) {
        NSString *tn = [NSString stringWithUTF8String:candidates[i]];
        if (![tables containsObject:tn]) continue;

        MI_write(fh, [NSString stringWithFormat:@"\n=== %@ (5 rows) ===\n", tn]);
        NSString *q = [NSString stringWithFormat:@"SELECT * FROM %@ LIMIT 5", tn];
        sqlite3_stmt *s = NULL;
        if (sqlite3_prepare_v2(db, q.UTF8String, -1, &s, NULL) != SQLITE_OK) {
            MI_write(fh, [NSString stringWithFormat:@"ERR: %s\n", sqlite3_errmsg(db)]);
            continue;
        }
        int cc = sqlite3_column_count(s);
        for (int c = 0; c < cc; c++) {
            MI_write(fh, [NSString stringWithFormat:@"%@%@", sqlite3_column_name(s, c) ? sqlite3_column_name(s, c) : "?",
                         c < cc - 1 ? " | " : ""]);
        }
        MI_write(fh, @"\n---\n");
        int rn = 0;
        while (sqlite3_step(s) == SQLITE_ROW && rn < 5) {
            for (int c = 0; c < cc; c++) {
                MI_write(fh, [NSString stringWithFormat:@"%@%@", MI_cstr(sqlite3_column_text(s, c)),
                              c < cc - 1 ? " | " : ""]);
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
        BOOL done = NO;
        for (int i = 0; i < ncand; i++) {
            if ([tn isEqualToString:[NSString stringWithUTF8String:candidates[i]]]) { done = YES; break; }
        }
        if (done) continue;

        MI_write(fh, [NSString stringWithFormat:@"\n=== %@ (3 rows, name match) ===\n", tn]);
        NSString *q = [NSString stringWithFormat:@"SELECT * FROM %@ LIMIT 3",
                       [tn stringByReplacingOccurrencesOfString:@"\"" withString:@"\"\""]];
        sqlite3_stmt *s = NULL;
        if (sqlite3_prepare_v2(db, q.UTF8String, -1, &s, NULL) != SQLITE_OK) continue;
        int cc = sqlite3_column_count(s);
        while (sqlite3_step(s) == SQLITE_ROW) {
            for (int c = 0; c < cc; c++) {
                MI_write(fh, [NSString stringWithFormat:@"%@%@", MI_cstr(sqlite3_column_text(s, c)),
                              c < cc - 1 ? " | " : ""]);
            }
            MI_write(fh, @"\n");
        }
        sqlite3_finalize(s);
    }

    [fh closeFile];
    sqlite3_close(db);
    MI_log(@"SAMPLE: dumped to %@", out);
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
    if (![fm fileExistsAtPath:p]) [fm createFileAtPath:p contents:[@"\n" dataUsingEncoding:NSUTF8StringEncoding] attributes:nil];
    else [[NSMutableData data] writeToFile:p atomically:YES];
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
static void MI_postResult(NSString *tag, NSString *text) {
    MI_log(@"%@: %@", tag, text);
    [[NSDistributedNotificationCenter defaultCenter]
        postNotificationName:kNotifyResult
                      object:nil
                    userInfo:@{@"tag": tag, @"text": text.length > 5000 ? [text substringToIndex:5000] : text}
            deliverImmediately:YES];
}

static void MI_hFindDB(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *path = MI_findDatabase();
        if (path) {
            NSFileManager *fm = [NSFileManager defaultManager];
            NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
            unsigned long long sz = [attrs[NSFileSize] unsignedLongLongValue];
            MI_postResult(@"findDB", [NSString stringWithFormat:@"SELECTED: %@\nSize: %.1f MB\n\n(see Console for full .db list)", path, sz / 1048576.0]);
        } else {
            MI_postResult(@"findDB", @"No .db files found in app sandbox or AppGroup containers.\nCheck Console for search details.");
        }
    });
}
static void MI_hSchema(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *dbPath = MI_findDatabase();
        MI_dumpSchema(dbPath);
        NSString *out = [NSTemporaryDirectory() stringByAppendingPathComponent:@"mi_schema.txt"];
        NSString *content = [NSString stringWithContentsOfFile:out encoding:NSUTF8StringEncoding error:nil];
        MI_postResult(@"schema", content.length > 0 ? content : @"Schema file empty or missing.");
    });
}
static void MI_hSample(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *dbPath = MI_findDatabase();
        MI_dumpSample(dbPath);
        NSString *out = [NSTemporaryDirectory() stringByAppendingPathComponent:@"mi_sample.txt"];
        NSString *content = [NSString stringWithContentsOfFile:out encoding:NSUTF8StringEncoding error:nil];
        MI_postResult(@"sample", content.length > 0 ? content : @"Sample file empty or missing.");
    });
}

// ============================================================
// Constructor
// ============================================================
__attribute__((constructor))
static void MI_ctor(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSDistributedNotificationCenter *dnc = [NSDistributedNotificationCenter defaultCenter];

        [dnc addObserverForName:kNotifySend object:nil queue:[NSOperationQueue mainQueue]
            usingBlock:^(NSNotification *n) {
                NSString *m = n.userInfo[kKeyMessage], *t = n.userInfo[kKeyThreadID];
                BOOL g = [n.userInfo[kKeyIsGroup] boolValue];
                if (!m.length || !t.length) { MI_log(@"Missing msg/tid"); return; }
                gLastThreadID = t;
                MI_send(m, t, g, n.userInfo[kKeyDelay]);
            }];
        [dnc addObserverForName:kNotifyDump object:nil queue:[NSOperationQueue mainQueue]
            usingBlock:^(NSNotification *n) { MI_hDump(); }];
        [dnc addObserverForName:kNotifyFindDB object:nil queue:[NSOperationQueue mainQueue]
            usingBlock:^(NSNotification *n) { MI_hFindDB(); }];
        [dnc addObserverForName:kNotifyDumpSchema object:nil queue:[NSOperationQueue mainQueue]
            usingBlock:^(NSNotification *n) { MI_hSchema(); }];
        [dnc addObserverForName:kNotifyDumpSample object:nil queue:[NSOperationQueue mainQueue]
            usingBlock:^(NSNotification *n) { MI_hSample(); }];

        [dnc postNotificationName:kNotifyReady object:nil
            userInfo:@{@"dylib":@"MessengerInjector",@"version":@"1.1"}
            deliverImmediately:YES];
        MI_log(@"v1.1 ready: send, dump, findDB, dumpSchema, dumpSample");
    });
}