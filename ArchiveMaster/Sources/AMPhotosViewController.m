#import "AMPhotosViewController.h"
#import "AMActions.h"
#import "AMFileItem.h"
#import "AMProgressController.h"
#import "AMUI.h"
#import <ImageIO/ImageIO.h>
#import <Photos/Photos.h>
#import <PhotosUI/PhotosUI.h>
#import <QuickLookThumbnailing/QuickLookThumbnailing.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

typedef NS_ENUM(NSInteger, AMPSection) { AMPSectionMode, AMPSectionQuality, AMPSectionDestination };
typedef NS_ENUM(NSInteger, AMPDestination) { AMPDestinationAlbum, AMPDestinationFiles, AMPDestinationZip };

static NSArray<NSNumber *> *AMMaxSizes(void) { return @[ @0, @4096, @2560, @1920, @1280 ]; }

static BOOL AMCanEncodeHEIC(void) {
    NSArray *types = CFBridgingRelease(CGImageDestinationCopyTypeIdentifiers());
    return [types containsObject:UTTypeHEIC.identifier];
}

/// Re-encodes one image. Returns the output URL (or nil) and its size.
static NSURL *AMSlimImage(NSURL *src, NSURL *outDir, float quality, NSInteger maxDim, BOOL heic, BOOL stripLocation, long long *outSize) {
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)src, NULL);
    if (!source) return nil;
    NSDictionary *props = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL));
    NSInteger w = [props[(id)kCGImagePropertyPixelWidth] integerValue];
    NSInteger h = [props[(id)kCGImagePropertyPixelHeight] integerValue];
    NSInteger longest = MAX(w, h);
    if (longest <= 0) { CFRelease(source); return nil; }
    NSInteger target = (maxDim > 0 && maxDim < longest) ? maxDim : longest;
    NSDictionary *opts = @{
        (id)kCGImageSourceCreateThumbnailFromImageAlways : @YES,
        (id)kCGImageSourceCreateThumbnailWithTransform : @YES,
        (id)kCGImageSourceThumbnailMaxPixelSize : @(target),
        (id)kCGImageSourceShouldCacheImmediately : @YES,
    };
    CGImageRef image = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)opts);
    if (!image) { CFRelease(source); return nil; }

    // Keep capture metadata, but the pixels are now upright and possibly smaller.
    NSMutableDictionary *meta = [props mutableCopy];
    [meta removeObjectsForKeys:@[ (id)kCGImagePropertyPixelWidth, (id)kCGImagePropertyPixelHeight, (id)kCGImagePropertyOrientation ]];
    meta[(id)kCGImagePropertyOrientation] = @1;
    NSMutableDictionary *tiff = [meta[(id)kCGImagePropertyTIFFDictionary] mutableCopy];
    if (tiff) { tiff[(id)kCGImagePropertyTIFFOrientation] = @1; meta[(id)kCGImagePropertyTIFFDictionary] = tiff; }
    NSMutableDictionary *exif = [meta[(id)kCGImagePropertyExifDictionary] mutableCopy];
    if (exif) {
        [exif removeObjectsForKeys:@[ (id)kCGImagePropertyExifPixelXDimension, (id)kCGImagePropertyExifPixelYDimension ]];
        meta[(id)kCGImagePropertyExifDictionary] = exif;
    }
    if (stripLocation) [meta removeObjectForKey:(id)kCGImagePropertyGPSDictionary];
    meta[(id)kCGImageDestinationLossyCompressionQuality] = @(quality);

    UTType *type = heic ? UTTypeHEIC : UTTypeJPEG;
    NSString *name = [src.lastPathComponent.stringByDeletingPathExtension stringByAppendingPathExtension:heic ? @"heic" : @"jpg"];
    NSURL *dst = [AMUI uniqueURLForName:name inDirectory:outDir];
    CGImageDestinationRef dest = CGImageDestinationCreateWithURL((__bridge CFURLRef)dst, (__bridge CFStringRef)type.identifier, 1, NULL);
    BOOL ok = NO;
    if (dest) {
        CGImageDestinationAddImage(dest, image, (__bridge CFDictionaryRef)meta);
        ok = CGImageDestinationFinalize(dest);
        CFRelease(dest);
    }
    CGImageRelease(image);
    CFRelease(source);
    if (!ok) { [NSFileManager.defaultManager removeItemAtURL:dst error:nil]; return nil; }

    long long srcSize = (long long)[AMUI sizeOfItemAtURL:src];
    long long dstSize = (long long)[AMUI sizeOfItemAtURL:dst];
    // Never make a photo bigger: if re-encoding to the same type at full size didn't help, keep the original.
    UTType *srcType = [UTType typeWithFilenameExtension:src.pathExtension];
    if (dstSize >= srcSize && target == longest && srcType && [srcType conformsToType:type]) {
        [NSFileManager.defaultManager removeItemAtURL:dst error:nil];
        dst = [AMUI uniqueURLForName:src.lastPathComponent inDirectory:outDir];
        if (![NSFileManager.defaultManager copyItemAtURL:src toURL:dst error:nil]) return nil;
        dstSize = srcSize;
    }
    if (outSize) *outSize = dstSize;
    return dst;
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

