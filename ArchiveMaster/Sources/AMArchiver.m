#import "AMArchiver.h"
#import "AMUI.h"

NSErrorDomain const AMArchiveErrorDomain = @"AMArchiveErrorDomain";

#pragma mark - Format info

@interface AMFormatInfo ()
@property (nonatomic, readwrite) am_format format;
@property (nonatomic, readwrite, copy) NSString *name;
@property (nonatomic, readwrite, copy) NSString *extension;
@property (nonatomic, readwrite, copy) NSString *summary;
@end

@implementation AMFormatInfo

+ (instancetype)f:(am_format)f name:(NSString *)name summary:(NSString *)summary {
    AMFormatInfo *i = [AMFormatInfo new];
    i.format = f;
    i.name = name;
    i.summary = summary;
    i.extension = @(am_format_extension(f));
    return i;
}

- (BOOL)singleFile { return am_format_is_single_file(self.format) != 0; }
- (BOOL)supportsPassword { return am_format_supports_password(self.format) != 0; }
- (BOOL)compresses {
    am_format f = self.format;
    return f != AM_FMT_TAR && f != AM_FMT_ISO && f != AM_FMT_CPIO && f != AM_FMT_RAR;
}

+ (NSArray<AMFormatInfo *> *)multiFileFormats {
    static NSArray *list;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        list = @[
            [self f:AM_FMT_ZIP name:@"ZIP" summary:L(@"兼容性最好，所有设备都能打开，可设置密码。")],
            [self f:AM_FMT_7Z name:@"7Z" summary:L(@"压缩率高，适合大文件，需要 7-Zip 等软件打开。")],
            [self f:AM_FMT_RAR name:@"RAR" summary:L(@"标准 RAR5 格式，所有支持 RAR 的软件都能打开。RAR 的压缩算法为 RARLAB 专有，因此这里只打包、不压缩；需要减小体积请选择 7Z 或 ZIP。")],
            [self f:AM_FMT_TAR_GZ name:@"TAR.GZ" summary:L(@"macOS 和 Linux 常用格式，速度快。")],
            [self f:AM_FMT_TAR_XZ name:@"TAR.XZ" summary:L(@"压缩率很高，但速度较慢。")],
            [self f:AM_FMT_TAR_ZST name:@"TAR.ZST" summary:L(@"Zstandard：速度与压缩率兼顾。")],
            [self f:AM_FMT_TAR_BZ2 name:@"TAR.BZ2" summary:L(@"传统的高压缩格式。")],
            [self f:AM_FMT_TAR_LZ4 name:@"TAR.LZ4" summary:L(@"速度极快，压缩率较低。")],
            [self f:AM_FMT_TAR name:@"TAR" summary:L(@"只打包不压缩，速度最快。")],
            [self f:AM_FMT_ISO name:@"ISO" summary:L(@"ISO 9660 光盘映像（含 Joliet 长文件名）。")],
            [self f:AM_FMT_CPIO name:@"CPIO" summary:L(@"Unix 归档格式，只打包不压缩。")],
        ];
    });
    return list;
}

+ (NSArray<AMFormatInfo *> *)singleFileFormats {
    static NSArray *list;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        list = @[
            [self f:AM_FMT_GZ name:@"GZ" summary:L(@"用 gzip 压缩这一个文件。")],
            [self f:AM_FMT_XZ name:@"XZ" summary:L(@"用 xz 压缩这一个文件，压缩率很高。")],
            [self f:AM_FMT_ZST name:@"ZST" summary:L(@"用 Zstandard 压缩这一个文件。")],
            [self f:AM_FMT_BZ2 name:@"BZ2" summary:L(@"用 bzip2 压缩这一个文件。")],
            [self f:AM_FMT_LZ4 name:@"LZ4" summary:L(@"用 LZ4 快速压缩这一个文件。")],
        ];
    });
    return list;
}

+ (AMFormatInfo *)infoForFormat:(am_format)format {
    for (AMFormatInfo *i in [self.multiFileFormats arrayByAddingObjectsFromArray:self.singleFileFormats])
        if (i.format == format) return i;
    return self.multiFileFormats.firstObject;
}

@end

@implementation AMArchiveEntry
@end

@implementation AMArchiveTask
@end

@implementation AMExtractOptions
+ (instancetype)fromSettings {
    AMExtractOptions *o = [AMExtractOptions new];
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    o.smart = [d boolForKey:AMDefaultsSmartExtract];
    o.deleteArchive = [d boolForKey:AMDefaultsDeleteAfterExtract];
    o.passwords = @[];
    return o;
}
@end

