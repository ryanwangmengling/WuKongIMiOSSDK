//
//  WKConversationDB.m
//  WuKongIMSDK
//
//  Created by tt on 2019/11/29.
//

#import "WKConversationDB.h"
#import "WKDB.h"
#import "WKConversationUtil.h"
#define SQL_EXIST @"select count(*) cn from conversation where channel_id=? and channel_type=? and is_deleted=0"

#define SQL_GET_SELECT @"conversation.*,IFNULL(channel.stick,0) stick,IFNULL(channel.mute,0) mute,IFNULL(conversation_extra.browse_to,0) browse_to,IFNULL(conversation_extra.keep_message_seq,0) keep_message_seq,IFNULL(conversation_extra.keep_offset_y,0) keep_offset_y,IFNULL(conversation_extra.draft,'') draft,IFNULL(conversation_extra.version,0) extra_version"

#define SQL_GET [NSString stringWithFormat:@"select %@ from conversation left join channel on conversation.channel_id=channel.channel_id and conversation.channel_type=channel.channel_type left join conversation_extra on conversation.channel_id=conversation_extra.channel_id and conversation.channel_type=conversation_extra.channel_type   where conversation.channel_id=? and conversation.channel_type=? and conversation.is_deleted=0",SQL_GET_SELECT]

#define SQL_GET_WITH_CHANNELS [NSString stringWithFormat:@"select %@ from conversation left join channel on conversation.channel_id=channel.channel_id and conversation.channel_type=channel.channel_type left join conversation_extra on conversation.channel_id=conversation_extra.channel_id and conversation.channel_type=conversation_extra.channel_type   where conversation.is_deleted=0 and conversation.channel_id in ",SQL_GET_SELECT]

// 把channel里的stick和mute查询出来 为了防止排序conversation的时候去循环获取频道信息，最近会话过多会导致卡顿
#define SQL_GET_IN_ALL [NSString stringWithFormat:@"select %@ from conversation left join channel on conversation.channel_id=channel.channel_id and conversation.channel_type=channel.channel_type left join conversation_extra on conversation.channel_id=conversation_extra.channel_id and conversation.channel_type=conversation_extra.channel_type  where conversation.channel_id=? and conversation.channel_type=?",SQL_GET_SELECT]

#define SQL_ALL [NSString stringWithFormat:@"select %@ from conversation left join channel on conversation.channel_id=channel.channel_id and conversation.channel_type=channel.channel_type left join conversation_extra on conversation.channel_id=conversation_extra.channel_id and conversation.channel_type=conversation_extra.channel_type where conversation.is_deleted=0 order by conversation.last_msg_timestamp desc,conversation.id desc",SQL_GET_SELECT]

#define SQL_INSERT @"insert into conversation(channel_id,channel_type,parent_channel_id,parent_channel_type,avatar,last_client_msg_no,last_message_seq,last_msg_timestamp,unread_count,extra,version,is_deleted) values(?,?,?,?,?,?,?,?,?,?,?,?)"

#define SQL_REPLACE @"insert into conversation(channel_id,channel_type,parent_channel_id,parent_channel_type,avatar,last_client_msg_no,last_message_seq,last_msg_timestamp,unread_count,extra,version,is_deleted) values(?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(channel_id,channel_type) DO UPDATE SET parent_channel_id=excluded.parent_channel_id,parent_channel_type=excluded.parent_channel_type,last_client_msg_no=excluded.last_client_msg_no,last_message_seq=excluded.last_message_seq,last_msg_timestamp=excluded.last_msg_timestamp,unread_count=excluded.unread_count,version=excluded.version,is_deleted=excluded.is_deleted"

