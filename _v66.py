import io
p = 'D:/agentic-fm/messenger-injector/dylib/MessengerInjector.m'
s = io.open(p, encoding='utf-8').read()

# Storage survey: enumerate ALL sqlite DBs in Messenger containers + table counts
anchor = '''    // Auto class-scan DISABLED for crash bisect (trigger manually via Diagnostics).'''
assert s.count(anchor) == 1
survey = anchor + '''

    // Storage survey: find EVERY SQLite store in reachable containers.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            @try {
                NSMutableString *r = [NSMutableString string];
                [r appendString:@"=== STORAGE SURVEY ===\\n"];
                NSFileManager *fm = [NSFileManager defaultManager];
                NSMutableArray *roots = [NSMutableArray array];
                NSString *known = MI_findDatabase();
                if (known.length > 0) {
                    NSRange ar = [known rangeOfString:@"Application Support"];
                    if (ar.location != NSNotFound)
                        [roots addObject:[known substringToIndex:ar.location]]; // app-group root
                }
                [roots addObject:@"/private/var/mobile/Containers/Shared/AppGroup"];
                NSMutableSet *seen = [NSMutableSet set];
                CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
                for (NSString *root in roots) {
                    NSDirectoryEnumerator *en = [fm enumeratorAtURL:[NSURL fileURLWithPath:root]
                        includingPropertiesForKeys:@[NSURLIsRegularFileKey, NSFileSizeKey]
                        options:NSDirectoryEnumerationSkipsPackageDescendants errorHandler:nil];
                    for (NSURL *u in en) {
                        if (CFAbsoluteTimeGetCurrent() - t0 > 12.0) break;
                        NSNumber *isReg = nil;
                        [u getResourceValue:&isReg forKey:NSURLIsRegularFileKey error:nil];
                        if (![isReg boolValue]) continue;
                        NSString *ext = u.pathExtension.lowercaseString;
                        if (![ext isEqualToString:@"db"] && ![ext isEqualToString:@"sqlite"] && ![ext isEqualToString:@"store"]) continue;
                        NSDictionary *sz = [u resourceValuesForKeys:@[NSFileSize] error:nil];
                        unsigned long long fsz = [sz[NSFileSize] unsignedLongLongValue];
                        if (fsz < 4096 || fsz > 500*1024*1024) continue;
                        NSString *canon = u.path;
                        if ([seen containsObject:canon]) continue;
                        [seen addObject:canon];
                        // open read-only, count tables, detect thread-ish tables
                        sqlite3 *d2 = NULL;
                        if (sqlite3_open_v2(canon.UTF8String, &d2, SQLITE_OPEN_READONLY, NULL) != SQLITE_OK) { if (d2) sqlite3_close(d2); continue; }
                        sqlite3_stmt *ts2 = NULL;
                        int tabs = 0;
                        BOOL hasThreads = NO, hasCM = NO, hasSnippet = NO;
                        if (sqlite3_prepare_v2(d2, "SELECT name FROM sqlite_master WHERE type='table'", -1, &ts2, NULL) == SQLITE_OK) {
                            while (sqlite3_step(ts2) == SQLITE_ROW) {
                                tabs++;
                                NSString *tn = (NSString *)MI_cstr(sqlite3_column_text(ts2,0)) ?: @"";
                                if ([tn isEqualToString:@"threads"]) hasThreads = YES;
                                if ([tn isEqualToString:@"client_messages"]) hasCM = YES;
                                if ([tn.lowercaseString containsString:@"thread"]) hasSnippet = YES;
                            }
                            sqlite3_finalize(ts2);
                        }
                        sqlite3_close(d2);
                        [r appendFormat:[NSString stringWithFormat:@"%%@ (%llu KB)%@%@\\n", fsz/1024,
                            hasThreads ? @" [threads]" : @"", hasCM ? @" [client_messages]" : @""]];
                        if (hasThreads || hasCM) [seen addObject:[NSString stringWithFormat:@"HIT-%@", canon]];
                    }
                }
                MI_SLOG_APPEND(r);

                dispatch_async(dispatch_get_main_queue(), ^{ MI_postResult(@"progress", r); });
            } @catch (NSException *e) {
                MI_postResult(@"progress", [NSString stringWithFormat:@"survey exc: %@", e.reason]);
            }
        });
    });
'''
# NOTE: MISLogAppend not defined here; replace marker with plain post (drop SLOG usage)
survey = survey.replace('''            MI_SLOG_APPEND(r);
''', ''')
            ''' )
survey = survey.replace('''                [r appendFormat:[NSString stringWithFormat:@"%%@ (%%llu KB)%%@%%@\\n", fsz/1024,
                            hasThreads ? @" [threads]" : @"", hasCM ? @" [client_messages]" : @""]];''',
'''                [r appendFormat:@"%@ (%llu KB)%@%@\\n", canon, fsz/1024,
                            hasThreads ? @" [threads]" : @"", hasCM ? @" [client_messages]" : @""];''')

s = s.replace(anchor, survey)

io.open(p, 'w', encoding='utf-8', newline='').write(s)
print('storage survey installed')
