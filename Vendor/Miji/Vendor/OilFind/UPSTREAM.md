# Oil Find 名称核心来源与 Miji 适配

- 官方仓库：https://github.com/oil-oil/oil-find
- 固定版本：[v1.6.2](https://github.com/oil-oil/oil-find/tree/v1.6.2)
- 固定 commit：`0fdc2f3ebd4fb08a020358503d4401fab358b026`
- 取得方式：`gh api repos/oil-oil/oil-find/git/ref/tags/v1.6.2` 验证 tag 为此 commit，再通过 `gh api repos/oil-oil/oil-find/tarball/<commit>` 获取官方归档，按路径抽取。
- 许可证：MIT，原文保存在 [LICENSE](LICENSE)，Copyright (c) 2026 Lin Zhihuang。
- 只使用此版本 MIT 开源仓库。未访问、抽取或依赖 Oil Find Pro。

保留的上游文件：

| 路径 | 状态 |
| --- | --- |
| `Sources/COilFind/coilfind.c` | 原样保留，使用其中 SIMD/字节名称匹配 |
| `Sources/COilFind/bloom.c` | 原样保留，与 C 核心共同编译 |
| `Sources/COilFind/include/coilfind.h` | 原文保留，末尾增加 `miji_names.h` 包含 |
| `Sources/OilFindCore/Pinyin.swift` | 保留字符拼音查表算法；增加默认关闭的 `wordInitials` 参数，用于 Miji 混合中英文文件名的拉丁单词首字母 |

本地扩展：`include/module.modulemap` 明确模块头文件；`include/miji_names.h`、`miji_names.c` 提供 Miji 的 AND/NOT 字面子串批量匹配、100/70/70 三列评分和有限并行扫描；`OilFindCore/CompactNameIndex.swift` 提供流式名称构建、紧凑字节列、ASCII 别名和名称列二进制快照。上游的扫描、监听、持久化、完整 Query/Searcher、更新器和 UI 未引入，避免改变 Miji 的查询和文件分类语义。

## 对外契约

`Sources/MijiCore/NameSearchEngine.swift`：

```swift
public init(databaseURL: URL, immutable: Bool = false) throws
public var isReady: Bool { get }
public func invalidate()
public func saveCache() throws
public func load(cancelled: @escaping () -> Bool = { false }) throws
public func refresh(rootID: String, relativePaths: [String], fullRescan: Bool,
                    cancelled: @escaping () -> Bool = { false }) throws
public func search(_ query: String, options: SearchOptions = SearchOptions(),
                   cancelled: @escaping () -> Bool = { false }) throws -> [Int64]
```

- AppModel 共享一个实例，后台调用 `load`；搜索不隐式构建。已就绪时 `load` 直接返回，完整重载先 `invalidate`。
- `immutable=true` 仅用于已关闭并完成 checkpoint 的基准库，连接使用 `file:...?immutable=1` URI，可无 `-shm` 打开 WAL 模式数据库，且不创建 sidecar。实时应用保持默认 `false`。
- 与 `SearchDatabase` 的只读连接独立，逐行只读 `files(id,root_id,name,extension,kind,size,modified)`。没有正文、旧名称规范化列、旧拼音列、FTS 或 `FileRecord` 整库数组依赖。`roots` 查询仅用 `id,online`。
- 名称归一化沿用 Miji 的 NFC + 小写；采用 Miji `QueryParser` 的引号、排除、`ext:`、`kind:`、`path:` 语法。名称引擎的 `.all` 表示全部搜索中的名称分支；`.content` 抛错，由 Main 调用正文接口。
- 结果为原 SQLite `Int64` ID，供 `nameHits` hydrate。名称排序沿用 Miji 的规范化 UTF-8 BINARY 次序，分值/时间/大小降序后按名称、ID 破同分。大小 `Int64`、修改时间 `Double` 不采用上游压缩精度。
- 中文拼音使用上游基本汉字表；加入 Miji 的去分隔符全拼、拉丁单词首字母规则。多音字按上游单字读音表，不声称句子级消歧。非汉字 Unicode 名称沿用 Foundation 拉丁化/去音调。
- ASCII 首字母键构建时预计算，全拼键最多保存 8 字节；键与原名/全拼相同时复用对应列。单词名称即使带前后分隔符，其全拼对字母数字查询也复用原名匹配。较长 ASCII 全拼不复制整名：原名命中时复用结果，否则 `memchr` 定位首字节，仅验证跨分隔符的候选。每次查询不再重新派生首字母键。不保存查询结果缓存，保留 Unicode、NUL、单字、AND/NOT、100/70/70 评分契约。
- 名称字节/偏移和元数据用紧凑列存储，无常驻完整路径。`path:` 查询逐行读取并归一化相对路径，以位图保存合格 ID；路径查询仍需要元数据扫描。
- 仅保留 O(limit) 的 top-K 堆。小索引按 4096 行搜索；至少 32768 行的索引以 32768 行为一批，C 同步扫描最多 4 个 8192 行块，再按原行序合并。每次最多 256 KiB ID/评分 scratch，没有全量结果数组；无名称词的查询采用串行扫描。`forEachMatch` API 不变，callback 与取消检查均在调用线程串行执行；每批扫描前和每 4096 个回调检查取消，throw/取消时 C 工作已完成，不留后台指针。根在线状态每次查询重新读取，离线默认可检索，根下线无需重建。
- `refresh` 在写库提交后调用。规范相对路径包括自身及后代；重复/嵌套路径合并，空路径或 `fullRescan=true` 刷新该根。新增根、改名、分类/扩展名/大小/时间变化、删除均支持。
- Miji v2 数据库以 `catalog_state` / `name_changes` 记录最多10万次名称元数据变化。每个扫描批次通知只读取上次 revision 后发生变化的 ID，包括删除，无需重读整根。旧 fixture 无 journal 时保留根 ID 流式核对作为兼容回退；journal 已裁剪或回退时完整重建。正文更新和仅 generation 变化不进入名称 journal。
- 名称未变化时只更新紧凑元数据；改名追加新名字节、旧条目标为删除。累计删除/改名超过 `max(16384,存活数/4)` 时偶尔全库紧凑重建，控制垃圾条目增长。
- Main 的 `NameSnapshotCache` 把紧凑名称列及元数据保存到数据库旁的 `.names.cache`，通过数据库 inode/device/creation 和 revision 校验。重启补 journal，损坏或变更窗口已丢失则从 SQLite 重建；改名墓碑在启动及刷新时都受压缩阈值限制。应用正常退出后保存，运行中的批次通知不写全量缓存；已有效且无变化的缓存不重写。
- 操作内部串行，`invalidate` 可在构建中立即标记失效。加载/刷新失败或取消不发布部分索引；刷新失败后 `isReady=false`，调用 `load` 恢复。名称字段单个字节列的 32 位偏移容量上限为 4 GiB，超过后明确抛错。

## CompactNameIndex 快照

`public func serialized() -> Data` 与 `public convenience init(serialized: Data) throws` 只读写名称核心列。v1 格式：8 字节 ASCII magic `MIJINAME`、UInt32 版本 1、UInt32 行数；依次为 names/full/initials 的 UInt32 字节数、原始字节、行数 + 1 个 UInt32 偏移；随后为行数个 live 字节、行数个 aliases 字节，最后为此前全部内容的 32 字节 SHA-256。整数固定小端，不依赖 Swift 对象布局。字节列保留起始零哨兵，首偏移为 1。

恢复前检查校验和及最小长度，拒绝未知版本、额外尾部、截断、过大行数、非单调/越界偏移、错误哨兵、非 0/1 live、未知/矛盾 aliases、别名复用列有额外字节、ASCII 标记与名称/键字节不符。损坏时抛 `BuildError.invalidSerializedData`，不发布部分索引。保留删除项及行序，恢复后支持 append/remove。没有 FileRecord、DB 身份/版本、路径或元数据；NameSnapshot 元数据、DB inode/revision 关联、持久化与失效回退由 Main 负责。

## 验证

`Tests/MijiCoreTests/NameSearchEngineTests.swift` 直接建立无正文、无旧拼音列、无 `name_fts` 的临时 SQLite fixture。覆盖中文短词/拼音、引用与排除、类别/扩展名/相对路径、多根离线、排序与 Int64 ID、Unicode 归一化/NUL/名称边界、局部刷新/删除/新根、取消/失效恢复、并发共享与只读 WAL 连接。

执行命令及实际日志由 `output/name-core-build/` 保存；该独立 scratch path 不占主 build 锁。小 fixture 的时间不代表生产全规模表现。生产库验收、存储迁移和 AppModel 接入由 Main 完成。

本轮优化验证使用 `output/name-optimization-build/` 独立 scratch。保留原有 13 项回归，新增跨并行块的 ASCII 分数/AND/NOT 对照、调用线程/取消/throw、快照 Unicode/别名/删除项 roundtrip 与损坏数据拒绝。`MIJI_NAME_BENCHMARK_ROWS=500000...1000000` 可显式运行 `testControlledLargeFixtureBenchmark`：只创建受控临时元数据 fixture，95% ASCII + 5% 中文，记录加载时间、RSS 与包含 top-K 的 name 引擎查询分位数；默认跳过大 fixture。真实 2479232 项的全库 P95 和 RSS 由 Main 最终验收。

最终 Core 隔离回归：17 项通过（含原有 13 项），大 fixture 默认跳过；显式运行大 fixture 另 1 项通过。100 万条、limit=500 的名称引擎最终 P95 为 6.43–30.32ms，进程峰值 RSS 169033728 字节；百万条 core 快照 42183409 字节，序列化 84.10ms、恢复 88.72ms。详见 `output/name-optimization-build/RESULT.md` 及对应 JSON/日志。这些是合成结果，不代表真实全库目标已通过；Main 提供的争用期间候选基准显示 ASCII P50 已改善，但 README/pdf 等仍需在迁移与测试争用结束后复测，并验证缓存 warm start。
