/**
 * MIHelper v2.1 — Trigger app for MessengerInjector
 *
 * User-friendly flow:
 *   1. Pick a chat (scan → tap)
 *   2. Compose messages (Me/Them rows)
 *   3. Inject → plain-English result banner
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

static NSString *const kNotifyReady   = @"com.messenger.injector.ready";
static NSString *const kNotifyResult  = @"com.messenger.injector.result";
static NSString *const kNotifyFindDB  = @"com.messenger.injector.findDB";
static NSString *const kNotifySchema  = @"com.messenger.injector.dumpSchema";
static NSString *const kNotifySample  = @"com.messenger.injector.dumpSample";
static NSString *const kNotifyThreads = @"com.messenger.injector.threadList";
static NSString *const kNotifyInject  = @"com.messenger.injector.inject";
static NSString *const kNotifyCrash   = @"com.messenger.injector.crashLog";
static NSString *const kNotifyListFiles = @"com.messenger.injector.listFiles";
static NSString *const kNotifyDumpView  = @"com.messenger.injector.dump";

// ============================================================
// Message row view (one composer row)
// ============================================================
@interface MIMessageRow : UIView
@property (nonatomic, assign) BOOL isMe;
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
    BOOL _dylibReady;
    BOOL _threadSelected;
    NSString *_selectedThreadName;
    NSString *_selectedThreadID;
}
@property (nonatomic, strong) UILabel *statusLabel;      // colored state line
@property (nonatomic, strong) UILabel *guideLabel;       // "what to do next" line
@property (nonatomic, strong) UILabel *selectedChatLabel;
@property (nonatomic, strong) UIButton *scanBtn;
@property (nonatomic, strong) UIStackView *threadListStack;
@property (nonatomic, strong) NSMutableArray<UIButton *> *threadButtons;
@property (nonatomic, strong) UITextField *threadField;
@property (nonatomic, strong) UIView *groupRow;
@property (nonatomic, strong) UISwitch *groupSwitch;
@property (nonatomic, strong) UIStackView *messageStack;
@property (nonatomic, strong) NSMutableArray<MIMessageRow *> *messageRows;
@property (nonatomic, strong) UIButton *injectBtn;
@property (nonatomic, strong) UILabel *resultBanner;
@property (nonatomic, strong) UITextView *resultsView;
@property (nonatomic, strong) UIButton *detailsToggleBtn;
@property (nonatomic, strong) UIView *advancedSection;
@property (nonatomic, strong) UIButton *advancedToggleBtn;
@end

@implementation MIHelperVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.title = @"MI Helper";
    _resultText = @"";
    _dylibReady = NO;
    _threadSelected = NO;
    _selectedThreadName = @"";
    _messageRows = [NSMutableArray array];
    _threadButtons = [NSMutableArray array];

    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.showsVerticalScrollIndicator = YES;
    scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    [self.view addSubview:scroll];

    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 10;
    stack.translatesAutoresizingMaskIntoConstraints = NO;

    // ---- Status banner (state + next step) ----
    UIView *statusCard = [[UIView alloc] init];
    statusCard.translatesAutoresizingMaskIntoConstraints = NO;
    statusCard.backgroundColor = [UIColor systemOrangeColor];
    statusCard.layer.cornerRadius = 10;

    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    self.statusLabel.textColor = [UIColor whiteColor];
    self.statusLabel.numberOfLines = 0;
    self.statusLabel.text = @"Waiting for dylib...";
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;

    self.guideLabel = [[UILabel alloc] init];
    self.guideLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
    self.guideLabel.textColor = [UIColor whiteColor];
    self.guideLabel.numberOfLines = 0;
    self.guideLabel.alpha = 0.9;
    self.guideLabel.text = @"Inject the dylib in TrollFools, open Messenger once, then come back.";
    self.guideLabel.translatesAutoresizingMaskIntoConstraints = NO;

    [statusCard addSubview:self.statusLabel];
    [statusCard addSubview:self.guideLabel];
    [NSLayoutConstraint activateConstraints:@[
        [self.statusLabel.topAnchor constraintEqualToAnchor:statusCard.topAnchor constant:10],
        [self.statusLabel.leadingAnchor constraintEqualToAnchor:statusCard.leadingAnchor constant:12],
        [self.statusLabel.trailingAnchor constraintEqualToAnchor:statusCard.trailingAnchor constant:-12],
        [self.guideLabel.topAnchor constraintEqualToAnchor:self.statusLabel.bottomAnchor constant:4],
        [self.guideLabel.leadingAnchor constraintEqualToAnchor:self.statusLabel.leadingAnchor],
        [self.guideLabel.trailingAnchor constraintEqualToAnchor:self.statusLabel.trailingAnchor],
        [self.guideLabel.bottomAnchor constraintEqualToAnchor:statusCard.bottomAnchor constant:-10],
    ]];

    // ---- STEP 1: pick chat ----
    UILabel *step1 = [self sec:@"1. PICK A CHAT"];

    self.scanBtn = [self makeBtn:@"\U0001F4CB  Scan my chats" bg:[UIColor systemTealColor] act:@selector(threadsTapped) h:48];
    [self.scanBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];

    self.selectedChatLabel = [[UILabel alloc] init];
    self.selectedChatLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    self.selectedChatLabel.textColor = [UIColor systemGreenColor];
    self.selectedChatLabel.numberOfLines = 0;
    self.selectedChatLabel.text = @"No chat selected yet";

    self.threadListStack = [[UIStackView alloc] init];
    self.threadListStack.axis = UILayoutConstraintAxisVertical;
    self.threadListStack.spacing = 6;
    self.threadListStack.translatesAutoresizingMaskIntoConstraints = NO;

    // ---- STEP 2: compose ----
    UILabel *step2 = [self sec:@"2. WRITE MESSAGES (Me = you, Them = other person)"];

    self.messageStack = [[UIStackView alloc] init];
    self.messageStack.axis = UILayoutConstraintAxisVertical;
    self.messageStack.spacing = 8;
    self.messageStack.translatesAutoresizingMaskIntoConstraints = NO;

    [self addMessageRow:YES];   // first row: Me
    [self addMessageRow:NO];   // second row: Them

    UIButton *addBtn = [self makeBtn:@"+ Add message" bg:[UIColor systemGray3Color] act:@selector(addRowTapped) h:36];

    // group switch row
    self.groupRow = [[UIView alloc] init];
    self.groupRow.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel *gL = [[UILabel alloc] init];
    gL.text = @"Group chat (only for 3+ person chats)";
    gL.font = [UIFont systemFontOfSize:13];
    gL.textColor = [UIColor secondaryLabelColor];
    gL.translatesAutoresizingMaskIntoConstraints = NO;
    self.groupSwitch = [[UISwitch alloc] init];
    self.groupSwitch.translatesAutoresizingMaskIntoConstraints = NO;
    [self.groupRow addSubview:gL];
    [self.groupRow addSubview:self.groupSwitch];
    [NSLayoutConstraint activateConstraints:@[
        [gL.leadingAnchor constraintEqualToAnchor:self.groupRow.leadingAnchor],
        [gL.centerYAnchor constraintEqualToAnchor:self.groupRow.centerYAnchor],
        [self.groupSwitch.trailingAnchor constraintEqualToAnchor:self.groupRow.trailingAnchor],
        [self.groupSwitch.centerYAnchor constraintEqualToAnchor:self.groupRow.centerYAnchor],
        [self.groupRow.heightAnchor constraintEqualToConstant:30],
    ]];

    // ---- STEP 3: inject ----
    UILabel *step3 = [self sec:@"3. INJECT"];
    self.injectBtn = [self makeBtn:@"\U0001F680  Inject into Messenger" bg:[UIColor systemBlueColor] act:@selector(injectTapped) h:54];
    [self.injectBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.injectBtn.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightBold];

    // ---- Result banner ----
    self.resultBanner = [[UILabel alloc] init];
    self.resultBanner.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    self.resultBanner.numberOfLines = 0;
    self.resultBanner.textAlignment = NSTextAlignmentCenter;
    self.resultBanner.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.resultBanner.layer.cornerRadius = 10;
    self.resultBanner.layer.borderColor = [UIColor systemGray4Color].CGColor;
    self.resultBanner.layer.borderWidth = 1;

    // ---- Details (raw log) ----
    self.detailsToggleBtn = [self makeBtn:@"Show full log" bg:[UIColor systemGray3Color] act:@selector(toggleDetailsTapped) h:32];
    self.detailsToggleBtn.titleLabel.font = [UIFont systemFontOfSize:13];

    self.resultsView = [[UITextView alloc] init];
    self.resultsView.editable = NO;
    self.resultsView.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
    self.resultsView.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.resultsView.layer.cornerRadius = 8;
    self.resultsView.text = @"Full log appears here.";
    self.resultsView.translatesAutoresizingMaskIntoConstraints = NO;
    self.resultsView.hidden = YES;
    [self.resultsView.heightAnchor constraintEqualToConstant:220].active = YES;

    UIButton *copyBtn = [self makeBtn:@"Copy full log" bg:[UIColor systemGray4Color] act:@selector(copyTapped) h:32];
    copyBtn.titleLabel.font = [UIFont systemFontOfSize:13];

    // ---- Advanced (collapsed) ----
    self.advancedToggleBtn = [self makeBtn:@"\u2699\uFE0F  Advanced tools (debug)" bg:[UIColor tertiarySystemFillColor] act:@selector(toggleAdvancedTapped) h:36];
    self.advancedToggleBtn.titleLabel.font = [UIFont systemFontOfSize:13];

    self.advancedSection = [[UIStackView alloc] init];
    self.advancedSection.axis = UILayoutConstraintAxisVertical;
    self.advancedSection.spacing = 8;
    self.advancedSection.translatesAutoresizingMaskIntoConstraints = NO;
    self.advancedSection.hidden = YES;

    UILabel *advNote = [[UILabel alloc] init];
    advNote.text = @"For debugging only. Normal use needs nothing down here.";
    advNote.font = [UIFont systemFontOfSize:11];
    advNote.textColor = [UIColor tertiaryLabelColor];
    advNote.numberOfLines = 0;

    self.threadField = [self makeField:@"Manual thread ID (if scan can't find it)" UIKeyboardType:UIKeyboardDefault];

    UIButton *findDBBtn   = [self makeBtn:@"Find database file"       bg:[UIColor systemGray3Color] act:@selector(findDBTapped)   h:36];
    UIButton *schemaBtn   = [self makeBtn:@"Dump DB schema"           bg:[UIColor systemOrangeColor] act:@selector(dumpSchemaTapped) h:36];
    UIButton *sampleBtn   = [self makeBtn:@"Dump sample data"         bg:[UIColor systemOrangeColor] act:@selector(dumpSampleTapped) h:36];
    UIButton *crashBtn    = [self makeBtn:@"Get crash log"            bg:[UIColor systemRedColor] act:@selector(crashTapped) h:36];
    UIButton *listFilesBtn= [self makeBtn:@"List all files"           bg:[UIColor systemPurpleColor] act:@selector(listFilesTapped) h:36];
    UIButton *dumpViewBtn = [self makeBtn:@"Dump view hierarchy"      bg:[UIColor systemGray3Color] act:@selector(dumpViewTapped) h:36];
    [self.advancedSection addArrangedSubview:advNote];
    [self.advancedSection addArrangedSubview:self.threadField];
    [self.advancedSection addArrangedSubview:findDBBtn];
    [self.advancedSection addArrangedSubview:schemaBtn];
    [self.advancedSection addArrangedSubview:sampleBtn];
    [self.advancedSection addArrangedSubview:crashBtn];
    [self.advancedSection addArrangedSubview:listFilesBtn];
    [self.advancedSection addArrangedSubview:dumpViewBtn];

    // ---- Assemble ----
    [stack addArrangedSubview:statusCard];
    [stack addArrangedSubview:step1];
    [stack addArrangedSubview:self.scanBtn];
    [stack addArrangedSubview:self.selectedChatLabel];
    [stack addArrangedSubview:self.threadListStack];
    [stack addArrangedSubview:step2];
    [stack addArrangedSubview:self.messageStack];
    [stack addArrangedSubview:addBtn];
    [stack addArrangedSubview:self.groupRow];
    [stack addArrangedSubview:step3];
    [stack addArrangedSubview:self.injectBtn];
    [stack addArrangedSubview:self.resultBanner];
    [stack addArrangedSubview:self.detailsToggleBtn];
    [stack addArrangedSubview:copyBtn];
    [stack addArrangedSubview:self.resultsView];
    [stack addArrangedSubview:self.advancedToggleBtn];
    [stack addArrangedSubview:self.advancedSection];

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

    // Keyboard toolbar
    UIBarButtonItem *doneBtn = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                                    target:self
                                                                    action:@selector(dismissKeyboard)];
    UIBarButtonItem *flexSpace = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
    UIToolbar *kbToolbar = [[UIToolbar alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 44)];
    kbToolbar.items = @[flexSpace, doneBtn];
    self.threadField.inputAccessoryView = kbToolbar;

    // ---- Dylib ready ----
    [[NSDistributedNotificationCenter defaultCenter]
        addObserverForName:kNotifyReady
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
            dispatch_async(dispatch_get_main_queue(), ^{
                NSString *ver = note.userInfo[@"version"] ?: @"?";
                self->_dylibReady = YES;
                self.statusLabel.text = [NSString stringWithFormat:@"\U0001F7E2 Dylib v%@ is running", ver];
                [self setStatusColor:[UIColor systemGreenColor]];
                [self updateGuidance];
            });
        }];

    // ---- Results from dylib ----
    [[NSDistributedNotificationCenter defaultCenter]
        addObserverForName:kNotifyResult
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self handleResultWithTag:note.userInfo[@"tag"] ?: @"result"
                                    text:note.userInfo[@"text"] ?: @"(empty)"];
            });
        }];
}

// ============================================================
// Result handling + plain-English banner
// ============================================================
- (void)handleResultWithTag:(NSString *)tag text:(NSString *)text {
    _resultText = [NSString stringWithFormat:@"[%@]\n%@", tag, text];
    self.resultsView.text = _resultText;

    if ([tag isEqualToString:@"threadList"]) {
        [self populateThreadList:text];
        return;
    }

    if ([tag isEqualToString:@"inject"]) {
        // Parse machine line: @@MIRESULT|ok=1|inserted=2|...|@@
        NSRange r = [text rangeOfString:@"@@MIRESULT|"];
        if (r.location != NSNotFound) {
            NSRange end = [text rangeOfString:@"|@@" options:0 range:NSMakeRange(r.location, text.length - r.location)];
            if (end.location != NSNotFound) {
                NSString *line = [text substringWithRange:NSMakeRange(r.location + 11, end.location - r.location - 11)];
                [self showResultBanner:line];
                return;
            }
        }
        // No machine line — old dylib or failure path
        if ([text containsString:@"ERROR"]) {
            [self showBanner:@"\u274C Something went wrong. Tap 'Show full log' below to see details."
                         color:[UIColor systemRedColor] border:[UIColor systemRedColor]];
        } else if ([text hasPrefix:@"Exception"]) {
            [self showBanner:@"\u274C Crash inside Messenger. Tap 'Show full log'."
                         color:[UIColor systemRedColor] border:[UIColor systemRedColor]];
        } else {
            [self showBanner:@"\u26A0\uFE0F Got a result, but couldn't parse it. Tap 'Show full log'."
                         color:[UIColor systemOrangeColor] border:[UIColor systemOrangeColor]];
        }
    }
    // Other tags (findDB, schema...) just show the raw log
}

- (void)showResultBanner:(NSString *)line {
    // line = "ok=1|inserted=2|errors=0|thread_pk=...|method=...|name=...|thread_id=..."
    NSMutableDictionary *kv = [NSMutableDictionary dictionary];
    for (NSString *part in [line componentsSeparatedByString:@"|"]) {
        NSArray *kp = [part componentsSeparatedByString:@"="];
        if (kp.count == 2) kv[kp[0]] = kp[1];
    }
    BOOL ok = [kv[@"ok"] intValue] == 1;
    NSString *method = kv[@"method"] ?: @"?";
    NSString *name = kv[@"name"] ?: @"";
    NSString *inserted = kv[@"inserted"] ?: @"0";

    if (!ok) {
        [self showBanner:[NSString stringWithFormat:@"\u274C Inject failed (%@ errors). Tap 'Show full log'.", kv[@"errors"] ?: @"?"]
                         color:[UIColor systemRedColor] border:[UIColor systemRedColor]];
        return;
    }
    if ([method isEqualToString:@"LAST_RESORT_first_thread"]) {
        [self showBanner:[NSString stringWithFormat:@"\u26A0\uFE0F Wrote %@ messages, but the right chat was NOT found — they may land in the wrong chat. Tap 'Show full log' and send me the log.", inserted]
                         color:[UIColor systemOrangeColor] border:[UIColor systemOrangeColor]];
        return;
    }
    NSString *chatPart = @"";
    if (name.length > 0 && ![name isEqualToString:@"NULL"]) {
        chatPart = [NSString stringWithFormat:@" to \u201C%@\u201D", name];
    }
    [self showBanner:[NSString stringWithFormat:@"\u2705 %@ messages written%@.\nNow: force-quit Messenger (swipe it away in the app switcher), reopen it, and open the chat.", inserted, chatPart]
                     color:[UIColor systemGreenColor] border:[UIColor systemGreenColor]];
}

- (void)showBanner:(NSString *)text color:(UIColor *)bg border:(UIColor *)bd {
    self.resultBanner.text = text;
    self.resultBanner.textColor = [UIColor whiteColor];
    self.resultBanner.backgroundColor = bg;
    self.resultBanner.layer.borderColor = bd.CGColor;
}

- (void)setStatusColor:(UIColor *)c {
    self.statusLabel.superview.backgroundColor = c;
}

// ============================================================
// Guidance (what to do next)
// ============================================================
- (void)updateGuidance {
    if (!_dylibReady) {
        self.guideLabel.text = @"Step 1: In TrollFools, inject the dylib, then open Messenger once. This screen goes green when it's live.";
        return;
    }
    if (!_threadSelected) {
        self.guideLabel.text = @"Step 1: Tap \u201CScan my chats\u201D and pick the conversation you want to fake.";
    } else {
        self.guideLabel.text = @"Step 2: Type your messages, then tap Inject.";
    }
}

// ============================================================
// Composer
// ============================================================
- (void)addMessageRow:(BOOL)isMe {
    MIMessageRow *row = [[MIMessageRow alloc] init];
    row.isMe = isMe;
    row.sideControl.selectedSegmentIndex = isMe ? 0 : 1;
    __weak typeof(self) weakSelf = self;
    row.onDelete = ^(MIMessageRow *r) {
        [weakSelf removeMessageRow:r];
    };
    [_messageRows addObject:row];
    [_messageStack addArrangedSubview:row];

    UIToolbar *kbToolbar = (UIToolbar *)self.threadField.inputAccessoryView;
    row.textField.inputAccessoryView = kbToolbar;
    row.minAgoField.inputAccessoryView = kbToolbar;
}

- (void)removeMessageRow:(MIMessageRow *)row {
    [_messageStack removeArrangedSubview:row];
    [row removeFromSuperview];
    [_messageRows removeObject:row];
    if (_messageRows.count == 0) [self addMessageRow:YES];
}

- (void)addRowTapped {
    [self addMessageRow:YES];
}

- (void)injectTapped {
    [self.view endEditing:YES];

    // Thread ID: from picker (stored) or manual field
    NSString *tid = _selectedThreadID ?: (self.threadField.text ?: @"");
    tid = [tid stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (tid.length == 0) {
        [self setStatusText:@"Pick a chat first (Step 1)"];
        [self setGuideText:@"Tap \u201CScan my chats\u201D and pick one — or type an ID in Advanced tools."];
        return;
    }

    NSMutableArray *messages = [NSMutableArray array];
    for (int i = 0; i < (int)_messageRows.count; i++) {
        MIMessageRow *row = _messageRows[i];
        NSString *text = [row.textField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (text.length == 0) continue;
        NSString *side = row.isMe ? @"me" : @"them";
        NSString *minAgoStr = row.minAgoField.text ?: @"";
        int minAgo = minAgoStr.length > 0 ? [minAgoStr intValue] : (int)(_messageRows.count - i);
        if (minAgo < 0) minAgo = 0;
        [messages addObject:@{@"s": side, @"t": text, @"m": @(minAgo)}];
    }
    if (messages.count == 0) {
        [self setStatusText:@"Type at least one message (Step 2)"];
        [self setGuideText:@"Fill in a message box, then tap Inject."];
        return;
    }

    self.statusLabel.text = @"\u23F3 Injecting...";
    [self setStatusColor:[UIColor systemBlueColor]];
    self.guideLabel.text = @"Hang tight — this takes a few seconds.";
    self.resultBanner.text = @"";

    [[NSDistributedNotificationCenter defaultCenter]
        postNotificationName:kNotifyInject
                      object:nil
                    userInfo:@{@"threadId": tid, @"messages": messages}
            deliverImmediately:YES];
}

- (void)setStatusText:(NSString *)t { self.statusLabel.text = t; }
- (void)setGuideText:(NSString *)t { self.guideLabel.text = t; }

// ============================================================
// Thread picker
// ============================================================
- (void)threadsTapped {
    [self.view endEditing:YES];
    self.statusLabel.text = @"\U0001F50D Scanning chats...";
    [self setStatusColor:[UIColor systemTealColor]];
    for (UIView *v in self.threadListStack.arrangedSubviews) {
        [self.threadListStack removeArrangedSubview:v];
        [v removeFromSuperview];
    }
    [self.threadButtons removeAllObjects];
    [[NSDistributedNotificationCenter defaultCenter]
        postNotificationName:kNotifyThreads object:nil userInfo:@{} deliverImmediately:YES];
}

- (void)populateThreadList:(NSString *)jsonStr {
    for (UIView *v in self.threadListStack.arrangedSubviews) {
        [self.threadListStack removeArrangedSubview:v];
        [v removeFromSuperview];
    }
    [self.threadButtons removeAllObjects];

    NSData *jsonData = [jsonStr dataUsingEncoding:NSUTF8StringEncoding];
    NSArray *threads = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:nil];
    if (![threads isKindOfClass:[NSArray class]] || threads.count == 0) {
        [self setStatusText:@"No chats found — check the full log"];
        [self setGuideText:@"Open Messenger, load your chat list, then try scanning again."];
        return;
    }

    for (NSDictionary *t in threads) {
        NSString *threadKey = t[@"k"] ?: @"";
        NSString *name = t[@"n"] ?: @"";
        NSString *preview = t[@"p"] ?: @"";
        if (name.length == 0 || [name isEqualToString:@"NULL"]) name = threadKey;
        if (preview.length > 40) preview = [[preview substringToIndex:40] stringByAppendingString:@"..."];

        UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
        [btn setTitle:[NSString stringWithFormat:@"%@\n%@  ·  %@", name, preview.length > 0 ? preview : @"(no preview)", threadKey]
             forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont systemFontOfSize:13];
        btn.titleLabel.numberOfLines = 3;
        btn.titleLabel.textAlignment = NSTextAlignmentLeft;
        btn.backgroundColor = [UIColor secondarySystemBackgroundColor];
        [btn setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
        btn.layer.cornerRadius = 8;
        btn.translatesAutoresizingMaskIntoConstraints = NO;
        [btn.heightAnchor constraintEqualToConstant:58].active = YES;
        btn.contentEdgeInsets = UIEdgeInsetsMake(6, 10, 6, 10);
        btn.accessibilityLabel = threadKey;
        btn.accessibilityTraits = UIAccessibilityTraitButton;
        [btn addTarget:self action:@selector(threadSelected:) forControlEvents:UIControlEventTouchUpInside];
        [self.threadButtons addObject:btn];
        [self.threadListStack addArrangedSubview:btn];
    }

    [self setStatusText:[NSString stringWithFormat:@"\U0001F4E6 Found %d chats", (int)threads.count]];
    [self setGuideText:@"Tap the chat you want to fake messages in."];
}

- (void)threadSelected:(UIButton *)btn {
    NSString *threadKey = btn.accessibilityLabel ?: @"";
    for (UIButton *b in _threadButtons) {
        b.backgroundColor = [UIColor secondarySystemBackgroundColor];
        [b setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
    }
    btn.backgroundColor = [UIColor systemGreenColor];
    [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _selectedThreadID = threadKey;
    // find the name from button title (first line)
    NSString *full = [btn titleForState:UIControlStateNormal] ?: @"";
    _selectedThreadName = [[full componentsSeparatedByString:@"\n"] firstObject] ?: threadKey;
    _threadSelected = YES;
    self.selectedChatLabel.text = [NSString stringWithFormat:@"\u2705 Selected: %@  (%@)", _selectedThreadName, threadKey];
    [self updateGuidance];
}

// ============================================================
// Advanced / debug
// ============================================================
- (void)toggleAdvancedTapped {
    self.advancedSection.hidden = !self.advancedSection.hidden;
    [self.advancedToggleBtn setTitle:self.advancedSection.hidden ? @"\u2699\uFE0F  Advanced tools (debug)" : @"\u2716  Hide advanced tools"
                          forState:UIControlStateNormal];
}

- (void)toggleDetailsTapped {
    self.resultsView.hidden = !self.resultsView.hidden;
    [self.detailsToggleBtn setTitle:self.resultsView.hidden ? @"Show full log" : @"\u2716 Hide full log"
                          forState:UIControlStateNormal];
}

- (void)findDBTapped {
    [self.view endEditing:YES];
    self.resultsView.text = @"Searching for database...";
    self.resultsView.hidden = NO;
    [self.detailsToggleBtn setTitle:@"\u2716 Hide full log" forState:UIControlStateNormal];
    [[NSDistributedNotificationCenter defaultCenter] postNotificationName:kNotifyFindDB object:nil userInfo:@{} deliverImmediately:YES];
}

- (void)dumpSchemaTapped {
    [self.view endEditing:YES];
    self.resultsView.text = @"Dumping schema... (a few seconds)";
    self.resultsView.hidden = NO;
    [self.detailsToggleBtn setTitle:@"\u2716 Hide full log" forState:UIControlStateNormal];
    [[NSDistributedNotificationCenter defaultCenter] postNotificationName:kNotifySchema object:nil userInfo:@{} deliverImmediately:YES];
}

- (void)dumpSampleTapped {
    [self.view endEditing:YES];
    self.resultsView.text = @"Dumping sample data...";
    self.resultsView.hidden = NO;
    [self.detailsToggleBtn setTitle:@"\u2716 Hide full log" forState:UIControlStateNormal];
    [[NSDistributedNotificationCenter defaultCenter] postNotificationName:kNotifySample object:nil userInfo:@{} deliverImmediately:YES];
}

- (void)crashTapped {
    [self.view endEditing:YES];
    self.resultsView.text = @"Fetching crash log...";
    self.resultsView.hidden = NO;
    [self.detailsToggleBtn setTitle:@"\u2716 Hide full log" forState:UIControlStateNormal];
    [[NSDistributedNotificationCenter defaultCenter] postNotificationName:kNotifyCrash object:nil userInfo:@{} deliverImmediately:YES];
}

- (void)listFilesTapped {
    [self.view endEditing:YES];
    self.resultsView.text = @"Listing files...";
    self.resultsView.hidden = NO;
    [self.detailsToggleBtn setTitle:@"\u2716 Hide full log" forState:UIControlStateNormal];
    [[NSDistributedNotificationCenter defaultCenter] postNotificationName:kNotifyListFiles object:nil userInfo:@{} deliverImmediately:YES];
}

- (void)dumpViewTapped {
    [self.view endEditing:YES];
    self.resultsView.text = @"Dumping view hierarchy...";
    self.resultsView.hidden = NO;
    [self.detailsToggleBtn setTitle:@"\u2716 Hide full log" forState:UIControlStateNormal];
    [[NSDistributedNotificationCenter defaultCenter] postNotificationName:kNotifyDumpView object:nil userInfo:@{} deliverImmediately:YES];
}

- (void)copyTapped {
    if (_resultText.length == 0) return;
    [UIPasteboard generalPasteboard].string = _resultText;
    [self setStatusText:@"\u2705 Copied to clipboard"];
    [self setStatusColor:[UIColor systemGreenColor]];
    [self updateGuidance];
}

// ============================================================
// UI helpers
// ============================================================
- (UILabel *)sec:(NSString *)t {
    UILabel *l = [[UILabel alloc] init];
    l.text = t;
    l.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    l.textColor = [UIColor secondaryLabelColor];
    return l;
}

- (UITextField *)makeField:(NSString *)ph UIKeyboardType:(UIKeyboardType)kt {
    UITextField *f = [[UITextField alloc] init];
    f.placeholder = ph;
    f.borderStyle = UITextBorderStyleRoundedRect;
    f.font = [UIFont systemFontOfSize:13];
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

- (void)dismissKeyboard {
    [self.view endEditing:YES];
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
