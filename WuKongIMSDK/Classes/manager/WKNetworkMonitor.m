//
//  WKNetworkMonitor.m
//  WuKongIMSDK
//
//  移植自 Android 的 NetworkChecker。无网络时通知上层暂停重连，网络恢复时
//  通知上层立即重连（Android：网络恢复后 resetConnCount + reconnection）。
//

#import "WKNetworkMonitor.h"
#import <SystemConfiguration/SystemConfiguration.h>
#import <netinet/in.h>
#import <strings.h>

NSString * const WKNetworkStatusDidChangeNotification = @"WKNetworkStatusDidChangeNotification";

@interface WKNetworkMonitor ()

@property(nonatomic,assign) SCNetworkReachabilityRef reachabilityRef;
@property(nonatomic,assign) BOOL isNetworkAvailable;
@property(nonatomic,assign) BOOL started;

- (void)handleReachabilityFlags:(SCNetworkReachabilityFlags)flags;

@end

static void WKNetworkReachabilityCallback(SCNetworkReachabilityRef target, SCNetworkReachabilityFlags flags, void *info) {
    WKNetworkMonitor *monitor = (__bridge WKNetworkMonitor *)info;
    if(!monitor) {
        return;
    }
    [monitor handleReachabilityFlags:flags];
}

@implementation WKNetworkMonitor

+ (instancetype)shared {
    static WKNetworkMonitor *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[WKNetworkMonitor alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if(self) {
        // 默认认为有网，start 后由真实探测结果覆盖
        _isNetworkAvailable = YES;
    }
    return self;
}

- (void)start {
    // start/stop 可能从任意线程调用（connect 在调用线程执行、网络回调在主线程），
    // check-then-act 必须串行，否则会重复创建 SCNetworkReachabilityRef 并泄漏，
    // 同时把 started 置位但只保留最后一个 ref（Round 14 并发普查，对应 Android 2585602）。
    SCNetworkReachabilityFlags flags = 0;
    BOOL needProbe = NO;
    @synchronized (self) {
        if(self.started) {
            return;
        }
        self.started = YES;

        // 监听 0.0.0.0 表示「通用网络可达性」，不依赖具体主机
        struct sockaddr_in zeroAddress;
        bzero(&zeroAddress, sizeof(zeroAddress));
        zeroAddress.sin_len = sizeof(zeroAddress);
        zeroAddress.sin_family = AF_INET;
        SCNetworkReachabilityRef ref = SCNetworkReachabilityCreateWithAddress(kCFAllocatorDefault, (const struct sockaddr *)&zeroAddress);
        if(!ref) {
            // 创建失败不算已启动，下次调用可重试
            self.started = NO;
            return;
        }
        self.reachabilityRef = ref;

        SCNetworkReachabilityContext context = {0, (__bridge void *)self, NULL, NULL, NULL};
        if(SCNetworkReachabilitySetCallback(ref, WKNetworkReachabilityCallback, &context)) {
            SCNetworkReachabilitySetDispatchQueue(ref, dispatch_get_main_queue());
        }
        // 启动时立即探测一次当前状态（回调在锁外触发，避免持锁调用外部代码）
        if(SCNetworkReachabilityGetFlags(ref, &flags)) {
            needProbe = YES;
        }
    }
    if(needProbe) {
        [self handleReachabilityFlags:flags];
    }
}

- (void)stop {
    @synchronized (self) {
        if(self.reachabilityRef) {
            SCNetworkReachabilitySetDispatchQueue(self.reachabilityRef, NULL);
            SCNetworkReachabilitySetCallback(self.reachabilityRef, NULL, NULL);
            CFRelease(self.reachabilityRef);
            self.reachabilityRef = NULL;
        }
        self.started = NO;
    }
}

// 跨线程读取当前网络状态（写入在 handleReachabilityFlags 的锁内）
- (BOOL)isNetworkAvailable {
    @synchronized (self) {
        return _isNetworkAvailable;
    }
}

- (void)handleReachabilityFlags:(SCNetworkReachabilityFlags)flags {
    BOOL available = [self reachableWithFlags:flags];
    // 判断+赋值放进锁内（可达性回调在主线程、启动探测可能在任意线程）；
    // 通知在锁外执行，避免持锁调用外部回调。
    @synchronized (self) {
        if(available == _isNetworkAvailable) {
            return;
        }
        _isNetworkAvailable = available;
    }
    __weak typeof(self) weakSelf = self;
    void(^notify)(void) = ^{
        if(weakSelf.networkStatusChange) {
            weakSelf.networkStatusChange(available);
        }
        [[NSNotificationCenter defaultCenter] postNotificationName:WKNetworkStatusDidChangeNotification
                                                            object:weakSelf
                                                          userInfo:@{@"available": @(available)}];
    };
    if([NSThread isMainThread]) {
        notify();
    }else {
        dispatch_async(dispatch_get_main_queue(), notify);
    }
}

- (BOOL)reachableWithFlags:(SCNetworkReachabilityFlags)flags {
    BOOL reachable = (flags & kSCNetworkReachabilityFlagsReachable) != 0;
    if(!reachable) {
        return NO;
    }
    // 需要先建立连接（例如需要唤醒 VPN / 蜂窝数据）时视为不可用
    if((flags & kSCNetworkReachabilityFlagsConnectionRequired) != 0) {
        return NO;
    }
#if TARGET_OS_IPHONE
    // 需要用户手动干预（例如 Wi-Fi 登录页）时视为不可用
    if((flags & kSCNetworkReachabilityFlagsInterventionRequired) != 0) {
        return NO;
    }
#endif
    return YES;
}

- (void)dealloc {
    [self stop];
}

@end
