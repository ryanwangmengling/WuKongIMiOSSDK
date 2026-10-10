//
//  WKRetryManager.m
//  WuKongIMBase
// 消息重试管理
//  Created by tt on 2019/12/29.
//

#import "WKRetryManager.h"
#import "WKSDK.h"
#import "WKMessageDB.h"
#import "WKChatManager.h"
#import "WKMessageExtraDB.h"
#import "WKReminderDB.h"
@implementation WKRetryItem


@end

@interface WKRetryManager ()

@property(nonatomic,strong) NSMutableDictionary<NSString*,WKRetryItem*> *retryDict;
@property(nonatomic,strong) NSMutableDictionary<NSString*,WKRetryItem*> *messageExtraRetryDict;
@property(nonatomic,strong) NSMutableDictionary<NSString*,WKRetryItem*> *reminderRetryDict;
@property(nonatomic,strong) NSLock *retryLock;
@property(nonatomic,strong) NSTimer *retryTimer;
@property(nonatomic,strong) NSTimer *messageExtraRetryTimer;
@property(nonatomic,strong) NSTimer *reminderRetryTimer;
@property(nonatomic,strong) NSTimer *expireMsgCheckTimer;

@property(nonatomic,assign) BOOL started; // 是否已开始
// 运行代际：start/stop 自增，用于作废尚未执行的定时器创建块
// （原实现「stop 后 main-queue 里排队的 scheduledTimer 仍会执行」，会留下永不失效的 NSTimer）
@property(atomic,assign) int runGeneration;
// 过期消息检查是否正在执行（Round 16：检查已移出主线程，防重入，避免耗时超过检查间隔时并发删除同一批消息）
@property(atomic,assign) BOOL expireChecking;

@end
@implementation WKRetryManager


static WKRetryManager *_instance;
+ (id)allocWithZone:(NSZone *)zone
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _instance = [super allocWithZone:zone];
    });
    return _instance;
}
+ (WKRetryManager *)shared
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _instance = [[self alloc] init];
    });
    return _instance;
}

-(void) add:(WKMessage*)message {
    if(message.clientSeq == 0 || !message.clientMsgNo||[message.clientMsgNo isEqualToString:@""]) {
        NSLog(@"消息clientSeq为0 不能添加到重试队列里！");
        return;
    }
    NSString *key= [self getKey:message];
    
    WKRetryItem *item = [[WKRetryItem alloc] init];
    item.message = message;
    item.retryCount = 0;
    item.nextRetryTime = [[NSDate date] timeIntervalSince1970] + [WKSDK shared].options.messageRetryInterval;
    
    [self.retryLock lock];
    self.retryDict[key] = item;
    [self.retryLock unlock];
}

-(void) addMessageExtra:(WKMessageExtra*)messageExtra {
    if(!messageExtra.isEdit || messageExtra.uploadStatus != WKContentEditUploadStatusWait) {
        return;
    }
    NSString *key = [NSString stringWithFormat:@"%llu",messageExtra.messageID];
    
    WKRetryItem *item = [[WKRetryItem alloc] init];
    item.messageExtra = messageExtra;
    item.retryCount = 0;
    item.nextRetryTime = [[NSDate date] timeIntervalSince1970] + [WKSDK shared].options.messageRetryInterval;
    
    [self.retryLock lock];
    self.messageExtraRetryDict[key] = item;
    [self.retryLock unlock];
}

-(void) addReminder:(WKReminder*)reminder {
    if(reminder.uploadStatus != WKReminderUploadStatusWait) {
        return;
    }
    NSString *key = [NSString stringWithFormat:@"%lld",reminder.reminderID];
    WKRetryItem *item = [[WKRetryItem alloc] init];
    item.reminder = reminder;
    item.retryCount = 0;
    item.nextRetryTime = [[NSDate date] timeIntervalSince1970] + [WKSDK shared].options.messageRetryInterval;
    [self.retryLock lock];
    self.reminderRetryDict[key] = item;
    [self.retryLock unlock];
}

-(NSString*) getKey:(WKMessage*)message {
    NSString *key=[NSString stringWithFormat:@"%u",message.clientSeq];
    return key;
}

