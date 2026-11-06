# MijiCore 冻结来源与维护边界

本目录是 Wumi 的本地 vendored SwiftPM 包，不通过符号链接或运行中的觅迹 App 提供能力。

## 本次冻结

- 来源：觅迹本机开发工作树（只读复制）。公开仓库不记录本机路径，`SOURCE_MANIFEST.json` 的 `source` 字段同样改为仓库名。
- 来源仓库：https://github.com/kbwumin13-sudo/miji.git （从源仓库 origin 只读核对，本次未联网）。
- 源 HEAD：`2b97bd2ec0aeab241d17c8352d99fff1ddac2ec5`。
- 冻结日期：2026-10-21；精确本地时间见证据目录的 `source-manifest.json`。
- 本次取自实际工作树，**并非仅取 HEAD**；保留 MijiCore 的未提交元数据写入、名称去重、类型过滤与缓存增强，以及 OilFind 名称核心的本地修改和新增实现。
- 43 个原始文件中有 10 个相对 HEAD 修改、3 个尚未跟踪。每个文件的工作树 SHA-256、HEAD SHA-256（如有）、字节数、来源状态见证据目录的 `source-manifest.json`；完整原始字节存于 `source-snapshot.tar.gz`，已跟踪改动另有 `source-dirty.patch`。原项目未被写入。
- 2026-10-21 冻结仅包含 Core；2026-10-23 另从同一本机 MIT 项目的 `Sources/MijiApp/MainView.swift`、`AppModel.swift` 和 `SearchKeyAction.swift` 移植搜索界面、分阶段查询及键盘行为到 Wumi 的 `MijiSearchView.swift`、`MijiSearchModel.swift` 和 `MijiSearchKeyAction.swift`。界面沿用觅迹原设计，索引生命周期改接 Wumi 既有单宿主。原项目只读，没有复制数据库、索引缓存、用户配置或其他项目记忆。

证据目录（相对 Wumi 根）：`artifacts/desktop-search-implementation-20261021/miji-vendor/`。该目录是本地验收材料，不随公开仓库发布。

## SwiftPM 与 helper

包要求 macOS 14、Swift tools 5.9，使用 Swift 5 语言模式。仅导出：

- `MijiCore` 库；依赖内部 target `CSQLite`、`CContentIndex`、`OilFindCore` / `COilFind`。
- `miji-extract` 可执行 helper（target 名保留 `MijiCLI`），调用协议为 `miji-extract extract --file FILE`，stdout 是 `ExtractedContent` JSON，失败退出码为 1、stderr 提示错误。

保留全部 MijiCore 源码。helper 从原 MijiCLI 提取 `extract` 分支并收窄参数，不提供 index/migrate/benchmark/search/roots 等诊断命令。`IsolatedContentExtractor` 的 `extract --file` 协议继续沿用。Wumi 的 `MijiIndexHost` 管理数据库写入和索引生命周期，应用包通过 `Contents/Helpers/miji-extract` 提供按需提取能力；不依赖独立觅迹 App。

不引入 MijiApp、独立 MijiAppUI、MijiAppTests，不声明远程包依赖。P0 仅冻结依赖；后续 Wumi 根包已声明本地 MijiCore 依赖。生产迁移、扫描、应用安装和最终窗口验收由 Main 执行，fixture 检查不代替这些验收。

## 许可

- Miji：MIT，Copyright (c) 2026 kbwumin13-sudo，原文见本目录 `LICENSE`。
- Oil Find：MIT，Copyright (c) 2026 Lin Zhihuang，原文见 `Vendor/OilFind/LICENSE`；其固定上游为 v1.6.2 / `0fdc2f3ebd4fb08a020358503d4401fab358b026`，保留 `Vendor/OilFind/UPSTREAM.md` 说明。
- OilFind 的 `DeduplicatedNameIndex.swift` 等本地增强也随本次工作树冻结，不能只用 Oil Find 上游 tag 重建本包。
- SQLite 通过系统 `sqlite3` 链接；Apple SDK 框架由系统提供，未捆绑这些二进制。
- 许可清单见证据目录 `licenses.json`；本包后续随应用分发时需携带上述 MIT 版权和许可原文。

## 维护规则

本目录由 Wumi 维护。禁止同步时直接用源 HEAD 或上游版本覆盖当前树；升级须重新记录源 HEAD、dirty 状态、逐文件摘要与许可证，逐项审阅本地适配并运行 fixture 回归。源项目继续独立开发，本目录不会反向写入源项目。

`SOURCE_MANIFEST.json`、`SOURCE_FILES.sha256` 和证据目录的原始归档始终表示 P0 捕获的来源字节，不是当前适配后源码的成品摘要；原始来源记录不能被本地修改覆盖。P0 的 `verify.py` 中“未适配文件与来源相等”检查只适用于 P0 状态，不能据此拒绝下列已授权的后端适配。

