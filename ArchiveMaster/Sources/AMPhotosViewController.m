#import "AMPhotosViewController.h"
#import "AMActions.h"
#import "AMFileItem.h"
#import "AMMediaCompressor.h"
#import "AMProgressController.h"
#import "AMQuickLook.h"
#import "AMUI.h"
#import <AVFoundation/AVFoundation.h>
#import <Photos/Photos.h>
#import <PhotosUI/PhotosUI.h>
#import <QuickLookThumbnailing/QuickLookThumbnailing.h>

typedef NS_ENUM(NSInteger, AMPDestination) { AMPDestinationAlbum, AMPDestinationFiles, AMPDestinationZip };

static const long long KB = 1024, MB = 1024 * 1024;
static const long long kPerImageMin = 30 * 1024, kPerImageMax = 10 * 1024 * 1024;

static NSArray<NSNumber *> *AMEdges(void) { return @[ @0, @4096, @2560, @1920, @1440, @1080, @720 ]; }
static NSArray<NSString *> *AMVideoPresets(void) {
    return @[ @"", AVAssetExportPreset1920x1080, AVAssetExportPreset1280x720, AVAssetExportPreset960x540 ];
}

static long long AMLogValue(float t, long long lo, long long hi) {
    if (hi <= lo) return hi;
    return llround((double)lo * pow((double)hi / (double)lo, MAX(0, MIN(1, t))));
}

static float AMLogPosition(long long v, long long lo, long long hi) {
    if (hi <= lo || v <= lo) return 0;
    return (float)MIN(1.0, log((double)v / (double)lo) / log((double)hi / (double)lo));
}

#pragma mark - Thumbnail cell

@interface AMThumbCell : UICollectionViewCell
@property (nonatomic, strong) UIImageView *imageView;
@property (nonatomic, strong) UIImageView *badge;
@property (nonatomic, strong) NSURL *url;
@end

@implementation AMThumbCell
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _imageView = [[UIImageView alloc] initWithFrame:self.contentView.bounds];
        _imageView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _imageView.contentMode = UIViewContentModeScaleAspectFill;
        _imageView.clipsToBounds = YES;
        _imageView.layer.cornerRadius = 8;
        _imageView.layer.cornerCurve = kCACornerCurveContinuous;
        _imageView.backgroundColor = UIColor.tertiarySystemFillColor;
        [self.contentView addSubview:_imageView];
        _badge = [[UIImageView alloc] initWithImage:[AMUI symbol:@"video.fill" pointSize:11]];
        _badge.tintColor = UIColor.whiteColor;
        _badge.layer.shadowOpacity = 0.6;
        _badge.layer.shadowRadius = 2;
        _badge.layer.shadowOffset = CGSizeZero;
        _badge.frame = CGRectMake(5, frame.size.height - 18, 18, 13);
        _badge.contentMode = UIViewContentModeScaleAspectFit;
        [self.contentView addSubview:_badge];
    }
    return self;
}
@end

#pragma mark - Section model

@interface AMPSection : NSObject
@property (nonatomic, copy) NSString *header;
@property (nonatomic, copy) NSString *footer;
@property (nonatomic, copy) NSArray<UITableViewCell *> *cells;
@end
@implementation AMPSection
+ (instancetype)header:(NSString *)h footer:(NSString *)f cells:(NSArray *)cells {
    AMPSection *s = [AMPSection new];
    s.header = h;
    s.footer = f;
    s.cells = cells;
    return s;
}
@end

#pragma mark - Controller

@interface AMPhotosViewController () <PHPickerViewControllerDelegate, UICollectionViewDataSource>
@property (nonatomic, strong) NSURL *stagingDir;
@property (nonatomic, copy) NSArray<AMPickedAsset *> *assets;
@property (nonatomic) long long imageBytes, otherBytes, totalBytes;
@property (nonatomic) NSInteger imageCount, videoCount, gifCount;

// Compress mode
@property (nonatomic) NSInteger mode;        // 0 compress, 1 pack
@property (nonatomic) NSInteger targetMode;  // 0 ratio, 1 per-photo size
@property (nonatomic) float ratio;
@property (nonatomic) float sizePosition;    // log slider position for per-photo size
@property (nonatomic) NSInteger edgeIndex;
@property (nonatomic) BOOL heic;
@property (nonatomic) BOOL stripLocation;
@property (nonatomic) NSInteger videoPreset;
@property (nonatomic) AMPDestination destination;
@property (nonatomic) BOOL deleteOriginals;
// Pack mode
@property (nonatomic) BOOL limitSize;
@property (nonatomic) float packPosition;

@property (nonatomic, copy) NSArray<AMPSection *> *layout;
@property (nonatomic, strong) UIView *hero, *header, *footer;
@property (nonatomic, strong) UILabel *headerLabel;
@property (nonatomic, strong) UICollectionView *strip;
@property (nonatomic, strong) UIButton *actionButton;
@property (nonatomic, strong) UITableViewCell *modeCell, *targetModeCell, *ratioCell, *sizeCell, *estimateCell, *edgeCell, *formatCell,
    *locationCell, *videoCell, *destCell, *deleteCell, *previewCell, *limitCell, *packSliderCell, *presetCell, *packInfoCell;
@property (nonatomic, strong) UISlider *packSlider, *sizeSlider;
@property (nonatomic, strong) NSCache<NSURL *, UIImage *> *thumbs;
@end

@implementation AMPhotosViewController

- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];
    [AMUI applyReadableMarginsToTableView:self.tableView];
}

- (instancetype)init {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _assets = @[];
        _ratio = 0.3f;
        _sizePosition = AMLogPosition(500 * KB, kPerImageMin, kPerImageMax);
        _stripLocation = YES;
        _packPosition = 0.5f;
        _thumbs = [NSCache new];
        _stagingDir = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"PhotoStaging"] isDirectory:YES];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = L(@"相册");
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeAlways;
    [self buildHero];
    [self buildHeader];
    [self buildFooter];
    [self buildCells];
    [self refresh];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // The copies live in tmp/, which "清除缓存" (or the system) may have emptied.
    if (self.assets.count && ![NSFileManager.defaultManager fileExistsAtPath:self.assets.firstObject.url.path]) [self clearSelection];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat w = self.tableView.bounds.size.width;
    if (self.tableView.tableHeaderView == self.header && fabs(self.header.frame.size.width - w) > 0.5) {
        self.header.frame = CGRectMake(0, 0, w, 140);
        self.tableView.tableHeaderView = self.header;
    }
    if (self.tableView.tableFooterView == self.footer && fabs(self.footer.frame.size.width - w) > 0.5) {
        self.footer.frame = CGRectMake(0, 0, w, 96);
        self.tableView.tableFooterView = self.footer;
    }
}

#pragma mark - Derived values