#pragma mark - Controller

@interface AMPhotosViewController () <PHPickerViewControllerDelegate, UICollectionViewDataSource>
@property (nonatomic, strong) NSURL *stagingDir;
@property (nonatomic, copy) NSArray<NSURL *> *assets;
@property (nonatomic) NSInteger imageCount, videoCount;
@property (nonatomic) long long totalBytes;
@property (nonatomic) NSInteger mode;  // 0 pack, 1 slim
@property (nonatomic) float quality;
@property (nonatomic) NSInteger maxSizeIndex;
@property (nonatomic) BOOL heic;
@property (nonatomic) BOOL stripLocation;
@property (nonatomic) AMPDestination destination;

@property (nonatomic, strong) UIView *hero;
@property (nonatomic, strong) UIView *header;
@property (nonatomic, strong) UILabel *headerLabel;
@property (nonatomic, strong) UICollectionView *strip;
@property (nonatomic, strong) UIView *footer;
@property (nonatomic, strong) UIButton *actionButton;
@property (nonatomic, strong) UITableViewCell *modeCell, *qualityCell, *sizeCell, *formatCell, *locationCell, *destCell;
@property (nonatomic, strong) NSCache<NSURL *, UIImage *> *thumbs;
@end

@implementation AMPhotosViewController

- (instancetype)init {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _assets = @[];
        _quality = 0.7f;
        _stripLocation = YES;
        _thumbs = [NSCache new];
        _stagingDir = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"PhotoStaging"] isDirectory:YES];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"相册";
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
    if (self.assets.count && ![NSFileManager.defaultManager fileExistsAtPath:self.assets.firstObject.path]) [self clearSelection];
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

#pragma mark - Building

