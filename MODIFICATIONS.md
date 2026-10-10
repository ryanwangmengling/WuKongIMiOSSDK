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

## Round 5 — 图片 OOM 与 formatter 缓存（2026-10-09）

> 背景：对应 Android 的图片 OOM 修复 `9c7878d`/`151e946`（「改进图片尺寸获取方式防止OOM，使用 BitmapFactory.Options 替代直接解码」）、`16c6ca8`（同批次稳定性优化），以及 `16f46f9`（`DateUtils.time2DateStr` 改 `ThreadLocal<SimpleDateFormat>` 修 Bugly#35089/#35070 OOM）。
> iOS 侧对应的问题是：**整图解码**（`[UIImage imageWithData:]` / `imageWithContentsOfFile:`），以及在**原图全分辨率**上反复做 JPEG 压缩；另有每条消息反序列化都 new 一个 `NSDateFormatter`。

### 5.1 新增 WKImageUtil（ImageIO 内存友好图片工具，新文件）
- **文件**: `WuKongIMSDK/Classes/utils/WKImageUtil.h` / `.m`（新增）
- **问题**: Android 有 `BitmapFactory.Options.inJustDecodeBounds`（只读尺寸）和 `inSampleSize`（解码阶段采样），iOS SDK 里没有等价封装，导致各处只能整图解码。
- **改动**: 新增 `WKImageUtil`，用 ImageIO 提供：
  - `imageSizeWithData:` / `imageSizeWithFile:`：`CGImageSourceCopyPropertiesAtIndex` 只读像素尺寸，**不解码**（等价 `inJustDecodeBounds`，并处理 EXIF 方向 >= 5 的宽高互换）。
  - `downsampleImageWithData:maxPixelSize:` / `downsampleImageWithFile:...`：`CGImageSourceCreateThumbnailAtIndex` + `kCGImageSourceThumbnailMaxPixelSize`，解码阶段只产生目标尺寸位图（等价 `inSampleSize`）。
  - `downsampleImage:maxPixelSize:`：对已在内存的 UIImage 用 `UIGraphicsBeginImageContextWithOptions(..., 1.0)` 降采样。
  - `compressImage:toMaxBytes:` / `compressImageData:toMaxBytes:`：先降采样再质量二分压缩到 `options.imageMaxBytes`。
- **对应 Android**: `9c7878d` / `151e946`（`BitmapFactory.Options` 替代直接解码）。

### 5.2 缩略图生成不再整图解码 + 全分辨率反复压缩（OOM 主因）
- **文件**: `WuKongIMSDK/Classes/model/content/WKImageContent.m`（`writeDataToLocalPath`、原 `compressImageSize:toByte:`）
- **问题**: 原 `compressImageSize:toByte:` 先在**原图全分辨率**上 `UIImageJPEGRepresentation`，再最多 6 次二分压缩，仍不满足时用 `UIGraphicsBeginImageContext` 在全尺寸上缩放——大图（相机原图）会同时存在多张全尺寸位图/压缩缓冲，是 iOS 端图片 OOM 的主要来源。data 分支更是直接 `[UIImage imageWithData:self.data]` 整图解码。
- **改动**: 压缩逻辑收敛到 `WKImageUtil`：
  - `orgImage` 分支 → `[WKImageUtil compressImage:self.orgImage toMaxBytes:...]`，进入二分前先按 `defaultMaxPixelSize`（1600px）降采样。
  - `data` 分支 → `[WKImageUtil compressImageData:...]`，用 ImageIO 采样解码，**全程不产生全分辨率位图**。
  - 保留原有「质量 1 已满足大小则直接返回」的快路径与小图行为。
- **对应 Android**: `9c7878d` / `151e946`。

### 5.3 thumbnailImage 降采样解码
- **文件**: `WuKongIMSDK/Classes/model/content/WKImageContent.m`（`thumbnailImage`）
- **问题**: 原实现 `[UIImage imageWithContentsOfFile:[self thumbPath]]` 按缩略图文件的原始分辨率整图解码，文件异常偏大时顶高内存峰值。
- **改动**: 改为 `[WKImageUtil downsampleImageWithFile:... maxPixelSize:defaultMaxPixelSize]`；ImageIO 解不了时退回原逻辑，保证可用性。
- **对应 Android**: `9c7878d` / `151e946`。

### 5.4 图片尺寸读取不解码
- **文件**: `WuKongIMSDK/Classes/model/content/WKImageContent.m`（`writeDataToLocalPath` 的 data 分支）
- **问题**: 调用方用 `initWithData:width:height:` 但宽高传 0 时，过去没有兜底，SDK 不会补尺寸（等于要调用方自己解码）。
- **改动**: 当 `width<=0 || height<=0` 时用 `[WKImageUtil imageSizeWithData:self.data]` 只读尺寸补全，不解码整图。
- **对应 Android**: `151e946`（`inJustDecodeBounds` 只获取图片信息，不加载到内存）。

### 5.5 NSDateFormatter 每行 new → 每线程缓存
- **文件**: `WuKongIMSDK/Classes/db/WKMessageDB.m`（`dateFromString:`）
- **问题**: 历史消息/群成员分页反序列化时每行都执行 `dateFromString:`，原实现每次都 `[[NSDateFormatter alloc] init]`（每个约 2~3KB），100 行就是约 100 个瞬时分配，堆压力明显（对应 Bugly#35089/#35070）。
- **改动**: 新增 `+ wk_dateFormatter`，用 `NSThread.currentThread.threadDictionary` 做每线程缓存（等价 Android 的 `ThreadLocal<SimpleDateFormat>`；`NSDateFormatter` 非线程安全，不能简单的 static 共享），分配次数从 O(行数) 降到 O(线程数)；空字符串直接返回 nil。
- **对应 Android**: `16f46f9`。

### 验证
- Example 目录 `pod install`（新文件 `WKImageUtil.h/.m` 需进 Pods 工程）后
  `xcodebuild -workspace WuKongIMSDK.xcworkspace -scheme WuKongIMSDK -sdk iphoneos -configuration Debug -derivedDataPath /tmp/wkdd_r5 CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build` → **BUILD SUCCEEDED**（`BUILD_EXIT=0`）。

### 已知未处理（后续可评估）
- `WKImageContent.writeDataToLocalPath` 的 `orgImage` 分支仍用 `UIImagePNGRepresentation` 把原图写成 **PNG**（无损、体积与编码内存峰值都大）；改成 JPEG 或直接沿用调用方文件会改变上传内容格式，属行为变更，本轮未动。
- `originalImage` 仍是整图解码，这是「原图」的 API 语义；建议 App 侧预览/列表改用 `WKImageUtil downsampleImageWithFile:maxPixelSize:`。

---

## Round 6 — 防御性补丁：空列表非法 SQL / 发送入口参数校验（2026-10-09）

> 背景：本轮原计划做「功能补齐」，勘察后发现 Android 的 typing/频道状态并不是 SDK 内置能力（`WKCMDKeys.wk_typing` 只是常量，`WKChannelState` 只是 `WKSyncChat.channel_status` 的字段声明、全库无消费；`3904ad5`「新增频道状态」实质只是加字段并恢复被注释的 reaction 查询），iOS 的 `WKCMDManager` 本就只做 cmd 转发，因此这类能力属于 App 层，不适合作为 SDK 补丁。提醒项内存缓存（Android `e91952f`）是真功能，但 iOS 有大量直接读 `WKReminderDB` 的调用点，只给 manager 加缓存会与直读不一致，推迟到后续轮次。本轮改为移植 Android 的两个纯防御性修复：空列表拼出非法 SQL、发送/重发入口的空指针。

### 6.1 空列表不再拼出非法 SQL `IN ()`
- **文件**: `WuKongIMSDK/Classes/db/WKMessageDB.m`（`getMessagesWithMessageIDs:`、`deleteMessagesWithClientSeqs:`、`deleteMessagesWithMessageIDs:db:`）、`WuKongIMSDK/Classes/db/WKReminderDB.m`（`getReminders:`）
- **问题**: 调用方传入空数组（或 nil）时，`[ids componentsJoinedByString:@","]` 会拼出 `IN ()` / `IN (null)` 这类非法 SQL，Android 对应问题见 Bugly#30010（`SQLiteException`）。iOS 同样会抛出 SQLite 错误并让整个查询失败。
- **改动**: 四个方法入口补空值短路：
  - `WKMessageDB.getMessagesWithMessageIDs:` → `if(!messageIDs || messageIDs.count == 0) return @[];`
  - `WKMessageDB.deleteMessagesWithClientSeqs:` → `if(!ids || ids.count == 0) return;`
  - `WKMessageDB.deleteMessagesWithMessageIDs:db:`：原写法 `if(messageIDs && messageIDs.count==0)` 只判了空数组、**没判 nil**（nil 会继续往下拼 `IN (null)`），改为 `if(!messageIDs || messageIDs.count == 0) return;`
  - `WKReminderDB.getReminders:` → `if(!ids || ids.count == 0) return @[];`
