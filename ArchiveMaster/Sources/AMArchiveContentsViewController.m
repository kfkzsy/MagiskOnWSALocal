#import "AMArchiveContentsViewController.h"
#import "AMActions.h"
#import "AMArchiver.h"
#import "AMFileItem.h"
#import "AMUI.h"

@interface AMArchiveContentsViewController () <UISearchResultsUpdating>
@property (nonatomic, strong) NSURL *archive;
@property (nonatomic, strong) NSURL *destination;
@property (nonatomic, copy) NSArray<AMArchiveEntry *> *entries;
@property (nonatomic, copy) NSArray<AMArchiveEntry *> *shown;
@property (nonatomic, copy) NSString *summary;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UIBarButtonItem *extractAllItem, *selectItem, *doneItem, *extractSelectedItem;
@end

@implementation AMArchiveContentsViewController

- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];
    [AMUI applyReadableMarginsToTableView:self.tableView];
}

- (instancetype)initWithArchive:(NSURL *)archive destination:(NSURL *)destination {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _archive = archive;
        _destination = destination;
        _entries = @[];
        _shown = @[];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.archive.lastPathComponent;
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    [self.tableView registerClass:UITableViewCell.class forCellReuseIdentifier:@"entry"];
    self.tableView.allowsMultipleSelectionDuringEditing = YES;

    self.extractAllItem = [[UIBarButtonItem alloc] initWithTitle:L(@"全部解压") style:UIBarButtonItemStyleDone target:self action:@selector(extractAll)];
    self.selectItem = [[UIBarButtonItem alloc] initWithTitle:L(@"选择") style:UIBarButtonItemStylePlain target:self action:@selector(startSelecting)];
    self.doneItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(stopSelecting)];
    self.extractSelectedItem = [[UIBarButtonItem alloc] initWithTitle:L(@"解压所选") style:UIBarButtonItemStyleDone target:self action:@selector(extractSelected)];
    UIBarButtonItem *flex = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
    self.toolbarItems = @[ flex, self.extractSelectedItem ];
    self.navigationItem.rightBarButtonItems = @[ self.extractAllItem ];
    self.extractAllItem.enabled = NO;

    UISearchController *search = [[UISearchController alloc] initWithSearchResultsController:nil];
    search.searchResultsUpdater = self;
    search.obscuresBackgroundDuringPresentation = NO;
    search.searchBar.placeholder = L(@"搜索压缩包内的文件");
    self.navigationItem.searchController = search;

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    [self.spinner startAnimating];
    self.tableView.backgroundView = self.spinner;

    __weak typeof(self) weak = self;
    [AMArchiver listArchive:self.archive completion:^(NSArray<AMArchiveEntry *> *entries, BOOL truncated, NSError *error) {
        typeof(self) strong = weak;
        if (!strong) return;
        [strong.spinner stopAnimating];
        strong.tableView.backgroundView = nil;
        if (error) {
            [AMUI showError:error title:L(@"无法读取压缩包") from:strong];
            return;
        }
        strong.entries = entries;
        strong.shown = entries;
        long long total = 0;
        NSInteger files = 0, encrypted = 0;
        for (AMArchiveEntry *e in entries) {
            if (e.isDirectory) continue;
            files++;
            if (e.size > 0) total += e.size;
            if (e.encrypted) encrypted++;
        }
        NSMutableString *summary = [NSMutableString stringWithFormat:L(@"%ld 个文件，解压后约 %@"), (long)files, [AMUI byteString:total]];
        if (truncated) [summary appendString:L(@"（仅显示前 20000 项）")];
        if (encrypted) [summary appendString:L(@"。部分文件已加密，打开时需要输入密码。")];
        strong.summary = summary;
        strong.extractAllItem.enabled = YES;
        strong.navigationItem.rightBarButtonItems = @[ strong.extractAllItem, strong.selectItem ];
        [strong.tableView reloadData];
    }];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    if (self.isEditing) [self stopSelecting];
}

#pragma mark - Actions

- (void)finishWith:(NSURL *)result {
    if (!result) return;
    void (^cb)(NSURL *) = self.onExtracted;
    if (self.navigationController.viewControllers.firstObject != self) [self.navigationController popViewControllerAnimated:YES];
    if (cb) cb(result);
}

- (void)extractAll {
    __weak typeof(self) weak = self;
    [AMActions extractArchive:self.archive into:self.destination onlyPaths:nil from:self completion:^(NSURL *result) {
        [weak finishWith:result];
    }];
}

- (void)startSelecting {
    [self setEditing:YES animated:YES];
    [self.navigationController setToolbarHidden:NO animated:YES];
    self.navigationItem.rightBarButtonItems = @[ self.doneItem ];
    [self updateSelection];
}

- (void)stopSelecting {
    [self setEditing:NO animated:YES];
    [self.navigationController setToolbarHidden:YES animated:YES];
    self.navigationItem.rightBarButtonItems = @[ self.extractAllItem, self.selectItem ];
}

