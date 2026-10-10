//
//  WKChannelRequestQueue.m
//  WuKongIMSDK
//
//  Created by tt on 2021/4/22.
//

#import "WKChannelRequestQueue.h"
#import "WKSDK.h"

typedef enum : NSUInteger {
    Wait,
    Success,
    Error,
    Cancel,
} WKRequestStatus;

typedef void(^WKChannelRequestComplete)(NSError * _Nullable error, BOOL notifyBefore);

@interface WKChannelRequest : NSObject

@property(nonatomic,strong) WKChannel *channel;
@property(nonatomic,strong) WKTaskOperator *operator;
@property(nonatomic,assign) WKRequestStatus status;
// 同一频道的请求可能被多个调用方（例如大量 cell）同时发起，这里收集全部回调，
// 结果返回时一并回调，避免后到者的 complete 被丢弃（Round 19）。
@property(nonatomic,strong) NSMutableArray<WKChannelRequestComplete> *completes;

-(void) cancel;

@end

@implementation WKChannelRequest

-(void) cancel {
    [self.operator cancel];
    self.status = Cancel;
}

@end

@interface WKChannelRequestQueue ()

@property(nonatomic,strong) NSMutableArray<WKChannelRequest*> *requests;

@property(nonatomic,strong) NSMutableDictionary<NSString*,WKChannelRequest*> *requestDict;

@property(nonatomic,strong) NSRecursiveLock *lock; // 递归锁可被同一线程多次获取


@end

@implementation WKChannelRequestQueue


static WKChannelRequestQueue *_instance;
+ (id)allocWithZone:(NSZone *)zone
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _instance = [super allocWithZone:zone];
    });
    return _instance;
}
+ (WKChannelRequestQueue *)shared
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _instance = [[self alloc] init];
    });
    return _instance;
}

-(NSString*) getChannelKey:(WKChannel*)channel {
    return [NSString stringWithFormat:@"%@-%d",channel.channelId,channel.channelType];
}

// 回调一个「已从队列移除」的请求的全部待回调 block。
// 必须在锁外执行，避免在锁内执行 App 代码（Round 19）。
-(void) notifyCompletes:(WKChannelRequest*)request error:(NSError*)error {
    NSArray<WKChannelRequestComplete> *completes = nil;
    [self.lock lock];
    completes = [request.completes copy];
    [request.completes removeAllObjects];
    [self.lock unlock];
    for (WKChannelRequestComplete complete in completes) {
        complete(error, NO);
    }
}

-(void) addRequest:(WKChannel*)channel complete:(void(^)(NSError *error,bool notifyBefore))complete{
    if(!channel) {
        if(complete) {
            complete([NSError errorWithDomain:@"频道为空" code:0 userInfo:nil], NO);
        }
        return;
    }
    NSString *key = [self getChannelKey:channel];
    WKChannelRequest *evictedRequest = nil;

    [self.lock lock];
    WKChannelRequest *request = [self.requestDict objectForKey:key];
    if(request && request.status == Wait) {
        // 同频道已有进行中的请求：本次回调挂到同一批，等结果一并回调；
        // 同时把它提到队首，避免刚发起就被 channelRequestMaxLimit 淘汰（Round 19）。
        if(complete) {
            [request.completes addObject:[complete copy]];
        }
        NSInteger index = [self.requests indexOfObject:request];
        if(index != NSNotFound && index != 0) {
            [self.requests removeObjectAtIndex:index];
            [self.requests insertObject:request atIndex:0];
        }
        [self.lock unlock];
        return;
    }
    if(request) {
        // 防御：理论上前述回调已把完成的请求移除，这里清理任何残留，避免同频道请求永久失效
        [self.requests removeObject:request];
        [self.requestDict removeObjectForKey:key];
    }

    request = [WKChannelRequest new];
    request.channel = channel;
    request.status = Wait;
    request.completes = [NSMutableArray array];
    if(complete) {
        [request.completes addObject:[complete copy]];
    }
    [self.requestDict setObject:request forKey:key];
    [self.requests insertObject:request atIndex:0];

    if(self.requests.count>[WKSDK shared].options.channelRequestMaxLimit) {
        WKChannelRequest *last = [self.requests lastObject];
        if(last && last != request) {
            [self.requests removeObject:last];
            [self.requestDict removeObjectForKey:[self getChannelKey:last.channel]];
            last.status = Cancel;
            evictedRequest = last;

            NSLog(@"移除频道请求！->%@",[self getChannelKey:last.channel]);
        }
    }
    [self.lock unlock];

    if(evictedRequest) {
        // 被淘汰的请求也要回调，否则调用方会一直等待（Round 19）
        [self notifyCompletes:evictedRequest error:[NSError errorWithDomain:@"频道请求过多，已被取消" code:0 userInfo:nil]];
        [evictedRequest.operator cancel];
    }

    // 在锁外调用提供者：提供者可能同步回调，若在锁内会以用户代码重入锁（Round 19）
    request.operator = [self createOperator:request key:key];
}

