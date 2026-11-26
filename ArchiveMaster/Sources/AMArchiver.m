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

+ (NSArray<AMFormatInfo *> *)multiFileFormats {
    static NSArray *list;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        list = @[
            [self f:AM_FMT_ZIP name:@"ZIP" summary:@"兼容性最好，所有设备都能打开，可设置密码。"],
            [self f:AM_FMT_7Z name:@"7Z" summary:@"压缩率高，适合大文件，需要 7-Zip 等软件打开。"],
            [self f:AM_FMT_TAR_GZ name:@"TAR.GZ" summary:@"macOS 和 Linux 常用格式，速度快。"],
            [self f:AM_FMT_TAR_XZ name:@"TAR.XZ" summary:@"压缩率很高，但速度较慢。"],
            [self f:AM_FMT_TAR_ZST name:@"TAR.ZST" summary:@"Zstandard：速度与压缩率兼顾。"],
            [self f:AM_FMT_TAR_BZ2 name:@"TAR.BZ2" summary:@"传统的高压缩格式。"],
            [self f:AM_FMT_TAR_LZ4 name:@"TAR.LZ4" summary:@"速度极快，压缩率较低。"],
            [self f:AM_FMT_TAR name:@"TAR" summary:@"只打包不压缩，速度最快。"],
            [self f:AM_FMT_ISO name:@"ISO" summary:@"ISO 9660 光盘映像（含 Joliet 长文件名）。"],
            [self f:AM_FMT_CPIO name:@"CPIO" summary:@"Unix 归档格式，只打包不压缩。"],
        ];
    });
    return list;
}

+ (NSArray<AMFormatInfo *> *)singleFileFormats {
    static NSArray *list;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        list = @[
            [self f:AM_FMT_GZ name:@"GZ" summary:@"用 gzip 压缩这一个文件。"],
            [self f:AM_FMT_XZ name:@"XZ" summary:@"用 xz 压缩这一个文件，压缩率很高。"],
            [self f:AM_FMT_ZST name:@"ZST" summary:@"用 Zstandard 压缩这一个文件。"],
            [self f:AM_FMT_BZ2 name:@"BZ2" summary:@"用 bzip2 压缩这一个文件。"],
            [self f:AM_FMT_LZ4 name:@"LZ4" summary:@"用 LZ4 快速压缩这一个文件。"],
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
    case AM_CANCELLED: desc = @"操作已取消。"; break;
    case AM_NEED_PASSWORD: desc = @"此压缩包已加密，需要输入密码。"; break;
    case AM_BAD_PASSWORD: desc = @"密码不正确，请重试。"; break;
    case AMArchiveErrorEmpty: desc = @"压缩包里没有可以解压的内容。"; break;
    case AM_UNSUPPORTED:
        if (AMContains(raw, @"ncrypt") || AMContains(raw, @"crypto")) desc = @"暂不支持这种加密压缩包。目前可以解压加密的 ZIP，加密的 RAR 和 7Z 暂不支持。";
        else if (AMContains(raw, @"Unrecognized")) desc = @"无法识别这个文件，它可能不是压缩包，或者已经损坏。";
        else if (AMContains(raw, @"single file")) desc = @"这种格式只能压缩单个文件。请选择 ZIP、7Z 等格式来压缩多个项目或文件夹。";
        else { desc = @"不支持的格式。"; showRaw = YES; }
        break;
    default:
        showRaw = YES;
        if (AMContains(raw, @"No space")) desc = @"存储空间不足。";
        else if (AMContains(raw, @"Truncated") || AMContains(raw, @"Premature") || AMContains(raw, @"EOF") || AMContains(raw, @"truncated"))
            desc = @"压缩包不完整或已损坏，可能还没有下载完。如果是分卷压缩包，请确认所有分卷都在同一个文件夹中。";
        else if (AMContains(raw, @"volume")) desc = @"这是分卷压缩包的一部分。请把所有分卷放在同一个文件夹中，然后从第一个分卷开始解压。";
        else if (AMContains(raw, @"Damaged") || AMContains(raw, @"corrupt") || AMContains(raw, @"CRC") || AMContains(raw, @"checksum") || AMContains(raw, @"Invalid") || AMContains(raw, @"Bad"))
            desc = @"压缩包已损坏，无法完整解压。";
        else if (AMContains(raw, @"Permission")) desc = @"没有访问该文件的权限。";
        else desc = @"操作未能完成。";
        break;
    }
    NSMutableDictionary *info = [NSMutableDictionary dictionaryWithObject:desc forKey:NSLocalizedDescriptionKey];
    if (showRaw && raw.length) info[NSLocalizedFailureReasonErrorKey] = [NSString stringWithFormat:@"详细信息：%@", raw];
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
    // Split volumes: x.001, x.r00
    static NSRegularExpression *re;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        re = [NSRegularExpression regularExpressionWithPattern:@"^(\\d{3}|r\\d{2})$" options:0 error:nil];
    });
    return [re firstMatchInString:ext options:0 range:NSMakeRange(0, ext.length)] != nil;
}