// 更新最新消息
#define SQL_UPDATE_LASTMSG @"update conversation set last_client_msg_no=?,last_message_seq=?,last_msg_timestamp=?,unread_count=?,is_deleted=0 where channel_id=? and channel_type=?"
// 更新用户标题
#define SQL_UPDATE_TITLEANDAVATAR @"update conversation set title=?,avatar=? where channel_id=? and channel_type=?"
// 清空频道未读消息数量
#define SQL_CLEAR_UNREADCOUNT @"update conversation set unread_count=0 where channel_id=? and channel_type=?"
// 设置频道未读消息数量
#define SQL_SET_UNREADCOUNT @"update conversation set unread_count=? where channel_id=? and channel_type=?"
// 更新提醒字段
#define SQL_UPDATE_REMINDERS @"update conversation set reminders=? where channel_id=? and channel_type=?"
// 通过最后一条消息的编号获取消息
#define SQL_GET_WITH_LASTCLIENTMSGNO [NSString stringWithFormat:@"select %@ from conversation left join channel on conversation.channel_id=channel.channel_id and conversation.channel_type=channel.channel_type left join conversation_extra on conversation.channel_id=conversation_extra.channel_id and conversation.channel_type=conversation_extra.channel_type  where conversation.last_client_msg_no=? and conversation.is_deleted=0",SQL_GET_SELECT]
// 所有会话未读数量
#define SQL_GET_ALL_UNREADCOUNT @"select sum(unread_count) unreadCount from conversation where is_deleted=0"
// 删除最近会话
#define SQL_DELETE_CONVERSATION @"update conversation set is_deleted=1 where channel_id=? and channel_type=?"
// 删除所有最近会话
#define SQL_DELETE_ALL_CONVERSATION @"delete from conversation"
// 恢复最近会话
#define SQL_RECOVERY_CONVERSATION @"update conversation set is_deleted=0 where channel_id=? and channel_type=?"

//获取会话最大版本
#define SQL_MAX_VERSION @"select IFNULL(MAX(version),0) version from conversation where version <> ''"

// 获取同步key
#define SQL_SYNC_KEY @"select GROUP_CONCAT(channel_id||':'||channel_type||':'||last_msg_seq,'|') synckey from (select *,(select max(message_seq) from message where message.channel_id=conversation.channel_id and message.channel_type= conversation.channel_type and message.content_type<>0 and message.content_type<>? limit 1) last_msg_seq from conversation) cn where channel_id<>''"

// 更新预览至
#define SQL_UPDATE_BROWSETO @"update conversation set browse_to=? where channel_id=? and channel_type=?"

@implementation WKConversationDB

static WKConversationDB *_instance;
+ (id)allocWithZone:(NSZone *)zone
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _instance = [super allocWithZone:zone];
    });
    return _instance;
}
+ (WKConversationDB *)shared
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _instance = [[self alloc] init];
    });
    return _instance;
}

-(void) addOrUpdateConversation:(WKConversation*)conversation{
    [[WKDB sharedDB].dbQueue inDatabase:^(FMDatabase * _Nonnull db) {
        bool exist = [self existConversation:conversation.channel db:db];
        if(exist) {
            [self updateConversation:conversation db:db];
        }else{
             [self insertConversation:conversation db:db];
        }
    }];
}

// 取代最近会话。返回 YES 表示整批写入成功；任一条失败会整批回滚并返回 NO（Round 33）
-(BOOL) replaceConversations:(NSArray<WKConversation*>*)conversations {
    if(!conversations || conversations.count<=0) {
        return YES;
    }
    if([WKDB sharedDB].dbQueue == nil) {
        NSLog(@"WARN: 最近会话批量替换失败：数据库不可用，数量:%lu",(unsigned long)conversations.count);
        return NO;
    }
    __block BOOL success = YES;
    [[WKDB sharedDB].dbQueue inTransaction:^(FMDatabase * _Nonnull db, BOOL * _Nonnull rollback) {
        for (WKConversation *conversation in conversations) {
            NSString *parentChannelID  = conversation.parentChannel?conversation.parentChannel.channelId:@"";
            uint8_t parentChannelType = conversation.parentChannel?conversation.parentChannel.channelType:0;
            // extraToStr: JSON 序列化失败会返回 nil，而 extra 列为 not null，需兜底为空串（Round 33）
            NSString *extraStr = [self extraToStr:conversation.extra] ?: @"";
            if(![db executeUpdate:SQL_REPLACE,conversation.channel.channelId?:@"",@(conversation.channel.channelType),parentChannelID,@(parentChannelType),conversation.avatar?:@"",conversation.lastClientMsgNo?:@"",@(conversation.lastMessageSeq),@(conversation.lastMsgTimestamp),@(conversation.unreadCount),extraStr,@(conversation.version),@(conversation.isDeleted)]) {
                success = NO;
                NSLog(@"WARN: 最近会话批量替换失败已回滚 channelId:%@ error:%@",conversation.channel.channelId?:@"",db.lastErrorMessage);
                *rollback = YES;
                return;
            }
        }
    }];
    return success;
}

