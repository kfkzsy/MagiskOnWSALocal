#import "AMFileBrowserViewController.h"
#import "AMActions.h"
#import "AMArchiveContentsViewController.h"
#import "AMArchiver.h"
#import "AMFileItem.h"
#import "AMUI.h"
#import <PhotosUI/PhotosUI.h>
#import <QuickLook/QuickLook.h>
#import <QuickLookThumbnailing/QuickLookThumbnailing.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <fcntl.h>
#include <unistd.h>

@interface AMFileCell : UITableViewCell
@property (nonatomic, strong, nullable) NSURL *representedURL;
@end

@implementation AMFileCell
- (void)prepareForReuse {
    [super prepareForReuse];
    self.representedURL = nil;
}
@end

static NSCache<NSString *, UIImage *> *AMThumbCache(void) {
    static NSCache *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [NSCache new];
        cache.countLimit = 400;
    });
    return cache;
}

@interface AMFileBrowserViewController () <UISearchResultsUpdating, UIDocumentPickerDelegate, PHPickerViewControllerDelegate,
                                           QLPreviewControllerDataSource>
@property (nonatomic, readwrite) NSURL *directory;
@property (nonatomic, copy) NSArray<AMFileItem *> *allItems;
@property (nonatomic, copy) NSArray<AMFileItem *> *items;
@property (nonatomic, strong) UISearchController *search;
@property (nonatomic, strong) dispatch_source_t source;
@property (nonatomic, strong) UIBarButtonItem *addItem, *moreItem, *selectAllItem, *doneItem;
@property (nonatomic, strong) UIBarButtonItem *compressBarItem, *shareBarItem, *deleteBarItem;
@property (nonatomic, strong) UIDocumentPickerViewController *filePicker, *folderPicker;
@property (nonatomic, copy) NSArray<NSURL *> *previewURLs;
@property (nonatomic, strong) NSMutableSet<NSString *> *pendingThumbs;
@property (nonatomic, strong) UILabel *footerLabel;
@property (nonatomic, strong, nullable) NSURL *pendingReveal;
@end

@implementation AMFileBrowserViewController

- (instancetype)initWithDirectory:(NSURL *)directory {
    if ((self = [super initWithStyle:UITableViewStylePlain])) {
        _directory = directory;
        _allItems = @[];
        _items = @[];
        _pendingThumbs = [NSMutableSet set];
    }
    return self;
}

- (void)dealloc {
    if (_source) dispatch_source_cancel(_source);
}

- (BOOL)isRoot {
    return [self.directory.URLByResolvingSymlinksInPath.path isEqualToString:AMUI.documentsURL.URLByResolvingSymlinksInPath.path];
}

- (NSString *)defaultTitle {
    return self.isRoot ? @"文件" : self.directory.lastPathComponent;
}

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.defaultTitle;
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeAlways;

    UITableView *tv = self.tableView;
    [tv registerClass:AMFileCell.class forCellReuseIdentifier:@"file"];
    tv.rowHeight = UITableViewAutomaticDimension;
    tv.estimatedRowHeight = 64;
    tv.allowsMultipleSelectionDuringEditing = YES;
    tv.separatorInset = UIEdgeInsetsMake(0, 72, 0, 0);

    self.refreshControl = [UIRefreshControl new];
    [self.refreshControl addTarget:self action:@selector(pullToRefresh) forControlEvents:UIControlEventValueChanged];

    self.search = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.search.searchResultsUpdater = self;
    self.search.obscuresBackgroundDuringPresentation = NO;
    self.search.searchBar.placeholder = @"搜索";
    self.navigationItem.searchController = self.search;
    self.definesPresentationContext = YES;

    [self buildBarItems];
    [self setEditing:NO animated:NO];

    self.footerLabel = [UILabel new];
    self.footerLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    self.footerLabel.adjustsFontForContentSizeCategory = YES;
    self.footerLabel.textColor = UIColor.secondaryLabelColor;
    self.footerLabel.textAlignment = NSTextAlignmentCenter;
    self.footerLabel.frame = CGRectMake(0, 0, 320, 56);
    tv.tableFooterView = self.footerLabel;

    [self startMonitoring];
    [self reload];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(reload) name:UIApplicationWillEnterForegroundNotification object:nil];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reload];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (self.pendingReveal) {
        NSURL *u = self.pendingReveal;
        self.pendingReveal = nil;
        [self revealItemAtURL:u];
    }
}

