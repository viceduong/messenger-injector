/**
 * MessengerInjector.dylib
 *
 * Injects custom messages into specific Facebook Messenger chats on iOS.
 * Designed for injection via TrollFools on TrollStore (iOS 15.6.1, A15/arm64e).
 *
 * Protocol (NSDistributedNotificationCenter):
 *   IN:  com.messenger.injector.send
 *        userInfo: { message: NSString, threadId: NSString, isGroup: NSNumber(BOOL), delay: NSString(optional) }
 *   IN:  com.messenger.injector.dump
 *        userInfo: { } (no params — dumps view hierarchy to temp file)
 *   OUT: com.messenger.injector.ready
 *        userInfo: { dylib: NSString, version: NSString }
 *
 * Build:
 *   xcrun clang -dynamiclib -arch arm64 \
 *     -isysroot $(xcrun --sdk iphoneos --show-sdk-path) \
 *     -miphoneos-version-min=15.0 \
 *     -framework Foundation -framework UIKit \
 *     -ObjC -fobjc-arc -O2 \
 *     -o libMessengerInjector.dylib MessengerInjector.m
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// ============================================================
// Notification names & keys
// ============================================================
static NSString *const kNotifySend  = @"com.messenger.injector.send";
static NSString *const kNotifyDump  = @"com.messenger.injector.dump";
static NSString *const kNotifyReady = @"com.messenger.injector.ready";

static NSString *const kKeyMessage  = @"message";
static NSString *const kKeyThreadID = @"threadId";
static NSString *const kKeyIsGroup  = @"isGroup";
static NSString *const kKeyDelay    = @"delay";

static NSString *gLastThreadID = nil;

// ============================================================
// Forward declarations (C requires prototypes before use)
// ============================================================
static void        MI_log(NSString *fmt, ...);
static NSArray<UIView *> *MI_collectViewsOfClass(UIView *root, Class cls);
static UIView     *MI_firstViewOfClass(UIView *root, Class cls);
static UIView     *MI_findCustomInput(UIView *view);
static UIView     *MI_findInputControl(UIView *root);
static void        MI_collectSendCandidates(UIView *view, NSMutableArray<UIView *> *out,
                                            UIWindow *win, CGFloat midX, CGFloat midY);
static UIView     *MI_findSendControl(UIView *root);
static void        MI_dumpHierarchy(UIView *view, NSInteger level, NSFileHandle *out);
static void        MI_dumpToTempFile(UIView *root);
static void        MI_typeAndSend(NSString *message);
static void        MI_sendMessage(NSString *message, NSString *threadId,
                                  BOOL isGroup, NSString *delayStr);
static void        MI_handleDump(void);

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
    NSRange range = [haystack rangeOfString:needle options:NSCaseInsensitiveSearch];
    return range.location != NSNotFound;
}

// ============================================================
// View hierarchy search
// ============================================================
static NSArray<UIView *> *MI_collectViewsOfClass(UIView *root, Class cls) {
    NSMutableArray *out = [NSMutableArray array];
    if (!root) return out;
    if ([root isKindOfClass:cls]) [out addObject:root];
    for (UIView *sub in root.subviews) {
        [out addObjectsFromArray:MI_collectViewsOfClass(sub, cls)];
    }
    return out;
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
            if (inWin.origin.y > win.bounds.size.height * 0.5) {
                return view;
            }
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
    if (tv) {
        MI_log(@"Input: UITextView (%@)", NSStringFromClass([tv class]));
        return tv;
    }

    UIView *tf = MI_firstViewOfClass(root, [UITextField class]);
    if (tf) {
        MI_log(@"Input: UITextField (%@)", NSStringFromClass([tf class]));
        return tf;
    }

    UIView *custom = MI_findCustomInput(root);
    if (custom) {
        MI_log(@"Input: custom (%@)", NSStringFromClass([custom class]));
        return custom;
    }

    return nil;
}

static void MI_collectSendCandidates(UIView *view, NSMutableArray<UIView *> *out,
                                      UIWindow *win, CGFloat midX, CGFloat midY) {
    if (!view) return;
    if ([view isKindOfClass:[UIControl class]] && view.isUserInteractionEnabled) {
        CGRect f = [view convertRect:view.bounds toView:win];
        if (f.origin.y > midY && f.origin.x > midX * 0.3) {
            [out addObject:view];
        }
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
        if (MI_stringContains(clsName, @"send") ||
            MI_stringContains(accLabel, @"send")) {
            score += 50;
        }

        if (score > bestScore) {
            bestScore = score;
            best = c;
        }
    }

    if (best) {
        MI_log(@"Send: %@ (score=%.0f, frame=%@)",
              NSStringFromClass([best class]), bestScore,
              NSStringFromCGRect([best convertRect:best.bounds toView:win]));
    }
    return best;
}

// ============================================================
// View hierarchy dumper
// ============================================================
static void MI_dumpHierarchy(UIView *view, NSInteger level, NSFileHandle *out) {
    if (!view || level > 25) return;
    NSString *indent = [@"" stringByPaddingToLength:(level * 2)
                                          withString:@" " startingAtIndex:0];
    NSString *line = [NSString stringWithFormat:@"%@ %@ frame=%@ acc=\"%@\"\n",
                      indent, NSStringFromClass([view class]),
                      NSStringFromCGRect(view.frame),
                      view.accessibilityLabel ?: @""];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    if (data) [out writeData:data];
    for (UIView *sub in view.subviews) {
        MI_dumpHierarchy(sub, level + 1, out);
    }
}

static void MI_dumpToTempFile(UIView *root) {
    if (!root) return;
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"mi_hierarchy.txt"];

    // Create or truncate the file
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:path]) {
        [fm createFileAtPath:path contents:[@"\n" dataUsingEncoding:NSUTF8StringEncoding] attributes:nil];
    } else {
        // Truncate by rewriting
        [[NSMutableData data] writeToFile:path atomically:YES];
    }

    NSFileHandle *fh = [NSFileHandle fileForWritingAtPath:path];
    if (!fh) {
        MI_log(@"DUMP: Cannot open temp file at %@", path);
        return;
    }

    [fh seekToEndOfFile];
    NSString *header = [NSString stringWithFormat:@"\n--- %@ ---\n", [NSDate date]];
    [fh writeData:[header dataUsingEncoding:NSUTF8StringEncoding]];
    MI_dumpHierarchy(root, 0, fh);
    [fh writeData:[@"=== end ===\n" dataUsingEncoding:NSUTF8StringEncoding]];
    [fh closeFile];

    MI_log(@"Hierarchy dumped to %@", path);
}

// ============================================================
// Type and send
// ============================================================
static void MI_typeAndSend(NSString *message) {
    UIView *root = [UIApplication sharedApplication].keyWindow.rootViewController.view;
    if (!root) {
        MI_log(@"ERROR: No root view found");
        return;
    }

    UIView *input = MI_findInputControl(root);
    if (!input) {
        MI_log(@"WARNING: No input control found. Dumping hierarchy...");
        MI_dumpToTempFile(root);
        return;
    }

    if ([input isKindOfClass:[UITextView class]]) {
        UITextView *tv = (UITextView *)input;
        [tv becomeFirstResponder];
        [tv setText:message];
        [[NSNotificationCenter defaultCenter]
            postNotificationName:UITextViewTextDidChangeNotification object:tv];
        MI_log(@"Typed into UITextView");
    } else if ([input isKindOfClass:[UITextField class]]) {
        UITextField *tf = (UITextField *)input;
        [tf becomeFirstResponder];
        [tf setText:message];
        [[NSNotificationCenter defaultCenter]
            postNotificationName:UITextFieldTextDidChangeNotification object:tf];
        MI_log(@"Typed into UITextField");
    } else {
        if ([input respondsToSelector:@selector(setText:)]) {
            [input performSelector:@selector(setText:) withObject:message];
            [input performSelector:@selector(becomeFirstResponder)];
            MI_log(@"Typed into custom view (%@)", NSStringFromClass([input class]));
        } else {
            MI_log(@"WARNING: Input %@ doesn't respond to setText:", NSStringFromClass([input class]));
            MI_dumpToTempFile(root);
            return;
        }
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIView *send = MI_findSendControl(root);
        if (!send) {
            MI_log(@"WARNING: No send control found. Dumping hierarchy...");
            MI_dumpToTempFile(root);
            return;
        }

        MI_log(@"Tapping send: %@", NSStringFromClass([send class]));

        if ([send isKindOfClass:[UIControl class]]) {
            [(UIControl *)send sendActionsForControlEvents:UIControlEventTouchUpInside];
        }

        MI_log(@"SENT: \"%@\" to thread %@", message, gLastThreadID);
    });
}

// ============================================================
// Send message (deep link + type + send)
// ============================================================
static void MI_sendMessage(NSString *message, NSString *threadId,
                           BOOL isGroup, NSString *delayStr) {
    dispatch_async(dispatch_get_main_queue(), ^{

        NSString *urlStr;
        if (isGroup) {
            urlStr = [NSString stringWithFormat:@"fb-messenger://group-thread/%@", threadId];
        } else {
            urlStr = [NSString stringWithFormat:@"fb-messenger://user-thread/%@", threadId];
        }

        NSURL *url = [NSURL URLWithString:urlStr];
        if (!url) {
            MI_log(@"ERROR: Invalid URL %@", urlStr);
            return;
        }

        MI_log(@"Opening chat: %@", urlStr);

        double delay = 2.5;
        if (delayStr.length > 0) {
            delay = [delayStr doubleValue];
            if (delay < 0.5) delay = 0.5;
        }

        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:^(BOOL ok) {
            if (!ok) {
                MI_log(@"ERROR: openURL failed for %@", urlStr);
                return;
            }
            MI_log(@"Chat opened. Waiting %.1fs for render...", delay);

            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                MI_typeAndSend(message);
            });
        }];
    });
}

// ============================================================
// Dump handler
// ============================================================
static void MI_handleDump(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *root = [UIApplication sharedApplication].keyWindow.rootViewController.view;
        if (!root) {
            MI_log(@"DUMP: No root view");
            return;
        }
        MI_log(@"DUMP: Starting view hierarchy dump...");
        MI_dumpToTempFile(root);
        MI_log(@"DUMP: Complete. Check file via Filza or Console.");
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
            NSString *msg  = note.userInfo[kKeyMessage];
            NSString *tid  = note.userInfo[kKeyThreadID];
            BOOL isGroup  = [note.userInfo[kKeyIsGroup] boolValue];
            NSString *dly  = note.userInfo[kKeyDelay];

            if (!msg.length || !tid.length) {
                MI_log(@"ERROR: Missing 'message' or 'threadId'");
                return;
            }

            gLastThreadID = tid;
            MI_log(@"TRIGGER: msg=\"%@\" thread=\"%@\" group=%d delay=%@",
                  msg, tid, isGroup, dly ?: @"2.5");

            MI_sendMessage(msg, tid, isGroup, dly);
        }];

        [[NSDistributedNotificationCenter defaultCenter]
            addObserverForName:kNotifyDump
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *note) {
            MI_log(@"DUMP trigger received");
            MI_handleDump();
        }];

        [[NSDistributedNotificationCenter defaultCenter]
            postNotificationName:kNotifyReady
                          object:nil
                        userInfo:@{@"dylib": @"MessengerInjector",
                                   @"version": @"1.0"}
              deliverImmediately:YES];

        MI_log(@"Loaded and ready. Listening for send + dump triggers.");
    });
}