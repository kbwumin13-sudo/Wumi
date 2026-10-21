# Wumi 原生窗口性能基准

入口：`@MainActor DebugPerformanceRun.run(delegate: AppDelegate, output: URL)`。同步返回，内部 Task 完成六阶段，写 `performance.json`、随后写 `performance-done`（`PASS` 或 `FAIL`），最后 `NSApp.terminate(nil)` 正常退出。运行失败时 JSON 的 `failures` 与 `validations` 明确记录原因；若报告不可写，则不写成功标记。每阶段完成会原子更新 JSON，未完成报告不能用于对比。

调用方负责接线、构建、隔离副本、启动、关闭、外部超时和复制完全相同的 Swift 文件到冻结 baseline；这些脚本不启动 App、不构建，也不改生产实现。performance 动作必须跳过 DebugSnapshot 自动 capture，避免截图工作与测量重叠。

## 夹具

从项目根执行：

```sh
python3 scripts/performance/make_fixtures.py --count 5000
python3 scripts/performance/make_fixtures.py --count 5000 --verify-only
```

生成固定根 `artifacts/performance-20261020/fixtures/5000`，打印绝对路径。只在这个专用目录下新建；已有目录仅验证，不覆盖、不删除。中断生成留下的不完整目录会明确失败，由调用方检查后处理。无用户文件、Git 仓库或索引夹具。`--count 20000` 可生成独立 `fixtures/20000`，可另行做普通加载压力测试；本入口的完整六阶段明确只接受 5000，避免扩大 baseline 的逐文件默认 App 查询成本。不要在 baseline-source 内运行生成器。

根下有 `manifest.json` 与 12 个目录：`small`（32 项）、`large`（5000 项）、`switch-a`（37 项）、`switch-b`（53 项）、`tab-00…07`（24…31 项）。文件名在目录间互斥，大小和修改日期为不同排列，便于检测排序未更新、旧目录结果覆盖新目录、恢复选择丢失。8 种扩展名覆盖多种默认应用及无应用分组；文件只用于元数据浏览，不打开或解码其内容，不保证图片/PDF 内容有效。manifest schema 1 含 `largeCount`、`directories[].path`、`directories[].entries[]` 的 `name/size/mtime`。

## 启动契约

给隔离副本传入：

```text
-DirDeskSnapshotAction performance
-DirDeskSnapshotDir <本轮独立输出目录>
-DirDeskPerformanceFixture <项目绝对路径>/artifacts/performance-20261020/fixtures/5000
-DirDeskSnapshotHidden YES
-DirDeskApplicationSupport <本轮隔离ApplicationSupport>
```

调用方同时负责隔离 UserDefaults 域、启动目录和配置，启动目录应为夹具 `small`，预先禁用所有同步计划。`DirDeskSnapshotHidden YES` 利用已有启动契约禁止闪电搜索索引；harness 只接受这个参数与显式 ApplicationSupport 覆盖。保留真实 AppKit 窗口与表格；可在隐藏窗口运行，不要求抢前台。不要开启采样 profiler、截图、其他自测或全盘索引。配置、可见列、语言、窗口尺寸、Git 开关须在三组中一致；harness 只设置本次 pane 的列表与排序配置，不替换业务实现。

`run.py GROUP --binary <binary>` 从归档应用组装专用 bundle ID 的副本；`run.py GROUP --label round-1` 启动一轮、等待退出并验证报告，外部超时为 150 秒。GROUP 为 `baseline-debug`、`baseline-release` 或 `optimized-release`。每轮输出目录必须不存在；启动前只清该专用 bundle ID 的偏好，Application Support 使用本轮新目录。`--action selfTest` 运行文件操作回归，完成后保留副本窗口，需正常退出再运行性能测量。

统一 80 秒整体合作式 deadline；小目录/加载/排序/切换阶段各 15 秒，分组与恢复各 25 秒，均受整体 deadline 限制。若同步主线程工作超过限制，恢复响应后报告失败、正常退出；主线程彻底死锁无法正常退出，Main 应保留外部 watchdog 并把该轮标为失败。`performance-done` 先于 App 正常退出，Main 应再等进程退出后启动下一轮。