- (void)buildBarItems {
    __weak typeof(self) weak = self;
    UIMenu *addMenu = [UIMenu menuWithTitle:@"" children:@[
        [UIAction actionWithTitle:@"从“文件”导入" image:[UIImage systemImageNamed:@"doc.badge.plus"] identifier:nil handler:^(__kindof UIAction *a) {
            [weak importFiles];
        }],
        [UIAction actionWithTitle:@"导入文件夹" image:[UIImage systemImageNamed:@"folder.badge.plus"] identifier:nil handler:^(__kindof UIAction *a) {
            [weak importFolder];
        }],
        [UIAction actionWithTitle:@"从相册导入" image:[UIImage systemImageNamed:@"photo.on.rectangle"] identifier:nil handler:^(__kindof UIAction *a) {
            [weak importPhotos];
        }],
        [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[
            [UIAction actionWithTitle:@"新建文件夹" image:[UIImage systemImageNamed:@"folder"] identifier:nil handler:^(__kindof UIAction *a) {
                [weak newFolder];
            }],
        ]],
    ]];
    self.addItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"plus"] menu:addMenu];
    self.addItem.accessibilityLabel = @"添加";
    self.moreItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"] menu:[self moreMenu]];
    self.moreItem.accessibilityLabel = @"更多";
    self.selectAllItem = [[UIBarButtonItem alloc] initWithTitle:@"全选" style:UIBarButtonItemStylePlain target:self action:@selector(toggleSelectAll)];
    self.doneItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(endSelecting)];

    self.compressBarItem = [[UIBarButtonItem alloc] initWithTitle:@"压缩" style:UIBarButtonItemStylePlain target:self action:@selector(compressSelected)];
    self.shareBarItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAction target:self action:@selector(shareSelected:)];
    self.deleteBarItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemTrash target:self action:@selector(deleteSelected:)];
    self.deleteBarItem.tintColor = UIColor.systemRedColor;
    UIBarButtonItem *flex = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
    self.toolbarItems = @[ self.compressBarItem, flex, self.shareBarItem, flex, self.deleteBarItem ];
}

- (UIMenu *)moreMenu {
    __weak typeof(self) weak = self;
    AMSortMode current = (AMSortMode)[NSUserDefaults.standardUserDefaults integerForKey:AMDefaultsSort];
    NSArray *titles = @[ @"名称", @"日期", @"大小", @"类型" ];
    NSMutableArray *sorts = [NSMutableArray array];
    for (NSInteger i = 0; i < (NSInteger)titles.count; i++) {
        UIAction *a = [UIAction actionWithTitle:titles[(NSUInteger)i] image:nil identifier:nil handler:^(__kindof UIAction *x) {
            [NSUserDefaults.standardUserDefaults setInteger:i forKey:AMDefaultsSort];
            [weak reload];
        }];
        a.state = i == current ? UIMenuElementStateOn : UIMenuElementStateOff;
        [sorts addObject:a];
    }
    return [UIMenu menuWithTitle:@"" children:@[
        [UIAction actionWithTitle:@"选择" image:[UIImage systemImageNamed:@"checkmark.circle"] identifier:nil handler:^(__kindof UIAction *a) {
            [weak setEditing:YES animated:YES];
        }],
        [UIMenu menuWithTitle:@"排序方式" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:sorts],
    ]];
}

#pragma mark - Data

- (void)pullToRefresh {
    [self reload];
    [self.refreshControl endRefreshing];
}

- (void)reload {
    if (!self.isViewLoaded) return;
    NSSet *selected = nil;
    if (self.isEditing) {
        NSMutableSet *s = [NSMutableSet set];
        for (NSIndexPath *ip in self.tableView.indexPathsForSelectedRows) [s addObject:self.items[(NSUInteger)ip.row].url.path];
        selected = s;
    }
    AMSortMode sort = (AMSortMode)[NSUserDefaults.standardUserDefaults integerForKey:AMDefaultsSort];
    self.allItems = [AMFileItem itemsInDirectory:self.directory sort:sort];
    [self applyFilter];
    if (selected.count) {
        [self.items enumerateObjectsUsingBlock:^(AMFileItem *item, NSUInteger idx, BOOL *stop) {
            if ([selected containsObject:item.url.path])
                [self.tableView selectRowAtIndexPath:[NSIndexPath indexPathForRow:(NSInteger)idx inSection:0] animated:NO scrollPosition:UITableViewScrollPositionNone];
        }];
    }
    self.moreItem.menu = [self moreMenu];
    [self updateFooter];
    [self updateToolbar];
}

- (void)applyFilter {
    NSString *q = self.search.searchBar.text;
    if (q.length) {
        NSPredicate *p = [NSPredicate predicateWithBlock:^BOOL(AMFileItem *i, NSDictionary *b) {
            return [i.name localizedCaseInsensitiveContainsString:q];
        }];
        self.items = [self.allItems filteredArrayUsingPredicate:p];
    } else {
        self.items = self.allItems;
    }
    [self.tableView reloadData];
    self.tableView.backgroundView = self.items.count ? nil : [self emptyViewSearching:q.length > 0];
}

