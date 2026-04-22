import Foundation
import Photos

// MARK: - 时间筛选类型

enum TimeFilterType: String {
    case all = "全部"
    case day = "按天"
    case month = "按月"
    case year = "按年"
}

// MARK: - 照片分组模型

struct PhotoSection {
    let title: String
    let date: Date
    var assets: [PhotoAssetModel]
}

// MARK: - 照片分组工具

class PhotoGrouper {

    // MARK: - 缓存的 DateFormatter（DateFormatter 创建成本高，全部缓存为静态属性）

    /// 用于按天分组的 key（"2024-06-15"）
    private static let keyDayFormatter: DateFormatter = makeFormatter(format: "yyyy-MM-dd")
    /// 用于按月分组的 key（"2024-06"）
    private static let keyMonthFormatter: DateFormatter = makeFormatter(format: "yyyy-MM")
    /// 用于按年分组的 key（"2024"）
    private static let keyYearFormatter: DateFormatter = makeFormatter(format: "yyyy")

    /// 用于显示天标题（"6月15日"）
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日"
        return f
    }()

    /// 用于显示月标题（"2024年6月"）
    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy年M月"
        return f
    }()

    /// 用于显示年标题（"2024年"）
    private static let yearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy年"
        return f
    }()

    static func groupAssets(_ assets: [PhotoAssetModel], by filterType: TimeFilterType) -> [PhotoSection] {
        switch filterType {
        case .all:   return groupByAll(assets)
        case .day:   return groupByDay(assets)
        case .month: return groupByMonth(assets)
        case .year:  return groupByYear(assets)
        }
    }

    // MARK: - Private

    private static func groupByAll(_ assets: [PhotoAssetModel]) -> [PhotoSection] {
        guard !assets.isEmpty else { return [] }
        return [PhotoSection(title: "全部照片", date: Date(), assets: assets)]
    }

    private static func groupByDay(_ assets: [PhotoAssetModel]) -> [PhotoSection] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: assets) { keyDayFormatter.string(from: $0.createDate) }
        return buildSections(from: grouped, parseFormatter: keyDayFormatter) { date in
            if calendar.isDateInToday(date) { return "今天" }
            if calendar.isDateInYesterday(date) { return "昨天" }
            return dayFormatter.string(from: date)
        }
    }

    private static func groupByMonth(_ assets: [PhotoAssetModel]) -> [PhotoSection] {
        let grouped = Dictionary(grouping: assets) { keyMonthFormatter.string(from: $0.createDate) }
        return buildSections(from: grouped, parseFormatter: keyMonthFormatter) { monthFormatter.string(from: $0) }
    }

    private static func groupByYear(_ assets: [PhotoAssetModel]) -> [PhotoSection] {
        let grouped = Dictionary(grouping: assets) { keyYearFormatter.string(from: $0.createDate) }
        return buildSections(from: grouped, parseFormatter: keyYearFormatter) { yearFormatter.string(from: $0) }
    }

    private static func buildSections(
        from grouped: [String: [PhotoAssetModel]],
        parseFormatter: DateFormatter,
        titleFormatter: (Date) -> String
    ) -> [PhotoSection] {
        return grouped.compactMap { key, assets in
            guard let date = parseFormatter.date(from: key) else { return nil }
            let sorted = assets.sorted { $0.createDate > $1.createDate }
            return PhotoSection(title: titleFormatter(date), date: date, assets: sorted)
        }
        .sorted { $0.date > $1.date }
    }

    /// 无 locale 要求的简单格式 formatter（仅供 key 生成/解析使用）
    private static func makeFormatter(format: String) -> DateFormatter {
        let f = DateFormatter()
        f.dateFormat = format
        return f
    }
}