## 测量及验收

六阶段固定顺序：`small_browse`、`large_load`、`repeated_sort`、`application_grouping`、`rapid_switch`、`restore_tabs`。

- 浏览等待精确文件名、大小和修改日期；验证无截断、displayItems 顺序、rows、表格数据源的每行顺序、实际已生成的可见行视图。每步要求状态持续稳定 120 ms，允许异步 rebuildRows 和 RunLoop 订阅完成，不只检查 loadState。没有依赖优化版独有字段。
- 大目录排序通过真实 NSTableView 发起选择，再改真实 pane 配置，依次检查姓名、大小、修改日期的降序/升序共六次，包含模型选择与表格选择的保持。预期序列仅依据 manifest 计算，不调用 FileSorter。
- 应用分组通过真实 `.application` 配置，检查全部 group 的归属、组内排序、header 与计数、选择保持。独立 oracle 在 UI 分组完成后才按扩展名做一次 Launch Services 查询，避免在测量前预热所有默认 App。fixture 没有逐文件默认应用覆盖；保持同一机器的默认 App 设置。
- 快速切换提交 12 个交错目录请求，每次间隔约 8 ms，最终切回 `small`。验证精确表格内容，350 ms 后复核没有旧数据。随后恢复序列化的 12 个标签 session，含 12 个不同目录，逐个激活并确认真实表格与恢复选择；不会自行调用 load() 来绕过懒加载。
- 所有阶段含最终 150 ms 等待及最终 UI 复核，随后排空最后一个 heartbeat。wall/CPU/wakeups/read/write 是整个阶段的进程级差值；footprint 起止值与每 100 ms 采样峰值均来自 Core `ProcessUsage`，不是 RSS。峰值可能漏过短峰。read/write 是 proc_pid_rusage 磁盘字节，缓存命中不等于物理磁盘读取。
- heartbeat 为独立串行队列每 20 ms 向 MainActor 投递，最多一个未完成探针，报告跳过 tick 数、全部样本和 nearest-rank p50/p95/max。阶段开始前预置探针，结束排空；同步主线程长工作也能被记录。这里是**投递到执行的主线程排队延迟，不是显示 FPS 或帧时长**。百分位是实际投递样本的分布，跳过 tick 不补零；阻塞长尾应结合 max 和 skippedTicks 解释。

Git 子进程次数未测，异步 Git 完成不作为 barrier；如果 Main 需要量化重复调用，可另用外部计数。UI 校验、visible table displayIfNeeded 和 heartbeat 自身的固定开销包含在测量内；不清系统文件缓存，也不承诺冷启动。

## 三组、多轮对比

先各一轮排错；排错轮单独保留，不纳入稳定统计。之后按轮交替：baseline Debug → baseline Release → optimized Release，重复三轮。三组使用相同 harness、夹具、设置与启动准备，每次输出独立目录；同一顺序降低机器状态和缓存漂移的影响，但不代表严格冷缓存实验。Debug/Release 的差异单独解读，优化收益以两个 Release 组为准。

每轮读取 JSON 后执行校验；失败/未完成/缺指标/heartbeat 尾部百分位错误会返回非零：

```sh
python3 scripts/performance/compare.py baseline-release=/path/run/performance.json
python3 scripts/performance/compare.py \
  baseline-debug=/path/bd1/performance.json baseline-debug=/path/bd2/performance.json baseline-debug=/path/bd3/performance.json \
  baseline-release=/path/br1/performance.json baseline-release=/path/br2/performance.json baseline-release=/path/br3/performance.json \
  optimized-release=/path/or1/performance.json optimized-release=/path/or2/performance.json optimized-release=/path/or3/performance.json
```

输出每组每阶段指标的轮间中位数，及相对第一个组的比值；不混合各轮 heartbeat 原始样本计算百分位。需 Release 相对 Release 比值时，把 baseline-release 放到第一个参数。统计不能替代真实功能回归。

工具纯数据测试（不生成夹具、不启动/编译 App）：

```sh
PYTHONDONTWRITEBYTECODE=1 python3 scripts/performance/test_tools.py
```
