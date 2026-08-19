/**
 * MessengerInjector.dylib v1.1
 *
 * SQLite schema dump + sample data extraction from Messenger's local database.
 * Also retains v1.0 UI-automation message injection.
 *
 * New triggers (v1.1):
 *   IN:  com.messenger.injector.findDB     — find & log database path
 *   IN:  com.messenger.injector.dumpSchema — dump all table definitions
 *   IN:  com.messenger.injector.dumpSample — dump sample rows from message tables
 *
 * Retained triggers (v1.0):
 *   IN:  com.messenger.injector.send       — UI-automation message send
 *   IN:  com.messenger.injector.dump       — view hierarchy dump
 *   OUT: com.messenger.injector.ready      — dylib loaded
 *
 * Build:
 *   xcrun clang -dynamiclib -arch arm64 \
 *     -isysroot $(xcrun --sdk iphoneos --show-sdk-path) \
 *     -miphoneos-version-min=15.0 \
 *     -framework Foundation -framework UIKit \
 *     -lsqlite3 \
 *     -ObjC -fobjc-arc -O2 \
 *     -o libMessengerInjector.dylib MessengerInjector.m
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <sqlite3.h>

#pragma clang diagnostic ignored "-Wdeprecated-declarations"

// NSDistributedNotificationCenter is not in the iOS SDK umbrella header.
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
// Notification names
// ============================================================
static NSString *const kNotifySend       = @"com.messenger.injector.send";
static NSString *const kNotifyDump       = @"com.messenger.injector.dump";
static NSString *const kNotifyReady      = @"com.messenger.injector.ready";
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
// Forward declarations
// ============================================================
static void     MI_log(NSString *fmt, ...);
static BOOL     MI_stringContains(NSString *haystack, NSString *needle);
static NSString *MI_findDatabase(void);
static void     MI_dumpSchemaToFile(NSString *dbPath);
static void     MI_dumpSampleData(NSString *dbPath);
static void     MI_dumpViewHierarchy(UIView *view, NSInteger level, NSFileHandle *out);
static void     MI_dumpViewToTempFile(UIView *root);
static UIView  *MI_firstViewOfClass(UIView *root, Class cls);
static UIView  *MI_findCustomInput(UIView *view);
static UIView  *MI_findInputControl(UIView *root);
static void     MI_collectSendCandidates(UIView *view, NSMutableArray<UIView *> *out,
                                         UIWindow *win, CGFloat midX, CGFloat midY);
static UIView  *MI_findSendControl(UIView *root);
static void     MI_typeAndSend(NSString *message);
static void     MI_sendMessage(NSString *message, NSString *threadId,
                               BOOL isGroup, NSString *delayStr);
static void     MI_handleDump(void);
static void     MI_handleFindDB(void);
static void     MI_handleDumpSchema(void);
static void     MI_handleDumpSample(void);

// ============================================================
// Logging
// ============================================================
static void MI_log(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt locale:nil arguments:args];
    va_end(args);
    NSLog(@"[MI] %@", msg);
}

static BOOL MI_stringContains(NSString *haystack, NSString *needle) {
    if (!haystack.length || !needle.length) return NO;
    return [haystack rangeOfString:needle options:NSCaseInsensitiveSearch].location != NSNotFound;
}

// ============================================================
// Database discovery
// ============================================================

/// Search for lightspeed-*.db in the app's sandbox and shared containers.
static NSString *MI_findDatabase(void) {
    if (gFoundDBPath.length > 0) return gFoundDBPath;

    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray<NSString *> *searchPaths = [NSMutableArray array];

    // 1. App's main container
    NSString *home = NSHomeDirectory();
    [searchPaths addObject:[home stringByAppendingPathComponent:@"Library"]];
    [searchPaths addObject:[home stringByAppendingPathComponent:@"Documents"]];
    [searchPaths addObject:home];

    // 2. AppGroup shared containers
    // Messenger uses a specific AppGroup. Search all shared containers.
    NSString *sharedBase = @"/var/mobile/Containers/Shared/AppGroup";
    NSArray *sharedGroups = [fm contentsOfDirectoryAtPath:sharedBase error:nil];
    for (NSString *group in sharedGroups) {
        NSString *groupPath = [sharedBase stringByAppendingPathComponent:group];
        [searchPaths addObject:groupPath];
        // Also check common subdirectories
        [searchPaths addObject:[groupPath stringByAppendingPathComponent:@"Library"]];
        [searchPaths addObject:[groupPath stringByAppendingPathComponent:@"Database"]];
        [searchPaths addObject:[groupPath stringByAppendingPathComponent:@"Application Support"]];
    }

    // 3. Application containers (other apps)
    NSString *appBase = @"/var/mobile/Containers/Application";
    NSArray *appGroups = [fm contentsOfDirectoryAtPath:appBase error:nil];
    for (NSString *group in appGroups) {
        NSString *groupPath = [appBase stringByAppendingPathComponent:group];
        [searchPaths addObject:[groupPath stringByAppendingPathComponent:@"Library"]];
        [searchPaths addObject:[groupPath stringByAppendingPathComponent:@"Documents"]];
    }

    // Search for lightspeed-*.db in all paths
    NSMutableSet<NSString *> *found = [NSMutableSet set];
    for (NSString *basePath in searchPaths) {
        if (![fm fileExistsAtPath:basePath]) continue;
        
        // Direct check
        NSArray *contents = [fm contentsOfDirectoryAtPath:basePath error:nil];
        for (NSString *file in contents) {
            if ([file hasPrefix:@"lightspeed-"] && [file hasSuffix:@".db"]) {
                NSString *fullPath = [basePath stringByAppendingPathComponent:file];
                [found addObject:fullPath];
                MI_log(@"DB found: %@", fullPath);
            }
        }
        
        // One level deep
        for (NSString *subdir in contents) {
            NSString *subPath = [basePath stringByAppendingPathComponent:subdir];
            BOOL isDir = NO;
            if (![fm fileExistsAtPath:subPath isDirectory:&isDir] || !isDir) continue;
            
            NSArray *subContents = [fm contentsOfDirectoryAtPath:subPath error:nil];
            for (NSString *file in subContents) {
                if ([file hasPrefix:@"lightspeed-"] && [file hasSuffix:@".db"]) {
                    NSString *fullPath = [subPath stringByAppendingPathComponent:file];
                    [found addObject:fullPath];
                    MI_log(@"DB found: %@", fullPath);
                }
            }
        }
    }

    if (found.count > 0) {
        gFoundDBPath = found.allObjects.firstObject;
        MI_log(@"Database selected: %@", gFoundDBPath);
        MI_log(@"All found: %@", found.allObjects);
    } else {
        MI_log(@"WARNING: No lightspeed-*.db found in any search path");
        MI_log(@"Home: %@", home);
        MI_log(@"Shared base exists: %@", [fm fileExistsAtPath:sharedBase] ? @"yes" : @"no");
        MI_log(@"App base exists: %@", [fm fileExistsAtPath:appBase] ? @"yes" : @"no");
    }

    return gFoundDBPath;
}

// ============================================================
// Schema dump
// ============================================================
static void MI_dumpSchemaToFile(NSString *dbPath) {
    if (!dbPath.length) {
        MI_log(@"SCHEMA: No database found. Run findDB first.");
        return;
    }

    sqlite3 *db = NULL;
    int rc = sqlite3_open_v2(dbPath.UTF8String, &db, SQLITE_OPEN_READONLY, NULL);
    if (rc != SQLITE_OK) {
        MI_log(@"SCHEMA: Failed to open DB: %s", sqlite3_errmsg(db));
        sqlite3_close(db);
        return;
    }

    NSString *outPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"mi_schema.txt"];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createFileAtPath:outPath contents:[@"\n" dataUsingEncoding:NSUTF8StringEncoding] attributes:nil];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:outPath];
    if (!fh) {
        MI_log(@"SCHEMA: Cannot write to %@", outPath);
        sqlite3_close(db);
        return;
    }
    [fh seekToEndOfFile];

    // Header
    NSString *header = [NSString stringWithFormat:@"=== Messenger DB Schema ===\nDB: %@\nDate: %@\n\n", dbPath, [NSDate date]];
    [fh writeData:[header dataUsingEncoding:NSUTF8StringEncoding]];

    // All tables and their definitions
    MI_log(@"SCHEMA: Querying sqlite_master...");
    sqlite3_stmt *stmt = NULL;
    rc = sqlite3_prepare_v2(db, "SELECT type, name, sql FROM sqlite_master WHERE sql IS NOT NULL ORDER BY type, name", &stmt, NULL);
    if (rc != SQLITE_OK) {
        [fh writeData:[NSString stringWithFormat:@"ERROR: %s\n\n", sqlite3_errmsg(db)] dataUsingEncoding:NSUTF8StringEncoding];
        sqlite3_close(db);
        return;
    }

    int tableCount = 0;
    int indexCount = 0;
    int triggerCount = 0;
    int viewCount = 0;

    while (sqlite3_step(stmt) == SQLITE_ROW) {
        const char *type = (const char *)sqlite3_column_text(stmt, 0);
        const char *name = (const char *)sqlite3_column_text(stmt, 1);
        const unsigned char *sql = sqlite3_column_text(stmt, 2);

        NSString *line = [NSString stringWithFormat:@"--- %@: %@ ---\n%s\n\n", type, name, sql ? @(sql) : @"(no SQL)"];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];

        if ([[@(type) isEqualToString:@"table"]]) tableCount++;
        else if ([[@(type) isEqualToString:@"index"]]) indexCount++;
        else if ([[@(type) isEqualToString:@"trigger"]]) triggerCount++;
        else if ([[@(type) isEqualToString:@"view"]]) viewCount++;
    }
    sqlite3_finalize(stmt);

    // Summary
    NSString *summary = [NSString stringWithFormat:
        @"=== Summary ===\nTables: %d\nIndexes: %d\nTriggers: %d\nViews: %d\n\n",
        tableCount, indexCount, triggerCount, viewCount];
    [fh writeData:[summary dataUsingEncoding:NSUTF8StringEncoding]];

    // Column details for all tables
    [fh writeData:[@"\n=== Column Details (PRAGMA table_info) ===\n\n" dataUsingEncoding:NSUTF8StringEncoding]];
    
    rc = sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name", &stmt, NULL);
    if (rc == SQLITE_OK) {
        while (sqlite3_step(stmt) == SQLITE_ROW) {
            NSString *tableName = [@(sqlite3_column_text(stmt, 0)) stringByReplacingOccurrencesOfString:@"'" withString:@"''"];
            sqlite3_finalize(stmt);
            
            NSString *pragmaQuery = [NSString stringWithFormat:@"PRAGMA table_info('%@')", tableName];
            sqlite3_stmt *colStmt = NULL;
            rc = sqlite3_prepare_v2(db, pragmaQuery.UTF8String, &colStmt, NULL);
            if (rc != SQLITE_OK) continue;
            
            [fh writeData:[[NSString stringWithFormat:@"\nTable: %@\n", tableName] dataUsingEncoding:NSUTF8StringEncoding]];
            [fh writeData:[@"  cid | name | type | notnull | default | pk\n  ----|------|------|---------|---------|----\n" dataUsingEncoding:NSUTF8StringEncoding]];
            
            while (sqlite3_step(colStmt) == SQLITE_ROW) {
                int cid = sqlite3_column_int(colStmt, 0);
                const char *cname = (const char *)sqlite3_column_text(colStmt, 1);
                const char *ctype = (const char *)sqlite3_column_text(colStmt, 2);
                int notnull = sqlite3_column_int(colStmt, 3);
                const unsigned char *dflt = sqlite3_column_text(colStmt, 4);
                int pk = sqlite3_column_int(colStmt, 5);
                
                NSString *row = [NSString stringWithFormat:@"  %3d | %-24s | %-12s | %d | %-8s | %d\n",
                                 cid, cname ? cname : "", ctype ? ctype : "", notnull,
                                 dflt ? (const char*)dflt : "", pk];
                [fh writeData:[row dataUsingEncoding:NSUTF8StringEncoding]];
            }
            sqlite3_finalize(colStmt);
            
            // Re-prepare the table list statement
            rc = sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name", &stmt, NULL);
            if (rc != SQLITE_OK) break;
        }
        sqlite3_finalize(stmt);
    }

    [fh closeFile];
    sqlite3_close(db);

    MI_log(@"SCHEMA: Dumped to %@", outPath);
    MI_log(@"SCHEMA: %d tables, %d indexes", tableCount, indexCount);
}

// ============================================================
// Sample data dump
// ============================================================
static void MI_dumpSampleData(NSString *dbPath) {
    if (!dbPath.length) {
        MI_log(@"SAMPLE: No database found. Run findDB first.");
        return;
    }

    sqlite3 *db = NULL;
    int rc = sqlite3_open_v2(dbPath.UTF8String, &db, SQLITE_OPEN_READONLY, NULL);
    if (rc != SQLITE_OK) {
        MI_log(@"SAMPLE: Failed to open DB: %s", sqlite3_errmsg(db));
        sqlite3_close(db);
        return;
    }

    NSString *outPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"mi_sample.txt"];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createFileAtPath:outPath contents:[@"\n" dataUsingEncoding:NSUTF8StringEncoding] attributes:nil];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:outPath];
    if (!fh) {
        sqlite3_close(db);
        return;
    }
    [fh seekToEndOfFile];

    [fh writeData:[NSString stringWithFormat:@"=== Sample Data ===\nDB: %@\nDate: %@\n\n", dbPath, [NSDate date]] dataUsingEncoding:NSUTF8StringEncoding];

    // Find tables that likely contain messages
    NSArray *candidateTables = @[@"messages", @"message", @"chat_messages", @"messaging_messages",
                                  @"threads", @"thread", @"chat_threads", @"messaging_threads",
                                  @"chat_bubbles", @"bubbles", @"sync_message"];

    // First, get all table names
    NSMutableArray<NSString *> *allTables = [NSMutableArray array];
    sqlite3_stmt *stmt = NULL;
    rc = sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name", &stmt, NULL);
    if (rc == SQLITE_OK) {
        while (sqlite3_step(stmt) == SQLITE_ROW) {
            [allTables addObject:@(sqlite3_column_text(stmt, 0))];
        }
        sqlite3_finalize(stmt);
    }

    [fh writeData:[@"\n=== All Tables ===\n" dataUsingEncoding:NSUTF8StringEncoding]];
    for (NSString *t in allTables) {
        [fh writeData:[[NSString stringWithFormat:@"%@\n", t] dataUsingEncoding:NSUTF8StringEncoding]];
    }

    // Dump sample from candidate tables
    for (NSString *table in candidateTables) {
        if (![allTables containsObject:table]) continue;
        
        [fh writeData:[[NSString stringWithFormat:@"\n=== Table: %@ (5 rows) ===\n", table] dataUsingEncoding:NSUTF8StringEncoding]];
        
        NSString *query = [NSString stringWithFormat:@"SELECT * FROM %@ LIMIT 5", table];
        sqlite3_stmt *s = NULL;
        rc = sqlite3_prepare_v2(db, query.UTF8String, &s, NULL);
        if (rc != SQLITE_OK) {
            [fh writeData:[[NSString stringWithFormat:@"ERROR: %s\n", sqlite3_errmsg(db)] dataUsingEncoding:NSUTF8StringEncoding]];
            continue;
        }
        
        int colCount = sqlite3_column_count(s);
        
        // Column headers
        NSMutableString *header = [NSMutableString string];
        for (int i = 0; i < colCount; i++) {
            const char *colName = sqlite3_column_name(s, i);
            [header appendFormat:@"%@%@  ", colName ? colName : "?", i < colCount - 1 ? "|" : ""];
        }
        [fh writeData:[[NSString stringWithFormat:@"%@\n", header] dataUsingEncoding:NSUTF8StringEncoding]];
        [fh writeData:[@"---\n" dataUsingEncoding:NSUTF8StringEncoding]];
        
        int rowCount = 0;
        while (sqlite3_step(s) == SQLITE_ROW && rowCount < 5) {
            for (int i = 0; i < colCount; i++) {
                const unsigned char *text = sqlite3_column_text(s, i);
                [fh writeData:[[NSString stringWithFormat:@"%@  ", text ? @(text) : @"NULL"] dataUsingEncoding:NSUTF8StringEncoding]];
                if (i < colCount - 1) {
                    [fh writeData:[@"|" dataUsingEncoding:NSUTF8StringEncoding]];
                }
            }
            [fh writeData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
            rowCount++;
        }
        sqlite3_finalize(s);
    }

    // Also dump sample from any table with "message" in the name
    for (NSString *table in allTables) {
        if (![MI_stringContains(table, @"message") && ![MI_stringContains(table, @"thread") && ![MI_stringContains(table, @"chat")]]) continue;
        if ([candidateTables containsObject:table]) continue; // already done
        
        [fh writeData:[[NSString stringWithFormat:@"\n=== Table: %@ (3 rows, matched by name) ===\n", table] dataUsingEncoding:NSUTF8StringEncoding]];
        
        NSString *query = [NSString stringWithFormat:@"SELECT * FROM %@ LIMIT 3", 
                          [table stringByReplacingOccurrencesOfString:@""" withString:@""""""]];
        sqlite3_stmt *s = NULL;
        rc = sqlite3_prepare_v2(db, query.UTF8String, &s, NULL);
        if (rc != SQLITE_OK) continue;
        
        int colCount = sqlite3_column_count(s);
        while (sqlite3_step(s) == SQLITE_ROW) {
            for (int i = 0; i < colCount; i++) {
                const unsigned char *text = sqlite3_column_text(s, i);
                [fh writeData:[[NSString stringWithFormat:@"%@  ", text ? @(text) : @"NULL"] dataUsingEncoding:NSUTF8StringEncoding]];
                if (i < colCount - 1) [fh writeData:[@"|" dataUsingEncoding:NSUTF8StringEncoding]];
            }
            [fh writeData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
        }
        sqlite3_finalize(s);
    }

    [fh closeFile];
    sqlite3_close(db);

    MI_log(@"SAMPLE: Dumped to %@", outPath);
}

// ============================================================
// View hierarchy (v1.0 — retained)
// ============================================================
static void MI_dumpViewHierarchy(UIView *view, NSInteger level, NSFileHandle *out) {
    if (!view || level > 25) return;
    NSString *indent = [@"" stringByPaddingToLength:(level * 2) withString:@" " startingAtIndex:0];
    NSString *line = [NSString stringWithFormat:@"%@ %@ frame=%@ acc=\"%@\"\n",
                      indent, NSStringFromClass([view class]),
                      NSStringFromCGRect(view.frame),
                      view.accessibilityLabel ?: @""];
    [out writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    for (UIView *sub in view.subviews) {
        MI_dumpViewHierarchy(sub, level + 1, out);
    }
}

static void MI_dumpViewToTempFile(UIView *root) {
    if (!root) return;
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"mi_hierarchy.txt"];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:path]) {
        [fm createFileAtPath:path contents:[@"\n" dataUsingEncoding:NSUTF8StringEncoding] attributes:nil];
    } else {
        [[NSMutableData data] writeToFile:path atomically:YES];
    }
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) return;
    [fh seekToEndOfFile];
    [fh writeData:[[NSString stringWithFormat:@"\n--- %@ ---\n", [NSDate date]] dataUsingEncoding:NSUTF8StringEncoding]];
    MI_dumpViewHierarchy(root, 0, fh);
    [fh writeData:[@"=== end ===\n" dataUsingEncoding:NSUTF8StringEncoding]];
    [fh closeFile];
    MI_log(@"View hierarchy dumped to %@", path);
}

static UIView *MI_firstViewOfClass(UIView *root, Class cls) {
    if (!root) return nil;
    if ([root isKindOfClass:cls]) return root;
    for (UIView *sub in root.subviews) {
        UIView *r = MI_firstViewOfClass(sub, cls);
        if (r) return r;
    }
    return nil;
}

static UIView *MI_findCustomInput(UIView *view) {
    if (!view) return nil;
    if ([view isKindOfClass:[UITextView class]] || [view isKindOfClass:[UITextField class]]) return nil;
    if ([view respondsToSelector:@selector(setText:)] &&
        [view respondsToSelector:@selector(becomeFirstResponder)] &&
        view.isUserInteractionEnabled) {
        UIWindow *win = [UIApplication sharedApplication].keyWindow;
        if (win) {
            CGRect inWin = [view convertRect:view.bounds toView:win];
            if (inWin.origin.y > win.bounds.size.height * 0.5) return view;
        }
    }
    for (UIView *sub in view.subviews) {
        UIView *r = MI_findCustomInput(sub);
        if (r) return r;
    }
    return nil;
}

static UIView *MI_findInputControl(UIView *root) {
    if (!root) return nil;
    UIView *tv = MI_firstViewOfClass(root, [UITextView class]);
    if (tv) { MI_log(@"Input: UITextView (%@)", NSStringFromClass([tv class])); return tv; }
    UIView *tf = MI_firstViewOfClass(root, [UITextField class]);
    if (tf) { MI_log(@"Input: UITextField (%@)", NSStringFromClass([tf class])); return tf; }
    UIView *custom = MI_findCustomInput(root);
    if (custom) { MI_log(@"Input: custom (%@)", NSStringFromClass([custom class])); return custom; }
    return nil;
}

static void MI_collectSendCandidates(UIView *view, NSMutableArray<UIView *> *out,
                                      UIWindow *win, CGFloat midX, CGFloat midY) {
    if (!view) return;
    if ([view isKindOfClass:[UIControl class]] && view.isUserInteractionEnabled) {
        CGRect f = [view convertRect:view.bounds toView:win];
        if (f.origin.y > midY && f.origin.x > midX * 0.3) [out addObject:view];
    }
    for (UIView *sub in view.subviews) {
        MI_collectSendCandidates(sub, out, win, midX, midY);
    }
}

static UIView *MI_findSendControl(UIView *root) {
    if (!root) return nil;
    UIWindow *win = [UIApplication sharedApplication].keyWindow;
    if (!win) return nil;
    CGRect wb = win.bounds;
    CGFloat midY = wb.size.height * 0.5;
    CGFloat midX = wb.size.width * 0.4;
    NSMutableArray<UIView *> *candidates = [NSMutableArray array];
    MI_collectSendCandidates(root, candidates, win, midX, midY);
    if (candidates.count == 0) return nil;
    UIView *best = nil;
    CGFloat bestScore = -1;
    for (UIView *c in candidates) {
        CGRect f = [c convertRect:c.bounds toView:win];
        CGFloat cx = f.origin.x + f.size.width / 2.0;
        CGFloat cy = f.origin.y + f.size.height / 2.0;
        CGFloat size = MAX(f.size.width, f.size.height);
        CGFloat score = 0;
        if (cx > midX) score += 10;
        if (cy > midY) score += 10;
        if (size < 50) score += 25;
        else if (size < 80) score += 15;
        else if (size < 120) score += 5;
        if ([c isKindOfClass:[UIButton class]]) score += 20;
        else if ([c isKindOfClass:[UIControl class]]) score += 10;
        NSString *clsName = NSStringFromClass([c class]);
        NSString *accLabel = c.accessibilityLabel ?: @"";
        if (MI_stringContains(clsName, @"send") || MI_stringContains(accLabel, @"send")) score += 50;
        if (score > bestScore) { bestScore = score; best = c; }
    }
    if (best) MI_log(@"Send: %@ (score=%.0f)", NSStringFromClass([best class]), bestScore);
    return best;
}

static void MI_typeAndSend(NSString *message) {
    UIView *root = [UIApplication sharedApplication].keyWindow.rootViewController.view;
    if (!root) { MI_log(@"ERROR: No root view"); return; }
    UIView *input = MI_findInputControl(root);
    if (!input) {
        MI_log(@"WARNING: No input found. Dumping...");
        MI_dumpViewToTempFile(root);
        return;
    }
    if ([input isKindOfClass:[UITextView class]]) {
        UITextView *tv = (UITextView *)input;
        [tv becomeFirstResponder];
        [tv setText:message];
        [[NSNotificationCenter defaultCenter] postNotificationName:UITextViewTextDidChangeNotification object:tv];
    } else if ([input isKindOfClass:[UITextField class]]) {
        UITextField *tf = (UITextField *)input;
        [tf becomeFirstResponder];
        [tf setText:message];
        [[NSNotificationCenter defaultCenter] postNotificationName:UITextFieldTextDidChangeNotification object:tf];
    } else {
        if ([input respondsToSelector:@selector(setText:)]) {
            [input performSelector:@selector(setText:) withObject:message];
            [input performSelector:@selector(becomeFirstResponder)];
        } else {
            MI_dumpViewToTempFile(root);
            return;
        }
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIView *send = MI_findSendControl(root);
        if (send && [send isKindOfClass:[UIControl class]]) {
            [(UIControl *)send sendActionsForControlEvents:UIControlEventTouchUpInside];
            MI_log(@"SENT: \"%@\" to %@", message, gLastThreadID);
        } else {
            MI_log(@"WARNING: No send control. Dumping...");
            MI_dumpViewToTempFile(root);
        }
    });
}

static void MI_sendMessage(NSString *message, NSString *threadId,
                           BOOL isGroup, NSString *delayStr) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *urlStr = isGroup
            ? [NSString stringWithFormat:@"fb-messenger://group-thread/%@", threadId]
            : [NSString stringWithFormat:@"fb-messenger://user-thread/%@", threadId];
        NSURL *url = [NSURL URLWithString:urlStr];
        if (!url) { MI_log(@"ERROR: Bad URL %@", urlStr); return; }
        MI_log(@"Opening: %@", urlStr);
        double delay = delayStr.length > 0 ? MAX([delayStr doubleValue], 0.5) : 2.5;
        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:^(BOOL ok) {
            if (!ok) { MI_log(@"ERROR: openURL failed"); return; }
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ MI_typeAndSend(message); });
        }];
    });
}

// ============================================================
// Trigger handlers
// ============================================================
static void MI_handleDump(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *root = [UIApplication sharedApplication].keyWindow.rootViewController.view;
        if (!root) { MI_log(@"DUMP: No root view"); return; }
        MI_log(@"DUMP: Starting...");
        MI_dumpViewToTempFile(root);
    });
}

static void MI_handleFindDB(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        MI_log(@"FINDDB: Searching for lightspeed-*.db...");
        NSString *path = MI_findDatabase();
        if (path) {
            MI_log(@"FINDDB: Found at %@", path);
            // Also log file size
            NSFileManager *fm = [NSFileManager defaultManager];
            NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
            unsigned long long size = [attrs[NSFileSize] unsignedLongLongValue];
            MI_log(@"FINDDB: File size: %llu bytes (%.1f MB)", size, size / 1048576.0);
        } else {
            MI_log(@"FINDDB: Not found");
        }
    });
}

static void MI_handleDumpSchema(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        MI_log(@"DUMPSchema: Starting...");
        NSString *dbPath = MI_findDatabase();
        MI_dumpSchemaToFile(dbPath);
    });
}

static void MI_handleDumpSample(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        MI_log(@"DUMPSample: Starting...");
        NSString *dbPath = MI_findDatabase();
        MI_dumpSampleData(dbPath);
    });
}

// ============================================================
// Constructor
// ============================================================
__attribute__((constructor))
static void MI_constructor(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{

        [[NSDistributedNotificationCenter defaultCenter]
            addObserverForName:kNotifySend
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *note) {
            NSString *msg = note.userInfo[kKeyMessage];
            NSString *tid = note.userInfo[kKeyThreadID];
            BOOL isGroup = [note.userInfo[kKeyIsGroup] boolValue];
            NSString *dly = note.userInfo[kKeyDelay];
            if (!msg.length || !tid.length) { MI_log(@"ERROR: Missing message/threadId"); return; }
            gLastThreadID = tid;
            MI_log(@"TRIGGER send: msg=\"%@\" thread=\"%@\" group=%d", msg, tid, isGroup);
            MI_sendMessage(msg, tid, isGroup, dly);
        }];

        [[NSDistributedNotificationCenter defaultCenter]
            addObserverForName:kNotifyDump
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *note) {
            MI_log(@"TRIGGER dump (view hierarchy)");
            MI_handleDump();
        }];

        [[NSDistributedNotificationCenter defaultCenter]
            addObserverForName:kNotifyFindDB
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *note) {
            MI_handleFindDB();
        }];

        [[NSDistributedNotificationCenter defaultCenter]
            addObserverForName:kNotifyDumpSchema
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *note) {
            MI_handleDumpSchema();
        }];

        [[NSDistributedNotificationCenter defaultCenter]
            addObserverForName:kNotifyDumpSample
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *note) {
            MI_handleDumpSample();
        }];

        [[NSDistributedNotificationCenter defaultCenter]
            postNotificationName:kNotifyReady
                          object:nil
                        userInfo:@{@"dylib": @"MessengerInjector",
                                   @"version": @"1.1"}
              deliverImmediately:YES];

        MI_log(@"v1.1 loaded. Triggers: send, dump, findDB, dumpSchema, dumpSample");
    });
}