- (UIView *)emptyViewSearching:(BOOL)searching {
    UIView *container = [UIView new];
    UIImageView *icon = [[UIImageView alloc] initWithImage:[AMUI symbol:searching ? @"magnifyingglass" : @"tray" pointSize:48]];
    icon.tintColor = UIColor.tertiaryLabelColor;
    UILabel *title = [UILabel new];
    title.text = searching ? @"无结果" : (self.isRoot ? @"还没有文件" : @"文件夹是空的");
    title.font = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle2];
    title.adjustsFontForContentSizeCategory = YES;
    title.textAlignment = NSTextAlignmentCenter;
    UILabel *body = [UILabel new];
    body.text = searching ? @"请尝试其他关键词。"
                          : @"点击右上角的 ＋ 从“文件”或相册导入，也可以在其他 App 中把压缩包分享到“解压大师”。";
    body.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    body.adjustsFontForContentSizeCategory = YES;
    body.textColor = UIColor.secondaryLabelColor;
    body.textAlignment = NSTextAlignmentCenter;
    body.numberOfLines = 0;
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[ icon, title, body ]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 8;
    stack.alignment = UIStackViewAlignmentCenter;
    [stack setCustomSpacing:14 afterView:icon];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.centerXAnchor constraintEqualToAnchor:container.centerXAnchor],
        [stack.centerYAnchor constraintEqualToAnchor:container.centerYAnchor constant:-40],
        [stack.widthAnchor constraintLessThanOrEqualToAnchor:container.widthAnchor constant:-64],
        [stack.widthAnchor constraintLessThanOrEqualToConstant:360],
    ]];
    return container;
}

- (void)updateFooter {
    NSDictionary *v = [self.directory resourceValuesForKeys:@[ NSURLVolumeAvailableCapacityForImportantUsageKey ] error:nil];
    NSNumber *free = v[NSURLVolumeAvailableCapacityForImportantUsageKey];
    NSString *count = [NSString stringWithFormat:@"%lu 个项目", (unsigned long)self.allItems.count];
    self.footerLabel.text = free ? [NSString stringWithFormat:@"%@，可用 %@", count, [AMUI byteString:free.longLongValue]] : count;
    self.footerLabel.hidden = self.items.count == 0;
}

- (void)startMonitoring {
    int fd = open(self.directory.fileSystemRepresentation, O_EVTONLY);
    if (fd < 0) return;
    dispatch_source_t s = dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE, (uintptr_t)fd,
                                                 DISPATCH_VNODE_WRITE | DISPATCH_VNODE_DELETE | DISPATCH_VNODE_RENAME,
                                                 dispatch_get_main_queue());
    __weak typeof(self) weak = self;
    dispatch_source_set_event_handler(s, ^{ [weak scheduleReload]; });
    dispatch_source_set_cancel_handler(s, ^{ close(fd); });
    dispatch_resume(s);
    self.source = s;
}

- (void)scheduleReload {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(reload) object:nil];
    [self performSelector:@selector(reload) withObject:nil afterDelay:0.3];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    [self applyFilter];
    [self updateFooter];
}

- (void)revealItemAtURL:(NSURL *)url {
    if (!self.isViewLoaded || !self.view.window) {
        self.pendingReveal = url;
        return;
    }
    [self reload];
    NSString *target = url.URLByResolvingSymlinksInPath.path;
    __block NSInteger row = NSNotFound;
    [self.items enumerateObjectsUsingBlock:^(AMFileItem *item, NSUInteger idx, BOOL *stop) {
        if ([item.url.URLByResolvingSymlinksInPath.path isEqualToString:target]) { row = (NSInteger)idx; *stop = YES; }
    }];
    if (row == NSNotFound || self.isEditing) return;
    NSIndexPath *ip = [NSIndexPath indexPathForRow:row inSection:0];
    [self.tableView scrollToRowAtIndexPath:ip atScrollPosition:UITableViewScrollPositionMiddle animated:YES];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (row >= (NSInteger)self.items.count || self.isEditing) return;
        [self.tableView selectRowAtIndexPath:ip animated:YES scrollPosition:UITableViewScrollPositionNone];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self.tableView deselectRowAtIndexPath:ip animated:YES];
        });
    });
}

#pragma mark - Table

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)self.items.count;
}

- (NSString *)thumbKeyForItem:(AMFileItem *)item {
    return [NSString stringWithFormat:@"%@|%.0f", item.url.path, item.modified.timeIntervalSince1970];
}

