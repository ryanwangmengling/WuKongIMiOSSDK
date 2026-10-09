# WuKongIMiOSSDK 本地修改记录

- Fork: https://github.com/ryanwangmengling/WuKongIMiOSSDK
- 上游: https://github.com/WuKongIM/WuKongIMiOSSDK（官方 2024-12-29 后冻结）
- 本地基线: `main` @ `aedef4e`
- 目的: 修复上游遗留 bug，并逐轮移植 WuKongIMAndroidSDK 的稳定性补丁（Android 参考仓库同目录 `../WuKongIMAndroidSDK`）。

> 维护约定：每轮一个主题，改完追加一节。每条记录写清「文件 / 问题 / 改动 / 对应 Android 修复」。
> 与上游同步方式见根目录外文档《Fork 全量 WuKongIMiOSSDK 改造清单》——始终把本地改动重放到 `upstream-master` 之上。

---

## Round 1 — 崩溃修复与重连退避单位（2026-10-09）

### 1.1 重连退避 cap 单位错误（严重）
- **文件**: `WuKongIMSDK/Classes/manager/WKConnectionManager.m`（`sharedManager` 中 `reconnectBackoff` 构造，约 108 行）
- **问题**: `builder.cap = 60 * 1000`。`WKBackoff.backoff:` 的返回值被 `backoffReconnect` 直接传给 `[NSThread sleepForTimeInterval:]`，单位是**秒**，因此 cap 实际是 60000 秒 ≈ 16.6 小时。`base=2, factor=2` 下第 5 次重连就已到 cap，弱网/断网时会表现为「再也不重连」。
- **改动**: `builder.cap = 60;`（60 秒），并加注释说明单位。
- **对应 Android**: `2026-01-29 fix:优化无网络时重连逻辑，避免重连次数被无效消耗`（Android 还有 NetworkChecker，iOS 网络感知属后续轮次）。

### 1.2 拉取消息回调收到 nil / error 被吞
- **文件**: `WuKongIMSDK/Classes/manager/WKChatManager.m`（`completePullMessages:error:complete:`，约 1126 行）
- **问题**: `messages` 为空时 `[self sortMessages:nil]` 会让回调收到 `nil`，调用方未判空即崩溃（上游 issue #2）；且原实现始终 `complete(..., nil)`，调用方无法感知失败。
- **改动**: 回调前把 `nil` 归一为 `@[]`，并把真实 `error` 透传。
- **对应 Android**: 无直接对应，属上游 issue #2。

### 1.3 媒体下载状态误报成功
- **文件**: `WuKongIMSDK/Classes/manager/WKMediaManager.m`（`download:callback:` 的 listener，约 140 行）
- **问题**: 只判断 `WKTaskStatusProgressing` / `WKTaskStatusError`，其余状态（`Wait`/`Suspend`/`Cancel` 等）全部落到 `else`，误报 `WKMediaDownloadStateSuccess`（上游 issue #3：原图被删/链接错误时仍返回 Success）。
- **改动**: 显式判断 `WKTaskStatusSuccess` 才返回 Success；`Error`/`Cancel` 返回 Fail；其余（Wait/Progressing/Suspend）返回 Processing 并带上真实进度。
- **对应 Android**: 无直接对应，属上游 issue #3。

---

## Round 2 — 网络感知与重连加固（2026-10-09）

> 背景：上游 iOS SDK 完全没有网络可达性判断（全仓无 Reachability/NWPathMonitor）。Android 有 `NetworkChecker`（`wkim/src/main/java/com/xinbida/wukongim/message/timer/NetworkChecker.java`）：每秒检查网络，无网时把状态置为 `noNetwork` 并停止无效重连，网络恢复时重置重连计数并立即重连。本轮把该机制移植到 iOS。