+ (NSString *)baseNameForArchive:(NSString *)fileName {
    NSString *name = fileName;
    NSRegularExpression *split = [NSRegularExpression regularExpressionWithPattern:@"\\.(\\d{3}|r\\d{2})$" options:NSRegularExpressionCaseInsensitive error:nil];
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
    NSRegularExpression *vol = [NSRegularExpression regularExpressionWithPattern:@"(\\.part\\d+\\.rar|\\.\\d{3}|\\.r\\d{2})$" options:0 error:nil];
    if ([vol firstMatchInString:lower options:0 range:NSMakeRange(0, lower.length)]) return @"分卷压缩包";
    for (NSString *c in @[ @"tar.gz", @"tar.bz2", @"tar.xz", @"tar.zst", @"tar.lz4" ]) {
        if ([lower hasSuffix:[@"." stringByAppendingString:c]]) return [NSString stringWithFormat:@"%@ 压缩包", c.uppercaseString];
    }
    NSString *ext = lower.pathExtension;
    if ([ext isEqualToString:@"iso"]) return @"ISO 光盘映像";
    if ([@[ @"apk", @"ipa", @"deb", @"rpm", @"xpi", @"crx" ] containsObject:ext]) return [NSString stringWithFormat:@"%@ 安装包", ext.uppercaseString];
    return [NSString stringWithFormat:@"%@ 压缩包", ext.uppercaseString];
}

/// Ordered list of volumes that make up the archive at `url` (just `url` when it isn't split).
+ (NSArray<NSURL *> *)volumesForArchive:(NSURL *)url {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *dir = url.URLByDeletingLastPathComponent;
    NSString *name = url.lastPathComponent;
    NSRange all = NSMakeRange(0, name.length);

    // name.part1.rar, name.part2.rar, ...
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"^(.*\\.)(part)(\\d+)(\\.rar)$" options:NSRegularExpressionCaseInsensitive error:nil];
    NSTextCheckingResult *m = [re firstMatchInString:name options:0 range:all];
    if (m) {
        NSString *base = [name substringWithRange:[m rangeAtIndex:1]];
        NSString *partWord = [name substringWithRange:[m rangeAtIndex:2]];
        int width = (int)[m rangeAtIndex:3].length;
        NSString *ext = [name substringWithRange:[m rangeAtIndex:4]];
        NSMutableArray *vols = [NSMutableArray array];
        for (long i = 1; i < 10000; i++) {
            NSString *n = [NSString stringWithFormat:@"%@%@%0*ld%@", base, partWord, width, i, ext];
            NSURL *u = [dir URLByAppendingPathComponent:n];
            if (![fm fileExistsAtPath:u.path]) break;
            [vols addObject:u];
        }
        return vols.count ? vols : @[ url ];
    }

    // name.7z.001, name.7z.002, ...
    re = [NSRegularExpression regularExpressionWithPattern:@"^(.*)\\.(\\d{3})$" options:0 error:nil];
    m = [re firstMatchInString:name options:0 range:all];
    if (m) {
        NSString *base = [name substringWithRange:[m rangeAtIndex:1]];
        NSMutableArray *vols = [NSMutableArray array];
        for (long i = 1; i < 1000; i++) {
            NSURL *u = [dir URLByAppendingPathComponent:[NSString stringWithFormat:@"%@.%03ld", base, i]];
            if (![fm fileExistsAtPath:u.path]) break;
            [vols addObject:u];
        }
        return vols.count ? vols : @[ url ];
    }

    // Old-style RAR volumes: name.rar, name.r00, name.r01, ...
    re = [NSRegularExpression regularExpressionWithPattern:@"^(.*)\\.(rar|r\\d{2})$" options:NSRegularExpressionCaseInsensitive error:nil];
    m = [re firstMatchInString:name options:0 range:all];
    if (m) {
        NSString *base = [name substringWithRange:[m rangeAtIndex:1]];
        NSString *ext = [name substringWithRange:[m rangeAtIndex:2]];
        BOOL upper = [ext isEqualToString:ext.uppercaseString];
        NSURL *main = [dir URLByAppendingPathComponent:[base stringByAppendingString:upper ? @".RAR" : @".rar"]];
        if (![fm fileExistsAtPath:main.path]) return @[ url ];
        NSMutableArray *vols = [NSMutableArray arrayWithObject:main];
        for (long i = 0; i < 100; i++) {
            NSURL *u = [dir URLByAppendingPathComponent:[NSString stringWithFormat:upper ? @"%@.R%02ld" : @"%@.r%02ld", base, i]];
            if (![fm fileExistsAtPath:u.path]) break;
            [vols addObject:u];
        }
        return vols;
    }
    return @[ url ];
}

