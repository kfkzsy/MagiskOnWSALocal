#import "AMSettingsViewController.h"
#import "AMArchiver.h"
#import "AMUI.h"
#import <archive.h>

static NSArray<NSString *> *AMEncodingValues(void) { return @[ @"", @"UTF-8", @"CP936", @"BIG5", @"SHIFT_JIS", @"CP949" ]; }
static NSArray<NSString *> *AMEncodingTitles(void) {
    return @[ @"自动识别", @"UTF-8", @"简体中文（GBK）", @"繁体中文（Big5）", @"日文（Shift_JIS）", @"韩文（EUC-KR）" ];
}
static const NSInteger kLevelValues[] = { 0, 1, 6, 9 };

@interface AMSettingsViewController ()
@property (nonatomic, strong) UITableViewCell *formatCell, *levelCell, *smartCell, *deleteCell, *encodingCell;
@property (nonatomic, strong) UITableViewCell *usageCell, *cacheCell, *formatsCell, *licensesCell, *versionCell;
@end

@implementation AMSettingsViewController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"设置";
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeAlways;
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;

    NSArray<AMFormatInfo *> *formats = AMFormatInfo.multiFileFormats;
    NSMutableArray *names = [NSMutableArray array];
    NSInteger selected = 0;
    for (NSUInteger i = 0; i < formats.count; i++) {
        [names addObject:formats[i].name];
        if (formats[i].format == (am_format)[d integerForKey:AMDefaultsFormat]) selected = (NSInteger)i;
    }
    self.formatCell = [AMForm popupCellWithTitle:@"默认格式" options:names selected:selected handler:^(NSInteger index) {
        [NSUserDefaults.standardUserDefaults setInteger:formats[(NSUInteger)index].format forKey:AMDefaultsFormat];
    }];

    NSInteger level = [d integerForKey:AMDefaultsLevel];
    NSInteger levelIndex = level <= 0 ? 0 : level <= 3 ? 1 : level <= 7 ? 2 : 3;
    self.levelCell = [AMForm popupCellWithTitle:@"默认压缩级别" options:@[ @"仅存储", @"快速", @"标准", @"最高" ] selected:levelIndex handler:^(NSInteger index) {
        [NSUserDefaults.standardUserDefaults setInteger:kLevelValues[index] forKey:AMDefaultsLevel];
    }];

    self.smartCell = [AMForm switchCellWithTitle:@"智能解压" on:[d boolForKey:AMDefaultsSmartExtract] handler:^(BOOL on) {
        [NSUserDefaults.standardUserDefaults setBool:on forKey:AMDefaultsSmartExtract];
    } outSwitch:nil];
    self.deleteCell = [AMForm switchCellWithTitle:@"解压后删除压缩包" on:[d boolForKey:AMDefaultsDeleteAfterExtract] handler:^(BOOL on) {
        [NSUserDefaults.standardUserDefaults setBool:on forKey:AMDefaultsDeleteAfterExtract];
    } outSwitch:nil];
    NSUInteger enc = [AMEncodingValues() indexOfObject:[d stringForKey:AMDefaultsEncoding] ?: @""];
    self.encodingCell = [AMForm popupCellWithTitle:@"文件名编码" options:AMEncodingTitles() selected:enc == NSNotFound ? 0 : (NSInteger)enc handler:^(NSInteger index) {
        [NSUserDefaults.standardUserDefaults setObject:AMEncodingValues()[(NSUInteger)index] forKey:AMDefaultsEncoding];
    }];

    self.usageCell = [AMForm valueCellWithTitle:@"文件占用" detail:@"…" symbol:@"internaldrive" tint:UIColor.systemGrayColor accessory:UITableViewCellAccessoryNone];
    self.usageCell.selectionStyle = UITableViewCellSelectionStyleNone;
    self.cacheCell = [AMForm valueCellWithTitle:@"清除缓存" detail:@"…" symbol:@"trash" tint:UIColor.systemRedColor accessory:UITableViewCellAccessoryNone];
    self.formatsCell = [AMForm valueCellWithTitle:@"支持的格式" detail:nil symbol:@"doc.zipper" tint:UIColor.systemOrangeColor accessory:UITableViewCellAccessoryDisclosureIndicator];
    self.licensesCell = [AMForm valueCellWithTitle:@"开源组件许可" detail:nil symbol:@"doc.plaintext" tint:UIColor.systemBlueColor accessory:UITableViewCellAccessoryDisclosureIndicator];
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    NSString *version = [NSString stringWithFormat:@"%@ (%@)", info[@"CFBundleShortVersionString"] ?: @"1.0", info[@"CFBundleVersion"] ?: @"1"];
    self.versionCell = [AMForm valueCellWithTitle:@"版本" detail:version symbol:@"info.circle" tint:UIColor.systemGrayColor accessory:UITableViewCellAccessoryNone];
    self.versionCell.selectionStyle = UITableViewCellSelectionStyleNone;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self updateStorage];
}

