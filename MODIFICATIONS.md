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

## 待办（后续轮次）
- Round 7 候选：提醒项内存缓存（`e91952e`/`e91952f`）、closeConnect 重连循环（`f37a1f5`）、在线 cmd ack（`842d29e`/`2498c0f`）、复核 `6d9d6ad`/`6a95caf`/`8ec8e49`。