-(void) addConversation:(WKConversation*)conversation {
    [[WKDB sharedDB].dbQueue inDatabase:^(FMDatabase * _Nonnull db) {
        [self insertConversation:conversation db:db];
    }];
}

// 返回 YES 表示写入成功。失败（如 channel_id+channel_type 已存在）返回 NO 并打 WARN（Round 36，对齐 Android ConversationDbManager.insert 的 result>0）
-(BOOL) insertConversation:(WKConversation*)conversation db:(FMDatabase*)db{
    NSString *extraStr = [self extraToStr:conversation.extra];
    NSString *parentChannelID  = conversation.parentChannel?conversation.parentChannel.channelId:@"";
    uint8_t parentChannelType = conversation.parentChannel?conversation.parentChannel.channelType:0;
    BOOL success = [db executeUpdate:SQL_INSERT,conversation.channel.channelId?:@"",@(conversation.channel.channelType),parentChannelID,@(parentChannelType),conversation.avatar?:@"",conversation.lastClientMsgNo?:@"",@(conversation.lastMessageSeq),@(conversation.lastMsgTimestamp),@(conversation.unreadCount),extraStr,@(conversation.version),@(conversation.isDeleted)];
    if(!success) {
        NSLog(@"WARN: 最近会话插入失败 channelId:%@ channelType:%d error:%@",conversation.channel.channelId?:@"",conversation.channel.channelType,db.lastErrorMessage);
    }
    return success;
}

-(void) clearConversationUnreadCount:(WKChannel*)channel {
    [[WKDB sharedDB].dbQueue inDatabase:^(FMDatabase * _Nonnull db) {
        [db executeUpdate:SQL_CLEAR_UNREADCOUNT,channel.channelId,@(channel.channelType)];
    }];
}

-(void) setConversationUnreadCount:(WKChannel*)channel unread:(NSInteger)unread {
    [[WKDB sharedDB].dbQueue inDatabase:^(FMDatabase * _Nonnull db) {
        [db executeUpdate:SQL_SET_UNREADCOUNT,@(unread),channel.channelId,@(channel.channelType)];
    }];
}

-(void) deleteConversation:(WKChannel*)channel {
    [[WKDB sharedDB].dbQueue inDatabase:^(FMDatabase * _Nonnull db) {
        [db executeUpdate:SQL_DELETE_CONVERSATION,channel.channelId?:@"",@(channel.channelType)];
    }];
}

-(void) deleteAllConversation {
    [[WKDB sharedDB].dbQueue inDatabase:^(FMDatabase * _Nonnull db) {
        [db executeUpdate:SQL_DELETE_ALL_CONVERSATION];
    }];
}


//-(WKConversation*) appendReminder:(WKReminder*) reminder channel:(WKChannel*)channel {
//    __block WKConversation *conversation;
//    [[WKDB sharedDB].dbQueue inDatabase:^(FMDatabase * _Nonnull db) {
//        conversation = [self getConversationWithChannel:channel db:db];
//        if(conversation) {
//            [conversation.reminderManager appendReminder:reminder];
//            [db executeUpdate:SQL_UPDATE_REMINDERS,[self remindersToStr:conversation.reminderManager.reminders],channel.channelId,@(channel.channelType)];
//        }
//    }];
//    return conversation;
//}
//
//-(WKConversation*) removeReminder:(WKReminderType)type channel:(WKChannel*)channel {
//    __block WKConversation *conversation;
//    [[WKDB sharedDB].dbQueue inDatabase:^(FMDatabase * _Nonnull db) {
//        conversation = [self getConversationWithChannel:channel db:db];
//        if(conversation) {
//            [conversation.reminderManager removeReminder:type];
//            [db executeUpdate:SQL_UPDATE_REMINDERS,[self remindersToStr:conversation.reminderManager.reminders],channel.channelId,@(channel.channelType)];
//        }
//    }];
//    return conversation;
//}
//
//-(WKConversation*) clearAllReminder:(WKChannel*)channel {
//    __block WKConversation *conversation;
//    [[WKDB sharedDB].dbQueue inDatabase:^(FMDatabase * _Nonnull db) {
//        conversation = [self getConversationWithChannel:channel db:db];
//        if(conversation) {
//            [db executeUpdate:SQL_UPDATE_REMINDERS,@"",channel.channelId,@(channel.channelType)];
//            conversation.reminderManager.reminders = [NSMutableArray array];
//        }
//    }];
//    return conversation;
//}
//
//- (WKConversation *)clearReminder:(WKChannel *)channel type:(NSInteger)type {
//    __block WKConversation *conversation;
//    [[WKDB sharedDB].dbQueue inDatabase:^(FMDatabase * _Nonnull db) {
//        conversation = [self getConversationWithChannel:channel db:db];
//        if(conversation) {
//            [self removeReminderForType:conversation.reminderManager.reminders type:type];
//            [db executeUpdate:SQL_UPDATE_REMINDERS,[self remindersToStr:conversation.reminderManager.reminders],channel.channelId,@(channel.channelType)];
//        }
//    }];
//    return conversation;
//}

