#import "AMArchiveContentsViewController.h"
#import "AMArchiver.h"
#import "AMFileItem.h"
#import "AMUI.h"

@interface AMArchiveContentsViewController () <UISearchResultsUpdating>
@property (nonatomic, strong) NSURL *archive;
@property (nonatomic, copy) NSArray<AMArchiveEntry *> *entries;
@property (nonatomic, copy) NSArray<AMArchiveEntry *> *shown;
@property (nonatomic, copy) NSString *summary;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@end

@implementation AMArchiveContentsViewController

- (instancetype)initWithArchive:(NSURL *)archive {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _archive = archive;
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
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"解压" style:UIBarButtonItemStyleDone target:self action:@selector(extract)];
    self.navigationItem.rightBarButtonItem.enabled = NO;

    UISearchController *search = [[UISearchController alloc] initWithSearchResultsController:nil];
    search.searchResultsUpdater = self;
    search.obscuresBackgroundDuringPresentation = NO;
    search.searchBar.placeholder = @"搜索压缩包内的文件";
    self.navigationItem.searchController = search;

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    [self.spinner startAnimating];
    self.tableView.backgroundView = self.spinner;

    [AMArchiver listArchive:self.archive completion:^(NSArray<AMArchiveEntry *> *entries, BOOL truncated, NSError *error) {
        [self.spinner stopAnimating];
        self.tableView.backgroundView = nil;
        if (error) {
            [AMUI showError:error title:@"无法读取压缩包" from:self];
            return;
        }
        self.entries = entries;
        self.shown = entries;
        long long total = 0;
        NSInteger files = 0, encrypted = 0;
        for (AMArchiveEntry *e in entries) {
            if (e.isDirectory) continue;
            files++;
            if (e.size > 0) total += e.size;
            if (e.encrypted) encrypted++;
        }
        NSMutableString *summary = [NSMutableString stringWithFormat:@"%ld 个文件，解压后约 %@", (long)files, [AMUI byteString:total]];
        if (truncated) [summary appendString:@"（仅显示前 20000 项）"];
        if (encrypted) [summary appendString:@"。部分文件已加密，解压时需要输入密码。"];
        self.summary = summary;
        self.navigationItem.rightBarButtonItem.enabled = YES;
        [self.tableView reloadData];
    }];
}

- (void)extract {
    void (^cb)(void) = self.onExtract;
    [self.navigationController popViewControllerAnimated:YES];
    if (cb) cb();
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
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)self.shown.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return self.summary;
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
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.accessibilityLabel = [NSString stringWithFormat:@"%@，%@%@", c.text, c.secondaryText ?: @"", e.encrypted ? @"，已加密" : @""];
    return cell;
}

@end
