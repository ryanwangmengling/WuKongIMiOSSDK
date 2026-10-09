//
//  WKBaseTask.m
//  WuKongIMSDK
//
//  Created by tt on 2020/1/16.
//

#import "WKBaseTask.h"

@interface WKBaseTask ()

@property(nonatomic,strong) NSMutableDictionary<NSString*,WKTaskListener> *listenerDic;


@end

@implementation WKBaseTask

@synthesize listeners;

@synthesize status;

@synthesize taskId;

- (void)addListener:(nonnull WKTaskListener)listener target:(id) target {
    NSString *key  = [NSString stringWithFormat:@"%@%@",NSStringFromClass([target class]),self.taskId];
    self.listenerDic[key] = listener;
}

- (void)removeListener:(id)target {
    NSString *key  = [NSString stringWithFormat:@"%@%@",NSStringFromClass([target class]),self.taskId];
    [self.listenerDic removeObjectForKey:key];
}
- (void)cancel {
    
}

- (void)resume {
    
}

- (void)suspend {
    
}

- (NSArray<WKTaskListener> *)listeners {
    return self.listenerDic.allValues;
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

@end
