//
//  WKReceiptManager.m
//  WuKongIMSDK
// 消息已读回执管理
//  Created by tt on 2021/4/9.
//

#import "WKReceiptManager.h"
#import "WKSDK.h"
#import "WKMessageDB.h"
@interface WKReceiptManager ()

@property(nonatomic,strong) NSMutableDictionary<WKChannel*,NSMutableSet<WKMessage*>*> *cacheDict;
@property(nonatomic,strong) NSLock *cachedLock;

@property(nonatomic,strong) NSTimer *flushTimer;

// 私有方法前置声明（Round 17）
-(void) setupFlushTimer;
-(void) removeCacheMessages:(WKChannel*)channel messages:(NSArray<WKMessage*>*)messages;

@end
@implementation WKReceiptManager


static WKReceiptManager *_instance;
+ (id)allocWithZone:(NSZone *)zone
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _instance = [super allocWithZone:zone];
    });
    return _instance;
}
+ (WKReceiptManager *)shared
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _instance = [[self alloc] init];
        [_instance setup];
    });
    return _instance;
}

-(void) setup {
    // 修复（Round 17）：NSTimer scheduledTimerWithTimeInterval 依赖调用线程的 runloop。+shared 可能被
    // App 在任意线程首次访问（SDK 内部也会经 WKSDK.receiptManager 惰性创建），若首次访问不在主线程，
    // 定时器会被挂到该线程（无 runloop 时永不触发）甚至创建失败。统一派发到主线程创建。
    if([NSThread isMainThread]) {
        [self setupFlushTimer];
    }else {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self setupFlushTimer];
        });
    }
}

// 只在主线程调用
-(void) setupFlushTimer {
    if(self.flushTimer) {
        if(self.flushTimer.isValid) {
            return; // 已有有效定时器，避免重复创建（多次 setup / 重连）
        }
        [self.flushTimer invalidate];
        self.flushTimer = nil;
    }
    self.flushTimer = [NSTimer scheduledTimerWithTimeInterval:[WKSDK shared].options.receiptFlushInterval target:self selector:@selector(flushLoop) userInfo:nil repeats:YES];
}

-(void) addReceiptMessages:(WKChannel*)channel messages:(NSArray<WKMessage*>*)messages {
    if(!channel || messages.count == 0) {
        return;
    }
    [self.cachedLock lock];
    NSMutableSet *messagesSets = [self.cacheDict objectForKey:channel];
    if(!messagesSets) {
        messagesSets = [[NSMutableSet alloc] init];
    }
    for (WKMessage *message in messages) {
        if(!message.remoteExtra.readed) {
            [messagesSets addObject:message];
        }
    }
    // 修复（Round 17）：原实现无条件 setObject:，即使没有任何需要上报的消息也会给频道建一个空集合，
    // 导致 cacheDict 键随频道数无上限增长、flushLoop 反复对空频道调用 flush:。改为仅在确有消息时写入。
    if(messagesSets.count>0) {
        [self.cacheDict setObject:messagesSets forKey:channel];
    }
    [self.cachedLock unlock];
}

-(void) flushLoop {
    if(![WKSDK shared].options.hasLogin) {
        return;
    }
    // 修复（Round 17）：原来直接遍历 cacheDict.allKeys，与 addReceiptMessages: 的写入并发时，
    // NSMutableDictionary 枚举中变更可能崩溃；先加锁取键快照再遍历。
    [self.cachedLock lock];
    NSArray<WKChannel*> *channels = self.cacheDict.allKeys;
    [self.cachedLock unlock];
    for (WKChannel *channel in channels) {
        [self flush:channel complete:^(NSError * _Nonnull error) {
            if(error!=nil) {
                NSLog(@"flush已读数据失败！->%@",error.domain);
            }
        }];
    }
}

-(void) flush:(WKChannel*)channel complete:(void(^)(NSError *error))complete {
    if(!self.messageReadedProvider) {
        NSLog(@"warn:没有设置消息已读提供者[[WKSDK shared].receiptManager setMessageReadedProvider]！不能操作fush");
        if(complete) {
            complete(nil);
        }
        return;
    }
    NSMutableArray *tmpMessages = [NSMutableArray array];
    [self.cachedLock lock];
    NSMutableSet *cacheMessages =[self.cacheDict objectForKey:channel];
    if(cacheMessages && cacheMessages.count>0) {
        for (WKMessage *message in cacheMessages) {
            [tmpMessages addObject:message];
        }
    }
    [self.cachedLock unlock];
    if(tmpMessages.count<=0) {
        if(complete) {
            complete(nil);
        }
        return;
    }
    
    __weak typeof(self) weakSelf = self;
    self.messageReadedProvider(channel,tmpMessages, ^(NSError * _Nullable error) {
        [weakSelf removeCacheMessages:(WKChannel*)channel messages:tmpMessages];
        if(tmpMessages && tmpMessages.count>0) {
            for (WKMessage *message in tmpMessages) {
                message.remoteExtra.readed = YES;
            }
        }
        if(complete) {
            complete(error);
        }
    });
}

// 移除本次已成功上报的缓存消息（按对象精确移除）
//
// 修复（Round 17）：原实现按「长度」移除缓存中最前面的 N 条（removeCacheWithLength:len:）。若在
// messageReadedProvider 异步回调返回前 App 又调用 addReceiptMessages: 追加了新消息，新消息会被
// 误当成已上报消息移除，导致这些新消息永远不上报（已读回执丢失）。改为精确移除本次实际上报的那批对象。
-(void) removeCacheMessages:(WKChannel*)channel messages:(NSArray<WKMessage*>*)messages {
    if(!channel || messages.count == 0) {
        return;
    }
    [self.cachedLock lock];
    NSMutableSet *cacheMessages = [self.cacheDict objectForKey:channel];
    if(cacheMessages && cacheMessages.count>0) {
        for (WKMessage *message in messages) {
            [cacheMessages removeObject:message];
        }
        if(cacheMessages.count == 0) {
            [self.cacheDict removeObjectForKey:channel]; // 空集合不再占用键
        }
    }
    [self.cachedLock unlock];
}


- (NSLock *)cachedLock {
    // 防并发首次初始化出多个实例（Round 12 普查，对应 Android 2585602）
    @synchronized (self) {
        if(!_cachedLock) {
            _cachedLock = [[NSLock alloc] init];
        }
        return _cachedLock;
    }
}

- (NSMutableDictionary<WKChannel *,NSMutableSet<WKMessage *> *> *)cacheDict {
    // 防并发首次初始化出多个实例（Round 12 普查，对应 Android 2585602）
    @synchronized (self) {
        if(!_cacheDict) {
            _cacheDict = [NSMutableDictionary dictionary];
        }
        return _cacheDict;
    }
}

@end