- (UIListContentConfiguration *)configurationForItem:(AMFileItem *)item thumbnail:(UIImage *)thumb {
    UIListContentConfiguration *c = [UIListContentConfiguration subtitleCellConfiguration];
    c.text = item.name;
    c.textProperties.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    c.textProperties.numberOfLines = 2;
    c.textProperties.lineBreakMode = NSLineBreakByTruncatingMiddle;
    c.secondaryText = item.subtitle;
    c.secondaryTextProperties.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    c.secondaryTextProperties.color = UIColor.secondaryLabelColor;
    c.textToSecondaryTextVerticalPadding = 3;
    if (thumb) {
        c.image = thumb;
        c.imageProperties.cornerRadius = 4;
        c.imageProperties.tintColor = nil;
    } else {
        c.image = [AMUI symbol:[AMFileItem symbolForKind:item.kind] pointSize:26];
        c.imageProperties.tintColor = [AMFileItem colorForKind:item.kind];
    }
    c.imageProperties.maximumSize = CGSizeMake(40, 40);
    c.imageProperties.reservedLayoutSize = CGSizeMake(40, 40);
    c.imageToTextPadding = 16;
    c.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(10, c.directionalLayoutMargins.leading, 10, c.directionalLayoutMargins.trailing);
    return c;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    AMFileCell *cell = [tableView dequeueReusableCellWithIdentifier:@"file" forIndexPath:indexPath];
    AMFileItem *item = self.items[(NSUInteger)indexPath.row];
    cell.representedURL = item.url;
    NSString *key = [self thumbKeyForItem:item];
    UIImage *thumb = item.wantsThumbnail ? [AMThumbCache() objectForKey:key] : nil;
    cell.contentConfiguration = [self configurationForItem:item thumbnail:thumb];
    cell.accessoryType = item.isDirectory ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
    if (item.wantsThumbnail && !thumb) [self loadThumbnailForItem:item key:key];
    return cell;
}

- (void)loadThumbnailForItem:(AMFileItem *)item key:(NSString *)key {
    if ([self.pendingThumbs containsObject:key]) return;
    [self.pendingThumbs addObject:key];
    CGFloat scale = self.traitCollection.displayScale > 0 ? self.traitCollection.displayScale : UIScreen.mainScreen.scale;
    QLThumbnailGenerationRequest *req = [[QLThumbnailGenerationRequest alloc] initWithFileAtURL:item.url
                                                                                         size:CGSizeMake(80, 80)
                                                                                        scale:scale
                                                                          representationTypes:QLThumbnailGenerationRequestRepresentationTypeThumbnail];
    __weak typeof(self) weak = self;
    [QLThumbnailGenerator.sharedGenerator generateBestRepresentationForRequest:req completionHandler:^(QLThumbnailRepresentation *rep, NSError *error) {
        UIImage *img = rep.UIImage;
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strong = weak;
            if (!strong) return;
            [strong.pendingThumbs removeObject:key];
            if (!img) return;
            [AMThumbCache() setObject:img forKey:key];
            for (UITableViewCell *c in strong.tableView.visibleCells) {
                if ([c isKindOfClass:AMFileCell.class] && [((AMFileCell *)c).representedURL isEqual:item.url])
                    c.contentConfiguration = [strong configurationForItem:item thumbnail:img];
            }
        });
    }];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (tableView.isEditing) { [self updateToolbar]; return; }
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    AMFileItem *item = self.items[(NSUInteger)indexPath.row];
    if (item.isDirectory) {
        [self.navigationController pushViewController:[[AMFileBrowserViewController alloc] initWithDirectory:item.url] animated:YES];
    } else if (item.kind == AMFileKindArchive) {
        [self showArchiveActionsForItem:item sourceView:[tableView cellForRowAtIndexPath:indexPath]];
    } else {
        [self previewItem:item];
    }
}

