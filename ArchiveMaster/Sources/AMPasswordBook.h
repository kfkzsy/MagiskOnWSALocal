#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Saved extraction passwords ("密码本"), tried automatically when an archive is encrypted.
/// Stored in the Keychain; falls back to app preferences when the signing setup gives no Keychain access.
@interface AMPasswordBook : NSObject
+ (NSArray<NSString *> *)passwords;
+ (void)addPassword:(NSString *)password;
+ (void)removePassword:(NSString *)password;
+ (void)setPasswords:(NSArray<NSString *> *)passwords;
@end

NS_ASSUME_NONNULL_END
