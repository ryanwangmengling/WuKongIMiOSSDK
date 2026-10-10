//
//  WKRobotDB.m
//  WuKongIMSDK
//
//  Created by tt on 2021/10/19.
//

#import "WKRobotDB.h"
#import "WKDB.h"
// 保存robot
//#define SQL_ROBOT_SAVE [NSString stringWithFormat:@"insert into %@(robot_id,version,status,menus) values(?,?,?,?)","robot"]

#define SQL_ROBOTS_WITH_IDS [NSString stringWithFormat:@"select * from robot where status=1 and robot_id in "]

#define SQL_ROBOTS_WITH_USERNAMES [NSString stringWithFormat:@"select * from robot where status=1 and username in "]

#define SQL_ROBOT_WITH_USERNAME [NSString stringWithFormat:@"select * from robot where status=1 and username=?"]

#define SQL_ROBOTS_INSERT_OR_UPDATE [NSString stringWithFormat:@"insert into robot(robot_id,version,status,inline_on,placeholder,menus,username) values(?,?,?,?,?,?,?) ON CONFLICT(robot_id) DO UPDATE SET version=excluded.version,status=excluded.status,inline_on=excluded.inline_on,placeholder=excluded.placeholder,menus=excluded.menus,username=excluded.username"]

@implementation WKRobotDB

static WKRobotDB *_instance;
+ (id)allocWithZone:(NSZone *)zone
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _instance = [super allocWithZone:zone];
    });
    return _instance;
}
+ (WKRobotDB *)shared
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _instance = [[self alloc] init];
    });
    return _instance;
}


-(NSArray<WKRobot*>*) queryRobots:(NSArray<NSString*>*)robotIDs  {
    if(!robotIDs || robotIDs.count==0) {
        return nil;
    }
    NSMutableArray<NSString*> *bindValues = [NSMutableArray array];
    NSMutableArray<NSString*> *placeholders = [NSMutableArray array];
    for (NSString *robotID in robotIDs) {
        [bindValues addObject:robotID?:@""];
        [placeholders addObject:@"?"];
    }
    NSMutableArray<WKRobot*> *robots = [NSMutableArray array];
    [[[WKDB sharedDB] dbQueue] inDatabase:^(FMDatabase * _Nonnull db) {
        FMResultSet *result=  [db executeQuery:[NSString stringWithFormat:@"%@ (%@)",SQL_ROBOTS_WITH_IDS,[placeholders componentsJoinedByString:@","]] withArgumentsInArray:bindValues];
        while (result.next) {
            [robots addObject:[self toRobot:result]];
        }
        [result close];
    }];
    return robots;
}

-(NSArray<WKRobot*>*) queryRobotsWithUsernames:(NSArray<NSString*>*)usernames {
    if(!usernames || usernames.count==0) {
        return nil;
    }
    NSMutableArray<NSString*> *bindValues = [NSMutableArray array];
    NSMutableArray<NSString*> *placeholders = [NSMutableArray array];
    for (NSString *username in usernames) {
        [bindValues addObject:username?:@""];
        [placeholders addObject:@"?"];
    }
    NSMutableArray<WKRobot*> *robots = [NSMutableArray array];
    [[[WKDB sharedDB] dbQueue] inDatabase:^(FMDatabase * _Nonnull db) {
        FMResultSet *result=  [db executeQuery:[NSString stringWithFormat:@"%@ (%@)",SQL_ROBOTS_WITH_USERNAMES,[placeholders componentsJoinedByString:@","]] withArgumentsInArray:bindValues];
        while (result.next) {
            [robots addObject:[self toRobot:result]];
        }
        [result close];
    }];
    return robots;
}

-(WKRobot*) queryRobotWithUsername:(NSString*)username {
    __block WKRobot *robot;
    [[WKDB sharedDB].dbQueue inDatabase:^(FMDatabase * _Nonnull db) {
        FMResultSet *result = [db executeQuery:SQL_ROBOT_WITH_USERNAME,username];
        if (result.next) {
            robot = [self toRobot:result];
        }
        [result close];
    }];
    return robot;
}