- (void)tableView:(UITableView *)tableView didDeselectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (tableView.isEditing) [self updateToolbar];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    AMFileItem *item = self.items[(NSUInteger)indexPath.row];
    __weak typeof(self) weak = self;
    UIContextualAction *del = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:@"删除"
                                                                    handler:^(UIContextualAction *a, UIView *src, void (^done)(BOOL)) {
        done(YES);
        [weak confirmDelete:@[ item.url ] sourceView:[tableView cellForRowAtIndexPath:indexPath] barItem:nil];
    }];
    del.backgroundColor = UIColor.systemRedColor;
    del.image = [UIImage systemImageNamed:@"trash"];
    UIContextualAction *share = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:@"分享"
                                                                      handler:^(UIContextualAction *a, UIView *src, void (^done)(BOOL)) {
        done(YES);
        typeof(self) strong = weak;
        if (strong) [AMUI share:@[ item.url ] from:strong sourceView:[tableView cellForRowAtIndexPath:indexPath] barItem:nil];
    }];
    share.backgroundColor = UIColor.systemBlueColor;
    share.image = [UIImage systemImageNamed:@"square.and.arrow.up"];
    UISwipeActionsConfiguration *c = [UISwipeActionsConfiguration configurationWithActions:@[ del, share ]];
    c.performsFirstActionWithFullSwipe = NO;
    return c;
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView leadingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    AMFileItem *item = self.items[(NSUInteger)indexPath.row];
    __weak typeof(self) weak = self;
    UIContextualAction *a;
    if (item.kind == AMFileKindArchive) {
        a = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:@"解压"
                                                  handler:^(UIContextualAction *x, UIView *src, void (^done)(BOOL)) {
            done(YES);
            [weak extractItem:item];
        }];
        a.backgroundColor = UIColor.systemGreenColor;
        a.image = [UIImage systemImageNamed:@"arrow.up.bin"];
    } else {
        a = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:@"压缩"
                                                  handler:^(UIContextualAction *x, UIView *src, void (^done)(BOOL)) {
            done(YES);
            [weak compressURLs:@[ item.url ]];
        }];
        a.backgroundColor = UIColor.systemOrangeColor;
        a.image = [UIImage systemImageNamed:@"doc.zipper"];
    }
    return [UISwipeActionsConfiguration configurationWithActions:@[ a ]];
}

- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath point:(CGPoint)point {
    if (tableView.isEditing) return nil;
    AMFileItem *item = self.items[(NSUInteger)indexPath.row];
    __weak typeof(self) weak = self;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggested) {
        NSMutableArray *primary = [NSMutableArray array];
        if (item.kind == AMFileKindArchive) {
            [primary addObject:[UIAction actionWithTitle:@"解压" image:[UIImage systemImageNamed:@"arrow.up.bin"] identifier:nil handler:^(__kindof UIAction *a) {
                [weak extractItem:item];
            }]];
            [primary addObject:[UIAction actionWithTitle:@"查看内容" image:[UIImage systemImageNamed:@"list.bullet.rectangle"] identifier:nil handler:^(__kindof UIAction *a) {
                [weak showContentsOfItem:item];
            }]];
        } else if (!item.isDirectory) {
            [primary addObject:[UIAction actionWithTitle:@"快速查看" image:[UIImage systemImageNamed:@"eye"] identifier:nil handler:^(__kindof UIAction *a) {
                [weak previewItem:item];
            }]];
        }
        [primary addObject:[UIAction actionWithTitle:@"压缩" image:[UIImage systemImageNamed:@"doc.zipper"] identifier:nil handler:^(__kindof UIAction *a) {
            [weak compressURLs:@[ item.url ]];
        }]];
        NSArray *edit = @[
            [UIAction actionWithTitle:@"重新命名" image:[UIImage systemImageNamed:@"pencil"] identifier:nil handler:^(__kindof UIAction *a) {
                [weak renameItem:item];
            }],
            [UIAction actionWithTitle:@"复制" image:[UIImage systemImageNamed:@"plus.square.on.square"] identifier:nil handler:^(__kindof UIAction *a) {
                [weak duplicateItem:item];
            }],
        ];
        NSArray *out = @[
            [UIAction actionWithTitle:@"分享" image:[UIImage systemImageNamed:@"square.and.arrow.up"] identifier:nil handler:^(__kindof UIAction *a) {
                typeof(self) strong = weak;
                if (strong) [AMUI share:@[ item.url ] from:strong sourceView:[tableView cellForRowAtIndexPath:indexPath] barItem:nil];
            }],
            [UIAction actionWithTitle:@"存储到“文件”" image:[UIImage systemImageNamed:@"folder"] identifier:nil handler:^(__kindof UIAction *a) {
                [weak exportItem:item];
            }],
        ];
        UIAction *del = [UIAction actionWithTitle:@"删除" image:[UIImage systemImageNamed:@"trash"] identifier:nil handler:^(__kindof UIAction *a) {
            [weak confirmDelete:@[ item.url ] sourceView:[tableView cellForRowAtIndexPath:indexPath] barItem:nil];
        }];
        del.attributes = UIMenuElementAttributesDestructive;
        return [UIMenu menuWithTitle:@"" children:@[
            [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:primary],
            [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:edit],
            [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:out],
            del,
        ]];
    }];
}

#pragma mark - Editing / selection