- (BOOL)isCompressibleImage:(AMPickedAsset *)a {
    return !a.isVideo && ![a.url.pathExtension.lowercaseString isEqualToString:@"gif"];
}

- (NSArray<AMPickedAsset *> *)compressibleImages {
    NSMutableArray *list = [NSMutableArray array];
    for (AMPickedAsset *a in self.assets) if ([self isCompressibleImage:a]) [list addObject:a];
    return list;
}

- (long long)perImageTarget { return [AMUI niceBytes:AMLogValue(self.sizePosition, kPerImageMin, kPerImageMax)]; }
- (long long)packMin { return MIN(self.totalBytes, MAX(200 * KB, self.totalBytes / 50)); }
- (long long)packTarget { return [AMUI niceBytes:AMLogValue(self.packPosition, self.packMin, self.totalBytes)]; }
- (BOOL)canLimitPack { return self.totalBytes > 400 * KB && self.imageCount - self.gifCount > 0; }
- (BOOL)canDeleteOriginals {
    for (AMPickedAsset *a in self.assets) if (a.assetIdentifier.length) return YES;
    return NO;
}

#pragma mark - Building

- (UIButton *)filledButton:(NSString *)title symbol:(NSString *)symbol action:(SEL)action {
    UIButtonConfiguration *c = AMUI.prominentButtonConfiguration;
    c.title = title;
    if (symbol) {
        c.image = [UIImage systemImageNamed:symbol];
        c.imagePadding = 8;
    }
    UIButton *b = [UIButton buttonWithConfiguration:c primaryAction:nil];
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    b.translatesAutoresizingMaskIntoConstraints = NO;
    return b;
}

- (void)buildHero {
    UIView *v = [UIView new];
    UIImageView *icon = [[UIImageView alloc] initWithImage:[AMUI symbol:@"photo.on.rectangle.angled" pointSize:60]];
    icon.tintColor = UIColor.tintColor;
    icon.contentMode = UIViewContentModeCenter;
    UILabel *title = [UILabel new];
    title.text = L(@"压缩照片和视频");
    title.font = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle2];
    title.adjustsFontForContentSizeCategory = YES;
    title.textAlignment = NSTextAlignmentCenter;
    title.numberOfLines = 0;
    UILabel *body = [UILabel new];
    body.text = L(@"选择一张或多张照片：可以按比例或按大小压缩后直接存回相册，也可以打包成 ZIP、7Z 等压缩包，并限制压缩包的大小。");
    body.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    body.adjustsFontForContentSizeCategory = YES;
    body.textColor = UIColor.secondaryLabelColor;
    body.textAlignment = NSTextAlignmentCenter;
    body.numberOfLines = 0;
    UIButton *pick = [self filledButton:L(@"选择照片") symbol:@"photo.on.rectangle" action:@selector(pickPhotos)];
    UILabel *privacy = [UILabel new];
    privacy.text = L(@"只有你选中的照片会被读取。");
    privacy.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    privacy.adjustsFontForContentSizeCategory = YES;
    privacy.textColor = UIColor.tertiaryLabelColor;
    privacy.textAlignment = NSTextAlignmentCenter;
    privacy.numberOfLines = 0;
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[ icon, title, body, pick, privacy ]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 10;
    [stack setCustomSpacing:18 afterView:icon];
    [stack setCustomSpacing:28 afterView:body];
    [stack setCustomSpacing:12 afterView:pick];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [v addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.centerXAnchor constraintEqualToAnchor:v.centerXAnchor],
        [stack.centerYAnchor constraintEqualToAnchor:v.safeAreaLayoutGuide.centerYAnchor constant:-20],
        [stack.widthAnchor constraintEqualToAnchor:v.widthAnchor constant:-64],
        [stack.widthAnchor constraintLessThanOrEqualToConstant:420],
    ]];
    self.hero = v;
}

- (void)buildHeader {
    UIView *h = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 375, 140)];
    self.headerLabel = [UILabel new];
    self.headerLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    self.headerLabel.adjustsFontForContentSizeCategory = YES;
    self.headerLabel.textColor = UIColor.secondaryLabelColor;
    self.headerLabel.translatesAutoresizingMaskIntoConstraints = NO;
    UICollectionViewFlowLayout *layout = [UICollectionViewFlowLayout new];
    layout.scrollDirection = UICollectionViewScrollDirectionHorizontal;
    layout.itemSize = CGSizeMake(84, 84);
    layout.minimumLineSpacing = 8;
    layout.sectionInset = UIEdgeInsetsMake(0, 20, 0, 20);
    self.strip = [[UICollectionView alloc] initWithFrame:CGRectZero collectionViewLayout:layout];
    self.strip.backgroundColor = UIColor.clearColor;
    self.strip.showsHorizontalScrollIndicator = NO;
    self.strip.dataSource = self;
    [self.strip registerClass:AMThumbCell.class forCellWithReuseIdentifier:@"thumb"];
    self.strip.translatesAutoresizingMaskIntoConstraints = NO;
    [h addSubview:self.headerLabel];
    [h addSubview:self.strip];
    [NSLayoutConstraint activateConstraints:@[
        [self.headerLabel.leadingAnchor constraintEqualToAnchor:h.readableContentGuide.leadingAnchor],
        [self.headerLabel.trailingAnchor constraintEqualToAnchor:h.readableContentGuide.trailingAnchor],
        [self.headerLabel.topAnchor constraintEqualToAnchor:h.topAnchor constant:8],
        [self.strip.leadingAnchor constraintEqualToAnchor:h.leadingAnchor],
        [self.strip.trailingAnchor constraintEqualToAnchor:h.trailingAnchor],
        [self.strip.topAnchor constraintEqualToAnchor:self.headerLabel.bottomAnchor constant:10],
        [self.strip.heightAnchor constraintEqualToConstant:84],
    ]];
    self.header = h;
}

- (void)buildFooter {
    UIView *f = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 375, 96)];
    self.actionButton = [self filledButton:L(@"开始压缩") symbol:@"arrow.down.right.and.arrow.up.left" action:@selector(runAction)];
    [f addSubview:self.actionButton];
    [NSLayoutConstraint activateConstraints:@[
        [self.actionButton.leadingAnchor constraintEqualToAnchor:f.readableContentGuide.leadingAnchor],
        [self.actionButton.trailingAnchor constraintEqualToAnchor:f.readableContentGuide.trailingAnchor],
        [self.actionButton.topAnchor constraintEqualToAnchor:f.topAnchor constant:16],
    ]];
    self.footer = f;
}

