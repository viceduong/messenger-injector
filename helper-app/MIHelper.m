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
static NSString *const kNotifySniff   = @"com.messenger.injector.sniff";
static NSString *const kNotifyDeepScan = @"com.messenger.injector.deepscan";
static NSString *const kNotifyThreadRow = @"com.messenger.injector.threadrow";
static NSString *const kNotifyCrash   = @"com.messenger.injector.crashLog";
static NSString *const kNotifyListFiles = @"com.messenger.injector.listFiles";
static NSString *const kNotifyDumpView  = @"com.messenger.injector.dump";
static NSString *const kNotifyClasses  = @"com.messenger.injector.classes";
static NSString *const kNotifyProtect = @"com.messenger.injector.protect";
static NSString *const kNotifyUnprotect = @"com.messenger.injector.unprotect";
static NSString *const kNotifyRepair  = @"com.messenger.injector.repair";
static NSString *const kNotifyRestore = @"com.messenger.injector.restore";
static NSString *const kNotifyMark    = @"com.messenger.injector.mark";
static NSString *const kNotifyIvars   = @"com.messenger.injector.ivars";

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
@property (nonatomic, strong) UITextField *needleField;
@property (nonatomic, strong) UIToolbar *kbToolbar;
@property (nonatomic, strong) UIButton *hideKbFloatBtn;
@property (nonatomic, copy) NSString *selID;
@property (nonatomic, copy) NSString *selName;
@end