-(NSInteger) getAllConversationUnreadCount {
    __block NSInteger unreadCount;
    [[WKDB sharedDB].dbQueue inDatabase:^(FMDatabase * _Nonnull db) {
        FMResultSet *resultSet = [db executeQuery:SQL_GET_ALL_UNREADCOUNT];
        if(resultSet.next) {
           unreadCount = [resultSet intForColumn:@"unreadCount"];
        }
        [resultSet close];
    }];
    return unreadCount;
}

-(void) updateBrowseTo:(uint32_t)browseTo forChannel:(WKChannel*)channel {
    [[WKDB sharedDB].dbQueue inDatabase:^(FMDatabase * _Nonnull db) {
        [db executeUpdate:SQL_UPDATE_BROWSETO,@(browseTo),channel.channelId,@(channel.channelType)];
    }];
}

-(void) removeReminderForType:(NSMutableArray*)reminders type:(NSInteger)type {
    if(!reminders || reminders.count<=0) {
        return;
    }
    for (NSInteger i = reminders.count - 1; i >= 0; i--) { // 逆序删除 防止出错
         WKReminder *reminder = reminders[i];
        if (reminder.type == type) {
            [reminders removeObject:reminder];
        }
    }
}

// 返回 YES 表示更新成功且命中至少一行（对齐 Android ConversationDbManager.update 的 affectedRows>0）。失败返回 NO 并打 WARN（Round 36）
-(BOOL) updateConversation:(WKConversation*)conversation db:(FMDatabase*)db{
    BOOL success = [db executeUpdate:SQL_UPDATE_LASTMSG,conversation.lastClientMsgNo?:@"",@(conversation.lastMessageSeq),@(conversation.lastMsgTimestamp),@(conversation.unreadCount),conversation.channel.channelId,@(conversation.channel.channelType)];
    if(success && [db changes] <= 0) {
        success = NO;
    }
    if(!success) {
        NSLog(@"WARN: 最近会话更新失败 channelId:%@ channelType:%d error:%@",conversation.channel.channelId?:@"",conversation.channel.channelType,db.lastErrorMessage);
    }
    return success;
}

-(void) updateConversation:(WKConversation*)conversation{
    [[WKDB sharedDB].dbQueue inDatabase:^(FMDatabase * _Nonnull db) {
        [self updateConversation:conversation db:db];
    }];
}

-(void) updateConversation:(WKChannel*)channel title:(NSString*)title avatar:(NSString*) avatar db:(FMDatabase*)db {
    [db executeUpdate:SQL_UPDATE_TITLEANDAVATAR,title?:@"",avatar?:@"",channel.channelId?:@"",@(channel.channelType)];
}


-(NSArray<WKConversation*>*) getConversationList {
    __block NSMutableArray<WKConversation*> *items = [NSMutableArray new];
    [[WKDB sharedDB].dbQueue inDatabase:^(FMDatabase * _Nonnull db) {
        FMResultSet *result = [db executeQuery:SQL_ALL];
        while (result.next) {
           [items addObject:[self toConversation:result.resultDictionary]];
        }
        [result close];
    }];
    return items;
}

-(WKConversation*) getConversation:(WKChannel*)channel{
     __block WKConversation *conversation;
    [[WKDB sharedDB].dbQueue inDatabase:^(FMDatabase * _Nonnull db) {
        FMResultSet *result =[db executeQuery:SQL_GET,channel.channelId,@(channel.channelType)];
        if (result.next) {
            conversation =  [self toConversation:result.resultDictionary];
        }
        [result close];
    }];
    return conversation;
}

