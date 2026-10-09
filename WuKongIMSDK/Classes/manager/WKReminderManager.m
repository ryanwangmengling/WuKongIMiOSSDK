//
//  WKReminderManager.m
//  WuKongIMSDK
//
//  Created by tt on 2022/4/19.
//

#import "WKReminderManager.h"
#import "WKReminderDB.h"
#import "WKConversationDB.h"
#import "WKSDK.h"
#import "WKRetryManager.h"
#import "WKConversationManagerInner.h"
#import "WKMemoryCache.h"
@interface WKReminderManager ()

/**
 *  用来存储所有添加j过的delegate
 *  NSHashTable 与 NSMutableSet相似，但NSHashTable可以持有元素的弱引用，而且在对象被销毁后能正确地将其移除。
 */
@property (strong, nonatomic) NSHashTable  *delegates;
/**
 *  delegateLock 用于给delegate的操作加锁，防止多线程同时调用
 */
@property (strong, nonatomic) NSLock  *delegateLock;

/**
 *  提醒项内存缓存（key = channelId_channelType_type）
 *  移植 Android e91952f：UI 层在主线程频繁调用 getReminders:channel:，
 *  每次都会走一遍 SQLCipher 查询，是提醒列表卡顿 / ANR 的来源。
 *  WKMemoryCache 已在 Round 9 加锁，这里直接复用。
 */
@property (strong, nonatomic) WKMemoryCache *reminderCache;

@end

@implementation WKReminderManager


static WKReminderManager *_instance;
+ (id)allocWithZone:(NSZone *)zone
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _instance = [super allocWithZone:zone];
    });
    return _instance;
}
+ (WKReminderManager *)shared
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _instance = [[self alloc] init];
    });
    return _instance;
}

- (WKMemoryCache *)reminderCache {
    @synchronized (self) {
        if(!_reminderCache) {
            _reminderCache = [[WKMemoryCache alloc] init];
            _reminderCache.maxCacheNum = 2000;
        }
    }
    return _reminderCache;
}

// 缓存 key：频道 + 提醒类型（类型不同查询结果不同，必须分开存）
-(NSString*) cacheKeyForChannel:(WKChannel*)channel type:(WKReminderType)type {
    return [NSString stringWithFormat:@"%@_%d_%lu",channel.channelId,channel.channelType,(unsigned long)type];
}

// 提醒项发生变化后按 (频道,类型) 精确失效，避免下一次读到旧数据
-(void) invalidateCacheForReminders:(NSArray<WKReminder*>*)reminders {
    if(!reminders || reminders.count == 0) {
        return;
    }
    for (WKReminder *reminder in reminders) {
        if(!reminder.channel) {
            continue;
        }
        [self.reminderCache setCache:nil forKey:[self cacheKeyForChannel:reminder.channel type:reminder.type]];
    }
}

// 清空提醒项内存缓存（退出登录 / 切换账号时必须调用，防止脏数据跨账号）
-(void) clearCache {
    [self.reminderCache removeAll];
}

-(NSArray<WKReminder*>*) getReminders:(WKReminderType)reminderType channel:(WKChannel*)channel {
    if(!channel) {
        return @[];
    }
    NSString *key = [self cacheKeyForChannel:channel type:reminderType];
    NSArray<WKReminder*> *cached = [self.reminderCache getCache:key];
    if(cached) { // 命中缓存
        return cached;
    }
    NSArray<WKReminder*> *reminders = [[WKReminderDB shared] getWaitDoneReminders:channel type:reminderType];
    if(reminders) {
        // 存副本，避免调用方（或缓存内部淘汰）与返回值互相影响
        [self.reminderCache setCache:[reminders copy] forKey:key];
    }
    return reminders;
}

