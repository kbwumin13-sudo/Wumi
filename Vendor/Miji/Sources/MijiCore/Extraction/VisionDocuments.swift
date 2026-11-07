import Foundation
import Vision
import PDFKit
import ImageIO
import CoreGraphics

enum ImageSearchAliases {
    // Independently authored search vocabulary, extending Vision's English identifiers.
    static let chinese: [String: [String]] = [
        "cat": ["猫", "貓"], "dog": ["狗", "犬"], "bird": ["鸟", "鳥"], "fish": ["鱼", "魚"],
        "horse": ["马", "馬"], "rabbit": ["兔子"], "butterfly": ["蝴蝶"], "insect": ["昆虫", "昆蟲"],
        "animal": ["动物", "動物"], "pet": ["宠物", "寵物"], "wildlife": ["野生动物"],
        "flower": ["花", "花卉"], "plant": ["植物"], "tree": ["树", "樹"], "forest": ["森林"],
        "grass": ["草地"], "garden": ["花园", "花園"], "leaf": ["树叶", "樹葉"],
        "mountain": ["山", "山脉"], "beach": ["海滩", "海灘"], "ocean": ["海洋", "大海"],
        "sea": ["大海"], "lake": ["湖泊"], "river": ["河流"], "waterfall": ["瀑布"],
        "water": ["水"], "snow": ["雪"], "desert": ["沙漠"], "sky": ["天空"], "cloud": ["云", "雲"],
        "sunset": ["日落", "晚霞"], "sunrise": ["日出"], "night": ["夜景"], "landscape": ["风景", "風景"],
        "nature": ["自然"], "outdoor": ["户外", "戶外"], "indoor": ["室内", "室內"],
        "person": ["人物", "人"], "people": ["人物", "人群"], "portrait": ["肖像", "人像"],
        "face": ["面孔", "人脸"], "baby": ["婴儿", "嬰兒"], "child": ["儿童", "兒童"],
        "food": ["食物", "美食"], "fruit": ["水果"], "vegetable": ["蔬菜"], "cake": ["蛋糕"],
        "bread": ["面包", "麵包"], "pizza": ["披萨"], "coffee": ["咖啡"], "tea": ["茶"],
        "drink": ["饮料", "飲料"], "restaurant": ["餐厅", "餐廳"], "cooking": ["烹饪"],
        "car": ["汽车", "汽車"], "vehicle": ["车辆", "車輛"], "bicycle": ["自行车", "單車"],
        "motorcycle": ["摩托车"], "bus": ["公交车", "巴士"], "train": ["火车", "火車"],
        "airplane": ["飞机", "飛機"], "boat": ["船"], "ship": ["船舶"], "road": ["道路"],
        "building": ["建筑", "建築"], "architecture": ["建筑", "建築"], "house": ["房屋"],
        "city": ["城市"], "street": ["街道"], "bridge": ["桥", "橋"], "tower": ["塔"],
        "room": ["房间", "房間"], "bedroom": ["卧室"], "kitchen": ["厨房", "廚房"],
        "furniture": ["家具"], "chair": ["椅子"], "table": ["桌子"], "bed": ["床"],
        "computer": ["电脑", "電腦"], "laptop": ["笔记本电脑"], "phone": ["手机", "手機"],
        "screen": ["屏幕", "螢幕"], "screenshot": ["截图", "截圖"], "document": ["文档", "文件"],
        "text": ["文字"], "book": ["书", "書"], "receipt": ["收据", "收據", "小票"],
        "menu": ["菜单", "菜單"], "map": ["地图", "地圖"], "chart": ["图表", "圖表"],
        "art": ["艺术", "藝術"], "painting": ["绘画", "繪畫"], "drawing": ["画作"],
        "sport": ["运动", "運動"], "sports": ["运动", "運動"], "ball": ["球"],
        "clothing": ["服装", "服裝"], "shoe": ["鞋"], "watch": ["手表", "手錶"],
        "wedding": ["婚礼", "婚禮"], "fireworks": ["烟花", "煙花"], "festival": ["节日", "節日"]
    ]
    static func labels(for identifiers: [String]) -> [String] {
        var labels: [String] = [], seen = Set<String>()
        func add(_ label: String) { if seen.insert(label).inserted { labels.append(label) } }
        for identifier in identifiers {
            add(identifier)
            let words = identifier.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
            for word in words {
                // Vision sometimes emits plural nouns or compound identifiers.
                let key = chinese[word] != nil ? word : (word.hasSuffix("s") ? String(word.dropLast()) : word)
                for alias in chinese[key] ?? [] { add(alias) }
            }
        }
        return labels
    }
}

private func performVision(_ requests: [VNRequest], image: CGImage, context: ExtractionContext) throws {
    try context.check()
    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
    timer.schedule(deadline: .now(), repeating: .milliseconds(50))
    timer.setEventHandler {
        if context.cancelled() || Date() >= context.deadline { requests.forEach { $0.cancel() } }
    }
    timer.resume()
    defer { timer.cancel() }
    do { try VNImageRequestHandler(cgImage: image, options: [:]).perform(requests) }
    catch { try context.check(); throw error }
    try context.check()
}

