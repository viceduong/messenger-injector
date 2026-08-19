/**
 * MessengerInjector.dylib
 *
 * Injects custom messages into specific Facebook Messenger chats on iOS.
 * Designed for injection via TrollFools on TrollStore (iOS 15.6.1, A15/arm64e).
 *
 * Protocol (NSDistributedNotificationCenter):
 *   IN:  com.messenger.injector.send
 *        userInfo: { message: NSString, threadId: NSString, isGroup: NSNumber(BOOL), delay: NSNumber(NSString, optional) }
 *   IN:  com.messenger.injector.dump
 *        userInfo: { } (no params — dumps view hierarchy to stderr)
 *   OUT: com.messenger.injector.ready
 *        userInfo: { } (posted once when dylib is loaded and listening)
 *
 * Build:
 *   xcrun clang -dynamiclib -arch arm64 \
 *     -isysroot $(xcrun --sdk iphoneos --show-sdk-path) \
 *     -miphoneos-version-min=15.0 \
 *     -framework Foundation -framework UIKit \
 *     -ObjC -fobjc-arc \
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
static NSString *const kKeyDelay    = @"delay";   // seconds (NSString), default "2.5"

static const char *kLogTag = "[MI]";

// ============================================================
// Logging helper
// ============================================================
static void MILog(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt locale:nil arguments:args];
    va_end(args);
    NSLog(@"%@ %@", kLogTag, msg);
}

// ============================================================
// View hierarchy search helpers
// ============================================================

/// Recursively collect all views of a given class.
static NSArray<UIView *> *MI_collectViewsOfClass(UIView *root, Class cls) {
    NSMutableArray *out = [NSMutableArray array];
    if (!root) return out;
    if ([root isKindOfClass:cls]) [out addObject:root];
    for (UIView *sub in root.subviews) {
        [out addObjectsFromArray:MI_collectViewsOfClass(sub, cls)];
    }
    return out;
}

/// Recursively find first view of given class.
static UIView *MI_firstViewOfClass(UIView *root, Class cls) {
    if (!root) return nil;
    if ([root isKindOfClass:cls]) return root;
    for (UIView *sub in root.subviews) {
        UIView *r = MI_firstViewOfClass(sub, cls);
        if (r) return r;
    }
    return nil;
}

/// Find the text input control.
/// Priority: UITextView → UITextField → custom view with text: setter in bottom half.
static UIView *MI_findInputControl(UIView *root) {
    if (!root) return nil;

    // 1. UITextView (LightSpeed likely uses this)
    UIView *tv = MI_firstViewOfClass(root, [UITextView class]);
    if (tv) {
        MILog(@"Input: UITextView (%@)", [tv class]);
        return tv;
    }

    // 2. UITextField
    UIView *tf = MI_firstViewOfClass(root, [UITextField class]);
    if (tf) {
        MILog(@"Input: UITextField (%@)", [tf class]);
        return tf;
    }

    // 3. Custom view: responds to setText: and is in bottom half of screen
    UIView *custom = MI_findCustomInput(root);
    if (custom) {
        MILog(@"Input: custom (%@)", [custom class]);
        return custom;
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

/// Find the send button/control.
/// Scores all UIControl instances in the bottom half, right side.
/// Prefers small, right-aligned, bottom-positioned controls.
static UIView *MI_findSendControl(UIView *root) {
    if (!root) return nil;
    UIWindow *win = [UIApplication sharedApplication].keyWindow;
    if (!win) return nil;

    CGRect wb = win.bounds;
    CGFloat midY = wb.size.height * 0.5;
    CGFloat midX = wb.size.width * 0.4;  // slightly left of center to catch right-aligned buttons

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

        // Bonus for views with "send" in accessibility label or class name
        NSString *clsName = NSStringFromClass([c class]);
        NSString *accLabel = c.accessibilityLabel ?: @"";
        if ([clsName caseInsensitiveContainsString:@"send"] ||
            [accLabel caseInsensitiveContainsString:@"send"]) {
            score += 50;
        }

        if (score > bestScore) {
            bestScore = score;
            best = c;
        }
    }

    if (best) {
        MILog(@"Send: %@ (score=%.0f, frame=%@)", [best class], bestScore,
              NSStringFromCGRect([best convertRect:best.bounds toView:win]));
    }
    return best;
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

// ============================================================
// View hierarchy dumper (debugging)
// ============================================================
static void MI_dumpHierarchy(UIView *view, NSInteger level, NSFileHandle *out) {
    if (!view || level > 25) return;
    NSString *indent = [@"" stringByPaddingToLength:(level * 2)
                                          withString:@" " startingAtIndex:0];
    NSString *line;
    if (level == 0) {
        line = [NSString stringWithFormat:@"%@ %@ (root)\n", indent, NSStringFromClass([view class])];
    } else {
        line = [NSString stringWithFormat:@"%@ %@ frame=%@ accLabel=\"%@\"\n",
                indent, NSStringFromClass([view class]),
                NSStringFromCGRect(view.frame),
                view.accessibilityLabel ?: @""];
    }
    [out writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    for (UIView *sub in view.subviews) {
        MI_dumpHierarchy(sub, level + 1, out);
    }
}

// ============================================================
// Core message-sending logic
// ============================================================
static void MI_sendMessage(NSString *message, NSString *threadId,
                           BOOL isGroup, NSString *delayStr) {
    dispatch_async(dispatch_get_main_queue(), ^{

        // Build deep link
        NSString *urlStr;
        if (isGroup) {
            urlStr = [NSString stringWithFormat:@"fb-messenger://group-thread/%@", threadId];
        } else {
            urlStr = [NSString stringWithFormat:@"fb-messenger://user-thread/%@", threadId];
        }

        NSURL *url = [NSURL URLWithString:urlStr];
        if (!url) {
            MILog(@"ERROR: Invalid URL %@", urlStr);
            return;
        }

        MILog(@"Opening chat: %@", urlStr);

        __block double delay = 2.5;
        if (delayStr.length > 0) {
            delay = [delayStr doubleValue];
            if (delay < 0.5) delay = 0.5;
        }

        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:^(BOOL ok) {
            if (!ok) {
                MILog(@"ERROR: openURL failed for %@", urlStr);
                return;
            }
            MILog(@"Chat opened. Waiting %.1fs for render...", delay);

            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [MI_typeAndSend:message];
            });
        }];
    });
}

static void MI_typeAndSend(NSString *message) {
    UIView *root = [UIApplication sharedApplication].keyWindow.rootViewController.view;
    if (!root) {
        MILog(@"ERROR: No root view found");
        return;
    }

    // Find input
    UIView *input = MI_findInputControl(root);
    if (!input) {
        MILog(@"WARNING: No input control found. Dumping hierarchy for debugging...");
        MI_dumpToTempFile(root);
        return;
    }

    // Type the message
    if ([input isKindOfClass:[UITextView class]]) {
        UITextView *tv = (UITextView *)input;
        [tv becomeFirstResponder];
        [tv setText:message];
        [[NSNotificationCenter defaultCenter]
            postNotificationName:UITextViewTextDidChangeNotification object:tv];
        MILog(@"Typed into UITextView");
    } else if ([input isKindOfClass:[UITextField class]]) {
        UITextField *tf = (UITextField *)input;
        [tf becomeFirstResponder];
        [tf setText:message];
        [[NSNotificationCenter defaultCenter]
            postNotificationName:UITextFieldTextDidChangeNotification object:tf];
        MILog(@"Typed into UITextField");
    } else {
        // Custom view — try setText:
        if ([input respondsToSelector:@selector(setText:)]) {
            [input performSelector:@selector(setText:) withObject:message];
            [input performSelector:@selector(becomeFirstResponder)];
            MILog(@"Typed into custom view (%@)", [input class]);
        } else {
            MILog(@"WARNING: Input view %@ doesn't respond to setText:", [input class]);
            MI_dumpToTempFile(root);
            return;
        }
    }

    // Find and tap send after a short pause
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIView *send = MI_findSendControl(root);
        if (!send) {
            MILog(@"WARNING: No send control found. Dumping hierarchy...");
            MI_dumpToTempFile(root);
            return;
        }

        MILog(@"Tapping send: %@", [send class]);

        if ([send isKindOfClass:[UIControl class]]) {
            [(UIControl *)send sendActionsForControlEvents:UIControlEventTouchUpInside];
        } else {
            // Fallback: simulate touch at center
            CGPoint center = CGPointMake(send.bounds.size.width / 2.0,
                                         send.bounds.size.height / 2.0);
            [send touchesBegan:nil withEvent:nil];
            [send touchesEnded:nil withEvent:nil];
            (void)center;
        }

        MILog(@"SENT: \"%@\" to thread %@", message, threadId);
    });
}

// Capture threadId for logging in the send completion
static NSString *gLastThreadID = nil;

static void MI_dumpToTempFile(UIView *root) {
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"messenger_injector_hierarchy.txt"];
    NSFileHandle *fh = [NSFileHandle fileForWritingAtPath:path];
    if (!fh) {
        [[NSString stringWithString:@""] writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        fh = [NSFileHandle fileForWritingAtPath:path];
    }
    if (fh) {
        [fh seekToEndOfFile];
        [fh writeData:([NSDate date].description + "\n---\n").dataUsingEncoding:NSUTF8StringEncoding];
        MI_dumpHierarchy(root, 0, fh);
        [fh writeData:@"\n=== end ===\n".dataUsingEncoding:NSUTF8StringEncoding];
        [fh closeFile];
        MILog(@"Hierarchy dumped to %@", path);
    }
}

// ============================================================
// Dump handler
// ============================================================
static void MI_handleDump(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *root = [UIApplication sharedApplication].keyWindow.rootViewController.view;
        if (!root) {
            MILog(@"DUMP: No root view");
            return;
        }
        MILog(@"DUMP: View hierarchy dump starting...");
        MI_dumpToTempFile(root);
        MILog(@"DUMP: Complete. Check file in Console or via Filza.");
    });
}

// ============================================================
// Constructor — runs when dylib is loaded into Messenger
// ============================================================
__attribute__((constructor))
static void MI_constructor(void) {
    // Delay to let Messenger finish launching
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{

        // Register for send triggers
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
                MILog(@"ERROR: Missing 'message' or 'threadId' in notification");
                return;
            }

            gLastThreadID = tid;
            MILog(@"TRIGGER: msg=\"%@\" thread=\"%@\" group=%d delay=%@",
                  msg, tid, isGroup, dly ?: @"2.5(default)");

            MI_sendMessage(msg, tid, isGroup, dly);
        }];

        // Register for dump triggers
        [[NSDistributedNotificationCenter defaultCenter]
            addObserverForName:kNotifyDump
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *note) {
            MILog(@"DUMP trigger received");
            MI_handleDump();
        }];

        // Post ready notification
        [[NSDistributedNotificationCenter defaultCenter]
            postNotificationName:kNotifyReady
                          object:nil
                        userInfo:@{@"dylib": @"MessengerInjector",
                                   @"version": @"1.0"}
              deliverImmediately:YES];

        MILog(@"Loaded and ready. Listening for '%@' and '%@'", kNotifySend, kNotifyDump);
    });
}