-(void) start {
    int generation = 0;
    @synchronized (self) { // 防并发重复 start 起两套定时器（Round 15）
        if(self.started) {
            return;
        }
        self.started = true;
        generation = ++self.runGeneration;
    }
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        typeof(self) strongSelf = weakSelf;
        if(!strongSelf || strongSelf.runGeneration != generation) {
            return;
        }
        [strongSelf startMessageRetry];
    });
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        typeof(self) strongSelf = weakSelf;
        if(!strongSelf || strongSelf.runGeneration != generation) {
            return;
        }
        [strongSelf startMessageExtraRetry];
    });
    // 原来这里重复 dispatch 了两次 startReminderRetry（第二次纯属多余，Round 15 去掉）
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        typeof(self) strongSelf = weakSelf;
        if(!strongSelf || strongSelf.runGeneration != generation) {
            return;
        }
        [strongSelf startReminderRetry];
    });
    
    // 过期消息检查定时器：原实现直接在调用线程（连接成功回调所在的 socket 队列）上 scheduledTimer，
    // dispatch 队列没有 runloop，导致该定时器实际从不触发；改为和其它定时器一样在主线程创建（Round 15）
    dispatch_async(dispatch_get_main_queue(), ^{
        typeof(self) strongSelf = weakSelf;
        if(!strongSelf || strongSelf.runGeneration != generation || !strongSelf.started) {
            return;
        }
        if(strongSelf.expireMsgCheckTimer) {
            [strongSelf.expireMsgCheckTimer invalidate];
            strongSelf.expireMsgCheckTimer = nil;
        }
        strongSelf.expireMsgCheckTimer = [NSTimer scheduledTimerWithTimeInterval:WKSDK.shared.options.expireMsgCheckInterval target:strongSelf selector:@selector(startExpireMsgCheck) userInfo:nil repeats:YES];
    });
}

-(void) stop {
    @synchronized (self) {
        self.started = false;
        self.runGeneration++; // 作废尚未执行的 start 定时器创建块
    }
    if(self.retryTimer) {
        [self.retryTimer invalidate];
        self.retryTimer = nil;
    }
    if(self.messageExtraRetryTimer) {
        [self.messageExtraRetryTimer invalidate];
        self.messageExtraRetryTimer = nil;
    }
    if(self.reminderRetryTimer) {
        [self.reminderRetryTimer invalidate];
        self.reminderRetryTimer = nil;
    }
    if(self.expireMsgCheckTimer) {
        [self.expireMsgCheckTimer invalidate];
        self.expireMsgCheckTimer = nil;
    }
}

-(void) startExpireMsgCheck {
    // Round 16：DB 查询 + 删除整段移出主线程，避免每次检查都卡 UI（延续 Android 68d3e6f「DB 操作移后台」精神）
    if(self.expireChecking) { // 防重入：一次检查可能长于 expireMsgCheckInterval
        return;
    }
    self.expireChecking = YES;
    int generation = self.runGeneration; // 代际快照：stop（登出/切换用户）后作废本次检查
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        typeof(self) strongSelf = weakSelf;
        if(!strongSelf) {
            return;
        }
        @try {
            if(strongSelf.runGeneration != generation || !strongSelf.started) {
                return;
            }
            NSArray<WKMessage*> *messages = [WKMessageDB.shared getExpireMessages:WKSDK.shared.options.expireMsgLimit];
            if(messages && messages.count>0) {
                for (WKMessage *message in messages) {
                    if(strongSelf.runGeneration != generation) { // 检查途中 stop，立即中止，避免误删新账号数据
                        break;
                    }
                    [WKSDK.shared.chatManager deleteMessage:message];
                }
            }
        } @finally {
            strongSelf.expireChecking = NO;
        }
    });
}

