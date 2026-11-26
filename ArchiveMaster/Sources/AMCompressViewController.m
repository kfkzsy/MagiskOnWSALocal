#import "AMCompressViewController.h"
#import "AMArchiver.h"
#import "AMUI.h"

@implementation AMCompressSettings
@end

typedef NS_ENUM(NSInteger, AMCSection) {
    AMCSectionName,
    AMCSectionFormat,
    AMCSectionLevel,
    AMCSectionPassword,
    AMCSectionSummary,
};

static const NSInteger kLevels[] = { 0, 1, 6, 9 };

static NSInteger AMLevelIndex(NSInteger level) {
    if (level <= 0) return 0;
    if (level <= 3) return 1;
    if (level <= 7) return 2;
    return 3;
}

@interface AMCompressViewController () <UITextFieldDelegate>
@property (nonatomic, copy) NSArray<NSURL *> *items;
@property (nonatomic, copy) NSString *suggestedName;
@property (nonatomic, copy) NSArray<AMFormatInfo *> *formats;
@property (nonatomic) am_format format;
@property (nonatomic) NSInteger level;
@property (nonatomic) BOOL usePassword;
@property (nonatomic) am_encryption encryption;

@property (nonatomic, strong) UITableViewCell *nameCell, *formatCell, *levelCell, *pwSwitchCell, *pwCell, *confirmCell, *encCell, *summaryCell;
@property (nonatomic, strong) UITextField *nameField, *pwField, *confirmField;
@property (nonatomic, strong) UILabel *extLabel;
@property (nonatomic, strong) UIBarButtonItem *goItem;
@end

@implementation AMCompressViewController

- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];
    [AMUI applyReadableMarginsToTableView:self.tableView];
}

- (instancetype)initWithItems:(NSArray<NSURL *> *)items suggestedName:(NSString *)name {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _items = [items copy];
        _suggestedName = [name copy];
        _encryption = AM_ENC_AES256;
    }
    return self;
}

- (AMFormatInfo *)info { return [AMFormatInfo infoForFormat:self.format]; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = L(@"压缩");
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;

    __weak typeof(self) weak = self;
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
                                                                                         primaryAction:[UIAction actionWithHandler:^(__kindof UIAction *a) {
        [weak.navigationController dismissViewControllerAnimated:YES completion:nil];
    }]];
    self.goItem = [[UIBarButtonItem alloc] initWithTitle:L(@"压缩") style:UIBarButtonItemStyleDone target:self action:@selector(confirm)];
    self.navigationItem.rightBarButtonItem = self.goItem;

    // Formats available for this selection.
    BOOL single = NO;
    if (self.items.count == 1) {
        NSNumber *isDir = nil;
        [self.items[0] getResourceValue:&isDir forKey:NSURLIsDirectoryKey error:nil];
        single = !isDir.boolValue;
    }
    NSMutableArray *formats = [AMFormatInfo.multiFileFormats mutableCopy];
    if (single) [formats addObjectsFromArray:AMFormatInfo.singleFileFormats];
    self.formats = formats;

    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    self.format = (am_format)[d integerForKey:AMDefaultsFormat];
    BOOL known = NO;
    for (AMFormatInfo *f in formats) known |= f.format == self.format;
    if (!known) self.format = AM_FMT_ZIP;
    self.level = kLevels[AMLevelIndex([d integerForKey:AMDefaultsLevel])];

    [self buildCells];
    [self updateExtension];
    [self validate];
    [self computeSummary];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (self.nameField.text.length == 0) [self.nameField becomeFirstResponder];
}

