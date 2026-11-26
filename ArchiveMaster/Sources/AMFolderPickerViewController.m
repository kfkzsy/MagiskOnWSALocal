#import "AMFolderPickerViewController.h"
#import "AMArchiver.h"
#import "AMFileItem.h"
#import "AMMediaCompressor.h"
#import "AMUI.h"
#import <AVFoundation/AVFoundation.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@interface AMFolderPickerViewController ()
@property (nonatomic, strong) NSURL *directory;
@property (nonatomic, copy) NSString *actionTitle;
@property (nonatomic, copy) NSArray<NSURL *> *excluded;
@property (nonatomic, copy) void (^onPick)(NSURL *);
@property (nonatomic, copy) NSArray<AMFileItem *> *folders;
@end

@implementation AMFolderPickerViewController

+ (void)presentFrom:(UIViewController *)vc title:(NSString *)title actionTitle:(NSString *)actionTitle excluded:(NSArray<NSURL *> *)excluded onPick:(void (^)(NSURL *))onPick {
    AMFolderPickerViewController *root = [[AMFolderPickerViewController alloc] initWithDirectory:AMUI.documentsURL actionTitle:actionTitle excluded:excluded onPick:onPick];
    root.navigationItem.prompt = title;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:root];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    [[AMUI topPresenterFrom:vc] presentViewController:nav animated:YES completion:nil];
}

- (instancetype)initWithDirectory:(NSURL *)dir actionTitle:(NSString *)actionTitle excluded:(NSArray<NSURL *> *)excluded onPick:(void (^)(NSURL *))onPick {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _directory = dir;
        _actionTitle = [actionTitle copy];
        _excluded = [excluded copy];
        _onPick = [onPick copy];
        _folders = @[];
    }
    return self;
}

- (BOOL)isExcluded:(NSURL *)url {
    for (NSURL *e in self.excluded)
        if ([AMUI url:url isInsideDirectory:e]) return YES;
    return NO;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    BOOL root = [self.directory.URLByResolvingSymlinksInPath.path isEqualToString:AMUI.documentsURL.URLByResolvingSymlinksInPath.path];
    self.title = root ? L(@"文件") : self.directory.lastPathComponent;
    [self.tableView registerClass:UITableViewCell.class forCellReuseIdentifier:@"folder"];
    __weak typeof(self) weak = self;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel primaryAction:[UIAction actionWithHandler:^(__kindof UIAction *a) {
        [weak.navigationController dismissViewControllerAnimated:YES completion:nil];
    }]];
    UIBarButtonItem *newFolder = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"folder.badge.plus"] style:UIBarButtonItemStylePlain target:self action:@selector(newFolder)];
    newFolder.accessibilityLabel = L(@"新建文件夹");
    UIBarButtonItem *pick = [[UIBarButtonItem alloc] initWithTitle:self.actionTitle style:UIBarButtonItemStyleDone target:self action:@selector(pickHere)];
    pick.enabled = ![self isExcluded:self.directory];
    UIBarButtonItem *flex = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
    self.toolbarItems = @[ newFolder, flex, pick ];
    [self reload];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.navigationController setToolbarHidden:NO animated:animated];
}

- (void)reload {
    NSMutableArray *folders = [NSMutableArray array];
    for (AMFileItem *i in [AMFileItem itemsInDirectory:self.directory sort:AMSortByName])
        if (i.isDirectory) [folders addObject:i];
    self.folders = folders;
    [self.tableView reloadData];
}

- (void)pickHere {
    void (^cb)(NSURL *) = self.onPick;
    NSURL *dir = self.directory;
    [self.navigationController dismissViewControllerAnimated:YES completion:^{
        if (cb) cb(dir);
    }];
}

- (void)newFolder {
    __weak typeof(self) weak = self;
    [AMUI promptWithTitle:L(@"新建文件夹") message:nil placeholder:L(@"名称") initial:L(@"未命名文件夹") secure:NO confirmTitle:L(@"创建") from:self handler:^(NSString *text) {
        typeof(self) strong = weak;
        NSString *name = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!strong || name.length == 0) return;
        if ([name hasPrefix:@"."]) name = [name substringFromIndex:1];
        NSURL *dest = [AMUI uniqueURLForName:name inDirectory:strong.directory];
        [NSFileManager.defaultManager createDirectoryAtURL:dest withIntermediateDirectories:NO attributes:nil error:nil];
        [strong reload];
    }];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)self.folders.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return self.folders.count ? nil : L(@"这里没有文件夹。");
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"folder" forIndexPath:indexPath];
    AMFileItem *item = self.folders[(NSUInteger)indexPath.row];
    BOOL excluded = [self isExcluded:item.url];
    UIListContentConfiguration *c = [UIListContentConfiguration cellConfiguration];
    c.text = item.name;
    c.textProperties.color = excluded ? UIColor.tertiaryLabelColor : UIColor.labelColor;
    c.image = [UIImage systemImageNamed:@"folder.fill"];
    c.imageProperties.tintColor = excluded ? UIColor.tertiaryLabelColor : UIColor.systemBlueColor;
    cell.contentConfiguration = c;
    cell.accessoryType = excluded ? UITableViewCellAccessoryNone : UITableViewCellAccessoryDisclosureIndicator;
    cell.selectionStyle = excluded ? UITableViewCellSelectionStyleNone : UITableViewCellSelectionStyleDefault;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    AMFileItem *item = self.folders[(NSUInteger)indexPath.row];
    if ([self isExcluded:item.url]) return;
    AMFolderPickerViewController *next = [[AMFolderPickerViewController alloc] initWithDirectory:item.url actionTitle:self.actionTitle excluded:self.excluded onPick:self.onPick];
    next.navigationItem.prompt = self.navigationItem.prompt;
    [self.navigationController pushViewController:next animated:YES];
}