- **对应 Android**: `fa953e3`（「防御空列表生成非法SQL IN ()导致SQLiteException(Bugly#30010)」，在 `ConversationDbManager.queryWithChannelIds`/`queryWithExtraChannelIds`/`MsgDbManager.queryWithMsgIds` 入口判空）。
- **说明**: iOS 其余 `IN (%@)` 站点（`WKReactionDB.m:40`、`WKRobotDB.m:42/61`、`WKChannelMemberDB.m:257/276`、`WKCMDDB.m:118`、`WKConversationDB.m:259`、`WKReminderDB.m:125`、`WKMessageDB.m:452/473/484/915`）此前已自带判空，无需改动；已知调用点在调用侧也做了判空（`WKPinnedMessageManager.m:47-56`、`WKChatManager.m:1800-1806`），但按 Android 的做法在 DB 层兜底更稳妥。

### 6.2 发送/重发入口参数校验
- **文件**: `WuKongIMSDK/Classes/manager/WKChatManager.m`（`sendMessage:content:channel:setting:clientMsgNo:topic:` :77，其余重载都汇入它；`resendMessage:` :94）
- **问题**: Android `202d1f6` 修的是重发消息时 `channelId` 或 `clientMsgNo` 为 null 导致的 NPE；iOS 是 OC，nil 不会崩溃，但**会用空 channelId 落库并发出脏消息**，后果更隐蔽（消息在本地存在、对端无法正确路由）。
- **改动**: 两个入口都校验关键参数，非法时打 WARN 日志并 `return nil`，不落库、不发送：
  - `sendMessage:...`：`content`/`channel`/`channel.channelId` 为空即忽略。
  - `resendMessage:`：另加 `message`/`message.content`/`clientMsgNo` 校验（与发送入口保持一致）。
- **对应 Android**: `202d1f6`（「修复重发消息时channelId或clientMsgNo为null导致的NPE」，`WKConnection.sendMessage` / `WKProto.getSendBaseMsg` 层判空，iOS 对应点在更早的 `WKChatManager` 入口）。
- **未移植的同类项（复核后判定不需要）**:
  - `6a95caf`（`MsgDbManager.insertOrReplaceExtra` 空指针）：iOS `updateMessageExtra:` 经 `extraToStr:` 已容 nil。
  - `8ec8e49`（`ChannelMembersDbManager.queryCount` cursor null）：iOS `getMemberCount:` 用 FMResultSet，FMDB 不返回 nil。
  - `6d9d6ad`（`getDb()` 空指针 10 处）：Round 3 已在 `WKFMDatabaseQueue` 用 `isClosed` 兜底，等价。

### 验证
- `xcodebuild -workspace WuKongIMSDK.xcworkspace -scheme WuKongIMSDK -sdk iphoneos -configuration Debug -derivedDataPath /tmp/wkdd_r6 CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build` → **BUILD SUCCEEDED**（`BUILD_EXIT=0`）。本轮未新增文件，无需 `pod install`。

### 已知未处理（后续轮次）
- 提醒项内存缓存（Android `e91952f`）：iOS 的 `WKConversationManager`/`WKChatManager` 多处直接读 `WKReminderDB`（`WKConversationManager.m:101/111/197/238/282/308`、`WKChatManager.m:379/709/1547`），加缓存必须同时改这些读路径，否则会读到过期数据。
- `f37a1f5`（closeConnect 关闭旧连接后自动重连形成连接循环）、`842d29e`/`2498c0f`（在线 cmd 未回 ack）仍未移植。

---

## Round 7 — 连接层并发安全加固（2026-10-09）

> 背景：Android `2585602`（2026-04-27「并发安全：Handler初始化、线程安全计数器、volatile可见性」）。iOS 连接层同样存在大量跨线程访问：退避重连在全局队列、socket 回调在 `_imsocketQueue`、网络监听在主队列（R2 引入）、同步完成回调在 App 提供的线程。本轮按 Android 的思路做可见性/原子性加固，并修掉 iOS 独有的 `tempPackets`（临时包）跨线程无锁读写 + 二次处理。

### 7.1 退避重连门闸的 check-then-act 竞态
- **文件**: `WuKongIMSDK/Classes/manager/WKConnectionManager.m`（`backoffReconnect`、`cancelBackoffReconnect`）
- **问题**: 原实现 `if(self.isBackoffReconnect) return;` / `self.isBackoffReconnect = true;` / `self.reconnectGeneration++;` 三段不是原子的，两个线程可同时通过门闸，各自 `dispatch_async` 出一个退避任务 → 重复重连；`reconnectGeneration` 的 `++` 是非原子 read-modify-write，socket 队列与网络线程也会并发送达。
- **改动**: 把「判门闸 + 置位 + generation 自增并取快照」整体放进 `@synchronized (self)`；`cancelBackoffReconnect` 的 `reconnectGeneration++` 与 `isBackoffReconnect = false` 同样加锁。
- **对应 Android**: `2585602`（`WKConnection.isReConnecting` 加 `volatile`；`ConnectionClient.timeoutRetryCount` 由 `int` 改 `AtomicInteger`，并用 `incrementAndGet()` 的返回值做判断）。

### 7.2 跨线程共享标志/计数器改为 atomic
- **文件**: `WuKongIMSDK/Classes/manager/WKConnectionManager.m`（类扩展属性声明）
- **问题**: `forceDisconnect`、`reconnectCount`、`isBackoffReconnect`、`reconnectGeneration`、`addrRetryCount`、`networkAvailable`、`networkMonitorStarted`、`pullOfflineFinished` 分别在「连接锁内 / socket 队列 / 全局队列 / 网络监听主队列 / 同步完成回调线程」读写，`nonatomic` 没有内存屏障，弱内存模型下可能读到旧值。典型后果：网络已恢复但退避任务仍读到 `networkAvailable == NO` 而放弃重连；或断连时读到 `forceDisconnect == NO` 触发多余重连。
- **改动**: 上列属性全部由 `nonatomic` 改 `atomic`（`lastMsgTimeInterval` 已在 R4 改 atomic）。
- **对应 Android**: `2585602` 的 `volatile`（`WKConnection.isReConnecting`、`WKDBHelper.uid`）与 `AtomicInteger`。

### 7.3 临时包 tempPackets 跨线程无锁读写 + 二次处理（iOS 独有，崩溃风险）
- **文件**: `WuKongIMSDK/Classes/manager/WKConnectionManager.m`（`finishedSyncConversation`、`finishedPullOffline`、`handlePacketData:`，新增 `appendTempPackets:` / `drainTempPackets`）
- **问题**:
  1. `pullOfflineFinished == NO` 期间，在线包在 socket 队列执行 `[self.tempPackets addObjectsFromArray:]`；而 `syncConversations:` 的完成块会在 **App 提供的线程**（网络回调线程）调用 `finishedSyncConversation` → `[self handlePackets:self.tempPackets]`。两个线程同时对同一个 `NSMutableArray` 读写、无任何锁，迭代中被 mutate 可能崩溃或丢包。
  2. `finishedSyncConversation` 处理完临时包后**不清空**数组；随后 socket 队列下一批包到达时会再次 drain 并把这批包再处理一遍 → 消息重复入库、重复回调。
- **改动**:
  - 新增 `tempPacketsLock`（`NSLock`，在 `sharedManager` 初始化）；新增 `appendTempPackets:` 与 `drainTempPackets`（取出即清空）两个方法，所有 append/取出均加锁。
  - `finishedSyncConversation` / `finishedPullOffline` 改为「先 drain（取出即清空）再 handle」，清空后不会被二次处理。
  - `handlePacketData:` 的 drain 分支改用 `drainTempPackets` 并重新拼装数组，保持「临时包在前、当前包在后」的原有处理顺序。
- **对应 Android**: 无直接对应（Android 离线同步模型不同），属 iOS 侧自查发现的线程错配；处理思路与 `2585602` 一致。

### 验证
- `xcodebuild -workspace WuKongIMSDK.xcworkspace -scheme WuKongIMSDK -sdk iphoneos -configuration Debug -derivedDataPath /tmp/wkdd_r7 CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build` → **BUILD SUCCEEDED**（`BUILD_EXIT=0`）。本轮未新增文件，无需 `pod install`。

### 已知未处理（后续轮次）
- `68d3e6f` / `d005ce6`（Android `MsgManager`：同步频道消息的 DB 写入移至后台线程 + 删除冗余 `queryWithMsgIds`，Bugly#30231 OOM）。
- `8c3cf3e`（收到消息先验证合法性再解码，`WKProto.java` / `CryptoUtils.java`）。
- 提醒项内存缓存（`e91952f`）：同 R6，需同时改所有直读 `WKReminderDB` 的路径。

---

## Round 8 — 连接句柄并发安全（socket 引用加锁）（2026-10-09）

> 背景：Android `dccdc56`（「修改连接anr问题」）与 `16c6ca8` 的连接管理规则（连接引用的访问统一放到 `connectionLock` 内，先取局部 `currentConnection` 再判空/使用）。iOS 侧原来的互斥写法是 `@synchronized (self.ssocket)`，存在三个问题：(1) `ssocket` 为 nil 时 `@synchronized(nil)` 是**空操作**，等于没有加锁；(2) 锁对象本身会被替换（`connectSocket:` 新建、`onlyConnect` 置空），不同线程可能锁在不同的对象上，互斥失效；(3) `writeData:` 完全无锁读取 `ssocket`。

### 8.1 引入稳定的 socketLock，socket 引用读写全部加锁
- **文件**: `WuKongIMSDK/Classes/manager/WKConnectionManager.m`（新增 `socketLock` 属性与懒加载 getter；`onlyConnect`、`connectSocket:port:`、`disconnect:`、`logout`、`writeData:`）
- **问题**: 多个线程会并发读写 `self.ssocket`：socket 队列（`didConnectToHost`/`didWriteDataWithTag`/`didReadData`）、全局队列（退避重连 → `reconnect` → `onlyConnect`）、主线程（网络恢复回调）、以及 App 线程（`sendPacket:` → `writeData:`）。并发下可能出现：对已 disconnect/已替换的旧 socket 写数据（消息静默丢失）、`onlyConnect` 的「判状态 + 替换 socket」被另一线程穿插。
- **改动**:
  - 新增 `@property(nonatomic,strong) NSRecursiveLock *socketLock;` 与懒加载 `- (NSRecursiveLock *)socketLock`。用可重入锁是因为 `onlyConnect` 在锁内会调用 `changeConnectStatus:` 触发连接状态回调，回调可能重入，需与原来对象锁（可重入）语义一致。
  - `onlyConnect`：用 `socketLock` 替换 `@synchronized (self.ssocket)`；持锁完成「已连接/连接中的短路判断 + 状态切换 + 释放旧 socket」，随后**在锁外**调用 `loopGetAddrToConnect`（`connectSocket:` 内部同样要加锁，留在锁内会自锁）。
  - `connectSocket:port:`：新建 socket、赋值 `self.ssocket`、`connectToHost:` 在锁内；`error` 分支保持在锁外。
  - `disconnect:` / `logout`：锁内取局部 `socket` 引用，锁外 `[socket disconnect]`，避免并发被替换/置空后再用旧 socket。
  - `writeData:`：补 `data` 的 nil 短路；锁内取局部引用，锁外 `writeData:withTimeout:tag:`。
- **对应 Android**: `dccdc56`（`WKConnection.sendMessage` / `connectionIsNull` / `closeConnect` 中 `synchronized (connectionLock)`，先取 `currentConnection` 再判空/使用）。

### 8.2 过期 socket 的断连回调不再误判为「当前连接断开」
- **文件**: `WuKongIMSDK/Classes/manager/WKConnectionManager.m`（`socketDidDisconnect:withError:`）
- **问题**: 替换 socket 后，旧 socket 的 `socketDidDisconnect:` 仍会回调。原实现无条件把状态置 `WKDisconnected`、停心跳并 `backoffReconnect`，于是旧 socket 的断开会把刚建立的新连接误判为断开，触发多余重连与状态抖动（对应 Android `dccdc56` 想解决的连接状态错乱/卡死）。
- **改动**: 锁内比较 `sock == self.ssocket`；只有当前 socket 才置空 `self.ssocket` 并继续原有断开处理（状态、心跳、退避重连）；否则按 debug 日志提示「忽略已过期的旧连接断开」并直接 `return`。
- **对应 Android**: `dccdc56`（`closeConnect` 先在锁内取 `connectionToCloseActual` 再处理）+ `ConnectionClient.onDisconnect` 里基于 attachment（`"close..."`）区分主动关闭与真断开。

### 验证
- `xcodebuild -workspace WuKongIMSDK.xcworkspace -scheme WuKongIMSDK -sdk iphoneos -configuration Debug -derivedDataPath /tmp/wkdd_r8 CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build` → **BUILD SUCCEEDED**（`BUILD_EXIT=0`）。本轮未新增文件，无需 `pod install`。

### 已知未处理（后续轮次）
- `68d3e6f` / `d005ce6`（Android `MsgManager`：同步频道消息的 DB 写入移至后台线程 + 删除冗余 `queryWithMsgIds`，Bugly#30231 OOM）：iOS 需改 `WKChatManager` 的 `calSync:`/`calSyncForForce:`/`pullMessages:` 回调线程，会改变 `complete` 回调线程语义，风险大，推迟。
- 提醒项内存缓存（`e91952f`）：同 R6，需同时改所有直读 `WKReminderDB` 的路径。
- `275ebfb` / `305124a`（Android 连接/定时器大重构，引入 `TimerManager`/`TimerTasks`/`NetworkChecker`）：属架构级重写，明显不能作为单点补丁移植。

---

## Round 9 — 缓存 / 频道管理器并发安全（2026-10-09）

> 背景：Android `35b2d6c`「修改获取频道资料卡的问题」把 `ChannelManager.wkChannelList` 从 `Collections.synchronizedList(new ArrayList<>())` 换成 `CopyOnWriteArrayList`（并发遍历/修改导致的问题），顺便把 `ConversationManager` 的 `saveSyncChat` 从 `new Thread()` 换成 `DispatchQueuePool(3)`；`2585602` 修过「Handler 初始化」等并发安全问题。iOS 侧同类问题集中在缓存与频道管理器：`WKMemoryCache` 完全无锁、`WKChannelManager.fetchChannelInfo:` 的 check-then-act 竞态、以及一批惰性锁 getter 的并发初始化。

### 9.1 WKMemoryCache 全面加锁
- **文件**: `WuKongIMSDK/Classes/utils/WKMemoryCache.m`
- **问题**: `cacheDictonary`（`NSMutableDictionary`）与 `cacheArray`（`NSMutableArray`）没有任何同步。该缓存被 `WKChannelManager` 用作频道成员内存缓存（`channelMemberCache`，`maxCacheNum=100000`），读写点分布在主线程 / socket 队列 / DB 回调 / App 线程。并发 `setCache:`/`getCache:` 会崩在 CFDictionary/CFArray 内部；`cleanCache` 里遍历 `cacheArray` 时若有并发 `setCache:` 也会崩。
- **改动**:
  - 新增 `NSRecursiveLock *lock`（懒加载）；`setCache:forKey:`、`getCache:` 全部进锁。
  - 清理逻辑拆出 `cleanCacheLocked`（调用方已持锁），`setCache:` 在锁内调用它；对外保留 `cleanCache` 作为自加锁入口。
  - `key` 为 nil 直接短路（原实现会把 nil 加进 `cacheArray` 而崩溃）。
- **对应 Android**: `35b2d6c`（线程安全集合）+ `2585602`（并发安全）。

### 9.2 频道资料请求的 check-then-act 竞态 + 锁外追加
- **文件**: `WuKongIMSDK/Classes/manager/WKChannelManager.m`（`fetchChannelInfo:completion:`）
- **问题**:
  1. 原实现「锁内读 `channelReqeusts[key]` → **锁外** `addObject:` → 再锁内写回」。两个并发请求可能都读到 nil，各自新建数组并互相覆盖：先到者的 completion **永远不被回调**，后到者还会多发一次 `channelInfoUpdate` 请求。
  2. 锁外 `[blockArray addObject:]` 与回调线程的 `removeObjectForKey:` / 遍历并发，会破坏 `NSMutableArray`（崩溃或丢回调）。
- **改动**: 把「判重 + 追加 / 新建并登记」整体放进同一把 `channelReqeustLock`；重复请求在锁内追加后返回 nil；新请求在锁内登记后再发起 `channelInfoUpdate`。
- **对应 Android**: `35b2d6c`（`ChannelManager.wkChannelList` 改线程安全集合）。

### 9.3 惰性锁 / 字典 getter 的并发初始化竞态
- **文件**: `WuKongIMSDK/Classes/manager/WKChannelManager.m`（`channelReqeusts`、`channelReqeustLock`、`cacheDict`、`cacheDictLock`、`delegateLock`、`delegates` 六个懒加载 getter）
- **问题**: 两个线程同时首次访问时可能各创建一个锁对象，导致一个线程持 A 锁、另一个持 B 锁，互斥完全失效；字典同理（后者覆盖前者，前者的写入丢失）。
- **改动**: 初始化整体放进 `@synchronized(self)`（`self` 是单例，锁稳定且可重入）。
- **对应 Android**: `2585602`（「并发安全问题，包括 Handler 初始化、线程安全计数器、volatile 可见性」）。

### 验证
- `xcodebuild -workspace WuKongIMSDK.xcworkspace -scheme WuKongIMSDK -sdk iphoneos -configuration Debug -derivedDataPath /tmp/wkdd_r9 CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build` → **BUILD SUCCEEDED**（`BUILD_EXIT=0`）。本轮未新增文件，无需 `pod install`。

### 本轮甄别后判定「不移植」
- `35b2d6c` 的 `ConversationManager` 用 `DispatchQueuePool(3)` 替换 `new Thread()`：iOS 的同步会话已走全局队列/`dispatch_after`，不存在「每条消息新建线程」的问题。
- `35b2d6c` 的「解密放在 msgKey 校验之后」：iOS `WKRecvPacket.m:60-66` 已先校验再解密（同 R8 对 `8c3cf3e` 的结论）。
- `b220233`（同步群成员时不再 `deleteWithChannel` 清库）：iOS `addOrUpdateMembers:` 只清内存缓存、DB 走 upsert，无清库行为。

---

## Round 10 — 提醒项内存缓存 + 提醒管理器健壮性（2026-10-09）

> 背景：Android `e91952f`「新增获取提醒项内存缓存」是为了修一个 ANR —— 堆栈是
> `SQLiteConnectionPool` ← `ReminderDBManager.queryWithChannelAndDone()` ← `WKUIConversationMsg.getReminderList()` ← `ChatFragment.onRefresh()`，
> 即在主线程直接查 SQLCipher。Android 的解法是在 `ReminderManager` 加一层按频道的提醒项内存缓存，并在退出登录时清空。iOS 的对应点是 `WKReminderManager`。

### 10.1 新增提醒项内存缓存（对应 Android e91952f）
- **文件**: `WuKongIMSDK/Classes/manager/WKReminderManager.h` / `.m`
- **问题**: `getReminders:(WKReminderType)reminderType channel:` 每次都直接 `[[WKReminderDB shared] getWaitDoneReminders:channel type:]`。UI 层会在主线程频繁调用它（与 Android 同一路径），每次都是一次 SQLCipher 查询，是提醒列表卡顿 / ANR 的来源。
- **改动**:
  - 新增 `WKMemoryCache *reminderCache`（`maxCacheNum = 2000`，复用 Round 9 已加锁的 `WKMemoryCache`）。
  - 缓存 key = `channelId_channelType_type`（提醒类型不同查询结果不同，必须分开存）。
  - 命中直接返回；未命中查库后**存副本**再返回，避免调用方与缓存互相影响。
  - 失效：`sync`（`addOrUpdates:` 之后）与 `done:`（`updateDone:` 之后）用本次变更的 `reminders` 逐条按 `(channel,type)` 精确失效 —— 不需要枚举所有类型，也就不会因为新增提醒类型而漏失效。
  - 新增 `-(void) clearCache`；`WKConnectionManager.logout` 中调用，防止退出登录/切换账号后读到上个账号的提醒项。
- **对应 Android**: `e91952f`（ReminderManager 内存缓存 + ConnectionManager.logout 里的 `clearAllCache`）。

### 10.2 WKMemoryCache 新增 removeAll
- **文件**: `WuKongIMSDK/Classes/utils/WKMemoryCache.h` / `.m`
- Round 9 已让 `setCache:nil forKey:nil` 短路，因此不能用它清空缓存；新增加锁的 `-(void) removeAll`（同时清 `cacheDictonary` 与 `cacheArray`），供 `WKReminderManager.clearCache` 使用。

### 10.3 提醒管理器健壮性
- **文件**: `WuKongIMSDK/Classes/manager/WKReminderManager.m`
- `delegateLock` / `delegates` / `reminderCache` 三个惰性 getter 加 `@synchronized(self)`：避免并发首次初始化各建一个对象导致互斥失效（延续 Round 8 / 9）。
- `addDelegate:` / `removeDelegate:` 的参数类型原写成 `id<WKReactionManagerDelegate>`（从 `WKReactionManager` 复制粘贴留下的错误），改为头文件声明的 `id<WKReminderManagerDelegate>`。

### 验证
- `xcodebuild -workspace WuKongIMSDK.xcworkspace -scheme WuKongIMSDK -sdk iphoneos -configuration Debug -derivedDataPath /tmp/wkdd_r10 CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build` → **BUILD SUCCEEDED**（`BUILD_EXIT=0`）。本轮未新增文件，无需 `pod install`。

### 本轮甄别后判定「不移植」
- `ce924cd`（优化同步最近会话）：核心是把逐条 `setOnRefreshMsg(msg, isEnd)` 改成批量 `setOnRefreshMsg(list)`。iOS `WKConversationManager` 早就是批量回调 `callOnConversationUpdateDelegates:(NSArray<WKConversation*>*)`，**N/A**；其中「同步会话每批 20→10」是 Android provider 侧参数，iOS 的批量大小由 App 提供的 `syncConversationProvider` 决定。
- `8ec8e49`（ChannelMembersDbManager.queryCount cursor NPE）、`6a95caf`/`6d9d6ad`（getDb() 空指针）：ObjC 对 nil 发消息天然安全 —— iOS 用 `resultSet.next` / `[resultSet close]`，`resultSet == nil` 时不会崩；DB 生命周期防御已在 Round 3 / 4 覆盖。
- `b1447cb`（logoutChat closeDbHelper 延迟 500ms）：iOS 的 DB 关闭竞态已在 Round 3（`switchDB` 关/开竞态、关闭后仍被调用）覆盖。

---

## Round 11 — 同步频道消息回调移出主线程（对应 Android 68d3e6f）（2026-10-09）

> 背景：Android `68d3e6f` 把 `setSyncChannelMsgListener` 回调里的 `saveSyncChannelMSGs`（DB 写入）移到后台线程，commit message 原文：「saveSyncChannelMSGs 在主线程与 DB 线程竞争 SQLCipher 连接池，实测会阻塞主线程触发 ANR……调用方原本就不依赖主线程语义」。iOS 的对应点是 `WKChatManager` 的 `syncChannelMessageProvider` 回调。

### 11.1 问题定位（Round 4 的移植有遗漏）
- `WKChatManager.m:813` `pullMessages:` 入口在 `[NSThread isMainThread]` 时，把整段流程派发到后台队列，再把最外层 `complete` 派发回主线程（Round 4 移植 `fac8ec7`/`68d3e6f` 时加的，`:818-834`），其注释假设「递归不在主线程」。
- 但 `syncChannelMessageProvider` 的回调线程由 App 决定（AFNetworking 等默认回到主队列）。`calSyncForForce:` 原来在回调里直接调用 `complete`（`:1411-1413`），于是 `pullMessages` 的各个 completion（`:1019` / `:1041` / `:1064` / `:1088` 等）就在**主线程**执行 `[[WKMessageDB shared] replaceMessages:...]` 同步写 SQLCipher，并同步递归 `pullMessages` —— 主线程被 DB 阻塞，正是 `68d3e6f` 描述的场景。即 Round 4 只覆盖了「入口在主线程」，漏掉了「provider 回调回到主线程」这条路径。

### 11.2 改动（`WuKongIMSDK/Classes/manager/WKChatManager.m`）
1. 新增串行队列 `syncChannelMessageQueue`（getter 加 `@synchronized(self)` 防并发首次初始化出两个队列）。
2. `calSyncForForce:` 的 provider 回调体整体 `dispatch_async` 到该队列：error / 无消息 / 正常三分支都改在队列内调用 `complete`。写库与后续递归不再占用主线程。
3. `weakSelf` 判空兜底：self 已释放时以原线程直接调用 `complete`，不丢回调。

### 线程语义说明（本轮最大的决策点）
- 该改动把「provider 回调后的收尾」从 App 的回调线程移到 SDK 串行队列，即 App 的 `complete` 可能从主线程变为后台线程。取舍与 Android `68d3e6f` 一致（其 onBack 也一并后移，理由同上）。
- 对**从主线程发起** `pullMessages` 的调用方（UI 上拉/下拉历史）：入口 `:818` 仍会把最外层 `complete` 派发回主线程，语义不变。
- 对**从后台线程发起**、且 provider 回调回到主线程的调用方：`complete` 现在落到后台串行队列；SDK 自身的 delegate 回调本就统一 `dispatch` 到主线程（`callRecvMessagesDelegate:` 等），不受影响。

### 验证
- `xcodebuild -workspace WuKongIMSDK.xcworkspace -scheme WuKongIMSDK -sdk iphoneos -configuration Debug -derivedDataPath /tmp/wkdd_r11 CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build` → **BUILD SUCCEEDED**（`BUILD_EXIT=0`）。本轮未新增文件，无需 `pod install`。

### 已知未处理
- `ackQueue`/`handleMessageQueue`/`sendMessageQueue` 的 getter 仍无锁（沿用上游写法），本次只给新增队列加锁。
- `calSync:` 里对 `getDeleted*MessageSeq` 的查询：provider 回调路径上的这些读操作现在也落在 `syncChannelMessageQueue` 上；主线程入口路径仍由 `:818` 的整体派发覆盖。

---

## Round 12 — 管理器惰性 getter 并发安全普查（对应 Android 2585602）（2026-10-09）

### 12.1 背景
R9/R10 已给 `WKMemoryCache`、`WKChannelManager`、`WKReminderManager` 的惰性 getter 加锁。本轮做一次**全库普查**：把所有「可能被多线程访问的管理器/工具类惰性 getter」统一用 `@synchronized(self)` 保护，避免并发首次访问各建一个实例（后建对象覆盖 ivar，先建对象及其中的委托/缓存/任务全部变成孤儿而丢失）。蓝本 Android `2585602`（并发初始化）。

### 12.2 做法
脚本按「方法声明 + 大括号配对」定位 getter，把 `if(!_x) { _x = [[... alloc] init]; } return _x;` 整段包进 `@synchronized (self) { ... }`。共 **45 处、16 个文件**：

| 文件 | 处数 | getter |
| --- | --- | --- |
| `WKSDK.m` | 10 | messageContentDict、messageContentDictLock、options、connectionManager、chatManager、conversationManager、channelManager、bodyCoderManager、cmdManager、coder |
| `utils/WKMemoryCache.m` | 3 | lock、cacheArray、cacheDictonary |
| `manager/WKCMDManager.m` | 2 | delegateLock、delegates |
| `manager/WKChannelRequestQueue.m` | 3 | requests、requestDict、lock |
| `manager/WKChatManager.m` | 7 | ackQueue、handleMessageQueue、sendMessageQueue、retryMessageDict、delegateLock、delegates、interceptDict |
| `manager/WKConnectionManager.m` | 2 | socketLock（R8 引入，getter 当时漏锁）、delegateLock |
| `manager/WKConversationManager.m` | 2 | delegateLock、delegates |
| `manager/WKMediaManager.m` | 1 | delegateLock |
| `manager/WKMessageQueueManager.m` | 1 | sendPackets |
| `manager/WKPinnedMessageManager.m` | 2 | delegateLock、delegates |
| `manager/WKReactionManager.m` | 2 | delegateLock、delegates |
| `manager/WKReceiptManager.m` | 2 | cachedLock、cacheDict |
| `manager/WKRetryManager.m` | 4 | retryLock、retryDict、messageExtraRetryDict、reminderRetryDict |
| `manager/WKTaskManager.m` | 2 | taskDic、taskLock |
| `manager/task/WKBaseTask.m` | 1 | listenerDic |
| `db/WKChannelMemberDB.m` | 1 | memberLock |

### 12.3 为什么危险（举例）
- `WKConversationManager`/`WKCMDManager`/`WKReactionManager`/`WKPinnedMessageManager` 等的 `delegates` 是 `NSHashTable`：App 常在任意线程 `addDelegate:`，SDK 回调线程同时读；并发首次访问会让其中一份委托表变成孤儿，此后**所有回调都丢**。
- `WKChatManager` 的三条 `dispatch_queue` 若并发首建，ack / 消息处理 / 发送任务会分散到两个队列，**串行语义被破坏**（与 Round 11 的 `syncChannelMessageQueue` 同类问题）。
- `WKRetryManager`/`WKReceiptManager`/`WKTaskManager` 的字典若并发首建，部分重试项/回执/任务会写进孤儿字典、永不被处理。

### 12.4 安全性说明
`@synchronized(self)` 只保护「首次构造」这一段，构造完成后 getter 内部仅读 ivar，开销很小；`@synchronized` 可重入，不会与调用方已持有的原生锁（如 `delegateLock`/`cacheLock`）冲突。本次未改变任何锁的粒度，也未改变既有锁/队列的配对约定。

### 12.5 判定不处理（普查中刻意排除）
- `db/WKChannelMemberDB.m:72 -extra`：`WKChannelMember` 模型对象的数据容器，随对象单线程使用，非共享状态。
- `db/WKDB.m:120 -migrateDatabase`：不是惰性 getter，方法体内 `if(!_manager)` 只是判空；迁移本身在 `FMDatabaseQueue` 串行执行。
- `model/**`、`coder/proto/**` 的惰性 getter（`WKMessage.header/extra`、`WKSendPacket.setting` 等）：模型/协议对象的数据容器，按对象访问。

### 12.6 验证
- `xcodebuild -workspace WuKongIMSDK.xcworkspace -scheme WuKongIMSDK -sdk iphoneos -configuration Debug -derivedDataPath /tmp/wkdd_r12 CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build` → **BUILD SUCCEEDED**（`BUILD_EXIT=0`，0 error）。
- 复查脚本：加锁后全库剩余「未加锁的惰性 getter」仅为上述 2 个刻意排除项（`REMAINING 2`）。本轮未新增文件，无需 `pod install`。

---

## Round 13 — 数据库不可用防御（打开失败 / 迁移修复失败）（对应 Android 6d9d6ad）（2026-10-09）

### 13.1 背景与定位
Android `6d9d6ad`「SDK 全量修复 getDb() 空指针 — 10 处 DB 事务操作统一加空判断」：把 `getDb()` 取到局部变量、null 时跳过事务、`finally` 复用同一个 db 引用（避免 TOCTOU）、`endTransaction` 再包一层 try-catch。

iOS 复核结论：
- **事务内空指针 → 已有防御**：iOS 的 DB 入口是 `[[WKDB sharedDB].dbQueue inDatabase:/inTransaction:]`，`dbQueue` 为 nil 时是 ObjC 对 nil 发消息（no-op）；R3/R4 又给 `WKFMDatabaseQueue` 加了 `closed` 短路（对应 Android `WKDBHelper.isClosed`、`bdc02e2`）。此部分 R3 已覆盖（见本文件 Round 3 / Round 10 章节）。
- **本轮发现的真实缺口**：`closed` 只在 SDK 自己调 `close` 时才为 YES。若 `[FMDatabaseQueue databaseQueueWithPath:]` 打开失败（路径不可写 / 磁盘满 / 文件损坏），FMDB 返回 **nil**，而 `WKDB.switchDB:` 会把它包成空壳 `WKFMDatabaseQueue` 安装到 `self.dbQueue`，同时 `currentUid` 已写入 → 之后 `needSwitchDB:` 永远返回 NO，即使磁盘/文件后来恢复也**永不重试**；并且 `migrateDatabase` 的返回值被忽略，核心表缺失时照样继续使用这个库。

### 13.2 改动
`db/WKFMDatabaseQueue.h` / `.m`
- 新增 `- (BOOL)isReady`：`!self.closed && self.queue != nil`。
- `inDatabase:` / `inTransaction:` 入口判断由 `if(self.closed)` 改为 `if(![self isReady])`：打开失败的空壳队列现在连 `traceDBLog` 都不执行，直接返回（对应 Android「getDb() == null 跳过事务」）。

`db/WKDB.m`
- `switchDB:` 拆出 `openFailed` 分支：`fmdb == nil` 时不安装空壳队列，改为 `dbQueue = nil` + `currentUid/currentDBPrefix = nil`，日志 `[WKDB] 打开数据库失败，数据库暂不可用: <path>`，延迟关闭旧队列后 return。
- 迁移后新增可用性校验：`if(![self checkCoreTables])` → 日志「数据库迁移/修复失败且核心表缺失，暂不启用本连接」→ 锁内（且仅当 `self.dbQueue == newQueue`）卸载队列、清空用户状态、`_manager = nil`、`[newQueue close]`，延迟关闭旧队列后 return。这样下次 `connect` 时 `needSwitchDB:` 返回 YES 可重试；期间所有 DB 访问因 `dbQueue == nil` 安全 no-op。
- 抽出 `- (void)closeOldQueueAsync:newQueue:`（原「延迟 0.5s 关闭旧队列」逻辑，移植 Android 594ccb2），三处调用复用。
- `createMigrationsTable`：队列不存在或 `!isReady` 时显式 `_manager = nil` 并返回 —— 修复「队列不可用却沿用上一次 `_manager`（持有上一个用户 / 已关闭的 FMDatabase）」；改用局部 `__block mgr` 收集，块结束后再赋给 `_manager`；块内加 `if(!db) return;`。
- `checkCoreTables`：`if(!queue || ![queue isReady]) return NO;`。

### 13.3 为什么不误伤正常路径
- 首次建库：`migrateDatabase` 先建 `schema_migrations`，再跑 Migrations 资源里的 SQL；`message/conversation/channel` 建好后 `checkCoreTables` 为 YES，走原路径。
- `checkCoreTables` 本就是本 fork 自 R3 起用做「DB 是否可用」的判据（R3 用它判断损坏并修复），本轮只是复用同一判据。
- SDK 内无任何代码调用 `createTable:`/`dropTable:`（`WKDB.h` 也未暴露），Example App 也不建表；表一律来自 Migrations 资源。因此 `checkCoreTables == NO` 确实等价于「这个库不可用」，不存在「调用方稍后自己建表」的场景被误伤。

### 13.4 验证
- `xcodebuild -workspace WuKongIMSDK.xcworkspace -scheme WuKongIMSDK -sdk iphoneos -configuration Debug -derivedDataPath /tmp/wkdd_r13 CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build` → **BUILD SUCCEEDED**（`BUILD_EXIT=0`，0 error）。
- 改动后用 `grep -n 'newQueue\|openFailed'` 复查，确认 `[newQueue inDatabase:]` 只有一处（编辑过程中曾短暂重复，已删除）。本轮未新增文件，无需 `pod install`。

### 13.5 判定不移植
- `6d9d6ad` 那 10 处 `beginTransaction/endTransaction` 本身：iOS 用 FMDB 的 `inTransaction:` 封装，`endTransaction` 由 FMDB 在 finally 里自行调用且内部有保护，不存在 Android 的「多次 getDb() 取到不同连接」/TOCTOU 问题。
- `8ec8e49`/`6a95caf`（cursor NPE）：ObjC 对 nil 发消息安全，已在 Round 10 记录。

---

## Round 14 — 连接层：消息完整性 + 重复连接防护 + 网络监听线程安全（对应 Android 2585602 等）（2026-10-09）

### 14.1 背景
Round 7 已把连接层的门闸（backoff 重连）与 tempPackets 做了并发加固，但 `loopGetAddrToConnect` / `connectSocket` / `WKNetworkMonitor` 这条「拿地址 → 建 socket」的链路还没查过。本轮专门交叉复查该链路与解包后的包分发，找出 4 个真实问题。

### 14.2 改动
`manager/WKConnectionManager.m`

1. **connack 之后的粘包会被整批丢掉**（`handlePacketData:`）。原来收到 `WK_CONNACK` 处理完连接成功后直接 `return`；而 `unpacket:` 一次 TCP 读取会解出同一段里的**所有**完整包，服务器常把 connack 与紧随其后的离线消息写在同一段，于是 connack 后面的包全部丢失。改为 `continue` 继续处理剩余包；此时 `pullOfflineFinished` 仍为 NO，剩余包会进临时包数组，等会话同步完成后按序处理。

2. **过期的「获取连接地址」重试会再建一条 socket**。`scheduleRetryGetAddr` 用 `dispatch_after` 延迟重试，延迟期间若已经连上（网络恢复触发的立即重连）或已重新发起连接，旧回调仍会执行 `loopGetAddrToConnect` → `connectSocket:`，而 `connectSocket:` 会**直接替换** `self.ssocket`（旧 socket 的断开因 `isCurrentSocket == NO` 被忽略），造成重复连接/连接互相踢。修复：
   - 新增 `addrGeneration`（atomic int）+ `cancelGetAddrRetry`（`addrGeneration++`、`addrRetryCount = 0`）。
   - `scheduleRetryGetAddr` 与 `loopGetAddrToConnect` 的 `getConnectAddr` 异步回调都先取 generation 快照，回调/延迟触发时 generation 变了就放弃（异步地址提供者在断开后才返回的场景也一并覆盖）。
   - `onlyConnect`（新一轮连接开始）、`disconnect:`、`logout`、`handleConnected`、`onNetworkStatusChange:`（有网/无网两条路）都调用 `cancelGetAddrRetry`。
   - `connectSocket:` 补 `if(self.forceDisconnect) return;`：已主动断开/退出登录后不再发起新连接（异步地址回调可能晚于 logout 返回）。

3. **`startNetworkMonitor` 的 check-then-act 竞态**：`connect` 可从任意线程并发调用，两个线程可能都通过 `networkMonitorStarted` 判断，重复 `[monitor start]` 并互相覆盖 `networkStatusChange` 回调。改为 `@synchronized(self)` 保护判断+置位。

`manager/WKNetworkMonitor.m`

4. **网络监听自身线程安全**：
   - `start` 整体加 `@synchronized(self)`：避免重复 `SCNetworkReachabilityCreateWithAddress` 造成 ref 泄漏 + 只保留最后一个 ref；`CreateWithAddress` 失败时把 `started` 复位为 NO 以便重试。
   - 启动时的首次探测改为在锁外调用 `handleReachabilityFlags:`（不持锁调用外部回调）。
   - `stop` 同一把锁保护 ref 的释放与 `started` 复位。
   - 新增显式 getter `isNetworkAvailable`（`@synchronized` 读）；`handleReachabilityFlags:` 把「比较+赋值」放进锁内、通知与 `NSNotification` 仍在锁外发出。

### 14.3 判定「已有覆盖 / 不需要移植」
- `8c3cf3e`（先验证 msgKey 再解密 payload）：iOS 顺序本来就是对的 —— `coder/proto/WKRecvPacket.m:62` 先比对 `msgKey`，`:66` 才 `decryption:`；校验失败直接返回 nil。无需改动。
- `e91952f`（提醒项内存缓存）：`WKReminderManager` 已有 `reminderCache` + `clearCache`（Round 5 移植，退出登录时清空防跨账号脏数据），无需再动。

### 14.4 验证
- `xcodebuild -workspace WuKongIMSDK.xcworkspace -scheme WuKongIMSDK -sdk iphoneos -configuration Debug -derivedDataPath /tmp/wkdd_r14 CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build` → **BUILD SUCCEEDED**（`BUILD_EXIT=0`，0 error；仅有 Pods 的 deployment target 既有告警）。本轮未新增文件，无需 `pod install`。

---

## Round 15 — 发送/重发与消息队列并发安全（对应 Android 2585602 / fac8ec7 / 68d3e6f）（2026-10-09）

### 15.1 背景
Round 14 收尾了「连接层」。本轮沿 R6 打过补丁的发送/重发入口往下走，交叉复查 `WKMessageQueueManager`（发送队列 + 定时 flush）、`WKRetryManager`（重试/上传定时器生命周期）与 `WKChatManager` 的拦截器字典，发现 4 组真实问题。

### 15.2 改动

**`manager/WKMessageQueueManager.m`**

1. **`sendPackets` 无锁并发读写（崩溃级）**。`sendMessage:` 在**调用线程**执行 `[self.sendPackets addObject:]`，而 `flushQueue`（NSTimer，主线程）同时 `firstObject`+`removeObjectAtIndex:0`、`stop` 同时 `removeAllObjects`。`NSMutableArray` 并发「读+写」会触发 over-release/越界 -> `EXC_BAD_ACCESS`（对应 Android 2585602 并发容器类问题）。
   - 新增 `queueLock`（`NSLock`，getter 带 `@synchronized(self)`）。
   - `sendMessage:` 的 `addObject:`、`stop` 的 `removeAllObjects` 加锁。
   - `flushQueue` 改为**锁内摘批、锁外编码/写 socket**：锁内算出本批数量并 `subarrayWithRange:`+`removeObjectsInRange:`，锁外再 `encode` 并 `writeData:`，避免在持锁期间做编码/网络写而阻塞发送方。
   - `sendMaxCountOfEach <= 0` 时仍按原语义「至少发 1 个」（`if(limit<=0) limit=1;`），不改变边界行为。

2. **重复 `start` / 快速 `stop` 会留下永不失效的 NSTimer（泄漏 + 双重 flush）**。原 `start` 在调用线程（连接状态回调所在的 socket 队列）同步 `invalidate` 后再 `dispatch_async(main)` 建新定时器：两次连续 `start` 时第二次执行时 `self.timer` 仍是 nil（第一次的还没在主线程序上建出来），于是两段块各建一个 timer，只有后一个写进 `self.timer`，前一个**永远活着**继续 `flushQueue`；`stop` 也会因为块还没执行而失效失败。
   - 新增 `timerGeneration`（atomic int）：`start`/`stop` 各自自增；主线程建 timer 前先比对代际，不一致直接返回。
   - `start` 的旧 timer 失效 + 新建**全部**移到主线程块内，保证同一时刻最多一个 timer。
   - `stop` 的 `invalidate` 也改到主线程执行。

**`manager/WKRetryManager.m`**

3. **`start` 的 check-then-act 无锁 + 定时器创建与 stop 竞态**。`start` 由 `WKConnectionManager.connectStatusChange` 调用（连接状态变化可来自 socket 队列/网络监听的任意线程）；原 `if(self.started) return; self.started = true;` 无保护，并发 `start` 会起**两套**重试定时器。另外三个 `start*Retry` 里 `dispatch_async(global_low)` -> `dispatch_async(main)` 建 timer 的块在 `stop` 之后仍会执行，重建出已被 stop 的定时器。
   - `start`/`stop` 对 `started` 的读写放进 `@synchronized(self)`。
   - 新增 `runGeneration`（atomic int）：`start` 取代际快照并传入三个后台块，块执行前比对代际；三个主线程建 timer 块再补 `if(!strongSelf.started) return;`，`stop` 之后不再新建定时器。
   - 去掉 `start` 里**重复 dispatch 的第二次 `startReminderRetry`**（原样是明显笔误，两次调用会各建一次提醒上传定时器）。

4. **过期消息检查定时器实际从未触发**。`self.expireMsgCheckTimer = [NSTimer scheduledTimerWithTimeInterval:... target:self selector:@selector(startExpireMsgCheck) ...]` 直接在 `start` 的调用线程上调度，而该线程是 socket 的 dispatch 队列——dispatch 队列 worker 线程不跑 runloop，定时器挂上去就不响。改为和其它定时器一样在主线程创建（同样带代际/`started` 校验）。

**`manager/WKChatManager.m`**

5. **拦截器字典 `interceptDict` 无锁**。`addMessageStoreBeforeIntercept:`/`removeMessageStoreBeforeIntercept:`（App 任意线程注册/移除）与消息存储路径上的 `getMessageStoreBeforeIntercepts`（`saveMessages` -> 消息处理队列）并发：轻则读到半更新状态，重则 `allValues` 与 `removeObjectForKey:` 并发崩溃/丢拦截器。三个方法统一 `@synchronized(self.interceptDict)`（对应 Android 2585602 并发容器）。

### 15.3 判定「不需要移植 / 已有覆盖」
- `fac8ec7`/`68d3e6f` 中「DB 操作移至后台线程」在本轮涉及的两条链路上已分别由 Round 11（`syncChannelMessageQueue`）与 Round 4（`pullMessages` 主线程入口）覆盖。
- `retryMessageDict`（`WKChatManager.m:46`）：本轮 grep 确认**已无任何读写点**，仅剩惰性 getter（R12 已加锁），无并发风险。

### 15.4 验证
- `cd Example && xcodebuild -workspace WuKongIMSDK.xcworkspace -scheme WuKongIMSDK -sdk iphoneos -configuration Debug -derivedDataPath /tmp/wkdd_r15 CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build` → **BUILD SUCCEEDED**（`EXIT=0`，0 error；仅有 Pods deployment target 既有告警，日志 `/tmp/wk_build_r15.log`）。本轮未新增文件，无需 `pod install`。

### 15.5 已知未处理
- `startExpireMsgCheck` 里的 `getExpireMessages` + `deleteMessage:` 仍在定时器线程（主线程）上执行，未像 Android `68d3e6f` 那样整体移到后台：`deleteMessage:` 会调用 `WKConversationManager` 的内存会话缓存（`getConversation:`/`calConversationUnread:`），要先单独评估该缓存是否线程安全，本轮不夹带。

---

## Round 16 — 已删除消息的查询过滤 + 过期消息检查移出主线程（对应 Android eb54d0f / 68d3e6f）（2026-10-09）

### 16.1 背景
延续 Round 15.5 的待办往下走，并对照 Android SDK 全量提交重新筛了一遍「尚未移植/尚未判定」的提交，选中 `eb54d0f`（修改通过 msgID 查询消息时未过滤已被删除消息）。Android 的 `MsgDbManager.queryWithMessageID` 对照时为 `... WHERE message_id=? and message.is_deleted=0`，而 iOS 的对应查询没有 `is_deleted` 条件。

### 16.2 改动

**`db/WKMessageDB.m`**

1. **`getMessageWithMessageId:` 会返回已被本地删除的消息**（对应 Android `eb54d0f`）。`SQL_MESSAGE_WITH_MESSAGEID`（`db/WKMessageDB.m:105`）原先只按 `message.message_id=?` 查询；本地删除只是把 `is_deleted` 置 1、行仍在，于是按 messageID 依然能查到已删除的消息。5 个调用点全部期望「拿到在用的消息」：
   - `manager/WKChatManager.m:361`/`:378`（`editMessage:newContent:` 编辑后刷新 UI、编辑上传完成/失败回调）；
   - `manager/WKRetryManager.m:251`（内容编辑重试超时）、`:393`（内容编辑上传回调）；
   - `manager/WKReactionManager.m:50`（`addOrCancelReaction:` 先查消息、再用它的 channel 发送回应）。
   修复：SQL 加 `and message.is_deleted=0`。效果：对已删除消息不再触发 UI 刷新回调（避免已删除的消息被编辑/重试路径重新推回 UI）；`addOrCancelReaction:` 对已删除消息直接返回（原逻辑会拿已删除消息的 channel 真把回应发上去）。`db/WKMessageDB.h:144` 注释同步写明「已删除返回 nil」。

**`manager/WKRetryManager.m`**

2. **过期消息检查整段跑在主线程**（Round 15.5 遗留；延续 Android `68d3e6f`「DB 操作移后台」精神）。`startExpireMsgCheck` 由 `expireMsgCheckTimer`（主线程，每 `expireMsgCheckInterval`=10s）触发，内部一次 `getExpireMessages:`（join `message_extra` 的 DB 查询）+ 逐条 `deleteMessage:`（DB 标记删除 + 重置最近会话 + 回调 delegate）全在主线程，消息多时明显卡 UI。
   修复：整段 `dispatch_async` 到全局队列，并加两重保护（`manager/WKRetryManager.m:182-212`）：
   - `expireChecking`（atomic BOOL）防重入：上一次检查未结束就跳过本轮，避免耗时超过检查间隔时同一批消息被并发删除、`onMessageDeleted:` 重复回调；
   - `runGeneration` 代际快照：进入前与逐条删除前都比对，`stop`（登出/切换用户）后立即中止，避免用旧库查到的 clientSeq 去删新账号的数据。

### 16.3 Round 15.5 的前提已核实（因此才可以移后台）
Round 15.5 的顾虑是「`deleteMessage:` 会动 `WKConversationManager` 的内存会话缓存」。本轮核实：`WKConversationManager` **没有内存会话缓存**（`manager/WKConversationManager.m` 仅有 `delegates`/`delegateLock`；`getConversation:` :99 直接查 DB 再补提醒项），`WKConversationDB`/`WKReminderDB` 也没有静态缓存，全部经 `WKFMDatabaseQueue` 串行访问；而 `deleteMessage:` 里的两处通知（`WKChatManager.m:1772` `callMessageDeletedDelegate:`、`resetConversationLastMessage:` → `WKConversationManager.m:364` `callOnConversationUpdateDelegate:`）本身都会 dispatch 到主线程。因此整段移后台是安全的。

### 16.4 验证
- `cd Example && xcodebuild -workspace WuKongIMSDK.xcworkspace -scheme WuKongIMSDK -sdk iphoneos -configuration Debug -derivedDataPath /tmp/wkdd_r16 CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build` → **BUILD SUCCEEDED**（日志 `/tmp/wk_build_r16.log`）。本轮未新增文件，无需 `pod install`。

### 16.5 本轮判定「不移植 / 无对应 / 已有覆盖」
- `922f23a`（发送失败的消息无法显示）：核心是 Android `insertMsgs` 改为「按 messageID 命中即不插入」+ `queryWithMsgIds` 拼 SQL 漏引号。iOS `saveMessages:`（`db/WKMessageDB.m:195`）本来就用 `getMessageWithMessageIdOrClientMsgNo:` 做存在性判断、按 messageID **或** clientMsgNo 去重，`message_id` 是整数参数绑定，无此问题。
- `f44d6eb`（ReminderDBManager 返回类型编译错误）：iOS 返回 nil 的 `NSArray` 合法且安全（nil 上取 count 为 0），无对应点。
- `b220233`（同步群成员每页先删全表）：iOS `WKChannelManager.addOrUpdateMembers:`（`manager/WKChannelManager.m:261`）只清内存缓存 + DB upsert，不删表，无此 bug。
- `836c02e`/`964c918`/`61dd373`/`a7984b8`/`c5f52cd`/`169215b`：仅日志/格式/demo 改动，或无实质状态机修复。
- `275ebfb`/`305124a`：连接层架构级重构（单线程 Executor + 定时器管理器）；iOS 已有等价的 `reconnectBackoff`/`reconnectGeneration`/`addrGeneration` 防护（R7/R14），不整体移植。
- `ce924cd`（批量刷新最近会话）：iOS delegate 是逐条 `onRefreshConversationMsg:`，无对应批量接口，移植价值低。
- `0e8a9b0`（未登录取 DB 数据的报错）：已被 Round 13（数据库不可用防御）覆盖。
- `65493fa`/`662a559`（VPN 检测，Android 8 专属）、`ce1086b`/`ff7196b`/`4f917b7`/`b3e8e11`/`3904ad5`（新功能）、`ac7e11f`（消息过期时间字段，iOS 早已有 `expire`/`expire_at` 与 `SQL_EXPIRE_MESSAGES`）属新功能/平台专属/已具备。

---

## Round 17 — 已读回执缓存正确性 + 任务监听者字典加锁（对应 Android 2585602 并发容器普查的收尾）（2026-10-09）

### 17.1 背景
Round 12 已对全 SDK 的惰性初始化 getter 做过一次并发普查（对应 Android 2585602），Round 15 覆盖了发送队列/重试定时器。本轮把「共享可变容器」和「NSTimer 创建线程」再全量扫了一遍（grep `@property NSMutable*`、`scheduledTimerWithTimeInterval`、`IN (` 拼接），确认剩余未加锁点只有两处：`WKReceiptManager.cacheDict` 与 `WKBaseTask.listenerDic`；其余容器（`WKSDK.messageContentDict`、`WKConnectionManager.tempPackets`、`WKTaskManager.taskDic`、`WKMemoryCache`、`WKChannelRequestQueue`、`WKChannelManager.cacheDict`/`channelReqeusts`）均已有锁，SQL `IN ()` 空列表在 R6 之后各处均已守卫。

### 17.2 改动

**`manager/WKReceiptManager.m`**（已读回执缓存，4 处）

1. **provider 异步回调期间追加的新消息会被误删（已读回执丢失）**。`flush:`（原 :116）在锁内把当前缓存拷成 `tmpMessages` 后，在锁外调用 App 的 `messageReadedProvider`；回调里原来的 `removeCacheWithLength:channel len:flushCachedLen` 是「从当前集合移除最前面的 N 条」。若回调返回前 App 又 `addReceiptMessages:` 追加了新消息，被移除的是新消息，这批新消息永远不会再上报。改为 `removeCacheMessages:channel messages:tmpMessages`，**按对象身份精确移除本次实际上报的那批**，并在集合清空时 `removeObjectForKey:`。
2. **`addReceiptMessages:` 无条件建空集合**。原实现即便没有任何可上报消息也会 `setObject:messagesSets forKey:channel`，`cacheDict` 键随频道数无上限增长、`flushLoop` 反复对空频道调 `flush:`。改为仅在 `messagesSets.count>0` 时写入（并补 `channel`/`messages` 空值早退）。
3. **`flushLoop` 无锁遍历 `cacheDict.allKeys`**。与 `addReceiptMessages:` 写入并发时可能「枚举中变更」崩溃。改为先加锁取键快照再遍历。
4. **`flushTimer` 可能在非主线程创建**。`setup` 在 `+shared` 的 `dispatch_once` 内执行，而 `+shared` 可能被 App 在任意线程首次访问；`scheduledTimerWithTimeInterval:` 依赖调用线程 runloop，非主线程（无 runloop）时定时器永不触发/创建失败。改为统一派发到主线程的 `setupFlushTimer` 创建，并做「已有有效定时器则不重复建」的幂等保护。

**`manager/task/WKBaseTask.m`**

5. **`listenerDic` 读写无锁**（`addListener:target:` / `removeListener:` / `listeners`）。`addListener:` 由 `WKTaskManager.add`（`manager/WKTaskManager.m:26`）与 `WKMediaManager.download:callback:`（`manager/WKMediaManager.m:138`）在调用线程执行；`removeListener:` 由监听回调内的 `WKTaskManager.remove:`（`WKTaskManager.m:86`）执行；而任务实现的 `update`（App 侧下载/上传子类在工作线程调用）会读 `listeners` → `allValues`，三者可能跨线程并发。新增 `listenerLock`（NSRecursiveLock），三个方法统一加锁，`listeners` 在锁内取快照后返回。

### 17.3 判定「不需要移植 / 已有覆盖」
- `e0779a9`/`5aaa5a1`（只把需要存储的消息 push 给 UI、不存储的不 push）：iOS 行为本就相反且注释明确 —— `manager/WKChatManager.m:610-613` 用 `commonMessages`（`filterNoCMDAndNoStreamMessages`）调 `callRecvMessagesDelegate:`，注释「不管存不存的消息都需要通知到delegate」。
- `137813f`（channel member 优先读 `avatar_cache_key`）：iOS 全库 grep `avatarCacheKey`/`avatar_cache_key` 无命中，无对应点。
- `38c916f`（getOrSyncHistoryMessages 上拉 start/end seq 互换）：iOS 是另一套 `pullMessages`/`calSync` 序号差检测（`manager/WKChatManager.m:896-1050`），语义不同。
- `d005ce6`/`18d12c6`（Android `saveSyncChannelMSGs` 删冗余 `queryWithMsgIds`，避免大批量消息堆内两份 OOM）：iOS `calSyncForForce`（`manager/WKChatManager.m:1391-1454`）与 pull 链路没有「写库后再按 msgIds 重查一遍」的冗余，无对应。
- `789faba`（附件消息 `updateContentAndRefresh` 未把 type 放进 content JSON）：iOS `WKMessageContent` 走自己的 encode 流程、`type` 另存于消息行，未确认有对应 bug。
- `cd8d574`/`05a454b`/`6d92c78`（保存频道成员提速等纯性能提交）：未确认有明确 bug，暂不夹带。

### 17.4 验证
- `cd Example && xcodebuild -workspace WuKongIMSDK.xcworkspace -scheme WuKongIMSDK -sdk iphoneos -configuration Debug -derivedDataPath /tmp/wkdd_r17 CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build` → **BUILD SUCCEEDED**（`BUILD_EXIT=0`，`error:` 计数 0，仅 Pods deployment target 既有告警，日志 `/tmp/wk_build_r17.log`）。本轮未新增文件，无需 `pod install`。

---

## Round 18 — 不连续消息同步的边界消息定位 / 分页取值修复（对应 Android `47ea031`/`75d9dc8`）（2026-10-09）

### 18.1 背景
Android PR #24（`fix/db-stability-and-performance`）里的 `47ea031`「查看不连续消息未同步」与 `75d9dc8`「同步不连续未同步」修的是 `MsgDbManager.getMessages` 在 `pullMode==0` 分支忽略 `contain` 参数、以及 start/end seq 互换，导致「不连续消息」同步时取的边界不是相邻消息。

iOS 的对应机制与 Android 不同：iOS 没有 `contain` 参数，而是由 `WKChatManager pullMessages:...`（`manager/WKChatManager.m:835`）先取本地一页消息，再用 `WKMessageDB getMessage:channel lessThanAndFirstMessageSeq:` / `moreThanAndFirstMessageSeq:`（实现 `db/WKMessageDB.m:600-622`，仅被 `WKChatManager.m:904`/`:906` 调用）取与基准 orderSeq **相邻**的一条有 messageSeq 的消息，比较两者 seq 差判断是否存在「不连续」，必要时调 `calSync:` 补同步。

### 18.2 改动

**`db/WKMessageDB.m`**（2 处）

1. **`SQL_MESSAGE_WITH_LESS_THAN_ORDER_SEQ`（:125）**：`order by message.message_seq asc limit 1` → `desc limit 1`。原写法在 `where ... order_seq<?` 的结果里取 **messageSeq 最小**（频道最早）的一条；调用方需要的是与基准最接近（messageSeq 最大）的相邻消息。
2. **`SQL_MESSAGE_WITH_MORE_THAN_ORDER_SEQ`（:128）**：`order by message.message_seq desc limit 1` → `asc limit 1`。同理，原写法取的是频道最新一条。

判据 / 证据：
- 调用方 `WKChatManager.m:903` 的注释明确写「查询小于 startOrderSeq 最近的一条有 messageSeq 的消息」，而两条 SQL 的 ORDER BY 方向与之相反。
- 同文件里对称的已删除消息查询 `SQL_DELETED_MESSAGE_SEQ_WITH_MESSAGE_SEQ_LESS`（:135）用 `desc`、`..._MORE`（:137）用 `asc`（LESS→desc / MORE→asc 的「最近优先」约定），且 `WKChatManager calSync:`（:1328）的两个循环靠 `break on gap>1` 依赖该顺序 —— 反证这两条 message_seq 查询的 ORDER BY 写反。
- `message_seq<>0` 的行满足 `order_seq = message_seq * WKOrderSeqFactor`（1000），两者单调一致，故按 message_seq 排序等同于按位置排序。
- 影响：基准 `startOrderSeq` 非 1000 倍数（本地未 ack 消息的 order_seq = maxOrderSeq+1）时进 `WKChatManager.m:899` 的 else 分支取邻居；取到极端值后 `needSync` 恒为真，`calSync` 会以错误的 start/end 对整段历史发起无效补同步（最多递归 5 次 `maxExecCount`），浪费网络与写库。

**`manager/WKChatManager.m`**（2 处）

3. **「计算最后一页后是否还存在消息」的 Down 分支循环体（:1016）**：`realStartMessageSeq = newMessages[0].messageSeq;` → `newMessages[i].messageSeq;`。原写法循环体恒读 index 0，当本页最旧一条是本地未确认消息（messageSeq==0）时 `realStartMessageSeq` 恒为 0，而 `calSync:` 在 Down 模式对 `startMessageSeq==0` 直接 `return false`，「是否还有更早消息」的判断被整体跳过。Up 分支（:1006-1012）从 `count-1` 递减取最新非 0 seq，Down 应对称地自前往后取最旧非 0 seq。
4. **`pullMessages` 内层循环的 `WKMessage *nextMessage;`（:957）** → `WKMessage *nextMessage = nil;`。下方 :964 有 `if(!nextMessage) break;`，i==count-1 时内层循环不执行；显式初始化消除未初始化读。

### 18.3 判定「不移植 / 无对应 / 已有覆盖」
- 索引 `5b69519`：iOS 已有 `WuKongIMSDK/Assets/Migrations/202604150900.sql`（Round 3 提交 `0f0a0b7` 引入，与 Android 内容一致）。
- WAL `f193f42` / `1a48603`（WAL 部分）：iOS `db/WKDB.m:108-114` 已在 `[newQueue inDatabase:]` 内执行 `PRAGMA journal_mode=WAL`（executeQuery）+ `synchronous=NORMAL`。
- 延迟关旧队列 `594ccb2`：iOS `WKDB.m:139-147` `closeOldQueueAsync:newQueue:` 已 dispatch_after 0.5s 关旧队列（R13）。
- `bdc02e2`（SQLCipher 关连接后 cursor 消费崩）：iOS 全库无 `- (FMResultSet` 返回（所有查询都在 `inDatabase:`/`inTransaction:` 块内消费），无对应点。
- `8ec8e49`（queryCount 空检查）：iOS `WKDB.m:597-605` 用 `while([set next])`，FMResultSet 为 nil 时安全。
- `16f46f9`（DateUtils ThreadLocal 缓存）：iOS `WKMessageDB.m:1171-1176` 的 `wk_dateFormatter` 用 `threadDictionary` 缓存，线程安全。
- `2e1f27c`（附件上传失败刷新 listener）：iOS `WKMediaManager.m:182-187` 失败分支已先 `message.status = WK_MESSAGE_FAIL;` 再 `updateMessageStatus:` / `callMessageUpdateDelegate:`，行为正确。
- `aef4cb6`（无网络重连不消耗次数）：iOS 已由 R2/R14 覆盖 —— `WKConnectionManager.m:545-578` `onNetworkStatusChange:` 有网即 `reconnectCount = 0` 并 cancel backoff/getAddr；`:466-474` `backoffReconnect` 无网早退；`:290-298` `connectSocket` 无网 / forceDisconnect 早退。
- `98c2b88`（收消息先验合法性再解码）：iOS 顺序本正确（`coder/proto/WKRecvPacket.m:62` 先比对 msgKey，`:66` 才 decryption，失败 return nil）。
- `d1351d0`（优化连接卡 UI）：主体是 Android demo 的 `ConnectionTestActivity` + `WKConnection` 锁重构（ReentrantLock 公平性 / 超时锁），属平台专属架构调整。
- 其余（`1a48603` 线程池扩容、`11af5e9`、`deaf7fb`、`c8483c4`、`7762914`/`fda3423`/`564727d`/`d742164`/`e108c79`/`99d0a8b`/`a735d9d`/`4f3e435`/`c038944`/`1ac36f5`/`a448c9f`/`d4d1dc8`/`d4be779`、`f25f6ce`/`8327844`/`5f67b27`）：为新功能 / Android 专属 / 已具备，逐条见本轮勘察。

### 18.4 验证
- `cd Example && xcodebuild -workspace WuKongIMSDK.xcworkspace -scheme WuKongIMSDK -sdk iphoneos -configuration Debug -derivedDataPath /tmp/wkdd_r18 CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build` → **BUILD SUCCEEDED**（`BUILD_EXIT=0`，`error:` 计数 0，`WKMessageDB.m`/`WKChatManager.m` 无新增告警，仅 Pods deployment target 既有告警，日志 `/tmp/wk_build_r18.log`）。本轮未新增文件，无需 `pod install`。

---

## Round 19 — 频道请求队列生命周期 + 回应回调契约修复（iOS 自有缺陷）（2026-10-09）

### 19.1 背景
`WKChannelManager.addChannelRequest:complete:`（`manager/WKChannelManager.m:118` → `WKChannelRequestQueue` 的 `addRequest:complete:`）面向「大量 cell 请求同一频道数据」的场景：同一频道的并发请求应共享一次 provider 调用，且每一个调用方都要拿到结果；请求结束后应能再次发起。对照同一文件里另一条路径 `WKChannelManager fetchChannelInfo:completion:`（:72-112）——它在锁内把重复请求 append 到 `blockArray`（:87）、最终回调前 `removeObjectForKey:key`（:103）——`WKChannelRequestQueue` 的实现与之语义不一致，导致该 API 事实上第二次起失效。Android 无此类 `ChannelRequestQueue`，本轮记为「iOS 自有缺陷」，无对应 Android commit。

### 19.2 改动

**`manager/WKChannelRequestQueue.m`**（4 类问题）

1. **请求完成后从不移出队列（核心）**。原 `createRequest:`（:105-126）的 provider 回调在最终结果（`notifyBefore==NO`）时只置 `request.status = Success/Error` 并回调 complete，**不移除** `requests`/`requestDict`。后果：某频道首次请求完成后该请求永久驻留，之后同频道 `addRequest:` 一律命中「已存在」分支（原 :78-83），既不再调用 provider，也不回调新的 complete → `addChannelRequest:complete:` 从第二次起永久失效（直到被 10 个其它频道的请求挤出）。改为最终回调前在锁内校验 `requestDict[key] == request` 后移除 `requests`/`requestDict` 并置 status。
2. **重复请求时后到者的 complete 被丢弃**。原 `createRequest:` 只捕获第一个 complete；命中已存在请求时只把 request 移到队首，`complete` 参数完全未使用——而该 API 的设计意图正是「大量 cell 获取同一频道数据」，每个 cell 都应收到回调。改为 `WKChannelRequest` 新增 `NSMutableArray<WKChannelRequestComplete> *completes` 收集同频道全部回调：`notifyBefore==YES`（缓存/中间结果）时回调当前全部挂起 block 且不移除请求；最终结果时在锁内快照并清空 completes、锁外逐块回调。
3. **在锁内执行 App 代码**。原实现是在持有 `self.lock`（NSRecursiveLock）时调用 App 提供的 `[WKSDK shared].channelInfoUpdate(...)`，provider 若同步回调即在锁内跑用户代码，重入安全只靠递归锁侥幸。改为「先在锁内登记请求 → 解锁 → 再调用 provider」；所有 complete 回调（含取消/淘汰路径）统一在锁外执行。
4. **取消 / 容量淘汰不回调挂起方**。`cancelRequest:`（:128）与超过 `channelRequestMaxLimit`（默认 10，`WKOptions.m:46`）的淘汰路径原来只 `[request cancel]`，从不回调 complete，调用方永久等待。两处都补 `complete([NSError errorWithDomain:@"频道信息请求已被取消" / @"频道请求过多，已被取消" code:0 userInfo:nil], NO)`；并补 `channel` 为空时早退并回调错误，避免 provider 收到 nil 频道、调用方挂起。
5. 附带：原淘汰逻辑会把「已完成但未移除」的请求也计入并发上限；修复 1 之后 `channelRequestMaxLimit` 恢复为「进行中请求」上限的语义。原 `createRequest:` 先调 provider 再设 `request.channel`，provider 同步回调时 `request.channel` 尚为 nil，本轮一并调整为先组装再发起。

**`manager/WKReactionManager.m`**（1 处）

6. **`addOrCancelReaction:messageID:complete:` 提前 return 不回调 complete**（原 :46 / :51）。未设置 `addOrCancelReactionProvider`、或 `getMessageWithMessageId:` 返回 nil（R16 之后「消息已删除」也走此分支）时直接 return，调用方会永久等待。两处补 `complete([NSError ...])`，domain 分别为「没有设置addOrCancelReactionProvider」「消息不存在或已删除，不能回应」。

### 19.3 判定「不移植 / 无对应 / 已有覆盖」
- 本轮为 iOS 自有缺陷，Android 无对应提交。
- 顺带复查 R16 的「已删除消息查询过滤」是否有回归：`getMessageWithMessageId:` 的全部调用点（`WKMessageDB.m:650`/`:662`/`:204`、`WKRetryManager.m:275`/`:417`、`WKChatManager.m:361`/`:378`、`WKReactionManager.m:50`）在 nil 分支的处理均可接受（跳过刷新/通知），无有害回归。

### 19.4 验证
- `cd Example && xcodebuild -workspace WuKongIMSDK.xcworkspace -scheme WuKongIMSDK -sdk iphoneos -configuration Debug -derivedDataPath /tmp/wkdd_r19 CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build` → **BUILD SUCCEEDED**（`BUILD_EXIT=0`，`error:` 计数 0，日志 `/tmp/wk_build_r19.log`）。本轮未新增文件，无需 `pod install`。

## Round 20 — 最近会话插入的 extra/version 参数错位修复 + 频道ID占位符绑定（iOS 自有缺陷）（2026-10-09）

### 20.1 背景
`db/WKConversationDB.m` 的 `insertConversation:db:` 与 `replaceConversations:` 共用同一张 `conversation` 表和相同的列清单 `(..., unread_count, extra, version, is_deleted)`，但两处 FMDB 位置参数顺序不一致：`replaceConversations:`（:99）为 `...@(unreadCount), extraStr, @(version), @(isDeleted)`（正确）；`insertConversation:db:`（:114）写成了 `...@(unreadCount), @(version), extraStr, @(isDeleted)`，把 `version` 数值绑进 `extra` 列、把 `extra` JSON 字符串绑进 `version` 列。

新建会话的所有路径都走 `insertConversation:`：`WKConversationManager addOrUpdateConversation:incUnreadCount:` 在会话不存在时于 :67 调用它（收到/发送某频道第一条消息、同步到新会话都会命中）；`WKConversationManager addConversation:`（:89）→ `WKConversationDB addConversation:`（:106）也落到它。只有「会话已存在」才走 `updateConversation:db:`（`SQL_UPDATE_LASTMSG` 不含 extra/version），所以该错位对每个新会话必然发生一次。

读回路径 `toConversation:`（`version` :407 走 `longLongValue`，`extra` :408-410 当 JSON 字符串解析）在错位后会出问题：`version` 列存的是 extra 的 JSON（空串或对象文本，`longLongValue` 得 0）→ 会话版本丢失 → `getConversationMaxVersion`（`SQL_MAX_VERSION`）拿到偏小值 → 触发不必要的最近会话全量同步；`extra` 列存的是纯数字文本（如 `0`），`NSJSONSerialization` 把 `0` 解析成 `NSNumber` 并赋给 `WKConversation.extra`（声明为 `NSDictionary*`），类型错位，后续 `conversation.extra[...]` 下标访问有崩溃风险。

Android 无对应提交：`ConversationDbManager` 用 `ContentValues` 按列名写入（`getInsertSyncCV`/`insertSyncMsg`），不存在位置参数错位。本轮记为「iOS 自有缺陷」。

### 20.2 改动
**`db/WKConversationDB.m`**（2 处）

1. **`insertConversation:db:`（:114）参数顺序修正（本轮主修）**：改为 `...@(conversation.unreadCount), extraStr, @(conversation.version), @(conversation.isDeleted)`，与列清单及 `replaceConversations:` 一致。修复后新插入会话的 `extra`/`version` 各归其位。
2. **`getConversations:`（:259-298）改占位符绑定**：原实现把每个 `channelId` 直接拼进 `IN (...)` 的引号中（`[NSString stringWithFormat:@"%@'%@'",...]`，原 :268-276），含单引号的频道ID会生成非法 SQL（并构成注入面）。现按 channel 数量生成 `?,?,...` 占位符、用 `[... executeQuery:... withArgumentsInArray:channelIDs]` 绑定（绑定顺序即 `IN` 列表顺序）。空列表由 :260 早退保护，无需担心生成 `IN ()`。

### 20.3 判定「不移植 / 无对应」
- 本轮主修为 iOS 自有缺陷，Android 用具名列写入，无位置参数错位，无对应 commit。
- 复查 `SQL_MAX_VERSION`（:50）的 `where version <> ''`：`version` 列具数值 affinity，`''` 被折叠为 0，等价于排除 version=0 的会话，属既有意图，非 bug，不动。
- 其余同类 `IN (...)` 拼接处绑定的是数值ID（clientSeq/messageID/reminderID 等），无字符串引号问题：`WKMessageDB.m:466/501/520/782/802/938`、`WKReminderDB.m:130/165`、`WKChannelMemberDB.m:267/285`、`WKCMDDB.m:123`、`WKReactionDB.m:59`，本轮不一并改动。
- 另注意到 `WKRobotDB.m:52/71` 把 robotID/username 包成双引号（`"%@"`）拼进 `IN (...)`：SQLite 会把双引号优先当标识符、无匹配列时才当字符串字面量（double-quoted string literal 旧行为），同样存在特殊字符破坏 SQL 的风险，但属另一文件、需评估 SQLite 编译选项，留作后续轮次候选。

### 20.4 验证
- `cd Example && xcodebuild -workspace WuKongIMSDK.xcworkspace -scheme WuKongIMSDK -sdk iphoneos -configuration Debug -derivedDataPath /tmp/wkdd_r20 CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build` → **BUILD SUCCEEDED**（`BUILD_EXIT=0`，`error:` 计数 0，日志 `/tmp/wk_build_r20.log`）。本轮未新增文件，无需 `pod install`。

## Round 21 — 字符串列表 SQL IN 拼接统一改为占位符绑定（iOS 自有加固）（2026-10-09）

### 21.1 背景
承接 Round 20 对 `WKConversationDB getConversations:` 的同类加固，本轮把全库剩余「把字符串值用双引号包起来拼进 `IN (...)`」的写法统一改为 `?` 占位符 + `withArgumentsInArray:` 绑定。原实现形如 `[NSString stringWithFormat:@"\"%@\"",value]` 再 `componentsJoinedByString:@","` 拼 SQL。问题有两层：
- SQLite 会把双引号 `"xxx"` 优先解析为标识符（列名），只有找不到同名列时才回退成字符串字面量（double-quoted string literal 旧行为）。若 SQLite/SQLCipher 以 `SQLITE_DBCONFIG_DQS_DML=0` 编译或运行时关闭该行为，`IN ("abc")` 会直接报 `no such column: abc`；即使开启，值里含 `"` 也会截断/破坏 SQL。
- 字符串拼接本身是注入面，与 R20 同类。

共 3 个文件、5 处：
- `db/WKRobotDB.m:42-61` `queryRobots:`（`SQL_ROBOTS_WITH_IDS`）、`db/WKRobotDB.m:63-82` `queryRobotsWithUsernames:`（`SQL_ROBOTS_WITH_USERNAMES`）。
- `db/WKChannelMemberDB.m:257-277` `getMembersWithChannel:uids:`（`SQL_MEMBER_LIST_WITH_UIDS`）、`db/WKChannelMemberDB.m:279-293` `updateMemberStatus:channel:uids:`（`SQL_UPDATE_MEMBER_STATUS`）。
- `db/WKMessageDB.m:488-512` `getMessagesWithClientMsgNos:db:` 的多值分支（`SQL_MESSAGE_WITH_CLIENTMSGNOS`）。

Android 无对应 commit：Android 用 `?`/`ContentValues` 具名绑定，无此拼接写法；本轮记为 iOS 自有加固。

### 21.2 改动
1. `WKRobotDB.m` 两处：按列表长度生成 `?,?,...`，`[... executeQuery:... withArgumentsInArray:bindValues]`；值取 `robotID?:@""` / `username?:@""`（原实现传 nil 会拼出无意义值）。
2. `WKChannelMemberDB.m` 两处：`SQL_MEMBER_LIST_WITH_UIDS`/`SQL_UPDATE_MEMBER_STATUS` 的 `?` 顺序为「channel_id, channel_type, member_uid...」（查成员）/「status, channel_id, channel_type, member_uid...」（改状态），故 args 先放前缀参数、再追加每个 uid，使其与 SQL 文本中 `?` 出现顺序一致。
3. `WKMessageDB.m` 多值分支同上；`clientMsgNos.count==1` 的单值分支本就使用 `SQL_MESSAGE_WITH_CLIENTMSGNO` + `?` 绑定（:494-495），保持不变。
4. 空列表均已由各方法入口早退保护（`WKRobotDB.m:43/64`、`WKChannelMemberDB.m:258/280`、`WKMessageDB.m:489`），不会生成 `IN ()`。

### 21.3 验证
- `cd Example && xcodebuild -workspace WuKongIMSDK.xcworkspace -scheme WuKongIMSDK -sdk iphoneos -configuration Debug -derivedDataPath /tmp/wkdd_r21 CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build` → **BUILD SUCCEEDED**（`BUILD_EXIT=0`，`error:` 计数 0，日志 `/tmp/wk_build_r21.log`）。本轮未新增文件，无需 `pod install`。
- 修改后重新 grep 双引号拼接模式（`\"%@\"`）于 `WuKongIMSDK/Classes` → 0 命中。

## Round 22 — 更新频道设置时循环内多次落库/回调修复（iOS 自有加固）（2026-10-09）

### 22.1 背景
`WKChannelManager updateChannelSetting:channel:setting:`（`manager/WKChannelManager.m:206-237`）把 `[self updateChannelInfo:channelInfo]` 写在 `for (NSString *key in setting.allKeys)` 循环体内。`updateChannelInfo:` 自身会 `queryChannelInfo`（读旧值）→ `WKChannelInfoDB updateChannelInfo`（写库）→ `setCache`（刷内存缓存）→ `callChannelInfoUpdateDelegate`（回调）。
因此 `setting` 有 N 个 key 时会：
- 落库 N 次（每次把内存对象的当前全量字段覆盖写一遍）；
- `channelInfoUpdate` 委托被回调 N 次，且前 N-1 次回调看到的 `channelInfo` 只应用了部分字段（例如一次同时设置 `mute`/`stick`，会先回调「只改了 mute」再回调「改了 mute+stick」）。

### 22.2 改动
`manager/WKChannelManager.m`：把 `[self updateChannelInfo:channelInfo]` 移到 for 循环之后，并加 `if(setting.count > 0)` 守卫。所有字段先在内存对象上一次性应用，完成后再只落库/回调一次；`setting` 为空时保持原先「不落库、不回调」的行为。

Android 无对应 commit：Android 侧无 `updateChannelSetting`/`ChannelSetting` 方法（全库 grep 0 命中），本轮记为 iOS 自有加固。

### 22.3 判定不移植（本轮 Android 提交二次筛选）
- `dc2b1a9`（fix:update cmd message）：Android 在同步最近会话转换、`MsgManager.WKSyncRecent2WKMsg`、`MessageHandler.handleReceiveMsg` 三处跳过 `WK_INSIDE_MSG`。iOS 用 `WK_CMD=99`（`WKConst.h:18`），`WKChatManager.m:610-613` 已用 `filterNoCMDAndNoStreamMessages:`（:675-679）过滤后再通知 delegate，:653/:666 单独处理 CMD；消息查询 SQL 也带 `content_type<>99`。无需移植。
- `25caa7a`（修改收到信息先验证合法性再解码内容）：实为带字面冲突标记的 merge commit，内容属 Android 专用 payload 解码，不可移植。
- PR #24/#25/#26 对应提交（`bdc02e2`/`a3b4ea0`/`594ccb2`/`8ec8e49`/`5b69519`/`f193f42`/`16f46f9`/`1a48603`）此前已逐一判定（iOS 由 `WKFMDatabaseQueue.isReady`+`WKDB.switchDB` openFailed+`closeOldQueueAsync` 覆盖 / `Assets/Migrations/202604150900.sql` 索引 / `WKDB.m:110-113` WAL 覆盖 / `intForQuery` 无对应 / 无 msgIds 分批）。
- 其余未记录提交为 demo/readme/LICENSE/连接层重构家族/替换 sqlcipher native 库，无稳定性修复。Android 侧已基本穷尽。

### 22.4 验证
- `cd Example && xcodebuild -workspace WuKongIMSDK.xcworkspace -scheme WuKongIMSDK -sdk iphoneos -configuration Debug -derivedDataPath /tmp/wkdd_r22 CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build` → **BUILD SUCCEEDED**（`BUILD_EXIT=0`，`error:` 计数 0，日志 `/tmp/wk_build_r22.log`）。本轮未新增文件，无需 `pod install`。
- Insert SQL 列/参数一致性普查（承接 R20）：`SQL_CHANNEL_SAVE`（`WKChannelInfoDB.m:12`，27 列）实参 :73/:86、`SQL_CHANNEL_UPDATE`（:14）实参 :95、`SQL_MEMBER_ADD`/`SQL_MEMBER_UPDATE_OR_ADD`（`WKChannelMemberDB.m:13/18`）实参 :142、`SQL_MESSAGE_EXTRA_INSERT_OR_UPDATE`（`WKMessageExtraDB.m:11`，15 列）实参 :67/:94、`SQL_ADD_UPDATE`(reminders)（`WKReminderDB.m:12`，12 列）实参 :64、`SQL_INSERT_REACTIONS`（`WKReactionDB.m:15`）实参 :93/:102 —— 列清单与实参逐条比对均一致，无第二处参数错位。

## Round 23 — 收包解码越界防御：WKDataRead 全员长度校验 + decodeLM 包体长度校验（iOS 自有加固）（2026-10-09）

### 23.1 背景
`coder/WKData.m` 的 `WKDataRead` 所有读取方法（`readUint8/16/32/64`、`readint64`、`readData:`、`readString`、`readLenth`、`lenthLength`）都直接用 `subdataWithRange:NSMakeRange(offset, len)`，**没有任何长度校验**；`coder/WKCoder.m` 的 `decodeLM:`（:45-73）读出 `remainingLength` 后也未校验实际可用 body 长度。
连接层的分包逻辑（`manager/WKConnectionManager.m` 的 `splitPacketData`）只校验「固定头 + 长度字节 + 声明的剩余长度 ≤ TCP 缓冲」，因此**声明的 remLength 与真实 body 内容可以不一致**（服务器 bug、中间设备改包、协议版本不匹配、或 App 直接调用公开 API `WKCoder.decode:`）。一旦 body 按字段读越界（例如 WK_RECV 包声明 remLength=1，`readString` 却要先读 2 字节长度），就会抛 `NSRangeException` 直接崩溃。
对应 Android 25caa7a「修改收到信息先验证合法性再解码内容」的防御意图；但该提交本身是带字面冲突标记（`<<<<<<< HEAD`）的 merge commit，属 Android 专用 payload 解码，**无法直接移植**，本轮按其「先验证合法性再解码」的思路在 iOS 侧独立加固。

### 23.2 改动
`coder/WKData.m`：
- 新增私有 `-(NSUInteger) unreadLength`（剩余可读字节，offset 越界返回 0）与 `-(BOOL) canRead:(NSUInteger)len`；
- `readUint8/readUint16/readUint32/readUint64/readint64`：读取前 `canRead:` 校验，不足则打日志、返回 0 且**不推进 offset**；
- `readData:`：`len<=0` 或越界返回空 `NSData`（不再 `subdataWithRange:` 崩溃）；
- `readString`：长度字段越界或内容越界返回 `@""`；
- `readLenth`：每步 `canRead:1`，越界 break；
- `lenthLength`：循环内新增 `i` 的边界检查（原实现直接读 `buffData[i]`）；
- `remainingData`：offset 越界时返回空 `NSData`。

`coder/WKCoder.m`：`decodeLM:` 读出 `remainingLength` 后，用 `reader.remainingData.length` 校验；声明长度大于实际可用字节数时打日志并 `return nil`（上层 `WKConnectionManager handlePacketData:` :896 已有 `if(!packet) continue;`，会安全跳过该包）。

### 23.3 判定不移植 / 附带结论
- Android `25caa7a`：带冲突标记的 merge commit，不可 cherry-pick；本轮仅沿用其防御意图。
- `WKDataRead.lenthLength` 在 iOS 全库无调用方（仅头文件声明 + 实现），但仍加了边界检查，避免后续被误用时崩溃。
- 正常合法包路径完全不变（所有校验只在越界时触发日志与默认值），不会影响协议兼容。

### 23.4 验证
- `cd Example && xcodebuild -workspace WuKongIMSDK.xcworkspace -scheme WuKongIMSDK -sdk iphoneos -configuration Debug -derivedDataPath /tmp/wkdd_r23 CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build` → **BUILD SUCCEEDED**（`BUILD_EXIT=0`，`error:` 计数 0，`WKData.m`/`WKCoder.m` 无新增告警，日志 `/tmp/wk_build_r23.log`）。本轮未新增文件，无需 `pod install`。

---

## Round 24 — 同步/完成回调契约修复：complete/callback 不再挂起或重复触发（iOS 自有缺陷）（2026-10-10）

### 24.1 背景
对全库带完成回调的公开 API 做普查（`WKRobotManager` sync/syncWithUsernames、`WKChatManager` syncMessageExtra、`WKConnectionManager` wakeup、`WKMediaManager` download:callback:），发现多处「提前 return 却不回调 complete/callback」以及「成功后重复回调」，上层等待回调的代码会永久挂起或收到重复完成通知：

- `manager/WKChatManager.m` `syncMessageExtra:complete:maxReqCount:`（:1849）三处缺陷：
  (a) 未设置 `syncMessageExtraProvider` 时直接走到方法末尾，**从不调用 complete**；
  (b) 提供者返回成功且本页 `results.count < messageExtraSyncLimit`（即已到最后一页）时既不递归也不回调 complete → **正常同步完成反而永久挂起**；
  (c) `error!=nil` 分支的 `return` 写在 `if(complete)` 内，`complete==nil` 时会继续处理错误页数据。
- `manager/WKRobotManager.m` `sync:complete:`（:34-79）与 `syncWithUsernames:complete:`（:81-126）：未设置 `syncRobotProvider`（:35-38/:82-85）或传入空数组（:39-41/:86-88）时提前 return 且不调用 complete。
- `manager/WKConnectionManager.m` `wakeup:complete:`（:1086-1116）：连接成功回调后未注销 `onConnectStatusChange`，超时前若再次收到 `WKConnected` 会**重复调用** complete。
- `manager/WKMediaManager.m` `download:callback:`（:124-156）：`downloadTaskProvider` 未设置或返回非 `WKMessageFileDownloadTask` 时 `return nil` 且不回调 callback，上层 loading 无法结束。

### 24.2 改动
- `manager/WKChatManager.m`：`syncMessageExtra:` 的 error 分支改为**无条件 return**（不再依赖 `complete` 非空）；本页 results 不足一页时回调 `complete(nil)`；新增 `else` 分支（同步提供者缺失）回调 `complete(NSError …)`，保证 complete 恰好被调用一次。
- `manager/WKRobotManager.m`：两个方法的「provider 缺失」「数组为空」分支分别回调 `complete(false, NSError …)` 与 `complete(false, nil)`。
- `manager/WKConnectionManager.m`：`wakeup:` 的状态回调块内新增 `hasComplete` 幂等判断，成功后立即 `self.onConnectStatusChange = nil`，避免重复回调。
- `manager/WKMediaManager.m`：`download:callback:` 两处 `return nil` 前回调 `callback(WKMediaDownloadStateFail,0,NSError …)`。

### 24.3 判定不移植 / 附带结论
- Android 无 `syncMessageExtra` 同构实现（grep `syncMessageExtra` 仅 `WKCMDKeys.wk_sync_message_extra` 字符串与 `ConversationManager.saveSyncMsgExtras`，语义不同）；`WKRobotManager`、`WKMediaManager`、`wakeup:` 亦为 iOS 自有 API 或 Android 无同构实现 → **本轮为 iOS 自有缺陷修复，无对应 Android commit**。
- 附带确认无同问题：`WKChatManager` 的 pullLastMessages/pullDown/pullUp/pullAround/pullMessages 系列（核心 :835 的早退走 `completePullMessages:`，:862/884/…）、`WKReceiptManager.flush:complete:`（:113-117/:127-132）、`WKChannelRequestQueue addRequest:`、`WKReactionManager addOrCancelReaction:`（后两者 R19 已修）在所有提前 return 路径都会回调 complete。

### 24.4 验证
- `cd Example && xcodebuild -workspace WuKongIMSDK.xcworkspace -scheme WuKongIMSDK -sdk iphoneos -configuration Debug -derivedDataPath /tmp/wkdd_r24 CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build` → **BUILD SUCCEEDED**（`BUILD_EXIT=0`，`error:` 计数 0，日志 `/tmp/wk_build_r24.log`）。本轮未新增文件，无需 `pod install`。

## Round 25 — 收包热路径日志收敛 + 媒体委托机制修复（iOS 自有加固）（2026-10-09）

### 25.1 背景
- `manager/WKConnectionManager.m` 共 39 处 `NSLog`，其中收包/分包/解包热路径上仍有多条未受 `[WKSDK shared].isDebug` 保护：`socket:didReadPartialDataOfLength:`（:632）、`didReadData:` 的解包数量（:644）、`unpacket:` 每轮循环（:805）、`unpackOneLM:` 的分包/整包/粘包分支（:856/:862/:867/:879）、`handlePacketData:` 的包数量/解码失败/解码成功（:893/:897/:900，其中 :897 会打印整段原始 `data`）、临时包数量（:945）、`handlePackets:` 未知包类型（:969）。这些日志在每次 TCP 读取、每个消息包上都会执行，iOS 的 `NSLog` 会同步写 stderr/`os_log`，消息量大时会明显拖慢收包线程并放大 IO 开销（Android 侧 4151c42「logger ANR」的同类思路）。
- `manager/WKMediaManager.m`：`addDelegate:`/`removeDelegate:` 直接访问 `self.delegates`，但类扩展只声明了 `NSHashTable *delegates` 属性、**没有对应的惰性 getter**（同类 manager 如 `WKReactionManager.m:106-114` 均有），因此 `_delegates` 恒为 nil，委托注册/注销实际是空操作；协议方法 `mediaManageUpdate:` 全库也无任何调用点。
- `coder/WKCoder.m` `encodeLM:`（:32）写作 `if(packetType == WK_PING)`，而 `packetType` 已是 `header.packetType<<4`、`WK_PING=7`，该比较恒为 false、是死代码（`decodeLM:` 用的是 `flag>>4`）。

### 25.2 改动
1. `manager/WKConnectionManager.m`：把上述 11 处热路径 `NSLog`（:632/:644/:805/:856/:862/:867/:879/:893/:897/:900/:945/:969）收敛到 `if([WKSDK shared].isDebug)` 内；`socketDidDisconnect`（:615）、解包异常（:812）等低频/错误日志保持无条件输出。行为逻辑不变，仅日志输出条件变化。
2. `manager/WKMediaManager.m`：
   - 类扩展新增 `-(void)callMediaManageUpdateDelegate:(id<WKMediaProto>)media;` 前置声明；
   - 新增 `-(NSHashTable*) delegates` 惰性 getter（`@synchronized(self)` + `NSPointerFunctionsWeakMemory`），使 `addDelegate:`/`removeDelegate:` 真正生效；
   - 新增 `callMediaManageUpdateDelegate:`，加锁取 delegates 快照后在主线程回调（与 `WKReactionManager.callReactionManagerChangeDelegate:` 同构）；
   - `taskComplete:`（:175-194）在上传任务成功/失败处理后，若 `message.content` 符合 `WKMediaProto` 则调用 `callMediaManageUpdateDelegate:`（语义：媒体数据已更新，如上传成功后 remoteUrl 被赋值）；
   - `taskProgress:`（:166-173）的上传/下载进度 `NSLog` 同样收敛到 `isDebug`（进度回调可能非常频繁）。
3. `coder/WKCoder.m` `encodeLM:`：`if(packetType == WK_PING)` 改为 `if(packet.header.packetType == WK_PING)`。因 PING/PONG 的 body `encode:` 均返回 nil、`encodeLength:0` 返回空数据，两种写法产生的字节完全相同（仅 1 字节固定头，`appendData:nil` 为 no-op），**不改变线上协议行为**，仅消除死代码隐患。

### 25.3 判定不移植 / 附带结论
- Android 无与热路径日志逐条对应的 commit；本轮按 4151c42「logger ANR」的意图在 iOS 侧独立收敛，记为 iOS 自有加固。
- `WKMediaManager` 委托机制修复为 iOS 自有（Android 无 `mediaManageUpdate:` 同构协议）。
- 附带确认 `encodeLength:0` 不产生缺长度前缀的坏包：`-[NSMutableData appendData:nil]` 实测为 no-op（编译运行 `/tmp/t_append.m` 验证）。

### 25.4 验证
- `cd Example && xcodebuild -workspace WuKongIMSDK.xcworkspace -scheme WuKongIMSDK -sdk iphoneos -configuration Debug -derivedDataPath /tmp/wkdd_r25 CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build` → **BUILD SUCCEEDED**（`BUILD_EXIT=0`，`error:` 计数 0，日志 `/tmp/wk_build_r25.log`）。本轮未新增文件，无需 `pod install`。

## Round 26 — 消息落库不再静默丢失：入库失败纳入错误处理 + client_msg_no 空值兜底（iOS 自有加固）（2026-10-10）

### 26.1 背景
`WuKongIMSDK/Classes/db/WKMessageDB.m` 的两条写路径都把 `executeUpdate` 的失败结果静默丢弃，可能造成「内存/最近会话有消息、DB 无该行」或「消息永久丢失且无任何日志」：

- `saveMessages:`（:199-260）先按 `messageId`/`clientMsgNo` 查存在性，未命中即拼 `SQL_MESSAGE_SAVE` 写入。原实现在 **insert 之前**就把 message 加入 `newMessages`，且 `bool success` 只用于设 `clientSeq`/`orderSeq`，失败不处理；随后 `hasRemoteExtra`/`reactions`/`streams` 仍照写。返回的 `newMessages` 会经 `WKChatManager.addOrUpdateConversationWithMessages:` 更新最近会话，于是 DB 插入失败时最近会话会指向一条并不存在的消息（后续按 clientSeq 读取时拿到空）。
- `replaceMessages:`（:262-301）在 `insertMessage:` 失败后查同 `clientMsgNo` 的冲突行：仅当找到且 `messageSeq` 不同才插一条 `clientMsgNo = "<clientMsgNo>-<seq>"` 的删除态副本。若 `dupMessage == nil`（如 `client_msg_no` 为空/为 NULL、或其他约束/IO 错误）或 seq 相同，分支直接落空 —— **消息既不入库也无任何日志**。
- `insertMessage:db:clientMsgNo:isDeleted:`（:305-322）把传入的 `clientMsgNo` 直接绑定进 SQL。schema（`Assets/Migrations/202005281108.sql:1/3`）为 `client_msg_no varchar(80) not null default ''` 且 `CREATE UNIQUE INDEX idx_client_msg_no`，绑定 nil 会写入 NULL 违反 NOT NULL，插入必然失败；而 `replaceMessages:` 恰好把 `message.clientMsgNo` 原样传入，客户端拼接的同步消息若未填 clientMsgNo 就会落入上面的静默丢弃分支。

### 26.2 改动（`WuKongIMSDK/Classes/db/WKMessageDB.m`）
1. `saveMessages:`：把 `[newMessages addObject:message]` 从 insert 之前移到 **`success` 分支内**，仅入库成功的消息才计入 `newMessages`（即才更新最近会话）。
2. `saveMessages:`：`hasRemoteExtra`→`WKMessageExtraDB`、`reactions`→`WKReactionDB`、`streams`→`saveOrUpdateStreams` 一并移入 `success` 分支，避免 DB 无该行却写出孤儿扩展/反应/流数据；新增 `else` 分支打印 `WARN: 消息入库失败...`（含 messageId/messageSeq/clientMsgNo/`db.lastErrorMessage`）。
3. `saveMessages:` 冲突副本 `clientMsgNo` 兜底：`[NSString stringWithFormat:@"%@-%u", message.clientMsgNo ?: @"", message.messageSeq]`。
4. `replaceMessages:`：在 `if(dupMessage && dupMessage.messageSeq != message.messageSeq)` 后补 `else`，打印 `WARN: 消息替换入库失败且无同 clientMsgNo 的冲突行，消息被丢弃...`；该 if 内副本 `clientMsgNo` 同样做 `?:@""` 兜底。
5. `insertMessage:db:clientMsgNo:isDeleted:`：绑定改为 `clientMsgNo ?: @""`，杜绝 nil→NULL 违反 `client_msg_no NOT NULL`。

### 26.3 判定不移植 / 附带结论
- Android 参考提交 `d005ce6`（perf Bugly#30231 OOM：`saveSyncChannelMSGs` 删除冗余 `queryWithMsgIds`）与 `18d12c6`（`update sync channel messages`，实为把 `queryWithMsgIds`+`getMsgReactionsAndRefreshMsg` 注释掉的 hack）在 iOS 的 `pullMessages`（`WKChatManager.m:1028-1051/:1061-1121`）与 `handleRecv` 路径**没有同构的二次查询**，无法忠实 cherry-pick；本轮按 `d005ce6` 的「同步入库可靠性、避免多余物化」意图在 iOS 侧独立修复，记为 iOS 自有加固。
- **评估后不做**：`saveMessages:` 的 N+1 存在性查询不批量化。该查询对新消息返回 0 行、不触发 `toMessage:` 的 `decodeContent`，只是 N 次带索引的 `SELECT`；要批量化需动态拼 `IN`，并改变「按 message_id **或** client_msg_no 命中」的去重语义，收益低、回归风险高，故不改。

### 26.4 验证
- `cd Example && xcodebuild -workspace WuKongIMSDK.xcworkspace -scheme WuKongIMSDK -sdk iphoneos -configuration Debug -derivedDataPath /tmp/wkdd_r26 CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build` → **BUILD SUCCEEDED**（`error:` 计数 0）。本轮未新增文件，无需 `pod install`。

## Round 27 — 提醒项按频道查询的 IN 列表改为占位符绑定（移植 Android 65c6eec）（2026-10-10）

### 27.1 背景
`WuKongIMSDK/Classes/db/WKReminderDB.m` 的 `getWaitDoneReminders:`（:174-211）需要把一批频道 ID 拼进 `channel_id in (...)`，原实现用字符串插值手工拼引号：

```objc
for (NSInteger i=0; i<channelIDs.count; i++) {
    NSString *channelID = channelIDs[i];
    ...
    inquery = [NSString stringWithFormat:@"%@'%@'",inquery,channelID];
}
...
[db executeQuery:[NSString stringWithFormat:@"%@ (%@)",SQL_GET_NO_DONE_WITH_CHANNELS,inquery],
              WKSDK.shared.options.connectInfo.uid?:@""];
```

- 频道 ID 含单引号时拼出非法 SQL，FMDB 返回 nil resultSet，`while (resultSet.next)` 静默变成 no-op，**提醒项被静默丢弃**；同时存在 SQL 注入面。
- 频道 ID 为 nil 时拼出 `'(null)'`，同样查不到。
- 该方法是热路径，调用方：`WKConversationManager.m:111/:238/:308`、`WKReminderManager.m:172`（每次会话列表/提醒刷新）。

### 27.2 改动（`WuKongIMSDK/Classes/db/WKReminderDB.m`）
对应 Android 提交 `65c6eec "update Optimize message queries"`（2023-12-05）：其把 `ReminderDBManager.queryWithChannelIds` 从 `stringBuffer.append("'").append(channelIds.get(i)).append("'")` + `rawQuery(sql, new Object[]{stringBuffer.toString()})` 改为 `select(reminders, "channel_id in (" + WKCursor.getPlaceholders(channelIds.size()) + ")", channelIds.toArray(new String[0]), null)`；当前 Android `db/ReminderDBManager.java:163` 即占位符版。

1. 循环内同时构造占位符数组：`NSMutableArray<NSString*> *placeholders`（每个 `@"?"`），频道 ID 统一做 `channel.channelId ?: @""` 兜底。
2. `inquery` 改为 `[placeholders componentsJoinedByString:@","]`，不再出现单引号。
3. `inDatabase:` 块内构造 `NSMutableArray *args`，首元素为 `WKSDK.shared.options.connectInfo.uid ?: @""`（`SQL_GET_NO_DONE_WITH_CHANNELS` 中 `publisher<>?` 位于 IN 之前），再 `addObjectsFromArray:channelIDs`。
4. 查询改为 `...withArgumentsInArray:args`，全部值走 SQLite 参数绑定。

### 27.3 判定不移植 / 附带结论
- Android `65c6eec` 还同时把 `ChannelDBManager`/`ChannelMembersDbManager`/`ConversationDbManager`/`MsgDbManager`/`MsgReactionDBManager`/`RobotDBManager` 改为占位符；这些 iOS 已在 Round 20/R21 用 `?` + `withArgumentsInArray:` 覆盖（`WKRobotDB.m:54/:75`、`WKChannelMemberDB.m`、`WKConversationDB.m` 等），**`WKReminderDB` 是 `65c6eec` 在 iOS 侧的最后一块遗漏**，本轮补齐。
- **复核后不改**：`WKChannelMemberDB.getMembersWithChannel:keyword:page:limit:`（:190-205）的 `offset=(page-1)*limit`。Android `ChannelMembersDbManager.java:43-85 search/queryWithPage` 是**完全相同**的 `int queryPage = (page-1)*size` 且同样未夹取；SQLite 规定负 OFFSET 等同 0，page==0 不崩、行为与 Android 一致，故不视为缺陷。
- 同步排除的 Android 提交：`aef4cb6`（无网络不累加重连计数）已由 iOS `SKConnectionManager.m backoffReconnect`（:466-508，`!networkAvailable` 时直接 return）与 `:545-578` 网络恢复归零覆盖，连接前地址校验也已由 `WKConnectionManager.m:247` 覆盖；`789faba`（附件 type 缺失）iOS `WKMessageContent.m:75-82 encode` 本就写入 `type`，不适用；`a7984b8`/`275ebfb` 仅删日志参数与死代码，已在 MODIFICATIONS.md:306/:605 记录为架构级重构不移植。

### 27.4 验证
- `cd Example && xcodebuild -workspace WuKongIMSDK.xcworkspace -scheme WuKongIMSDK -sdk iphoneos -configuration Debug -derivedDataPath /tmp/wkdd_r27 CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build` → **BUILD SUCCEEDED**（`BUILD_EXIT=0`，`error:` 计数 0，日志 `/tmp/wk_build_r27.log`）。本轮未新增文件，无需 `pod install`。

## Round 28 — 修复收包解密失败导致的 JSON 解析崩溃 + extra 字段解析空值防御（2026-10-11）

### 28.1 背景
- Round 28 先用 `git log --oneline` 全量对照 Android 仓库（HEAD `662a559`）与本文档：候选提交 `6a95caf`（insertOrReplaceExtra 空指针）、`6d9d6ad`（getDb 空指针）、`11af5e9`（丢库补表）、`202d1f6`（重发 null NPE）、`8ec8e49`（cursor NPE）、`2585602`（并发）**均已在本文档记录**，无新可移植项。本轮转为修 iOS 自有崩溃点。
- **崩溃链（本轮主修复）**：服务端未按当前 AES 配置下发（负载非 base64 / 非法填充）时 `WKAESUtil.aesDecrypt:key:iv:`（`Classes/utils/WKAESUtil.m:35-47`）在 `CCCrypt` 非 `kCCSuccess` 时返回 nil → `WKSecurityManager.decryption:`（`Classes/manager/WKSecurityManager.m:81-83`）返回 nil → `WKRecvPacket.m` `decodeLM:header:`（:66-67）把 nil 直接赋给 `packet.payload` → 收包路径 `WKChatManager.m` `recvPacketsToMessages:`（:1488）调用 `decodeContent:contentType:`（:1516）→ `[NSJSONSerialization JSONObjectWithData:nil ...]` 抛 `NSInvalidArgumentException: data parameter is nil`，**整条收包热路径崩溃**。
- 经验验证（`clang -fobjc-arc -framework Foundation` 小程序）：`JSONObjectWithData:nil` → `EXCEPTION NSInvalidArgumentException: data parameter is nil`；`[NSNull dataUsingEncoding:]` → `-[NSNull dataUsingEncoding:]: unrecognized selector`；`[NSMutableDictionary dictionaryWithDictionary:nil]` 不崩（空字典）；`dictionaryWithDictionary:[NSNull null]` → `-[NSDictionary initWithDictionary:copyItems:]: dictionary argument is not an NSDictionary`。
- **同类未守卫点**：`WKMessageDB.m` `toMessage:`、`WKConversationDB.m` `toConversation:`、`WKChannelInfoDB.m` `toChannelInfo:` 对 `dict[@"extra"]` 直接 `dataUsingEncoding:` + JSON 解析，无 nil/NSNull 守卫；而 `WKMessageExtraDB.m:172/:181`、`WKChannelMemberDB.m:367`、`WKReminderDB.m:232` 均已守卫，行为不一致。

### 28.2 改动（5 个文件）
1. `WuKongIMSDK/Classes/coder/proto/WKRecvPacket.m`（`decodeLM:header:`）: 解密结果为 nil 时打 warn 日志（含 fromUid/channelId/clientMsgNo）并把 `packet.payload` 退化为 `[NSData data]`，不再把 nil 传给下游。
2. `WuKongIMSDK/Classes/manager/WKChatManager.m`（`decodeContent:contentType:`）: 入口新增 `if(!contentData || contentData.length == 0){ NSLog(@"warn: 消息内容为空，跳过解码！"); return nil; }`（空数据原本也会因 JSON 解析失败返回 nil，行为等价，仅去掉崩溃面）。
3. `WuKongIMSDK/Classes/db/WKMessageDB.m`（`toMessage:`）: extra 解析段加 `[extraStr isKindOfClass:[NSString class]] && extraStr.length>0` 与 `[extraDictionary isKindOfClass:[NSDictionary class]]` 守卫。
4. `WuKongIMSDK/Classes/db/WKConversationDB.m`（`toConversation:`）: 同 3。
5. `WuKongIMSDK/Classes/db/WKChannelInfoDB.m`（`toChannelInfo:`）: 同 3（原实现 `dictionaryWithDictionary:extraDictionary` 在 extraDictionary 为 NSNull 时会抛异常）。

### 28.3 判定 / 附带结论
- 表 `message`/`conversation`/`channel` 等的 `extra` 列 schema 均为 `text not null default ''`（`Assets/Migrations/201911270513.sql:72/:104/:16`），且 `SQL_EXTRA_COLS`（`WKMessageDB.m:35`）只 IFNULL 了 readed/readed_at/... 而**不 alias `message_extra.extra`**，故 DB 层 extra 当前实际不可为 NULL；第 3-5 项为**防御性加固**（与已守卫站点保持一致），主修复是第 1-2 项。
- 未守卫但判定安全、本轮不改：`WKCMDManager.m:106`（`cmd.param` 列 `text not null default ''`，`Assets/Migrations/202011211232.sql:11`）；`WKMOSContentConvertManager.m:229`（`convertContentToLM:` 全库无调用者，死代码）。
- 本轮修复为 iOS 自有缺陷，**无对应 Android commit**（Android 侧未发现同型解密/JSON 空值缺陷）。

### 28.4 验证
- `cd Example && xcodebuild -workspace WuKongIMSDK.xcworkspace -scheme WuKongIMSDK -sdk iphoneos -configuration Debug -derivedDataPath /tmp/wkdd_r28 CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build` → **BUILD SUCCEEDED**。本轮未新增文件，无需 `pod install`。

---

## Round 29 — 移植 Android 握手 DH/AES 空值防护，修复非法 serverKey 导致 Curve25519 抛异常崩溃（2026-10-11）

### 29.1 背景
- 候选排除：`WKReminderDB.m` 全文复核（254 行）无新增问题（Round 27 已修 `getWaitDoneReminders:`；`addOrUpdates:` :56-67 在事务内逐条 executeUpdate 忽略失败，低风险）；`substringToIndex:` 全 Classes 仅 2 处，均在 `WKSecurityManager.m`。
- Android 全量对照：HEAD `662a559` 前 60 条中有实质内容者均已在本文档记录；未记录仅 `9978523`(Add logs)/`22b28ce`(merge)/`deb45d9`(merge)/`7c8624a`(优化导入版本)，无移植价值。
- **崩溃链（本轮主修复）**：连接握手 `WKConnectionManager.handleConnected:`（:1004-1006）→ `WKSecurityManager.generateAesKey:connackPacket.serverKey salt:connackPacket.salt`（:47-61）。`serverKey` 来自 `WKConnackPacket.decodeLM:`（:37 `packet.serverKey=[reader readString]`），`WKData readString`（:185-202）在长度为 0/越界时返回 `@""`、在非 UTF-8 字节时返回 nil，且协议层无任何长度校验。`initWithBase64EncodedString:options:IgnoreUnknownCharacters` 对空串/非法串返回**空 data（length 0，非 nil）**，随后 `Curve25519 generateSharedSecretFromPublicKey:andKeyPair:` 因 `[theirPublicKey length] != 32` **`@throw NSInvalidArgumentException`（`Example/Pods/25519/Classes/Curve25519.m:89-94`，Pod 依赖，非 fork 代码）**，未捕获 → 握手阶段直接崩溃。
- 经验验证（`clang -fobjc-arc` 小程序）：非法 base64 → 空 data length 0；`initWithData:nil` → 非 nil 空串；`[nil length]`=0；`writeVariableString:nil` 写 0 长度（安全）；`strlen(NULL)` → **段错误 exit 139**。

### 29.2 改动（2 个文件）
对应 Android 提交 `b006969 "update connect"`（`git log -S "TextUtils.isEmpty(serverKey)"` / `-S "key.length() > 16"` 均命中），其 `CryptoUtils.setServerKeyAndSalt`（`wkim/src/main/java/com/xinbida/wukongim/utils/CryptoUtils.java:72-88`）已有：空 `serverKey`/`salt` 早退（`this.serverKey=new byte[0]; return;`）与 `if(!TextUtils.isEmpty(key) && key.length()>16) aesKey=key.substring(0,16)`；iOS 对应实现缺失。
1. `WuKongIMSDK/Classes/manager/WKSecurityManager.m` `generateAesKey:salt:`（:47-85）：入口校验 `self.curve25519Key` 非空且 base64 解码后 `pubKeyData.length == 32`（`pubKey?:@""` 兜底）；`sharedKeyData` 为 nil、`aesKeyFull` 为 nil 或长度 < 16 时均打 warn 并 `self.sharedKey/aesKey/aesIV = nil` 后 return，不再把非法公钥交给 Curve25519、不再对短串 `substringToIndex:16` 越界。
2. `WuKongIMSDK/Classes/manager/WKSecurityManager.h` `sharedKey` 声明加 `nullable`（协商失败即为 nil，与实现一致）。
3. `WuKongIMSDK/Classes/manager/WKSecurityManager.m` `md5:`（:88-92）：入口加 `if(!input || input.length==0) return nil;`，防 `strlen(NULL)` 段错误。两个调用方对 nil 均安全：`WKRecvPacket.m:61-64` 走 `![nil isEqualToString:]`→YES→判「消息不合法」返回 nil；`WKSendPacket.m:62` `writeVariableString:nil` 写 0 长度。

### 29.3 判定 / 附带结论
- 降级行为：协商失败后 `aesKey/aesIV` 为 nil，`WKAESUtil` 对 nil key 走 bzero 全零 key（不崩），收包解密失败由 Round 28 的 `WKRecvPacket.m` 兜底退化为空负载 → 连接不再因非法 serverKey 崩溃。
- 不改 Curve25519（Pod 依赖）：在不修改第三方 Pod 的前提下，按 Android 同构做法在调用前做长度校验即可完全避免该 `@throw`。
- `salt` 长度守卫 iOS 原本已有（`salt.length>16`），仅补齐空值/短 key 部分。

### 29.4 验证
- `cd Example && xcodebuild -workspace WuKongIMSDK.xcworkspace -scheme WuKongIMSDK -sdk iphoneos -configuration Debug -derivedDataPath /tmp/wkdd_r29 CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build` → **BUILD SUCCEEDED**，`error:` 计数 0，`WKSecurityManager.m` 无 `-Wnonnull` 警告（`sharedKey` 改 nullable 后消除），日志 `/tmp/wk_build_r29b.log`。本轮未新增文件，无需 `pod install`。

---

## Round 30 — 网络字符串解码与 DB 写入空值兜底（Android parity）（2026-10-11）

### 30.1 背景
- 延续 Round 26/29 的「nil 字符串 → 绑定 NULL → NOT NULL 约束失败/静默丢数据」模式：`WKDataRead.readString`（`WuKongIMSDK/Classes/coder/WKData.m:185-202`）在长度字段/内容越界时返回 `@""`（:188/:196）、len==0 返回 `@""`（:192），但 **:201 `[[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding]` 遇到非 UTF-8 字节返回 nil**。该方法声明于 `WKData.h:58`、文件处于 `NS_ASSUME_NONNULL_BEGIN`（`WKData.h:10`）下，返回 nil 违反 nonnull 契约；Android `new String(bytes, UTF_8)` 永不返回 null —— parity gap。
- nil 传播面：`readString` 消费者 9 处（`WKRecvPacket.m:36 msgKey / :37 fromUid / :38 channelId / :44 clientMsgNo / :46 streamNo / :55 topic`、`WKDisconnectPacket.m:28 reason`、`WKConnackPacket.m:37 serverKey / :38 salt`，R29 已对 serverKey/salt 加长度守卫）。nil 继续流向 DB 写绑定即变 NULL，命中 `client_msg_no`/`channel_id`/`member_uid` 等 NOT NULL 列 → 约束失败 → 该行静默不入库（R26 已在 WKMessageDB 证实此模式并仅对 message 表兜底）。
- 全库剩余未兜底的 NOT NULL 文本列写绑定（本轮 B 项）：`WKReactionDB.m:93/:102`（channelId/uid/emoji/createdAt）、`WKChannelMemberDB.m:142`（memberUid）、`WKReminderDB.m:64`（channelId）、`WKConversationDB.m:99/:114`（channelId）。

### 30.2 改动（5 个文件）
A. 根因修复 `WuKongIMSDK/Classes/coder/WKData.m` `readString`（:198-206）：UTF-8 解码失败不再返回 nil，改打 `WKDataRead: readString 内容非UTF-8...` 日志并返回 `@""`，使方法满足 nonnull 契约、与 Android 行为一致。所有消费者把「nil」与「空串」按同一语义处理（`WKRecvPacket.m:61-64` 的 msgKey 校验 `![exceptMsgKey isEqualToString:]` 对 nil/`@""` 结果相同），无行为回归。
B. 写侧兜底（补 `?:@""`）：`WKReactionDB.m:93`/`:102`、`WKChannelMemberDB.m:142`、`WKReminderDB.m:64`、`WKConversationDB.m:99`/`:114`。避免任一字段为 nil 时绑定 NULL 触发 NOT NULL 约束失败。
C. 读侧一致性：`WKReactionDB.m:123-124`（emoji/createdAt）、`WKChannelMemberDB.m:353`（memberUid）补 `?:@""`，与此前已有兜底的 uid（`WKReactionDB.m:121`）/channelId（:126）一致。
对应 Android 实现：无直接对应提交，属 Android `new String(bytes, UTF_8)` 永不返回 null 的固有行为对齐；DB 兜底延续 R26 模式。

### 30.3 判定
- 不改 readString 的越界分支（已返回 `@""`）。
- `WKReactionDB.insertOrUpdateReactions:` 仍返回 `true` 而无视 executeUpdate 失败（批量写忽略失败属既有设计，本轮仅消除 nil→NULL 这一可避免的失败源，未改返回值语义）。
- 未纳入本轮：`WKConnectionManager` 4 处未受 `isDebug` 保护的 NSLog（:596/:615/:818/:1037）经复核全为异常/错误路径，保留无条件日志合理；`WKAESUtil` nil key 静默全零 key 属安全降级，单独评估。

### 30.4 验证
- `cd Example && xcodebuild -workspace WuKongIMSDK.xcworkspace -scheme WuKongIMSDK -sdk iphoneos -configuration Debug -derivedDataPath /tmp/wkdd_r30 CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build` → **BUILD SUCCEEDED**，`error:` 计数 0，日志 `/tmp/wk_build_r30.log`。

---

## Round 31 — 加密失败不再静默：AES key 空值守卫 + nil payload 编码崩溃防护（2026-10-11）

### 31.1 背景
- 承接 Round 29 遗留（本文档 30.3 与待办 #5）：`WKSecurityManager.generateAesKey:salt:` 协商失败时把 `aesKey` 清为 nil（R29 有意），但 `WKConnectionManager.handleConnected:`（:1004-1006）不检查结果就 `changeConnectStatus:WKConnected`；连接状态一变即启动发送队列（`[WKMessageQueueManager.shared start]`，:740）。
- 静默 bug 链：`WKSendPacket.encodeLM:`（:42）取 `[[WKSecurityManager shared] encryption:payloadStr]` → `WKAESUtil.aesEncrypt:key:iv:` → `AES128operation:` 里 `[key getCString:keyPtr ...]`（:64）与 `[iv getCString:ivPtr ...]`（:68）**对 nil 是 no-op**，keyPtr/ivPtr 仍是 bzero 后的全零缓冲区 → CCCrypt 用「16 字节全零 AES key + 全零 IV」成功返回密文。即密钥未协商成功时消息仍被「成功」加密，服务端无法解开且本地无任何告警（Android `CryptoUtils` 加密失败返回 null，parity gap）。
- 同一路径的第二处崩溃：`aesEncrypt` 对 nil key 返回 nil 后，`WKSendPacket.encodeLM:` 原第 :44 行 `packet.payload=[payloadEnc dataUsingEncoding:]` 在 `payloadEnc` 为 nil 时把 payload 置 nil，随后 :69 `[writer writeData:packet.payload]` → `WKDataWrite.writeData:`（`WKData.m`:52-54）`[self.buffData appendData:nil]` 抛 NSInvalidArgumentException。
- 同类 nil-append 风险点：`WKCoder.encodeLM:`（`WKCoder.m`:43）在 packetType 未注册（`getBodyCoder:` 返回 nil）时 `appendData:bodyBytes`；`WKMessageQueueManager.flushQueue:`（:162-164）在 coder encode 返回 nil 时 `appendData:data`。（`WKConnectionManager.writeData:` :703-713 已有 nil 守卫，无需改。）

### 31.2 改动（8 个文件 / 11 处）
A. 空 key 守卫（不再静默产生错误密文）：
1. `WuKongIMSDK/Classes/utils/WKAESUtil.m` `aesEncrypt:key:iv:`（:20 起，NSLog :28）加 `if(!key || key.length==0)` 直接 return nil 并打 `warn: WKAESUtil aesEncrypt 失败：AES key 为空（密钥未协商成功？）`。
2. 同文件 `aesDecrypt:key:iv:`（:35 起，NSLog :47）加同款空 key 守卫与告警。
3. 同文件 `AES128operation:data:key:iv:`（:60 起，NSLog :74）在函数入口加 `if(!key || key.length==0 || !data) return nil`（双保险，含 `initWithBase64EncodedString:` 解码失败 data 为 nil 的情形）。
B. nil payload / nil 编码结果防护（不再崩溃）：
4. `WuKongIMSDK/Classes/coder/WKData.m` `writeData:`（:52-59）入口加 `if(!data || data.length==0) return;`，`pushBufferData:`（:71-73）加 `if(!tmpData || tmpData.length==0) return;`。
5. `WuKongIMSDK/Classes/coder/proto/WKSendPacket.m` `encodeLM:`（:43-50）改用 `if(payloadEnc && [payloadEnc dataUsingEncoding:NSUTF8StringEncoding])` 分支赋值；失败时打 `warn: WKSendPacket payload 加密失败，将以空 payload 编码 clientMsgNo:%@` 并 `packet.payload=[NSData data]`。
6. `WuKongIMSDK/Classes/coder/WKCoder.m` `encodeLM:`（:41-45）bodyBytes 为 nil（packetType 无编码器）时打 `warn: WKCoder 未找到 packetType=%d 的 body 编码器，按空 body 编码` 并退化为 `[NSData data]`。
7. `WuKongIMSDK/Classes/manager/WKMessageQueueManager.m` `flushQueue:`（:161-166）encode 返回 nil 时打 `warn: WKMessageQueueManager 编码发送包失败，已跳过 clientMsgNo:%@` 并 `continue`。
C. 让根因可观测：
8. `WuKongIMSDK/Classes/manager/WKSecurityManager.h`（:44-47）新增 `-(BOOL) isAesKeyReady;`；`.m`（:105-107）实现 `return self.aesKey.length > 0;`。
9. `WuKongIMSDK/Classes/manager/WKConnectionManager.m` `handleConnected:`（:1006-1010）在 `generateAesKey:salt:` 之后判断 `isAesKeyReady`，未就绪则打 `warn: 连接已建立但 AES 密钥未就绪（serverKey/salt 非法或 DH 协商失败），发送的消息将无法加密`。
对应 Android 提交：`98c2b88`/`25caa7a` 的「加密失败返回 null」防护思路（Android `CryptoUtils.aesEncrypt` 返回 null、调用方判空），iOS 此前只做了 decrypt 侧（R28）。

### 31.3 判定
- 不改「协商失败仍允许连接」的降级策略（与 Android 一致：连接可用于收包/重连，发送会失败）；只把静默错误密文改为显式失败 + 告警，避免服务端收到永远解不开的消息。
- 空 key 时 `aesEncrypt` 现在返回 nil，因此 B 项 4-7 的 nil 防护是本轮 A 项的必要配套（否则把「静默错误密文」换成「崩溃」）。
- `aesDecrypt` 全零 key 本就会 CCCrypt 失败返回 nil，R28 已在 `WKRecvPacket` 兜底为空 payload；本轮加守卫只为提前告警，行为不变。
- 排除项：Android `137813f`（member 头像缓存 key）— iOS `WKChannelMember`（`WKChannelMemberDB.h`:26-49）无该属性、`toMemberModel:` 也不读该列，不移植；`38c916f`/`6d92c78`/`cd8d574`/`05a454b`/`dc2b1a9` 均为 Android 专属结构或已被 iOS 等价实现覆盖。

### 31.4 验证
- `cd Example && xcodebuild -workspace WuKongIMSDK.xcworkspace -scheme WuKongIMSDK -sdk iphoneos -configuration Debug -derivedDataPath /tmp/wkdd_r31 CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build` → **BUILD SUCCEEDED**，`error:` 计数 0；本轮 7 个源文件无新增告警（唯一的 `WKConnectionManager.m:1130` retain-cycle 警告为既有的、不在改动区域内），日志 `/tmp/wk_build_r31.log`。

---

## Round 32 — 回应入库不再谎报成功：批量写失败回滚 + 失败不通知 delegate（2026-10-11）

### 32.1 背景
- 承接 Round 31/26 的「DB 写失败静默」主题与本轮待办 #3：`WKReactionDB.insertOrUpdateReactions:`（`WuKongIMSDK/Classes/db/WKReactionDB.m`:90）与 `insertOrUpdateReactions:db:`（:100）无条件 `return true`，循环内 `[db executeUpdate:SQL_INSERT_REACTIONS,...]` 的返回值被丢弃，入库失败无任何告警。
- `WKReactionManager.sync:`（`WuKongIMSDK/Classes/manager/WKReactionManager.m`:90-92）拿到回应后先入库、紧接着 `callReactionManagerChangeDelegate:` 通知 UI，从不检查入库结果 → 若写库失败，UI 展示实际未落库的回应，重启后丢失。
- 对照 Android `MsgReactionDBManager.insertReactions`（`wkim/src/main/java/com/xinbida/wukongim/db/MsgReactionDBManager.java`:35-58）：用事务 + `setTransactionSuccessful()`，异常时只 `endTransaction()`（等价回滚），即 Android 失败会整批回滚；iOS 此前既不回滚也不上报。Android 消费方 `MsgManager`（`MsgManager.java`:1007-1017）写库后再 `getMsgReactionsAndRefreshMsg` 从 DB 重建，UI 以 DB 为准；iOS 直接拿服务端对象通知，缺少这层一致性。
- 另：`[WKDB sharedDB].dbQueue` 为 nil（DB 未打开，`WKDB.switchDB:` 失败时置空）时 `inTransaction:` 是 no-op，原实现直接返回 true（谎报成功）。

### 32.2 改动（3 个文件 / 3 处）
1. `WuKongIMSDK/Classes/db/WKReactionDB.m` `insertOrUpdateReactions:`（:90-112）：空数组早退 YES；`dbQueue == nil` 时打 `WARN: 回应入库失败：数据库不可用` 并 return NO；事务内逐条检查 `executeUpdate:` 返回值，任一条失败则 `success = NO`、打 `WARN: 回应入库失败已回滚 ... error:%@`（`db.lastErrorMessage`）、`*rollback = YES` 并结束；返回真实 `success`。
2. 同文件 `insertOrUpdateReactions:db:`（:114-132）：空数组/`db == nil` 早退与告警；逐条检查返回值，失败打 `WARN: 回应入库失败(事务内) ...` 并返回真实结果（**不**主动回滚外层事务，避免单条回应失败导致整条消息丢失；回滚交由调用方 `WKMessageDB` 的事务决定）。
3. `WuKongIMSDK/Classes/manager/WKReactionManager.m` `sync:`（:90-97）：检查返回值，失败时打 `WARN: 同步回应入库失败，本次不通知 delegate（下次同步将重试）...` 并 `return`，不再通知 delegate；成功才 `callReactionManagerChangeDelegate:`。
- `WuKongIMSDK/Classes/db/WKReactionDB.h`（:30-40）补充两个方法的返回值语义注释。

### 32.3 判定
- 不移植 Android 的「写库后 query 回读刷新 UI」做法：iOS delegate 收到的就是服务端原样对象，与刚写入的整批数据一致，无需再查库；只在失败时停止通知即可。
- `insertOrUpdateReactions:db:` 选择「记录失败但不由本方法回滚」：它被 `WKMessageDB.saveMessages:`（:245）与 `replaceMessages:`（:293）在消息落库事务内调用，若在此回滚会连消息一起丢；R26 已让消息落库失败被识别并跳过，回应失败只降级为告警。
- `WKMessageDB` 两处调用仍忽略返回值（消息保存不应因回应写失败而失败），但失败现在有 `WARN` 可观测。

### 32.4 验证
- `cd Example && xcodebuild -workspace WuKongIMSDK.xcworkspace -scheme WuKongIMSDK -sdk iphoneos -configuration Debug -derivedDataPath /tmp/wkdd_r32 CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build` → **BUILD SUCCEEDED**，`error:` 计数 0，三个改动文件无新增告警，日志 `/tmp/wk_build_r32.log`。

## Round 33 — 其余批量写不再静默丢失：会话/提醒/成员入库失败整批回滚 + 失败不通知 UI（2026-10-12）

### 33.1 背景
- 承接 Round 32 的「DB 写失败静默」主题与本轮待办 #3：以下批量写方法在事务内循环 `[db executeUpdate:...]` 但完全丢弃返回值，任一行失败既不回滚也不告警，调用方仍按「已落库」继续刷新 UI：
  - `WKConversationDB.replaceConversations:`（`WuKongIMSDK/Classes/db/WKConversationDB.m`:90）——同步最近会话时整批替换；
  - `WKConversationExtraDB.addOrUpdates:`（`db/WKConversationExtraDB.m`:45）——草稿/预览位置等会话扩展；
  - `WKReminderDB.addOrUpdates:`（`db/WKReminderDB.m`:58）——提醒项；
  - `WKChannelMemberDB.addOrUpdateMembers:`（`db/WKChannelMemberDB.m`:137）——群成员。
- 另外三处 `extraToStr:`/`dataToStr:`（`WKConversationDB.m`:355、`WKChannelMemberDB.m`:403、`WKConversationExtraDB.m`:67 / `WKReminderDB.m`:254）在 JSON 序列化失败时 `[[NSString alloc] initWithData:nil ...]` 会返回 **nil**，而对应列 schema 为 `not null default ''`（`Assets/Migrations/202204121358.sql`：reminders.data、conversation_extra；`Assets/Migrations/201911270513.sql`：conversation.extra、channel_member.extra 均为 `text not null default ''`）——绑定 nil 即 NULL，整行写入必然失败且被静默忽略。
- `[WKDB sharedDB].dbQueue` 为 nil（DB 未打开，`WKDB.switchDB:` 失败时置空）时 `inTransaction:` 是 no-op，原实现直接「成功」返回。

### 33.2 改动（10 个文件 / 12 处）
1. `db/WKConversationDB.m` `replaceConversations:`（:90）：改返回 `BOOL`；`dbQueue==nil` 打 `WARN: 最近会话批量替换失败：数据库不可用` 返回 NO；`extraToStr:` 结果 `?:@""` 兜底；逐条检查 `executeUpdate:`，失败打 `WARN: 最近会话批量替换失败已回滚 ... error:%@`（`db.lastErrorMessage`）、`*rollback = YES`、返回 NO。`db/WKConversationDB.h`:29 同步签名与注释。
2. `db/WKConversationExtraDB.m` `addOrUpdates:`（:45）：改返回 `BOOL`；`dbQueue==nil` 告警返回 NO；`channelId` 补 `?:@""`；逐条检查，失败 `WARN: 最近会话扩展入库失败已回滚 ...` + 回滚 + NO。`db/WKConversationExtraDB.h`:17 同步。
3. `db/WKReminderDB.m` `addOrUpdates:`（:58）：改返回 `BOOL`；`dataToStr:` 结果 `?:@""` 兜底（新增，修 `data` NOT NULL 失败）；逐条检查，失败 `WARN: 提醒项入库失败已回滚 ...` + 回滚 + NO。`db/WKReminderDB.h`:18 同步。
4. `db/WKChannelMemberDB.m` `addOrUpdateMembers:`（:137）：改返回 `BOOL`；`extraToStr:` 结果 `?:@""` 兜底；逐条检查，失败 `WARN: 成员入库失败已回滚 ...` + 回滚 + NO。`db/WKChannelMemberDB.h`:62 同步。
5. 调用方——失败即跳过本地 UI 通知（延续 R32「失败不通知 delegate」）：
   - `manager/WKConversationManager.m` `replaceConversations:` 处（:244）：失败打 `WARN: 最近会话批量入库失败，跳过通知` 并 return，不再 `callOnConversationUpdateDelegates:`；
   - 同文件 `syncExtra`（:263）：失败打 `WARN` 并 return，不再 `updateConversationExtras:`（该方法从 DB 回读，写库未成功则回读无意义）；
   - 同文件 `updateOrAddExtra:`（:273）：失败打 `WARN: 最近会话扩展入库失败，跳过本地通知与上传` 并 return，跳过本地 delegate 通知与 `updateConversationExtraProvider` 上传；
   - `manager/WKReminderManager.m` `sync`（:126）：失败打 `WARN: 提醒项批量入库失败，跳过缓存失效与通知` 并 return，不再 `invalidateCacheForReminders:`/`updateConversations:`；
   - `manager/WKChannelManager.m`:270 仍忽略返回值（成员同步失败下次同步重试），但 DB 层已有 `WARN` 可观测。

### 33.3 判定（Android 对照）
- 对应 Android：`ChannelMembersDbManager.insertMembers`（`wkim/src/main/java/com/xinbida/wukongim/db/ChannelMembersDbManager.java`:213-236）、`ConversationDbManager` 会话扩展批量写（`ConversationDbManager.java`:514-534）、`ReminderDBManager` 提醒批量写（`ReminderDBManager.java`:210-228）——均用 `db.beginTransaction()` + `setTransactionSuccessful()` + `finally endTransaction()`，异常时未 `setTransactionSuccessful` 即等价整批回滚。iOS 本轮补齐这一「失败整批回滚」语义。
- Android 的 `catch (Exception ignored)` 同样吞掉异常，只是事务保证回滚；iOS 在此之上额外打 `WARN` 并把结果返回给调用方，使其能停止 UI 通知——强于 Android。
- 未改动 `WKChannelManager.addOrUpdateMembers:`（manager）签名：它只负责清缓存 + 落库，失败对调用方无不同处理，保持 void 最小侵入。
- `WKConversationDB.extraToStr:`/`WKChannelMemberDB.extraToStr:`/`WKConversationExtraDB.extraToStr:` 的其它调用点（`WKConversationDB.m`:111 `insertConversation:db:` 等）未在本轮收窄，仅在 `replaceConversations:`/`addOrUpdateMembers:` 内兜底——`insertConversation:db:` 走 `addOrUpdateConversation:` 单条路径，失败同样被上层忽略，留待后续轮次评估。

### 33.4 验证
- `cd Example && xcodebuild -workspace WuKongIMSDK.xcworkspace -scheme WuKongIMSDK -sdk iphoneos -configuration Debug -derivedDataPath /tmp/wkdd_r33 CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build` → **BUILD SUCCEEDED**，`error:` 计数 0，日志 `/tmp/wk_build_r33.log`。

## Round 34 — JSON 序列化失败不得返回 nil（写库 NULL 违例根因）+ 消息内容/扩展/回执更新失败可观测（2026-10-10）

### 34.1 背景
- 承接 Round 33 发现的 `extraToStr:`/`dataToStr:` 在 JSON 序列化失败时返回 nil。根因不在调用点，而在 helper 自身：
  ```objc
  NSString *extraStr = @"";
  if(extra) {
      NSData *jsonData = [NSJSONSerialization dataWithJSONObject:extra options:kNilOptions error:nil];
      extraStr = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding]; // jsonData==nil 时返回 nil，覆盖了默认 @""
  }
  return extraStr;
  ```
  `[NSJSONSerialization dataWithJSONObject:...]` 遇到非 JSON 类型（NSDate/NaN/自定义对象等）会返回 nil，随后 `[[NSString alloc] initWithData:nil ...]` 返回 **nil**，把初始的 `@""` 覆盖掉。该 nil 绑定到 `not null default ''` 的 text 列 → 绑定 NULL → 整行写库失败（且此前各版本静默忽略）。
- 对比 Android：`WKMsg.getLocalMapExtraString()`（`wkim/src/main/java/com/xinbida/wukongim/entity/WKMsg.java`:201-208）以 `String extras = ""` 起手，仅在 `localExtraMap != null && !isEmpty()` 时用 `new JSONObject(map).toString()` 覆盖，**永不返回 null**；`WKConversationMsg.getLocalExtraString()`（`WKConversationMsg.java`:44）同理。iOS helper 本意相同，但 `initWithData:nil` 破坏了该保证。
- 与 Round 33 的关系：R33 是在各调用点加 `?:@""` 治标；本轮在 helper 内部根治，覆盖所有（含尚未加兜底的）调用点。

### 34.2 改动（8 个文件 / 12 处）
一、根治 7 个 JSON→字符串 helper：序列化失败时不返回 nil，回退 `@""` 并打 WARN（`NSStringFromClass([self class])`）：
  1. `db/WKMessageDB.m` `extraToStr:`（现 :996）——同时覆盖 message 表 `extra`（`:234` saveMessages / `:321` insertMessage 的绑定）。
  2. `db/WKChannelInfoDB.m` `extraToStr:`（现 :315）——覆盖 channel_info `extra`（`:73`/`:86` SQL_CHANNEL_SAVE、`:95`/`:124` SQL_CHANNEL_UPDATE）。
  3. `db/WKMessageExtraDB.m` `extraToStr:`（现 :139）——覆盖 message_extra `extra`（`:61`/`:88` 未加兜底的调用点）。
  4. `db/WKConversationDB.m` `extraToStr:`（现 :355）——覆盖 conversation `extra`（含 R33 未收窄的 `:123` `insertConversation:db:`）。
  5. `db/WKConversationExtraDB.m` `extraToStr:`（现 :67）。
  6. `db/WKChannelMemberDB.m` `extraToStr:`（现 :403）。
  7. `db/WKReminderDB.m` `dataToStr:`（现 :254）——`reminders.data`。
  统一改法：
  ```objc
  if(!jsonData) { NSLog(@"WARN: extra JSON 序列化失败，回退为空串 %@",NSStringFromClass([self class])); return @""; }
  extraStr = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding] ?: @"";
  ```
二、同类站点：`manager/WKCMDManager.m`:164 `paramStr` 也以 `[[NSString alloc] initWithData:jsonData ...]` 覆盖了 `:152` 的 `@""`，补 `?: @""`（`cmdMessage.param` 最终写入 cmd 表 not null 列）。
三、消息更新失败可观测（`db/WKMessageDB.m`，均为 void，保持签名最小侵入，仅加失败 WARN，不再静默）：
  - `updateMessageContent:status:extra:clientSeq:`（现 :692）——多媒体上传成功后内容/状态落库失败原本无任何日志，重启后丢失 remoteUrl；
  - `updateMessageWithSendackPackets:`（现 :720，逐条）——回执落库失败原本静默，服务端已回执但本地状态停在发送中；
  - `updateMessageVoiceReaded:clientSeq:`（现 :737）；
  - `updateMessageExtra:clientSeq:`（现 :746）。

### 34.3 判定（Android 对照）
- JSON→字符串 helper 的 UTF-8 解码理论上可能返回 nil，但 `jsonData` 来自 `NSJSONSerialization` 必为合法 UTF-8，故实际只在 `jsonData==nil` 时触发；为防御仍加 `?:@""`。
- Android `WKMsg.getLocalMapExtraString()` 在 null/空 map 时返回 `""`，不返回 null；iOS 修复后行为对齐，且额外打一条 WARN。
- 消息 update 的 void→WARN 不改变调用方语义（发送/通知流程不受影响），只补可观测性；未改 `WKMessageDB.h` 签名，避免波及 `WKMediaManager`/`WKChatManager` 调用点。
- 未处理 `WKMOSContentConvertManager.m`:360 `contentJSONStr`（赋给 `contentDic[@"contentJson"]`，nil 等价于删除该 key，无 NULL 绑定问题）与 `WKRSAUtil.m` 的多处 `initWithData:`（结果为临时结构体/返回给调用方判空，非 DB 绑定）。

### 34.4 验证
- `cd Example && xcodebuild -workspace WuKongIMSDK.xcworkspace -scheme WuKongIMSDK -sdk iphoneos -configuration Debug -derivedDataPath /tmp/wkdd_r34 CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build` → **BUILD SUCCEEDED**，`error:` 计数 0，日志 `/tmp/wk_build_r34.log`。

## Round 35 — 编辑正文/提醒项上传重试次数耗尽不再静默（对齐 `retrySend` 的 ed969a1 修法）（2026-10-11）

### 35.1 背景
- 上游 iOS 提交 `ed969a1`（2024-07-04，*fix: maxed the retry count without the delegate callback*）修的是消息发送重试：`retrySend` 原来把「超过重试次数」分支**嵌在内层 `if` 里**（`if(item && retryCount<max){ if(retryCount<max){ ... } }`），导致该分支永远不可达——次数耗尽后消息既不标失败也不回调上层。
- 同一结构在另两条定时重试路径**仍然存在**，两者都只有「未超限则重试」的分支，**没有 `else`**：
  - `manager/WKRetryManager.m contentEditRetryUpload`（改前 :360-385）：`if(item && item.retryCount<contentEditRetryCount){ if(item.retryCount<contentEditRetryCount){ if(...){ ... item.retryCount++; ... [self uploadContentEdit:item.messageExtra]; } } }`；
  - `manager/WKRetryManager.m reminderUpload`（改前 :336-358）：`if(item && item.retryCount<reminderRetryCount){ if(...){ ... item.retryCount++; ... [self uploadReminder:item.reminder]; } }`。
- 后果：次数耗尽后 item **永久留在** `messageExtraRetryDict`/`reminderRetryDict`，每个定时器 tick 空转却不再做任何事——既不标记上传失败，也不通知上层，`removeMessageExtraRetryItem:`/`removeReminderRetryItem:` 永不调用。
- 量化（默认值，`WKOptions.m:23-28`：`contentEditRetryInterval=10`/`contentEditRetryCount=8`、`reminderRetryInterval=10`/`reminderRetryCount=20`）：定时器周期为 `interval/2`（:283/:316）即 **5s**，8 次在 **40s** 就耗尽重试计数；而 `startMessageExtraRetry` 的时间窗是 `editedAt + 10*8 = 80s`（:270）——即 **后半段 40s 完全不再尝试上传**。提醒项更糟：`startReminderRetry`（:303-333）没有时间窗分支，只在 start 时靠 `updateExpireDoneUploadStatusFail:`（:305）按龄批量置失败，运行期耗尽后不会有任何失败状态写入。

### 35.2 改动（1 个文件 / 2 处）
`manager/WKRetryManager.m`：
1. `reminderUpload`（现 :336-363）：显式 `if(!item) continue;`，并把超限分支补成 `else`——`[self removeReminderRetryItem:key]` + `[[WKReminderDB shared] updateUploadStatus:WKReminderUploadStatusError reminderID:@(item.reminder.reminderID)]` + `NSLog(@"WARN: 提醒项上传重试次数已耗尽，标记为上传失败 reminderID:%lld key:%@", ...)`。
2. `contentEditRetryUpload`（现 :365-397）：删去重复的嵌套 `if(item.retryCount<contentEditRetryCount)` 判断，显式 `if(!item) continue;`，超限分支补成 `else`——`[self removeMessageExtraRetryItem:key]` + `[[WKMessageExtraDB shared] updateUploadStatus:WKContentEditUploadStatusError withMessageID:item.messageExtra.messageID]` + `WARN` 日志 + `getMessageWithMessageId:` 后 `[[WKSDK shared].chatManager callMessageUpdateDelegate:message]`（与 `startMessageExtraRetry` 超时分支 :273-278 完全一致）。

### 35.3 判定（Android 对照 / 不移植说明）
- **无对应 Android commit**：Android 仓库全量 grep `retryCount|contentEditRetry|reminderRetry|maxRetry` 只有 `ConnectionClient.java:88-95` 的连接超时 `MAX_TIMEOUT_RETRIES`，没有编辑正文/提醒项的重试实现（Android 侧不重试这两类上传）。故本轮是 iOS 自身 bug 修复，非移植。
- 修法刻意对齐 iOS 自身 `retrySend`（`ed969a1`）的既有语义：**超限 → 移出重试队列 + 标记失败 + 通知上层**，避免为两条路径发明第三套行为。
- 提醒项未新增 delegate 回调：`WKReminderManagerDelegate` 只有 `reminderManager:didChange:reminders:`（`WKReminderManager.h:22-29`，语义是某频道提醒列表变化），而上传状态「只对本地生效」（`WKReminder.h:41`）；现有 `uploadReminder` 出错路径（:404-405）也只写 DB 不回调，故本轮只补 `WARN` 使其可观测，保持一致。
- 未改 `WKRetryManager.h` 方法签名；`addMessageExtra:`/`addReminder:` 的 `retryCount=0` 初值不变。

### 35.4 验证
- `cd Example && xcodebuild -workspace WuKongIMSDK.xcworkspace -scheme WuKongIMSDK -sdk iphoneos -configuration Debug -derivedDataPath /tmp/wkdd_r35 CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build` → **BUILD SUCCEEDED**，`error:` 计数 0，日志 `/tmp/wk_build_r35.log`。

---
## 待办（后续轮次）
- Round 36 候选（按优先级）：
  1. `WKChatManager` 发送/重发与 DB 写入链路继续下钻（`saveMessage:...` 忽略 `WKMessageDB` 落库结果；`WKMessageDB` 其余 void update：`updateMessageStatus:withClientSeq:`、`deleteMessagesWithClientSeqs:`、`destoryMessage:` 等失败处理）。
  2. `WKConversationManager.addOrUpdateConversation:incUnreadCount:` 返回的 `WKConversationAddOrUpdateResult` 被 `WKChatManager.addOrUpdateConversationWithMessages:`（:719-733）完全忽略，单条会话写失败仍通知 UI。
  3. `WKConversationDB.insertConversation:db:`/`updateConversation:db:`、`WKChannelMemberDB.deleteMembers:`、`WKConversationExtraDB.updateVersion:` 等单条写仍忽略 `executeUpdate` 失败，评估是否统一上报。
  4. `WKConnectionManager` 非 isDebug 日志是否有 payload/敏感信息打印（R30/R33 已复核为异常路径、保留）。
  5. 复查 `WKCoder.encodeLM:` 空 body 退化是否会让服务端拒包（R31 已改为不崩溃）。
  6. Android 未移植提交继续扫描——本轮已确认近期（2025-2026）未移植提交几乎全是 Java/连接池/新功能，iOS 可移植面基本耗尽（PR #24 索引已 R3 移植；PR #25/#26 是 Android 关闭 DB 竞态，iOS 无 DB 关闭路径；9d07754 是 rawQuery→select，iOS 已用占位符绑定）。
- 纯新功能（非稳定性，单独评估）：`ce1086b`/`ff7196b` 设置设备信息、`4f917b7` 添加单个频道成员、`b3e8e11` 连接节点、`3904ad5` 频道状态。