-(WKTaskOperator*) createOperator:(WKChannelRequest*)request key:(NSString*)key {
    __weak typeof(self) weakSelf = self;
    return [WKSDK shared].channelInfoUpdate(request.channel, ^(NSError * _Nullable error,bool notifyBefore) {
        __strong typeof(self) strongSelf = weakSelf;
        if(!strongSelf) {
            return;
        }
        [strongSelf handleCallback:request key:key error:error notifyBefore:notifyBefore];
    });
}

-(void) handleCallback:(WKChannelRequest*)request key:(NSString*)key error:(NSError*)error notifyBefore:(BOOL)notifyBefore {
    if(notifyBefore) {
        // 中间结果（例如本地缓存）：只回调当前已挂上的调用方，请求仍在进行中
        NSArray<WKChannelRequestComplete> *completes = nil;
        [self.lock lock];
        if([self.requestDict objectForKey:key] == request) {
            completes = [request.completes copy];
        }
        [self.lock unlock];
        for (WKChannelRequestComplete complete in completes) {
            complete(nil, YES);
        }
        return;
    }
    // 最终结果：先从队列移除，再回调。
    // 回调里若再次请求同频道会重新发起，不会被误判为进行中（Round 19 核心修复）。
    NSArray<WKChannelRequestComplete> *completes = nil;
    [self.lock lock];
    if([self.requestDict objectForKey:key] == request) {
        [self.requests removeObject:request];
        [self.requestDict removeObjectForKey:key];
        request.status = error?Error:Success;
        completes = [request.completes copy];
        [request.completes removeAllObjects];
    }
    [self.lock unlock];
    for (WKChannelRequestComplete complete in completes) {
        complete(error, notifyBefore);
    }
}

-(void) cancelRequest:(WKChannel*)channel {
    WKChannelRequest *request = nil;
    NSArray<WKChannelRequestComplete> *completes = nil;
    [self.lock lock];
    NSString *key = [self getChannelKey:channel];
    request = [self.requestDict objectForKey:key];
    if(request) {
        [self.requests removeObject:request];
        [self.requestDict removeObjectForKey:key];
        request.status = Cancel;
        completes = [request.completes copy];
        [request.completes removeAllObjects];
    }
    [self.lock unlock];
    if(request) {
        [request.operator cancel];
        // 取消也要回调，否则调用方会一直等待（Round 19）
        for (WKChannelRequestComplete complete in completes) {
            complete([NSError errorWithDomain:@"频道信息请求已被取消" code:0 userInfo:nil], NO);
        }
    }
}


- (NSMutableArray<WKChannelRequest *> *)requests {
    // 防并发首次初始化出多个实例（Round 12 普查，对应 Android 2585602）
    @synchronized (self) {
        if(!_requests) {
            _requests = [NSMutableArray array];
        }
        return _requests;
    }
}

- (NSMutableDictionary *)requestDict {
    // 防并发首次初始化出多个实例（Round 12 普查，对应 Android 2585602）
    @synchronized (self) {
        if(!_requestDict) {
            _requestDict = [NSMutableDictionary dictionary];
        }
        return _requestDict;
    }
}

- (NSRecursiveLock *)lock {
    // 防并发首次初始化出多个实例（Round 12 普查，对应 Android 2585602）
    @synchronized (self) {
        if(!_lock) {
            _lock = [[NSRecursiveLock alloc] init];
        }
        return _lock;
    }
}


@end
