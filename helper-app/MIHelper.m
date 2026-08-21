/**
 * MIHelper v4.0 — auto-DB + search + select + inject
 *
 *   1. Auto-reads Messenger DB on launch (status shows progress)
 *   2. Search bar filters people by name (diacritic-insensitive)
 *   3. Tap a person to select
 *   4. Compose messages (Me/Them) with live preview
 *   5. Inject -> plain-English result
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
#import <objc/runtime.h>

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

        _sideControl = [[UISegmentedControl alloc] initWithItems:@[@"\U0001F9D1 Me", @"\U0001F464 Them"]];
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
    BOOL _dbLoaded;
    BOOL _injectPending;
    NSMutableArray *_people;      // [{k,n,p,t}]
    NSMutableArray *_personBtns;  // visible buttons
}
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UITextField *searchField;
@property (nonatomic, strong) UILabel *selectedLabel;   // shows chosen person
@property (nonatomic, strong) UIStackView *peopleListStack;
@property (nonatomic, strong) UIScrollView *peopleScroll;
@property (nonatomic, strong) NSLayoutConstraint *peopleScrollH;
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
@property (nonatomic, copy) NSString *selID;
@property (nonatomic, copy) NSString *selName;
@end

@implementation MIHelperVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.title = @"Fake Chat";
    _resultText = @"";
    _dbLoaded = NO;
    _people = [NSMutableArray array];
    _personBtns = [NSMutableArray array];

    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
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
    self.statusLabel.numberOfLines = 1;
    self.statusLabel.text = @"\U00023F3 Reading Messenger database... (open Messenger once)";
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.statusLabel.heightAnchor constraintEqualToConstant:34].active = YES;

    // ---------- Search ----------
    self.searchField = [[UITextField alloc] init];
    self.searchField.placeholder = @"\U0001F50D Search person...";
    self.searchField.borderStyle = UITextBorderStyleRoundedRect;
    self.searchField.clearButtonMode = UITextFieldViewModeWhileEditing;
    self.searchField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.searchField.font = [UIFont systemFontOfSize:15];
    self.searchField.delegate = self;
    self.searchField.translatesAutoresizingMaskIntoConstraints = NO;
    [self.searchField.heightAnchor constraintEqualToConstant:40].active = YES;
    [self.searchField addTarget:self action:@selector(searchChanged) forControlEvents:UIControlEventEditingChanged];

    // ---------- Selected person ----------
    self.selectedLabel = [[UILabel alloc] init];
    self.selectedLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    self.selectedLabel.textColor = [UIColor secondaryLabelColor];
    self.selectedLabel.numberOfLines = 0;
    self.selectedLabel.text = @"No person selected \u2014 search & tap above";

    // ---------- People list (scrollable, max height) ----------
    self.peopleScroll = [[UIScrollView alloc] init];
    self.peopleScroll.translatesAutoresizingMaskIntoConstraints = NO;
    self.peopleScroll.showsVerticalScrollIndicator = YES;
    self.peopleScroll.hidden = YES;
    self.peopleScrollH = [self.peopleScroll.heightAnchor constraintEqualToConstant:220];
    self.peopleScrollH.active = YES;

    self.peopleListStack = [[UIStackView alloc] init];
    self.peopleListStack.axis = UILayoutConstraintAxisVertical;
    self.peopleListStack.spacing = 6;
    self.peopleListStack.translatesAutoresizingMaskIntoConstraints = NO;

    [self.peopleScroll addSubview:self.peopleListStack];
    [NSLayoutConstraint activateConstraints:@[
        [self.peopleListStack.topAnchor constraintEqualToAnchor:self.peopleScroll.topAnchor constant:8],
        [self.peopleListStack.leadingAnchor constraintEqualToAnchor:self.peopleScroll.leadingAnchor constant:8],
        [self.peopleListStack.widthAnchor constraintEqualToAnchor:self.peopleScroll.widthAnchor constant:-16],
        [self.peopleListStack.bottomAnchor constraintEqualToAnchor:self.peopleScroll.bottomAnchor constant:-8],
    ]];

    // ---------- Messages ----------
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

    UILabel *prevLabel = [[UILabel alloc] init];
    prevLabel.text = @"How it will look:";
    prevLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    prevLabel.textColor = [UIColor tertiaryLabelColor];

    self.previewView = [[UITextView alloc] init];
    self.previewView.editable = NO;
    self.previewView.selectable = NO;
    self.previewView.font = [UIFont fontWithName:@"Menlo-Regular" size:12];
    self.previewView.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.previewView.layer.cornerRadius = 10;
    self.previewView.text = @"(empty)";
    self.previewView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.previewView.heightAnchor constraintEqualToConstant:110].active = YES;

    // ---------- Inject ----------
    UILabel *s3 = [self stepLabel:@"3.  Inject"];
    self.injectBtn = [self makeBtn:@"\U0001F680  Inject into chat" bg:[UIColor systemBlueColor] act:@selector(injectTapped) h:56];
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
    self.resultLabel.scrollEnabled = YES;
    [self.resultLabel.heightAnchor constraintLessThanOrEqualToConstant:300].active = YES;
    self.outputCopyBtn = [self makeBtn:@"\U0001F4CB  Copy output" bg:[UIColor systemGreenColor] act:@selector(copyOutputTapped) h:36];
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
    self.debugToggleBtn = [self makeBtn:@"\u2699\uFE0F  Advanced / debug" bg:[UIColor secondarySystemBackgroundColor] act:@selector(toggleDebugTapped) h:40];
    self.debugToggleBtn.titleLabel.font = [UIFont systemFontOfSize:13];

    self.debugStack = [[UIStackView alloc] init];
    self.debugStack.axis = UILayoutConstraintAxisVertical;
    self.debugStack.spacing = 8;
    self.debugStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.debugStack.hidden = YES;

    UIButton *rescanBtn = [self makeBtn:@"\U0001F504  Re-read database" bg:[UIColor systemTealColor] act:@selector(rescanTapped) h:40];
    UIButton *researchBtn = [self makeBtn:@"\U0001F52C  Research mapping (selected person)" bg:[UIColor systemIndigoColor] act:@selector(researchTapped) h:40];
    UIButton *sqlBtn = [self makeBtn:@"\U0001F4DC  Research SQL logic" bg:[UIColor systemIndigoColor] act:@selector(researchSqlTapped) h:40];
    researchBtn.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    sqlBtn.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    UIButton *findDBBtn = [self makeBtn:@"Find database file" bg:[UIColor secondarySystemBackgroundColor] act:@selector(findDBTapped) h:40];
    UIButton *schemaBtn = [self makeBtn:@"Dump DB schema" bg:[UIColor systemOrangeColor] act:@selector(dumpSchemaTapped) h:40];
    UIButton *sampleBtn = [self makeBtn:@"Dump sample data" bg:[UIColor systemOrangeColor] act:@selector(dumpSampleTapped) h:40];
    UIButton *crashBtn = [self makeBtn:@"Get crash log" bg:[UIColor systemRedColor] act:@selector(crashTapped) h:40];
    UIButton *listBtn = [self makeBtn:@"List all files" bg:[UIColor systemPurpleColor] act:@selector(listFilesTapped) h:40];
    UIButton *dumpViewBtn = [self makeBtn:@"Dump view hierarchy" bg:[UIColor secondarySystemBackgroundColor] act:@selector(dumpViewTapped) h:40];
    [self.debugStack addArrangedSubview:rescanBtn];
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
    [stack addArrangedSubview:self.searchField];
    [stack addArrangedSubview:self.selectedLabel];
    [stack addArrangedSubview:self.peopleScroll];
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

    // keyboard toolbar
    self.kbToolbar = [[UIToolbar alloc] initWithFrame:CGRectMake(0, 0, 320, 44)];
    UIBarButtonItem *flex = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
    UIBarButtonItem *done = [[UIBarButtonItem alloc] initWithTitle:@"Done" style:UIBarButtonItemStyleDone target:self action:@selector(dismissKeyboard)];
    self.kbToolbar.items = @[flex, done];

    // floating hide-keyboard pill
    self.hideKbFloatBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.hideKbFloatBtn setTitle:@"Hide \u2328\uFE0F" forState:UIControlStateNormal];
    self.hideKbFloatBtn.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.hideKbFloatBtn.layer.cornerRadius = 16;
    self.hideKbFloatBtn.layer.borderWidth = 1;
    self.hideKbFloatBtn.layer.borderColor = [UIColor systemGray3Color].CGColor;
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

    [self applyToolbars];
    [self refreshPreview];

    // ---------- observers ----------
    __weak typeof(self) weakSelf = self;
    [[NSDistributedNotificationCenter defaultCenter]
        addObserverForName:kNotifyReady object:nil queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
            dispatch_async(dispatch_get_main_queue(), ^{
                typeof(self) strongSelf = weakSelf;
                if (!strongSelf || strongSelf->_dbLoaded) return;
                NSString *ver = note.userInfo[@"version"] ?: @"";
                strongSelf.statusLabel.text = [NSString stringWithFormat:@"\u2705 Dylib v%@ running \u2014 reading DB...", ver];
                strongSelf.statusLabel.backgroundColor = [UIColor systemTealColor];
                [strongSelf rescanTapped];
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

    // AUTO-SCAN: retry every 4s until DB loads
    [NSTimer scheduledTimerWithTimeInterval:4.0 repeats:YES block:^(NSTimer *timer) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) { [timer invalidate]; return; }
        if (strongSelf->_dbLoaded) { [timer invalidate]; return; }
        [[NSDistributedNotificationCenter defaultCenter]
            postNotificationName:kNotifyThreads object:nil userInfo:@{} deliverImmediately:YES];
    }];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

// ============================================================
// Results routing
// ============================================================
- (void)handleResultWithTag:(NSString *)tag text:(NSString *)text {
    _resultText = [NSString stringWithFormat:@"[%@]\n%@", tag, text];
    if ([tag isEqualToString:@"threadList"]) { [self populatePeople:text]; return; }
    if ([tag isEqualToString:@"threads"]) {
        // scan error — show in status
        self.statusLabel.text = [NSString stringWithFormat:@"\u26A0\uFE0F %@", text.length > 60 ? [text substringToIndex:60] : text];
        self.statusLabel.backgroundColor = [UIColor systemOrangeColor];
        return;
    }
    if ([tag isEqualToString:@"inject"]) { [self showInjectResult:text]; return; }
    if (tag.length > 0 && ![tag isEqualToString:@"result"]) {
        self.resultCard.hidden = NO;
        self.resultCard.backgroundColor = [UIColor secondarySystemBackgroundColor];
        self.resultLabel.textColor = [UIColor labelColor];
        self.resultLabel.text = [NSString stringWithFormat:@"[%@]\n%@", tag, text];
    }
}

// ============================================================
// People list
// ============================================================
- (void)populatePeople:(NSString *)jsonStr {
    NSData *jd = [jsonStr dataUsingEncoding:NSUTF8StringEncoding];
    NSArray *arr = [NSJSONSerialization JSONObjectWithData:jd options:0 error:nil];
    if (![arr isKindOfClass:[NSArray class]]) arr = @[];
    _people = [arr mutableCopy];
    _dbLoaded = _people.count > 0;
    if (!_dbLoaded) {
        self.statusLabel.text = @"\u26A0\uFE0F DB read but no chats found \u2014 open Messenger chats first";
        self.statusLabel.backgroundColor = [UIColor systemOrangeColor];
        return;
    }
    self.statusLabel.text = [NSString stringWithFormat:@"\u2705 Database loaded \u2014 %d chats. Search & tap a person.", (int)_people.count];
    self.statusLabel.backgroundColor = [UIColor systemGreenColor];
    self.peopleScroll.hidden = NO;
    [self rebuildPeopleList];
}

- (NSString *)fold:(NSString *)s {
    return [s stringByFoldingWithOptions:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch locale:[NSLocale currentLocale]];
}

- (void)rebuildPeopleList {
    for (UIView *v in self.peopleListStack.arrangedSubviews) { [self.peopleListStack removeArrangedSubview:v]; [v removeFromSuperview]; }
    [_personBtns removeAllObjects];

    NSString *q = [self fold:self.searchField.text ?: @""];
    int shown = 0;
    for (NSDictionary *t in _people) {
        NSString *name = t[@"n"] ?: @"";
        NSString *k = t[@"k"] ?: @"";
        if (q.length > 0 && [[self fold:name] containsString:q] == NO) continue;
        if (k.length == 0) continue; // unresolved ID -> not injectable, hide
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
        NSString *sub = t[@"p"] ?: @"";
        [btn setTitle:[NSString stringWithFormat:@"%@   \u00B7   %@", name, sub] forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont systemFontOfSize:14];
        btn.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
        btn.titleEdgeInsets = UIEdgeInsetsMake(0, 8, 0, 8);
        btn.backgroundColor = [UIColor secondarySystemBackgroundColor];
        [btn setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
        btn.layer.cornerRadius = 8;
        btn.translatesAutoresizingMaskIntoConstraints = NO;
        [btn.heightAnchor constraintEqualToConstant:44].active = YES;
        btn.accessibilityLabel = k;
        objc_setAssociatedObject(btn, "name", name, OBJC_ASSOCIATION_COPY);
        [btn addTarget:self action:@selector(personPicked:) forControlEvents:UIControlEventTouchUpInside];
        [_personBtns addObject:btn];
        [self.peopleListStack addArrangedSubview:btn];
        shown++;
        if (shown >= 100) break;
    }
    if (shown == 0) {
        UILabel *empty = [[UILabel alloc] init];
        empty.text = q.length > 0 ? @"No match." : @"(no chats with resolved IDs)";
        empty.font = [UIFont systemFontOfSize:13];
        empty.textColor = [UIColor tertiaryLabelColor];
        [self.peopleListStack addArrangedSubview:empty];
    }
    // shrink list height when few rows
    CGFloat h = MIN(220.0, MAX(44.0, shown * 50.0 + 16.0));
    self.peopleScrollH.constant = h;
}

- (void)searchChanged { [self rebuildPeopleList]; }

- (void)personPicked:(UIButton *)btn {
    [self.view endEditing:YES];
    _selID = btn.accessibilityLabel ?: @"";
    _selName = objc_getAssociatedObject(btn, "name") ?: _selID;
    for (UIButton *b in _personBtns) {
        b.backgroundColor = [UIColor secondarySystemBackgroundColor];
        [b setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
    }
    btn.backgroundColor = [UIColor systemGreenColor];
    [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.selectedLabel.text = [NSString stringWithFormat:@"\u2705 %@  (%@)", _selName, _selID];
    self.selectedLabel.textColor = [UIColor systemGreenColor];
}

// ============================================================
// Messages + preview
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
    [self applyToolbars];
}

- (void)applyToolbars {
    for (MIMessageRow *row in self.messageRows) {
        row.textField.inputAccessoryView = self.kbToolbar;
        row.minAgoField.inputAccessoryView = self.kbToolbar;
    }
    self.searchField.inputAccessoryView = self.kbToolbar;
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
        if (t.length > 34) t = [[t substringToIndex:34] stringByAppendingString:@"\u2026"];
        if (row.isMe) { [s appendFormat:@"%28s\n", t.UTF8String]; }
        else { [s appendFormat:@"%@\n", t]; }
    }
    self.previewView.text = s.length ? s : @"(type in the boxes above)";
}

// ============================================================
// Inject
// ============================================================
- (void)injectTapped {
    [self.view endEditing:YES];
    if (_selID.length == 0) {
        [self showErrorCard:@"\u2B06\uFE0F Pick a person first (search & tap above)."];
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
        [self showErrorCard:@"\u270D\uFE0F Write at least one message."];
        return;
    }
    self.statusLabel.text = @"\u23F3 Injecting...";
    self.statusLabel.backgroundColor = [UIColor systemBlueColor];
    self.resultCard.hidden = YES;
    _injectPending = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(45 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        typeof(self) strongSelf = weakSelf;
        if (strongSelf && strongSelf->_injectPending) {
            strongSelf->_injectPending = NO;
            strongSelf.statusLabel.text = @"\u26A0\uFE0F No response \u2014 is Messenger open with the dylib?";
            strongSelf.statusLabel.backgroundColor = [UIColor systemRedColor];
        }
    });
    [[NSDistributedNotificationCenter defaultCenter]
        postNotificationName:kNotifyInject object:nil
                    userInfo:@{@"threadId": _selID, @"messages": messages}
            deliverImmediately:YES];
}

- (void)showErrorCard:(NSString *)msg {
    self.resultCard.hidden = NO;
    self.resultCard.backgroundColor = [UIColor systemOrangeColor];
    self.resultLabel.textColor = [UIColor whiteColor];
    self.resultLabel.text = msg;
}

- (void)showInjectResult:(NSString *)text {
    NSRange r = [text rangeOfString:@"@@MIRESULT|"];
    if (r.location == NSNotFound) {
        [self showErrorCard:@"\u274C Unexpected result \u2014 tap Copy output below result for details."];
        self.resultCard.backgroundColor = [UIColor secondarySystemBackgroundColor];
        self.resultLabel.textColor = [UIColor labelColor];
        self.resultLabel.text = [NSString stringWithFormat:@"[inject]\n%@", text];
        return;
    }
    NSRange end = [text rangeOfString:@"|@@" options:0 range:NSMakeRange(r.location, text.length - r.location)];
    if (end.location == NSNotFound) { [self showErrorCard:@"\u26A0\uFE0F Got a result but couldn't parse it."]; return; }
    NSString *line = [text substringWithRange:NSMakeRange(r.location + 11, end.location - r.location - 11)];
    NSMutableDictionary *kv = [NSMutableDictionary dictionary];
    for (NSString *part in [line componentsSeparatedByString:@"|"]) {
        NSArray *kp = [part componentsSeparatedByString:@"="];
        if (kp.count >= 2) kv[kp[0]] = [[kp subarrayWithRange:NSMakeRange(1, kp.count - 1)] componentsJoinedByString:@"="];
    }
    self.resultCard.hidden = NO;
    BOOL ok = [kv[@"ok"] intValue] == 1;
    NSString *method = kv[@"method"] ?: @"";
    NSString *n = kv[@"inserted"] ?: @"0";
    if (!ok) {
        self.resultCard.backgroundColor = [UIColor systemRedColor];
        self.resultLabel.textColor = [UIColor whiteColor];
        NSString *reason = kv[@"reason"] ?: @"";
        if ([reason containsString:@"entity_id_mismatch"]) {
            self.resultLabel.text = @"\U0001F6D1 Refused: resolved chat belongs to a DIFFERENT person (safety gate). Try Advanced \u2192 Research mapping.";
        } else if ([reason containsString:@"name_not_found"]) {
            self.resultLabel.text = @"\U0001F6D1 Couldn't resolve that name to a contact.";
        } else {
            self.resultLabel.text = [NSString stringWithFormat:@"\u274C Inject failed (%@ errors). Tap Copy output for details.", kv[@"errors"] ?: @"?"];
        }
    } else if ([method containsString:@"LAST_RESORT"]) {
        self.resultCard.backgroundColor = [UIColor systemOrangeColor];
        self.resultLabel.textColor = [UIColor whiteColor];
        self.resultLabel.text = [NSString stringWithFormat:@"\u26A0\uFE0F Wrote %@ message(s), but the exact chat was NOT found \u2014 they may be in the wrong chat.", n];
    } else {
        self.resultCard.backgroundColor = [UIColor systemGreenColor];
        self.resultLabel.textColor = [UIColor whiteColor];
        self.resultLabel.text = [NSString stringWithFormat:@"\u2705 Wrote %@ message%@ to \"%@\".\nForce-quit Messenger (swipe away), reopen, then check the chat.", n, [n isEqualToString:@"1"] ? @"" : @"s", _selName ?: @""];
    }
    _injectPending = NO;
}

// ============================================================
// Debug actions
// ============================================================
- (void)toggleDebugTapped {
    self.debugStack.hidden = !self.debugStack.hidden;
    [self.debugToggleBtn setTitle:self.debugStack.hidden ? @"\u2699\uFE0F  Advanced / debug" : @"\u2716  Close advanced" forState:UIControlStateNormal];
}

- (void)postDebug:(NSString *)notif label:(NSString *)label {
    [self.view endEditing:YES];
    self.resultCard.hidden = NO;
    self.resultCard.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.resultLabel.textColor = [UIColor labelColor];
    self.resultLabel.text = [NSString stringWithFormat:@"%@...", label];
    [[NSDistributedNotificationCenter defaultCenter] postNotificationName:notif object:nil userInfo:@{} deliverImmediately:YES];
}

- (void)rescanTapped {
    _dbLoaded = NO;
    self.statusLabel.text = @"\u23F3 Re-reading Messenger database...";
    self.statusLabel.backgroundColor = [UIColor systemTealColor];
    [[NSDistributedNotificationCenter defaultCenter] postNotificationName:kNotifyThreads object:nil userInfo:@{} deliverImmediately:YES];
}

- (void)findDBTapped { [self postDebug:kNotifyFindDB label:@"Finding database"]; }
- (void)dumpSchemaTapped { [self postDebug:kNotifySchema label:@"Dumping schema"]; }
- (void)dumpSampleTapped { [self postDebug:kNotifySample label:@"Dumping sample data"]; }
- (void)crashTapped { [self postDebug:kNotifyCrash label:@"Fetching crash log"]; }
- (void)listFilesTapped { [self postDebug:kNotifyListFiles label:@"Listing files"]; }
- (void)dumpViewTapped { [self postDebug:kNotifyDumpView label:@"Dumping view hierarchy"]; }

- (void)researchTapped {
    [self.view endEditing:YES];
    NSString *tid = _selID ?: @"";
    self.resultCard.hidden = NO;
    self.resultCard.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.resultLabel.textColor = [UIColor labelColor];
    self.resultLabel.text = @"\U0001F52C Researching mapping (a few seconds)...";
    [[NSDistributedNotificationCenter defaultCenter]
        postNotificationName:kNotifyResearch object:nil userInfo:@{@"threadId": tid, @"mode": @"map"} deliverImmediately:YES];
}

- (void)researchSqlTapped {
    [self.view endEditing:YES];
    self.resultCard.hidden = NO;
    self.resultCard.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.resultLabel.textColor = [UIColor labelColor];
    self.resultLabel.text = @"\U0001F4DC Reading app SQL logic...";
    [[NSDistributedNotificationCenter defaultCenter]
        postNotificationName:kNotifyResearch object:nil userInfo:@{@"threadId": @"", @"mode": @"sql"} deliverImmediately:YES];
}

- (void)copyOutputTapped {
    [UIPasteboard generalPasteboard].string = _resultText;
    [self.outputCopyBtn setTitle:@"\u2705 Copied!" forState:UIControlStateNormal];
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        typeof(self) strongSelf = weakSelf;
        if (strongSelf) [strongSelf.outputCopyBtn setTitle:@"\U0001F4CB  Copy output" forState:UIControlStateNormal];
    });
}

// ============================================================
// Keyboard
// ============================================================
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