- (UIButton *)filledButton:(NSString *)title symbol:(NSString *)symbol action:(SEL)action {
    UIButtonConfiguration *c = [UIButtonConfiguration filledButtonConfiguration];
    c.title = title;
    if (symbol) {
        c.image = [UIImage systemImageNamed:symbol];
        c.imagePadding = 8;
    }
    c.buttonSize = UIButtonConfigurationSizeLarge;
    c.cornerStyle = UIButtonConfigurationCornerStyleLarge;
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
    title.text = @"压缩相册里的照片";
    title.font = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle2];
    title.adjustsFontForContentSizeCategory = YES;
    title.textAlignment = NSTextAlignmentCenter;
    title.numberOfLines = 0;
    UILabel *body = [UILabel new];
    body.text = @"选择照片和视频，可以原画质打包成 ZIP、7Z 等压缩包，也可以给图片“瘦身”，在保持清晰的同时大幅减小体积。";
    body.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    body.adjustsFontForContentSizeCategory = YES;
    body.textColor = UIColor.secondaryLabelColor;
    body.textAlignment = NSTextAlignmentCenter;
    body.numberOfLines = 0;
    UIButton *pick = [self filledButton:@"选择照片" symbol:@"photo.on.rectangle" action:@selector(pickPhotos)];
    UILabel *privacy = [UILabel new];
    privacy.text = @"只有你选中的照片会被读取。";
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
        [self.headerLabel.leadingAnchor constraintEqualToAnchor:h.leadingAnchor constant:20],
        [self.headerLabel.trailingAnchor constraintEqualToAnchor:h.trailingAnchor constant:-20],
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
    self.actionButton = [self filledButton:@"打包压缩…" symbol:@"doc.zipper" action:@selector(runAction)];
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
    self.modeCell = [AMForm segmentedCellWithItems:@[ @"打包压缩", @"图片瘦身" ] selected:0 handler:^(NSInteger index) {
        weak.mode = index;
        [weak refresh];
    }];
    self.qualityCell = [AMForm sliderCellWithTitle:@"画质" value:self.quality min:0.3f max:1.0f format:^NSString *(float v) {
        return [NSString stringWithFormat:@"%ld%%", lroundf(v * 100)];
    } handler:^(float v) {
        weak.quality = v;
    }];
    self.sizeCell = [AMForm popupCellWithTitle:@"最长边" options:@[ @"保持原尺寸", @"4096 像素", @"2560 像素", @"1920 像素", @"1280 像素" ] selected:0 handler:^(NSInteger index) {
        weak.maxSizeIndex = index;
    }];
    NSArray *formats = AMCanEncodeHEIC() ? @[ @"JPEG（兼容性好）", @"HEIC（体积更小）" ] : @[ @"JPEG" ];
    self.formatCell = [AMForm popupCellWithTitle:@"格式" options:formats selected:0 handler:^(NSInteger index) {
        weak.heic = index == 1;
    }];
    self.locationCell = [AMForm switchCellWithTitle:@"移除位置信息" on:YES handler:^(BOOL on) {
        weak.stripLocation = on;
    } outSwitch:nil];
    self.destCell = [AMForm popupCellWithTitle:@"保存到" options:@[ @"相册", @"“文件”页面", @"ZIP 压缩包" ] selected:0 handler:^(NSInteger index) {
        weak.destination = (AMPDestination)index;
    }];
}

#pragma mark - State

- (void)refresh {
    BOOL has = self.assets.count > 0;
    self.tableView.backgroundView = has ? nil : self.hero;
    self.tableView.tableHeaderView = has ? self.header : nil;
    self.tableView.tableFooterView = has ? self.footer : nil;
    self.tableView.scrollEnabled = has;
    if (has) {
        NSMutableArray *parts = [NSMutableArray array];
        if (self.imageCount) [parts addObject:[NSString stringWithFormat:@"%ld 张照片", (long)self.imageCount]];
        if (self.videoCount) [parts addObject:[NSString stringWithFormat:@"%ld 个视频", (long)self.videoCount]];
        self.headerLabel.text = [NSString stringWithFormat:@"已选择 %@ · 共 %@", [parts componentsJoinedByString:@"、"], [AMUI byteString:self.totalBytes]];
        UIButtonConfiguration *c = self.actionButton.configuration;
        c.title = self.mode == 0 ? @"打包压缩…" : @"开始瘦身";
        c.image = [UIImage systemImageNamed:self.mode == 0 ? @"doc.zipper" : @"wand.and.stars"];
        self.actionButton.configuration = c;
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"重新选择" style:UIBarButtonItemStylePlain target:self action:@selector(pickPhotos)];
        self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"清除" style:UIBarButtonItemStylePlain target:self action:@selector(clearSelection)];
    } else {
        self.navigationItem.rightBarButtonItem = nil;
        self.navigationItem.leftBarButtonItem = nil;
    }
    [self.strip reloadData];
    [self.tableView reloadData];
    [self.view setNeedsLayout];
}

- (void)clearSelection {
    [NSFileManager.defaultManager removeItemAtURL:self.stagingDir error:nil];
    self.assets = @[];
    self.imageCount = self.videoCount = 0;
    self.totalBytes = 0;
    [self.thumbs removeAllObjects];
    [self refresh];
}