### 2.1 新增网络监听 WKNetworkMonitor（新文件）
- **文件**: `WuKongIMSDK/Classes/manager/WKNetworkMonitor.h` / `.m`（新增）；`WuKongIMSDK.podspec`
- **问题**: SDK 不感知网络，无网时仍会不断尝试连接，且界面无法区分「无网络」与「连接中」。
- **改动**: 新增单例 `WKNetworkMonitor`，用 `SCNetworkReachability`（`SCNetworkReachabilityCreateWithAddress` + `SCNetworkReachabilitySetCallback` + `SCNetworkReachabilitySetDispatchQueue`，主队列）监听 0.0.0.0 的可达性，按 `kSCNetworkReachabilityFlagsReachable` / `ConnectionRequired` / `InterventionRequired` 判定，暴露 `isNetworkAvailable`、`start`/`stop` 与 `networkStatusChange` block。podspec 增加链接 `SystemConfiguration`。
- **为什么不用 NWPathMonitor**: podspec 最低支持 iOS 11.0，`NWPathMonitor` 需要 iOS 12+。
- **对应 Android**: `NetworkChecker.java` 的整体机制。

### 2.2 无网络时重连次数被无效消耗
- **文件**: `WuKongIMSDK/Classes/manager/WKConnectionManager.m`（`backoffReconnect`、新增 `onNetworkStatusChange:`）
- **问题**: 无网时每次退避重连仍会 `reconnectCount++`，弱网/断网久了 `backoff` 很快到达 cap（60 秒），且一直空转。
- **改动**: `backoffReconnect` 在 `networkAvailable == NO` 时直接返回、不消耗重连次数，等网络恢复由 `onNetworkStatusChange:` 触发；恢复网络时把 `reconnectCount`/`addrRetryCount` 归 0（对应 Android `resetConnCount()`），未连接则立即 `reconnect`。
- **对应 Android**: `2026-01-29 fix:优化无网络时重连逻辑，避免重连次数被无效消耗` + `NetworkChecker.resetConnCount()`。

### 2.3 连接状态新增「无网络」
- **文件**: `WuKongIMSDK/Classes/manager/WKConnectionManager.h`（枚举）
- **改动**: `WKConnectStatus` 末尾新增 `WKNoNetwork`；无网时 `onNetworkStatusChange:` 会 `stopHeartbeat` 并切换到该状态，UI 可据此提示。
- **对应 Android**: `WKConnectStatus.noNetwork`。

### 2.4 loopGetAddrToConnect 每秒无限重试 + 数组越界
- **文件**: `WuKongIMSDK/Classes/manager/WKConnectionManager.m`（`loopGetAddrToConnect`、新增 `scheduleRetryGetAddr`）
- **问题**: (1) 获取连接地址失败/为空时固定每秒无限重试，无退避；(2) `if(addrs.count>0)` 后取 `addrs[1]`，当地址字符串不含 `:` 时会越界崩溃；(3) 无网时也在空转。
- **改动**: 地址为空改走新的 `scheduleRetryGetAddr`（独立 `addrBackoff`：base=1、factor=2、cap=30 秒）做指数退避；仅当 `addrs.count > 1` 才取端口，否则回退到 `options.port`；无网时暂停获取地址，等网络恢复。
- **对应 Android**: Android 地址获取/重连的退避保护。

### 2.5 connect 失败后不再重连
- **文件**: `WuKongIMSDK/Classes/manager/WKConnectionManager.m`（`connectSocket:port:`）
- **问题**: `connectToHost:onPort:error:` 同步返回 error 时只把状态置为 `WKDisconnected` 就结束，不再安排任何重连，导致一次失败后彻底掉线。
- **改动**: error 分支补 `[self backoffReconnect]`；无网络时直接不发起连接。
- **对应 Android**: `ConnectionClient` 失败回调中的重连安排。

### 2.6 退避重连可被取消 / 不重复排队
- **文件**: `WuKongIMSDK/Classes/manager/WKConnectionManager.m`（`backoffReconnect`、新增 `cancelBackoffReconnect`；`disconnect:`、`logout`、`handleConnected:`）
- **问题**: 退避期间可能同时存在多个排队重连（网络恢复又触发一次），主动断开/退出登录后旧的退避任务仍会重连。
- **改动**: 引入 `reconnectGeneration` 代际：`cancelBackoffReconnect` 自增代际使在途退避任务失效；`isBackoffReconnect` 防止重复排队；`disconnect:`/`logout`/`handleConnected:` 均调用取消；网络恢复也会取消后立即重连。
- **对应 Android**: Android `reconnection()` 的幂等/取消语义。