-(void) startMessageRetry {
    // 将上传中的消息状态变为失败
     [[WKMessageDB shared] updateMessageUploadingToFailStatus];
    
    // 将待发送的消息修改为发送失败
    [self.retryLock lock];
    [self.retryDict removeAllObjects];
     [self.retryLock unlock];
    NSArray<WKMessage*> *messages = [[WKMessageDB shared] getMessagesWaitSend];
    if(messages && messages.count>0) {
        NSInteger i =messages.count - 1;
        for (WKMessage *message in messages) {
            if(message.localTimestamp + [WKSDK shared].options.messageRetryInterval*[WKSDK shared].options.messageRetryCount > [[NSDate date] timeIntervalSince1970] ) {
//                [[WKRetryManager shared] add:message];
                 [[[WKSDK shared] chatManager] sendMessage:message addRetryQueue:true];
            }else {
                // 更新消息状态 c为失败
                 message.status =WK_MESSAGE_FAIL;
                 [[WKMessageDB shared] updateMessageStatus:WK_MESSAGE_FAIL withClientSeq:message.clientSeq];
                 // 通知上层
                 [[WKSDK shared].chatManager callMessageUpdateDelegate:message left:i total:messages.count];
            }
            i--;
        }
    }
    
    NSTimeInterval retryInterval = [WKSDK shared].options.messageRetryInterval/2.0f;
    if(retryInterval<=0) {
        retryInterval = 1.0f;
    }
    if(self.retryTimer) {
        [self.retryTimer invalidate];
        self.retryTimer = nil;
    }
    // 定时器必须在主线程才能执行
     __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(self) strongSelf = weakSelf;
        if(!strongSelf || !strongSelf.started) { // stop 之后不再新建定时器（Round 15）
            return;
        }
        strongSelf.retryTimer = [NSTimer scheduledTimerWithTimeInterval:retryInterval target:strongSelf selector:@selector(retrySend) userInfo:nil repeats:YES];
    });
   
}

-(void) startMessageExtraRetry {
    // 将上传中的消息状态变为失败
     [[WKMessageExtraDB shared] updateContentEditUploadStatusToFailStatus];
    [self.retryLock lock];
    [self.messageExtraRetryDict removeAllObjects];
    [self.retryLock unlock];
    
    NSArray<WKMessageExtra*> *messageExtras = [[WKMessageExtraDB shared] getContentEditWaitUpload];
    if(messageExtras && messageExtras.count>0) {
        for (WKMessageExtra *messageExtra in messageExtras) {
            if(messageExtra.editedAt + [WKSDK shared].options.contentEditRetryInterval*[WKSDK shared].options.contentEditRetryCount > [[NSDate date] timeIntervalSince1970] ) {
                [self addMessageExtra:messageExtra];
            }else{ // 超时
                [[WKMessageExtraDB shared] updateUploadStatus:WKContentEditUploadStatusError withMessageID:messageExtra.messageID];
                
                WKMessage *message = [[WKMessageDB shared] getMessageWithMessageId:messageExtra.messageID];
                 if(message) {
                     [[WKSDK shared].chatManager callMessageUpdateDelegate:message];
                 }
            }
        }
    }
    
    NSTimeInterval retryInterval = [WKSDK shared].options.contentEditRetryInterval/2.0f;
    if(retryInterval<=0) {
        retryInterval = 1.0f;
    }
    if(self.messageExtraRetryTimer) {
        [self.messageExtraRetryTimer invalidate];
        self.messageExtraRetryTimer = nil;
    }
    // 定时器必须在主线程才能执行
     __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(self) strongSelf = weakSelf;
        if(!strongSelf || !strongSelf.started) { // stop 之后不再新建定时器（Round 15）
            return;
        }
        strongSelf.messageExtraRetryTimer = [NSTimer scheduledTimerWithTimeInterval:retryInterval target:strongSelf selector:@selector(contentEditRetryUpload) userInfo:nil repeats:YES];
    });
}

// 提示数据上传
-(void) startReminderRetry {
    NSInteger expire =  [[NSDate date] timeIntervalSince1970] - [WKSDK shared].options.reminderDoneUploadExpire;
    [[WKReminderDB shared] updateExpireDoneUploadStatusFail:expire];
    [self.retryLock lock];
    [self.reminderRetryDict removeAllObjects];
    [self.retryLock unlock];
    
    NSArray<WKReminder*> *reminders = [[WKReminderDB shared] getWaitUploads];
    if(reminders && reminders.count>0) {
        for (WKReminder *reminder in reminders) {
            [self addReminder:reminder];
        }
    }
    NSTimeInterval retryInterval = [WKSDK shared].options.reminderRetryInterval/2.0f;
    if(retryInterval<=0) {
        retryInterval = 1.0f;
    }
    if(self.reminderRetryTimer) {
        [self.reminderRetryTimer invalidate];
        self.reminderRetryTimer = nil;
    }
    // 定时器必须在主线程才能执行
     __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(self) strongSelf = weakSelf;
        if(!strongSelf || !strongSelf.started) { // stop 之后不再新建定时器（Round 15）
            return;
        }
        strongSelf.reminderRetryTimer = [NSTimer scheduledTimerWithTimeInterval:retryInterval target:strongSelf selector:@selector(reminderUpload) userInfo:nil repeats:YES];
    });
}


