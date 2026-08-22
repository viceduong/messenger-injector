import io
p = 'D:/agentic-fm/messenger-injector/dylib/MessengerInjector.m'
s = io.open(p, encoding='utf-8').read()

# Add per-image class discovery; route Diagnostics to it (safer than global scan)
old = 'static void MI_hClassScan(void) {'
assert s.count(old) == 1
new_fn = '''// Per-image discovery: enumerate classes ONLY from Messenger/Facebook images.
// Avoids process-wide objc_getClassList (crashed in this app).
static void MI_hClassScan(void) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @try {
            NSMutableString *r = [NSMutableString string];
            NSArray *filters = @[@"Thread", @"Snippet", @"Summary", @"Inbox", @"Conversation"];
            NSMutableArray *buckets = [NSMutableArray array];
            for (NSUInteger i = 0; i < filters.count; i++) [buckets addObject:[NSMutableArray array]];
            int imgCount = 0;
            int matchedImages = 0;
            for (uint32_t i = 0; i < _dyld_image_count(); i++) {
                const char *ipath = _dyld_get_image_name(i);
                if (!ipath) continue;
                NSString *path = [NSString stringWithUTF8String:ipath];
                NSString *low = path.lowercaseString;
                BOOL interesting = [low containsString:@"messenger"] || [low containsString:@"/fb"] ||
                                   [low containsString:@"facebook"] || [low containsString:@"fblight"];
                if (!interesting) continue;
                imgCount++;
                const struct mach_header_64 *hdr = (const struct mach_header_64 *)_dyld_get_image_header(i);
                if (!hdr) continue;
                size_t sz = 0;
                const char **classNames = objc_copyClassNamesForImage(ipath, &sz);
                matchedImages++;
                for (size_t c = 0; c < sz; c++) {
                    NSString *name = [NSString stringWithUTF8String:classNames[c]];
                    for (NSUInteger f = 0; f < filters.count; f++) {
                        if ([name rangeOfString:filters[f] options:NSCaseInsensitiveSearch].location != NSNotFound) {
                            if ([buckets[f] count] < 25) [buckets[f] addObject:name];
                            break;
                        }
                    }
                }
                free(classNames);
            }
            [r appendFormat:@"fb images: %d (scanned %d)\\n", matchedImages, imgCount];
            for (NSUInteger f = 0; f < filters.count; f++) {
                [r appendFormat:@"\\n== %@ (%d) ==\\n", filters[f], (int)[buckets[f] count]];
                for (NSString *nm in buckets[f]) [r appendFormat:@"%@\\n", nm];
            }

            dispatch_async(dispatch_get_main_queue(), ^{ MI_postResult(@"progress", r); });
        } @catch (NSException *e) {
            MI_postResult(@"progress", [NSString stringWithFormat:@"scan exc: %@", e.reason]);
        }
    });
}

''' + old
s = s.replace(old, new_fn)

io.open(p, 'w', encoding='utf-8', newline='').write(s)
print('per-image scan installed')
