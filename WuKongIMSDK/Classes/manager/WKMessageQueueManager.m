//
//  WKMessageQueueManager.m
//  WuKongIMSDK
//
//  Created by tt on 2023/11/15.
//

#import "WKMessageQueueManager.h"
#import "WKMessage.h"
#import "WKSendPacket.h"
#import "WKSDK.h"
#import "WKConnectionManager.h"

@interface WKMessageQueueManager ()

@property (nonatomic, strong) NSMutableArray<WKSendPacket*> *sendPackets;
// 保护 sendPackets：sendMessage: 在调用线程 append，flushQueue/stop 在主线程消费
@property (nonatomic,strong) NSLock *queueLock;

@property(nonatomic,strong) NSTimer *timer;
// 定时器代际：start/stop 自增，用于作废尚未执行的 main-queue 定时器创建块
// （否则「重复 start」或「start 后立刻 stop」会留下一个永不失效的 NSTimer）
@property(atomic,assign) int timerGeneration;

@end

@implementation WKMessageQueueManager


static WKMessageQueueManager *_instance;
+ (id)allocWithZone:(NSZone *)zone
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _instance = [super allocWithZone:zone];
    });
    return _instance;
}
+ (WKMessageQueueManager *)shared
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _instance = [[self alloc] init];
    });
    return _instance;
}
- (NSMutableArray<WKSendPacket *> *)sendPackets {
    // 防并发首次初始化出多个实例（Round 12 普查，对应 Android 2585602）
    @synchronized (self) {
        if(!_sendPackets) {
            _sendPackets = [NSMutableArray array];
        }
        return _sendPackets;
    }
}

- (void)sendMessage:(WKMessage *)message {
    // 发送消息
    WKSendPacket *sendPacket = [WKSendPacket new];
    sendPacket.header.showUnread = message.header?message.header.showUnread:0;
    sendPacket.header.noPersist = message.header?message.header.noPersist:0;
    WKSetting *setting = message.setting;
    if(message.topic && ![message.topic isEqualToString:@""]) {
        setting.topic = true;
    }
    sendPacket.setting = setting;
    sendPacket.clientSeq = message.clientSeq;
    sendPacket.clientMsgNo = message.clientMsgNo;
    sendPacket.channelId = message.channel.channelId;
    sendPacket.channelType = message.channel.channelType;
    sendPacket.expire = message.expire;
    sendPacket.topic = message.topic;
    sendPacket.payload = message.content.encode;
    // 与主线程的 flushQueue/stop 互斥，避免 NSMutableArray 并发读写崩溃（Round 15）
    [self.queueLock lock];
    [self.sendPackets addObject:sendPacket];
    [self.queueLock unlock];
    
   
}

- (NSLock *)queueLock {
    // 防并发首次初始化出多个实例（Round 12 普查，对应 Android 2585602）
    @synchronized (self) {
        if(!_queueLock) {
            _queueLock = [[NSLock alloc] init];
        }
        return _queueLock;
    }
}

-(void) start {
    // 定时器只在主线程创建/销毁；用代际作废旧块，保证同一时刻最多一个 timer。
    int generation = 0;
    @synchronized (self) {
        generation = ++self.timerGeneration;
    }
    CGFloat delay = (double)WKSDK.shared.options.sendFrequency/1000.0f;
    NSLog(@"MessageQueue start delay: %0.2f",delay);
    
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(self) strongSelf = weakSelf;
        if(!strongSelf) {
            return;
        }
        if(generation != strongSelf.timerGeneration) { // 已被后续 start/stop 取代
            return;
        }
        if(strongSelf.timer) {
            [strongSelf.timer invalidate];
            strongSelf.timer = nil;
        }
        strongSelf.timer = [NSTimer scheduledTimerWithTimeInterval:delay target:strongSelf selector:@selector(flushQueue) userInfo:nil repeats:YES];
    });
  
    
}

-(void) stop {
    NSLog(@"MessageQueue stop");
    // 作废尚未执行的 start 块，避免 stop 之后又被创建一个 timer
    @synchronized (self) {
        self.timerGeneration++;
    }
    [self.queueLock lock];
    [self.sendPackets removeAllObjects];
    [self.queueLock unlock];
    // timer 只在主线程销毁
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(self) strongSelf = weakSelf;
        if(!strongSelf) {
            return;
        }
        if(strongSelf.timer) {
            [strongSelf.timer invalidate];
            strongSelf.timer = nil;
        }
    });
}

-(void) flushQueue {
    // 先在锁内把本批要发的包摘出来（不在锁内 encode/写 socket，避免阻塞 sendMessage:）
    NSInteger limit = [WKSDK shared].options.sendMaxCountOfEach;
    if(limit<=0) { // 与原来语义保持一致：上限非法时也至少发 1 个
        limit = 1;
    }
    [self.queueLock lock];
    NSInteger count = MIN((NSInteger)self.sendPackets.count, limit);
    NSArray<WKSendPacket*> *batch = count>0?[self.sendPackets subarrayWithRange:NSMakeRange(0, count)]:@[];
    if(count>0) {
        [self.sendPackets removeObjectsInRange:NSMakeRange(0, count)];
    }
    [self.queueLock unlock];
    
    if(batch.count==0) {
        return;
    }
    NSMutableData *sendPacketDatas = [[NSMutableData alloc] init];
    for (WKSendPacket *sendPacket in batch) {
        NSData *data = [[WKSDK shared].coder encode:sendPacket];
        [sendPacketDatas appendData:data];
    }
    if(sendPacketDatas.length>0) {
        [WKConnectionManager.sharedManager writeData:sendPacketDatas];
    }
}


@end