- (void)buildCells {
    __weak typeof(self) weak = self;
    self.modeCell = [AMForm segmentedCellWithItems:@[ L(@"压缩图片"), L(@"打包成压缩包") ] selected:0 handler:^(NSInteger index) {
        weak.mode = index;
        [weak refresh];
    }];
    self.targetModeCell = [AMForm segmentedCellWithItems:@[ L(@"按比例"), L(@"按单张大小") ] selected:0 handler:^(NSInteger index) {
        weak.targetMode = index;
        [weak refresh];
    }];
    self.ratioCell = [AMForm sliderCellWithTitle:L(@"压缩到原来的") value:self.ratio min:0.05f max:0.9f format:^NSString *(float v) {
        return [NSString stringWithFormat:@"%ld%%", (long)lroundf(v * 100)];
    } handler:^(float v) {
        weak.ratio = roundf(v * 100) / 100;
        [weak updateEstimate];
    } outSlider:nil];
    UISlider *slider = nil;
    self.sizeCell = [AMForm sliderCellWithTitle:L(@"每张不超过") value:self.sizePosition min:0 max:1 format:^NSString *(float t) {
        return [AMUI byteString:[AMUI niceBytes:AMLogValue(t, kPerImageMin, kPerImageMax)]];
    } handler:^(float t) {
        weak.sizePosition = t;
        [weak updateEstimate];
    } outSlider:&slider];
    self.sizeSlider = slider;
    self.estimateCell = [AMForm valueCellWithTitle:L(@"预计") detail:@"—" symbol:nil tint:nil accessory:UITableViewCellAccessoryNone];
    self.estimateCell.selectionStyle = UITableViewCellSelectionStyleNone;

    NSMutableArray *edges = [NSMutableArray arrayWithObject:L(@"不限制")];
    for (NSNumber *e in [AMEdges() subarrayWithRange:NSMakeRange(1, AMEdges().count - 1)])
        [edges addObject:[NSString stringWithFormat:L(@"%@ 像素"), e]];
    self.edgeCell = [AMForm popupCellWithTitle:L(@"最长边") options:edges selected:0 handler:^(NSInteger index) {
        weak.edgeIndex = index;
    }];
    NSArray *formats = AMMediaCompressor.canEncodeHEIC ? @[ L(@"JPEG（兼容性最好）"), L(@"HEIC（体积更小）") ] : @[ @"JPEG" ];
    self.formatCell = [AMForm popupCellWithTitle:L(@"格式") options:formats selected:0 handler:^(NSInteger index) {
        weak.heic = index == 1;
    }];
    self.locationCell = [AMForm switchCellWithTitle:L(@"移除位置信息") on:YES handler:^(BOOL on) {
        weak.stripLocation = on;
    } outSwitch:nil];
    self.videoCell = [AMForm popupCellWithTitle:L(@"视频") options:@[ L(@"保持原样"), L(@"压缩为 1080p"), L(@"压缩为 720p"), L(@"压缩为 540p") ] selected:0 handler:^(NSInteger index) {
        weak.videoPreset = index;
    }];
    self.destCell = [AMForm popupCellWithTitle:L(@"保存到") options:@[ L(@"相册"), L(@"“文件”页面"), L(@"ZIP 压缩包") ] selected:0 handler:^(NSInteger index) {
        weak.destination = (AMPDestination)index;
        [weak refresh];
    }];
    self.deleteCell = [AMForm switchCellWithTitle:L(@"删除原图") on:NO handler:^(BOOL on) {
        weak.deleteOriginals = on;
    } outSwitch:nil];
    self.previewCell = [AMForm actionCellWithTitle:L(@"预览压缩效果") symbol:@"eye" destructive:NO];

    self.limitCell = [AMForm switchCellWithTitle:L(@"限制压缩包大小") on:NO handler:^(BOOL on) {
        weak.limitSize = on;
        [weak refresh];
    } outSwitch:nil];
    self.packSliderCell = [AMForm sliderCellWithTitle:L(@"目标大小") value:self.packPosition min:0 max:1 format:^NSString *(float t) {
        typeof(self) strong = weak;
        return strong ? [AMUI byteString:[AMUI niceBytes:AMLogValue(t, strong.packMin, strong.totalBytes)]] : @"";
    } handler:^(float t) {
        weak.packPosition = t;
        [weak updateEstimate];
    } outSlider:&slider];
    self.packSlider = slider;
    self.packInfoCell = [AMForm valueCellWithTitle:L(@"原始大小") detail:@"—" symbol:nil tint:nil accessory:UITableViewCellAccessoryNone];
    self.packInfoCell.selectionStyle = UITableViewCellSelectionStyleNone;
}

/// "常用大小" menu; rebuilt for each selection because the usable range depends on it.
- (UITableViewCell *)makePresetCell {
    __weak typeof(self) weak = self;
    NSMutableArray *actions = [NSMutableArray array];
    for (NSNumber *mb in @[ @5, @10, @20, @25, @50, @100, @200, @500 ]) {
        long long bytes = mb.longLongValue * MB;
        if (bytes < self.packMin || bytes >= self.totalBytes) continue;
        NSString *title = mb.integerValue == 25 ? L(@"25 MB（常见邮件附件上限）") : [NSString stringWithFormat:@"%@ MB", mb];
        [actions addObject:[UIAction actionWithTitle:title image:nil identifier:nil handler:^(__kindof UIAction *a) {
            typeof(self) strong = weak;
            if (!strong) return;
            strong.packSlider.value = AMLogPosition(bytes, strong.packMin, strong.totalBytes);
            [strong.packSlider sendActionsForControlEvents:UIControlEventValueChanged];
        }]];
    }
    for (NSNumber *pct in @[ @50, @25, @10 ]) {
        long long bytes = self.totalBytes * pct.longLongValue / 100;
        if (bytes < self.packMin) continue;
        [actions addObject:[UIAction actionWithTitle:[NSString stringWithFormat:L(@"原始大小的 %@%%"), pct] image:nil identifier:nil handler:^(__kindof UIAction *a) {
            typeof(self) strong = weak;
            if (!strong) return;
            strong.packSlider.value = AMLogPosition(bytes, strong.packMin, strong.totalBytes);
            [strong.packSlider sendActionsForControlEvents:UIControlEventValueChanged];
        }]];
    }
    return [AMForm menuCellWithTitle:L(@"常用大小") buttonTitle:L(@"选择") menu:[UIMenu menuWithTitle:@"" children:actions]];
}

#pragma mark - State