- (void)buildCells {
    __weak typeof(self) weak = self;
    UITextField *tf = nil;
    self.nameCell = [AMForm textFieldCellWithPlaceholder:L(@"压缩包名称") text:self.suggestedName secure:NO outTextField:&tf];
    self.nameField = tf;
    self.nameField.delegate = self;
    self.nameField.accessibilityLabel = L(@"压缩包名称");
    self.extLabel = [UILabel new];
    self.extLabel.textColor = UIColor.secondaryLabelColor;
    self.extLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    self.nameField.rightView = self.extLabel;
    self.nameField.rightViewMode = UITextFieldViewModeAlways;
    self.nameField.clearButtonMode = UITextFieldViewModeNever;
    [self.nameField addTarget:self action:@selector(validate) forControlEvents:UIControlEventEditingChanged];

    NSMutableArray *names = [NSMutableArray array];
    NSInteger selected = 0;
    for (NSUInteger i = 0; i < self.formats.count; i++) {
        AMFormatInfo *f = self.formats[i];
        [names addObject:f.singleFile ? [NSString stringWithFormat:L(@"%@（单个文件）"), f.name] : f.name];
        if (f.format == self.format) selected = (NSInteger)i;
    }
    self.formatCell = [AMForm popupCellWithTitle:L(@"格式") options:names selected:selected handler:^(NSInteger index) {
        [weak formatSelected:index];
    }];

    self.levelCell = [AMForm segmentedCellWithItems:@[ L(@"仅存储"), L(@"快速"), L(@"标准"), L(@"最高") ]
                                           selected:AMLevelIndex(self.level)
                                            handler:^(NSInteger index) {
        weak.level = kLevels[index];
    }];

    self.pwSwitchCell = [AMForm switchCellWithTitle:L(@"设置密码") on:NO handler:^(BOOL on) {
        [weak passwordToggled:on];
    } outSwitch:nil];

    self.pwCell = [AMForm textFieldCellWithPlaceholder:L(@"密码") text:nil secure:YES outTextField:&tf];
    self.pwField = tf;
    self.confirmCell = [AMForm textFieldCellWithPlaceholder:L(@"再次输入密码") text:nil secure:YES outTextField:&tf];
    self.confirmField = tf;
    for (UITextField *f in @[ self.pwField, self.confirmField ]) {
        f.delegate = self;
        f.textContentType = UITextContentTypeNewPassword;
        f.passwordRules = nil;
        [f addTarget:self action:@selector(validate) forControlEvents:UIControlEventEditingChanged];
    }
    self.pwField.returnKeyType = UIReturnKeyNext;
    UIImageView *warn = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"exclamationmark.circle.fill"]];
    warn.tintColor = UIColor.systemRedColor;
    warn.accessibilityLabel = L(@"两次输入的密码不一致");
    self.confirmField.rightView = warn;
    self.confirmField.rightViewMode = UITextFieldViewModeNever;

    self.encCell = [AMForm popupCellWithTitle:L(@"加密方式") options:@[ L(@"AES-256（推荐）"), L(@"ZipCrypto（兼容旧软件）") ] selected:0 handler:^(NSInteger index) {
        weak.encryption = index == 0 ? AM_ENC_AES256 : AM_ENC_ZIPCRYPTO;
    }];

    self.summaryCell = [AMForm valueCellWithTitle:L(@"内容") detail:L(@"正在计算…") symbol:nil tint:nil accessory:UITableViewCellAccessoryNone];
}

- (void)computeSummary {
    NSArray *items = self.items;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        unsigned long long total = 0;
        for (NSURL *u in items) total += [AMUI sizeOfItemAtURL:u];
        dispatch_async(dispatch_get_main_queue(), ^{
            UIListContentConfiguration *c = (UIListContentConfiguration *)self.summaryCell.contentConfiguration;
            c.secondaryText = [NSString stringWithFormat:L(@"%lu 项 · %@"), (unsigned long)items.count, [AMUI byteString:(long long)total]];
            self.summaryCell.contentConfiguration = c;
        });
    });
}

#pragma mark - State

- (void)formatSelected:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)self.formats.count) return;
    self.format = self.formats[index].format;
    [self updateExtension];
    [self.tableView reloadData];
    [self validate];
}

- (void)updateExtension {
    self.extLabel.text = [@"." stringByAppendingString:self.info.extension];
    [self.extLabel sizeToFit];
    CGRect f = self.extLabel.frame;
    f.size.width += 4;
    self.extLabel.frame = f;
}

- (void)passwordToggled:(BOOL)on {
    self.usePassword = on;
    NSInteger section = (NSInteger)[self.sections indexOfObject:@(AMCSectionPassword)];
    if (section == NSNotFound) return;
    NSArray *rows = @[ [NSIndexPath indexPathForRow:1 inSection:section], [NSIndexPath indexPathForRow:2 inSection:section],
                       [NSIndexPath indexPathForRow:3 inSection:section] ];
    [self.tableView performBatchUpdates:^{
        if (on) [self.tableView insertRowsAtIndexPaths:rows withRowAnimation:UITableViewRowAnimationFade];
        else [self.tableView deleteRowsAtIndexPaths:rows withRowAnimation:UITableViewRowAnimationFade];
    } completion:nil];
    if (on) [self.pwField becomeFirstResponder];
    else [self.view endEditing:YES];
    [self validate];
}