-(void) reminderUpload {
    [self.retryLock lock];
    NSArray *keys = self.reminderRetryDict.allKeys;
    [self.retryLock unlock];
    
    for (NSString *key  in keys) {
        [self.retryLock lock];
        WKRetryItem *item =  self.reminderRetryDict[key];
        [self.retryLock unlock];
        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        if(!item) continue;
        // 如果重试次数小于目标重试次数并且满足重试时间，则重试
        if(item.retryCount<[WKSDK shared].options.reminderRetryCount) {
            if((now - item.nextRetryTime)>=0) {
                if([WKSDK shared].isDebug) {
                    NSLog(@"重试上传提醒项  key:[%@] retryCount: [%ld] nextRetryTime: [%ld]",key,item.retryCount,item.nextRetryTime);
                }
                item.retryCount++;
                item.nextRetryTime =now+[WKSDK shared].options.reminderRetryInterval;
                [self uploadReminder:item.reminder];
            }
        }else { // 超过重试次数 提醒项上传状态设置为失败并移出重试队列（对齐 retrySend 的 ed969a1 修法）
            [self removeReminderRetryItem:key];
            [[WKReminderDB shared] updateUploadStatus:WKReminderUploadStatusError reminderID:@(item.reminder.reminderID)];
            NSLog(@"WARN: 提醒项上传重试次数已耗尽，标记为上传失败 reminderID:%lld key:%@",(long long)item.reminder.reminderID,key);
        }
    }
}

-(void) contentEditRetryUpload {
    [self.retryLock lock];
    NSArray *keys = self.messageExtraRetryDict.allKeys;
    [self.retryLock unlock];
    
    for (NSString *key  in keys) {
        [self.retryLock lock];
        WKRetryItem *item =  self.messageExtraRetryDict[key];
        [self.retryLock unlock];
        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        
        if(!item) continue;
        // 如果重试次数小于目标重试次数并且满足重试时间，则重试
        if(item.retryCount<[WKSDK shared].options.contentEditRetryCount) {
            if((now - item.nextRetryTime)>=0) {
                if([WKSDK shared].isDebug) {
                    NSLog(@"重试上传编辑正文  key:[%@] retryCount: [%ld] nextRetryTime: [%ld]",key,item.retryCount,item.nextRetryTime);
                }
                item.retryCount++;
                item.nextRetryTime =now+[WKSDK shared].options.contentEditRetryInterval;
                [self uploadContentEdit:item.messageExtra];
            }
        }else { // 超过重试次数 编辑正文上传状态设置为失败、移出重试队列并通知上层（对齐 retrySend 的 ed969a1 修法）
            [self removeMessageExtraRetryItem:key];
            [[WKMessageExtraDB shared] updateUploadStatus:WKContentEditUploadStatusError withMessageID:item.messageExtra.messageID];
            NSLog(@"WARN: 编辑正文上传重试次数已耗尽，标记为上传失败 messageID:%llu key:%@",item.messageExtra.messageID,key);
            WKMessage *message = [[WKMessageDB shared] getMessageWithMessageId:item.messageExtra.messageID];
            if(message) {
                [[WKSDK shared].chatManager callMessageUpdateDelegate:message];
            }
        }
    }
}

-(void) uploadReminder:(WKReminder*)reminder {
    if(![WKSDK shared].reminderManager.reminderDoneProvider) {
        return;
    }
    [WKSDK shared].reminderManager.reminderDoneProvider(@[@(reminder.reminderID)], ^(NSError * _Nullable error) {
        if(error) {
            [[WKReminderDB shared] updateUploadStatus:WKReminderUploadStatusError reminderID:@(reminder.reminderID)];
        }else {
            NSString *key = [NSString stringWithFormat:@"%llu",reminder.reminderID];
            [self removeReminderRetryItem:key];
            [[WKReminderDB shared] updateUploadStatus:WKReminderUploadStatusSuccess reminderID:@(reminder.reminderID)];
        }
    });
}

