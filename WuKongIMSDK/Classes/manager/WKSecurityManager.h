//
//  WKSecurityManager.h
//  WuKongIMSDK
//
//  Created by tt on 2021/2/24.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface WKSecurityManager : NSObject

+ (WKSecurityManager *)shared;

@property(nonatomic,copy,nullable) NSString *sharedKey; // 共享key（协商失败/未协商时为 nil）


/**
 生成DH密钥对
 */
-(void) generateDHPair;

/**
 获取DH的公钥
 */
-(NSString*) getDHPubKey;

/**
 通过其他的公钥获取共享密钥
 */
-(void) generateAesKey:(NSString*)pubKey salt:(NSString*)salt;

/**
 加密数据
 */
-(NSString*) encryption:(NSString*)data;

/**
 解密
 */
-(NSString*) decryption:(NSString*)data;

/**
 AES key 是否已就绪（DH 协商成功且长度合法）
 */
-(BOOL) isAesKeyReady;

- (NSString *)md5:(NSString *)input;

@end

NS_ASSUME_NONNULL_END