## Wumi 后端阶段的本地适配

- `NameSearchEngine.swift` 增加完整名称命中的同步流式 API `forEachNameMatch`（单词或多词 AND）和 `indexedCount`，不先取前 N 条再执行 Wumi 过滤/计数。`NameMetadata` 仍只常驻原有紧凑名称元数据，没有新增全盘路径或 FileRecord 副本。
- `Models.swift` / `FileScanner.swift` / `SearchDatabase.swift` 和新增 `WumiCatalog.swift` 保留创建时间、目录与包标识。新增 `wumi_file_metadata` 附加表，支持旧 schema 2 缺少该表时只读查询，并由可写打开补表；不清空旧 files、正文、OCR 或根配置。catalog API 按 ID 分页传递有界记录，正文候选通过 FTS 召回并由调用者校验完整 AST。
- `WumiCatalog.swift` 提供显式 SQLite backup，包含已提交的 WAL 内容；`DatabaseLease.swift` 为目标库提供跨进程占用锁。Wumi 的显式迁移入口是 `MijiIndexHost.backup(from:to:isCancelled:)`，不自动寻找或读取觅迹生产源库。backup/helper 生命周期后续由 Main 指定的对应负责人继续维护。
- `IndexService.swift` 增加停止屏障供宿主退出使用；Wumi 通过单个宿主管理扫描、监听、内容提取和名称缓存。显式 fixture 只读模式不启动这些索引任务，也不启用未索引目录的临时扫描。
- `MijiSearchBackend.swift` 位于 Wumi Core，保留 Wumi AST 的树语义，复用原条件执行器；正文未知时的 AND/NOT 不生成伪命中。普通名称走上述名称核心；高级名称叶子使用同一核心的查询内命中 ID 集，避免 SQL LIKE 全表补召回。临时目录索引由 Main 限为最多两个、30 秒过期，供有界按需查询使用。
- 历史记录缺少 `created` 时，不在候选批次构造阶段读取文件元数据。只有 AST 实际到达创建日期谓词，或完整 AST 已确认匹配且需要 `.created` 排序时，才对在线缺失项读取 URL 的 creationDate。AND 内稳定地优先执行名称、glob、扩展名、大小等纯内存条件，不跨 OR/NOT 搬动谓词；日期范围沿用 Wumi 原有编译器，正文未知的三值逻辑保留。每条记录当前评估中的成功、失败读取都只发生一次，过滤与排序共享结果，后续查询重新解析。已有存储日期优先，离线/不可读/已不存在的缺失日期保持 nil；普通名称及其他排序零创建日期读取。排序仍检查全部已匹配项以保证全局 top-K，不只补显示的前 N 条。此补齐不回写数据库、不重建索引，也不建立持久路径缓存。

### 整词与逐字拼音兼容

Oil Find 的逐字读音可能与 Miji 原有 CFString 整词读音不同，例如 `重庆音乐.txt` 的 `zhongqing` / `chongqing`。`CompactNameIndex.swift` 现在保留逐字全拼/首字母，并在整词全拼/首字母不同时追加别名；名称去重后每种中文名只在构建时计算一次，ASCII 路径保持原优化。普通候选和高级名称 AST 都接受这组键，包含多词、排除和混合正文条件；大小写敏感模式继续按原名匹配。

别名复用现有紧凑字节列，只为不同键增加字节；使用 `0xff` 隔开，合法 UTF-8 查询不可能跨别名边界产生伪命中。没有新增全文路径列、SQL LIKE 兜底或另一份全量名称索引。原有 C matcher、名称去重和 core 快照字段布局继续沿用。

`NameSnapshotCache` magic 从 `MJNAME01` 改为 `MJNAME02`，让缺少整词别名的旧名称缓存一次性失效并从 catalog 重建；只影响派生名称缓存，不修改数据库记录或正文。下一次可写宿主安静退出可保存新缓存，之后 warm load 保留两组拼音。首次加载可能比原缓存恢复更慢，生产规模耗时及新增键字节数须由 Main 单独测量，不能套用旧缓存基线。

## Wumi 资源占用阶段的本地适配（2026-10-24）

诊断见 Wumi 根目录 `artifacts/weight-diagnosis-20261024/`（本地记录，不随公开仓库发布）：整盘扫描首尾相接、每轮逐行改写 generation，日用版扫描期写盘约 9–19 GiB/小时。