- (void)pickPhotos {
    PHPickerConfiguration *config = [PHPickerConfiguration new];
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
        [AMActions importPickerResults:results into:dir imagesOnly:NO from:strong completion:^(NSArray<NSURL *> *urls) {
            [weak setPickedAssets:urls];
        }];
    }];
}

- (void)setPickedAssets:(NSArray<NSURL *> *)urls {
    self.assets = urls;
    NSInteger images = 0, videos = 0;
    long long total = 0;
    for (NSURL *u in urls) {
        AMFileKind k = [AMFileItem kindForFileName:u.lastPathComponent];
        if (k == AMFileKindVideo) videos++;
        else images++;
        total += (long long)[AMUI sizeOfItemAtURL:u];
    }
    self.imageCount = images;
    self.videoCount = videos;
    self.totalBytes = total;
    [self refresh];
}

- (NSString *)stampedName:(NSString *)prefix {
    NSDateFormatter *f = [NSDateFormatter new];
    f.dateFormat = @"yyyy-MM-dd HH.mm.ss";
    return [NSString stringWithFormat:@"%@ %@", prefix, [f stringFromDate:NSDate.date]];
}

#pragma mark - Actions

- (void)runAction {
    if (self.assets.count == 0) return;
    if (self.mode == 0) [self pack];
    else [self slim];
}

- (void)pack {
    __weak typeof(self) weak = self;
    [AMActions compressItems:self.assets suggestedName:[self stampedName:@"照片"] into:AMUI.documentsURL from:self completion:^(NSURL *result) {
        if (result) [weak showResultTitle:[NSString stringWithFormat:@"已创建“%@”", result.lastPathComponent]
                                  message:[NSString stringWithFormat:@"大小 %@，已保存在“文件”页面。", [AMUI byteString:(long long)[AMUI sizeOfItemAtURL:result]]]
                                      url:result];
    }];
}

- (void)slim {
    NSMutableArray *images = [NSMutableArray array];
    for (NSURL *u in self.assets) {
        NSString *ext = u.pathExtension.lowercaseString;
        if ([AMFileItem kindForFileName:u.lastPathComponent] == AMFileKindImage && ![ext isEqualToString:@"gif"]) [images addObject:u];
    }
    if (images.count == 0) {
        [AMUI showMessage:@"图片瘦身只处理照片（不含视频和 GIF 动图）。" title:@"没有可处理的照片" from:self];
        return;
    }
    if (self.destination != AMPDestinationAlbum) { [self slimImages:images]; return; }
    __weak typeof(self) weak = self;
    [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelAddOnly handler:^(PHAuthorizationStatus status) {
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strong = weak;
            if (!strong) return;
            if (status == PHAuthorizationStatusAuthorized || status == PHAuthorizationStatusLimited) {
                [strong slimImages:images];
                return;
            }
            UIAlertController *a = [UIAlertController alertControllerWithTitle:@"无法存入相册"
                                                                       message:@"请在“设置”中允许“解压大师”添加照片，或将“保存到”改为“文件”页面。"
                                                                preferredStyle:UIAlertControllerStyleAlert];
            [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
            [a addAction:[UIAlertAction actionWithTitle:@"前往设置" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
                [UIApplication.sharedApplication openURL:[NSURL URLWithString:UIApplicationOpenSettingsURLString] options:@{} completionHandler:nil];
            }]];
            [strong presentViewController:a animated:YES completion:nil];
        });
    }];
}