- (void)rebuildLayout {
    NSMutableArray *sections = [NSMutableArray array];
    if (self.assets.count == 0) { self.layout = sections; return; }
    if (self.mode == 0) {
        [sections addObject:[AMPSection header:L(@"处理方式") footer:L(@"通过降低分辨率和画质来减小体积，适合分享、上传和节省空间。") cells:@[ self.modeCell ]]];
        if (self.imageCount - self.gifCount > 0) {
            NSArray *cells = @[ self.targetModeCell, self.targetMode == 0 ? self.ratioCell : self.sizeCell, self.estimateCell ];
            NSString *footer = self.targetMode == 0 ? L(@"比例越小，文件越小，分辨率和细节损失越多。")
                                                    : L(@"适合有大小限制的场合，例如证件照上传要求“不超过 200 KB”。已经足够小的照片保持不变。");
            [sections addObject:[AMPSection header:L(@"压缩程度") footer:footer cells:cells]];
            [sections addObject:[AMPSection header:L(@"图片设置") footer:L(@"HEIC 体积更小，但部分电脑和旧设备无法直接打开。GIF 动图不会被压缩。") cells:@[ self.edgeCell, self.formatCell, self.locationCell ]]];
        }
        if (self.videoCount > 0)
            [sections addObject:[AMPSection header:L(@"视频") footer:L(@"压缩视频会降低分辨率并重新编码，耗时较长。") cells:@[ self.videoCell ]]];
        NSMutableArray *save = [NSMutableArray arrayWithObject:self.destCell];
        NSString *saveFooter;
        switch (self.destination) {
        case AMPDestinationAlbum:
            if (self.canDeleteOriginals) [save addObject:self.deleteCell];
            saveFooter = self.canDeleteOriginals ? L(@"压缩后的照片保留原来的拍摄时间。删除的原图会移到“最近删除”，30 天内可以恢复。")
                                                 : L(@"压缩后的照片保留原来的拍摄时间，原图不受影响。");
            break;
        case AMPDestinationFiles: saveFooter = L(@"保存到“文件”页面中的新文件夹。"); break;
        case AMPDestinationZip: saveFooter = L(@"保存为一个 ZIP 压缩包，方便直接发送。"); break;
        }
        [sections addObject:[AMPSection header:L(@"保存") footer:saveFooter cells:save]];
        if (self.imageCount - self.gifCount > 0)
            [sections addObject:[AMPSection header:nil footer:L(@"用第一张照片和当前设置生成预览，可以左右滑动对比原图。") cells:@[ self.previewCell ]]];
    } else {
        [sections addObject:[AMPSection header:L(@"处理方式") footer:L(@"把照片和视频打包成一个压缩包，方便传输和备份。") cells:@[ self.modeCell ]]];
        if (self.canLimitPack) {
            NSMutableArray *cells = [NSMutableArray arrayWithObject:self.limitCell];
            if (self.limitSize) {
                self.presetCell = [self makePresetCell];
                [cells addObjectsFromArray:@[ self.packSliderCell, self.presetCell, self.packInfoCell ]];
            }
            NSString *footer = self.limitSize ? L(@"为满足目标大小，照片会按比例压缩（降低分辨率和画质）；视频和 GIF 保持原样。")
                                              : L(@"不限制时保留原始画质。");
            [sections addObject:[AMPSection header:L(@"压缩包大小") footer:footer cells:cells]];
        }
    }
    self.layout = sections;
}

- (void)refresh {
    BOOL has = self.assets.count > 0;
    self.tableView.backgroundView = has ? nil : self.hero;
    self.tableView.tableHeaderView = has ? self.header : nil;
    self.tableView.tableFooterView = has ? self.footer : nil;
    self.tableView.scrollEnabled = has;
    if (has) {
        NSMutableArray *parts = [NSMutableArray array];
        if (self.imageCount) [parts addObject:[NSString stringWithFormat:L(@"%ld 张照片"), (long)self.imageCount]];
        if (self.videoCount) [parts addObject:[NSString stringWithFormat:L(@"%ld 个视频"), (long)self.videoCount]];
        self.headerLabel.text = [NSString stringWithFormat:L(@"已选择 %@ · 共 %@"), [parts componentsJoinedByString:L(@"、")], [AMUI byteString:self.totalBytes]];
        UIButtonConfiguration *c = self.actionButton.configuration;
        c.title = self.mode == 0 ? L(@"开始压缩") : L(@"打包压缩…");
        c.image = [UIImage systemImageNamed:self.mode == 0 ? @"arrow.down.right.and.arrow.up.left" : @"doc.zipper"];
        self.actionButton.configuration = c;
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:L(@"重新选择") style:UIBarButtonItemStylePlain target:self action:@selector(pickPhotos)];
        self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:L(@"清除") style:UIBarButtonItemStylePlain target:self action:@selector(clearSelection)];
    } else {
        self.navigationItem.rightBarButtonItem = nil;
        self.navigationItem.leftBarButtonItem = nil;
    }
    [self rebuildLayout];
    [self.strip reloadData];
    [self.tableView reloadData];
    [self updateEstimate];
    [self.view setNeedsLayout];
}

- (void)setDetail:(NSString *)detail forCell:(UITableViewCell *)cell {
    UIListContentConfiguration *c = (UIListContentConfiguration *)cell.contentConfiguration;
    c.secondaryText = detail;
    cell.contentConfiguration = c;
}

- (void)updateEstimate {
    if (self.assets.count == 0) return;
    long long est = 0;
    if (self.targetMode == 0) {
        est = (long long)(self.imageBytes * self.ratio);
    } else {
        long long target = self.perImageTarget;
        for (AMPickedAsset *a in self.compressibleImages) est += MIN((long long)[AMUI sizeOfItemAtURL:a.url], target);
    }
    [self setDetail:[NSString stringWithFormat:L(@"%@ → 约 %@"), [AMUI byteString:self.imageBytes], [AMUI byteString:est]] forCell:self.estimateCell];
    [self setDetail:[NSString stringWithFormat:L(@"%@（目标 %@）"), [AMUI byteString:self.totalBytes], [AMUI byteString:self.packTarget]] forCell:self.packInfoCell];
}

- (void)clearSelection {
    [NSFileManager.defaultManager removeItemAtURL:self.stagingDir error:nil];
    self.assets = @[];
    self.imageCount = self.videoCount = self.gifCount = 0;
    self.imageBytes = self.otherBytes = self.totalBytes = 0;
    self.deleteOriginals = NO;
    UISwitch *sw = (UISwitch *)self.deleteCell.accessoryView;
    sw.on = NO;
    [self.thumbs removeAllObjects];
    [self refresh];
}

- (void)setPickedAssets:(NSArray<AMPickedAsset *> *)assets {
    self.assets = assets;
    NSInteger images = 0, videos = 0, gifs = 0;
    long long imageBytes = 0, other = 0;
    for (AMPickedAsset *a in assets) {
        long long size = (long long)[AMUI sizeOfItemAtURL:a.url];
        if (a.isVideo) { videos++; other += size; continue; }
        images++;
        if ([self isCompressibleImage:a]) imageBytes += size;
        else { gifs++; other += size; }
    }
    self.imageCount = images;
    self.videoCount = videos;
    self.gifCount = gifs;
    self.imageBytes = imageBytes;
    self.otherBytes = other;
    self.totalBytes = imageBytes + other;
    // Default pack target: 25 MB if that's a real reduction, otherwise half the original.
    long long def = (25 * MB < self.totalBytes * 0.8) ? 25 * MB : self.totalBytes / 2;
    self.packPosition = AMLogPosition(def, self.packMin, self.totalBytes);
    self.packSlider.value = self.packPosition;
    [self.packSlider sendActionsForControlEvents:UIControlEventValueChanged];
    [self refresh];
}

