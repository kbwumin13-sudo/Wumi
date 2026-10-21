# 界面对照工具

逐像素对照原软件参考截图（`docs/reference/`，2x）与 DirDesk 离屏渲染时用的小工具。坐标一律以点为单位（像素 ÷ 2）。

| 文件 | 用途 |
|---|---|
| `harness.sh <动作> [文件夹] [附加参数…]` | 用改了 bundle ID 的隐藏副本运行一个截图动作，PNG 写到 `$DIRDESK_HARNESS_DIR/out`（默认 `/tmp/dirdesk-harness`）；用完删除该目录和 `~/Library/Preferences/com.kbwumin13.dirdesk.menuharness.plist` |
| `px.py 图 h\|v 固定坐标 起 止` | 沿一条水平或竖直线列出颜色变化点 |
| `runs.py 图 y0 y1 x0 x1 [容差] [最小间隙]` | 在一条横带里找出内容块及其横向范围（量文字、图标的位置与宽度） |
| `vruns.py 图 x0 x1 y0 y1 [容差] [最小间隙]` | 在一条竖带里找出各行内容的纵向范围（量行距、间距） |
| `cmp.py 参考图 我方图 x y w h 输出 [--side]` | 从两张 2x 截图裁同一区域并排拼接 |
| `front.swift` | `swiftc front.swift -o /tmp/front && /tmp/front`：列出最前面的几个窗口与前台 App，用来确认后台操作没有抢焦点 |

用 cua-driver 截原软件窗口时用 `get_window_state` 的 `screenshot_out_file` 加 `max_image_dimension: 0`，与 DirDesk 窗口用同一方法截取后再比较；参考库里浮动面板的旧截图含阴影并被缩放，不宜直接量。