-(NSArray<WKConversation*>*) getConversations:(NSArray<WKChannel*> *)channels {
    if(!channels||channels.count == 0) {
        return nil;
    }
    NSMutableArray<NSString*> *channelIDs = [NSMutableArray array];
    NSMutableArray<NSString*> *placeholders = [NSMutableArray array];
    for (WKChannel *channel in channels) {
        [channelIDs addObject:channel.channelId?:@""];
        [placeholders addObject:@"?"];
    }
    // 使用占位符绑定频道ID（原实现直接把 channelId 拼进 IN (...) 的引号中，含单引号的频道ID会生成非法SQL）
    NSString *inquery = [placeholders componentsJoinedByString:@","];
    __block NSMutableArray<WKConversation*> *conversations = [NSMutableArray array];
    [[WKDB sharedDB].dbQueue inDatabase:^(FMDatabase * _Nonnull db) {
        FMResultSet *resultSet =  [db executeQuery:[NSString stringWithFormat:@"%@ (%@)",SQL_GET_WITH_CHANNELS,inquery] withArgumentsInArray:channelIDs];
        while (resultSet.next) {
            WKConversation *conversation = [self toConversation:resultSet.resultDictionary];
            BOOL exist = false;
            for (WKChannel *channel in channels) {
                if([channel isEqual:conversation.channel]) {
                    exist = true;
                    break;
                }
            }
            if(exist) {
                [conversations addObject:conversation];
            }
        }
        [resultSet close];
    }];
    
    return conversations;
    
}


-(WKConversation*) recoveryConversation:(WKChannel*)channel {
     __block WKConversation *conversation;
    [[WKDB sharedDB].dbQueue inDatabase:^(FMDatabase * _Nonnull db) {
        FMResultSet *result = [db executeQuery:SQL_GET_IN_ALL,channel.channelId,@(channel.channelType)];
        if (result.next) {
            conversation =  [self toConversation:result.resultDictionary];
        }
        [result close];
        if(conversation) {
            conversation.isDeleted = 0;
            [db executeUpdate:SQL_RECOVERY_CONVERSATION,channel.channelId,@(channel.channelType)];
        }
    }];
    return conversation;
}

-(WKConversation*) getConversationWithLastClientMsgNo:(NSString*)lastClientMsgNo {
     __block WKConversation *conversation;
    [[WKDB sharedDB].dbQueue inDatabase:^(FMDatabase * _Nonnull db) {
        FMResultSet *result =  [db executeQuery:SQL_GET_WITH_LASTCLIENTMSGNO,lastClientMsgNo?:@""];
        if (result.next) {
            conversation =  [self toConversation:result.resultDictionary];
        }
        [result close];
    }];
    return conversation;
}

-(WKConversation*) getConversationWithChannel:(WKChannel*)channel db:(FMDatabase*)db{
    FMResultSet *result =[db executeQuery:SQL_GET,channel.channelId,@(channel.channelType)];
    WKConversation *conversation;
    if (result.next) {
        conversation =  [self toConversation:result.resultDictionary];
    }
    [result close];
    return conversation;
}

-(WKConversation*) getConversationWithChannelInAll:(WKChannel*)channel db:(FMDatabase*)db{
    FMResultSet *result =[db executeQuery:SQL_GET_IN_ALL,channel.channelId,@(channel.channelType)];
    WKConversation *conversation;
    if (result.next) {
        conversation =  [self toConversation:result.resultDictionary];
    }
    [result close];
    return conversation;
}

-(NSString*) extraToStr:(NSDictionary*)extra {
    NSString *extraStr = @"";
    if(extra) {
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:extra options:kNilOptions error:nil];
        if(!jsonData) { // 序列化失败时 initWithData:nil 会返回 nil，绑定 NULL 会让 not null 列整行写库失败（Round 34）
            NSLog(@"WARN: extra JSON 序列化失败，回退为空串 %@",NSStringFromClass([self class]));
            return @"";
        }
        extraStr = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding] ?: @"";
    }
    return extraStr;
}