- (void)loadFileURLs:(NSArray<NSURL *> *)urls {
    [self clearSelection];
    NSURL *dir = [self.stagingDir URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSMutableArray *assets = [NSMutableArray array];
    for (NSURL *u in urls) {
        AMFileKind k = [AMFileItem kindForFileName:u.lastPathComponent];
        if (k != AMFileKindImage && k != AMFileKindVideo) continue;
        NSURL *dest = [AMUI uniqueURLForName:u.lastPathComponent inDirectory:dir];
        if (![NSFileManager.defaultManager copyItemAtURL:u toURL:dest error:nil]) continue;
        AMPickedAsset *a = [AMPickedAsset new];
        a.url = dest;
        a.isVideo = k == AMFileKindVideo;
        [assets addObject:a];
    }
    self.mode = 0;
    UISegmentedControl *seg = nil;
    for (UIView *v in self.modeCell.contentView.subviews) if ([v isKindOfClass:UISegmentedControl.class]) seg = (UISegmentedControl *)v;
    seg.selectedSegmentIndex = 0;
    [self setPickedAssets:assets];
}

- (void)pickPhotos {
    PHPickerConfiguration *config = [[PHPickerConfiguration alloc] initWithPhotoLibrary:PHPhotoLibrary.sharedPhotoLibrary];
    config.selectionLimit = 0;
    config.filter = [PHPickerFilter anyFilterMatchingSubfilters:@[ PHPickerFilter.imagesFilter, PHPickerFilter.videosFilter ]];
    config.preferredAssetRepresentationMode = PHPickerConfigurationAssetRepresentationModeCurrent;
    config.selection = PHPickerConfigurationSelectionOrdered;
    PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:config];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    __weak typeof(self) weak = self;
    [picker dismissViewControllerAnimated:YES completion:^{
        typeof(self) strong = weak;
        if (!strong || results.count == 0) return;
        [strong clearSelection];
        NSURL *dir = [strong.stagingDir URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
        [AMActions importPickerResults:results into:dir imagesOnly:NO from:strong completion:^(NSArray<AMPickedAsset *> *assets) {
            [weak setPickedAssets:assets];
        }];
    }];
}

- (NSString *)stampedName:(NSString *)prefix {
    NSDateFormatter *f = [NSDateFormatter new];
    f.dateFormat = @"yyyy-MM-dd HH.mm.ss";
    return [NSString stringWithFormat:@"%@ %@", prefix, [f stringFromDate:NSDate.date]];
}

#pragma mark - Compress photos

- (void)runAction {
    if (self.assets.count == 0) return;
    if (self.mode == 0) [self runCompress];
    else [self runPack];
}

- (long long)budgetForImage:(AMPickedAsset *)a {
    long long size = (long long)[AMUI sizeOfItemAtURL:a.url];
    return self.targetMode == 0 ? MAX(10 * KB, (long long)(size * self.ratio)) : self.perImageTarget;
}

- (void)runCompress {
    NSArray<AMPickedAsset *> *images = self.compressibleImages;
    NSMutableArray<AMPickedAsset *> *videos = [NSMutableArray array];
    if (self.videoPreset > 0)
        for (AMPickedAsset *a in self.assets) if (a.isVideo) [videos addObject:a];
    if (images.count + videos.count == 0) {
        NSString *msg = self.videoCount ? L(@"请在“视频”中选择一种压缩方式，或选择照片。") : L(@"GIF 动图不会被压缩。");
        [AMUI showMessage:msg title:L(@"没有需要压缩的项目") from:self];
        return;
    }
    if (self.destination != AMPDestinationAlbum) { [self compressImages:images videos:videos]; return; }
    __weak typeof(self) weak = self;
    [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelAddOnly handler:^(PHAuthorizationStatus status) {
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strong = weak;
            if (!strong) return;
            if (status == PHAuthorizationStatusAuthorized || status == PHAuthorizationStatusLimited) [strong compressImages:images videos:videos];
            else [strong showSettingsAlert:L(@"无法存入相册") message:L(@"请在“设置”中允许“解压大师”添加照片，或把“保存到”改为“文件”页面。")];
        });
    }];
}

- (void)showSettingsAlert:(NSString *)title message:(NSString *)message {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:L(@"取消") style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:L(@"前往设置") style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        [UIApplication.sharedApplication openURL:[NSURL URLWithString:UIApplicationOpenSettingsURLString] options:@{} completionHandler:nil];
    }]];
    [[AMUI topPresenterFrom:self] presentViewController:a animated:YES completion:nil];
}

- (void)compressImages:(NSArray<AMPickedAsset *> *)images videos:(NSArray<AMPickedAsset *> *)videos {
    NSInteger maxEdge = AMEdges()[(NSUInteger)self.edgeIndex].integerValue;
    BOOL heic = self.heic, strip = self.stripLocation;
    NSString *preset = AMVideoPresets()[(NSUInteger)self.videoPreset];
    NSMutableDictionary<NSURL *, NSNumber *> *budgets = [NSMutableDictionary dictionary];
    for (AMPickedAsset *a in images) budgets[a.url] = @([self budgetForImage:a]);
    NSURL *outDir = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[@"Compressed-" stringByAppendingString:NSUUID.UUID.UUIDString]] isDirectory:YES];
    NSUInteger total = images.count + videos.count;

    AMProgressController *p = [[AMProgressController alloc] initWithTitle:L(@"正在压缩…") symbol:@"arrow.down.right.and.arrow.up.left"];
    [p setProgress:0 detail:[NSString stringWithFormat:@"0 / %lu", (unsigned long)total]];
    AMArchiveTask *task = [AMArchiveTask new];
    p.cancelHandler = ^{ task.cancelled = YES; };
    id op = [AMUI beginLongOperation];
    __weak typeof(self) weak = self;
    [self presentViewController:p animated:YES completion:^{
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            [NSFileManager.defaultManager createDirectoryAtURL:outDir withIntermediateDirectories:YES attributes:nil error:nil];
            NSMutableArray<AMMediaResult *> *results = [NSMutableArray array];
            NSMutableArray<NSString *> *ids = [NSMutableArray array];
            NSInteger failed = 0;
            for (NSUInteger i = 0; i < images.count && !task.cancelled; i++) {
                AMPickedAsset *a = images[i];
                @autoreleasepool {
                    AMMediaResult *r = [AMMediaCompressor compressImageAtURL:a.url toDirectory:outDir budget:budgets[a.url].longLongValue
                                                                     maxEdge:maxEdge heic:heic stripLocation:strip];
                    if (r) {
                        [results addObject:r];
                        if (a.assetIdentifier && !r.keptOriginal) [ids addObject:a.assetIdentifier];
                    } else {
                        failed++;
                    }
                }
                NSUInteger done = i + 1;
                NSString *name = a.url.lastPathComponent;
                dispatch_async(dispatch_get_main_queue(), ^{
                    [p setProgress:(double)done / total detail:[NSString stringWithFormat:@"%lu / %lu · %@", (unsigned long)done, (unsigned long)total, name]];
                });
            }
            for (NSUInteger j = 0; j < videos.count && !task.cancelled; j++) {
                AMPickedAsset *a = videos[j];
                NSUInteger base = images.count + j;
                NSString *name = a.url.lastPathComponent;
                AMMediaResult *r = [AMMediaCompressor compressVideoAtURL:a.url toDirectory:outDir preset:preset cancelled:^BOOL {
                    return task.cancelled;
                } progress:^(float f) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [p setProgress:(base + f) / total detail:[NSString stringWithFormat:@"%lu / %lu · %@", (unsigned long)base + 1, (unsigned long)total, name]];
                    });
                }];
                if (r) {
                    [results addObject:r];
                    if (a.assetIdentifier && !r.keptOriginal) [ids addObject:a.assetIdentifier];
                } else if (!task.cancelled) {
                    failed++;
                }
            }
            BOOL cancelled = task.cancelled;
            dispatch_async(dispatch_get_main_queue(), ^{
                [AMUI endLongOperation:op];
                [p dismissViewControllerAnimated:YES completion:^{
                    typeof(self) strong = weak;
                    if (cancelled || !strong || results.count == 0) {
                        [NSFileManager.defaultManager removeItemAtURL:outDir error:nil];
                        if (!cancelled && strong) [AMUI showMessage:L(@"这些项目无法处理。") title:L(@"压缩失败") from:strong];
                        return;
                    }
                    [strong deliver:results ids:ids fromDir:outDir failed:failed];
                }];
            });
        });
    }];
}