---

## Round 3 — DB 生命周期与迁移健壮性（2026-10-09）

> 背景：Android 侧 2026 年集中修了一批 DB 问题（`11af5e9` 丢库补表、`594ccb2` 连接池关闭竞态、`a3b4ea0` harden close、`bdc02e2` SQLCipher 关闭后 cursor 崩、`5b69519` 补索引、`1a48603`/`f193f42` 开 WAL）。iOS 的 `WKDB`/`WKDBMigrationManager`/`WKFMDatabaseQueue` 基本停留在 2019 年的实现，本轮按同样的思路加固。

### 3.1 needSwitchDB 逻辑反了：每次 connect 都重开 DB
- **文件**: `WuKongIMSDK/Classes/db/WKDB.m`（`needSwitchDB:`）
- **问题**: 原逻辑在 `dbPrefix` **相同**（第二次起）时反而返回 `YES`，只有前缀不同才可能返回 `false`。结果是同一用户每次 `connect` 都会 `close` 旧库再新建，重连/多线程场景下极易出现「旧队列已关闭仍被使用」的崩溃。
- **改动**: 仅当「当前用户 == uid 且 `currentDBPrefix` 未变」时返回 `NO`（复用）；用 `@synchronized(self)` 保护，并去掉在这里顺带改 prefix 的副作用。
- **对应 Android**: `594ccb2`（连接池关闭竞态两层防御 + logout race）、`a3b4ea0`（harden db close）。

### 3.2 switchDB 关闭/重开竞态
- **文件**: `WuKongIMSDK/Classes/db/WKDB.m`（`switchDB:`）
- **问题**: (1) 先 `[self.dbQueue close]` 再立刻新建，整个过程无锁，期间其他线程仍可能拿到已关闭队列；(2) 没有重置迁移管理器 `_manager`，它会一直持有上一个用户的 `FMDatabase`；(3) 没有开启 WAL。
- **改动**: 在 `@synchronized(self)` 内**先建新队列并安装 `self.dbQueue`**，再关闭旧队列（延迟 0.5s 到后台队列）；进入时把 `_manager` 置 nil；新队列上设置 SQLCipher key，并用 `executeQuery:@"PRAGMA journal_mode=WAL"` + `PRAGMA synchronous=NORMAL` 开启 WAL；同一 uid + prefix 直接复用。
- **对应 Android**: `594ccb2` 的「先捕获目标 helper、延迟 500ms 再关闭」+ `1a48603`/`f193f42` 的 WAL。

### 3.3 DB 文件丢失后核心表缺失崩溃（`no such table: message`）
- **文件**: `WuKongIMSDK/Classes/db/WKDB.m`（`migrateDatabase`、新增 `checkCoreTables`）
- **问题**: `migrateDatabase` 只跑一次迁移，且忽略 `_manager == nil` 与返回值，只看 `error`。当 DB 文件被删除/损坏、但 `schema_migrations` 仍记录「已迁移」时，核心表不会被重建，运行时报 `no such table: message`（Android 同款问题）。
- **改动**: 迁移后校验 `message`/`conversation`/`channel` 三张核心表是否存在；缺失则 `DELETE FROM schema_migrations` 并（容忍错误地）重跑建表 SQL，再次校验；`_manager` 为空直接返回失败。
- **对应 Android**: `11af5e9`（`maxIndex=0` 从头跑 + 每条 SQL 单独 try-catch）。