static int AMIncludeEntry(void *ctx, const char *path) {
    NSSet<NSString *> *set = (__bridge NSSet<NSString *> *)ctx;
    NSString *p = [NSString stringWithUTF8String:path];
    if (!p) return 0;
    if ([set containsObject:p]) return 1;
    for (NSString *sel in set)
        if ([p hasPrefix:[sel stringByAppendingString:@"/"]]) return 1;
    return 0;
}

#pragma mark - Progress relay (C callback -> main-queue block)

@interface AMProgressRelay : NSObject
@property (nonatomic, strong) AMArchiveTask *task;
@property (nonatomic, copy) AMProgressBlock block;
@property (nonatomic) CFAbsoluteTime last;
@property (nonatomic, copy) NSString *name;
@end

@implementation AMProgressRelay
@end

static int AMRelayProgress(void *ctx, int64_t done, int64_t total, const char *name) {
    AMProgressRelay *r = (__bridge AMProgressRelay *)ctx;
    if (r.task.cancelled) return 1;
    if (name) {
        NSString *n = [NSString stringWithUTF8String:name];
        if (n) r.name = n.lastPathComponent;
    }
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (r.block && (now - r.last > 0.05 || done >= total)) {
        r.last = now;
        double f = total > 0 ? (double)done / (double)total : 0;
        f = MAX(0, MIN(1, f));
        NSString *n = r.name;
        AMProgressBlock b = r.block;
        dispatch_async(dispatch_get_main_queue(), ^{ b(f, n); });
    }
    return 0;
}

static BOOL AMContains(NSString *s, NSString *needle) {
    return s && [s rangeOfString:needle options:NSCaseInsensitiveSearch].location != NSNotFound;
}

static NSError *AMMakeError(NSInteger code, const char *cmsg) {
    NSString *raw = (cmsg && *cmsg) ? [NSString stringWithUTF8String:cmsg] : nil;
    NSString *desc;
    BOOL showRaw = NO;
    switch (code) {
    case AM_CANCELLED: desc = L(@"操作已取消。"); break;
    case AM_NEED_PASSWORD: desc = L(@"此压缩包已加密，需要输入密码。"); break;
    case AM_BAD_PASSWORD: desc = L(@"密码不正确，请重试。"); break;
    case AMArchiveErrorEmpty: desc = L(@"压缩包里没有可以解压的内容。"); break;
    case AM_UNSUPPORTED:
        if (AMContains(raw, @"ncrypt") || AMContains(raw, @"crypto")) desc = L(@"暂不支持这种加密压缩包。目前可以解压加密的 ZIP，加密的 RAR 和 7Z 暂不支持。");
        else if (AMContains(raw, @"Unrecognized")) desc = L(@"无法识别这个文件，它可能不是压缩包，或者已经损坏。");
        else if (AMContains(raw, @"single file")) desc = L(@"这种格式只能压缩单个文件。请选择 ZIP、7Z 等格式来压缩多个项目或文件夹。");
        else { desc = L(@"不支持的格式。"); showRaw = YES; }
        break;
    default:
        showRaw = YES;
        if (AMContains(raw, @"No space")) desc = L(@"存储空间不足。");
        else if (AMContains(raw, @"Truncated") || AMContains(raw, @"Premature") || AMContains(raw, @"EOF") || AMContains(raw, @"truncated"))
            desc = L(@"压缩包不完整或已损坏，可能还没有下载完。如果是分卷压缩包，请确认所有分卷都在同一个文件夹中。");
        else if (AMContains(raw, @"volume")) desc = L(@"这是分卷压缩包的一部分。请把所有分卷放在同一个文件夹中，然后从第一个分卷开始解压。");
        else if (AMContains(raw, @"Damaged") || AMContains(raw, @"corrupt") || AMContains(raw, @"CRC") || AMContains(raw, @"checksum") || AMContains(raw, @"Invalid") || AMContains(raw, @"Bad"))
            desc = L(@"压缩包已损坏，无法完整解压。");
        else if (AMContains(raw, @"Permission")) desc = L(@"没有访问该文件的权限。");
        else desc = L(@"操作未能完成。");
        break;
    }
    NSMutableDictionary *info = [NSMutableDictionary dictionaryWithObject:desc forKey:NSLocalizedDescriptionKey];
    if (showRaw && raw.length) info[NSLocalizedFailureReasonErrorKey] = [NSString stringWithFormat:L(@"详细信息：%@"), raw];
    return [NSError errorWithDomain:AMArchiveErrorDomain code:code userInfo:info];
}

@implementation AMArchiver