- (NSString *)summaryForResults:(NSArray<AMMediaResult *> *)results failed:(NSInteger)failed {
    long long inImg = 0, outImg = 0, inVid = 0, outVid = 0;
    NSInteger nImg = 0, nVid = 0, kept = 0;
    for (AMMediaResult *r in results) {
        if (r.keptOriginal) kept++;
        if (r.isVideo) { nVid++; inVid += r.originalBytes; outVid += r.bytes; }
        else { nImg++; inImg += r.originalBytes; outImg += r.bytes; }
    }
    NSMutableArray *lines = [NSMutableArray array];
    if (nImg) {
        double pct = inImg > 0 ? 100.0 * (double)(inImg - outImg) / (double)inImg : 0;
        [lines addObject:[NSString stringWithFormat:L(@"%ld 张照片：%@ → %@，减小 %.0f%%"), (long)nImg, [AMUI byteString:inImg], [AMUI byteString:outImg], MAX(0, pct)]];
    }
    if (nVid) {
        double pct = inVid > 0 ? 100.0 * (double)(inVid - outVid) / (double)inVid : 0;
        [lines addObject:[NSString stringWithFormat:L(@"%ld 个视频：%@ → %@，减小 %.0f%%"), (long)nVid, [AMUI byteString:inVid], [AMUI byteString:outVid], MAX(0, pct)]];
    }
    if (kept) [lines addObject:[NSString stringWithFormat:L(@"%ld 项已经足够小，保持原样。"), (long)kept]];
    if (failed) [lines addObject:[NSString stringWithFormat:L(@"%ld 项无法处理。"), (long)failed]];
    return [lines componentsJoinedByString:@"\n"];
}

- (void)deliver:(NSArray<AMMediaResult *> *)results ids:(NSArray<NSString *> *)ids fromDir:(NSURL *)outDir failed:(NSInteger)failed {
    NSString *summary = [self summaryForResults:results failed:failed];
    NSFileManager *fm = NSFileManager.defaultManager;
    __weak typeof(self) weak = self;
    switch (self.destination) {
    case AMPDestinationAlbum: {
        NSMutableArray<AMMediaResult *> *toSave = [NSMutableArray array];
        for (AMMediaResult *r in results) if (!r.keptOriginal) [toSave addObject:r];
        if (toSave.count == 0) {
            [fm removeItemAtURL:outDir error:nil];
            [self showResultTitle:L(@"无需保存") message:[summary stringByAppendingString:L(@"\n没有生成更小的新照片。")] url:nil];
            return;
        }
        BOOL deleteOriginals = self.deleteOriginals && ids.count > 0;
        [PHPhotoLibrary.sharedPhotoLibrary performChanges:^{
            for (AMMediaResult *r in toSave) {
                PHAssetCreationRequest *req = [PHAssetCreationRequest creationRequestForAsset];
                PHAssetResourceCreationOptions *o = [PHAssetResourceCreationOptions new];
                o.shouldMoveFile = YES;
                [req addResourceWithType:r.isVideo ? PHAssetResourceTypeVideo : PHAssetResourceTypePhoto fileURL:r.url options:o];
                if (r.captureDate) req.creationDate = r.captureDate;  // keep its place in the timeline
                if (r.location) req.location = r.location;
            }
        } completionHandler:^(BOOL success, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [fm removeItemAtURL:outDir error:nil];
                typeof(self) strong = weak;
                if (!strong) return;
                if (!success) {
                    [AMUI hapticError];
                    [AMUI showError:error title:L(@"无法存入相册") from:strong];
                    return;
                }
                [AMUI hapticSuccess];
                NSString *title = [NSString stringWithFormat:L(@"已存入相册（%lu 项）"), (unsigned long)toSave.count];
                if (deleteOriginals) [strong deleteOriginals:ids title:title summary:summary];
                else [strong showResultTitle:title message:summary url:nil];
            });
        }];
        break;
    }
    case AMPDestinationFiles: {
        NSURL *dest;
        NSError *error = nil;
        BOOL ok;
        if (results.count == 1) {
            dest = [AMUI uniqueURLForName:results[0].url.lastPathComponent inDirectory:AMUI.documentsURL];
            ok = [fm moveItemAtURL:results[0].url toURL:dest error:&error];
            [fm removeItemAtURL:outDir error:nil];
        } else {
            dest = [AMUI uniqueURLForName:[self stampedName:L(@"压缩的照片")] inDirectory:AMUI.documentsURL];
            ok = [fm moveItemAtURL:outDir toURL:dest error:&error];
        }
        if (!ok) {
            [fm removeItemAtURL:outDir error:nil];
            [AMUI showError:error title:L(@"无法保存") from:self];
            return;
        }
        [AMUI hapticSuccess];
        [self showResultTitle:[NSString stringWithFormat:L(@"已保存到“%@”"), dest.lastPathComponent] message:summary url:dest];
        break;
    }
    case AMPDestinationZip: {
        AMCompressSettings *s = [AMCompressSettings new];
        s.name = [self stampedName:L(@"压缩的照片")];
        s.format = AM_FMT_ZIP;
        s.level = 0;  // JPEG/HEIC/MP4 are already compressed; storing is fastest
        NSMutableArray *urls = [NSMutableArray array];
        for (AMMediaResult *r in results) [urls addObject:r.url];
        [AMActions compressItems:urls settings:s into:AMUI.documentsURL from:self completion:^(NSURL *result) {
            [fm removeItemAtURL:outDir error:nil];
            if (result) [weak showResultTitle:[NSString stringWithFormat:L(@"已创建“%@”"), result.lastPathComponent] message:summary url:result];
        }];
        break;
    }
    }
}

