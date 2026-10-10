//
//  WKSecurityManager.m
//  WuKongIMSDK
//
//  Created by tt on 2021/2/24.
//

#import "WKSecurityManager.h"
#import "Curve25519.h"
#import<CommonCrypto/CommonDigest.h>
#import "WKAESUtil.h"
@interface WKSecurityManager ()

@property(nonatomic,strong) ECKeyPair *curve25519Key;
@property(nonatomic,copy) NSString *aesKey;
@property(nonatomic,copy) NSString *aesIV;
@end

@implementation WKSecurityManager

static WKSecurityManager *_instance;
+ (id)allocWithZone:(NSZone *)zone
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _instance = [super allocWithZone:zone];
    });
    return _instance;
}
+ (WKSecurityManager *)shared
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _instance = [[self alloc] init];
    });
    return _instance;
}

-(void) generateDHPair {
    self.curve25519Key = [Curve25519 generateKeyPair];
}

-(NSString*) getDHPubKey {
    return [self.curve25519Key.publicKey base64EncodedStringWithOptions:NSDataBase64Encoding64CharacterLineLength];
}

-(void) generateAesKey:(NSString*)pubKey salt:(NSString*)salt {
    // 服务端下发的 serverKey 可能为空/非法（非 base64、解码后非 32 字节），
    // 直接交给 Curve25519 会因 [theirPublicKey length] != 32 抛未捕获异常导致握手阶段崩溃。
    // 与 Android CryptoUtils#setServerKeyAndSalt 保持一致：非法输入直接放弃本次协商。
    NSData *pubKeyData = [[NSData alloc] initWithBase64EncodedString:pubKey?:@"" options:NSDataBase64DecodingIgnoreUnknownCharacters];
    if(!self.curve25519Key || pubKeyData.length != 32) {
        NSLog(@"warn: 服务端 DH 公钥非法(pubKey=%@, 解码后 %lu 字节)，跳过本次密钥协商", pubKey?:@"", (unsigned long)pubKeyData.length);
        self.sharedKey = nil;
        self.aesKey = nil;
        self.aesIV = nil;
        return;
    }
    NSData *sharedKeyData = [Curve25519 generateSharedSecretFromPublicKey:pubKeyData andKeyPair:self.curve25519Key];
    if(!sharedKeyData) {
        NSLog(@"warn: DH 共享密钥计算失败，跳过本次密钥协商");
        self.sharedKey = nil;
        self.aesKey = nil;
        self.aesIV = nil;
        return;
    }
    
    self.sharedKey =  [sharedKeyData base64EncodedStringWithOptions:NSDataBase64Encoding64CharacterLineLength];
    
    NSString *aesKeyFull = [self md5:self.sharedKey];
    // 防止 aesKeyFull 为 nil 或长度不足时 substringToIndex:16 越界崩溃
    if(!aesKeyFull || aesKeyFull.length < 16) {
        NSLog(@"warn: 派生 AES key 长度不足(md5=%@)，跳过本次密钥协商", aesKeyFull?:@"");
        self.aesKey = nil;
        self.aesIV = nil;
        return;
    }
    self.aesKey = [aesKeyFull substringToIndex:16];
    
    if(salt && salt.length>16) {
        self.aesIV = [salt substringToIndex:16];
    }else{
        self.aesIV = salt;
    }
}


- (NSString *)md5:(NSString *)input{
    // 防御：nil/空串会让 UTF8String 返回 NULL，strlen(NULL) 直接段错误
    if(!input || input.length == 0) {
        return nil;
    }
    const char *cStr = [input UTF8String];
    unsigned char digest[CC_MD5_DIGEST_LENGTH];

    CC_MD5( cStr, (CC_LONG)strlen(cStr), digest ); // This is the md5 call

    NSMutableString *output = [NSMutableString stringWithCapacity:CC_MD5_DIGEST_LENGTH * 2];
    for(int i = 0; i < CC_MD5_DIGEST_LENGTH; i++)
           [output appendFormat:@"%02x", digest[i]];
    
    return output;
}

-(BOOL) isAesKeyReady {
    return self.aesKey.length > 0;
}

-(NSString*) encryption:(NSString*)data {
    return [WKAESUtil aesEncrypt:data key:self.aesKey iv:self.aesIV];
}

-(NSString*) decryption:(NSString*)data {
    return [WKAESUtil aesDecrypt:data key:self.aesKey iv:self.aesIV];
}

@end