+ (NSSet<NSString *> *)archiveExtensions {
    static NSSet *set;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        set = [NSSet setWithArray:@[
            @"zip", @"zipx", @"7z", @"rar", @"tar", @"gz", @"gzip", @"tgz", @"bz2", @"bz", @"tbz", @"tbz2", @"xz", @"txz",
            @"zst", @"zstd", @"tzst", @"lz4", @"tlz4", @"lzma", @"tlz", @"lz", @"z", @"taz", @"cab", @"iso", @"lzh", @"lha",
            @"xar", @"deb", @"rpm", @"cpio", @"ar", @"warc", @"jar", @"apk", @"ipa", @"xpi", @"crx", @"uu", @"mtree"
        ]];
    });
    return set;
}

+ (BOOL)isArchiveURL:(NSURL *)url {
    NSString *ext = url.pathExtension.lowercaseString;
    if ([self.archiveExtensions containsObject:ext]) return YES;
    // Split volumes: x.r00, x.z01, x.001, and x.7z.1 (a number after an archive extension).
    static NSRegularExpression *re, *digits;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        re = [NSRegularExpression regularExpressionWithPattern:@"^(\\d{3}|r\\d{2}|z\\d{2,})$" options:0 error:nil];
        digits = [NSRegularExpression regularExpressionWithPattern:@"^\\d+$" options:0 error:nil];
    });
    if ([re firstMatchInString:ext options:0 range:NSMakeRange(0, ext.length)]) return YES;
    if ([digits firstMatchInString:ext options:0 range:NSMakeRange(0, ext.length)]) {
        NSString *inner = url.lastPathComponent.stringByDeletingPathExtension.pathExtension.lowercaseString;
        return [self.archiveExtensions containsObject:inner];
    }
    return NO;
}

+ (NSString *)baseNameForArchive:(NSString *)fileName {
    NSString *name = fileName;
    NSRegularExpression *split = [NSRegularExpression regularExpressionWithPattern:@"\\.(\\d+|r\\d{2}|z\\d{2,})$" options:NSRegularExpressionCaseInsensitive error:nil];
    name = [split stringByReplacingMatchesInString:name options:0 range:NSMakeRange(0, name.length) withTemplate:@""];
    NSRegularExpression *part = [NSRegularExpression regularExpressionWithPattern:@"\\.part\\d+\\.rar$" options:NSRegularExpressionCaseInsensitive error:nil];
    if ([part firstMatchInString:name options:0 range:NSMakeRange(0, name.length)]) {
        name = [part stringByReplacingMatchesInString:name options:0 range:NSMakeRange(0, name.length) withTemplate:@""];
        return name.length ? name : fileName;
    }
    NSString *lower = name.lowercaseString;
    for (NSString *c in @[ @".tar.gz", @".tar.bz2", @".tar.xz", @".tar.zst", @".tar.lz4", @".tar.lzma", @".tar.lz", @".tar.z" ]) {
        if ([lower hasSuffix:c] && lower.length > c.length) return [name substringToIndex:name.length - c.length];
    }
    NSString *base = name.stringByDeletingPathExtension;
    return base.length ? base : fileName;
}

+ (NSString *)kindForArchive:(NSString *)fileName {
    NSString *lower = fileName.lowercaseString;
    NSRegularExpression *vol = [NSRegularExpression regularExpressionWithPattern:@"(\\.part\\d+\\.rar|\\.\\d+|\\.r\\d{2}|\\.z\\d{2,})$" options:0 error:nil];
    if ([vol firstMatchInString:lower options:0 range:NSMakeRange(0, lower.length)]) return L(@"分卷压缩包");
    for (NSString *c in @[ @"tar.gz", @"tar.bz2", @"tar.xz", @"tar.zst", @"tar.lz4" ]) {
        if ([lower hasSuffix:[@"." stringByAppendingString:c]]) return [NSString stringWithFormat:L(@"%@ 压缩包"), c.uppercaseString];
    }
    NSString *ext = lower.pathExtension;
    if ([ext isEqualToString:@"iso"]) return L(@"ISO 光盘映像");
    if ([@[ @"apk", @"ipa", @"deb", @"rpm", @"xpi", @"crx" ] containsObject:ext]) return [NSString stringWithFormat:L(@"%@ 安装包"), ext.uppercaseString];
    return [NSString stringWithFormat:L(@"%@ 压缩包"), ext.uppercaseString];
}

