/**
 * MIHelper v1.2 — Trigger app for MessengerInjector
 *
 * v1.2: Results display panel — shows dylib output on screen.
 *       Listen for com.messenger.injector.result notifications.
 *
 * Build:
 *   xcrun clang -arch arm64 \
 *     -isysroot $(xcrun --sdk iphoneos --show-sdk-path) \
 *     -miphoneos-version-min=15.0 \
 *     -framework Foundation -framework UIKit \
 *     -ObjC -fobjc-arc -O2 \
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
static NSString *const kNotifyFindDB     = @"com.messenger.injector.findDB";
static NSString *const kNotifyDumpSchema = @"com.messenger.injector.dumpSchema";
static NSString *const kNotifyDumpSample = @"com.messenger.injector.dumpSample";
static NSString *const kNotifyResult     = @"com.messenger.injector.result";

// ============================================================
// View controller
// ============================================================
@interface MIHelperVC : UIViewController <UITextFieldDelegate>
@property (nonatomic, strong) UITextField *threadField;
@property (nonatomic, strong) UITextField *messageField;
@property (nonatomic, strong) UISwitch *groupSwitch;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UITextView *resultsView;
@property (nonatomic, strong) UIButton *copyButton;
@property (nonatomic, copy) NSString *latestResult;
@end

@implementation MIHelperVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.title = @"MI Helper v1.2";
    self.latestResult = @"";

    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.showsVerticalScrollIndicator = YES;
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

    // --- Send Message ---
    UILabel *sendSec = [self sec:@"Send Message (UI Automation)"];
    self.threadField = [self makeField:@"Thread ID (user_id or group fbId)" UIKeyboardType:UIKeyboardTypeNumberPad];
    self.messageField = [self makeField:@"Message to send" UIKeyboardType:UIKeyboardTypeDefault];

    UIView *groupRow = [[UIView alloc] init];
    groupRow.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel *gL = [[UILabel alloc] init];
    gL.text = @"Group chat";
    gL.font = [UIFont systemFontOfSize:14];
    gL.translatesAutoresizingMaskIntoConstraints = NO;
    self.groupSwitch = [[UISwitch alloc] init];
    self.groupSwitch.translatesAutoresizingMaskIntoConstraints = NO;
    [self.groupSwitch addTarget:self action:@selector(groupToggled:) forControlEvents:UIControlEventValueChanged];
    [groupRow addSubview:gL];
    [groupRow addSubview:self.groupSwitch];
    [NSLayoutConstraint activateConstraints:@[
        [gL.leadingAnchor constraintEqualToAnchor:groupRow.leadingAnchor],
        [gL.centerYAnchor constraintEqualToAnchor:groupRow.centerYAnchor],
        [self.groupSwitch.trailingAnchor constraintEqualToAnchor:groupRow.trailingAnchor],
        [self.groupSwitch.centerYAnchor constraintEqualToAnchor:groupRow.centerYAnchor],
        [groupRow.heightAnchor constraintEqualToConstant:30],
    ]];

    UIButton *sendBtn = [self makeBtn:@"Send Message" bg:[UIColor systemBlueColor] act:@selector(sendTapped) h:44];

    // --- Debug ---
    UILabel *dbgSec = [self sec:@"Debug & Schema Dump"];
    UIButton *findDBBtn   = [self makeBtn:@"Find Database"     bg:[UIColor secondarySystemBackgroundColor] act:@selector(findDBTapped)   h:40];
    UIButton *schemaBtn   = [self makeBtn:@"Dump DB Schema"    bg:[UIColor systemOrangeColor] act:@selector(dumpSchemaTapped) h:40];
    UIButton *sampleBtn   = [self makeBtn:@"Dump Sample Data"  bg:[UIColor systemOrangeColor] act:@selector(dumpSampleTapped) h:40];
    UIButton *dumpViewBtn = [self makeBtn:@"Dump View Hierarchy" bg:[UIColor secondarySystemBackgroundColor] act:@selector(dumpViewTapped) h:40];

    // --- Results ---
    UILabel *resSec = [self sec:@"Results"];
    self.resultsView = [[UITextView alloc] init];
    self.resultsView.editable = NO;
    self.resultsView.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    self.resultsView.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.resultsView.layer.cornerRadius = 8;
    self.resultsView.text = @"Tap a button above, results appear here.";
    self.resultsView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.resultsView.heightAnchor constraintEqualToConstant:200].active = YES;

    self.copyButton = [self makeBtn:@"Copy Results" bg:[UIColor systemGreenColor] act:@selector(copyTapped) h:36];

    [stack addArrangedSubview:title];
    [stack addArrangedSubview:self.statusLabel];
    [stack addArrangedSubview:sendSec];
    [stack addArrangedSubview:self.threadField];
    [stack addArrangedSubview:self.messageField];
    [stack addArrangedSubview:groupRow];
    [stack addArrangedSubview:sendBtn];
    [stack addArrangedSubview:dbgSec];
    [stack addArrangedSubview:findDBBtn];
    [stack addArrangedSubview:schemaBtn];
    [stack addArrangedSubview:sampleBtn];
    [stack addArrangedSubview:dumpViewBtn];
    [stack addArrangedSubview:resSec];
    [stack addArrangedSubview:self.resultsView];
    [stack addArrangedSubview:self.copyButton];

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
                self.latestResult = [NSString stringWithFormat:@"[%@]\n%@", tag, text];
                self.resultsView.text = self.latestResult;
                [self.resultsView scrollRangeToVisible:NSMakeRange(0, 0)];
            });
        }];
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

// --- Actions ---
- (void)sendTapped {
    [self.view endEditing:YES];
    NSString *tid = self.threadField.text ?: @"";
    NSString *msg = self.messageField.text ?: @"";
    if (tid.length == 0) { [self flash:@"Enter thread ID" red:YES]; return; }
    if (msg.length == 0)  { [self flash:@"Enter message" red:YES]; return; }
    [[NSDistributedNotificationCenter defaultCenter]
        postNotificationName:kNotifySend
                      object:nil
                    userInfo:@{@"message": msg, @"threadId": tid, @"isGroup": @(self.groupSwitch.isOn)}
            deliverImmediately:YES];
    [self flash:[NSString stringWithFormat:@"\U0001F851 send: thread=%@", tid] red:NO];
    self.messageField.text = @"";
}

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
        postNotificationName:kNotifyDumpSchema object:nil userInfo:@{} deliverImmediately:YES];
    [self flash:@"\U0001F851 dumpSchema" red:NO];
}

- (void)dumpSampleTapped {
    [self.view endEditing:YES];
    self.resultsView.text = @"Dumping sample data... (may take a few seconds)";
    [[NSDistributedNotificationCenter defaultCenter]
        postNotificationName:kNotifyDumpSample object:nil userInfo:@{} deliverImmediately:YES];
    [self flash:@"\U0001F851 dumpSample" red:NO];
}

- (void)dumpViewTapped {
    [self.view endEditing:YES];
    self.resultsView.text = @"Dumping view hierarchy...";
    [[NSDistributedNotificationCenter defaultCenter]
        postNotificationName:kNotifyDump object:nil userInfo:@{} deliverImmediately:YES];
    [self flash:@"\U0001F851 dumpView" red:NO];
}

- (void)copyTapped {
    if (self.latestResult.length == 0) { [self flash:@"Nothing to copy" red:YES]; return; }
    [UIPasteboard generalPasteboard].string = self.latestResult;
    [self flash:@"\u2705 Copied to clipboard" red:NO];
}

- (void)groupToggled:(UISwitch *)sw {
    self.threadField.placeholder = sw.isOn ? @"Group thread fbId" : @"User ID (1-on-1)";
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