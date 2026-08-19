/**
 * MIHelper v1.1 — Trigger app for MessengerInjector
 *
 * Posts NSDistributedNotifications to trigger the dylib inside Messenger.
 * v1.1 adds: FindDB, Dump Schema, Dump Sample buttons.
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

// ============================================================
// View controller
// ============================================================
@interface MIHelperVC : UIViewController <UITextFieldDelegate>
@property (nonatomic, strong) UITextField *threadField;
@property (nonatomic, strong) UITextField *messageField;
@property (nonatomic, strong) UISwitch *groupSwitch;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIButton *sendButton;
@property (nonatomic, strong) UIButton *dumpViewButton;
@property (nonatomic, strong) UIButton *findDBButton;
@property (nonatomic, strong) UIButton *dumpSchemaButton;
@property (nonatomic, strong) UIButton *dumpSampleButton;
@end

@implementation MIHelperVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.title = @"MI Helper v1.1";

    UILabel *title = [[UILabel alloc] init];
    title.text = @"Messenger Injector";
    title.font = [UIFont systemFontOfSize:26 weight:UIFontWeightBold];
    title.textAlignment = NSTextAlignmentCenter;
    title.translatesAutoresizingMaskIntoConstraints = NO;

    // --- Section: Send Message (v1.0) ---
    UILabel *sendSection = [self sectionLabel:@"Send Message (UI Automation)"];

    self.threadField = [[UITextField alloc] init];
    self.threadField.placeholder = @"Thread ID (user_id or group fbId)";
    self.threadField.borderStyle = UITextBorderStyleRoundedRect;
    self.threadField.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
    self.threadField.keyboardType = UIKeyboardTypeNumberPad;
    self.threadField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.threadField.delegate = self;
    self.threadField.translatesAutoresizingMaskIntoConstraints = NO;

    self.messageField = [[UITextField alloc] init];
    self.messageField.placeholder = @"Message to send";
    self.messageField.borderStyle = UITextBorderStyleRoundedRect;
    self.messageField.font = [UIFont systemFontOfSize:15];
    self.messageField.delegate = self;
    self.messageField.translatesAutoresizingMaskIntoConstraints = NO;

    UIView *groupRow = [[UIView alloc] init];
    groupRow.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel *groupLabel = [[UILabel alloc] init];
    groupLabel.text = @"Group chat";
    groupLabel.font = [UIFont systemFontOfSize:14];
    groupLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.groupSwitch = [[UISwitch alloc] init];
    self.groupSwitch.translatesAutoresizingMaskIntoConstraints = NO;
    [self.groupSwitch addTarget:self action:@selector(groupToggled:) forControlEvents:UIControlEventValueChanged];
    [groupRow addSubview:groupLabel];
    [groupRow addSubview:self.groupSwitch];
    [NSLayoutConstraint activateConstraints:@[
        [groupLabel.leadingAnchor constraintEqualToAnchor:groupRow.leadingAnchor],
        [groupLabel.centerYAnchor constraintEqualToAnchor:groupRow.centerYAnchor],
        [self.groupSwitch.trailingAnchor constraintEqualToAnchor:groupRow.trailingAnchor],
        [self.groupSwitch.centerYAnchor constraintEqualToAnchor:groupRow.centerYAnchor],
        [groupRow.heightAnchor constraintEqualToConstant:30],
    ]];

    self.sendButton = [self makeButton:@"Send Message" color:[UIColor systemBlueColor] action:@selector(sendTapped)];

    // --- Section: Debug / Schema (v1.1) ---
    UILabel *debugSection = [self sectionLabel:@"Debug & Schema Dump"];

    self.dumpViewButton = [self makeButton:@"Dump View Hierarchy" color:[UIColor secondarySystemBackgroundColor] action:@selector(dumpViewTapped)];
    self.findDBButton   = [self makeButton:@"Find Database"       color:[UIColor secondarySystemBackgroundColor] action:@selector(findDBTapped)];
    self.dumpSchemaButton = [self makeButton:@"Dump DB Schema"    color:[UIColor systemOrangeColor] action:@selector(dumpSchemaTapped)];
    self.dumpSampleButton = [self makeButton:@"Dump Sample Data"  color:[UIColor systemOrangeColor] action:@selector(dumpSampleTapped)];

    // Status
    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.text = @"Waiting for dylib...";
    self.statusLabel.font = [UIFont systemFontOfSize:12];
    self.statusLabel.textColor = [UIColor secondaryLabelColor];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.numberOfLines = 0;
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;

    // Layout
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        title,
        sendSection,
        self.threadField,
        self.messageField,
        groupRow,
        self.sendButton,
        debugSection,
        self.dumpViewButton,
        self.findDBButton,
        self.dumpSchemaButton,
        self.dumpSampleButton,
        self.statusLabel
    ]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 10;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [stack.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [stack.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20],
        [stack.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20],
        [self.sendButton.heightAnchor constraintEqualToConstant:46],
        [self.dumpViewButton.heightAnchor constraintEqualToConstant:40],
        [self.findDBButton.heightAnchor constraintEqualToConstant:40],
        [self.dumpSchemaButton.heightAnchor constraintEqualToConstant:40],
        [self.dumpSampleButton.heightAnchor constraintEqualToConstant:40],
    ]];

    // Listen for dylib ready
    [[NSDistributedNotificationCenter defaultCenter]
        addObserverForName:kNotifyReady
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
            dispatch_async(dispatch_get_main_queue(), ^{
                NSString *ver = note.userInfo[@"version"] ?: @"?";
                self.statusLabel.text = [NSString stringWithFormat:@"\u{1F7E2} Dylib v%@ ready", ver];
                self.statusLabel.textColor = [UIColor systemGreenColor];
            });
        }];
}

// --- Helpers ---
- (UILabel *)sectionLabel:(NSString *)text {
    UILabel *l = [[UILabel alloc] init];
    l.text = text;
    l.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    l.textColor = [UIColor tertiaryLabelColor];
    l.translatesAutoresizingMaskIntoConstraints = NO;
    return l;
}

- (UIButton *)makeButton:(NSString *)title color:(UIColor *)bg action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    b.backgroundColor = bg;
    [b setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
    b.layer.cornerRadius = 8;
    b.translatesAutoresizingMaskIntoConstraints = NO;
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

// --- Actions ---
- (void)sendTapped {
    [self.view endEditing:YES];
    NSString *threadId = self.threadField.text ?: @"";
    NSString *message  = self.messageField.text ?: @"";
    if (threadId.length == 0) { [self flash:@"Enter thread ID" red:YES]; return; }
    if (message.length == 0)  { [self flash:@"Enter message" red:YES]; return; }

    [[NSDistributedNotificationCenter defaultCenter]
        postNotificationName:kNotifySend
                      object:nil
                    userInfo:@{@"message": message, @"threadId": threadId, @"isGroup": @(self.groupSwitch.isOn)}
            deliverImmediately:YES];
    [self flash:[NSString stringWithFormat:@"\u{2192} send: thread=%@", threadId] red:NO];
    self.messageField.text = @"";
}

- (void)dumpViewTapped {
    [self.view endEditing:YES];
    [[NSDistributedNotificationCenter defaultCenter] postNotificationName:kNotifyDump object:nil userInfo:@{} deliverImmediately:YES];
    [self flash:@"\u{2192} dump view hierarchy" red:NO];
}

- (void)findDBTapped {
    [self.view endEditing:YES];
    [[NSDistributedNotificationCenter defaultCenter] postNotificationName:kNotifyFindDB object:nil userInfo:@{} deliverImmediately:YES];
    [self flash:@"\u{2192} find database..." red:NO];
}

- (void)dumpSchemaTapped {
    [self.view endEditing:YES];
    [[NSDistributedNotificationCenter defaultCenter] postNotificationName:kNotifyDumpSchema object:nil userInfo:@{} deliverImmediately:YES];
    [self flash:@"\u{2192} dumping schema..." red:NO];
}

- (void)dumpSampleTapped {
    [self.view endEditing:YES];
    [[NSDistributedNotificationCenter defaultCenter] postNotificationName:kNotifyDumpSample object:nil userInfo:@{} deliverImmediately:YES];
    [self flash:@"\u{2192} dumping sample data..." red:NO];
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