### 3.4 DB 队列关闭后仍被调用
- **文件**: `WuKongIMSDK/Classes/db/WKFMDatabaseQueue.m`
- **问题**: `close` 之后 `inDatabase:`/`inTransaction:` 仍会进入已关闭的 `FMDatabaseQueue`；SQLCipher 关闭连接后再访问游标会崩溃。原类也没有任何「已关闭」判断。
- **改动**: 新增原子标志 `closed`；`inDatabase:`/`inTransaction:` 入口 `if(self.closed) { return; }`；`close` 幂等（重复调用/allocation 后调用都安全）。
- **对应 Android**: `594ccb2` 的 `WKDBHelper.isClosed` 入口短路；`bdc02e2`（SQLCipher 关闭后 cursor 崩）。

### 3.5 迁移 bundle 缺失时静默成功、不建任何表
- **文件**: `WuKongIMSDK/Classes/db/WKDBMigrationManager.m`（`migrateDatabaseToVersion:bundle:error:`）
- **问题**: `if(!_migrationsBundle) [NSException exceptionWithName:...];` —— 只**创建**了异常对象却没有 `@throw`；而且判断的是实例变量 `_migrationsBundle`（此时恒为 nil）而不是入参，真正的赋值在判断之后。于是 bundle 缺失时迁移直接「成功」返回，所有表都不创建，问题被完全掩盖。
- **改动**: 判断入参 `migrationsBundle`；为空则返回 `NSError`（domain `WKDBMigrationManagerErrorDomain`）并 `return NO`；之后才赋值给 `_migrationsBundle`。
- **对应 Android**: `11af5e9` 同类「迁移失败被吞」。

### 3.6 迁移整体执行失败即整条回滚
- **文件**: `WuKongIMSDK/Classes/db/WKDBMigrationManager.m`（`WKDBFileMigration migrateDatabase:error:`）
- **问题**: 用 `[database executeStatements:self.SQL]` 整体执行，任意一条失败整条迁移就中止。在已有表结构上重跑（3.3 的修复场景）时，`CREATE TABLE`/`ALTER TABLE` 因对象已存在而失败，后续 SQL 全部不执行。
- **改动**: 先整体 `executeStatements`，成功即返回；失败回退到新方法 `executeStatementsToleratingErrors:`（按语句执行，错误信息含 `already exists` 或 `duplicate column name` 则跳过）。新增 `splitSQLStatements` 拆分 SQL，尊重 `-- +migrate StatementBegin/End` 以保护 `CREATE TRIGGER` 内部的分号。
- **对应 Android**: `11af5e9` 的「每条 SQL 单独 try-catch 跳过」。

### 3.7 补齐复合索引
- **文件**: `WuKongIMSDK/Assets/Migrations/202604150900.sql`（新增）
- **改动**: 移植 Android `202604150900.sql` 的索引：`idx_msg_message_id`、`idx_msg_channel_order(channel_id,channel_type,order_seq)`、`idx_msg_channel_seq(channel_id,channel_type,message_seq)`、`idx_reminders_channel_done(channel_id,channel_type,done)`、`idx_msg_flame(flame,is_deleted)`。全部 `IF NOT EXISTS`，其中 `idx_message_id` 已在 baseline 存在，幂等。
- **对应 Android**: `5b69519`（补 5 个索引）+ `wkim/src/main/assets/wk_sql/202604150900.sql`。

---

## Round 4 — 心跳线程安全 / 主线程 DB / 日志性能（2026-10-09）

> 背景：对应 Android 的并发安全提交 `2585602`（Handler 初始化/线程安全计数器/volatile 可见性）、`fac8ec7`/`68d3e6f`（DB 操作移至后台线程修 ANR）、`4151c42`（非 debug 跳过 getStackTrace 修 ANR）。iOS 这里没有 Android 那套 Handler/线程池，主要问题是 NSTimer 的跨线程创建/销毁和主线程同步读库。

