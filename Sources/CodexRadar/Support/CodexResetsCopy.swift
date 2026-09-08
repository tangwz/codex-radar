import Foundation

enum CodexResetsCopy {
  static func text(_ key: String, locale: Locale) -> String {
    let chinese = locale.language.languageCode?.identifier == "zh"
    switch key {
    case "title": return chinese ? "Codex 重置公告" : "Codex reset announcements"
    case "lastAnnouncement": return chinese ? "最近公告时间" : "Last announcement"
    case "all": return chinese ? "全部公告" : "All announcements"
    case "regular": return chinese ? "普通重置" : "Regular"
    case "banked": return chinese ? "重置券" : "Banked"
    case "statistics": return chinese ? "重置公告统计" : "Announcement statistics"
    case "monthSummary": return chinese ? "%@，%lld 条公告" : "%@, %lld announcements"
    case "historyInfo": return chinese ? "关于公告统计" : "About announcement statistics"
    case "loadingHistory": return chinese ? "正在加载公告统计" : "Loading announcement statistics"
    case "historyUnavailable": return chinese ? "公告历史暂不可用" : "Announcement history unavailable"
    case "type": return chinese ? "公告类型" : "Announcement type"
    case "radarTitle": return chinese ? "公告雷达" : "Announcement radar"
    case "noAnnouncement": return chinese ? "无公告记录" : "No recorded announcement"
    case "regularAnnouncement": return chinese ? "普通重置公告" : "Regular announcement"
    case "bankedAnnouncement": return chinese ? "重置券公告" : "Banked announcement"
    case "mixedDay": return chinese ? "同日有两类公告" : "Both types on this day"
    case "radarUnavailable": return chinese ? "公告雷达暂不可用" : "Announcement radar unavailable"
    case "dataSource": return chinese ? "重置数据来源" : "Reset data source"
    case "refreshNotice": return chinese
      ? "直接读取 Codex Resets 第三方公共 API，无需自建后端或账户凭证。刷新遵循服务端缓存策略，并非即时通知；退出应用后不推送通知。"
      : "Reads the Codex Resets third-party public API directly, without an owned backend or account credentials. Refresh follows server caching, not realtime delivery. No notifications while the app is quit."
    case "byMonth": return chinese ? "每月公告数量" : "Announcements by month"
    case "regularByMonth": return chinese ? "每月普通重置公告" : "Regular announcements by month"
    case "bankedByMonth": return chinese ? "每月重置券公告" : "Banked announcements by month"
    case "source": return chinese ? "查看原始来源" : "Open original source"
    case "attribution": return chinese ? "数据来源：Codex Resets（第三方）" : "Data: Codex Resets (third party)"
    case "forecastDisclaimer": return chinese
      ? "第三方预测，尚未确认；不是 OpenAI 的承诺。"
      : "Third-party forecast, not confirmed and not an OpenAI commitment."
    case "announcementDisclaimer": return chinese
      ? "检测到重置公告，请核实原文和你的账户状态；不代表额度已经到账。"
      : "A reset announcement was recorded. Check its source and your account; quota delivery is not verified."
    case "unavailable": return chinese
      ? "数据源暂时不可用，以下为缓存信息；本地用量统计不受影响。"
      : "Source unavailable. Showing cached information; local usage is unaffected."
    case "waiting": return chinese ? "当前没有有效预测，最近公告仍可查看。" : "No active forecast. Previous announcements remain available."
    case "updated": return chinese ? "数据生成时间" : "Data generated"
    case "historyNote": return chinese
      ? "按公告或首次观察时间统计，不是账户实际重置时间。周从周一开始，月和天按所选时区计算。全部公告为两类公告数量之和；混合日表示同一天有两类公告，不表示同一次重置同时发生。"
      : "Counts use announcement/first-observed times, not account reset times. Weeks start Monday; months and days follow your time zone. All announcements sums both types. Mixed days contain both types, not necessarily a single combined event."
    default: return key
    }
  }
}
