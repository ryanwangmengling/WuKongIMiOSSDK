//
//  WKNetworkMonitor.h
//  WuKongIMSDK
//
//  网络可达性监听。移植自 Android 的 NetworkChecker。
//  使用 SystemConfiguration 的 SCNetworkReachability，兼容 iOS 11（NWPathMonitor 需要 iOS 12+）。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 网络状态发生变化的通知。userInfo[@"available"] = @(BOOL)
FOUNDATION_EXPORT NSString * const WKNetworkStatusDidChangeNotification;

@interface WKNetworkMonitor : NSObject

+ (instancetype)shared;

/// 当前是否有可用网络（默认 YES，启动后由真实探测结果覆盖）
@property(nonatomic,assign,readonly) BOOL isNetworkAvailable;

/// 开始监听（幂等）
- (void)start;

/// 停止监听
- (void)stop;

/// 网络状态变化回调，主线程执行。available = 当前是否有网
@property(nonatomic,copy,nullable) void(^networkStatusChange)(BOOL available);

@end

NS_ASSUME_NONNULL_END