/// Siblings of `name` in `names` matching `<base><infix><number><suffix>`, sorted by number; nil unless
/// they form a run starting at 0 or 1 with no gaps and at least `minParts` parts.
static NSArray<NSString *> *AMNumberedRun(NSArray<NSString *> *names, NSString *base, NSString *infix, NSString *suffix, NSUInteger minParts) {
    NSString *pattern = [NSString stringWithFormat:@"^%@%@(\\d+)%@$", [NSRegularExpression escapedPatternForString:base],
                                                   [NSRegularExpression escapedPatternForString:infix],
                                                   [NSRegularExpression escapedPatternForString:suffix]];
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pattern options:NSRegularExpressionCaseInsensitive error:nil];
    NSMutableDictionary<NSNumber *, NSString *> *byNumber = [NSMutableDictionary dictionary];
    for (NSString *n in names) {
        NSTextCheckingResult *m = [re firstMatchInString:n options:0 range:NSMakeRange(0, n.length)];
        if (m) byNumber[@([[n substringWithRange:[m rangeAtIndex:1]] integerValue])] = n;
    }
    NSInteger first = byNumber[@0] ? 0 : 1;
    NSMutableArray *run = [NSMutableArray array];
    for (NSInteger i = first; byNumber[@(i)]; i++) [run addObject:byNumber[@(i)]];
    return run.count >= minParts ? run : nil;
}

/// Ordered list of volumes that make up the archive at `url` (just `url` when it isn't split, or
/// when the folder can't be listed). Handles x.part1.rar, x.rar + x.r00, x.z01 … x.zip, and
/// numbered pieces such as x.7z.001 or x.7z.1.
+ (NSArray<NSURL *> *)volumesForArchive:(NSURL *)url {
    NSURL *dir = url.URLByDeletingLastPathComponent;
    NSString *name = url.lastPathComponent;
    NSArray<NSString *> *names = [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir.path error:nil];
    if (names.count < 2) return @[ url ];
    NSRange all = NSMakeRange(0, name.length);
    NSArray<NSURL *> *(^urls)(NSArray<NSString *> *) = ^NSArray<NSURL *> *(NSArray<NSString *> *list) {
        NSMutableArray *out = [NSMutableArray array];
        for (NSString *n in list) [out addObject:[dir URLByAppendingPathComponent:n]];
        return out;
    };

    // x.part1.rar, x.part2.rar, ...
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"^(.*)\\.part\\d+\\.rar$" options:NSRegularExpressionCaseInsensitive error:nil];
    NSTextCheckingResult *m = [re firstMatchInString:name options:0 range:all];
    if (m) {
        NSArray *run = AMNumberedRun(names, [name substringWithRange:[m rangeAtIndex:1]], @".part", @".rar", 2);
        return run ? urls(run) : @[ url ];
    }

    // Spanned ZIP: x.z01, x.z02, ..., x.zip (read in that order).
    re = [NSRegularExpression regularExpressionWithPattern:@"^(.*)\\.(zip|z\\d{2,})$" options:NSRegularExpressionCaseInsensitive error:nil];
    m = [re firstMatchInString:name options:0 range:all];
    if (m) {
        NSString *base = [name substringWithRange:[m rangeAtIndex:1]];
        NSArray *run = AMNumberedRun(names, base, @".z", @"", 1);
        NSString *zip = nil;
        for (NSString *n in names) if ([n caseInsensitiveCompare:[base stringByAppendingString:@".zip"]] == NSOrderedSame) zip = n;
        if (run.count && zip) return urls([run arrayByAddingObject:zip]);
    }

    // Old-style RAR volumes: x.rar, x.r00, x.r01, ...
    re = [NSRegularExpression regularExpressionWithPattern:@"^(.*)\\.(rar|r\\d{2})$" options:NSRegularExpressionCaseInsensitive error:nil];
    m = [re firstMatchInString:name options:0 range:all];
    if (m) {
        NSString *base = [name substringWithRange:[m rangeAtIndex:1]];
        NSString *rar = nil;
        for (NSString *n in names) if ([n caseInsensitiveCompare:[base stringByAppendingString:@".rar"]] == NSOrderedSame) rar = n;
        NSMutableDictionary<NSNumber *, NSString *> *byNumber = [NSMutableDictionary dictionary];
        NSRegularExpression *rx = [NSRegularExpression regularExpressionWithPattern:
            [NSString stringWithFormat:@"^%@\\.r(\\d{2})$", [NSRegularExpression escapedPatternForString:base]] options:NSRegularExpressionCaseInsensitive error:nil];
        for (NSString *n in names) {
            NSTextCheckingResult *mm = [rx firstMatchInString:n options:0 range:NSMakeRange(0, n.length)];
            if (mm) byNumber[@([[n substringWithRange:[mm rangeAtIndex:1]] integerValue])] = n;
        }
        if (rar && byNumber[@0]) {
            NSMutableArray *run = [NSMutableArray arrayWithObject:rar];
            for (NSInteger i = 0; byNumber[@(i)]; i++) [run addObject:byNumber[@(i)]];
            return urls(run);
        }
        if (!rar) return @[ url ];
    }

    // Numbered pieces: x.7z.001 / x.7z.1 / x.001 ...
    re = [NSRegularExpression regularExpressionWithPattern:@"^(.*)\\.(\\d+)$" options:0 error:nil];
    m = [re firstMatchInString:name options:0 range:all];
    if (m) {
        NSArray *run = AMNumberedRun(names, [name substringWithRange:[m rangeAtIndex:1]], @".", @"", 2);
        if (run) return urls(run);
    }
    return @[ url ];
}

