//
//  WKTaskManager.m
//  WuKongIMSDK
//
//  Created by tt on 2020/1/15.
//

#import "WKTaskManager.h"

@interface WKTaskManager ()
@property(nonatomic,strong) NSLock *taskLock;
@property(nonatomic,strong) NSMutableDictionary *taskDic;

@end

@implementation WKTaskManager

- (void)add:(id<WKTaskProto>)task {
    if(!task || !task.taskId) {
        return;
    }
    [self.taskLock lock];
    self.taskDic[task.taskId] = task;
    [self.taskLock unlock];
    __weak typeof(task) weakTask = task;
    [task addListener:^{
        if(weakTask.status == WKTaskStatusProgressing) {
            [self callTaskProgressDelegate:weakTask];
        }
        if([self isComplete:weakTask]) {
            [self callTaskCompleteDelegate:weakTask];
            [self remove:weakTask];
        }
        
    } target:self];
    [task resume];
    
}

-(void) callTaskCompleteDelegate:(id<WKTaskProto>) task {
    if(self.delegate && [self.delegate respondsToSelector:@selector(taskComplete:)]) {
        
        if (![NSThread isMainThread]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.delegate taskComplete:task];
            });
        }else {
            [self.delegate taskComplete:task];
        }
    }
}
-(void) callTaskProgressDelegate:(id<WKTaskProto>) task {
    if(self.delegate && [self.delegate respondsToSelector:@selector(taskProgress:)]) {
        
        if (![NSThread isMainThread]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.delegate taskProgress:task];
            });
        }else {
            [self.delegate taskProgress:task];
        }
    }
}

-(BOOL) isComplete:(id<WKTaskProto>) task {
     return task.status !=WKTaskStatusWait && task.status != WKTaskStatusSuspend && task.status != WKTaskStatusProgressing;
}

- (id<WKTaskProto>)get:(NSString *)taskId {
    if(!taskId) {
        return nil;
    }
    [self.taskLock lock];
    id<WKTaskProto> task = self.taskDic[taskId];
    [self.taskLock unlock];
    return task;
}

- (void)remove:(id<WKTaskProto>)task {
    if(!task || !task.taskId) {
        return;
    }
    [self.taskLock lock];
    [self.taskDic removeObjectForKey:task.taskId];
    [self.taskLock unlock];
    [task removeListener:self];
}

-(NSMutableDictionary*) taskDic {
    // 防并发首次初始化出多个实例（Round 12 普查，对应 Android 2585602）
    @synchronized (self) {
        if(!_taskDic) {
            _taskDic = [[NSMutableDictionary alloc] init];
        }
        return _taskDic;
    }
}

- (NSLock *)taskLock {
    // 防并发首次初始化出多个实例（Round 12 普查，对应 Android 2585602）
    @synchronized (self) {
        if(!_taskLock) {
            _taskLock = [[NSLock alloc] init];
        }
        return _taskLock;
    }
}

@end
