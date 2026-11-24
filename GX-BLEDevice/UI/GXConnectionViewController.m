#import "GXConnectionViewController.h"

#import "BKUDPCommandManager.h"
#import "GXBLEScanner.h"
#import "GXDeviceConnectionCoordinator.h"
#import "GXImagePreviewViewController.h"
#import "GXWiFiConnector.h"

@interface GXConnectionViewController ()

@property (nonatomic, strong) GXDeviceConnectionCoordinator *connectionCoordinator;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIButton *connectButton;
@property (nonatomic, strong) UIButton *previewButton;
@property (nonatomic, copy, nullable) NSString *gatewayAddress;
@property (nonatomic, strong, nullable) NSUUID *gatewayRefresh;
@property (nonatomic, strong, nullable) BKUDPCommandManager *commandManager;
@property (nonatomic, strong, nullable) UIAlertController *pendingAlert;
@property (nonatomic) BOOL previewPending;

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
    [self presentPendingResult];
    [self refreshConnectedDevice];
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

    self.previewButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.previewButton setTitle:@"查看图像" forState:UIControlStateNormal];
    [self.previewButton addTarget:self
                           action:@selector(previewButtonTapped:)
                 forControlEvents:UIControlEventTouchUpInside];
    self.previewButton.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    self.previewButton.titleLabel.adjustsFontForContentSizeCategory = YES;
    self.previewButton.hidden = YES;
    NSLayoutConstraint *previewHeight = [self.previewButton.heightAnchor constraintGreaterThanOrEqualToConstant:44];
    previewHeight.priority = UILayoutPriorityDefaultHigh;
    previewHeight.active = YES;

    UIStackView *content = [[UIStackView alloc] initWithArrangedSubviews:@[
        titleLabel,
        self.statusLabel,
        self.connectButton,
        self.previewButton,
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

// 回到首页时重新读取网关，让已连设备的用户可以直接看图。
- (void)refreshConnectedDevice {
    if (self.gatewayRefresh != nil || !self.connectButton.enabled || self.presentedViewController != nil) {
        return;
    }

    NSUUID *refresh = [NSUUID UUID];
    self.gatewayRefresh = refresh;
    __weak typeof(self) weakSelf = self;

    [self.connectionCoordinator readConnectedDeviceWithCompletion:^(NSString * _Nullable gatewayAddress) {
        GXConnectionViewController *controller = weakSelf;
        if (controller.gatewayRefresh != refresh) {
            return;
        }

        controller.gatewayRefresh = nil;
        BOOL hadConnection = controller.gatewayAddress != nil;
        [controller updateConnectedGatewayAddress:gatewayAddress];
        if (hadConnection && gatewayAddress == nil) {
            controller.statusLabel.text = @"设备 Wi-Fi 已断开，请重新连接。";
        }
    }];
}

- (void)updateConnectedGatewayAddress:(NSString * _Nullable)gatewayAddress {
    self.gatewayAddress = gatewayAddress;
    self.previewButton.hidden = gatewayAddress == nil;
    if (gatewayAddress != nil) {
        self.statusLabel.text = [NSString stringWithFormat:@"设备 Wi-Fi 已连接（%@）", gatewayAddress];
    }
}

// 本次连接结束前禁用按钮，防止重复扫描。设备网关就绪后直接进入预览。
- (void)connectButtonTapped:(UIButton *)sender {
    sender.enabled = NO;
    self.gatewayRefresh = nil;
    self.previewPending = NO;
    [self updateConnectedGatewayAddress:nil];
    __weak typeof(self) weakSelf = self;

    [self.connectionCoordinator connectToNearestDeviceWithProgress:^(NSString *message) {
        weakSelf.statusLabel.text = message;
    } completion:^(NSString * _Nullable gatewayAddress, NSError * _Nullable error) {
        GXConnectionViewController *controller = weakSelf;
        controller.connectButton.enabled = YES;
        [controller updateConnectedGatewayAddress:gatewayAddress];
        if (gatewayAddress != nil) {
            [controller presentImagePreviewForHost:gatewayAddress];
        } else {
            [controller showConnectionError:error];
        }
    }];
}

- (void)previewButtonTapped:(UIButton *)sender {
    [self verifyGatewayAndOpenPreview];
}

- (void)verifyGatewayAndOpenPreview {
    if (self.gatewayAddress == nil || !self.connectButton.enabled || self.presentedViewController != nil) {
        return;
    }

    self.gatewayRefresh = nil;
    self.connectButton.enabled = NO;
    self.previewButton.enabled = NO;
    __weak typeof(self) weakSelf = self;

    // 以点击时读到的网关为准，避免用缓存地址向已经切换的网络取 Key。
    [self.connectionCoordinator readConnectedDeviceWithCompletion:^(NSString * _Nullable gatewayAddress) {
        GXConnectionViewController *controller = weakSelf;
        controller.connectButton.enabled = YES;
        controller.previewButton.enabled = YES;
        [controller updateConnectedGatewayAddress:gatewayAddress];

        if (gatewayAddress == nil) {
            controller.statusLabel.text = @"设备 Wi-Fi 已断开，请重新连接。";
            return;
        }

        [controller presentImagePreviewForHost:gatewayAddress];
    }];
}

- (void)presentImagePreviewForHost:(NSString *)host {
    if (![self canPresentConnectionResult]) {
        self.previewPending = YES;
        return;
    }

    self.previewPending = NO;
    // 同一个设备复用指令实例，重新打开预览时仍遵守上次取 Key 的发送间隔。
    if (![self.commandManager.host isEqualToString:host]) {
        [self.commandManager close];
        self.commandManager = [[BKUDPCommandManager alloc] initWithHost:host];
    }

    GXImagePreviewViewController *preview =
        [[GXImagePreviewViewController alloc] initWithCommandManager:self.commandManager];
    preview.modalPresentationStyle = UIModalPresentationFullScreen;
    [self presentViewController:preview animated:YES completion:nil];
}

- (void)showConnectionError:(NSError * _Nullable)error {
    NSString *title = @"连接未完成";
    NSString *message = error.localizedDescription ?: @"请重新搜索设备。";
    BOOL needsBluetoothPermission = NO;

    if ([error.domain isEqualToString:GXBLEScanErrorDomain]) {
        if (error.code == GXBLEScanErrorPoweredOff) {
            title = @"蓝牙未开启";
        } else if (error.code == GXBLEScanErrorUnauthorized) {
            title = @"需要蓝牙权限";
            needsBluetoothPermission = YES;
        }
    } else if ([error.domain isEqualToString:GXWiFiErrorDomain] &&
               error.code == GXWiFiErrorGatewayUnavailable) {
        title = @"未读到 Wi-Fi 网关";
    } else if ([error.domain isEqualToString:GXWiFiErrorDomain] &&
               error.code == GXWiFiErrorUnexpectedGateway) {
        title = @"设备网关不匹配";
    }

    self.statusLabel.text = title;
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
    [self presentPendingResult];
}

- (void)sceneDidActivate:(NSNotification *)notification {
    if (notification.object == self.view.window.windowScene) {
        [self presentPendingResult];
        [self refreshConnectedDevice];
    }
}

- (BOOL)canPresentConnectionResult {
    UIWindowScene *scene = self.view.window.windowScene;
    return scene != nil && scene.activationState == UISceneActivationStateForegroundActive
        && self.presentedViewController == nil;
}

// Wi-Fi 系统弹窗期间可能无法展示页面，回到前台后再处理结果。
- (void)presentPendingResult {
    if (![self canPresentConnectionResult]) {
        return;
    }

    UIAlertController *alert = self.pendingAlert;
    if (alert != nil) {
        self.pendingAlert = nil;
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    if (self.previewPending && self.connectButton.enabled) {
        self.previewPending = NO;
        [self verifyGatewayAndOpenPreview];
    }
}

@end
