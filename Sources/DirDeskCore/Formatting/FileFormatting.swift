import Foundation

/// Age bucket that drives the soft date colors: red < 5 min, rose < 1 h, blue < 1 day,
/// green < 7 days, purple otherwise. Missing and future dates have no color.
public enum DateAgeBucket: String, CaseIterable, Sendable {
    case minutes, hour, day, week, older

    public static func bucket(for date: Date?, now: Date = Date()) -> DateAgeBucket? {
        guard let date, date <= now.addingTimeInterval(1) else { return nil }
        let age = now.timeIntervalSince(date)
        switch age {
        case ..<300: return .minutes
        case ..<3600: return .hour
        case ..<86_400: return .day
        case ..<604_800: return .week
        default: return .older
        }
    }
}

public enum FileSizeFormatter {
    public enum Style: Sendable {
        /// Item sizes: three significant digits, as in the original's lists ("5.56 KB", "98.4 KB", "734 KB", "1.23 MB").
        case file
        /// Volume capacity: up to two decimals ("74.55 GB", "59.8 GB").
        case capacity
    }

    /// Decimal uses 1000-based KB/MB/GB; binary uses KiB/MiB/GiB. Values below one unit are shown in bytes ("445 B").
    public static func string(_ bytes: Int64, unit: FileSizeUnit = .decimal, style: Style = .file) -> String {
        let base: Double = unit == .decimal ? 1000 : 1024
        let units = unit == .decimal ? ["KB", "MB", "GB", "TB", "PB"] : ["KiB", "MiB", "GiB", "TiB", "PiB"]
        if bytes < Int64(base) { return "\(bytes) B" }
        var value = Double(bytes)
        var index = -1
        while value >= base && index < units.count - 1 {
            value /= base
            index += 1
        }
        func decimals(for value: Double) -> Int {
            switch style {
            case .file: value < 10 ? 2 : (value < 100 ? 1 : 0)
            case .capacity: index == 0 ? 0 : (index == 1 ? 1 : 2)
            }
        }
        var places = decimals(for: value)
        let scale = pow(10, Double(places))
        // Rounding may carry into the next unit ("999.6 KB" -> "1 MB") or the next digit ("9.996 KB" -> "10 KB").
        if (value * scale).rounded() / scale >= base, index < units.count - 1 {
            value /= base
            index += 1
            places = decimals(for: value)
        } else if style == .file {
            let rounded = (value * scale).rounded() / scale
            places = decimals(for: rounded)
        }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = places
        formatter.roundingMode = .halfUp
        formatter.usesGroupingSeparator = false
        let text = formatter.string(from: NSNumber(value: value)) ?? String(format: "%.\(places)f", value)
        return "\(text) \(units[index])"
    }
}

/// Date text used by list columns: relative within two hours, "Yesterday HH:mm", otherwise yy/MM/dd HH:mm.
public struct FileDateFormatter {
    public var locale: Locale
    public var absolute: Bool
    private let absoluteFormatter: DateFormatter
    private let timeFormatter: DateFormatter
    private let relativeFormatter: RelativeDateTimeFormatter

    public init(locale: Locale = .current, absolute: Bool = false) {
        self.locale = locale
        self.absolute = absolute
        absoluteFormatter = DateFormatter()
        absoluteFormatter.locale = locale
        absoluteFormatter.dateFormat = Self.absolutePattern(for: locale)
        timeFormatter = DateFormatter()
        timeFormatter.locale = locale
        timeFormatter.dateFormat = "HH:mm"
        relativeFormatter = RelativeDateTimeFormatter()
        relativeFormatter.locale = locale
        relativeFormatter.unitsStyle = .full
        relativeFormatter.dateTimeStyle = .numeric
    }

    static func absolutePattern(for locale: Locale) -> String {
        let pattern = DateFormatter.dateFormat(fromTemplate: "yyMMddHHmm", options: 0, locale: locale) ?? "yy/MM/dd HH:mm"
        return pattern.replacingOccurrences(of: "a ", with: "").replacingOccurrences(of: " a", with: "")
            .replacingOccurrences(of: "h", with: "H")
    }

    /// Within two hours the text counts minutes ("75 min ago" / "75分钟前"), as the original's date pills do.
    public func string(_ date: Date?, now: Date = Date(), justNow: String, minutesAgoFormat: String? = nil,
                       yesterdayFormat: String, todayFormat: String) -> String {
        guard let date else { return "--" }
        if absolute { return absoluteFormatter.string(from: date) }
        let age = now.timeIntervalSince(date)
        if age >= 0 && age < 60 { return justNow }
        if age >= 60 && age < 7200 {
            if let minutesAgoFormat { return String(format: minutesAgoFormat, Int64(age / 60)) }
            return relativeFormatter.localizedString(for: date, relativeTo: now)
        }
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) {
            return String(format: todayFormat, timeFormatter.string(from: date))
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return String(format: yesterdayFormat, timeFormatter.string(from: date))
        }
        return absoluteFormatter.string(from: date)
    }

    public func absoluteString(_ date: Date?) -> String {
        guard let date else { return "--" }
        return absoluteFormatter.string(from: date)
    }
}