- (void)setDetail:(NSString *)detail forCell:(UITableViewCell *)cell {
    UIListContentConfiguration *c = (UIListContentConfiguration *)cell.contentConfiguration;
    c.secondaryText = detail;
    cell.contentConfiguration = c;
}

- (void)updateStorage {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        unsigned long long docs = [AMUI sizeOfItemAtURL:AMUI.documentsURL];
        unsigned long long tmp = [AMUI sizeOfItemAtURL:[NSURL fileURLWithPath:NSTemporaryDirectory()]];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self setDetail:[AMUI byteString:(long long)docs] forCell:self.usageCell];
            [self setDetail:[AMUI byteString:(long long)tmp] forCell:self.cacheCell];
        });
    });
}

- (void)clearCache {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *tmp = [NSURL fileURLWithPath:NSTemporaryDirectory()];
    for (NSURL *u in [fm contentsOfDirectoryAtURL:tmp includingPropertiesForKeys:nil options:0 error:nil])
        [fm removeItemAtURL:u error:nil];
    [AMUI toast:@"缓存已清除" symbol:@"checkmark.circle.fill"];
    [self updateStorage];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 4; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return [@[ @2, @3, @2, @3 ][(NSUInteger)section] integerValue];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSArray *rows = @[
        @[ self.formatCell, self.levelCell ],
        @[ self.smartCell, self.deleteCell, self.encodingCell ],
        @[ self.usageCell, self.cacheCell ],
        @[ self.formatsCell, self.licensesCell, self.versionCell ],
    ];
    return rows[(NSUInteger)indexPath.section][(NSUInteger)indexPath.row];
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return @[ @"压缩", @"解压", @"存储空间", @"关于" ][(NSUInteger)section];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    switch (section) {
    case 1: return @"智能解压：压缩包里只有一个文件或文件夹时直接解压出来，否则放进与压缩包同名的新文件夹。\n解压后如果文件名是乱码，请把“文件名编码”改为对应的语言后重新解压。";
    case 2: return @"所有文件都保存在本机，可以在“文件”App 的“我的 iPhone › 解压大师”中找到。";
    default: return nil;
    }
}

- (BOOL)tableView:(UITableView *)tableView shouldHighlightRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *c = [self tableView:tableView cellForRowAtIndexPath:indexPath];
    return c == self.cacheCell || c == self.formatsCell || c == self.licensesCell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    UITableViewCell *c = [self tableView:tableView cellForRowAtIndexPath:indexPath];
    if (c == self.formatsCell) {
        [self.navigationController pushViewController:[AMFormatsViewController new] animated:YES];
    } else if (c == self.licensesCell) {
        [self.navigationController pushViewController:[AMLicensesViewController new] animated:YES];
    } else if (c == self.cacheCell) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"清除缓存？" message:@"会删除临时文件和“相册”页面中已读取的照片副本，不会影响“文件”页面中的文件。" preferredStyle:UIAlertControllerStyleActionSheet];
        __weak typeof(self) weak = self;
        [a addAction:[UIAlertAction actionWithTitle:@"清除缓存" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) {
            [weak clearCache];
        }]];
        [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        a.popoverPresentationController.sourceView = c;
        a.popoverPresentationController.sourceRect = c.bounds;
        [self presentViewController:a animated:YES completion:nil];
    }
}

@end

#pragma mark - Formats

@interface AMFormatsViewController ()
@property (nonatomic, copy) NSArray<NSArray<NSArray<NSString *> *> *> *rows;
@end

