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
        return;
    }
    self.reachabilityRef = ref;

    SCNetworkReachabilityContext context = {0, (__bridge void *)self, NULL, NULL, NULL};
    if(SCNetworkReachabilitySetCallback(ref, WKNetworkReachabilityCallback, &context)) {
        SCNetworkReachabilitySetDispatchQueue(ref, dispatch_get_main_queue());
    }
    // 启动时立即探测一次当前状态
    SCNetworkReachabilityFlags flags;
    if(SCNetworkReachabilityGetFlags(ref, &flags)) {
        [self handleReachabilityFlags:flags];
    }
}

- (void)stop {
    if(self.reachabilityRef) {
        SCNetworkReachabilitySetDispatchQueue(self.reachabilityRef, NULL);
        SCNetworkReachabilitySetCallback(self.reachabilityRef, NULL, NULL);
        CFRelease(self.reachabilityRef);
        self.reachabilityRef = NULL;
    }
    self.started = NO;
}

- (void)handleReachabilityFlags:(SCNetworkReachabilityFlags)flags {
    BOOL available = [self reachableWithFlags:flags];
    if(available == self.isNetworkAvailable) {
        return;
    }
    self.isNetworkAvailable = available;
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