-(BOOL) addOrUpdateRobots:(NSArray<WKRobot*>*)robots {
    if(!robots || robots.count<=0) {
        return YES;
    }
    if([[WKDB sharedDB] dbQueue] == nil) {
        NSLog(@"WARN: 机器人入库失败：数据库不可用 数量:%lu",(unsigned long)robots.count);
        return NO;
    }
    __block BOOL success = YES;
    [[[WKDB sharedDB] dbQueue] inTransaction:^(FMDatabase * _Nonnull db, BOOL * _Nonnull rollback) {
        for (WKRobot *robot in robots) {
            NSString *menusStr = @"";
            if(robot.menus&&robot.menus.count>0) {
                menusStr = [self toJSON:robot.menus];
            }
            
            if(![db executeUpdate:SQL_ROBOTS_INSERT_OR_UPDATE,robot.robotID?:@"",@(robot.version),@(robot.status),@(robot.inlineOn),robot.placeholder?:@"",menusStr,robot.username?:@""]) {
                success = NO;
                NSLog(@"WARN: 机器人入库失败已回滚 robotID:%@ error:%@",robot.robotID?:@"",db.lastErrorMessage);
                *rollback = YES;
                return;
            }
        }
       
    }];
    return success;
}

-(NSString*) toJSON:(NSArray<WKRobotMenus*> *) menusList {
    NSMutableArray<NSDictionary*> *menusDicts = [NSMutableArray array];
    if(menusList && menusList.count>0) {
        for (WKRobotMenus *menus in menusList) {
            [menusDicts addObject:@{
                @"cmd":menus.cmd?:@"",
                @"remark": menus.remark?:@"",
                @"type": menus.type?:@"",
            }];
        }
    }
    NSData *menusData = [NSJSONSerialization dataWithJSONObject:menusDicts options:0 error:nil];
    return  [[NSString alloc] initWithData:menusData encoding:NSUTF8StringEncoding];
}

-(WKRobot*) toRobot:(FMResultSet*)result {
    WKRobot *robot = [WKRobot new];
    robot.robotID = [result stringForColumn:@"robot_id"];
    robot.username = [result stringForColumn:@"username"];
    robot.version = [result longForColumn:@"version"];
    robot.status = [result intForColumn:@"status"];
    robot.inlineOn = [result boolForColumn:@"inline_on"];
    robot.placeholder = [result stringForColumn:@"placeholder"]?:@"";
    NSString *menusJSON = [result stringForColumn:@"menus"];
    if(menusJSON && ![menusJSON isEqualToString:@""]) {
        NSError *err;
        NSArray *menusDicts = [NSJSONSerialization
            JSONObjectWithData:[menusJSON dataUsingEncoding:NSUTF8StringEncoding]
                       options:NSJSONReadingAllowFragments
                         error:&err];
        // menus 必须是 JSON 数组；NSNull/字典/数字做快速枚举会崩（Round 40）
        if(!err && [menusDicts isKindOfClass:[NSArray class]]) {
            NSMutableArray *menus = [NSMutableArray array];
            for (NSDictionary *menusDict in menusDicts) {
                if(![menusDict isKindOfClass:[NSDictionary class]]) {
                    continue;
                }
                WKRobotMenus *m = [self toRobotMenus:menusDict];
                m.robotID = robot.robotID;
                [menus addObject:m];
            }
            robot.menus = menus;
        }
    }
    return robot;
}

-(WKRobotMenus*) toRobotMenus:(NSDictionary*)dict {
    WKRobotMenus *menus = [WKRobotMenus new];
    menus.cmd = dict[@"cmd"];
    menus.remark = dict[@"remark"];
    menus.type = dict[@"type"];
    return menus;
}

@end