-(void) uploadContentEdit:(WKMessageExtra*)extra {
    if(![WKSDK shared].chatManager.messageEditProvider) {
        return;
    }
    if(!extra.isEdit || !extra.contentEditData || [extra.contentEditData length] == 0) {
        return;
    }
    [WKSDK shared].chatManager.messageEditProvider(extra, ^(NSError * _Nullable error) {
        if(error) {
            [[WKMessageExtraDB shared] updateUploadStatus:WKContentEditUploadStatusError withMessageID:extra.messageID];
        }else {
            NSString *key = [NSString stringWithFormat:@"%llu",extra.messageID];
            [self removeMessageExtraRetryItem:key];
            [[WKMessageExtraDB shared] updateUploadStatus:WKContentEditUploadStatusSuccess withMessageID:extra.messageID];
        }
       WKMessage *message = [[WKMessageDB shared] getMessageWithMessageId:extra.messageID];
        if(message) {
            [[WKSDK shared].chatManager callMessageUpdateDelegate:message];
        }
       
    });
}

-(void) retrySend{
    [self.retryLock lock];
    NSArray *keys = self.retryDict.allKeys;
    [self.retryLock unlock];
    for (NSString *key  in keys) {
        [self.retryLock lock];
        WKRetryItem *item =  self.retryDict[key];
        [self.retryLock unlock];
        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        // 如果重试次数小于目标重试次数并且满足重试时间，则重试
        if(!item) continue;
        if(item.retryCount<[WKSDK shared].options.messageRetryCount ) {
            if((now - item.nextRetryTime)>=0) {
                if([WKSDK shared].isDebug) {
                    NSLog(@"重发消息  key:[%@] retryCount: [%ld] nextRetryTime: [%ld]",key,item.retryCount,item.nextRetryTime);
                }
                item.retryCount++;
                item.nextRetryTime =now+[WKSDK shared].options.messageRetryInterval;
                [[[WKSDK shared] chatManager] sendMessage:item.message addRetryQueue:false];
            }
        }else { // 超过重试次数 消息状态设置为发送失败
            [self.retryLock lock];
            [self.retryDict removeObjectForKey:key];
            [self.retryLock unlock];
            // 更新消息状态为失败
            item.message.status =WK_MESSAGE_FAIL;
            [[WKMessageDB shared] updateMessageStatus:WK_MESSAGE_FAIL withClientSeq:item.message.clientSeq];
           
            // 通知上层
            [[WKSDK shared].chatManager callMessageUpdateDelegate:item.message];
        }
    }
}

// TODO: retrySend如果执行时间过长 removeRetryItem会出现阻塞情况 (待观察)
-(void) removeRetryItem:(NSString*) key {
    [self.retryLock lock];
    [self.retryDict removeObjectForKey:key];
    [self.retryLock unlock];
}

-(void) removeMessageExtraRetryItem:(NSString*) key {
    [self.retryLock lock];
    [self.messageExtraRetryDict removeObjectForKey:key];
    [self.retryLock unlock];
}

-(void) removeReminderRetryItem:(NSString*)key {
    [self.retryLock lock];
    [self.reminderRetryDict removeObjectForKey:key];
    [self.retryLock unlock];
}

-(NSLock*) retryLock {
    // 防并发首次初始化出多个实例（Round 12 普查，对应 Android 2585602）
    @synchronized (self) {
        if(!_retryLock) {
            _retryLock = [[NSLock alloc] init];
        }
        return _retryLock;
    }
}

-(NSMutableDictionary*)retryDict {
    // 防并发首次初始化出多个实例（Round 12 普查，对应 Android 2585602）
    @synchronized (self) {
        if(!_retryDict) {
            _retryDict = [[NSMutableDictionary alloc] init];
        }
        return _retryDict;
    }
}

- (NSMutableDictionary<NSString *,WKRetryItem *> *)messageExtraRetryDict {
    // 防并发首次初始化出多个实例（Round 12 普查，对应 Android 2585602）
    @synchronized (self) {
        if(!_messageExtraRetryDict) {
            _messageExtraRetryDict = [[NSMutableDictionary alloc] init];
        }
        return _messageExtraRetryDict;
    }
}

- (NSMutableDictionary<NSString *,WKRetryItem *> *)reminderRetryDict {
    // 防并发首次初始化出多个实例（Round 12 普查，对应 Android 2585602）
    @synchronized (self) {
        if(!_reminderRetryDict) {
            _reminderRetryDict = [[NSMutableDictionary alloc] init];
        }
        return _reminderRetryDict;
    }
}


@end