/// Moves the originals to "Recently Deleted" (the system asks the user to confirm).
- (void)deleteOriginals:(NSArray<NSString *> *)ids title:(NSString *)title summary:(NSString *)summary {
    __weak typeof(self) weak = self;
    [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelReadWrite handler:^(PHAuthorizationStatus status) {
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strong = weak;
            if (!strong) return;
            if (status != PHAuthorizationStatusAuthorized && status != PHAuthorizationStatusLimited) {
                [strong showResultTitle:title message:[summary stringByAppendingString:L(@"\n\n原图未删除：需要允许“解压大师”访问照片。")] url:nil];
                return;
            }
            PHFetchResult<PHAsset *> *assets = [PHAsset fetchAssetsWithLocalIdentifiers:ids options:nil];
            if (assets.count == 0) {
                [strong showResultTitle:title message:[summary stringByAppendingString:L(@"\n\n原图未删除：无法访问这些照片，请在“设置”中允许访问所有照片，或手动删除。")] url:nil];
                return;
            }
            NSUInteger missing = ids.count - assets.count;
            [PHPhotoLibrary.sharedPhotoLibrary performChanges:^{
                [PHAssetChangeRequest deleteAssets:assets];
            } completionHandler:^(BOOL success, NSError *error) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    NSString *extra;
                    if (success && missing == 0) extra = L(@"\n\n原图已移到“最近删除”。");
                    else if (success) extra = [NSString stringWithFormat:L(@"\n\n已删除 %lu 张原图，另有 %lu 张无法访问，请手动删除。"), (unsigned long)assets.count, (unsigned long)missing];
                    else extra = L(@"\n\n原图未删除。");
                    [weak showResultTitle:title message:[summary stringByAppendingString:extra] url:nil];
                });
            }];
        });
    }];
}

#pragma mark - Preview

- (void)previewEffect {
    AMPickedAsset *first = self.compressibleImages.firstObject;
    if (!first) return;
    long long budget = [self budgetForImage:first];
    NSInteger maxEdge = AMEdges()[(NSUInteger)self.edgeIndex].integerValue;
    BOOL heic = self.heic, strip = self.stripLocation;
    NSURL *dir = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[@"PreviewCompress-" stringByAppendingString:NSUUID.UUID.UUIDString]] isDirectory:YES];
    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    [spinner startAnimating];
    self.previewCell.accessoryView = spinner;
    self.previewCell.userInteractionEnabled = NO;
    __weak typeof(self) weak = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
        AMMediaResult *r = [AMMediaCompressor compressImageAtURL:first.url toDirectory:dir budget:budget maxEdge:maxEdge heic:heic stripLocation:strip];
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strong = weak;
            if (!strong) return;
            strong.previewCell.accessoryView = nil;
            strong.previewCell.userInteractionEnabled = YES;
            if (!r) {
                [NSFileManager.defaultManager removeItemAtURL:dir error:nil];
                [AMUI showMessage:L(@"这张照片无法处理。") title:L(@"无法预览") from:strong];
                return;
            }
            NSString *before = [NSString stringWithFormat:L(@"原图 · %@ · %ld×%ld"), [AMUI byteString:r.originalBytes], (long)r.originalWidth, (long)r.originalHeight];
            double pct = r.originalBytes > 0 ? 100.0 * (double)(r.originalBytes - r.bytes) / (double)r.originalBytes : 0;
            NSString *after = r.keptOriginal ? L(@"已经足够小，保持原样")
                                             : [NSString stringWithFormat:L(@"压缩后 · %@ · %ld×%ld（-%.0f%%）"), [AMUI byteString:r.bytes], (long)r.width, (long)r.height, MAX(0, pct)];
            AMQuickLook *ql = [[AMQuickLook alloc] initWithItems:@[ [AMPreviewItem itemWithURL:first.url title:before], [AMPreviewItem itemWithURL:r.url title:after] ] index:1];
            ql.onDismiss = ^{ [NSFileManager.defaultManager removeItemAtURL:dir error:nil]; };
            [strong presentViewController:ql animated:YES completion:nil];
        });
    });
}

#pragma mark - Pack

- (void)runPack {
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    for (AMPickedAsset *a in self.assets) [urls addObject:a.url];
    AMCompressViewController *opts = [[AMCompressViewController alloc] initWithItems:urls suggestedName:[self stampedName:L(@"照片")]];
    BOOL limit = self.limitSize && self.canLimitPack;
    long long target = self.packTarget;
    __weak typeof(self) weak = self;
    opts.onConfirm = ^(AMCompressSettings *s) {
        typeof(self) strong = weak;
        if (!strong) return;
        if (limit) [strong packFitting:s target:target];
        else [AMActions compressItems:urls settings:s into:AMUI.documentsURL from:strong completion:^(NSURL *result) {
            if (result) [weak showResultTitle:[NSString stringWithFormat:L(@"已创建“%@”"), result.lastPathComponent]
                                      message:[NSString stringWithFormat:L(@"大小 %@，已保存在“文件”页面。"), [AMUI byteString:(long long)[AMUI sizeOfItemAtURL:result]]]
                                          url:result];
        }];
    };
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:opts];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:nav animated:YES completion:nil];
}

