//
//  WKFMDatabaseQueue.m
//  WuKongIMSDK
//
//  Created by tt on 2021/8/26.
//

#import "WKFMDatabaseQueue.h"
#import "WKSDK.h"
@interface WKFMDatabaseQueue ()

@property(nonatomic,strong) FMDatabaseQueue *queue;

// 关闭后置 YES：所有 DB 入口提前短路，避免在已关闭的队列/连接上继续操作导致崩溃
// （移植 Android 594ccb2 的 WKDBHelper.isClosed 防御层）
@property(atomic,assign) BOOL closed;

@end

@implementation WKFMDatabaseQueue


+(WKFMDatabaseQueue*) databaseQueue:(FMDatabaseQueue*)queue {
    WKFMDatabaseQueue *fMDatabaseQueue = [WKFMDatabaseQueue new];
    fMDatabaseQueue.queue = queue;
    return fMDatabaseQueue;
}

// 队列是否可用：未关闭且内部 FMDatabaseQueue 创建成功。
// FMDatabaseQueue 打开失败时 databaseQueueWithPath: 返回 nil（路径不可写/磁盘满/文件损坏），
// 这种“空壳”队列既没 closed 也没法执行任何语句，所有入口应直接返回
// （对应 Android 6d9d6ad 的 getDb() == null 时跳过事务）。
- (BOOL)isReady {
    return !self.closed && self.queue != nil;
}


- (void)inDatabase:(void (NS_NOESCAPE^)(FMDatabase * _Nonnull db))block {
    if(![self isReady]) { return; }
    
    if([WKSDK shared].options.traceDBLog) {
        // [NSThread callStackSymbols] 需要符号化，代价极高；仅在 debug 下采集完整调用栈，
        // release 只打印方法名（移植 Android 4151c42：非 debug 跳过 getStackTrace，修复 ANR）。
        if([WKSDK shared].isDebug) {
            NSArray *syms = [NSThread  callStackSymbols];
            if ([syms count] > 1) {
                NSLog(@"<%@ %p> %@ - caller: %@ ", [self class], self, NSStringFromSelector(_cmd),[syms objectAtIndex:1]);
                if([syms count]>2) {
                    NSLog(@"%@ - caller: %@ ", NSStringFromSelector(_cmd),[syms objectAtIndex:2]);
                }
            } else {
                 NSLog(@"<%@ %p> %@", [self class], self, NSStringFromSelector(_cmd));
            }
        } else {
            NSLog(@"<%@ %p> %@", [self class], self, NSStringFromSelector(_cmd));
        }
    }
   
    [self.queue inDatabase:^(FMDatabase *db){
        block(db);
    }];
}

- (void)inTransaction:(__attribute__((noescape)) void (^)(FMDatabase *db, BOOL *rollback))block {
    if(![self isReady]) { return; }

    if([WKSDK shared].options.traceDBLog) {
        // 同 inDatabase:，release 跳过 callStackSymbols（移植 Android 4151c42）
        if([WKSDK shared].isDebug) {
            NSArray *syms = [NSThread  callStackSymbols];
            if ([syms count] > 1) {
                NSLog(@"<%@ %p> %@ - caller: %@ ", [self class], self, NSStringFromSelector(_cmd),[syms objectAtIndex:1]);
            } else {
                 NSLog(@"<%@ %p> %@", [self class], self, NSStringFromSelector(_cmd));
            }
        } else {
            NSLog(@"<%@ %p> %@", [self class], self, NSStringFromSelector(_cmd));
        }
    }
   
    [self.queue inTransaction:^(FMDatabase * _Nonnull db, BOOL * _Nonnull rollback) {
        block(db,rollback);
    }];
}


-(void) close {
    if(self.closed) { return; }
    self.closed = YES;
    [self.queue close];
}


@end