- (void)updateSelection {
    NSUInteger n = self.tableView.indexPathsForSelectedRows.count;
    self.extractSelectedItem.enabled = n > 0;
    self.extractSelectedItem.title = n ? [NSString stringWithFormat:L(@"解压所选（%lu）"), (unsigned long)n] : L(@"解压所选");
}

- (void)extractSelected {
    NSMutableSet *paths = [NSMutableSet set];
    for (NSIndexPath *ip in self.tableView.indexPathsForSelectedRows) [paths addObject:self.shown[(NSUInteger)ip.row].path];
    if (paths.count == 0) return;
    [self stopSelecting];
    __weak typeof(self) weak = self;
    [AMActions extractArchive:self.archive into:self.destination onlyPaths:paths from:self completion:^(NSURL *result) {
        [weak finishWith:result];
    }];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    NSString *q = searchController.searchBar.text;
    if (q.length == 0) {
        self.shown = self.entries;
    } else {
        NSPredicate *p = [NSPredicate predicateWithBlock:^BOOL(AMArchiveEntry *e, NSDictionary *b) {
            return [e.path localizedCaseInsensitiveContainsString:q];
        }];
        self.shown = [self.entries filteredArrayUsingPredicate:p];
    }
    [self.tableView reloadData];
    if (self.isEditing) [self updateSelection];
}

#pragma mark - Table

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)self.shown.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return self.summary;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return self.entries.count ? L(@"轻点文件可以直接预览，无需解压整个压缩包。") : nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"entry" forIndexPath:indexPath];
    AMArchiveEntry *e = self.shown[(NSUInteger)indexPath.row];
    UIListContentConfiguration *c = [UIListContentConfiguration subtitleCellConfiguration];
    NSString *name = e.path.lastPathComponent;
    NSString *parent = e.path.stringByDeletingLastPathComponent;
    c.text = name.length ? name : e.path;
    c.textProperties.lineBreakMode = NSLineBreakByTruncatingMiddle;
    NSMutableArray *parts = [NSMutableArray array];
    if (parent.length) [parts addObject:parent];
    if (!e.isDirectory && e.size >= 0) [parts addObject:[AMUI byteString:e.size]];
    c.secondaryText = parts.count ? [parts componentsJoinedByString:@" · "] : nil;
    c.secondaryTextProperties.color = UIColor.secondaryLabelColor;
    c.secondaryTextProperties.lineBreakMode = NSLineBreakByTruncatingHead;
    AMFileKind kind = e.isDirectory ? AMFileKindFolder : [AMFileItem kindForFileName:name];
    c.image = [UIImage systemImageNamed:e.encrypted ? @"lock.doc" : [AMFileItem symbolForKind:kind]];
    c.imageProperties.tintColor = e.encrypted ? UIColor.systemOrangeColor : [AMFileItem colorForKind:kind];
    c.imageProperties.reservedLayoutSize = CGSizeMake(28, 28);
    cell.contentConfiguration = c;
    cell.accessibilityLabel = [NSString stringWithFormat:L(@"%@，%@%@"), c.text, c.secondaryText ?: @"", e.encrypted ? L(@"，已加密") : @""];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (tableView.isEditing) { [self updateSelection]; return; }
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    AMArchiveEntry *e = self.shown[(NSUInteger)indexPath.row];
    if (e.isDirectory) return;
    [AMActions previewEntry:e.path inArchive:self.archive from:self];
}

- (void)tableView:(UITableView *)tableView didDeselectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (tableView.isEditing) [self updateSelection];
}

- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath point:(CGPoint)point {
    if (tableView.isEditing) return nil;
    AMArchiveEntry *e = self.shown[(NSUInteger)indexPath.row];
    __weak typeof(self) weak = self;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu *(NSArray<UIMenuElement *> *s) {
        NSMutableArray *actions = [NSMutableArray array];
        if (!e.isDirectory) {
            [actions addObject:[UIAction actionWithTitle:L(@"快速查看") image:[UIImage systemImageNamed:@"eye"] identifier:nil handler:^(__kindof UIAction *a) {
                typeof(self) strong = weak;
                if (strong) [AMActions previewEntry:e.path inArchive:strong.archive from:strong];
            }]];
        }
        [actions addObject:[UIAction actionWithTitle:L(@"只解压这一项") image:[UIImage systemImageNamed:@"arrow.up.bin"] identifier:nil handler:^(__kindof UIAction *a) {
            typeof(self) strong = weak;
            if (!strong) return;
            [AMActions extractArchive:strong.archive into:strong.destination onlyPaths:[NSSet setWithObject:e.path] from:strong completion:^(NSURL *result) {
                [weak finishWith:result];
            }];
        }]];
        [actions addObject:[UIAction actionWithTitle:L(@"拷贝名称") image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil handler:^(__kindof UIAction *a) {
            UIPasteboard.generalPasteboard.string = e.path.lastPathComponent;
        }]];
        return [UIMenu menuWithTitle:e.path children:actions];
    }];
}

@end
