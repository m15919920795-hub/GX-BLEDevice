#import "GXImagePreviewViewController.h"

#import "BKUDPImageManager.h"

// 使用当前设备的值验证出图，后续可在读取设备信息后传入。
static const uint8_t GXPreviewW32Key = 254;

@interface GXImagePreviewViewController () <BKUDPImageManagerDelegate>

@property (nonatomic, copy) NSString *host;
@property (nonatomic, strong) BKUDPImageManager *imageManager;
@property (nonatomic, strong) UIImageView *imageView;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIButton *retryButton;
@property (nonatomic) BOOL shouldResumeStream;

@end

@implementation GXImagePreviewViewController

- (instancetype)initWithHost:(NSString *)host {
    self = [super initWithNibName:nil bundle:nil];
    if (self != nil) {
        _host = [host copy];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.view.backgroundColor = UIColor.blackColor;
    self.view.tintColor = UIColor.whiteColor;
    self.imageManager = [[BKUDPImageManager alloc] init];
    self.imageManager.delegate = self;
    [self configurePreview];

    NSNotificationCenter *notifications = [NSNotificationCenter defaultCenter];
    [notifications addObserver:self
                       selector:@selector(sceneDidEnterBackground:)
                           name:UISceneDidEnterBackgroundNotification
                         object:nil];
    [notifications addObserver:self
                       selector:@selector(sceneDidActivate:)
                           name:UISceneDidActivateNotification
                         object:nil];
}

- (void)configurePreview {
    self.imageView = [[UIImageView alloc] init];
    self.imageView.translatesAutoresizingMaskIntoConstraints = NO;
    self.imageView.contentMode = UIViewContentModeScaleAspectFit;

    UIButton *backButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [backButton setTitle:@"返回" forState:UIControlStateNormal];
    [backButton addTarget:self action:@selector(backButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
    [backButton.widthAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;

    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.textColor = UIColor.whiteColor;
    self.statusLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    self.statusLabel.adjustsFontForContentSizeCategory = YES;
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.numberOfLines = 2;
    [self.statusLabel setContentCompressionResistancePriority:UILayoutPriorityDefaultLow
                                                      forAxis:UILayoutConstraintAxisHorizontal];

    self.retryButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.retryButton.hidden = YES;
    [self.retryButton setTitle:@"重试" forState:UIControlStateNormal];
    [self.retryButton addTarget:self action:@selector(retryButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
    NSLayoutConstraint *retryWidth = [self.retryButton.widthAnchor constraintGreaterThanOrEqualToConstant:44];
    retryWidth.priority = UILayoutPriorityDefaultHigh;
    retryWidth.active = YES;

    UIStackView *controls = [[UIStackView alloc] initWithArrangedSubviews:@[
        backButton,
        self.statusLabel,
        self.retryButton,
    ]];
    controls.translatesAutoresizingMaskIntoConstraints = NO;
    controls.axis = UILayoutConstraintAxisHorizontal;
    controls.alignment = UIStackViewAlignmentCenter;
    controls.spacing = 12;

    [self.view addSubview:self.imageView];
    [self.view addSubview:controls];

    UILayoutGuide *safeArea = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [controls.topAnchor constraintEqualToAnchor:safeArea.topAnchor],
        [controls.leadingAnchor constraintEqualToAnchor:safeArea.leadingAnchor constant:12],
        [controls.trailingAnchor constraintEqualToAnchor:safeArea.trailingAnchor constant:-12],
        [controls.heightAnchor constraintGreaterThanOrEqualToConstant:44],
        [self.imageView.topAnchor constraintEqualToAnchor:controls.bottomAnchor],
        [self.imageView.leadingAnchor constraintEqualToAnchor:safeArea.leadingAnchor],
        [self.imageView.trailingAnchor constraintEqualToAnchor:safeArea.trailingAnchor],
        [self.imageView.bottomAnchor constraintEqualToAnchor:safeArea.bottomAnchor],
    ]];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self startReceiving];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    self.shouldResumeStream = NO;
    [self.imageManager stopReceiving];
}

// App 真正进入后台时停流，回到预览页时重新请求图像。
- (void)sceneDidEnterBackground:(NSNotification *)notification {
    if (notification.object == self.view.window.windowScene) {
        self.shouldResumeStream = YES;
        [self.imageManager stopReceiving];
    }
}

- (void)sceneDidActivate:(NSNotification *)notification {
    if (self.shouldResumeStream && notification.object == self.view.window.windowScene) {
        [self startReceiving];
    }
}

- (void)backButtonTapped:(UIButton *)sender {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)retryButtonTapped:(UIButton *)sender {
    [self startReceiving];
}

- (void)startReceiving {
    self.shouldResumeStream = NO;
    self.retryButton.hidden = YES;
    self.imageView.image = nil;
    self.statusLabel.text = [NSString stringWithFormat:@"正在等待 %@ 的图像…", self.host];
    [self.imageManager startReceivingFromHost:self.host w32Key:GXPreviewW32Key];
}

- (void)udpImageManager:(BKUDPImageManager *)manager didReceiveImage:(UIImage *)image {
    if (self.imageView.image == nil) {
        self.statusLabel.text = @"正在接收图像";
    }
    self.imageView.image = image;
}

- (void)udpImageManager:(BKUDPImageManager *)manager didStopWithError:(NSError *)error {
    self.statusLabel.text = error.localizedDescription;
    self.retryButton.hidden = NO;
}

@end
