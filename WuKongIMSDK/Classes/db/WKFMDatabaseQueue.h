//
//  WKFMDatabaseQueue.h
//  WuKongIMSDK
//
//  Created by tt on 2021/8/26.
//

#import <fmdb/FMDB.h>

NS_ASSUME_NONNULL_BEGIN

@interface WKFMDatabaseQueue : NSObject


+(WKFMDatabaseQueue*) databaseQueue:(FMDatabaseQueue*)queue;


- (void)inDatabase:(void (NS_NOESCAPE^)(FMDatabase * _Nonnull db))block;

- (void)inTransaction:(__attribute__((noescape)) void (^)(FMDatabase *db, BOOL *rollback))block;

-(void) close;

/**
 队列是否可用：未关闭且内部 FMDatabaseQueue 创建成功。

 对应 Android 6d9d6ad：getDb() == null 时直接返回，不在空连接上执行事务。
 */
- (BOOL)isReady;

@end

NS_ASSUME_NONNULL_END
