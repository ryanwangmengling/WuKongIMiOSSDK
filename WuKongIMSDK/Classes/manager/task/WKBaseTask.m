//
//  WKBaseTask.m
//  WuKongIMSDK
//
//  Created by tt on 2020/1/16.
//

#import "WKBaseTask.h"

@interface WKBaseTask ()

@property(nonatomic,strong) NSMutableDictionary<NSString*,WKTaskListener> *listenerDic;

// 监听者字典的读写锁（Round 17）
@property(nonatomic,strong) NSRecursiveLock *listenerLock;

@end

@implementation WKBaseTask

@synthesize listeners;

@synthesize status;

@synthesize taskId;

- (void)addListener:(nonnull WKTaskListener)listener target:(id) target {
    if(!listener) {
        return;
    }
    NSString *key  = [NSString stringWithFormat:@"%@%@",NSStringFromClass([target class]),self.taskId];
    // 修复（Round 17）：listenerDic 无锁。addListener: 由 WKTaskManager.add / WKMediaManager.download:
    // 在调用线程执行，removeListener: 由监听回调里的 WKTaskManager.remove: 执行，任务实现的 update
    // （App 子类通常在下载/上传回调线程调用）会读 listeners -> allValues，可能跨线程并发。
    [self.listenerLock lock];
    self.listenerDic[key] = listener;
    [self.listenerLock unlock];
}

- (void)removeListener:(id)target {
    NSString *key  = [NSString stringWithFormat:@"%@%@",NSStringFromClass([target class]),self.taskId];
    [self.listenerLock lock];
    [self.listenerDic removeObjectForKey:key];
    [self.listenerLock unlock];
}
- (void)cancel {
    
}

- (void)resume {
    
}

- (void)suspend {
    
}

- (NSArray<WKTaskListener> *)listeners {
    // 修复（Round 17）：加锁取快照，避免与 addListener:/removeListener: 并发。
    [self.listenerLock lock];
    NSArray<WKTaskListener> *values = self.listenerDic.allValues;
    [self.listenerLock unlock];
    return values;
}

-(void) update {
    if(self.listeners) {
        for (WKTaskListener listener in self.listeners) {
            listener();
        }
    }
}

- (NSMutableDictionary *)listenerDic {
    // 防并发首次初始化出多个实例（Round 12 普查，对应 Android 2585602）
    @synchronized (self) {
        if(!_listenerDic) {
            _listenerDic = [NSMutableDictionary dictionary];
        }
        return _listenerDic;
    }
}

- (NSRecursiveLock *)listenerLock {
    // 防并发首次初始化出多个实例（Round 17）
    @synchronized (self) {
        if(!_listenerLock) {
            _listenerLock = [[NSRecursiveLock alloc] init];
        }
        return _listenerLock;
    }
}

@end
