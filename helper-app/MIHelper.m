/**
 * MIHelper v3.0 — intuitive 3-step UX for MessengerInjector
 *
 *   STEP 1: Pick a chat   (tap card → scan → tap a chat)
 *   STEP 2: Write messages (Me/Them rows + LIVE bubble preview)
 *   STEP 3: Inject         (big button → plain-English result)
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
static NSString *const kNotifyResearch = @"com.messenger.injector.research";
static NSString *const kNotifyInject  = @"com.messenger.injector.inject";
static NSString *const kNotifyCrash   = @"com.messenger.injector.crashLog";
static NSString *const kNotifyListFiles = @"com.messenger.injector.listFiles";
static NSString *const kNotifyDumpView  = @"com.messenger.injector.dump";

// ============================================================
// One message row: [Me|Them] [text] [min ago] [delete]
// ============================================================
@interface MIMessageRow : UIView
@property (nonatomic, assign) BOOL isMe;
@property (nonatomic, strong) UISegmentedControl *sideControl;
@property (nonatomic, strong) UITextField *textField;
@property (nonatomic, strong) UITextField *minAgoField;
@property (nonatomic, copy) void (^onChanged)(void);
@property (nonatomic, copy) void (^onDelete)(MIMessageRow *row);
@end

@implementation MIMessageRow

- (instancetype)init {
    self = [super init];
    if (self) {
        self.translatesAutoresizingMaskIntoConstraints = NO;
        self.backgroundColor = [UIColor secondarySystemBackgroundColor];
        self.layer.cornerRadius = 10;
        _isMe = YES;

        _sideControl = [[UISegmentedControl alloc] initWithItems:@[@"\U0001F9D1 Me", @"\U0001F9D1\u200d Th"]];
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
        __weak typeof(self) weakSelf = self;
        [_textField addTarget:self action:@selector(textChanged) forControlEvents:UIControlEventEditingChanged];

        _minAgoField = [[UITextField alloc] init];
        _minAgoField.translatesAutoresizingMaskIntoConstraints = NO;
        _minAgoField.placeholder = @"min";
        _minAgoField.borderStyle = UITextBorderStyleRoundedRect;
        _minAgoField.font = [UIFont systemFontOfSize:12];
        _minAgoField.keyboardType = UIKeyboardTypeNumberPad;
        _minAgoField.textAlignment = NSTextAlignmentCenter;
        [_minAgoField.widthAnchor constraintEqualToConstant:52].active = YES;

        UIButton *del = [UIButton buttonWithType:UIButtonTypeSystem];
        del.translatesAutoresizingMaskIntoConstraints = NO;
        [del setTitle:@"\U0001F5D1" forState:UIControlStateNormal];
        del.titleLabel.font = [UIFont systemFontOfSize:16];
        [del addTarget:self action:@selector(deleteTapped) forControlEvents:UIControlEventTouchUpInside];
        [del.widthAnchor constraintEqualToConstant:34].active = YES;

        [self addSubview:_sideControl];
        [self addSubview:_minAgoField];
        [self addSubview:del];
        [self addSubview:_textField];
        [NSLayoutConstraint activateConstraints:@[
            [_sideControl.topAnchor constraintEqualToAnchor:self.topAnchor constant:6],
            [_sideControl.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:8],
            [_sideControl.widthAnchor constraintEqualToConstant:110],
            [_sideControl.heightAnchor constraintEqualToConstant:26],

            [_minAgoField.centerYAnchor constraintEqualToAnchor:_sideControl.centerYAnchor],
            [_minAgoField.leadingAnchor constraintEqualToAnchor:_sideControl.trailingAnchor constant:8],

            [del.centerYAnchor constraintEqualToAnchor:_sideControl.centerYAnchor],
            [del.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-8],

            [_textField.topAnchor constraintEqualToAnchor:_sideControl.bottomAnchor constant:6],
            [_textField.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:8],
            [_textField.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-8],
            [_textField.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-6],
            [_textField.heightAnchor constraintEqualToConstant:34],
        ]];
    }
    return self;
}

- (void)sideChanged:(UISegmentedControl *)c { _isMe = (c.selectedSegmentIndex == 0); if (_onChanged) _onChanged(); }
- (void)textChanged { if (_onChanged) _onChanged(); }
- (void)deleteTapped { if (_onDelete) _onDelete(self); }

@end

// ============================================================
// View controller
// ============================================================
@interface MIHelperVC : UIViewController <UITextFieldDelegate>
{
    NSString *_resultText;
    BOOL _dylibReady;
    NSString *_selThreadID;
    NSString *_selThreadName;
    BOOL _injectPending;
}
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIView *chatCard;
@property (nonatomic, strong) UILabel *chatCardTitle;
@property (nonatomic, strong) UILabel *chatCardSub;
@property (nonatomic, strong) UIStackView *threadListStack;
@property (nonatomic, strong) NSMutableArray<UIButton *> *threadButtons;
@property (nonatomic, strong) UIStackView *messageStack;
@property (nonatomic, strong) NSMutableArray<MIMessageRow *> *messageRows;
@property (nonatomic, strong) UITextView *previewView;
@property (nonatomic, strong) UIButton *injectBtn;
@property (nonatomic, strong) UIView *resultCard;
@property (nonatomic, strong) UITextView *resultLabel;
@property (nonatomic, strong) UIButton *outputCopyBtn;
@property (nonatomic, strong) UIStackView *debugStack;
@property (nonatomic, strong) UIButton *debugToggleBtn;
@property (nonatomic, strong) UIToolbar *kbToolbar;
@property (nonatomic, strong) UIButton *hideKbFloatBtn;
@property (nonatomic, strong) UITextField *manualTidField;
@end

@implementation MIHelperVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.title = @"Fake Chat";
    _resultText = @"";
    _dylibReady = NO;

    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.showsVerticalScrollIndicator = YES;
    scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    [self.view addSubview:scroll];

    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 14;
    stack.translatesAutoresizingMaskIntoConstraints = NO;

    // ---------- Status strip ----------
    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    self.statusLabel.textColor = [UIColor whiteColor];
    self.statusLabel.backgroundColor = [UIColor systemOrangeColor];
    self.statusLabel.layer.cornerRadius = 8;
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.text = @"Waiting for dylib — open Messenger once after injecting it";
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.statusLabel.heightAnchor constraintEqualToConstant:34].active = YES;

    // ---------- STEP 1: chat card ----------
    self.chatCard = [[UIView alloc] init];
    self.chatCard.translatesAutoresizingMaskIntoConstraints = NO;
    self.chatCard.backgroundColor = [UIColor systemBackgroundColor];
    self.chatCard.layer.cornerRadius = 12;
    self.chatCard.userInteractionEnabled = YES;
    [self.chatCard addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(chatCardTapped)]];

    self.chatCardTitle = [[UILabel alloc] init];
    self.chatCardTitle.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    self.chatCardTitle.text = @"1.  Pick a chat";
    self.chatCardTitle.translatesAutoresizingMaskIntoConstraints = NO;

    self.chatCardSub = [[UILabel alloc] init];
    self.chatCardSub.font = [UIFont systemFontOfSize:14];
    self.chatCardSub.textColor = [UIColor secondaryLabelColor];
    self.chatCardSub.text = @"Tap here to scan your Messenger chats";
    self.chatCardSub.numberOfLines = 0;
    self.chatCardSub.translatesAutoresizingMaskIntoConstraints = NO;

    [self.chatCard addSubview:self.chatCardTitle];
    [self.chatCard addSubview:self.chatCardSub];
    [NSLayoutConstraint activateConstraints:@[
        [self.chatCardTitle.topAnchor constraintEqualToAnchor:self.chatCard.topAnchor constant:14],
        [self.chatCardTitle.leadingAnchor constraintEqualToAnchor:self.chatCard.leadingAnchor constant:14],
        [self.chatCardTitle.trailingAnchor constraintEqualToAnchor:self.chatCard.trailingAnchor constant:-14],
        [self.chatCardSub.topAnchor constraintEqualToAnchor:self.chatCardTitle.bottomAnchor constant:6],
        [self.chatCardSub.leadingAnchor constraintEqualToAnchor:self.chatCardTitle.leadingAnchor],
        [self.chatCardSub.trailingAnchor constraintEqualToAnchor:self.chatCardTitle.trailingAnchor],
        [self.chatCardSub.bottomAnchor constraintEqualToAnchor:self.chatCard.bottomAnchor constant:-14],
    ]];

    self.threadListStack = [[UIStackView alloc] init];
    self.threadListStack.axis = UILayoutConstraintAxisVertical;
    self.threadListStack.spacing = 6;
    self.threadListStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.threadListStack.hidden = YES;
    self.threadButtons = [NSMutableArray array];

    // ---------- STEP 2: messages ----------
    UILabel *s2 = [self stepLabel:@"2.  Write the conversation"];
    self.messageStack = [[UIStackView alloc] init];
    self.messageStack.axis = UILayoutConstraintAxisVertical;
    self.messageStack.spacing = 8;
    self.messageStack.translatesAutoresizingMaskIntoConstraints = NO;

    self.messageRows = [NSMutableArray array];
    [self addMessageRow:YES];
    [self addMessageRow:NO];

    UIButton *addBtn = [self makeBtn:@"+  Add message" bg:[UIColor secondarySystemBackgroundColor] act:@selector(addRowTapped) h:40];
    [addBtn setTitleColor:[UIColor systemBlueColor] forState:UIControlStateNormal];

    // preview
    UILabel *prevLabel = [[UILabel alloc] init];
    prevLabel.text = @"How it will look:";
    prevLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    prevLabel.textColor = [UIColor tertiaryLabelColor];

    self.previewView = [[UITextView alloc] init];
    self.previewView.editable = NO;
    self.previewView.selectable = NO;
    self.previewView.font = [UIFont systemFontOfSize:13];
    self.previewView.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.previewView.layer.cornerRadius = 10;
    self.previewView.text = @"(empty)";
    self.previewView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.previewView.heightAnchor constraintEqualToConstant:110].active = YES;

    // ---------- STEP 3: inject ----------
    UILabel *s3 = [self stepLabel:@"3.  Inject"];
    self.injectBtn = [self makeBtn:@"\U0001F680  Inject into Messenger" bg:[UIColor systemBlueColor] act:@selector(injectTapped) h:56];
    [self.injectBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.injectBtn.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightBold];

    // ---------- Result card ----------
    self.resultCard = [[UIView alloc] init];
    self.resultCard.translatesAutoresizingMaskIntoConstraints = NO;
    self.resultCard.backgroundColor = [UIColor systemBackgroundColor];
    self.resultCard.layer.cornerRadius = 12;
    self.resultCard.hidden = YES;
    self.resultLabel = [[UITextView alloc] init];
    self.resultLabel.font = [UIFont systemFontOfSize:12];
    self.resultLabel.editable = NO;
    self.resultLabel.selectable = YES;
    self.resultLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.resultLabel.backgroundColor = [UIColor clearColor];
    self.resultLabel.textContainerInset = UIEdgeInsetsMake(8, 4, 8, 4);
    self.resultLabel.scrollEnabled = YES;
    [self.resultLabel.heightAnchor constraintLessThanOrEqualToConstant:300].active = YES;
    self.outputCopyBtn = [self makeBtn:@"\U0001F4CB  Copy output" bg:[UIColor systemGreenColor] act:@selector(copyTapped) h:36];
    [self.outputCopyBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [self.resultCard addSubview:self.resultLabel];
    [self.resultCard addSubview:self.outputCopyBtn];
    [NSLayoutConstraint activateConstraints:@[
        [self.resultLabel.topAnchor constraintEqualToAnchor:self.resultCard.topAnchor constant:10],
        [self.resultLabel.leadingAnchor constraintEqualToAnchor:self.resultCard.leadingAnchor constant:10],
        [self.resultLabel.trailingAnchor constraintEqualToAnchor:self.resultCard.trailingAnchor constant:-10],
        [self.outputCopyBtn.topAnchor constraintEqualToAnchor:self.resultLabel.bottomAnchor constant:8],
        [self.outputCopyBtn.leadingAnchor constraintEqualToAnchor:self.resultCard.leadingAnchor constant:10],
        [self.outputCopyBtn.trailingAnchor constraintEqualToAnchor:self.resultCard.trailingAnchor constant:-10],
        [self.outputCopyBtn.bottomAnchor constraintEqualToAnchor:self.resultCard.bottomAnchor constant:-10],
    ]];

    // ---------- Debug (collapsed) ----------
    self.debugToggleBtn = [self makeBtn:@"⚙️  Advanced / debug (thread ID, schema, research...)" bg:[UIColor secondarySystemBackgroundColor] act:@selector(toggleDebugTapped) h:40];
    self.debugToggleBtn.titleLabel.font = [UIFont systemFontOfSize:13];

    self.debugStack = [[UIStackView alloc] init];
    self.debugStack.axis = UILayoutConstraintAxisVertical;
    self.debugStack.spacing = 8;
    self.debugStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.debugStack.hidden = YES;

    self.manualTidField = [[UITextField alloc] init];
    self.manualTidField.placeholder = @"Manual thread ID (used by Inject if no chat picked)";
    self.manualTidField.borderStyle = UITextBorderStyleRoundedRect;
    self.manualTidField.font = [UIFont systemFontOfSize:13];
    self.manualTidField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.manualTidField.translatesAutoresizingMaskIntoConstraints = NO;

    UIButton *scanBtn = [self makeBtn:@"Scan chats (list IDs)" bg:[UIColor secondarySystemBackgroundColor] act:@selector(threadsTapped) h:40];
    UIButton *researchBtn = [self makeBtn:@"\U0001F52C  Research thread mapping (uses ID above)" bg:[UIColor systemIndigoColor] act:@selector(researchTapped) h:40];
    UIButton *sqlBtn = [self makeBtn:@"📜  Research SQL logic" bg:[UIColor systemIndigoColor] act:@selector(researchSqlTapped) h:40];
    sqlBtn.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    UIButton *findDBBtn = [self makeBtn:@"Find database file" bg:[UIColor secondarySystemBackgroundColor] act:@selector(findDBTapped) h:40];
    UIButton *schemaBtn = [self makeBtn:@"Dump DB schema" bg:[UIColor systemOrangeColor] act:@selector(dumpSchemaTapped) h:40];
    UIButton *sampleBtn = [self makeBtn:@"Dump sample data" bg:[UIColor systemOrangeColor] act:@selector(dumpSampleTapped) h:40];
    UIButton *crashBtn = [self makeBtn:@"Get crash log" bg:[UIColor systemRedColor] act:@selector(crashTapped) h:40];
    UIButton *listBtn = [self makeBtn:@"List all files" bg:[UIColor systemPurpleColor] act:@selector(listFilesTapped) h:40];
    UIButton *dumpViewBtn = [self makeBtn:@"Dump view hierarchy" bg:[UIColor secondarySystemBackgroundColor] act:@selector(dumpViewTapped) h:40];
    [self.debugStack addArrangedSubview:self.manualTidField];
    [self.debugStack addArrangedSubview:scanBtn];
    [self.debugStack addArrangedSubview:researchBtn];
    [self.debugStack addArrangedSubview:sqlBtn];
    [self.debugStack addArrangedSubview:findDBBtn];
    [self.debugStack addArrangedSubview:schemaBtn];
    [self.debugStack addArrangedSubview:sampleBtn];
    [self.debugStack addArrangedSubview:crashBtn];
    [self.debugStack addArrangedSubview:listBtn];
    [self.debugStack addArrangedSubview:dumpViewBtn];

    // ---------- assemble ----------
    [stack addArrangedSubview:self.statusLabel];
    [stack addArrangedSubview:self.chatCard];
    [stack addArrangedSubview:self.threadListStack];
    [stack addArrangedSubview:s2];
    [stack addArrangedSubview:self.messageStack];
    [stack addArrangedSubview:addBtn];
    [stack addArrangedSubview:prevLabel];
    [stack addArrangedSubview:self.previewView];
    [stack addArrangedSubview:s3];
    [stack addArrangedSubview:self.injectBtn];
    [stack addArrangedSubview:self.resultCard];
    [stack addArrangedSubview:self.debugToggleBtn];
    [stack addArrangedSubview:self.debugStack];

    // keyboard toolbar (Done)
    self.kbToolbar = [[UIToolbar alloc] initWithFrame:CGRectMake(0, 0, 320, 44)];
    UIBarButtonItem *flex = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
    UIBarButtonItem *done = [[UIBarButtonItem alloc] initWithTitle:@"Done" style:UIBarButtonItemStyleDone target:self action:@selector(dismissKeyboard)];
    self.kbToolbar.items = @[flex, done];

    // floating hide-keyboard pill (top-right, visible while keyboard up)
    self.hideKbFloatBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.hideKbFloatBtn setTitle:@"Hide ⌨️" forState:UIControlStateNormal];
    self.hideKbFloatBtn.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.hideKbFloatBtn.layer.cornerRadius = 16;
    self.hideKbFloatBtn.layer.borderWidth = 1;
    self.hideKbFloatBtn.layer.borderColor = [UIColor systemGray3Color].CGColor;
    self.hideKbFloatBtn.layer.shadowOpacity = 0.2;
    self.hideKbFloatBtn.layer.shadowRadius = 4;
    self.hideKbFloatBtn.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    self.hideKbFloatBtn.translatesAutoresizingMaskIntoConstraints = NO;
    self.hideKbFloatBtn.hidden = YES;
    [self.hideKbFloatBtn addTarget:self action:@selector(dismissKeyboard) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.hideKbFloatBtn];
    [NSLayoutConstraint activateConstraints:@[
        [self.hideKbFloatBtn.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        [self.hideKbFloatBtn.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8],
        [self.hideKbFloatBtn.heightAnchor constraintEqualToConstant:30],
    ]];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(kbShow:) name:UIKeyboardWillShowNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(kbHide:) name:UIKeyboardWillHideNotification object:nil];

    UITapGestureRecognizer *tapDismiss = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismissKeyboard)];
    tapDismiss.cancelsTouchesInView = NO;
    [scroll addGestureRecognizer:tapDismiss];

    [scroll addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:scroll.topAnchor constant:12],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.bottomAnchor constant:-12],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.leadingAnchor constant:16],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.trailingAnchor constant:-16],
        [stack.widthAnchor constraintEqualToAnchor:scroll.widthAnchor constant:-32],
    ]];

    [self addMessageRowToolbars];
    [self refreshPreview];

    // ---------- dylib ready ----------
    __weak typeof(self) weakSelf = self;
    [[NSDistributedNotificationCenter defaultCenter]
        addObserverForName:kNotifyReady object:nil queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
            dispatch_async(dispatch_get_main_queue(), ^{
                typeof(self) strongSelf = weakSelf;
                if (!strongSelf) return;
                NSString *ver = note.userInfo[@"version"] ?: @"?";
                strongSelf->_dylibReady = YES;
                strongSelf.statusLabel.text = [NSString stringWithFormat:@"✅ Dylib v%@ running — ready", ver];
                strongSelf.statusLabel.backgroundColor = [UIColor systemGreenColor];
            });
        }];

    [[NSDistributedNotificationCenter defaultCenter]
        addObserverForName:kNotifyResult object:nil queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
            dispatch_async(dispatch_get_main_queue(), ^{
                typeof(self) strongSelf = weakSelf;
                if (!strongSelf) return;
                [strongSelf handleResultWithTag:note.userInfo[@"tag"] ?: @"result" text:note.userInfo[@"text"] ?: @""];
            });
        }];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

// ============================================================
// Results
// ============================================================
- (void)handleResultWithTag:(NSString *)tag text:(NSString *)text {
    _resultText = [NSString stringWithFormat:@"[%@]\n%@", tag, text];
    if ([tag isEqualToString:@"threadList"]) { [self populateThreadList:text]; return; }
    if ([tag isEqualToString:@"inject"]) { [self showInjectResult:text]; return; }
    if (tag.length > 0 && ![tag isEqualToString:@"result"]) {
        self.resultCard.hidden = NO;
        self.resultCard.backgroundColor = [UIColor secondarySystemBackgroundColor];
        self.resultLabel.textColor = [UIColor labelColor];
        self.resultLabel.text = [NSString stringWithFormat:@"[%@]\n%@", tag, text];
    }
}

- (void)showInjectResult:(NSString *)text {
    NSRange r = [text rangeOfString:@"@@MIRESULT|"];
    if (r.location == NSNotFound) {
        self.resultCard.hidden = NO;
        self.resultCard.backgroundColor = [UIColor systemRedColor];
        self.resultLabel.textColor = [UIColor whiteColor];
        self.resultLabel.text = [text containsString:@"Exception"]
            ? @"❌ Messenger crashed during inject. Open Messenger — if it stays open, check Advanced → Get crash log."
            : @"❌ Unexpected result — open Advanced → Copy for details.";
        return;
    }
    NSRange end = [text rangeOfString:@"|@@" options:0 range:NSMakeRange(r.location, text.length - r.location)];
    if (end.location == NSNotFound) {
        self.resultCard.hidden = NO;
        self.resultCard.backgroundColor = [UIColor systemOrangeColor];
        self.resultLabel.textColor = [UIColor whiteColor];
        self.resultLabel.text = @"⚠️ Got a result but couldn't parse it. Check Advanced for the full log.";
        return;
    }
    NSString *line = [text substringWithRange:NSMakeRange(r.location + 11, end.location - r.location - 11)];
    NSMutableDictionary *kv = [NSMutableDictionary dictionary];
    for (NSString *part in [line componentsSeparatedByString:@"|"]) {
        NSArray *kp = [part componentsSeparatedByString:@"="];
        if (kp.count >= 2) kv[kp[0]] = [[kp subarrayWithRange:NSMakeRange(1, kp.count - 1)] componentsJoinedByString:@"="];
    }
    self.resultCard.hidden = NO;
    BOOL ok = [kv[@"ok"] intValue] == 1;
    NSString *method = kv[@"method"] ?: @"";
    NSString *name = kv[@"name"] ?: @"";
    NSString *n = kv[@"inserted"] ?: @"0";
    if (!ok) {
        self.resultCard.backgroundColor = [UIColor systemRedColor];
        self.resultLabel.textColor = [UIColor whiteColor];
        NSString *reason = kv[@"reason"] ?: @"";
        self.resultLabel.text = [reason containsString:@"entity_id_mismatch"]
            ? [NSString stringWithFormat:@"🛑 Refused to inject: the resolved chat belongs to a DIFFERENT person (safety gate). Open Advanced → Research thread mapping with your thread ID and send me the output."]
            : [NSString stringWithFormat:@"❌ Inject failed (%@ errors). Open Advanced for the full log.", kv[@"errors"] ?: @"?"];
    } else if ([method isEqualToString:@"LAST_RESORT_first_thread"]) {
        self.resultCard.backgroundColor = [UIColor systemOrangeColor];
        self.resultLabel.textColor = [UIColor whiteColor];
        self.resultLabel.text = [NSString stringWithFormat:@"⚠️ Wrote %@ message(s), but the exact chat was NOT found — they may land in the wrong chat. Tap Advanced → Research and send me the output.", n];
    } else {
        self.resultCard.backgroundColor = [UIColor systemGreenColor];
        self.resultLabel.textColor = [UIColor whiteColor];
        NSString *chat = (name.length > 0 && ![name isEqualToString:@"NULL"]) ? [NSString stringWithFormat:@" to “%@”", name] : @"";
        self.resultLabel.text = [NSString stringWithFormat:@"✅ Wrote %@ message%@.\nNow force-quit Messenger (swipe it away), reopen it, and open the chat to verify.", n, chat];
    }
    _injectPending = NO;
}

// ============================================================
// Step 1 — chat picker
// ============================================================
- (void)chatCardTapped { [self threadsTapped]; }

- (void)threadsTapped {
    [self.view endEditing:YES];
    [self.threadButtons removeAllObjects];
    for (UIView *v in self.threadListStack.arrangedSubviews) { [self.threadListStack removeArrangedSubview:v]; [v removeFromSuperview]; }
    self.threadListStack.hidden = NO;
    self.chatCardSub.text = @"Scanning...";
    [[NSDistributedNotificationCenter defaultCenter] postNotificationName:kNotifyThreads object:nil userInfo:@{} deliverImmediately:YES];
}

- (void)populateThreadList:(NSString *)jsonStr {
    for (UIView *v in self.threadListStack.arrangedSubviews) { [self.threadListStack removeArrangedSubview:v]; [v removeFromSuperview]; }
    [self.threadButtons removeAllObjects];
    NSData *jd = [jsonStr dataUsingEncoding:NSUTF8StringEncoding];
    NSArray *threads = [NSJSONSerialization JSONObjectWithData:jd options:0 error:nil];
    if (![threads isKindOfClass:[NSArray class]] || threads.count == 0) {
        self.chatCardSub.text = @"No chats found — open Messenger, load your chat list, try again.";
        self.threadListStack.hidden = YES;
        return;
    }
    for (NSDictionary *t in threads) {
        NSString *k = t[@"k"] ?: @"";
        NSString *n = t[@"n"] ?: @"";
        NSString *p = t[@"p"] ?: @"";
        if (n.length == 0 || [n isEqualToString:@"NULL"]) n = k;
        if (p.length > 34) p = [[p substringToIndex:34] stringByAppendingString:@"…"];
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
        [btn setTitle:[NSString stringWithFormat:@"%@   %@  ·  %@", n, p.length ? p : @"", k] forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont systemFontOfSize:13];
        btn.titleLabel.numberOfLines = 2;
        btn.titleLabel.textAlignment = NSTextAlignmentLeft;
        btn.backgroundColor = [UIColor secondarySystemBackgroundColor];
        [btn setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
        btn.layer.cornerRadius = 8;
        btn.contentEdgeInsets = UIEdgeInsetsMake(8, 10, 8, 10);
        btn.translatesAutoresizingMaskIntoConstraints = NO;
        [btn.heightAnchor constraintEqualToConstant:52].active = YES;
        btn.accessibilityLabel = k;
        [btn addTarget:self action:@selector(threadPicked:) forControlEvents:UIControlEventTouchUpInside];
        [self.threadButtons addObject:btn];
        [self.threadListStack addArrangedSubview:btn];
    }
    self.chatCardSub.text = [NSString stringWithFormat:@"✅ Found %d chats — tap the one you want:", (int)threads.count];
}

- (void)threadPicked:(UIButton *)btn {
    _selThreadID = btn.accessibilityLabel ?: @"";
    NSString *full = [btn titleForState:UIControlStateNormal] ?: @"";
    _selThreadName = [[full componentsSeparatedByString:@"\u00A0\u00A0"] firstObject] ?: _selThreadID;
    // trim trailing " · id" from name
    NSRange dot = [_selThreadName rangeOfString:@"  ·  "];
    if (dot.location != NSNotFound) _selThreadName = [_selThreadName substringToIndex:dot.location];
    _selThreadName = [_selThreadName stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    for (UIButton *b in self.threadButtons) {
        b.backgroundColor = [UIColor secondarySystemBackgroundColor];
        [b setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
    }
    btn.backgroundColor = [UIColor systemGreenColor];
    [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.threadListStack.hidden = YES;
    self.chatCardTitle.text = @"1.  Pick a chat";
    self.chatCardSub.text = [NSString stringWithFormat:@"✅ %@   (%@)   — tap to change", _selThreadName, _selThreadID];
    self.chatCardSub.textColor = [UIColor systemGreenColor];
    self.manualTidField.text = _selThreadID;
}

// ============================================================
// Step 2 — messages + preview
// ============================================================
- (void)addMessageRow:(BOOL)isMe {
    MIMessageRow *row = [[MIMessageRow alloc] init];
    row.isMe = isMe;
    row.sideControl.selectedSegmentIndex = isMe ? 0 : 1;
    __weak typeof(self) weakSelf = self;
    row.onChanged = ^{ [weakSelf refreshPreview]; };
    row.onDelete = ^(MIMessageRow *r) { [weakSelf removeMessageRow:r]; };
    [self.messageRows addObject:row];
    [self.messageStack addArrangedSubview:row];
    row.textField.inputAccessoryView = self.kbToolbar;
    row.minAgoField.inputAccessoryView = self.kbToolbar;
}

- (void)addMessageRowToolbars {
    for (MIMessageRow *row in self.messageRows) {
        row.textField.inputAccessoryView = self.kbToolbar;
        row.minAgoField.inputAccessoryView = self.kbToolbar;
    }
    self.manualTidField.inputAccessoryView = self.kbToolbar;
}

- (void)removeMessageRow:(MIMessageRow *)row {
    [self.messageStack removeArrangedSubview:row];
    [row removeFromSuperview];
    [self.messageRows removeObject:row];
    if (self.messageRows.count == 0) [self addMessageRow:YES];
    [self refreshPreview];
}

- (void)addRowTapped { [self addMessageRow:YES]; }

- (void)refreshPreview {
    NSMutableString *s = [NSMutableString string];
    for (MIMessageRow *row in self.messageRows) {
        NSString *t = [row.textField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (t.length == 0) continue;
        if (t.length > 60) t = [[t substringToIndex:60] stringByAppendingString:@"…"];
        if (row.isMe) { [s appendFormat:@"            %@\n", t]; }
        else { [s appendFormat:@"%@  (them)\n", t]; }
    }
    self.previewView.text = s.length ? s : @"(type in the boxes above)";
}

// ============================================================
// Step 3 — inject
// ============================================================
- (void)injectTapped {
    [self.view endEditing:YES];
    NSString *tid = _selThreadID.length ? _selThreadID : (self.manualTidField.text ?: @"");
    tid = [tid stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (tid.length == 0) {
        self.resultCard.hidden = NO;
        self.resultCard.backgroundColor = [UIColor systemOrangeColor];
        self.resultLabel.textColor = [UIColor whiteColor];
        self.resultLabel.text = @"⬆️ Pick a chat first (Step 1).";
        return;
    }
    NSMutableArray *messages = [NSMutableArray array];
    for (int i = 0; i < (int)self.messageRows.count; i++) {
        MIMessageRow *row = self.messageRows[i];
        NSString *t = [row.textField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (t.length == 0) continue;
        NSString *minStr = row.minAgoField.text ?: @"";
        int minAgo = minStr.length > 0 ? [minStr intValue] : (int)(self.messageRows.count - i);
        if (minAgo < 0) minAgo = 0;
        [messages addObject:@{@"s": row.isMe ? @"me" : @"them", @"t": t, @"m": @(minAgo)}];
    }
    if (messages.count == 0) {
        self.resultCard.hidden = NO;
        self.resultCard.backgroundColor = [UIColor systemOrangeColor];
        self.resultLabel.textColor = [UIColor whiteColor];
        self.resultLabel.text = @"✍️ Write at least one message (Step 2).";
        return;
    }
    self.statusLabel.text = @"⏳ Injecting...";
    self.statusLabel.backgroundColor = [UIColor systemBlueColor];
    self.resultCard.hidden = YES;
    _injectPending = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(45 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        typeof(self) strongSelf = weakSelf;
        if (strongSelf && strongSelf->_injectPending) {
            strongSelf->_injectPending = NO;
            strongSelf.statusLabel.text = @"⚠️ No response — is Messenger open with the dylib?";
            strongSelf.statusLabel.backgroundColor = [UIColor systemRedColor];
        }
    });
    [[NSDistributedNotificationCenter defaultCenter]
        postNotificationName:kNotifyInject object:nil
                    userInfo:@{@"threadId": tid, @"messages": messages}
            deliverImmediately:YES];
}

// ============================================================
// Debug actions
// ============================================================
- (void)toggleDebugTapped {
    self.debugStack.hidden = !self.debugStack.hidden;
    [self.debugToggleBtn setTitle:self.debugStack.hidden ? @"⚙️  Advanced / debug (thread ID, schema, research...)" : @"✖  Close advanced" forState:UIControlStateNormal];
}

- (void)postDebug:(NSString *)notif label:(NSString *)label {
    [self.view endEditing:YES];
    self.resultCard.hidden = NO;
    self.resultCard.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.resultLabel.textColor = [UIColor labelColor];
    self.resultLabel.text = [NSString stringWithFormat:@"%@...", label];
    [[NSDistributedNotificationCenter defaultCenter] postNotificationName:notif object:nil userInfo:@{} deliverImmediately:YES];
}

- (void)findDBTapped { [self postDebug:kNotifyFindDB label:@"Finding database"]; }
- (void)dumpSchemaTapped { [self postDebug:kNotifySchema label:@"Dumping schema"]; }
- (void)dumpSampleTapped { [self postDebug:kNotifySample label:@"Dumping sample data"]; }
- (void)crashTapped { [self postDebug:kNotifyCrash label:@"Fetching crash log"]; }
- (void)listFilesTapped { [self postDebug:kNotifyListFiles label:@"Listing files"]; }
- (void)dumpViewTapped { [self postDebug:kNotifyDumpView label:@"Dumping view hierarchy"]; }

- (void)researchTapped {
    [self.view endEditing:YES];
    NSString *tid = [self.manualTidField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    self.resultCard.hidden = NO;
    self.resultCard.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.resultLabel.textColor = [UIColor labelColor];
    self.resultLabel.text = @"🔬 Researching thread mapping (a few seconds)...";
    [[NSDistributedNotificationCenter defaultCenter]
        postNotificationName:kNotifyResearch object:nil userInfo:@{@"threadId": tid ?: @"", @"mode": @"map"} deliverImmediately:YES];
}

- (void)researchSqlTapped {
    [self.view endEditing:YES];
    self.resultCard.hidden = NO;
    self.resultCard.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.resultLabel.textColor = [UIColor labelColor];
    self.resultLabel.text = @"📜 Reading app SQL logic (views/triggers)...";
    [[NSDistributedNotificationCenter defaultCenter]
        postNotificationName:kNotifyResearch object:nil userInfo:@{@"threadId": @"", @"mode": @"sql"} deliverImmediately:YES];
}

// ============================================================
// Keyboard
// ============================================================
- (void)copyTapped {
    [UIPasteboard generalPasteboard].string = _resultText;
    [self.outputCopyBtn setTitle:@"\u2705 Copied!" forState:UIControlStateNormal];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self.outputCopyBtn setTitle:@"\U0001F4CB  Copy output" forState:UIControlStateNormal];
    });
}

- (void)kbShow:(NSNotification *)n { self.hideKbFloatBtn.hidden = NO; }
- (void)kbHide:(NSNotification *)n { self.hideKbFloatBtn.hidden = YES; }
- (void)dismissKeyboard { [self.view endEditing:YES]; }
- (BOOL)textFieldShouldReturn:(UITextField *)tf { [tf resignFirstResponder]; return YES; }

// ============================================================
// UI helpers
// ============================================================
- (UILabel *)stepLabel:(NSString *)t {
    UILabel *l = [[UILabel alloc] init];
    l.text = t;
    l.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    l.textColor = [UIColor labelColor];
    return l;
}

- (UIButton *)makeBtn:(NSString *)t bg:(UIColor *)bg act:(SEL)act h:(CGFloat)h {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:t forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    b.backgroundColor = bg;
    [b setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
    b.layer.cornerRadius = 10;
    b.translatesAutoresizingMaskIntoConstraints = NO;
    [b.heightAnchor constraintEqualToConstant:h].active = YES;
    [b addTarget:self action:act forControlEvents:UIControlEventTouchUpInside];
    return b;
}

@end

// ============================================================
// App delegate
// ============================================================
@interface MIHelperAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation MIHelperAppDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
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
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([MIHelperAppDelegate class]));
    }
}
