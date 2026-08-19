/**
 * MIHelper — Trigger app for MessengerInjector
 *
 * Minimal iOS app that posts NSDistributedNotifications to trigger
 * the MessengerInjector dylib inside Facebook Messenger.
 *
 * Build:
 *   xcrun clang -arch arm64 \
 *     -isysroot $(xcrun --sdk iphoneos --show-sdk-path) \
 *     -miphoneos-version-min=15.0 \
 *     -framework Foundation -framework UIKit \
 *     -ObjC -fobjc-arc \
 *     -o MIHelper MIHelper.m
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

static NSString *const kNotifySend  = @"com.messenger.injector.send";
static NSString *const kNotifyDump  = @"com.messenger.injector.dump";
static NSString *const kNotifyReady = @"com.messenger.injector.ready";

// ============================================================
// Main view controller
// ============================================================
@interface MIHelperVC : UIViewController <UITextFieldDelegate>
@property (nonatomic, strong) UITextField *threadField;
@property (nonatomic, strong) UITextField *messageField;
@property (nonatomic, strong) UISwitch *groupSwitch;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIButton *sendButton;
@property (nonatomic, strong) UIButton *dumpButton;
@end

@implementation MIHelperVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.title = @"MI Helper";
    self.navigationItem.title = @"MI Helper";

    UILabel *title = [[UILabel alloc] init];
    title.text = @"Messenger Injector";
    title.font = [UIFont systemFontOfSize:28 weight:UIFontWeightBold];
    title.textAlignment = NSTextAlignmentCenter;
    title.translatesAutoresizingMaskIntoConstraints = NO;

    // Thread ID field
    self.threadField = [[UITextField alloc] init];
    self.threadField.placeholder = @"Thread ID (user_id or group fbId)";
    self.threadField.borderStyle = UITextBorderStyleRoundedRect;
    self.threadField.font = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightRegular];
    self.threadField.keyboardType = UIKeyboardTypeNumberPad;
    self.threadField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.threadField.delegate = self;
    self.threadField.translatesAutoresizingMaskIntoConstraints = NO;

    // Message field
    self.messageField = [[UITextField alloc] init];
    self.messageField.placeholder = @"Message to send";
    self.messageField.borderStyle = UITextBorderStyleRoundedRect;
    self.messageField.font = [UIFont systemFontOfSize:16];
    self.messageField.delegate = self;
    self.messageField.translatesAutoresizingMaskIntoConstraints = NO;

    // Group switch
    UIView *groupRow = [[UIView alloc] init];
    groupRow.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *groupLabel = [[UILabel alloc] init];
    groupLabel.text = @"Group chat";
    groupLabel.font = [UIFont systemFontOfSize:15];
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
        [groupRow.heightAnchor constraintEqualToConstant:32],
    ]];

    // Send button
    self.sendButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.sendButton setTitle:@"Send Message" forState:UIControlStateNormal];
    self.sendButton.titleLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightBold];
    self.sendButton.backgroundColor = [UIColor systemBlueColor];
    [self.sendButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.sendButton.layer.cornerRadius = 10;
    [self.sendButton addTarget:self action:@selector(sendTapped) forControlEvents:UIControlEventTouchUpInside];
    self.sendButton.translatesAutoresizingMaskIntoConstraints = NO;

    // Dump button
    self.dumpButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.dumpButton setTitle:@"Dump View Hierarchy (Debug)" forState:UIControlStateNormal];
    self.dumpButton.titleLabel.font = [UIFont systemFontOfSize:14];
    self.dumpButton.backgroundColor = [UIColor secondarySystemBackgroundColor];
    [self.dumpButton addTarget:self action:@selector(dumpTapped) forControlEvents:UIControlEventTouchUpInside];
    self.dumpButton.layer.cornerRadius = 10;
    self.dumpButton.translatesAutoresizingMaskIntoConstraints = NO;

    // Status label
    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.text = @"Waiting for dylib...";
    self.statusLabel.font = [UIFont systemFontOfSize:13];
    self.statusLabel.textColor = [UIColor secondaryLabelColor];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;

    // Layout
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        title, self.threadField, self.messageField, groupRow,
        self.sendButton, self.dumpButton, self.statusLabel
    ]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 14;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [stack.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [stack.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:24],
        [stack.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-24],
        [self.sendButton.heightAnchor constraintEqualToConstant:50],
        [self.dumpButton.heightAnchor constraintEqualToConstant:44],
    ]];

    // Listen for dylib ready notification
    [[NSDistributedNotificationCenter defaultCenter]
        addObserverForName:kNotifyReady
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.statusLabel.text = @"✅ Dylib ready";
                self.statusLabel.textColor = [UIColor systemGreenColor];
            });
        }];
}

- (void)sendTapped {
    [self.view endEditing:YES];

    NSString *threadId = self.threadField.text ?: @"";
    NSString *message  = self.messageField.text ?: @"";
    BOOL isGroup = self.groupSwitch.isOn;

    if (threadId.length == 0) {
        [self flashStatus:@"Enter a thread ID" red:YES];
        return;
    }
    if (message.length == 0) {
        [self flashStatus:@"Enter a message" red:YES];
        return;
    }

    NSDictionary *userInfo = @{
        @"message":  message,
        @"threadId": threadId,
        @"isGroup":  @(isGroup),
    };

    [[NSDistributedNotificationCenter defaultCenter]
        postNotificationName:kNotifySend
                      object:nil
                    userInfo:userInfo
            deliverImmediately:YES];

    [self flashStatus:[NSString stringWithFormat:@"Trigger sent → thread %@", threadId] red:NO];

    // Clear message field
    self.messageField.text = @"";
}

- (void)dumpTapped {
    [self.view endEditing:YES];
    [[NSDistributedNotificationCenter defaultCenter]
        postNotificationName:kNotifyDump
                      object:nil
                    userInfo:@{}
            deliverImmediately:YES];
    [self flashStatus:@"Dump trigger sent" red:NO];
}

- (void)groupToggled:(UISwitch *)sw {
    self.threadField.placeholder = sw.isOn
        ? @"Group thread fbId"
        : @"User ID (1-on-1)";
}

- (void)flashStatus:(NSString *)msg red:(BOOL)red {
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

// ============================================================
// main
// ============================================================
int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil,
                                 NSStringFromClass([MIHelperAppDelegate class]));
    }
}