- (void)setEditing:(BOOL)editing animated:(BOOL)animated {
    [super setEditing:editing animated:animated];
    [self.navigationController setToolbarHidden:!editing animated:animated];
    self.navigationItem.hidesBackButton = editing;
    self.navigationItem.leftBarButtonItem = editing ? self.selectAllItem : nil;
    self.navigationItem.rightBarButtonItems = editing ? @[ self.doneItem ] : @[ self.moreItem, self.addItem ];
    if (!editing) self.navigationItem.title = self.defaultTitle;
    [self updateToolbar];
}

- (void)endSelecting {
    [self setEditing:NO animated:YES];
}

- (NSArray<NSURL *> *)selectedURLs {
    NSMutableArray *urls = [NSMutableArray array];
    for (NSIndexPath *ip in [self.tableView.indexPathsForSelectedRows sortedArrayUsingSelector:@selector(compare:)])
        if (ip.row < (NSInteger)self.items.count) [urls addObject:self.items[(NSUInteger)ip.row].url];
    return urls;
}

- (void)updateToolbar {
    if (!self.isEditing) return;
    NSUInteger n = self.tableView.indexPathsForSelectedRows.count;
    for (UIBarButtonItem *b in @[ self.compressBarItem, self.shareBarItem, self.deleteBarItem ]) b.enabled = n > 0;
    self.selectAllItem.title = (n > 0 && n == self.items.count) ? @"取消全选" : @"全选";
    self.navigationItem.title = n ? [NSString stringWithFormat:@"已选择 %lu 项", (unsigned long)n] : @"选择项目";
}

- (void)toggleSelectAll {
    BOOL all = self.tableView.indexPathsForSelectedRows.count == self.items.count;
    for (NSInteger i = 0; i < (NSInteger)self.items.count; i++) {
        NSIndexPath *ip = [NSIndexPath indexPathForRow:i inSection:0];
        if (all) [self.tableView deselectRowAtIndexPath:ip animated:NO];
        else [self.tableView selectRowAtIndexPath:ip animated:NO scrollPosition:UITableViewScrollPositionNone];
    }
    [self updateToolbar];
}

- (void)compressSelected {
    NSArray *urls = self.selectedURLs;
    if (urls.count) [self compressURLs:urls];
}

- (void)shareSelected:(UIBarButtonItem *)sender {
    NSMutableArray *files = [NSMutableArray array];
    BOOL hasFolder = NO;
    for (NSURL *u in self.selectedURLs) {
        NSNumber *isDir = nil;
        [u getResourceValue:&isDir forKey:NSURLIsDirectoryKey error:nil];
        if (isDir.boolValue) hasFolder = YES;
        else [files addObject:u];
    }
    if (hasFolder && files.count == 0) {
        [AMUI showMessage:@"文件夹不能直接分享，请先将它压缩。" title:@"无法分享文件夹" from:self];
        return;
    }
    [AMUI share:files from:self sourceView:nil barItem:sender];
}

- (void)deleteSelected:(UIBarButtonItem *)sender {
    NSArray *urls = self.selectedURLs;
    if (urls.count) [self confirmDelete:urls sourceView:nil barItem:sender];
}

#pragma mark - Actions

- (void)extractItem:(AMFileItem *)item {
    __weak typeof(self) weak = self;
    [AMActions extractArchive:item.url into:self.directory from:self completion:^(NSURL *result) {
        if (result) [weak revealItemAtURL:result];
    }];
}

- (void)offerToExtract:(NSURL *)url {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"已收到“%@”", url.lastPathComponent]
                                                               message:@"要现在解压吗？"
                                                        preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weak = self;
    [a addAction:[UIAlertAction actionWithTitle:@"稍后" style:UIAlertActionStyleCancel handler:nil]];
    UIAlertAction *go = [UIAlertAction actionWithTitle:@"解压" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        typeof(self) strong = weak;
        if (!strong) return;
        [AMActions extractArchive:url into:url.URLByDeletingLastPathComponent from:strong completion:^(NSURL *result) {
            if (result) [weak revealItemAtURL:result];
        }];
    }];
    [a addAction:go];
    a.preferredAction = go;
    [[AMUI topPresenterFrom:self] presentViewController:a animated:YES completion:nil];
}