+ (NSArray<NSArray<NSURL *> *> *)volumeGroupsForURLs:(NSArray<NSURL *> *)urls {
    NSMutableDictionary<NSString *, NSMutableArray<NSURL *> *> *byBase = [NSMutableDictionary dictionary];
    NSMutableArray<NSString *> *order = [NSMutableArray array];
    for (NSURL *u in urls) {
        NSString *key = [self baseNameForArchive:u.lastPathComponent].lowercaseString;
        if (!byBase[key]) { byBase[key] = [NSMutableArray array]; [order addObject:key]; }
        [byBase[key] addObject:u];
    }
    NSMutableArray *groups = [NSMutableArray array];
    for (NSString *key in order) {
        NSMutableArray<NSURL *> *g = byBase[key];
        [g sortUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
            // Old-style RAR sets start with x.rar, then x.r00, x.r01...; spanned ZIPs end with x.zip.
            NSString *ea = a.pathExtension.lowercaseString, *eb = b.pathExtension.lowercaseString;
            if ([ea isEqualToString:@"rar"] != [eb isEqualToString:@"rar"]) return [ea isEqualToString:@"rar"] ? NSOrderedAscending : NSOrderedDescending;
            return [a.lastPathComponent localizedStandardCompare:b.lastPathComponent];
        }];
        [groups addObject:g];
    }
    return groups;
}

/// Runs the C extractor over all volumes. Must be called on a background queue.
+ (int)extractVolumes:(NSArray<NSURL *> *)volumes
                 into:(NSURL *)dir
            passwords:(NSArray<NSString *> *)passwords
            onlyPaths:(NSSet<NSString *> *)onlyPaths
                relay:(AMProgressRelay *)relay
                  err:(char *)err
               errlen:(size_t)errlen {
    NSString *encoding = [NSUserDefaults.standardUserDefaults stringForKey:AMDefaultsEncoding] ?: @"";
    const char **pw = calloc(passwords.count + 1, sizeof *pw);
    for (NSUInteger i = 0; i < passwords.count; i++) pw[i] = passwords[i].UTF8String;
    am_read_opts ro = {
        .passwords = pw,
        .password_count = (int)passwords.count,
        .charset = encoding.length ? encoding.UTF8String : NULL,
        .include = onlyPaths.count ? AMIncludeEntry : NULL,
        .include_ctx = (__bridge void *)onlyPaths,
    };
    const char **paths = calloc(volumes.count, sizeof *paths);
    for (NSUInteger i = 0; i < volumes.count; i++) paths[i] = volumes[i].fileSystemRepresentation;
    int rc = am_extract_volumes(paths, (int)volumes.count, dir.fileSystemRepresentation, &ro,
                                AMRelayProgress, (__bridge void *)relay, err, errlen);
    free(paths);
    free(pw);
    return rc;
}

#pragma mark - Extract