@implementation MIHelperVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.title = @"MIHelper";
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
    self.statusLabel.text = @"\U000023F3 Reading Messenger database... (open Messenger once)";
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
    UILabel *s2 = [self stepLabel:@"2.  Entries"];
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
    prevLabel.text = @"Preview:";
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
    UILabel *s3 = [self stepLabel:@"3.  Apply"];
    self.injectBtn = [self makeBtn:@"Apply" bg:[UIColor systemBlueColor] act:@selector(injectTapped) h:56];
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
    self.debugToggleBtn = [self makeBtn:@"\u2699\uFE0F  Advanced" bg:[UIColor secondarySystemBackgroundColor] act:@selector(toggleDebugTapped) h:40];
    self.debugToggleBtn.titleLabel.font = [UIFont systemFontOfSize:13];

    self.debugStack = [[UIStackView alloc] init];
    self.debugStack.axis = UILayoutConstraintAxisVertical;
    self.debugStack.spacing = 8;
    self.debugStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.debugStack.hidden = YES;

    UIButton *rescanBtn = [self makeBtn:@"\U0001F504  Refresh" bg:[UIColor systemTealColor] act:@selector(rescanTapped) h:40];
    UIButton *researchBtn = [self makeBtn:@"\U0001F52C  Lookup info" bg:[UIColor systemIndigoColor] act:@selector(researchTapped) h:40];
    UIButton *sqlBtn = [self makeBtn:@"\U0001F4DC  Inspect data" bg:[UIColor systemIndigoColor] act:@selector(researchSqlTapped) h:40];
    UIButton *diagBtn = [self makeBtn:@"\U0001F4CA  Diagnostics" bg:[UIColor systemIndigoColor] act:@selector(diagnosticsTapped) h:40];
    diagBtn.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    UIButton *restoreBtn = [self makeBtn:@"\u267B\uFE0F  Restore history (server replay)" bg:[UIColor systemTealColor] act:@selector(restoreHistoryTapped) h:40];
    restoreBtn.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    UIButton *protectBtn = [self makeBtn:@"\U0001F6E1\uFE0F  Protect preview (anti-sync)" bg:[UIColor systemGreenColor] act:@selector(protectTapped) h:40];
    protectBtn.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    UIButton *unprotectBtn = [self makeBtn:@"\U0001F513  Remove protection" bg:[UIColor systemOrangeColor] act:@selector(unprotectTapped) h:40];
    unprotectBtn.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    UIButton *sniffBtn = [self makeBtn:@"\U0001F50E  Scan cache" bg:[UIColor systemIndigoColor] act:@selector(sniffTapped) h:40];
    sniffBtn.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    self.needleField = [[UITextField alloc] init];
    self.needleField.placeholder = @"Text currently shown in list";
    self.needleField.borderStyle = UITextBorderStyleRoundedRect;
    self.needleField.font = [UIFont systemFontOfSize:13];
    self.needleField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.needleField.translatesAutoresizingMaskIntoConstraints = NO;
    self.needleField.inputAccessoryView = self.kbToolbar;
    UIButton *deepBtn = [self makeBtn:@"\U0001F4BE  Scan storage" bg:[UIColor systemIndigoColor] act:@selector(deepScanTapped) h:40];
    deepBtn.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    UIButton *trowBtn = [self makeBtn:@"\U0001F5A5\uFE0F  Sync header" bg:[UIColor systemIndigoColor] act:@selector(threadRowTapped) h:40];
    trowBtn.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    researchBtn.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    sqlBtn.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    UIButton *findDBBtn = [self makeBtn:@"Locate storage" bg:[UIColor secondarySystemBackgroundColor] act:@selector(findDBTapped) h:40];
    UIButton *schemaBtn = [self makeBtn:@"Storage structure" bg:[UIColor systemOrangeColor] act:@selector(dumpSchemaTapped) h:40];
    UIButton *sampleBtn = [self makeBtn:@"Sample export" bg:[UIColor systemOrangeColor] act:@selector(dumpSampleTapped) h:40];
    UIButton *crashBtn = [self makeBtn:@"Error reports" bg:[UIColor systemRedColor] act:@selector(crashTapped) h:40];
    UIButton *listBtn = [self makeBtn:@"File list" bg:[UIColor systemPurpleColor] act:@selector(listFilesTapped) h:40];
    UIButton *dumpViewBtn = [self makeBtn:@"UI tree" bg:[UIColor secondarySystemBackgroundColor] act:@selector(dumpViewTapped) h:40];
    [self.debugStack addArrangedSubview:rescanBtn];
    [self.debugStack addArrangedSubview:researchBtn];
    [self.debugStack addArrangedSubview:sqlBtn];
    [self.debugStack addArrangedSubview:diagBtn];
    [self.debugStack addArrangedSubview:restoreBtn];
    [self.debugStack addArrangedSubview:protectBtn];
    [self.debugStack addArrangedSubview:unprotectBtn];
    [self.debugStack addArrangedSubview:sniffBtn];
    [self.debugStack addArrangedSubview:self.needleField];
    [self.debugStack addArrangedSubview:trowBtn];
    [self.debugStack addArrangedSubview:deepBtn];
    [self.debugStack addArrangedSubview:findDBBtn];
    [self.debugStack addArrangedSubview:schemaBtn];
    [self.debugStack addArrangedSubview:sampleBtn];
    [self.debugStack addArrangedSubview:crashBtn];
    [self.debugStack addArrangedSubview:listBtn];
    [self.debugStack addArrangedSubview:dumpViewBtn];

    // ---------- assemble ----------
    [stack addArrangedSubview:self.statusLabel];
    // ---------- How-to card ----------
    UITextView *howto = [[UITextView alloc] init];
    howto.editable = NO;
    howto.scrollEnabled = NO;
    howto.font = [UIFont systemFontOfSize:12.5];
    howto.textColor = [UIColor secondaryLabelColor];
    howto.backgroundColor = [UIColor secondarySystemBackgroundColor];
    howto.layer.cornerRadius = 10;
    howto.text = @"BEST RESULTS - follow exactly:\n\n1. TrollFools: inject dylib (kills Messenger)\n2. Open Messenger, wait 3s, inject here IMMEDIATELY\n   (before sync finishes = preview sticks longest)\n3. Pick person, write messages, APPLY\n4. Check the list now - your text shows\n\nPREVIEW PERSISTS while a chat stays quiet.\nIt reverts when that chat gets server activity\n(new msgs/receipts). Archive the chat to keep\nit indefinitely. Re-inject anytime to refresh.";
    howto.translatesAutoresizingMaskIntoConstraints = NO;
    [stack addArrangedSubview:self.statusLabel];
    [stack addArrangedSubview:howto];
    [stack addArrangedSubview:self.searchField];
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

    // Save/Load template row
    UIStackView *tplRow = [[UIStackView alloc] init];
    tplRow.axis = UILayoutConstraintAxisHorizontal;
    tplRow.spacing = 8;
    UIButton *saveTplBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [saveTplBtn setTitle:@"\U0001F4BE  Save" forState:UIControlStateNormal];
    saveTplBtn.titleLabel.font = [UIFont systemFontOfSize:13];
    [saveTplBtn addTarget:self action:@selector(saveTemplateTapped) forControlEvents:UIControlEventTouchUpInside];
    saveTplBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [saveTplBtn.heightAnchor constraintEqualToConstant:36].active = YES;
    UIButton *loadTplBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [loadTplBtn setTitle:@"\U0001F4C2  Load" forState:UIControlStateNormal];
    loadTplBtn.titleLabel.font = [UIFont systemFontOfSize:13];
    [loadTplBtn addTarget:self action:@selector(loadTemplateTapped) forControlEvents:UIControlEventTouchUpInside];
    loadTplBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [loadTplBtn.heightAnchor constraintEqualToConstant:36].active = YES;
    [tplRow addArrangedSubview:saveTplBtn];
    [tplRow addArrangedSubview:loadTplBtn];
    [stack addArrangedSubview:tplRow];
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
    [[UIPasteboard generalPasteboard] setString:_resultText]; // zero-tap copy
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
    self.statusLabel.text = @"\u23F3 Applying...";
    self.statusLabel.backgroundColor = [UIColor systemBlueColor];
    self.resultCard.hidden = YES;
    _injectPending = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(45 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        typeof(self) strongSelf = weakSelf;
        if (strongSelf && strongSelf->_injectPending) {
            strongSelf->_injectPending = NO;
            strongSelf.statusLabel.text = @"\u26A0\uFE0F No response \u2014 open Messenger once, then retry.";
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
            self.resultLabel.text = @"\U0001F6D1 Refused: resolved chat belongs to a DIFFERENT person (safety gate). Try Advanced \u2192 Lookup info.";
        } else if ([reason containsString:@"name_not_found"]) {
            self.resultLabel.text = @"\U0001F6D1 Couldn't resolve that name to a contact.";
        } else {
            self.resultLabel.text = [NSString stringWithFormat:@"\u274C Apply failed (%@ errors). Tap Copy output for details.", kv[@"errors"] ?: @"?"];
        }
    } else if ([method containsString:@"LAST_RESORT"]) {
        self.resultCard.backgroundColor = [UIColor systemOrangeColor];
        self.resultLabel.textColor = [UIColor whiteColor];
        self.resultLabel.text = [NSString stringWithFormat:@"\u26A0\uFE0F Wrote %@ message(s), but the exact chat was NOT found \u2014 they may be in the wrong chat.", n];
        self.statusLabel.text = @"\u26A0\uFE0F Done with warnings";
        self.statusLabel.backgroundColor = [UIColor systemOrangeColor];
    } else {
        self.resultCard.backgroundColor = [UIColor systemGreenColor];
        self.resultLabel.textColor = [UIColor whiteColor];
        self.resultLabel.text = [NSString stringWithFormat:@"\u2705 Done (%@). Reopen Messenger to view.", n];
    self.statusLabel.text = [NSString stringWithFormat:@"\u2705 Done (%@)", n];
    self.statusLabel.backgroundColor = [UIColor systemGreenColor];
    }
    _injectPending = NO;
}

