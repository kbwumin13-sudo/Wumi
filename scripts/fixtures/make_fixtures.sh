#!/bin/zsh
# Builds a deterministic test tree for side-by-side checks of the original app and DirDesk.
# Usage: scripts/fixtures/make_fixtures.sh [target-dir]   (default: ~/DirDeskFixtures)
# The target directory is deleted and recreated, so only point it at a fixture folder.
set -euo pipefail

ROOT="${1:-$HOME/DirDeskFixtures}"
HERE="${0:A:h}"
case "$ROOT" in
  "$HOME"/DirDeskFixtures*|/tmp/*|/private/tmp/*) ;;
  *) echo "refusing to rebuild $ROOT (must be ~/DirDeskFixtures* or under /tmp)" >&2; exit 2 ;;
esac

rm -rf "$ROOT"
mkdir -p "$ROOT"
cd "$ROOT"

# Sets an mtime relative to now: age <file> <seconds-ago>
age() { touch -t "$(date -v-"$2"S +%Y%m%d%H%M.%S)" "$1"; }
# Writes Finder tags as a binary plist xattr: tag <file> <name>...
tag() {
  local file="$1"; shift
  local hex
  hex=$(python3 -I -c 'import plistlib,sys; sys.stdout.write(plistlib.dumps(sys.argv[1:], fmt=plistlib.FMT_BINARY).hex())' "$@")
  xattr -wx com.apple.metadata:_kMDItemUserTags "$hex" "$file"
}

# 01 sorting, dates, sizes, special names
mkdir -p 01-排序与日期 && cd 01-排序与日期
for n in "File 1" "File 2" "File 10" "file 3" "Report-2025" "Report-2026" "a" "B" "中文名" "Émoji 🍎" "数学分析 第2章" "数学分析 第10章"; do
  print -r -- "$n" > "$n.txt"
done
print "now" > age-now.txt
print "minutes" > age-30min.txt && age age-30min.txt 1800
print "hours" > age-3h.txt && age age-3h.txt 10800
print "days" > age-3d.txt && age age-3d.txt 259200
print "weeks" > age-30d.txt && age age-30d.txt 2592000
print "future" > age-future.txt && touch -t "$(date -v+30d +%Y%m%d%H%M.%S)" age-future.txt
: > size-0B.bin
head -c 999 /dev/zero > size-999B.bin
head -c 1000 /dev/zero > size-1000B.bin
head -c 1024 /dev/zero > size-1024B.bin
head -c 1500000 /dev/zero > size-1.5MB.bin
mkfile -n 150m size-150MB.bin
print "hidden" > .hidden-file
ln -s "File 1.txt" "link-to-File 1"
mkdir "Folder 2" "Folder 10" "folder 1"
cd ..

# 02 documents
mkdir -p 02-文档 && cd 02-文档
cat > sample.md <<'MD'
# DirDesk 夹具文档

一段普通文字，**加粗**、*斜体*、`行内代码`。

## 列表

- 第一项
- 第二项
  1. 子项甲
  2. 子项乙

> 引用一段话。

| 名称 | 数量 |
| --- | ---: |
| 苹果 | 3 |
| 香蕉 | 12 |

```swift
print("hello")
```

```plantuml
@startuml
Alice -> Bob: 请求
Bob --> Alice: 响应
@enduml
```

---

TODO: 结尾
MD
print '{"name": "DirDesk", "items": [1, 2, 3], "nested": {"ok": true}}' > data.json
printf 'name,qty\napple,3\nbanana,12\n' > table.csv
printf 'Plain text line one\nline two\n' > notes.txt
print -r -- "中文 GB18030 编码文本" | iconv -f UTF-8 -t GB18030 > gb18030.txt
print -r -- "<html><body><h1>Title</h1><p>Body</p></body></html>" > page.html
textutil -convert docx -output doc.docx notes.txt
textutil -convert rtf -output doc.rtf notes.txt
for i in {1..60}; do print "第 $i 行：用于生成多页 PDF 的文本内容。Line $i of the multi-page PDF fixture."; done > long.txt
cupsfilter long.txt > sample.pdf 2>/dev/null
cd ..

# 03 images (ImageIO helper renders a subject on a gradient)
mkdir -p 03-图片 && cd 03-图片
swift "$HERE/make_image.swift" photo-gps.jpg 1600 1200 public.jpeg 30.6586 104.0648 512.3
swift "$HERE/make_image.swift" photo-no-gps.jpg 1600 1200 public.jpeg
swift "$HERE/make_image.swift" image.png 800 600 public.png
swift "$HERE/make_image.swift" image.heic 1200 900 public.heic
swift "$HERE/make_image.swift" image.tiff 640 480 public.tiff
swift "$HERE/make_image.swift" large-6000x4000.jpg 6000 4000 public.jpeg
ffmpeg -loglevel error -f lavfi -i testsrc=size=320x240:rate=10:duration=2 animated.gif
for i in 1 2 3; do cp image.png "page-$i.png"; done
cd ..

# 04 audio and video
mkdir -p 04-音视频 && cd 04-音视频
say -o speech.aiff "DirDesk fixture audio"
afconvert -f m4af -d aac speech.aiff speech.m4a && rm speech.aiff
ffmpeg -loglevel error -f lavfi -i testsrc=size=640x360:rate=25:duration=4 -f lavfi -i sine=frequency=440:duration=4 -shortest -pix_fmt yuv420p clip.mp4
ffmpeg -loglevel error -i clip.mp4 -c copy clip.mov
cd ..

# 05 archives
mkdir -p 05-压缩包/src/子目录 && cd 05-压缩包
print "alpha" > src/a.txt; print "beta" > src/子目录/b.txt; cp ../03-图片/image.png src/
(cd src && zip -qr ../sample.zip . && zip -qr -P 1234 ../password-1234.zip . && bsdtar --format 7zip -cf ../sample.7z . && tar -czf ../sample.tar.gz .)
cp sample.zip nested-inner.zip && zip -q nested.zip nested-inner.zip && rm nested-inner.zip
cd ..

# 06 git repository with every badge state
mkdir -p 06-Git仓库 && cd 06-Git仓库
git init -q -b main
git config user.email fixture@example.com && git config user.name Fixture
print "clean" > clean.txt; print "base" > modified.txt; print "base" > staged.txt; print "line" > conflict.txt
git add . && git commit -qm "initial"
git checkout -qb other && print "other" > conflict.txt && git commit -qam "other side"
git checkout -q main && print "main" > conflict.txt && git commit -qam "main side"
git merge other >/dev/null 2>&1 || true
print "changed" >> modified.txt
print "staged change" >> staged.txt && git add staged.txt
print "new" > untracked.txt
cd ..

# 07 Finder tags
mkdir -p 07-标签 && cd 07-标签
print red > red.txt && tag red.txt "红色"
print blue > blue.txt && tag blue.txt "蓝色"
print both > both.txt && tag both.txt "红色" "项目A"
print custom > custom.txt && tag custom.txt "项目A"
cd ..

# 08 large folder for paging and performance
mkdir -p 08-大目录 && cd 08-大目录
for i in {1..5000}; do : > "item-$(printf %05d $i).txt"; done
cd ..

# 09 nesting and many subfolders
mkdir -p 09-嵌套/a/b/c/d/e/f && print deep > 09-嵌套/a/b/c/d/e/f/deep.txt
mkdir -p 09-嵌套/many && for i in {1..150}; do mkdir "09-嵌套/many/sub-$(printf %03d $i)"; done

# 10 batch rename sources
mkdir -p 10-批量重命名 && for i in {1..20}; do : > "10-批量重命名/IMG_$(printf %03d $i).JPG"; done

# 11 folder sync pair
mkdir -p 11-同步/left/sub 11-同步/right
print same > 11-同步/left/same.txt && cp 11-同步/left/same.txt 11-同步/right/
print left-only > 11-同步/left/left-only.txt
print right-only > 11-同步/right/right-only.txt
print "left version" > 11-同步/left/changed.txt && print "right version" > 11-同步/right/changed.txt
print nested > 11-同步/left/sub/nested.txt

# 12 PDF tool inputs
mkdir -p 12-PDF工具 && for i in 1 2 3; do cp 02-文档/sample.pdf "12-PDF工具/part-$i.pdf"; done

# 13 empty folder and a package bundle
mkdir -p 13-空文件夹 "14-包/Fixture.app/Contents/MacOS"

print "fixtures ready at $ROOT"