+ (am_read_opts)readOptionsWithPassword:(NSString *)password encoding:(NSString *)encoding {
    am_read_opts o = { .password = password.length ? password.UTF8String : NULL,
                       .charset = encoding.length ? encoding.UTF8String : NULL };
    return o;
}

#pragma mark - Extract

+ (AMArchiveTask *)extractArchive:(NSURL *)archive
                      toDirectory:(NSURL *)directory
                         password:(NSString *)password
                         progress:(AMProgressBlock)progress
                       completion:(void (^)(NSURL *, NSError *))completion {
    AMArchiveTask *task = [AMArchiveTask new];
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    BOOL smart = [d boolForKey:AMDefaultsSmartExtract];
    BOOL deleteAfter = [d boolForKey:AMDefaultsDeleteAfterExtract];
    NSString *encoding = [d stringForKey:AMDefaultsEncoding] ?: @"";
    NSString *pw = [password copy];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSFileManager *fm = NSFileManager.defaultManager;
        NSArray<NSURL *> *volumes = [self volumesForArchive:archive];
        NSURL *tmp = [directory URLByAppendingPathComponent:[@".extracting-" stringByAppendingString:NSUUID.UUID.UUIDString] isDirectory:YES];
        NSError *error = nil;
        NSURL *result = nil;

        if ([fm createDirectoryAtURL:tmp withIntermediateDirectories:YES attributes:nil error:&error]) {
            AMProgressRelay *relay = [AMProgressRelay new];
            relay.task = task;
            relay.block = progress;
            char err[1024] = "";
            am_read_opts ro = [self readOptionsWithPassword:pw encoding:encoding];
            const char **paths = calloc(volumes.count, sizeof *paths);
            for (NSUInteger i = 0; i < volumes.count; i++) paths[i] = volumes[i].fileSystemRepresentation;
            int rc = am_extract_volumes(paths, (int)volumes.count, tmp.fileSystemRepresentation, &ro,
                                        AMRelayProgress, (__bridge void *)relay, err, sizeof err);
            free(paths);

            if (rc == AM_OK) {
                NSArray<NSURL *> *items = [fm contentsOfDirectoryAtURL:tmp includingPropertiesForKeys:nil options:0 error:nil];
                if (items.count == 0) {
                    error = AMMakeError(AMArchiveErrorEmpty, NULL);
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
        am_read_opts ro = [self readOptionsWithPassword:nil encoding:encoding];
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
