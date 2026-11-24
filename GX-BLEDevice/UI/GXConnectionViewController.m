#import "GXConnectionViewController.h"

#import "GXBLEScanner.h"
#import "GXDeviceConnectionCoordinator.h"

@interface GXConnectionViewController ()

@property (nonatomic, strong) GXDeviceConnectionCoordinator *connectionCoordinator;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIButton *connectButton;
@property (nonatomic, strong, nullable) UIAlertController *pendingAlert;

@end

@implementation GXConnectionViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    self.connectionCoordinator = [[GXDeviceConnectionCoordinator alloc] init];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    [self configureContent];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(sceneDidActivate:)
                                                 name:UISceneDidActivateNotification
                                               object:nil];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self presentPendingAlert];
}

- (void)configureContent {
    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.text = @"连接 FPV 设备";
    titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle1];
    titleLabel.adjustsFontForContentSizeCategory = YES;
    titleLabel.numberOfLines = 0;
    titleLabel.textAlignment = NSTextAlignmentCenter;

    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.text = @"请先开启 FPV 设备";
    self.statusLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    self.statusLabel.adjustsFontForContentSizeCategory = YES;
    self.statusLabel.textColor = UIColor.secondaryLabelColor;
    self.statusLabel.numberOfLines = 0;
    self.statusLabel.textAlignment = NSTextAlignmentCenter;

    self.connectButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.connectButton setTitle:@"搜索并连接" forState:UIControlStateNormal];
    [self.connectButton addTarget:self
                           action:@selector(connectButtonTapped:)
                 forControlEvents:UIControlEventTouchUpInside];
    self.connectButton.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    self.connectButton.titleLabel.adjustsFontForContentSizeCategory = YES;
    self.connectButton.contentEdgeInsets = UIEdgeInsetsMake(10, 24, 10, 24);
    [self.connectButton.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;

    UIStackView *content = [[UIStackView alloc] initWithArrangedSubviews:@[
        titleLabel,
        self.statusLabel,
        self.connectButton,
    ]];
    content.translatesAutoresizingMaskIntoConstraints = NO;
    content.axis = UILayoutConstraintAxisVertical;
    content.spacing = 16;

    [self embedContentInScrollView:content];
}

// 横屏下保持内容居中，文字放大后仍然可以滚动到连接按钮。
- (void)embedContentInScrollView:(UIStackView *)content {
    UIScrollView *scrollView = [[UIScrollView alloc] init];
    scrollView.translatesAutoresizingMaskIntoConstraints = NO;

    UIView *container = [[UIView alloc] init];
    container.translatesAutoresizingMaskIntoConstraints = NO;

    [self.view addSubview:scrollView];
    [scrollView addSubview:container];
    [container addSubview:content];

    UILayoutGuide *safeArea = self.view.safeAreaLayoutGuide;
    UILayoutGuide *scrollContent = scrollView.contentLayoutGuide;
    UILayoutGuide *scrollFrame = scrollView.frameLayoutGuide;

    NSLayoutConstraint *preferredWidth = [content.widthAnchor constraintEqualToConstant:420];
    preferredWidth.priority = UILayoutPriorityDefaultHigh;

    [NSLayoutConstraint activateConstraints:@[
        [scrollView.topAnchor constraintEqualToAnchor:safeArea.topAnchor],
        [scrollView.bottomAnchor constraintEqualToAnchor:safeArea.bottomAnchor],
        [scrollView.leadingAnchor constraintEqualToAnchor:safeArea.leadingAnchor],
        [scrollView.trailingAnchor constraintEqualToAnchor:safeArea.trailingAnchor],
        [container.topAnchor constraintEqualToAnchor:scrollContent.topAnchor],
        [container.bottomAnchor constraintEqualToAnchor:scrollContent.bottomAnchor],
        [container.leadingAnchor constraintEqualToAnchor:scrollContent.leadingAnchor],
        [container.trailingAnchor constraintEqualToAnchor:scrollContent.trailingAnchor],
        [container.widthAnchor constraintEqualToAnchor:scrollFrame.widthAnchor],
        [container.heightAnchor constraintGreaterThanOrEqualToAnchor:scrollFrame.heightAnchor],
        [content.centerXAnchor constraintEqualToAnchor:container.centerXAnchor],
        [content.centerYAnchor constraintEqualToAnchor:container.centerYAnchor],
        [content.leadingAnchor constraintGreaterThanOrEqualToAnchor:container.leadingAnchor constant:24],
        [content.trailingAnchor constraintLessThanOrEqualToAnchor:container.trailingAnchor constant:-24],
        [content.topAnchor constraintGreaterThanOrEqualToAnchor:container.topAnchor constant:16],
        [content.bottomAnchor constraintLessThanOrEqualToAnchor:container.bottomAnchor constant:-16],
        preferredWidth,
    ]];

    NSLayoutConstraint *preferredHeight = [container.heightAnchor constraintEqualToAnchor:scrollFrame.heightAnchor];
    preferredHeight.priority = UILayoutPriorityDefaultLow;
    preferredHeight.active = YES;
}

