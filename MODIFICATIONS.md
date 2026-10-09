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

## 待办（后续轮次）
- Round 15 候选：复核 `6d9d6ad` 之后剩余的数据库类提交；`WKChatManager` 的发送/重发与 DB 写入链路交叉复查。
- 纯新功能（非稳定性，单独评估）：`ce1086b`/`ff7196b` 设置设备信息、`4f917b7` 添加单个频道成员、`b3e8e11` 连接节点、`3904ad5` 频道状态。