+ (AMArchiveTask *)extractArchive:(NSURL *)archive
                      toDirectory:(NSURL *)directory
                          options:(AMExtractOptions *)options
                         progress:(AMProgressBlock)progress
                       completion:(void (^)(NSURL *, NSError *))completion {
    AMArchiveTask *task = [AMArchiveTask new];
    BOOL smart = options.smart, deleteAfter = options.deleteArchive && options.onlyPaths.count == 0;
    NSArray<NSString *> *passwords = [options.passwords copy] ?: @[];
    NSSet<NSString *> *onlyPaths = [options.onlyPaths copy];
    NSArray<NSURL *> *explicitVolumes = [options.volumes copy];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSFileManager *fm = NSFileManager.defaultManager;
        NSArray<NSURL *> *volumes = explicitVolumes.count ? explicitVolumes : [self volumesForArchive:archive];
        NSURL *tmp = [directory URLByAppendingPathComponent:[@".extracting-" stringByAppendingString:NSUUID.UUID.UUIDString] isDirectory:YES];
        NSError *error = nil;
        NSURL *result = nil;

        if ([fm createDirectoryAtURL:tmp withIntermediateDirectories:YES attributes:nil error:&error]) {
            AMProgressRelay *relay = [AMProgressRelay new];
            relay.task = task;
            relay.block = progress;
            char err[1024] = "";
            int rc = [self extractVolumes:volumes into:tmp passwords:passwords onlyPaths:onlyPaths relay:relay err:err errlen:sizeof err];
            if (rc == AM_OK) {
                NSArray<NSURL *> *items = [fm contentsOfDirectoryAtURL:tmp includingPropertiesForKeys:nil options:0 error:nil];
                NSURL *single = onlyPaths.count == 1 ? [tmp URLByAppendingPathComponent:onlyPaths.anyObject] : nil;
                if (items.count == 0) {
                    error = AMMakeError(AMArchiveErrorEmpty, NULL);
                } else if (single && [fm fileExistsAtPath:single.path]) {
                    NSURL *dest = [AMUI uniqueURLForName:single.lastPathComponent inDirectory:directory];
                    if ([fm moveItemAtURL:single toURL:dest error:&error]) result = dest;
                } else if (smart && items.count == 1) {
                    NSURL *dest = [AMUI uniqueURLForName:items[0].lastPathComponent inDirectory:directory];
                    if ([fm moveItemAtURL:items[0] toURL:dest error:&error]) result = dest;
                } else {
                    NSURL *dest = [AMUI uniqueURLForName:[self baseNameForArchive:archive.lastPathComponent] inDirectory:directory];
                    if ([fm moveItemAtURL:tmp toURL:dest error:&error]) result = dest;
                }
            } else {
                error = AMMakeError(rc, err);
            }
            if (result && deleteAfter) {
                for (NSURL *v in volumes) [fm removeItemAtURL:v error:nil];
            }
        }
        [fm removeItemAtURL:tmp error:nil];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(result, result ? nil : error); });
    });
    return task;
}

+ (AMArchiveTask *)extractEntry:(NSString *)path
                    fromArchive:(NSURL *)archive
                      passwords:(NSArray<NSString *> *)passwords
                       progress:(AMProgressBlock)progress
                     completion:(void (^)(NSURL *, NSError *))completion {
    AMArchiveTask *task = [AMArchiveTask new];
    NSArray<NSString *> *pw = [passwords copy] ?: @[];
    NSString *entry = [path copy];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSFileManager *fm = NSFileManager.defaultManager;
        NSURL *tmp = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
                                                 [@"Preview/" stringByAppendingString:NSUUID.UUID.UUIDString]] isDirectory:YES];
        [fm createDirectoryAtURL:tmp withIntermediateDirectories:YES attributes:nil error:nil];
        AMProgressRelay *relay = [AMProgressRelay new];
        relay.task = task;
        relay.block = progress;
        char err[1024] = "";
        int rc = [self extractVolumes:[self volumesForArchive:archive] into:tmp passwords:pw
                            onlyPaths:[NSSet setWithObject:entry] relay:relay err:err errlen:sizeof err];
        NSURL *file = [tmp URLByAppendingPathComponent:entry];
        NSError *error = nil;
        if (rc != AM_OK) error = AMMakeError(rc, err);
        else if (![fm fileExistsAtPath:file.path]) error = AMMakeError(AMArchiveErrorEmpty, NULL);
        if (error) [fm removeItemAtURL:tmp error:nil];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(error ? nil : file, error); });
    });
    return task;
}

#pragma mark - Create

+ (AMArchiveTask *)createArchiveNamed:(NSString *)name
                          inDirectory:(NSURL *)directory
                            fromItems:(NSArray<NSURL *> *)items
                               format:(am_format)format
                                level:(NSInteger)level
                             password:(NSString *)password
                           encryption:(am_encryption)encryption
                             progress:(AMProgressBlock)progress
                           completion:(void (^)(NSURL *, NSError *))completion {
    AMArchiveTask *task = [AMArchiveTask new];
    NSString *pw = [password copy];
    NSArray<NSURL *> *inputs = [items copy];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSFileManager *fm = NSFileManager.defaultManager;
        NSString *ext = @(am_format_extension(format));
        NSString *finalName = [name stringByAppendingFormat:@".%@", ext];
        NSURL *tmp = [directory URLByAppendingPathComponent:[NSString stringWithFormat:@".creating-%@.%@", NSUUID.UUID.UUIDString, ext]];

        AMProgressRelay *relay = [AMProgressRelay new];
        relay.task = task;
        relay.block = progress;
        am_write_opts wo = { .format = format, .level = (int)level,
                             .password = pw.length ? pw.UTF8String : NULL,
                             .encryption = pw.length ? encryption : AM_ENC_NONE };
        const char **paths = calloc(inputs.count, sizeof *paths);
        for (NSUInteger i = 0; i < inputs.count; i++) paths[i] = inputs[i].fileSystemRepresentation;
        char err[1024] = "";
        int rc = am_create(tmp.fileSystemRepresentation, paths, (int)inputs.count, &wo, AMRelayProgress,
                           (__bridge void *)relay, err, sizeof err);
        free(paths);

        NSURL *result = nil;
        NSError *error = nil;
        if (rc == AM_OK) {
            NSURL *dest = [AMUI uniqueURLForName:finalName inDirectory:directory];
            if ([fm moveItemAtURL:tmp toURL:dest error:&error]) result = dest;
        } else {
            error = AMMakeError(rc, err);
        }
        [fm removeItemAtURL:tmp error:nil];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(result, result ? nil : error); });
    });
    return task;
}