// 本次连接结束前禁用按钮，防止重复启动扫描或重复弹出系统加入提示。
- (void)connectButtonTapped:(UIButton *)sender {
    sender.enabled = NO;
    __weak typeof(self) weakSelf = self;

    [self.connectionCoordinator connectToNearestDeviceWithProgress:^(NSString *message) {
        weakSelf.statusLabel.text = message;
    } completion:^(NSString * _Nullable ssid, NSError * _Nullable error) {
        [weakSelf showResultWithSSID:ssid error:error];
    }];
}

- (void)showResultWithSSID:(NSString * _Nullable)ssid error:(NSError * _Nullable)error {
    self.connectButton.enabled = YES;

    NSString *title;
    NSString *message;
    BOOL needsBluetoothPermission = NO;

    if (ssid != nil) {
        title = @"连接成功";
        message = [NSString stringWithFormat:@"已连接到 %@", ssid];
    } else {
        title = @"连接未完成";
        message = error.localizedDescription ?: @"请重新搜索设备。";

        if ([error.domain isEqualToString:GXBLEScanErrorDomain]) {
            if (error.code == GXBLEScanErrorPoweredOff) {
                title = @"蓝牙未开启";
            } else if (error.code == GXBLEScanErrorUnauthorized) {
                title = @"需要蓝牙权限";
                needsBluetoothPermission = YES;
            }
        }
    }

    self.statusLabel.text = ssid != nil ? message : title;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    if (needsBluetoothPermission) {
        [alert addAction:[UIAlertAction actionWithTitle:@"打开 App 设置"
                                                 style:UIAlertActionStyleDefault
                                               handler:^(__unused UIAlertAction *action) {
            NSURL *settingsURL = [NSURL URLWithString:UIApplicationOpenSettingsURLString];
            [UIApplication.sharedApplication openURL:settingsURL options:@{} completionHandler:nil];
        }]];
    }

    [alert addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleCancel handler:nil]];
    self.pendingAlert = alert;
    [self presentPendingAlert];
}

- (void)sceneDidActivate:(NSNotification *)notification {
    if (notification.object == self.view.window.windowScene) {
        [self presentPendingAlert];
    }
}

// 系统权限弹窗期间界面可能暂时失去焦点。回到前台后再展示本次连接结果。
- (void)presentPendingAlert {
    if (self.pendingAlert == nil || self.presentedViewController != nil) {
        return;
    }

    UIWindowScene *scene = self.view.window.windowScene;
    if (scene == nil || scene.activationState != UISceneActivationStateForegroundActive) {
        return;
    }

    UIAlertController *alert = self.pendingAlert;
    self.pendingAlert = nil;
    [self presentViewController:alert animated:YES completion:nil];
}

@end