-(void) sync {
    if(!self.reminderProvider) {
        NSLog(@"##########reminderProvider没有提供##########");
        return;
    }
    __weak typeof(self) weakSelf = self;
    self.reminderProvider(^(NSArray<WKReminder *> * _Nonnull reminders, NSError * _Nullable error) {
        if(error) {
            NSLog(@"同步提醒项失败！->%@",error);
            return;
        }
        if(!reminders ||reminders.count == 0) {
            return;
        }
        NSMutableSet *sets = [[NSMutableSet alloc] init];
        for (WKReminder *reminder in reminders) {
            [sets addObject:reminder.channel];
        }
        [[WKReminderDB shared] addOrUpdates:reminders];
        [weakSelf invalidateCacheForReminders:reminders];
        [weakSelf updateConversations:sets];
        
    });
}

-(void) done:(NSArray<NSNumber*>*)ids {
    if(!ids || ids.count==0) {
        return;
    }
    if(!self.reminderDoneProvider) {
        NSLog(@"##########reminderDoneProvider没有提供##########");
        return;
    }
    
    NSArray<WKReminder*> *reminders = [[WKReminderDB shared] getReminders:ids];
    if(!reminders || reminders.count == 0) {
        return;
    }
    
    [[WKReminderDB shared] updateDone:ids];
    [self invalidateCacheForReminders:reminders];
    NSMutableSet *sets = [[NSMutableSet alloc] init];
    for (WKReminder *reminder in reminders) {
        [sets addObject:reminder.channel];
        [[WKRetryManager shared] addReminder:reminder];
    }
    [self updateConversations:sets];
    
    self.reminderDoneProvider(ids, ^(NSError * _Nullable error) {
        if(!error) {
            for (NSNumber *idI in ids) {
                NSString *key = idI.stringValue;
                [[WKRetryManager shared] removeReminderRetryItem:key];
            }
        }
    });
    
}

-(void) updateConversations:(NSSet<WKChannel*>*)channels {
    NSMutableArray *channelArray = [NSMutableArray array];
    for (WKChannel *channel in channels) {
        [channelArray addObject:channel];
    }
    NSDictionary<WKChannel*,NSArray<WKReminder*>*> *reminderDict = [[WKReminderDB shared] getWaitDoneReminders:channelArray];
    if(!reminderDict) {
        reminderDict = [NSMutableDictionary dictionary];
    }
   
    NSArray<WKConversation*> *conversations = [[WKConversationDB shared] getConversations:channelArray];
    if(!conversations||conversations.count ==0) {
        return;
    }
    for (WKConversation *conversation in conversations) {
        conversation.reminders = reminderDict[conversation.channel];
        [self callRemindersDidChangeDelegate:conversation.channel reminders:conversation.reminders];
    }
    [[WKSDK shared].conversationManager callOnConversationUpdateDelegates:conversations];
    
    
    
}


- (NSLock *)delegateLock {
    @synchronized (self) {
        if (_delegateLock == nil) {
            _delegateLock = [[NSLock alloc] init];
        }
    }
    return _delegateLock;
}

-(NSHashTable*) delegates {
    @synchronized (self) {
        if (_delegates == nil) {
            _delegates = [NSHashTable hashTableWithOptions:NSPointerFunctionsWeakMemory];
        }
    }
    return _delegates;
}



-(void) addDelegate:(id<WKReminderManagerDelegate>) delegate{
    [self.delegateLock lock];//防止多线程同时调用
    [self.delegates addObject:delegate];
    [self.delegateLock unlock];
}
- (void)removeDelegate:(id<WKReminderManagerDelegate>) delegate {
    [self.delegateLock lock];//防止多线程同时调用
    [self.delegates removeObject:delegate];
    [self.delegateLock unlock];
}

- (void)callRemindersDidChangeDelegate:(WKChannel*)channel reminders:(NSArray<WKReminder*>*) reminders {
    [self.delegateLock lock];
    NSHashTable *copyDelegates =  [self.delegates copy];
    [self.delegateLock unlock];
    for (id delegate in copyDelegates) {//遍历delegates ，call delegate
        if(!delegate) {
            continue;
        }
        if ([delegate respondsToSelector:@selector(reminderManager:didChange:reminders:)]) {
            if (![NSThread isMainThread]) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [delegate reminderManager:self didChange:channel reminders:reminders];
                });
            }else {
                [delegate reminderManager:self didChange:channel reminders:reminders];
            }
        }
    }
}

@end