#pragma mark - Several archives

/// Runs am_create into `output` (a temporary name). Must be called on a background queue.
+ (int)createAt:(NSURL *)output
          items:(NSArray<NSURL *> *)items
           opts:(am_write_opts)wo
          relay:(AMProgressRelay *)relay
            err:(char *)err
         errlen:(size_t)errlen {
    const char **paths = calloc(items.count, sizeof *paths);
    for (NSUInteger i = 0; i < items.count; i++) paths[i] = items[i].fileSystemRepresentation;
    int rc = am_create(output.fileSystemRepresentation, paths, (int)items.count, &wo, AMRelayProgress, (__bridge void *)relay, err, errlen);
    free(paths);
    return rc;
}

static AMProgressBlock AMScaled(AMProgressBlock block, double base, double span) {
    if (!block) return nil;
    return ^(double f, NSString *item) { block(base + f * span, item); };
}

+ (AMArchiveTask *)createArchivesNamed:(NSString *)name
                           inDirectory:(NSURL *)directory
                             fromItems:(NSArray<NSURL *> *)items
                                format:(am_format)format
                                 level:(NSInteger)level
                              password:(NSString *)password
                            encryption:(am_encryption)encryption
                                output:(AMOutputMode)output
                                 count:(NSInteger)count
                              progress:(AMProgressBlock)progress
                            completion:(void (^)(NSArray<NSURL *> *, NSError *))completion {
    if (output == AMOutputSingle || count < 2) {
        return [self createArchiveNamed:name inDirectory:directory fromItems:items format:format level:level password:password
                             encryption:encryption progress:progress completion:^(NSURL *result, NSError *error) {
            completion(result ? @[ result ] : @[], error);
        }];
    }
    AMArchiveTask *task = [AMArchiveTask new];
    NSString *pw = [password copy];
    NSArray<NSURL *> *inputs = [items copy];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSFileManager *fm = NSFileManager.defaultManager;
        NSString *ext = @(am_format_extension(format));
        am_write_opts wo = { .format = format, .level = (int)level,
                             .password = pw.length ? pw.UTF8String : NULL,
                             .encryption = pw.length ? encryption : AM_ENC_NONE };
        NSMutableArray<NSURL *> *results = [NSMutableArray array];
        NSError *error = nil;
        char err[1024] = "";
        AMProgressRelay *relay = [AMProgressRelay new];
        relay.task = task;

        if (output == AMOutputVolumes) {
            // Build the whole archive, then cut it into `count` pieces from the end.
            NSURL *tmp = [directory URLByAppendingPathComponent:[NSString stringWithFormat:@".creating-%@.%@", NSUUID.UUID.UUIDString, ext]];
            relay.block = AMScaled(progress, 0, 0.9);
            int rc = [self createAt:tmp items:inputs opts:wo relay:relay err:err errlen:sizeof err];
            if (rc == AM_OK) {
                NSString *base = name;
                for (NSInteger k = 2; [fm fileExistsAtPath:[directory URLByAppendingPathComponent:[NSString stringWithFormat:@"%@.%@.001", base, ext]].path]; k++)
                    base = [NSString stringWithFormat:@"%@ %ld", name, (long)k];
                NSMutableArray<NSURL *> *parts = [NSMutableArray array];
                const char **outs = calloc((size_t)count, sizeof *outs);
                for (NSInteger i = 0; i < count; i++) {
                    NSURL *u = [directory URLByAppendingPathComponent:[NSString stringWithFormat:@"%@.%@.%03ld", base, ext, (long)i + 1]];
                    [parts addObject:u];
                    outs[i] = u.fileSystemRepresentation;
                }
                relay.block = AMScaled(progress, 0.9, 0.1);
                rc = am_split_file(tmp.fileSystemRepresentation, (int)count, outs, AMRelayProgress, (__bridge void *)relay, err, sizeof err);
                free(outs);
                if (rc == AM_OK)
                    for (NSURL *u in parts) if ([fm fileExistsAtPath:u.path]) [results addObject:u];
            }
            if (rc != AM_OK) error = AMMakeError(rc, err);
            [fm removeItemAtURL:tmp error:nil];
        } else {
            // Units to distribute: the selected items, or a single folder's contents (kept under its name).
            NSArray<NSURL *> *units = inputs;
            NSString *prefix = nil;
            NSNumber *isDir = nil;
            [inputs.firstObject getResourceValue:&isDir forKey:NSURLIsDirectoryKey error:nil];
            if (inputs.count == 1 && isDir.boolValue) {
                units = [fm contentsOfDirectoryAtURL:inputs.firstObject includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:nil] ?: @[];
                prefix = inputs.firstObject.lastPathComponent;
            }
            NSInteger n = MIN(count, (NSInteger)units.count);
            if (n < 1) {
                error = AMMakeError(AMArchiveErrorEmpty, NULL);
            } else {
                // Largest first into the lightest archive keeps the sizes close.
                NSMutableArray *sized = [NSMutableArray array];
                for (NSURL *u in units) [sized addObject:@[ u, @([AMUI sizeOfItemAtURL:u]) ]];
                [sized sortUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) { return [b[1] compare:a[1]]; }];
                NSMutableArray<NSMutableArray<NSURL *> *> *bins = [NSMutableArray array];
                NSMutableArray<NSNumber *> *weights = [NSMutableArray array];
                for (NSInteger i = 0; i < n; i++) { [bins addObject:[NSMutableArray array]]; [weights addObject:@0]; }
                unsigned long long total = 0;
                for (NSArray *pair in sized) {
                    NSUInteger best = 0;
                    for (NSUInteger i = 1; i < bins.count; i++) if (weights[i].unsignedLongLongValue < weights[best].unsignedLongLongValue) best = i;
                    [bins[best] addObject:pair[0]];
                    weights[best] = @(weights[best].unsignedLongLongValue + [pair[1] unsignedLongLongValue]);
                    total += [pair[1] unsignedLongLongValue];
                }
                double base = 0;
                wo.prefix = prefix.length ? prefix.UTF8String : NULL;
                for (NSInteger i = 0; i < n && !error; i++) {
                    double span = total ? (double)weights[i].unsignedLongLongValue / (double)total : 1.0 / n;
                    relay.block = AMScaled(progress, base, span);
                    base += span;
                    NSURL *tmp = [directory URLByAppendingPathComponent:[NSString stringWithFormat:@".creating-%@.%@", NSUUID.UUID.UUIDString, ext]];
                    int rc = [self createAt:tmp items:bins[i] opts:wo relay:relay err:err errlen:sizeof err];
                    if (rc == AM_OK) {
                        NSURL *dest = [AMUI uniqueURLForName:[NSString stringWithFormat:@"%@-%ld.%@", name, (long)i + 1, ext] inDirectory:directory];
                        if ([fm moveItemAtURL:tmp toURL:dest error:&error]) [results addObject:dest];
                    } else {
                        error = AMMakeError(rc, err);
                    }
                    [fm removeItemAtURL:tmp error:nil];
                }
            }
        }
        if (error) {
            for (NSURL *u in results) [fm removeItemAtURL:u error:nil];
            [results removeAllObjects];
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(results, results.count ? nil : error); });
    });
    return task;
}