- (void)slimImages:(NSArray<NSURL *> *)images {
    float quality = self.quality;
    NSInteger maxDim = AMMaxSizes()[(NSUInteger)self.maxSizeIndex].integerValue;
    BOOL heic = self.heic, strip = self.stripLocation;
    NSURL *outDir = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[@"Slim-" stringByAppendingString:NSUUID.UUID.UUIDString]] isDirectory:YES];

    AMProgressController *p = [[AMProgressController alloc] initWithTitle:@"正在处理图片…" symbol:@"wand.and.stars"];
    [p setProgress:0 detail:[NSString stringWithFormat:@"0 / %lu", (unsigned long)images.count]];
    AMArchiveTask *task = [AMArchiveTask new];
    p.cancelHandler = ^{ task.cancelled = YES; };
    __weak typeof(self) weak = self;
    [self presentViewController:p animated:YES completion:^{
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            [NSFileManager.defaultManager createDirectoryAtURL:outDir withIntermediateDirectories:YES attributes:nil error:nil];
            NSMutableArray<NSURL *> *outputs = [NSMutableArray array];
            long long inBytes = 0, outBytes = 0;
            for (NSUInteger i = 0; i < images.count && !task.cancelled; i++) {
                @autoreleasepool {
                    long long size = 0;
                    NSURL *out = AMSlimImage(images[i], outDir, quality, maxDim, heic, strip, &size);
                    if (out) {
                        [outputs addObject:out];
                        inBytes += (long long)[AMUI sizeOfItemAtURL:images[i]];
                        outBytes += size;
                    }
                }
                NSUInteger done = i + 1;
                NSString *name = images[i].lastPathComponent;
                dispatch_async(dispatch_get_main_queue(), ^{
                    [p setProgress:(double)done / images.count detail:[NSString stringWithFormat:@"%lu / %lu · %@", (unsigned long)done, (unsigned long)images.count, name]];
                });
            }
            BOOL cancelled = task.cancelled;
            dispatch_async(dispatch_get_main_queue(), ^{
                [p dismissViewControllerAnimated:YES completion:^{
                    typeof(self) strong = weak;
                    if (cancelled || !strong || outputs.count == 0) {
                        [NSFileManager.defaultManager removeItemAtURL:outDir error:nil];
                        if (!cancelled && strong) [AMUI showMessage:@"这些照片无法处理。" title:@"处理失败" from:strong];
                        return;
                    }
                    [strong deliver:outputs fromDir:outDir inBytes:inBytes outBytes:outBytes];
                }];
            });
        });
    }];
}

- (NSString *)savingsTextIn:(long long)inBytes out:(long long)outBytes count:(NSUInteger)count {
    if (outBytes >= inBytes || inBytes == 0)
        return [NSString stringWithFormat:@"%lu 张照片，体积没有明显变化。可以尝试降低画质或缩小尺寸。", (unsigned long)count];
    double pct = 100.0 * (double)(inBytes - outBytes) / (double)inBytes;
    return [NSString stringWithFormat:@"%lu 张照片：%@ → %@，节省 %.0f%%。", (unsigned long)count, [AMUI byteString:inBytes], [AMUI byteString:outBytes], pct];
}

- (void)deliver:(NSArray<NSURL *> *)outputs fromDir:(NSURL *)outDir inBytes:(long long)inBytes outBytes:(long long)outBytes {
    NSString *summary = [self savingsTextIn:inBytes out:outBytes count:outputs.count];
    NSFileManager *fm = NSFileManager.defaultManager;
    __weak typeof(self) weak = self;
    switch (self.destination) {
    case AMPDestinationAlbum: {
        [PHPhotoLibrary.sharedPhotoLibrary performChanges:^{
            for (NSURL *u in outputs) {
                PHAssetCreationRequest *r = [PHAssetCreationRequest creationRequestForAsset];
                PHAssetResourceCreationOptions *o = [PHAssetResourceCreationOptions new];
                o.shouldMoveFile = YES;
                [r addResourceWithType:PHAssetResourceTypePhoto fileURL:u options:o];
            }
        } completionHandler:^(BOOL success, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [fm removeItemAtURL:outDir error:nil];
                typeof(self) strong = weak;
                if (!strong) return;
                if (success) {
                    [AMUI hapticSuccess];
                    [strong showResultTitle:@"已存入相册" message:summary url:nil];
                } else {
                    [AMUI showError:error title:@"无法存入相册" from:strong];
                }
            });
        }];
        break;
    }
    case AMPDestinationFiles: {
        NSURL *dest = [AMUI uniqueURLForName:[self stampedName:@"瘦身照片"] inDirectory:AMUI.documentsURL];
        NSError *error = nil;
        if ([fm moveItemAtURL:outDir toURL:dest error:&error]) {
            [AMUI hapticSuccess];
            [self showResultTitle:[NSString stringWithFormat:@"已保存到“%@”", dest.lastPathComponent] message:summary url:dest];
        } else {
            [fm removeItemAtURL:outDir error:nil];
            [AMUI showError:error title:@"无法保存" from:self];
        }
        break;
    }
    case AMPDestinationZip: {
        AMCompressSettings *s = [AMCompressSettings new];
        s.name = [self stampedName:@"瘦身照片"];
        s.format = AM_FMT_ZIP;
        s.level = 0;  // JPEG/HEIC are already compressed; storing is fastest.
        [AMActions compressItems:outputs settings:s into:AMUI.documentsURL from:self completion:^(NSURL *result) {
            [fm removeItemAtURL:outDir error:nil];
            if (result) [weak showResultTitle:[NSString stringWithFormat:@"已创建“%@”", result.lastPathComponent] message:summary url:result];
        }];
        break;
    }
    }
}

