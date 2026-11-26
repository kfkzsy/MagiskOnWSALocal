#import "AMPasswordBook.h"
#import <Security/Security.h>

static NSString *const kService = @"ArchiveMaster.PasswordBook";
static NSString *const kAccount = @"passwords";
static NSString *const kFallbackKey = @"AMPasswordBookFallback";

@implementation AMPasswordBook

+ (NSDictionary *)baseQuery {
    return @{
        (id)kSecClass : (id)kSecClassGenericPassword,
        (id)kSecAttrService : kService,
        (id)kSecAttrAccount : kAccount,
    };
}

+ (NSArray<NSString *> *)passwords {
    NSMutableDictionary *q = [self.baseQuery mutableCopy];
    q[(id)kSecReturnData] = @YES;
    q[(id)kSecMatchLimit] = (id)kSecMatchLimitOne;
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)q, &result);
    if (status == errSecSuccess && result) {
        NSData *data = CFBridgingRelease(result);
        NSArray *list = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if ([list isKindOfClass:NSArray.class]) return list;
    }
    NSArray *fallback = [NSUserDefaults.standardUserDefaults arrayForKey:kFallbackKey];
    return fallback ?: @[];
}

+ (void)setPasswords:(NSArray<NSString *> *)passwords {
    NSData *data = [NSJSONSerialization dataWithJSONObject:passwords options:0 error:nil];
    NSDictionary *q = self.baseQuery;
    OSStatus status = SecItemUpdate((__bridge CFDictionaryRef)q, (__bridge CFDictionaryRef) @{ (id)kSecValueData : data });
    if (status == errSecItemNotFound) {
        NSMutableDictionary *add = [q mutableCopy];
        add[(id)kSecValueData] = data;
        add[(id)kSecAttrAccessible] = (id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
        status = SecItemAdd((__bridge CFDictionaryRef)add, NULL);
    }
    if (status == errSecSuccess) {
        [NSUserDefaults.standardUserDefaults removeObjectForKey:kFallbackKey];
    } else {
        [NSUserDefaults.standardUserDefaults setObject:passwords forKey:kFallbackKey];
    }
}

+ (void)addPassword:(NSString *)password {
    if (password.length == 0) return;
    NSMutableArray *list = [self.passwords mutableCopy];
    [list removeObject:password];
    [list insertObject:password atIndex:0];  // most recent first: tried first next time
    [self setPasswords:list];
}

+ (void)removePassword:(NSString *)password {
    NSMutableArray *list = [self.passwords mutableCopy];
    [list removeObject:password];
    [self setPasswords:list];
}

@end