#pragma mark - List

static int AMCollectEntry(void *ctx, const am_entry_info *info) {
    NSMutableArray *list = (__bridge NSMutableArray *)ctx;
    if (list.count >= 20000) return 1;
    AMArchiveEntry *e = [AMArchiveEntry new];
    e.path = [NSString stringWithUTF8String:info->path] ?: @"?";
    e.size = info->size;
    e.isDirectory = info->is_dir != 0;
    e.encrypted = info->is_encrypted != 0;
    [list addObject:e];
    return 0;
}

+ (void)listArchive:(NSURL *)archive completion:(void (^)(NSArray<AMArchiveEntry *> *, BOOL, NSError *))completion {
    NSString *encoding = [NSUserDefaults.standardUserDefaults stringForKey:AMDefaultsEncoding] ?: @"";
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<NSURL *> *volumes = [self volumesForArchive:archive];
        NSMutableArray *list = [NSMutableArray array];
        char err[1024] = "";
        am_read_opts ro = { .charset = encoding.length ? encoding.UTF8String : NULL };
        const char **paths = calloc(volumes.count, sizeof *paths);
        for (NSUInteger i = 0; i < volumes.count; i++) paths[i] = volumes[i].fileSystemRepresentation;
        int rc = am_list_volumes(paths, (int)volumes.count, &ro, AMCollectEntry, (__bridge void *)list, err, sizeof err);
        free(paths);
        NSError *error = (rc == AM_OK || list.count) ? nil : AMMakeError(rc, err);
        BOOL truncated = list.count >= 20000;
        dispatch_async(dispatch_get_main_queue(), ^{ completion(list, truncated, error); });
    });
}

@end