- (BOOL)passwordActive { return self.usePassword && self.info.supportsPassword; }

- (void)validate {
    NSString *name = [self.nameField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    BOOL ok = name.length > 0 && [name rangeOfString:@"/"].location == NSNotFound;
    if (self.passwordActive) {
        BOOL match = [self.pwField.text isEqualToString:self.confirmField.text ?: @""];
        self.confirmField.rightViewMode = (!match && self.confirmField.text.length) ? UITextFieldViewModeAlways : UITextFieldViewModeNever;
        ok = ok && self.pwField.text.length > 0 && match;
    }
    self.goItem.enabled = ok;
}

- (void)confirm {
    [self validate];
    if (!self.goItem.enabled) return;
    AMCompressSettings *s = [AMCompressSettings new];
    NSString *name = [self.nameField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *suffix = [@"." stringByAppendingString:self.info.extension];
    if ([name.lowercaseString hasSuffix:suffix] && name.length > suffix.length) name = [name substringToIndex:name.length - suffix.length];
    s.name = name;
    s.format = self.format;
    s.level = self.level;
    s.password = self.passwordActive ? self.pwField.text : nil;
    s.encryption = self.passwordActive ? self.encryption : AM_ENC_NONE;
    [self.view endEditing:YES];
    void (^cb)(AMCompressSettings *) = self.onConfirm;
    [self.navigationController dismissViewControllerAnimated:YES completion:^{
        if (cb) cb(s);
    }];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    if (textField == self.pwField) [self.confirmField becomeFirstResponder];
    else if (textField == self.confirmField || textField == self.nameField) {
        [textField resignFirstResponder];
        if (self.goItem.enabled && textField == self.confirmField) [self confirm];
    }
    return YES;
}

#pragma mark - Table

- (NSArray<NSNumber *> *)sections {
    NSMutableArray *s = [@[ @(AMCSectionName), @(AMCSectionFormat), @(AMCSectionLevel) ] mutableCopy];
    if (self.info.supportsPassword) [s addObject:@(AMCSectionPassword)];
    [s addObject:@(AMCSectionSummary)];
    return s;
}

- (AMCSection)kindForSection:(NSInteger)section {
    return (AMCSection)self.sections[(NSUInteger)section].integerValue;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return (NSInteger)self.sections.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return [self kindForSection:section] == AMCSectionPassword ? (self.usePassword ? 4 : 1) : 1;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    switch ([self kindForSection:indexPath.section]) {
    case AMCSectionName: return self.nameCell;
    case AMCSectionFormat: return self.formatCell;
    case AMCSectionLevel: return self.levelCell;
    case AMCSectionPassword: return @[ self.pwSwitchCell, self.pwCell, self.confirmCell, self.encCell ][(NSUInteger)indexPath.row];
    case AMCSectionSummary: return self.summaryCell;
    }
    return self.summaryCell;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch ([self kindForSection:section]) {
    case AMCSectionName: return L(@"名称");
    case AMCSectionFormat: return L(@"格式");
    case AMCSectionLevel: return L(@"压缩级别");
    case AMCSectionPassword: return L(@"加密");
    case AMCSectionSummary: return nil;
    }
    return nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    switch ([self kindForSection:section]) {
    case AMCSectionName: return nil;
    case AMCSectionFormat: return self.info.summary;
    case AMCSectionLevel: return L(@"级别越高，文件越小，但耗时越长。照片、视频等本身已压缩过的文件通常很难再变小。");
    case AMCSectionPassword:
        return L(@"加密后，打开压缩包里的文件需要输入密码，忘记密码将无法解压。AES-256 更安全；ZipCrypto 兼容 Windows 自带解压等旧软件，但安全性较低。");
    case AMCSectionSummary: return nil;
    }
    return nil;
}

- (BOOL)tableView:(UITableView *)tableView shouldHighlightRowAtIndexPath:(NSIndexPath *)indexPath {
    return NO;
}

@end