@end

#pragma mark - Info

@interface AMInfoViewController ()
@property (nonatomic, strong) NSURL *url;
@property (nonatomic, strong) NSMutableArray<NSArray<NSString *> *> *rows;
@end

@implementation AMInfoViewController

+ (void)presentForURL:(NSURL *)url from:(UIViewController *)vc {
    AMInfoViewController *info = [[AMInfoViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    info.url = url;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:info];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    if (nav.sheetPresentationController) {
        nav.sheetPresentationController.detents = @[ UISheetPresentationControllerDetent.mediumDetent, UISheetPresentationControllerDetent.largeDetent ];
        nav.sheetPresentationController.prefersGrabberVisible = YES;
    }
    [[AMUI topPresenterFrom:vc] presentViewController:nav animated:YES completion:nil];
}

static NSString *AMFullDate(NSDate *d) {
    if (!d) return @"—";
    return [NSDateFormatter localizedStringFromDate:d dateStyle:NSDateFormatterLongStyle timeStyle:NSDateFormatterShortStyle];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = L(@"简介");
    __weak typeof(self) weak = self;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone primaryAction:[UIAction actionWithHandler:^(__kindof UIAction *a) {
        [weak.navigationController dismissViewControllerAnimated:YES completion:nil];
    }]];
    [self.tableView registerClass:UITableViewCell.class forCellReuseIdentifier:@"row"];
    self.rows = [NSMutableArray array];

    NSURL *url = self.url;
    NSDictionary *v = [url resourceValuesForKeys:@[ NSURLIsDirectoryKey, NSURLFileSizeKey, NSURLCreationDateKey, NSURLContentModificationDateKey ] error:nil];
    BOOL isDir = [v[NSURLIsDirectoryKey] boolValue];
    [self add:L(@"名称") value:url.lastPathComponent];
    NSString *kind;
    if (isDir) kind = L(@"文件夹");
    else if ([AMArchiver isArchiveURL:url]) kind = [AMArchiver kindForArchive:url.lastPathComponent];
    else kind = [UTType typeWithFilenameExtension:url.pathExtension].localizedDescription ?: url.pathExtension.uppercaseString;
    [self add:L(@"类型") value:kind ?: @"—"];
    if (!isDir) {
        long long size = [v[NSURLFileSizeKey] longLongValue];
        NSString *bytes = [NSNumberFormatter localizedStringFromNumber:@(size) numberStyle:NSNumberFormatterDecimalStyle];
        [self add:L(@"大小") value:[NSString stringWithFormat:L(@"%@（%@ 字节）"), [AMUI byteString:size], bytes]];
    }
    NSString *docs = AMUI.documentsURL.URLByResolvingSymlinksInPath.path;
    NSString *parent = url.URLByDeletingLastPathComponent.URLByResolvingSymlinksInPath.path;
    NSString *rel = [parent hasPrefix:docs] ? [parent substringFromIndex:docs.length] : parent;
    NSMutableArray *crumbs = [NSMutableArray arrayWithObject:L(@"文件")];
    for (NSString *c in rel.pathComponents) if (![c isEqualToString:@"/"]) [crumbs addObject:c];
    [self add:L(@"位置") value:[crumbs componentsJoinedByString:@" › "]];
    [self add:L(@"创建时间") value:AMFullDate(v[NSURLCreationDateKey])];
    [self add:L(@"修改时间") value:AMFullDate(v[NSURLContentModificationDateKey])];

    AMFileKind fileKind = isDir ? AMFileKindFolder : [AMFileItem kindForFileName:url.lastPathComponent];
    if (fileKind == AMFileKindImage) [self addImageDetails];
    if (fileKind == AMFileKindVideo || fileKind == AMFileKindAudio) {
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
        double secs = CMTimeGetSeconds(asset.duration);
        if (secs > 0) {
            NSDateComponentsFormatter *f = [NSDateComponentsFormatter new];
            f.allowedUnits = secs >= 3600 ? (NSCalendarUnitHour | NSCalendarUnitMinute | NSCalendarUnitSecond) : (NSCalendarUnitMinute | NSCalendarUnitSecond);
            f.zeroFormattingBehavior = NSDateComponentsFormatterZeroFormattingBehaviorPad;
            [self add:L(@"时长") value:[f stringFromTimeInterval:secs] ?: @"—"];
        }
    }
    if (isDir) {
        [self add:L(@"包含") value:L(@"正在计算…")];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            NSInteger files = 0, folders = 0;
            for (NSURL *u in [NSFileManager.defaultManager enumeratorAtURL:url includingPropertiesForKeys:@[ NSURLIsDirectoryKey ] options:0 errorHandler:nil]) {
                NSNumber *d = nil;
                [u getResourceValue:&d forKey:NSURLIsDirectoryKey error:nil];
                if (d.boolValue) folders++; else files++;
            }
            unsigned long long size = [AMUI sizeOfItemAtURL:url];
            dispatch_async(dispatch_get_main_queue(), ^{
                [weak set:L(@"包含") value:[NSString stringWithFormat:L(@"%ld 个文件，%ld 个文件夹"), (long)files, (long)folders]];
                [weak add:L(@"大小") value:[AMUI byteString:(long long)size]];
                [weak.tableView reloadData];
            });
        });
    }
    if (fileKind == AMFileKindArchive) {
        [self add:L(@"内容") value:L(@"正在读取…")];
        [AMArchiver listArchive:url completion:^(NSArray<AMArchiveEntry *> *entries, BOOL truncated, NSError *error) {
            if (error) { [weak set:L(@"内容") value:error.localizedDescription]; [weak.tableView reloadData]; return; }
            long long total = 0;
            NSInteger files = 0, encrypted = 0;
            for (AMArchiveEntry *e in entries) {
                if (e.isDirectory) continue;
                files++;
                if (e.size > 0) total += e.size;
                if (e.encrypted) encrypted++;
            }
            [weak set:L(@"内容") value:[NSString stringWithFormat:L(@"%ld 个文件，解压后约 %@"), (long)files, [AMUI byteString:total]]];
            if (encrypted) [weak add:L(@"加密") value:[NSString stringWithFormat:L(@"%ld 个文件已加密"), (long)encrypted]];
            NSArray *vols = [AMArchiver volumesForArchive:url];
            if (vols.count > 1) [weak add:L(@"分卷") value:[NSString stringWithFormat:L(@"共 %lu 个分卷"), (unsigned long)vols.count]];
            [weak.tableView reloadData];
        }];
    }
}