- (void)showArchiveActionsForItem:(AMFileItem *)item sourceView:(UIView *)source {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:item.name message:item.subtitle preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weak = self;
    [sheet addAction:[UIAlertAction actionWithTitle:@"解压到此处" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [weak extractItem:item];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"查看内容" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [weak showContentsOfItem:item];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"分享" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        typeof(self) strong = weak;
        if (strong) [AMUI share:@[ item.url ] from:strong sourceView:source barItem:nil];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = source ?: self.view;
    sheet.popoverPresentationController.sourceRect = source ? source.bounds : self.view.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)showContentsOfItem:(AMFileItem *)item {
    AMArchiveContentsViewController *vc = [[AMArchiveContentsViewController alloc] initWithArchive:item.url];
    __weak typeof(self) weak = self;
    vc.onExtract = ^{ [weak extractItem:item]; };
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)compressURLs:(NSArray<NSURL *> *)urls {
    __weak typeof(self) weak = self;
    [AMActions compressItems:urls suggestedName:nil into:self.directory from:self completion:^(NSURL *result) {
        typeof(self) strong = weak;
        if (!result || !strong) return;
        [AMUI toast:[NSString stringWithFormat:@"已创建“%@”", result.lastPathComponent] symbol:@"checkmark.circle.fill"];
        if (strong.isEditing) [strong setEditing:NO animated:YES];
        [strong revealItemAtURL:result];
    }];
}

- (void)previewItem:(AMFileItem *)item {
    NSMutableArray *urls = [NSMutableArray array];
    NSInteger index = 0;
    for (AMFileItem *i in self.items) {
        if (i.isDirectory) continue;
        if ([i.url isEqual:item.url]) index = (NSInteger)urls.count;
        [urls addObject:i.url];
    }
    self.previewURLs = urls;
    QLPreviewController *ql = [QLPreviewController new];
    ql.dataSource = self;
    ql.currentPreviewItemIndex = index;
    [self presentViewController:ql animated:YES completion:nil];
}

- (NSInteger)numberOfPreviewItemsInPreviewController:(QLPreviewController *)controller {
    return (NSInteger)self.previewURLs.count;
}

- (id<QLPreviewItem>)previewController:(QLPreviewController *)controller previewItemAtIndex:(NSInteger)index {
    return self.previewURLs[(NSUInteger)index];
}

- (void)renameItem:(AMFileItem *)item {
    __weak typeof(self) weak = self;
    [AMUI promptWithTitle:@"重新命名" message:nil placeholder:@"名称" initial:item.name secure:NO confirmTitle:@"完成" from:self handler:^(NSString *text) {
        typeof(self) strong = weak;
        NSString *name = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!strong || name.length == 0 || [name isEqualToString:item.name]) return;
        if ([name containsString:@"/"] || [name hasPrefix:@"."]) {
            [AMUI showMessage:@"名称不能包含“/”，也不能以“.”开头。" title:@"名称无效" from:strong];
            return;
        }
        NSURL *dest = [strong.directory URLByAppendingPathComponent:name];
        NSError *error = nil;
        BOOL caseOnly = [name.lowercaseString isEqualToString:item.name.lowercaseString];
        if (!caseOnly && [NSFileManager.defaultManager fileExistsAtPath:dest.path]) {
            [AMUI showMessage:[NSString stringWithFormat:@"已存在名为“%@”的项目。", name] title:@"无法重新命名" from:strong];
            return;
        }
        if (![NSFileManager.defaultManager moveItemAtURL:item.url toURL:dest error:&error]) {
            [AMUI showError:error title:@"无法重新命名" from:strong];
            return;
        }
        [strong revealItemAtURL:dest];
    }];
}

- (void)duplicateItem:(AMFileItem *)item {
    NSURL *dest = [AMUI uniqueURLForName:item.name inDirectory:self.directory];
    NSError *error = nil;
    if ([NSFileManager.defaultManager copyItemAtURL:item.url toURL:dest error:&error]) [self revealItemAtURL:dest];
    else [AMUI showError:error title:@"无法复制" from:self];
}

- (void)exportItem:(AMFileItem *)item {
    UIDocumentPickerViewController *p = [[UIDocumentPickerViewController alloc] initForExportingURLs:@[ item.url ] asCopy:YES];
    p.delegate = self;
    [self presentViewController:p animated:YES completion:nil];
}

- (void)confirmDelete:(NSArray<NSURL *> *)urls sourceView:(UIView *)source barItem:(UIBarButtonItem *)barItem {
    NSString *title = urls.count == 1 ? [NSString stringWithFormat:@"要删除“%@”吗？", urls.firstObject.lastPathComponent]
                                      : [NSString stringWithFormat:@"要删除这 %lu 个项目吗？", (unsigned long)urls.count];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:title message:@"此操作无法撤销。" preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weak = self;
    [sheet addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        typeof(self) strong = weak;
        if (!strong) return;
        NSError *error = nil;
        for (NSURL *u in urls) {
            if (![NSFileManager.defaultManager removeItemAtURL:u error:&error]) break;
        }
        if (strong.isEditing) [strong setEditing:NO animated:YES];
        [strong reload];
        if (error) [AMUI showError:error title:@"无法删除" from:strong];
        else [AMUI toast:urls.count == 1 ? @"已删除" : [NSString stringWithFormat:@"已删除 %lu 个项目", (unsigned long)urls.count] symbol:@"trash"];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    UIPopoverPresentationController *pop = sheet.popoverPresentationController;
    if (barItem) pop.barButtonItem = barItem;
    else { pop.sourceView = source ?: self.view; pop.sourceRect = source ? source.bounds : self.view.bounds; }
    [[AMUI topPresenterFrom:self] presentViewController:sheet animated:YES completion:nil];
}

- (void)newFolder {
    __weak typeof(self) weak = self;
    [AMUI promptWithTitle:@"新建文件夹" message:nil placeholder:@"名称" initial:@"未命名文件夹" secure:NO confirmTitle:@"创建" from:self handler:^(NSString *text) {
        typeof(self) strong = weak;
        NSString *name = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!strong || name.length == 0) return;
        if ([name hasPrefix:@"."]) name = [name substringFromIndex:1];
        NSURL *dest = [AMUI uniqueURLForName:name inDirectory:strong.directory];
        NSError *error = nil;
        if ([NSFileManager.defaultManager createDirectoryAtURL:dest withIntermediateDirectories:NO attributes:nil error:&error])
            [strong revealItemAtURL:dest];
        else
            [AMUI showError:error title:@"无法创建文件夹" from:strong];
    }];
}

#pragma mark - Import

- (void)importFiles {
    self.filePicker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[ UTTypeItem ] asCopy:YES];
    self.filePicker.allowsMultipleSelection = YES;
    self.filePicker.delegate = self;
    [self presentViewController:self.filePicker animated:YES completion:nil];
}