// ============================================================
// Debug actions
// ============================================================
- (void)toggleDebugTapped {
    self.debugStack.hidden = !self.debugStack.hidden;
    [self.debugToggleBtn setTitle:self.debugStack.hidden ? @"\u2699\uFE0F  Advanced" : @"\u2716  Close" forState:UIControlStateNormal];
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

- (void)sniffTapped {
    [self.view endEditing:YES];
    NSString *tid = _selID ?: @"";
    self.resultCard.hidden = NO;
    self.resultCard.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.resultLabel.textColor = [UIColor labelColor];
    self.resultLabel.text = @"\U0001F50E Sniffing all snippet sources...";
    [[NSDistributedNotificationCenter defaultCenter]
        postNotificationName:kNotifySniff object:nil userInfo:@{@"threadId": tid} deliverImmediately:YES];
}

- (void)sendProtect:(BOOL)arm {
    [self.view endEditing:YES];
    NSString *tid = _selID ?: @"";
    self.resultCard.hidden = NO;
    self.resultCard.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.resultLabel.textColor = [UIColor labelColor];
    self.resultLabel.text = arm ? @"\U0001F6E1\uFE0F Arming protection..." : @"Removing protection...";
    [[NSDistributedNotificationCenter defaultCenter]
        postNotificationName:arm ? kNotifyProtect : kNotifyUnprotect
        object:nil userInfo:@{@"threadId": tid} deliverImmediately:YES];
}

- (void)protectTapped { [self sendProtect:YES]; }
- (void)unprotectTapped { [self sendProtect:NO]; }

- (void)diagnosticsTapped {
    [self.view endEditing:YES];
    self.resultCard.hidden = NO;
    self.resultCard.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.resultLabel.textColor = [UIColor labelColor];
    self.resultLabel.text = @"\U0001F4CA Collecting diagnostics... open the chat list first if cache not captured";
    [[NSDistributedNotificationCenter defaultCenter]
        postNotificationName:kNotifyClasses object:nil userInfo:@{} deliverImmediately:YES];
}

- (void)repairRowTapped {
    [self.view endEditing:YES];
    NSString *tid = _selID ?: @"";
    self.resultCard.hidden = NO;
    self.resultCard.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.resultLabel.textColor = [UIColor labelColor];
    self.resultLabel.text = @"Repairing...";
    [[NSDistributedNotificationCenter defaultCenter]
        postNotificationName:kNotifyRepair object:nil userInfo:@{@"threadId": tid} deliverImmediately:YES];
}

- (void)restoreHistoryTapped {
    [self.view endEditing:YES];
    NSString *tid = _selID ?: @"";
    self.resultCard.hidden = NO;
    self.resultCard.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.resultLabel.textColor = [UIColor labelColor];
    self.resultLabel.text = @"\u267B\uFE0F Clearing sync ranges... then reopen Messenger on WiFi";
    [[NSDistributedNotificationCenter defaultCenter]
        postNotificationName:kNotifyRestore object:nil userInfo:@{@"threadId": tid} deliverImmediately:YES];
}

- (void)flash:(NSString *)msg red:(BOOL)isRed {
    self.resultCard.hidden = NO;
    self.resultCard.backgroundColor = isRed ? [UIColor systemRedColor] : [UIColor systemGreenColor];
    self.resultLabel.textColor = [UIColor whiteColor];
    self.resultLabel.text = msg;
}

- (NSString *)templateFilePath {
    return [NSTemporaryDirectory() stringByAppendingPathComponent:@"mi_template.json"];
}

- (void)saveTemplateTapped {
    NSMutableArray *arr = [NSMutableArray array];
    for (MIMessageRow *row in self.messageRows) {
        NSString *t = [row.textField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (t.length == 0) continue;
        [arr addObject:@{@"s": row.isMe ? @"me" : @"them", @"t": t, @"m": row.minAgoField.text ?: @"0"}];
    }
    if (arr.count == 0) { [self flash:@"\u26A0\uFE0F Nothing to save" red:YES]; return; }
    NSData *data = [NSJSONSerialization dataWithJSONObject:arr options:NSJSONWritingPrettyPrinted error:nil];
    [data writeToFile:[self templateFilePath] atomically:YES];
    [self flash:@"\u2705 Template saved" red:NO];
}

- (void)loadTemplateTapped {
    NSString *path = [self templateFilePath];
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) { [self flash:@"\u26A0\uFE0F No saved template" red:YES]; return; }
    NSArray *arr = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![arr isKindOfClass:[NSArray class]] || arr.count == 0) { [self flash:@"\u26A0\uFE0F Empty" red:YES]; return; }

    for (MIMessageRow *row in self.messageRows) {
        [self.messageStack removeArrangedSubview:row];
        [row removeFromSuperview];
    }
    [self.messageRows removeAllObjects];

    for (NSDictionary *d in arr) {
        MIMessageRow *row = [[MIMessageRow alloc] init];
        BOOL isMe = [d[@"s"] isEqualToString:@"me"];
        row.isMe = isMe;
        row.sideControl.selectedSegmentIndex = isMe ? 0 : 1;
        row.textField.text = d[@"t"] ?: @"";
        row.minAgoField.text = [d[@"m"] stringValue] ?: @"0";
        __weak typeof(self) weakSelf = self;
        row.onChanged = ^{ [weakSelf refreshPreview]; };
        row.onDelete = ^(MIMessageRow *r) { [weakSelf removeMessageRow:r]; };
        [self.messageRows addObject:row];
        [self.messageStack addArrangedSubview:row];
        row.textField.inputAccessoryView = self.kbToolbar;
        row.minAgoField.inputAccessoryView = self.kbToolbar;
    }
    [self refreshPreview];
    [self flash:@"\u2705 Loaded" red:NO];
}