- 扫描只写新增和变化的行。`SearchDatabase.upsertScannedFiles` 对未变行只做查询，把行 ID 记入 `FileIDSet`；`finishScan`/`finishIncrementalScan` 的 `seen` 版本按这组 ID 删除范围内未见的行，在线、启用与保护路径规则同原 generation 版本。原 generation 接口和测试保留。
- `IndexService` 把整根协调请求（`IncrementalIndexState.FullRescan`）和路径队列分开：新根、重新连接、路径变化、手动重建与重新启用立即执行；丢事件、根变化等自动请求在上一次整根扫描完成 30 分钟后才执行，等待期间路径变更照常处理。丢事件和 RootChanged 只作用于事件所属的根，根目录自身的元数据事件不再触发整根扫描。中断的扫描在重启后从范围起点重来，不再保存遍历栈；旧状态文件读取时迁移。事件检查点每 30 秒批量写入。
- 索引队列改为 background QoS，活动断言改为 `.background`；使用电池、低电量模式或温度过高时暂停正文提取和自动整根协调，路径变更照常更新。整根请求原因、开始、完成（写入与删除行数）和电源状态通过 `os.Logger`（subsystem `local.miji`）记录。提取 helper 也以 background QoS 运行。
- `FileWatcher` 在 FSEvents 队列只转交事件，过滤与入队在单独队列执行；路径规范化在加锁前完成，每个事件和每个根各一次。路径入队只追加，合并与去重在取出队列、写盘或超过 4,096 条时进行。
- 待处理路径合并时，上限改为 8,192 条，并且不越过第 4 层目录；合并后仍超过 16,384 条，就改为一次推迟执行的整根协调。原先上限是 2,048 条，超过后会一路合并到 `Users/<name>` 这类宽范围，整根扫描一结束又几乎重扫一遍。
- 子树范围查询拆成“路径本身”和“后代区间”两条语句。原 `relative_path=? OR (relative_path>=? AND relative_path<?)` 只能用到 `root_id`，每次局部扫描的清理都会读完该根的全部索引项（生产库约 400 万行）。`finishIncrementalScan` 两个版本和名称引擎的回退刷新都已改写。
- 名称快照改为直接映射缓存文件。`OilFindCore/MappedStorage.swift` 提供私有映射、对齐分段写入器和 `SegmentedArray`（映射段加内存追加段，映射段的写入只落在进程私有页）。`NameSnapshotCache` 升为 `MJNAME03`，各列按 16 字节对齐分段并以 SHA-256 校验；`MJNAME02` 读取一次后改写。从 SQLite 或旧缓存建成的快照立即写成映射缓存；内存追加行超过 262,144 行，或未排序尾部/墓碑过多时，宿主在 utility 队列压缩重写。搜索面板显示时预读映射。

## Wumi 索引时间片适配（2026-10-26）

`IndexWorkScheduling` 为目录元数据和正文提取提供有界时间片。目录保留扫描会话、迭代器及已见 ID，真正遍历完成才清理过期行；整根核对和局部变更可交替推进，局部已核对范围保护同期新插入项。所有根和范围共享元数据时间及条数预算，短文件范围在同片继续处理，随后通过 `asyncAfter` 让出队列。正文在文件边界检查预算，不因超时片而取消有效 OCR。静止时停止续片，停止服务会取消等待中的工作。真实写入和清理才通知目录变化。

Wumi 的本地键鼠事件接入已有 `setUserActive` 门控，输入停止 350ms 后恢复；仅保持前台不暂停索引。稳定续片不再提前保存事件检查点，普通事件保留原有 30 秒合并落盘，根变化、范围接管/完成与停止仍可靠保存。范围、持久格式、全文/OCR 和电源策略保持原有契约。调度测试使用可注入时钟和排队器验证多次让出后的完整性、批量增量吞吐、全盘与局部及多根公平、输入暂停恢复、停止、静止不空转和事件落盘后重放。

## 本地验证

在本目录执行 `swift test -c release`。只复制了六个以临时 SQLite 或内存构造数据的上游测试文件，另增 `VendoredFixtureTests.swift` 验证全文及固定 OCR 结果持久化、只读重开与离线/恢复查询，`WumiCatalogTests.swift` 验证旧 schema 补表和 WAL backup。未复制上游生产扫描器、IndexService 或真实 OCR 提取测试；`ScanSchedulingTests.swift` 是 Wumi 自己的扫描写入、范围清理、事件分流、状态迁移与冷却/电源调度测试，`NameSnapshotCacheTests` 和 `DeduplicatedNameIndexTests` 覆盖 v3 映射、v2 转换、映射后变更与压缩。名称大规模基准默认条件跳过，需显式环境变量才运行；本轮未启用。