-(BOOL) existConversation:(WKChannel*)channel db:(FMDatabase*)db{
    FMResultSet *result = [db executeQuery:SQL_EXIST,channel.channelId,@(channel.channelType)];
    __block BOOL isExit=false;
    if(result.next){
        NSDictionary *resultDic = result.resultDictionary;
        isExit = [resultDic[@"cn"] integerValue]>0?YES:NO;
    }
    [result close];
    return isExit;
}

-(long long) getConversationMaxVersion {
    __block long long version =0;
    [[WKDB sharedDB].dbQueue inDatabase:^(FMDatabase * _Nonnull db) {
        FMResultSet *result = [db executeQuery:SQL_MAX_VERSION];
        if(result.next){
            NSDictionary *resultDic = result.resultDictionary;
            version = [resultDic[@"version"] longLongValue];
        }
        [result close];
    }];
    return version;
}

-(NSString*) getConversationSyncKey {
    __block NSString *syncKey = @"";
    [[WKDB sharedDB].dbQueue inDatabase:^(FMDatabase * _Nonnull db) {
        
        FMResultSet *result = [db executeQuery:SQL_SYNC_KEY,@(WK_CMD)];
        if(result.next){
            NSDictionary *resultDic = result.resultDictionary;
            if(resultDic[@"synckey"] && ![resultDic[@"synckey"] isKindOfClass:[NSNull class]]) {
                syncKey = resultDic[@"synckey"];
            }
            
        }
        [result close];
    }];
    return syncKey;
}

-(WKConversation*) toConversation:(NSDictionary*)dict {
    WKConversation *conversation = [WKConversation new];
    conversation.channel = [[WKChannel alloc] initWith:dict[@"channel_id"] channelType:[dict[@"channel_type"] integerValue]];
    if(dict[@"parent_channel_id"] && ![dict[@"parent_channel_id"] isEqualToString:@""]) {
        conversation.parentChannel = [WKChannel channelID:dict[@"parent_channel_id"] channelType:[dict[@"parent_channel_type"] integerValue]];
    }
    conversation.avatar = dict[@"avatar"];
    conversation.lastClientMsgNo = dict[@"last_client_msg_no"];
    conversation.lastMessageSeq = [dict[@"last_message_seq"] unsignedIntValue];
    conversation.lastMsgTimestamp = [dict[@"last_msg_timestamp"] integerValue];
    conversation.unreadCount = [dict[@"unread_count"] integerValue];
    conversation.version = [dict[@"version"] longLongValue];
    conversation.mute = [dict[@"mute"] boolValue];
    conversation.stick = [dict[@"stick"] boolValue];
    // 同 WKMessageExtraDB.toExtra:：extra 列空/非字符串/非 JSON 对象时跳过，避免 NSNull/nil 触发 NSInvalidArgumentException
    NSString *extraStr = dict[@"extra"];
    if([extraStr isKindOfClass:[NSString class]] && extraStr.length>0) {
        __autoreleasing NSError *error = nil;
        NSDictionary *extraDictionary = [NSJSONSerialization JSONObjectWithData:[extraStr dataUsingEncoding:NSUTF8StringEncoding] options:kNilOptions error:&error];
        if(!error && [extraDictionary isKindOfClass:[NSDictionary class]]) {
            conversation.extra = extraDictionary;
        }
    }
    conversation.remoteExtra.channel = conversation.channel;
    if(dict[@"keep_message_seq"]) {
        conversation.remoteExtra.keepMessageSeq = [dict[@"keep_message_seq"] unsignedIntValue];
    }
    if(dict[@"keep_offset_y"]) {
        conversation.remoteExtra.keepOffsetY = [dict[@"keep_offset_y"] integerValue];
    }
    if(dict[@"draft"]) {
        conversation.remoteExtra.draft = dict[@"draft"];
    }
    if(dict[@"extra_version"]) {
        conversation.remoteExtra.version = [dict[@"extra_version"] longLongValue];
    }
    
    return conversation;
}

@end

@implementation WKConversationAddOrUpdateResult

+(instancetype) initWithInsert:(BOOL)insert modify:(BOOL)modify conversation:(WKConversation*)conversation {
    WKConversationAddOrUpdateResult *result = [WKConversationAddOrUpdateResult new];
    result.insert = insert;
    result.conversation = conversation;
    result.modify = modify;
    result.success = YES; // 默认成功；调用方落库失败时置 NO（Round 36）
    return result;
}

@end