- (void)deepScanTapped {
    [self.view endEditing:YES];
    NSString *needle = [self.needleField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (needle.length < 3) {
        self.resultCard.hidden = NO;
        self.resultCard.backgroundColor = [UIColor systemOrangeColor];
        self.resultLabel.textColor = [UIColor whiteColor];
        self.resultLabel.text = @"Type the exact text the list shows first.";
        return;
    }
    self.resultCard.hidden = NO;
    self.resultCard.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.resultLabel.textColor = [UIColor labelColor];
    self.resultLabel.text = @"\U0001F4BE Scanning storage (up to a minute)...";
    [[NSDistributedNotificationCenter defaultCenter]
        postNotificationName:kNotifyDeepScan object:nil userInfo:@{@"text": needle} deliverImmediately:YES];
}

- (void)threadRowTapped {
    [self.view endEditing:YES];
    NSString *tid = _selID ?: @"";
    if (tid.length == 0) {
        self.resultCard.hidden = NO;
        self.resultCard.backgroundColor = [UIColor systemOrangeColor];
        self.resultLabel.textColor = [UIColor whiteColor];
        self.resultLabel.text = @"Pick a person first.";
        return;
    }
    self.resultCard.hidden = NO;
    self.resultCard.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.resultLabel.textColor = [UIColor labelColor];
    self.resultLabel.text = @"Syncing header...";
    [[NSDistributedNotificationCenter defaultCenter]
        postNotificationName:kNotifyThreadRow object:nil userInfo:@{@"threadId": tid} deliverImmediately:YES];
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
