#import "GXImagePreviewViewController.h"

#import "BKUDPCommandManager.h"
#import "BKUDPImageManager.h"

@interface GXImagePreviewViewController () <BKUDPImageManagerDelegate>

@property (nonatomic, strong) BKUDPCommandManager *commandManager;
@property (nonatomic, strong, nullable) NSUUID *previewRequest;
@property (nonatomic, strong, nullable) NSNumber *imageKey;
@property (nonatomic, strong) BKUDPImageManager *imageManager;
@property (nonatomic, strong) UIImageView *imageView;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIButton *retryButton;
@property (nonatomic) BOOL exitingPreview;

@end

@implementation GXImagePreviewViewController

- (instancetype)initWithCommandManager:(BKUDPCommandManager *)commandManager {
    self = [super initWithNibName:nil bundle:nil];
    if (self != nil) {
        _commandManager = commandManager;
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
    if (self.previewRequest == nil) {
        [self startReceiving];
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self stopPreviewWithCompletion:nil];
}

// App 进入后台时结束本次预览。回来后由用户重新打开预览。
- (void)sceneDidEnterBackground:(NSNotification *)notification {
    if (notification.object == self.view.window.windowScene) {
        [self exitPreviewAnimated:NO];
    }
}

- (void)backButtonTapped:(UIButton *)sender {
    sender.enabled = NO;
    [self exitPreviewAnimated:YES];
}

- (void)exitPreviewAnimated:(BOOL)animated {
    if (self.exitingPreview) {
        return;
    }

    self.exitingPreview = YES;
    self.imageKey = nil;
    __weak typeof(self) weakSelf = self;
    [self stopPreviewWithCompletion:^{
        [weakSelf dismissViewControllerAnimated:animated completion:nil];
    }];
}

- (void)retryButtonTapped:(UIButton *)sender {
    [self startReceiving];
}

- (void)startReceiving {
    if (self.exitingPreview) {
        return;
    }

    self.retryButton.hidden = YES;
    self.imageView.image = nil;
    self.statusLabel.text = self.imageKey == nil ? @"正在获取设备 Key…" : @"正在准备图像…";

    NSUUID *request = [NSUUID UUID];
    self.previewRequest = request;
    __weak typeof(self) weakSelf = self;

    // 固件开流期间可能忽略取 Key 指令。先等停流指令处理完，再开始获取。
    [self.imageManager stopReceivingWithCompletion:^{
        GXImagePreviewViewController *preview = weakSelf;
        if (preview.previewRequest != request) {
            return;
        }

        NSNumber *imageKey = preview.imageKey;
        if (imageKey != nil) {
            [preview openImageStreamWithKey:imageKey.unsignedCharValue];
        } else {
            [preview requestKeyForPreview:request];
        }
    }];
}

- (void)requestKeyForPreview:(NSUUID *)request {
    __weak typeof(self) weakSelf = self;
    [self.commandManager requestImageKeyWithCompletion:^(uint8_t w32Key, NSError * _Nullable error) {
        GXImagePreviewViewController *preview = weakSelf;
        if (preview.previewRequest != request) {
            return;
        }

        if (error != nil) {
            preview.statusLabel.text = error.localizedDescription;
            preview.retryButton.hidden = NO;
            return;
        }

        // 同一次预览缓存已取得的 Key，图像重试时复用。
        preview.imageKey = @(w32Key);
        [preview openImageStreamWithKey:w32Key];
    }];
}

- (void)openImageStreamWithKey:(uint8_t)w32Key {
    NSString *host = self.commandManager.host;
    self.statusLabel.text = [NSString stringWithFormat:@"正在等待 %@ 的图像…", host];
    [self.imageManager startReceivingFromHost:host w32Key:w32Key];
}

- (void)stopPreviewWithCompletion:(dispatch_block_t _Nullable)completion {
    self.previewRequest = nil;
    [self.commandManager close];
    [self.imageManager stopReceivingWithCompletion:completion];
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