/// Compresses the photos just enough that the whole archive lands near `target`, then packs.
- (void)packFitting:(AMCompressSettings *)s target:(long long)target {
    NSArray<AMPickedAsset *> *images = self.compressibleImages;
    NSMutableArray<AMPickedAsset *> *others = [NSMutableArray array];
    for (AMPickedAsset *a in self.assets) if (![self isCompressibleImage:a]) [others addObject:a];
    long long overhead = 8 * KB + 512 * (long long)self.assets.count;
    long long imageBudget = target - self.otherBytes - overhead;
    if (imageBudget < (long long)images.count * 20 * KB) {
        [AMUI showMessage:[NSString stringWithFormat:L(@"视频和 GIF 等无法压缩的文件共 %@，已接近或超过目标大小 %@。请调大目标，或去掉部分视频。"),
                                                     [AMUI byteString:self.otherBytes], [AMUI byteString:target]]
                    title:L(@"无法达到目标大小") from:self];
        return;
    }
    long long imageTotal = self.imageBytes;
    BOOL heic = NO, strip = self.stripLocation;  // JPEG inside archives opens everywhere
    NSURL *fitDir = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[@"Fit-" stringByAppendingString:NSUUID.UUID.UUIDString]] isDirectory:YES];

    AMProgressController *p = [[AMProgressController alloc] initWithTitle:L(@"正在压缩照片…") symbol:@"arrow.down.right.and.arrow.up.left"];
    [p setProgress:0 detail:[NSString stringWithFormat:L(@"目标 %@"), [AMUI byteString:target]]];
    AMArchiveTask *task = [AMArchiveTask new];
    p.cancelHandler = ^{ task.cancelled = YES; };
    id op = [AMUI beginLongOperation];
    __weak typeof(self) weak = self;
    [self presentViewController:p animated:YES completion:^{
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSFileManager *fm = NSFileManager.defaultManager;
            [fm createDirectoryAtURL:fitDir withIntermediateDirectories:YES attributes:nil error:nil];
            NSMutableArray<NSURL *> *fitted = [NSMutableArray array];
            for (NSUInteger i = 0; i < images.count && !task.cancelled; i++) {
                @autoreleasepool {
                    AMPickedAsset *a = images[i];
                    long long size = (long long)[AMUI sizeOfItemAtURL:a.url];
                    long long budget = imageTotal > 0 ? (long long)((double)imageBudget * (double)size / (double)imageTotal) : size;
                    NSURL *out = nil;
                    if (budget >= size) {
                        out = [AMUI uniqueURLForName:a.url.lastPathComponent inDirectory:fitDir];
                        if (![fm linkItemAtURL:a.url toURL:out error:nil] && ![fm copyItemAtURL:a.url toURL:out error:nil]) out = nil;
                    } else {
                        out = [AMMediaCompressor compressImageAtURL:a.url toDirectory:fitDir budget:budget maxEdge:0 heic:heic stripLocation:strip].url;
                    }
                    if (out) [fitted addObject:out];
                    NSUInteger done = i + 1;
                    NSString *name = a.url.lastPathComponent;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [p setProgress:(double)done / images.count detail:[NSString stringWithFormat:@"%lu / %lu · %@", (unsigned long)done, (unsigned long)images.count, name]];
                    });
                }
            }
            for (AMPickedAsset *a in others) {
                NSURL *out = [AMUI uniqueURLForName:a.url.lastPathComponent inDirectory:fitDir];
                if ([fm linkItemAtURL:a.url toURL:out error:nil] || [fm copyItemAtURL:a.url toURL:out error:nil]) [fitted addObject:out];
            }
            BOOL cancelled = task.cancelled;
            dispatch_async(dispatch_get_main_queue(), ^{
                [AMUI endLongOperation:op];
                [p dismissViewControllerAnimated:YES completion:^{
                    typeof(self) strong = weak;
                    if (cancelled || !strong || fitted.count == 0) {
                        [fm removeItemAtURL:fitDir error:nil];
                        return;
                    }
                    [AMActions compressItems:fitted settings:s into:AMUI.documentsURL from:strong completion:^(NSURL *result) {
                        [fm removeItemAtURL:fitDir error:nil];
                        if (!result) return;
                        long long size = (long long)[AMUI sizeOfItemAtURL:result];
                        NSString *msg = [NSString stringWithFormat:L(@"目标 %@，实际 %@。"), [AMUI byteString:target], [AMUI byteString:size]];
                        if (size > target * 1.05) msg = [msg stringByAppendingString:L(@"部分照片已压缩到最小，仍略超出目标。")];
                        [weak showResultTitle:[NSString stringWithFormat:L(@"已创建“%@”"), result.lastPathComponent] message:msg url:result];
                    }];
                }];
            });
        });
    }];
}

#pragma mark - Results

- (void)showResultTitle:(NSString *)title message:(NSString *)message url:(NSURL *)url {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    if (url) {
        NSNumber *isDir = nil;
        [url getResourceValue:&isDir forKey:NSURLIsDirectoryKey error:nil];
        if (!isDir.boolValue) {
            __weak typeof(self) weak = self;
            [a addAction:[UIAlertAction actionWithTitle:L(@"分享") style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
                typeof(self) strong = weak;
                if (strong) [AMUI share:@[ url ] from:strong sourceView:strong.actionButton barItem:nil];
            }]];
        }
        [a addAction:[UIAlertAction actionWithTitle:L(@"在“文件”中查看") style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
            [NSNotificationCenter.defaultCenter postNotificationName:AMRevealInFilesNotification object:url];
        }]];
    }
    [a addAction:[UIAlertAction actionWithTitle:L(@"好") style:UIAlertActionStyleCancel handler:nil]];
    [[AMUI topPresenterFrom:self] presentViewController:a animated:YES completion:nil];
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return (NSInteger)self.layout.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)self.layout[(NSUInteger)section].cells.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    return self.layout[(NSUInteger)indexPath.section].cells[(NSUInteger)indexPath.row];
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return self.layout[(NSUInteger)section].header;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return self.layout[(NSUInteger)section].footer;
}

- (BOOL)tableView:(UITableView *)tableView shouldHighlightRowAtIndexPath:(NSIndexPath *)indexPath {
    return [self tableView:tableView cellForRowAtIndexPath:indexPath] == self.previewCell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if ([self tableView:tableView cellForRowAtIndexPath:indexPath] == self.previewCell) [self previewEffect];
}

#pragma mark - Strip

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    return (NSInteger)self.assets.count;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    AMThumbCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"thumb" forIndexPath:indexPath];
    AMPickedAsset *asset = self.assets[(NSUInteger)indexPath.item];
    NSURL *url = asset.url;
    cell.url = url;
    cell.badge.hidden = !asset.isVideo;
    cell.imageView.image = [self.thumbs objectForKey:url];
    cell.isAccessibilityElement = YES;
    cell.accessibilityLabel = url.lastPathComponent;
    if (!cell.imageView.image) {
        CGFloat scale = self.traitCollection.displayScale > 0 ? self.traitCollection.displayScale : 2;
        QLThumbnailGenerationRequest *req = [[QLThumbnailGenerationRequest alloc] initWithFileAtURL:url size:CGSizeMake(84, 84) scale:scale
                                                                              representationTypes:QLThumbnailGenerationRequestRepresentationTypeThumbnail];
        __weak typeof(self) weak = self;
        [QLThumbnailGenerator.sharedGenerator generateBestRepresentationForRequest:req completionHandler:^(QLThumbnailRepresentation *rep, NSError *error) {
            UIImage *img = rep.UIImage;
            if (!img) return;
            dispatch_async(dispatch_get_main_queue(), ^{
                [weak.thumbs setObject:img forKey:url];
                if ([cell.url isEqual:url]) cell.imageView.image = img;
            });
        }];
    }
    return cell;
}

@end
