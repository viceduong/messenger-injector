/**
 * MIHelper v2.0 — Trigger app for MessengerInjector
 *
 * v2.0: Conversation composer — compose multi-message conversations (Me/Them),
 *        batch-inject into Messenger's local DB. Also: thread list, crash log.
 *
 * Build:
 *   xcrun clang -arch arm64 \
 *     -isysroot $(xcrun --sdk iphoneos --show-sdk-path) \
 *     -miphoneos-version-min=15.0 \
 *     -framework Foundation -framework UIKit \
 *     -ObjC -fobjc-arc -O2 -Wno-cocoa-api-design \
 *     -o MIHelper MIHelper.m
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#pragma clang diagnostic ignored "-Wcocoa-api-design"

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

static NSString *const kNotifySend       = @"com.messenger.injector.send";
static NSString *const kNotifyDump       = @"com.messenger.injector.dump";
static NSString *const kNotifyReady      = @"com.messenger.injector.ready";
static NSString *const kNotifyResult     = @"com.messenger.injector.result";
static NSString *const kNotifyFindDB     = @"com.messenger.injector.findDB";
static NSString *const kNotifySchema  = @"com.messenger.injector.dumpSchema";
static NSString *const kNotifySample  = @"com.messenger.injector.dumpSample";
static NSString *const kNotifyThreads = @"com.messenger.injector.threadList";
static NSString *const kNotifyInject  = @"com.messenger.injector.inject";
static NSString *const kNotifyCrash   = @"com.messenger.injector.crashLog";

// ============================================================
// Message row view (one composer row)
// ============================================================
@interface MIMessageRow : UIView
@property (nonatomic, assign) BOOL isMe; // YES=me (right bubble), NO=them (left bubble)
@property (nonatomic, strong) UISegmentedControl *sideControl;
@property (nonatomic, strong) UITextField *textField;
@property (nonatomic, strong) UITextField *minAgoField;
@property (nonatomic, strong) UIButton *deleteBtn;
@property (nonatomic, copy) void (^onDelete)(MIMessageRow *row);
@end

@implementation MIMessageRow

- (instancetype)init {
    self = [super init];
    if (self) {
        self.translatesAutoresizingMaskIntoConstraints = NO;
        self.backgroundColor = [UIColor secondarySystemBackgroundColor];
        self.layer.cornerRadius = 8;
        _isMe = YES;

        _sideControl = [[UISegmentedControl alloc] initWithItems:@[@"Me", @"Them"]];
        _sideControl.translatesAutoresizingMaskIntoConstraints = NO;
        _sideControl.selectedSegmentIndex = 0;
        [_sideControl setTitleTextAttributes:@{NSFontAttributeName: [UIFont systemFontOfSize:11 weight:UIFontWeightMedium]} forState:UIControlStateNormal];
        [_sideControl addTarget:self action:@selector(sideChanged:) forControlEvents:UIControlEventValueChanged];

        _textField = [[UITextField alloc] init];
        _textField.translatesAutoresizingMaskIntoConstraints = NO;
        _textField.placeholder = @"Message text...";
        _textField.borderStyle = UITextBorderStyleRoundedRect;
        _textField.font = [UIFont systemFontOfSize:14];
        _textField.autocorrectionType = UITextAutocorrectionTypeNo;

        _minAgoField = [[UITextField alloc] init];
        _minAgoField.translatesAutoresizingMaskIntoConstraints = NO;
        _minAgoField.placeholder = @"min ago";
        _minAgoField.borderStyle = UITextBorderStyleRoundedRect;
        _minAgoField.font = [UIFont systemFontOfSize:12];
        _minAgoField.keyboardType = UIKeyboardTypeNumberPad;
        _minAgoField.textAlignment = NSTextAlignmentCenter;
        [_minAgoField.widthAnchor constraintEqualToConstant:65].active = YES;

        _deleteBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        _deleteBtn.translatesAutoresizingMaskIntoConstraints = NO;
        [_deleteBtn setTitle:@"\u2715" forState:UIControlStateNormal];
        _deleteBtn.titleLabel.font = [UIFont systemFontOfSize:18];
        _deleteBtn.tintColor = [UIColor systemRedColor];
        [_deleteBtn addTarget:self action:@selector(deleteTapped) forControlEvents:UIControlEventTouchUpInside];
        [_deleteBtn.widthAnchor constraintEqualToConstant:32].active = YES;

        [self addSubview:_sideControl];
        [self addSubview:_minAgoField];
        [self addSubview:_deleteBtn];
        [self addSubview:_textField];

        [NSLayoutConstraint activateConstraints:@[
            [_sideControl.topAnchor constraintEqualToAnchor:self.topAnchor constant:6],
            [_sideControl.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:8],
            [_sideControl.widthAnchor constraintEqualToConstant:100],
            [_sideControl.heightAnchor constraintEqualToConstant:28],

            [_minAgoField.centerYAnchor constraintEqualToAnchor:_sideControl.centerYAnchor],
            [_minAgoField.leadingAnchor constraintEqualToAnchor:_sideControl.trailingAnchor constant:8],

            [_deleteBtn.centerYAnchor constraintEqualToAnchor:_sideControl.centerYAnchor],
            [_deleteBtn.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-8],

            [_textField.topAnchor constraintEqualToAnchor:_sideControl.bottomAnchor constant:6],
            [_textField.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:8],
            [_textField.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-8],
            [_textField.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-6],
            [_textField.heightAnchor constraintEqualToConstant:34],
        ]];
    }
    return self;
}

- (void)sideChanged:(UISegmentedControl *)c {
    _isMe = (c.selectedSegmentIndex == 0);
}

- (void)deleteTapped {
    if (_onDelete) _onDelete(self);
}

@end

// ============================================================
// View controller
// ============================================================
@interface MIHelperVC : UIViewController <UITextFieldDelegate>
{
    NSString *_resultText;
    BOOL _injectPending;
}
@property (nonatomic, strong) UITextField *threadField;
@property (nonatomic, strong) UISwitch *groupSwitch;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UITextView *resultsView;
@property (nonatomic, strong) UIButton *btnCopy;

// Composer
@property (nonatomic, strong) UIStackView *messageStack;
@property (nonatomic, strong) NSMutableArray<MIMessageRow *> *messageRows;
@property (nonatomic, strong) UIStackView *threadListStack;
@property (nonatomic, strong) NSMutableArray<UIButton *> *threadButtons;
@end

@implementation MIHelperVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.title = @"MI Helper v2.0";
    _resultText = @"";
    _messageRows = [NSMutableArray array];
    _threadButtons = [NSMutableArray array];

    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.showsVerticalScrollIndicator = YES;
    scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    [self.view addSubview:scroll];

    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 8;
    stack.translatesAutoresizingMaskIntoConstraints = NO;

    // Title
    UILabel *title = [[UILabel alloc] init];
    title.text = @"Messenger Injector";
    title.font = [UIFont systemFontOfSize:24 weight:UIFontWeightBold];
    title.textAlignment = NSTextAlignmentCenter;

    // Status
    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.text = @"Waiting for dylib...";
    self.statusLabel.font = [UIFont systemFontOfSize:13];
    self.statusLabel.textColor = [UIColor secondaryLabelColor];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.numberOfLines = 0;

    // === Conversation Composer ===
    UILabel *compSec = [self sec:@"Conversation Composer"];

    self.threadField = [self makeField:@"Thread ID (e.g. user_id)" UIKeyboardType:UIKeyboardTypeDefault];
    self.threadField.text = @"100003506470529"; // auto-populate with your own user ID

    UIView *groupRow = [[UIView alloc] init];
    groupRow.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel *gL = [[UILabel alloc] init];
    gL.text = @"Group chat";
    gL.font = [UIFont systemFontOfSize:14];
    gL.translatesAutoresizingMaskIntoConstraints = NO;
    self.groupSwitch = [[UISwitch alloc] init];
    self.groupSwitch.translatesAutoresizingMaskIntoConstraints = NO;
    [groupRow addSubview:gL];
    [groupRow addSubview:self.groupSwitch];
    [NSLayoutConstraint activateConstraints:@[
        [gL.leadingAnchor constraintEqualToAnchor:groupRow.leadingAnchor],
        [gL.centerYAnchor constraintEqualToAnchor:groupRow.centerYAnchor],
        [self.groupSwitch.trailingAnchor constraintEqualToAnchor:groupRow.trailingAnchor],
        [self.groupSwitch.centerYAnchor constraintEqualToAnchor:groupRow.centerYAnchor],
        [groupRow.heightAnchor constraintEqualToConstant:30],
    ]];

    // Message rows stack
    self.messageStack = [[UIStackView alloc] init];
    self.messageStack.axis = UILayoutConstraintAxisVertical;
    self.messageStack.spacing = 8;
    self.messageStack.translatesAutoresizingMaskIntoConstraints = NO;

    // Add initial row
    [self addMessageRow];

    // Add row button
    UIButton *addBtn = [self makeBtn:@"+ Add Message" bg:[UIColor systemGray3Color] act:@selector(addRowTapped) h:36];

    // Inject button
    UIButton *injectBtn = [self makeBtn:@"\U0001F851 Inject Conversation" bg:[UIColor systemBlueColor] act:@selector(injectTapped) h:48];

    // === Debug ===
    UILabel *dbgSec = [self sec:@"Debug & Diagnostics"];
    UIButton *findDBBtn   = [self makeBtn:@"Find Database"       bg:[UIColor secondarySystemBackgroundColor] act:@selector(findDBTapped)   h:40];
    UIButton *schemaBtn   = [self makeBtn:@"Dump DB Schema"       bg:[UIColor systemOrangeColor] act:@selector(dumpSchemaTapped) h:40];
    UIButton *sampleBtn   = [self makeBtn:@"Dump Sample Data"     bg:[UIColor systemOrangeColor] act:@selector(dumpSampleTapped) h:40];
    UIButton *threadsBtn  = [self makeBtn:@"Scan Threads"         bg:[UIColor systemTealColor] act:@selector(threadsTapped) h:40];
    
    // Thread picker list (populated when Scan Threads is tapped)
    self.threadListStack = [[UIStackView alloc] init];
    self.threadListStack.axis = UILayoutConstraintAxisVertical;
    self.threadListStack.spacing = 4;
    self.threadListStack.translatesAutoresizingMaskIntoConstraints = NO;
    UIButton *crashBtn    = [self makeBtn:@"Get Crash Log"        bg:[UIColor systemRedColor] act:@selector(crashTapped) h:40];
    UIButton *listFilesBtn = [self makeBtn:@"List All Files"         bg:[UIColor systemPurpleColor] act:@selector(listFilesTapped) h:40];
    UIButton *dumpViewBtn = [self makeBtn:@"Dump View Hierarchy"  bg:[UIColor secondarySystemBackgroundColor] act:@selector(dumpViewTapped) h:40];

    // === Results ===
    UILabel *resSec = [self sec:@"Results"];
    self.resultsView = [[UITextView alloc] init];
    self.resultsView.editable = NO;
    self.resultsView.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    self.resultsView.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.resultsView.layer.cornerRadius = 8;
    self.resultsView.text = @"Tap a button above, results appear here.";
    self.resultsView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.resultsView.heightAnchor constraintEqualToConstant:250].active = YES;

    self.btnCopy = [self makeBtn:@"Copy Results" bg:[UIColor systemGreenColor] act:@selector(copyTapped) h:36];

    [stack addArrangedSubview:title];
    [stack addArrangedSubview:self.statusLabel];
    [stack addArrangedSubview:compSec];
    [stack addArrangedSubview:self.threadField];
    [stack addArrangedSubview:groupRow];
    [stack addArrangedSubview:self.messageStack];
    [stack addArrangedSubview:addBtn];
    [stack addArrangedSubview:injectBtn];
    [stack addArrangedSubview:dbgSec];
    [stack addArrangedSubview:findDBBtn];
    [stack addArrangedSubview:schemaBtn];
    [stack addArrangedSubview:sampleBtn];
    [stack addArrangedSubview:threadsBtn];
    [stack addArrangedSubview:self.threadListStack];
    [stack addArrangedSubview:crashBtn];
    [stack addArrangedSubview:listFilesBtn];
    [stack addArrangedSubview:dumpViewBtn];
    [stack addArrangedSubview:resSec];
    [stack addArrangedSubview:self.resultsView];
    [stack addArrangedSubview:self.btnCopy];

    [scroll addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:scroll.topAnchor constant:10],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.bottomAnchor constant:-10],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.leadingAnchor constant:16],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.trailingAnchor constant:-16],
        [stack.widthAnchor constraintEqualToAnchor:scroll.widthAnchor constant:-32],
    ]];

    // Listen for dylib ready
    [[NSDistributedNotificationCenter defaultCenter]
        addObserverForName:kNotifyReady
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
            dispatch_async(dispatch_get_main_queue(), ^{
                NSString *ver = note.userInfo[@"version"] ?: @"?";
                self.statusLabel.text = [NSString stringWithFormat:@"\U0001F7E2 Dylib v%@ ready", ver];
                self.statusLabel.textColor = [UIColor systemGreenColor];
            });
        }];

    // Listen for results from dylib
    [[NSDistributedNotificationCenter defaultCenter]
        addObserverForName:kNotifyResult
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
            dispatch_async(dispatch_get_main_queue(), ^{
                NSString *tag = note.userInfo[@"tag"] ?: @"result";
                NSString *text = note.userInfo[@"text"] ?: @"(empty)";
                _resultText = [NSString stringWithFormat:@"[%@]\n%@", tag, text];
                self.resultsView.text = _resultText;
                [self.resultsView scrollRangeToVisible:NSMakeRange(0, 0)];
                if ([tag isEqualToString:@"inject"]) _injectPending = NO;
                
                // Parse threadList JSON and display tappable buttons
                if ([tag isEqualToString:@"threadList"]) {
                    [self populateThreadList:text];
                }
            });
        }];

    // Add a done button to dismiss keyboard
    UIBarButtonItem *doneBtn = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                                    target:self
                                                                    action:@selector(dismissKeyboard)];
    UIBarButtonItem *flexSpace = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
    UIToolbar *kbToolbar = [[UIToolbar alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 44)];
    kbToolbar.items = @[flexSpace, doneBtn];
    self.threadField.inputAccessoryView = kbToolbar;
    for (MIMessageRow *row in _messageRows) {
        row.textField.inputAccessoryView = kbToolbar;
        row.minAgoField.inputAccessoryView = kbToolbar;
    }
}

// --- Message row management ---
- (void)addMessageRow {
    MIMessageRow *row = [[MIMessageRow alloc] init];
    __weak typeof(self) weakSelf = self;
    row.onDelete = ^(MIMessageRow *r) {
        [weakSelf removeMessageRow:r];
    };
    [_messageRows addObject:row];
    [_messageStack addArrangedSubview:row];

    // Wire keyboard toolbar
    UIToolbar *kbToolbar = (UIToolbar *)self.threadField.inputAccessoryView;
    row.textField.inputAccessoryView = kbToolbar;
    row.minAgoField.inputAccessoryView = kbToolbar;
}

- (void)removeMessageRow:(MIMessageRow *)row {
    [_messageStack removeArrangedSubview:row];
    [row removeFromSuperview];
    [_messageRows removeObject:row];
    if (_messageRows.count == 0) [self addMessageRow];
}

- (void)addRowTapped {
    [self addMessageRow];
    [self flash:[NSString stringWithFormat:@"Row %d added", (int)_messageRows.count] red:NO];
}

- (void)injectTapped {
    [self.view endEditing:YES];
    NSString *tid = self.threadField.text ?: @"";
    if (tid.length == 0) { [self flash:@"Enter thread ID" red:YES]; return; }

    NSMutableArray *messages = [NSMutableArray array];
    for (int i = 0; i < (int)_messageRows.count; i++) {
        MIMessageRow *row = _messageRows[i];
        NSString *text = row.textField.text ?: @"";
        if (text.length == 0) continue;
        NSString *side = row.isMe ? @"me" : @"them";
        NSString *minAgoStr = row.minAgoField.text ?: @"";
        int minAgo = minAgoStr.length > 0 ? [minAgoStr intValue] : (int)(_messageRows.count - i);
        if (minAgo < 0) minAgo = 0;
        [messages addObject:@{@"s": side, @"t": text, @"m": @(minAgo)}];
    }

    if (messages.count == 0) { [self flash:@"No messages to inject" red:YES]; return; }

    self.resultsView.text = [NSString stringWithFormat:@"Injecting %d messages...", (int)messages.count];
    _injectPending = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(45 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (weakSelf && weakSelf->_injectPending) {
            weakSelf->_injectPending = NO;
            [weakSelf flash:@"⚠️ No response after 45s. Is Messenger OPEN with the dylib injected?" red:YES];
        }
    });
    [[NSDistributedNotificationCenter defaultCenter]
        postNotificationName:kNotifyInject
                      object:nil
                    userInfo:@{@"threadId": tid, @"messages": messages}
            deliverImmediately:YES];
    [self flash:[NSString stringWithFormat:@"\U0001F851 inject %d msgs → %@", (int)messages.count, tid] red:NO];
}

// --- Helpers ---
- (UILabel *)sec:(NSString *)t {
    UILabel *l = [[UILabel alloc] init];
    l.text = t;
    l.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    l.textColor = [UIColor tertiaryLabelColor];
    return l;
}

- (UITextField *)makeField:(NSString *)ph UIKeyboardType:(UIKeyboardType)kt {
    UITextField *f = [[UITextField alloc] init];
    f.placeholder = ph;
    f.borderStyle = UITextBorderStyleRoundedRect;
    f.font = [UIFont systemFontOfSize:14];
    f.keyboardType = kt;
    f.autocorrectionType = UITextAutocorrectionTypeNo;
    f.translatesAutoresizingMaskIntoConstraints = NO;
    f.delegate = self;
    return f;
}

- (UIButton *)makeBtn:(NSString *)t bg:(UIColor *)bg act:(SEL)act h:(CGFloat)h {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:t forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    b.backgroundColor = bg;
    [b setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
    b.layer.cornerRadius = 8;
    b.translatesAutoresizingMaskIntoConstraints = NO;
    [b.heightAnchor constraintEqualToConstant:h].active = YES;
    [b addTarget:self action:act forControlEvents:UIControlEventTouchUpInside];
    return b;
}

// --- Debug Actions ---
- (void)findDBTapped {
    [self.view endEditing:YES];
    self.resultsView.text = @"Searching for database...";
    [[NSDistributedNotificationCenter defaultCenter]
        postNotificationName:kNotifyFindDB object:nil userInfo:@{} deliverImmediately:YES];
    [self flash:@"\U0001F851 findDB" red:NO];
}

- (void)dumpSchemaTapped {
    [self.view endEditing:YES];
    self.resultsView.text = @"Dumping schema... (may take a few seconds)";
    [[NSDistributedNotificationCenter defaultCenter]
        postNotificationName:kNotifySchema object:nil userInfo:@{} deliverImmediately:YES];
    [self flash:@"\U0001F851 dumpSchema" red:NO];
}

- (void)dumpSampleTapped {
    [self.view endEditing:YES];
    self.resultsView.text = @"Dumping sample data...";
    [[NSDistributedNotificationCenter defaultCenter]
        postNotificationName:kNotifySample object:nil userInfo:@{} deliverImmediately:YES];
    [self flash:@"\U0001F851 dumpSample" red:NO];
}

- (void)populateThreadList:(NSString *)jsonStr {
    // Clear old buttons
    for (UIView *v in self.threadListStack.arrangedSubviews) {
        [self.threadListStack removeArrangedSubview:v];
        [v removeFromSuperview];
    }
    [self.threadButtons removeAllObjects];
    
    NSData *jsonData = [jsonStr dataUsingEncoding:NSUTF8StringEncoding];
    NSArray *threads = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:nil];
    if (![threads isKindOfClass:[NSArray class]] || threads.count == 0) {
        self.resultsView.text = @"No threads found.";
        return;
    }
    
    self.resultsView.text = [NSString stringWithFormat:@"Found %d threads. Tap one to select.", (int)threads.count];
    
    for (NSDictionary *t in threads) {
        NSString *threadKey = t[@"k"] ?: @"";
        NSString *name = t[@"n"] ?: @"";
        NSString *preview = t[@"p"] ?: @"";
        NSNumber *ts = t[@"t"];
        
        // Format timestamp
        NSString *timeStr = @"";
        if (ts && ts.longLongValue > 0) {
            NSDate *date = [NSDate dateWithTimeIntervalSince1970:ts.longLongValue / 1000.0];
            NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
            fmt.dateFormat = @"MM/dd HH:mm";
            timeStr = [fmt stringFromDate:date];
        }
        
        // Button title: name (or thread_key) + preview
        NSString *title;
        if (name.length > 0) {
            title = [NSString stringWithFormat:@"%@  [%@]\n%@", name, timeStr, preview];
        } else {
            title = [NSString stringWithFormat:@"%@  [%@]\n%@", threadKey, timeStr, preview];
        }
        
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
        [btn setTitle:title forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont systemFontOfSize:12];
        btn.titleLabel.numberOfLines = 2;
        btn.titleLabel.textAlignment = NSTextAlignmentLeft;
        btn.backgroundColor = [UIColor secondarySystemBackgroundColor];
        [btn setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
        btn.layer.cornerRadius = 6;
        btn.translatesAutoresizingMaskIntoConstraints = NO;
        [btn.heightAnchor constraintEqualToConstant:50].active = YES;
        btn.contentEdgeInsets = UIEdgeInsetsMake(4, 8, 4, 8);
        btn.tag = (int)self.threadButtons.count;
        [btn addTarget:self action:@selector(threadSelected:) forControlEvents:UIControlEventTouchUpInside];
        // Store thread key in accessibility label
        btn.accessibilityLabel = threadKey;
        
        [self.threadButtons addObject:btn];
        [self.threadListStack addArrangedSubview:btn];
    }
}

- (void)threadSelected:(UIButton *)btn {
    NSString *threadKey = btn.accessibilityLabel ?: @"";
    self.threadField.text = threadKey;
    [self flash:[NSString stringWithFormat:@"Selected: %@", threadKey] red:NO];
}

- (void)threadsTapped {
    [self.view endEditing:YES];
    self.resultsView.text = @"Scanning threads...";
    // Clear old thread buttons
    for (UIView *v in self.threadListStack.arrangedSubviews) {
        [self.threadListStack removeArrangedSubview:v];
        [v removeFromSuperview];
    }
    [self.threadButtons removeAllObjects];
    [[NSDistributedNotificationCenter defaultCenter]
        postNotificationName:kNotifyThreads object:nil userInfo:@{} deliverImmediately:YES];
    [self flash:@"\U0001F851 scan threads" red:NO];
}

- (void)crashTapped {
    [self.view endEditing:YES];
    self.resultsView.text = @"Fetching crash log...";
    [[NSDistributedNotificationCenter defaultCenter]
        postNotificationName:kNotifyCrash object:nil userInfo:@{} deliverImmediately:YES];
    [self flash:@"\U0001F851 crashLog" red:NO];
}

- (void)listFilesTapped {
    [self.view endEditing:YES];
    self.resultsView.text = @"Listing files...";
    [[NSDistributedNotificationCenter defaultCenter]
        postNotificationName:@"com.messenger.injector.listFiles" object:nil userInfo:@{} deliverImmediately:YES];
    [self flash:@"\U0001F851 listFiles" red:NO];
}

- (void)dumpViewTapped {
    [self.view endEditing:YES];
    self.resultsView.text = @"Dumping view hierarchy...";
    [[NSDistributedNotificationCenter defaultCenter]
        postNotificationName:kNotifyDump object:nil userInfo:@{} deliverImmediately:YES];
    [self flash:@"\U0001F851 dumpView" red:NO];
}

- (void)copyTapped {
    if (_resultText.length == 0) { [self flash:@"Nothing to copy" red:YES]; return; }
    [UIPasteboard generalPasteboard].string = _resultText;
    [self flash:@"\u2705 Copied" red:NO];
}

- (void)dismissKeyboard {
    [self.view endEditing:YES];
}

- (void)flash:(NSString *)msg red:(BOOL)red {
    self.statusLabel.text = msg;
    self.statusLabel.textColor = red ? [UIColor systemRedColor] : [UIColor systemGreenColor];
}

- (BOOL)textFieldShouldReturn:(UITextField *)tf {
    [tf resignFirstResponder];
    return YES;
}

@end

// ============================================================
// App delegate
// ============================================================
@interface MIHelperAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation MIHelperAppDelegate

- (BOOL)application:(UIApplication *)app
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    MIHelperVC *vc = [[MIHelperVC alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.navigationBar.prefersLargeTitles = YES;
    self.window.rootViewController = nav;
    [self.window makeKeyAndVisible];
    return YES;
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil,
                                 NSStringFromClass([MIHelperAppDelegate class]));
    }
}