- (void)addImageDetails {
    CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)self.url, NULL);
    if (!src) return;
    NSDictionary *p = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(src, 0, NULL));
    CFRelease(src);
    CGSize size = [AMMediaCompressor pixelSizeOfImageAtURL:self.url];
    if (size.width > 0) {
        double mp = size.width * size.height / 1e6;
        [self add:L(@"尺寸") value:[NSString stringWithFormat:L(@"%.0f × %.0f 像素（%.1f 百万像素）"), size.width, size.height, mp]];
    }
    NSDictionary *tiff = p[(id)kCGImagePropertyTIFFDictionary];
    NSString *make = tiff[(id)kCGImagePropertyTIFFMake], *model = tiff[(id)kCGImagePropertyTIFFModel];
    if ([model isKindOfClass:NSString.class]) {
        NSString *camera = ([make isKindOfClass:NSString.class] && ![model hasPrefix:make]) ? [NSString stringWithFormat:@"%@ %@", make, model] : model;
        [self add:L(@"相机") value:camera];
    }
    NSString *taken = p[(id)kCGImagePropertyExifDictionary][(id)kCGImagePropertyExifDateTimeOriginal];
    if ([taken isKindOfClass:NSString.class]) [self add:L(@"拍摄时间") value:taken];
    if (p[(id)kCGImagePropertyGPSDictionary]) [self add:L(@"位置信息") value:L(@"包含 GPS 位置")];
}

- (void)add:(NSString *)title value:(NSString *)value {
    [self.rows addObject:@[ title, value ?: @"—" ]];
}

- (void)set:(NSString *)title value:(NSString *)value {
    for (NSUInteger i = 0; i < self.rows.count; i++)
        if ([self.rows[i][0] isEqualToString:title]) { self.rows[i] = @[ title, value ?: @"—" ]; return; }
    [self add:title value:value];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)self.rows.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"row" forIndexPath:indexPath];
    NSArray<NSString *> *row = self.rows[(NSUInteger)indexPath.row];
    UIListContentConfiguration *c = [UIListContentConfiguration valueCellConfiguration];
    c.text = row[0];
    c.secondaryText = row[1];
    c.secondaryTextProperties.numberOfLines = 0;
    c.textProperties.color = UIColor.secondaryLabelColor;
    c.secondaryTextProperties.color = UIColor.labelColor;
    cell.contentConfiguration = c;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    return cell;
}

- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath point:(CGPoint)point {
    NSString *value = self.rows[(NSUInteger)indexPath.row][1];
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu *(NSArray<UIMenuElement *> *s) {
        return [UIMenu menuWithTitle:@"" children:@[ [UIAction actionWithTitle:L(@"拷贝") image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil handler:^(__kindof UIAction *a) {
            UIPasteboard.generalPasteboard.string = value;
        }] ]];
    }];
}

@end
