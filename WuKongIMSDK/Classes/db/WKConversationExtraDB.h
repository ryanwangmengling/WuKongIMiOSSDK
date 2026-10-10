//
//  WKConversationExtraDB.h
//  WuKongIMSDK
//
//  Created by tt on 2022/4/23.
//

#import <Foundation/Foundation.h>
#import "WKConversationExtra.h"
NS_ASSUME_NONNULL_BEGIN

@interface WKConversationExtraDB : NSObject

+ (WKConversationExtraDB *)shared;

/// 最近会话扩展批量入库。返回 YES 表示整批成功；任一条失败会整批回滚并返回 NO（Round 33）
-(BOOL) addOrUpdates:(NSArray<WKConversationExtra*>*)extras;

-(void) updateVersion:(WKChannel*)channel version:(int64_t)version;

-(int64_t) getMaxVersion;


@end

NS_ASSUME_NONNULL_END
