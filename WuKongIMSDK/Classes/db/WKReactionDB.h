//
//  WKReactionDB.h
//  WuKongIMSDK
//
//  Created by tt on 2021/9/13.
//

#import <Foundation/Foundation.h>
#import <fmdb/FMDB.h>
#import "WKReaction.h"

NS_ASSUME_NONNULL_BEGIN

@interface WKReactionDB : NSObject

+ (WKReactionDB *)shared;


/**
 获取某个消息的回应
 */
-(NSArray<WKReaction*>*) getReactions:(NSArray<NSNumber*>*) messageIDs;

/**
  获取以消息ID为key 回应集合为值的字典
 */
-(  NSDictionary<NSString*,NSArray<WKReaction*>*> *) getReactionDictionary:(NSArray<NSNumber*>*) messageIDs;


/**
 插入回应。返回 YES 表示整批成功；任一条失败会整批回滚并返回 NO（调用方应据此决定是否对外通知）
 */
-(BOOL) insertOrUpdateReactions:(NSArray<WKReaction*>*)reactions;

/**
 在调用方事务内插入回应。返回 YES 表示全部成功；失败返回 NO 且不主动回滚外层事务
 */
-(BOOL) insertOrUpdateReactions:(NSArray<WKReaction*>*)reactions db:(FMDatabase*)db;

/**
 获取某个频道的最大版本号
 */
-(uint64_t) maxVersion:(WKChannel*) channel;

@end

NS_ASSUME_NONNULL_END