### 4.1 心跳定时器跨线程竞态
- **文件**: `WuKongIMSDK/Classes/manager/WKConnectionManager.m`（`startHeartbeat`、`stopHeartbeat`）
- **问题**: `startHeartbeat` 先在调用线程 `invalidate` 旧 timer，再 `dispatch_async` 到主线程才赋值新 timer；而 `stopHeartbeat` 在调用线程（socket 队列/socketDidDisconnect、网络监听回调）直接 `[self.heartTimer invalidate]`。当 `stopHeartbeat` 在「`dispatch` 已入队但主线程 block 尚未执行」时先跑，它 invalidate 到的是 nil，随后主线程 block 又创建了一个**永不失效**的 timer——表现为连接断开后心跳仍在跑、并可能误触发重连。
- **改动**: `startHeartbeat` 与 `stopHeartbeat` 都 `dispatch_async` 到**同一个主队列串行**执行：start 在主队列内先 `invalidate` 再创建并赋值；stop 在主队列内 `invalidate` 并置 nil。用 `[NSTimer timerWithTimeInterval:...]` + `[[NSRunLoop mainRunLoop] addTimer:forMode:NSRunLoopCommonModes]` 替代 `scheduledTimerWithTimeInterval:`，避免列表滚动（tracking mode）时心跳不触发被误判为断线。
- **对应 Android**: `2585602`（并发安全问题修复）。

### 4.2 心跳读取的最后消息时间可见性
- **文件**: `WuKongIMSDK/Classes/manager/WKConnectionManager.m`（`lastMsgTimeInterval` 属性）
- **问题**: `lastMsgTimeInterval` 由 socket 队列（`handlePacketData:`）写、主线程（`checkAndSendHeartbeat`）读，原为 `nonatomic`，跨线程读存在可见性/撕裂风险。
- **改动**: 改为 `atomic`。
- **对应 Android**: `2585602` 的 volatile 可见性修复。

### 4.3 主线程同步读 DB 造成 ANR
- **文件**: `WuKongIMSDK/Classes/manager/WKChatManager.m`（`pullMessages:startOrderSeq:...maxExecCount:complete:`）
- **问题**: 拉取历史消息的公开 API 一旦在主线程调用，会**同步**执行 `getLocalMessages`（读 message）、`completePullMessages:` → `fillReaction:`（读 reaction）、`fillReplyRevoke:`（读 message）等多次 DB 查询，消息量大时直接阻塞主线程卡 UI/ANR。
- **改动**: 方法入口判断 `[NSThread isMainThread]`：主线程调用时把整个「查库 + 补全」过程放到 `dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0)`，`complete` 回调再 `dispatch_async` 回主线程；内部调用（socket 队列的离线拉取、递归重试）不在主线程，保持原有回调线程语义不变。所有公开入口（`pullLastMessages:`/`pullDown:`/`pullMessages:...`）最终都汇入该方法，因此一处生效。
- **对应 Android**: `fac8ec7`（logoutChat DB 操作移至后台线程）、`68d3e6f`（DB 写入移至后台线程）。

### 4.4 traceDBLog 的 callStackSymbols 性能开销
- **文件**: `WuKongIMSDK/Classes/db/WKFMDatabaseQueue.m`（`inDatabase:`、`inTransaction:`）
- **问题**: `traceDBLog` 打开后每次 DB 调用都会执行 `[NSThread callStackSymbols]`（符号化，代价极高）并 `NSLog`，release 下会拖慢所有 DB 操作、可能触发 ANR。
- **改动**: 仅当 `[WKSDK shared].isDebug` 时才采集完整调用栈；release 只打印类名 + 方法名。
- **对应 Android**: `4151c42`（`WKLoggerUtils.getFunctionName` 非 debug 跳过 getStackTrace）。

---

## 待办（后续轮次）
- Round 5: OOM（图片尺寸读取/解码降采样 `CGImageSourceCreateThumbnailAtIndex` + `kCGImageSourceThumbnailMaxPixelSize`，对应 Android `16c6ca8`/`9c7878d`/`151e946`；时间格式化 formatter 缓存，对应 Android `16f46f9` DateUtils 改 ThreadLocal）。
- Round 6: 功能补齐（typing/输入中、频道状态、群成员同步、提醒缓存、信令）。