整词/逐字拼音、别名边界、序列化/缓存重启、旧 magic 失效回归分别位于 `NameSearchEngineTests`、`DeduplicatedNameIndexTests`、`NameSnapshotCacheTests`。Wumi 的真实临时文件创建日期补齐、完整排序计数与名称/高级查询拼音一致性回归位于根包 `Tests/DirDeskCoreTests/MijiBackendTests.swift`；读取计数回归覆盖名称/glob 先排除、跨批次候选、重复日期及失败读取仅一次、排序只读取已匹配在线缺失项、OR 短路、NOT/未知正文、取消后不发布行。所有数据库和文件均由测试在临时目录创建，不访问生产库或 Main 的生产副本。

## 觅迹 1.2.0 预览与定位同步（2026-10-31）

本轮来源为独立觅迹的公开 tag `v1.2.0` / commit `56c3cd9bd6d764fd1e0a7202a8dade40cd7ae68c`（https://github.com/kbwumin13-sudo/miji/releases/tag/v1.2.0）。原 P0 来源清单仍保留，未覆盖。新清单 `PREVIEW_SYNC_1_2_0.json` 记录本轮上游文件摘要和 Wumi 对应位置。

- Core 定向合入 `ContentPageRange`、可选 `ExtractedContent.pageRanges`、提取上下文的UTF-8范围及PDF文字层／OCR按页记录；兼容旧JSON和既有schema。Wumi额外文件元数据、目录扫描、索引时间片、名称映射缓存、后台QoS和提取进程树回收均保留。
- UI 由 Wumi 的 `Sources/DirDesk/Search/MijiSearchModel.swift`、`MijiSearchView.swift`、`MijiSearchKeyAction.swift` 及新增的 `MijiPreviewResolver.swift`、`MijiPreviewMedia.swift`、`MijiResultPreviewPane.swift` 承接；全局面板尺寸适配位于 `GlobalSearchController.swift`。窄嵌入区域改为上下布局。
- 右侧预览、摘要高亮、文件复制、PDF匹配页／阅读窗口、代码行定位、网格与按需媒体播放复用 Wumi 唯一宿主的只读连接；没有新增索引写入者，不自动读取或迁移独立觅迹的生产数据库。可见性门控、名称刷新与正文缓存、文件操作和定位回调继续沿用Wumi契约。
- 新增 `PDFPageMapTests.swift`（按本地codec入口适配），扩展应用的 `DebugMijiRun` 验收代码行、页码、离线映射、版本变化、预览去重与隐藏释放、剪贴板和焦点。验收与构建日志在根目录本地 `artifacts/miji-1.2.0-sync-20261031/`，不随公开仓库提交。

## 觅迹 1.2.1 自适应预览同步（2026-11-07）

来源为独立觅迹 1.2.1 的 `97b21e69eadeeae7e289c3e9b41214db6e2aaa92`，文件来源摘要见 `PREVIEW_SYNC_1_2_1.json`。此次仅适配搜索 UI；沿用已交付 Wumi 1.2.4 基线，索引宿主、只读 UI 连接、扫描调度和持久格式保持原样。

- `MijiSearchPreviewPolicy` 用结果元数据选择自动／显示／隐藏模式；纯应用、文件夹、压缩包和无正文的其他文件采用紧凑列表。整组结果决定分栏，选择和异步加载结果不改变窗口尺寸。手动模式在本次搜索会话内保留。
- 内容预览保留 PDF 页码、代码行、正文和按需媒体播放，固定文件头与操作、可滚动正文和可复制路径；加载与失败状态使用原生控件。窄嵌入视图继续使用上下布局。
- 预览只为可见且有内容的选中结果加载；隐藏／关闭取消任务并释放模型内容与 PDF，缩略图取消生成并受原有 24 MiB 缓存上限和关窗清理约束，媒体卸载时停止并释放播放观察。
- `DebugMijiRun` 继续仅在显式临时数据库和只读模式运行，补充自动紧凑、手动模式、混合结果稳定尺寸和隐藏释放回归。

本地 TXT／Markdown／代码没有索引正文时，保留系统原文件预览回退；此回退不提取或写入索引。Wumi 的 GeometryReader 分栏显式填满可用尺寸，保留 800 点紧凑、1060 点分栏及窄嵌入上下布局。

## Wumi 升级与通知契约修复（2026-11-07）

- 保留旧版显式保存的排除项；缺少旧键时继续沿用迁入目录的原默认。用户保存但尚未应用的目录设置记录为 pending，宿主成功应用相同快照后才清除；已单独禁用的根不因应用列表而启用。
- 加载期间的索引选项通过 pending host 交接，宿主启动使用最新配置。目录事件先发布当前根元数据，查询计划再刷新。
- `IndexService.onContentChange` 只在原有正文完成／失败提交后发通知，不改变提取、写入、扫描或调度逻辑。Wumi 将其合并为正文代次，使旧正文缓存失效；普通目录元数据仍复用缓存，可见性与两秒限频保持。首次索引就绪和正文删改可在查询不变时更新。
