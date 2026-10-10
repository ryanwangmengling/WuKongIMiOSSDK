//
//  WKConversationExtraDB.m
//  WuKongIMSDK
//
//  Created by tt on 2022/4/23.
//

#import "WKConversationExtraDB.h"
#import "WKDB.h"


#define SQL_ADD_UPDATE [NSString stringWithFormat:@"insert into %@( channel_id,channel_type,browse_to,keep_message_seq,keep_offset_y,`draft`,`version`) values(?,?,?,?,?,?,?) ON CONFLICT(channel_id,channel_type) DO UPDATE SET browse_to=excluded.browse_to,keep_message_seq=excluded.keep_message_seq,keep_offset_y=excluded.keep_offset_y,draft=excluded.draft,version=excluded.version",@"conversation_extra"]

#define SQL_MAX_VERSION [NSString stringWithFormat:@"select max(version) max_version from %@",@"conversation_extra"]

#define SQL_UPDATE_VERSION [NSString stringWithFormat:@"update %@ set version=? where channel_id=? and channel_type=? ",@"conversation_extra"]

@implementation WKConversationExtraDB

static WKConversationExtraDB *_instance;
+ (id)allocWithZone:(NSZone *)zone
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _instance = [super allocWithZone:zone];
    });
    return _instance;
}
+ (WKConversationExtraDB *)shared
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _instance = [[self alloc] init];
    });
    return _instance;
}

-(void) updateVersion:(WKChannel*)channel version:(int64_t)version {
    [[WKDB sharedDB].dbQueue inDatabase:^(FMDatabase * _Nonnull db) {
        if(![db executeUpdate:SQL_UPDATE_VERSION,@(version),channel.channelId?:@"",@(channel.channelType)]) {
            NSLog(@"WARN: 更新会话扩展版本失败 channelId:%@ error:%@",channel.channelId?:@"",db.lastErrorMessage);
        }
    }];
}

// 最近会话扩展批量入库。返回 YES 表示整批写入成功；任一条失败会整批回滚并返回 NO（Round 33）
-(BOOL) addOrUpdates:(NSArray<WKConversationExtra*>*)extras {
    if(!extras || extras.count==0) {
        return YES;
    }
    if([WKDB sharedDB].dbQueue == nil) {
        NSLog(@"WARN: 最近会话扩展入库失败：数据库不可用，数量:%lu",(unsigned long)extras.count);
        return NO;
    }
    __block BOOL success = YES;
    [[WKDB sharedDB].dbQueue inTransaction:^(FMDatabase * _Nonnull db, BOOL * _Nonnull rollback) {
        for (WKConversationExtra *extra in extras) {
            if(![db executeUpdate:SQL_ADD_UPDATE,extra.channel.channelId?:@"",@(extra.channel.channelType),@(0),@(extra.keepMessageSeq),@(extra.keepOffsetY),extra.draft?:@"",@(extra.version)]) {
                success = NO;
                NSLog(@"WARN: 最近会话扩展入库失败已回滚 channelId:%@ error:%@",extra.channel.channelId?:@"",db.lastErrorMessage);
                *rollback = YES;
                return;
            }
        }
    }];
    return success;
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
-(int64_t) getMaxVersion {
    __block int64_t maxVersion = 0;
    [[WKDB sharedDB].dbQueue inDatabase:^(FMDatabase * _Nonnull db) {
        FMResultSet *result = [db executeQuery:SQL_MAX_VERSION];
        if(result.next) {
            maxVersion = [result longLongIntForColumn:@"max_version"];
        }
        [result close];
    }];
    return maxVersion;
}

@end