- (void)importFolder {
    self.folderPicker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[ UTTypeFolder ] asCopy:NO];
    self.folderPicker.delegate = self;
    [self presentViewController:self.folderPicker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSFileManager *fm = NSFileManager.defaultManager;
    if (controller == self.filePicker) {
        NSURL *last = nil;
        NSInteger n = 0;
        for (NSURL *u in urls) {
            NSURL *dest = [AMUI uniqueURLForName:u.lastPathComponent inDirectory:self.directory];
            if ([fm moveItemAtURL:u toURL:dest error:nil] || [fm copyItemAtURL:u toURL:dest error:nil]) { last = dest; n++; }
        }
        self.filePicker = nil;
        if (n) [AMUI toast:[NSString stringWithFormat:@"已导入 %ld 个文件", (long)n] symbol:@"checkmark.circle.fill"];
        if (last) [self revealItemAtURL:last];
    } else if (controller == self.folderPicker) {
        self.folderPicker = nil;
        NSURL *src = urls.firstObject;
        if (!src) return;
        NSURL *dir = self.directory;
        [AMUI toast:@"正在导入文件夹…" symbol:nil];
        __weak typeof(self) weak = self;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            BOOL scoped = [src startAccessingSecurityScopedResource];
            NSURL *dest = [AMUI uniqueURLForName:src.lastPathComponent inDirectory:dir];
            NSError *error = nil;
            __block BOOL ok = NO;
            NSFileCoordinator *coord = [NSFileCoordinator new];
            [coord coordinateReadingItemAtURL:src options:0 error:&error byAccessor:^(NSURL *readURL) {
                ok = [NSFileManager.defaultManager copyItemAtURL:readURL toURL:dest error:nil];
            }];
            if (scoped) [src stopAccessingSecurityScopedResource];
            dispatch_async(dispatch_get_main_queue(), ^{
                typeof(self) strong = weak;
                if (!strong) return;
                if (ok) {
                    [AMUI toast:[NSString stringWithFormat:@"已导入“%@”", dest.lastPathComponent] symbol:@"checkmark.circle.fill"];
                    [strong revealItemAtURL:dest];
                } else {
                    [AMUI showMessage:@"无法读取这个文件夹。" title:@"导入失败" from:strong];
                }
            });
        });
    } else {
        [AMUI toast:@"已存储" symbol:@"checkmark.circle.fill"];
    }
}

- (void)importPhotos {
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
        [AMActions importPickerResults:results into:strong.directory imagesOnly:NO from:strong completion:^(NSArray<NSURL *> *urls) {
            if (urls.count) {
                [AMUI toast:[NSString stringWithFormat:@"已导入 %lu 项", (unsigned long)urls.count] symbol:@"checkmark.circle.fill"];
                [weak revealItemAtURL:urls.lastObject];
            }
        }];
    }];
}

@end