- (void)showResultTitle:(NSString *)title message:(NSString *)message url:(NSURL *)url {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    if (url) {
        NSNumber *isDir = nil;
        [url getResourceValue:&isDir forKey:NSURLIsDirectoryKey error:nil];
        if (!isDir.boolValue) {
            __weak typeof(self) weak = self;
            [a addAction:[UIAlertAction actionWithTitle:@"分享" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
                typeof(self) strong = weak;
                if (strong) [AMUI share:@[ url ] from:strong sourceView:strong.actionButton barItem:nil];
            }]];
        }
        [a addAction:[UIAlertAction actionWithTitle:@"在“文件”中查看" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
            [NSNotificationCenter.defaultCenter postNotificationName:AMRevealInFilesNotification object:url];
        }]];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
    [[AMUI topPresenterFrom:self] presentViewController:a animated:YES completion:nil];
}

#pragma mark - Table

- (NSArray<NSNumber *> *)sections {
    if (self.assets.count == 0) return @[];
    if (self.mode == 0) return @[ @(AMPSectionMode) ];
    return @[ @(AMPSectionMode), @(AMPSectionQuality), @(AMPSectionDestination) ];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return (NSInteger)self.sections.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch ((AMPSection)self.sections[(NSUInteger)section].integerValue) {
    case AMPSectionMode: return 1;
    case AMPSectionQuality: return 4;
    case AMPSectionDestination: return 1;
    }
    return 0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    switch ((AMPSection)self.sections[(NSUInteger)indexPath.section].integerValue) {
    case AMPSectionMode: return self.modeCell;
    case AMPSectionQuality: return @[ self.qualityCell, self.sizeCell, self.formatCell, self.locationCell ][(NSUInteger)indexPath.row];
    case AMPSectionDestination: return self.destCell;
    }
    return self.modeCell;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch ((AMPSection)self.sections[(NSUInteger)section].integerValue) {
    case AMPSectionMode: return @"处理方式";
    case AMPSectionQuality: return @"图片设置";
    case AMPSectionDestination: return nil;
    }
    return nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    switch ((AMPSection)self.sections[(NSUInteger)section].integerValue) {
    case AMPSectionMode:
        return self.mode == 0 ? @"保留原始文件和画质，把照片和视频打包成一个压缩包，方便传输和备份。"
                              : @"重新编码图片以减小体积，适合分享和节省空间。原照片不会被修改，视频和 GIF 不参与瘦身。";
    case AMPSectionQuality: return @"画质 70% 左右通常肉眼难以分辨。HEIC 体积更小，但部分电脑和旧设备无法直接打开。";
    case AMPSectionDestination: return nil;
    }
    return nil;
}

- (BOOL)tableView:(UITableView *)tableView shouldHighlightRowAtIndexPath:(NSIndexPath *)indexPath {
    return NO;
}

#pragma mark - Strip

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    return (NSInteger)self.assets.count;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    AMThumbCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"thumb" forIndexPath:indexPath];
    NSURL *url = self.assets[(NSUInteger)indexPath.item];
    cell.url = url;
    cell.badge.hidden = [AMFileItem kindForFileName:url.lastPathComponent] != AMFileKindVideo;
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