func recognizeImageText(_ image: CGImage, context: ExtractionContext) throws -> String {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    request.automaticallyDetectsLanguage = true
    let available = try request.supportedRecognitionLanguages()
    let preferred = ["zh-Hans", "zh-Hant", "en-US", "ja-JP", "ko-KR", "fr-FR", "de-DE", "es-ES", "it-IT", "pt-BR", "ru-RU", "uk-UA", "vi-VT", "ar-SA", "hi-IN"]
    request.recognitionLanguages = preferred.filter { available.contains($0) }
    try performVision([request], image: image, context: context)
    return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
}

func classifyImage(_ image: CGImage, context: ExtractionContext) throws -> [String] {
    let request = VNClassifyImageRequest()
    try performVision([request], image: image, context: context)
    let identifiers = (request.results ?? []).filter { $0.confidence >= 0.12 }
        .sorted { $0.confidence > $1.confidence }.prefix(12).map(\.identifier)
    return ImageSearchAliases.labels(for: identifiers)
}

private func partialVisionFailure(_ error: Error, context: ExtractionContext, operation: String) throws {
    try context.check() // Cancellation/timeouts are failures, not successful partial indexes.
    context.warn("\(operation)失败：\(error.localizedDescription)")
}

func extractImage(_ data: Data, options: ExtractionOptions, context: ExtractionContext) throws -> (labels: [String], pages: Int) {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { throw ContentExtractionError.invalidDocument("图片格式损坏或系统不支持") }
    let count = CGImageSourceGetCount(source)
    guard count > 0 else { throw ContentExtractionError.invalidDocument("图片没有图像帧") }
    let type = CGImageSourceGetType(source) as String?
    let frames = type == "public.tiff" ? count : 1
    if count > frames { context.warn("多帧图片仅提取首帧；其余动画帧未索引") }
    var labels: [String] = []
    for index in 0..<frames {
        try context.check()
        if context.isFull { break }
        if !options.recognizeImages && !options.classifyImages { break }
        let properties: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                          kCGImageSourceCreateThumbnailWithTransform: true,
                                          kCGImageSourceThumbnailMaxPixelSize: 3200,
                                          kCGImageSourceShouldCacheImmediately: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, properties as CFDictionary) else {
            context.warn("图片第 \(index + 1) 帧无法解码"); continue
        }
        if options.recognizeImages {
            do { context.append(try recognizeImageText(image, context: context)) }
            catch { try partialVisionFailure(error, context: context, operation: "图片 OCR") }
        }
        if options.classifyImages {
            do { labels.append(contentsOf: try classifyImage(image, context: context)) }
            catch { try partialVisionFailure(error, context: context, operation: "图片分类") }
        }
    }
    var seen = Set<String>()
    return (labels.filter { seen.insert($0).inserted }, frames)
}

private func renderPDFPage(_ page: PDFPage) -> CGImage? {
    guard let reference = page.pageRef else { return nil }
    var bounds = reference.getBoxRect(.cropBox)
    if bounds.isEmpty { bounds = reference.getBoxRect(.mediaBox) }
    guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else { return nil }
    let rotated = reference.rotationAngle % 180 != 0
    let width = rotated ? bounds.height : bounds.width
    let height = rotated ? bounds.width : bounds.height
    let scale = min(3, 3200 / max(width, height))
    let pixelWidth = max(1, Int(ceil(width * scale))), pixelHeight = max(1, Int(ceil(height * scale)))
    guard let drawing = CGContext(data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8,
                                 bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                 bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    let rectangle = CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight)
    drawing.setFillColor(CGColor(gray: 1, alpha: 1)); drawing.fill(rectangle)
    drawing.concatenate(reference.getDrawingTransform(.cropBox, rect: rectangle, rotate: 0, preserveAspectRatio: true))
    drawing.drawPDFPage(reference)
    return drawing.makeImage()
}

func extractPDF(_ data: Data, options: ExtractionOptions, context: ExtractionContext) throws -> Int {
    try context.check()
    guard let document = PDFDocument(data: data) else { throw ContentExtractionError.invalidDocument("PDF 无法打开") }
    guard !document.isLocked else { throw ContentExtractionError.invalidDocument("PDF 已加密，需要密码") }
    let count = document.pageCount
    context.beginPageMapping()
    var skipped = 0, blank = 0
    for index in 0..<count {
        try context.check()
        if context.isFull { context.warn("PDF 剩余页面因文字上限未提取"); break }
        try autoreleasepool {
            guard let page = document.page(at: index) else { context.warn("PDF 第 \(index + 1) 页无法读取"); return }
            let text = page.string ?? ""
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                context.appendPage(text, page: index + 1); return
            }
            guard options.ocrPDF else { skipped += 1; return }
            guard let image = renderPDFPage(page) else { context.warn("PDF 第 \(index + 1) 页无法渲染 OCR"); return }
            do {
                let recognized = try recognizeImageText(image, context: context)
                if recognized.isEmpty { blank += 1 }
                context.appendPage(recognized, page: index + 1)
            } catch { try partialVisionFailure(error, context: context, operation: "PDF 第 \(index + 1) 页 OCR") }
        }
    }
    if skipped > 0 { context.warn("PDF 有 \(skipped) 页无文字层，PDF OCR 已关闭") }
    if blank > 0 { context.warn("PDF 有 \(blank) 页 OCR 未识别到文字") }
    return count
}