@implementation AMFormatsViewController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"支持的格式";
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.rows = @[
        @[
            @[ @"ZIP", @"可设置密码（AES-256 / ZipCrypto），自动识别中文文件名" ],
            @[ @"7Z", @"LZMA2 高压缩率，支持 PPMd、BCJ2、Zstandard 等算法" ],
            @[ @"TAR", @"以及 TAR.GZ / TGZ、TAR.BZ2、TAR.XZ、TAR.ZST、TAR.LZ4" ],
            @[ @"GZ · BZ2 · XZ · ZST · LZ4", @"单个文件压缩与解压" ],
            @[ @"ISO", @"ISO 9660 光盘映像，含 Joliet / Rock Ridge" ],
            @[ @"CPIO", @"Unix 归档格式" ],
        ],
        @[
            @[ @"RAR", @"RAR 4 和 RAR 5，含固实压缩" ],
            @[ @"分卷压缩包", @".part1.rar、.r00、.7z.001、.zip.001 等" ],
            @[ @"CAB", @"Windows 安装包" ],
            @[ @"LZH / LHA", @"日本常用的压缩格式" ],
            @[ @"XAR · PKG", @"macOS 安装包" ],
            @[ @"DEB · RPM · AR", @"Linux 软件包" ],
            @[ @"APK · IPA · JAR", @"基于 ZIP 的安装包" ],
            @[ @"LZMA · LZIP · Z", @"以及 UU、WARC、MTREE" ],
        ],
    ];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return (NSInteger)self.rows.count; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)self.rows[(NSUInteger)section].count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? @"压缩与解压" : @"仅解压";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) return nil;
    return [NSString stringWithFormat:@"加密的 RAR 和 7Z 暂不支持解压。\n\n压缩引擎：%s", archive_version_details()];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    NSArray<NSString *> *row = self.rows[(NSUInteger)indexPath.section][(NSUInteger)indexPath.row];
    UIListContentConfiguration *c = [UIListContentConfiguration subtitleCellConfiguration];
    c.text = row[0];
    c.textProperties.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    c.secondaryText = row[1];
    c.secondaryTextProperties.color = UIColor.secondaryLabelColor;
    c.image = [UIImage systemImageNamed:indexPath.section == 0 ? @"arrow.up.arrow.down.circle.fill" : @"arrow.up.circle.fill"];
    c.imageProperties.tintColor = indexPath.section == 0 ? UIColor.systemGreenColor : UIColor.systemBlueColor;
    cell.contentConfiguration = c;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    return cell;
}

@end

#pragma mark - Licenses

@implementation AMLicensesViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"开源组件许可";
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    UITextView *tv = [UITextView new];
    tv.editable = NO;
    tv.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    tv.adjustsFontForContentSizeCategory = YES;
    tv.textContainerInset = UIEdgeInsetsMake(16, 12, 32, 12);
    tv.translatesAutoresizingMaskIntoConstraints = NO;
    NSString *bsd2 =
        @"Redistribution and use in source and binary forms, with or without modification, are permitted provided that the "
        @"following conditions are met:\n1. Redistributions of source code must retain the above copyright notice, this list of "
        @"conditions and the following disclaimer.\n2. Redistributions in binary form must reproduce the above copyright notice, "
        @"this list of conditions and the following disclaimer in the documentation and/or other materials provided with the "
        @"distribution.\n\nTHIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS \"AS IS\" AND ANY EXPRESS OR IMPLIED "
        @"WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE "
        @"ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDERS OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, "
        @"SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; "
        @"LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN "
        @"CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS "
        @"SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.";
    NSString *bsd3 = [bsd2 stringByReplacingOccurrencesOfString:@"distribution.\n\nTHIS SOFTWARE"
                                                     withString:@"distribution.\n3. Neither the name Facebook, nor Meta, nor the names of its contributors may be used to "
                                                                @"endorse or promote products derived from this software without specific prior written permission.\n\nTHIS SOFTWARE"];
    tv.text = [NSString stringWithFormat:
        @"libarchive\nCopyright (c) 2003-2024 Tim Kientzle and the libarchive contributors. BSD 2-Clause License.\n\n%@\n\n"
        @"──────────\n\nZstandard (zstd)\nCopyright (c) Meta Platforms, Inc. and affiliates. All rights reserved. BSD 3-Clause License.\n\n%@\n\n"
        @"──────────\n\nLZ4 Library\nCopyright (c) 2011-2020, Yann Collet. BSD 2-Clause License.\n\n%@\n\n"
        @"──────────\n\nXZ Utils (liblzma)\nCopyright (C) The XZ Utils authors and contributors. BSD Zero Clause License (0BSD).\n"
        @"Permission to use, copy, modify, and/or distribute this software for any purpose with or without fee is hereby granted.",
        bsd2, bsd3, bsd2];
    [self.view addSubview:tv];
    [NSLayoutConstraint activateConstraints:@[
        [tv.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [tv.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [tv.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor],
        [tv.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor],
    ]];
}

@end
