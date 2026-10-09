//
//  WKCache.m
//  WuKongIMBase
//
//  Created by tt on 2020/1/11.
//

#import "WKMemoryCache.h"

@interface WKMemoryCache ()
@property(nonatomic,strong) NSMutableDictionary<NSString*,id> *cacheDictonary;
@property(nonatomic,strong) NSMutableArray<NSString*> *cacheArray;
// 串行化缓存读写：NSMutableDictionary / NSMutableArray 非线程安全，
// 而频道的成员缓存会被主线程、socket 队列、DB 回调、App 线程并发访问。
// 用可重入锁，setCache: 内部会再调用 cleanCache。
@property(nonatomic,strong) NSRecursiveLock *lock;

@end

@implementation WKMemoryCache

- (NSRecursiveLock *)lock {
    if(!_lock) {
        _lock = [[NSRecursiveLock alloc] init];
    }
    return _lock;
}

-(void) setCache:(id)value forKey:(NSString*)key {
    if(!key) {
        return;
    }
    [self.lock lock];
    if(value) {
        self.cacheDictonary[key] = value;
    }else {
        [self.cacheDictonary removeObjectForKey:key];
    }
    
    [self.cacheArray addObject:key];
    
    [self cleanCacheLocked];
    [self.lock unlock];
}
-(id) getCache:(NSString*)key {
    if(!key) {
        return nil;
    }
    [self.lock lock];
    id value = self.cacheDictonary[key];
    [self.lock unlock];
    return value;
}
// 清理缓存（对外入口，自行加锁）
-(void) cleanCache {
    [self.lock lock];
    [self cleanCacheLocked];
    [self.lock unlock];
}
// 清理缓存（调用方需已持有 lock）
-(void) cleanCacheLocked {
    if(self.maxCacheNum>0) {
        if(self.cacheArray.count>self.maxCacheNum) {
            NSInteger cleanCount = self.maxCacheNum/2;
            for (int i=0;i<cleanCount;i++) {
                if(i<self.cacheArray.count) {
                    NSString *key = self.cacheArray[i];
                    [self.cacheDictonary removeObjectForKey:key];
                    [self.cacheArray removeObject:key];
                }
            }
        }
    }
}

-(NSMutableArray*) cacheArray {
    if(!_cacheArray) {
        _cacheArray = [NSMutableArray array];
    }
    return _cacheArray;
}

-(NSMutableDictionary*) cacheDictonary {
    if(!_cacheDictonary) {
        _cacheDictonary = [[NSMutableDictionary alloc] init];
    }
    return _cacheDictonary;
}

@end
