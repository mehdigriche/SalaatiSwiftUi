import SwiftUI
import AppKit
import UserNotifications
import ServiceManagement
import AVFoundation
import UniformTypeIdentifiers
import StoreKit          // ← add this line

// MARK: - App Entry Point
@main
struct SalaatiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene {
        Settings { EmptyView() }
    }
}

// MARK: - App Delegate
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var popover: NSPopover!
    var timer: Timer?
    var prayerManager = PrayerTimesManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupPopover()
        startTimer()
        NotificationManager.shared.requestPermission()
        AthanPlayer.shared.prefetchAll()
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.action = #selector(togglePopover)
            button.target = self
        }
        refreshMenuBar()
    }

    private func setupPopover() {
        popover = NSPopover()
        popover.contentSize = NSSize(width: 380, height: 550)
        popover.behavior = .transient
        popover.animates = true
        popover.appearance = NSAppearance(named: .darkAqua)  // ← add this
        popover.contentViewController = NSHostingController(rootView: MenuBarPopoverView(manager: prayerManager, appDelegate: self))
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshMenuBar()
                self?.prayerManager.updateCurrentPrayer()
                self?.checkAndPlayAthan()
            }
        }
    }

    // Tracks "PrayerName-yyyy-MM-dd" to avoid replaying on the same day
    private var lastAthanKey: String?

    private func checkAndPlayAthan() {
        let settings = SettingsManager.shared
        guard !settings.silentMode else { return }
        let now = Date()
        let calendar = Calendar.current

        for prayer in prayerManager.prayers where prayer.isEnabled && prayer.name != "Sunrise" {
            let diff = calendar.dateComponents([.second], from: prayer.time, to: now).second ?? Int.max
            // Fire within the first 3 seconds after the prayer time
            guard diff >= 0 && diff < 3 else { continue }

            // Build a stable key: prayerName + today's date
            let dateStr = DateFormatter.localizedString(from: now, dateStyle: .short, timeStyle: .none)
            let key = "\(prayer.name)-\(dateStr)"
            guard key != lastAthanKey else { continue }

            lastAthanKey = key
            guard settings.athanEnabled(for: prayer.name) else { break }
            let reciter = reciterFor(prayer: prayer.name)
            AthanPlayer.shared.play(reciter: reciter, isFajr: prayer.name == "Fajr", prayerName: prayer.name)
            break
        }
    }

    private func reciterFor(prayer: String) -> AthanReciter {
        let s = SettingsManager.shared
        switch prayer {
        case "Fajr":    return s.fajrReciter
        case "Dhuhr":   return s.dhuhrReciter
        case "Asr":     return s.asrReciter
        case "Maghrib": return s.maghribReciter
        case "Isha":    return s.ishaReciter
        default:        return s.fajrReciter
        }
    }

    // Alternates each second to drive the flash
    private var flashTick = false

    func refreshMenuBar() {
        guard let button = statusItem.button else { return }
        let settings = SettingsManager.shared
        let athanPlaying = AthanPlayer.shared.isPlaying
        flashTick.toggle()

        // Icon — swap to waveform while athan plays
        if settings.showIcon {
            let iconName = athanPlaying
                ? (flashTick ? "waveform" : "waveform.badge.mic")
                : "moon.stars.fill"
            let img = NSImage(systemSymbolName: iconName, accessibilityDescription: "Salaati")
            if athanPlaying {
                // Tint the icon red
                let config = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
                button.image = img?.withSymbolConfiguration(config)
            } else {
                button.image = img
            }
        } else {
            button.image = nil
        }

        // Build text
        var text = ""
        if settings.showNextPrayer {
            let prayer = athanPlaying
                ? prayerManager.prayers.first(where: { $0.name == AthanPlayer.shared.currentlyPlayingPrayerName })
                : prayerManager.getNextPrayer()

            if let p = prayer {
                if settings.prayerNameDisplay == .full {
                    text += p.localizedName
                } else if settings.prayerNameDisplay == .abbreviation {
                    text += String((p.localizedName).prefix(3))
                }

                if athanPlaying {
                    // No countdown while athan plays — flash the prayer name instead
                } else {
                    if settings.prayerTimeDisplay == .countdown {
                        if !text.isEmpty { text += " " }
                        text += prayerManager.timeRemaining()
                    } else if settings.prayerTimeDisplay == .time {
                        if !text.isEmpty { text += " " }
                        text += formatTime(p.time)
                    }
                }
            }
        }

        // Apply attributed string — red/white flash when athan playing, normal otherwise
        if athanPlaying && !text.isEmpty {
            let color: NSColor = flashTick ? .systemRed : NSColor(red: 1, green: 1, blue: 1, alpha: 0.55)
            let attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: color,
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
            ]
            button.attributedTitle = NSAttributedString(string: text, attributes: attrs)
        } else {
            button.attributedTitle = NSAttributedString(string: "")
            button.title = text
        }

        // Icon position
        if settings.showIcon && !text.isEmpty {
            button.imagePosition = .imageLeading
        } else if settings.showIcon {
            button.imagePosition = .imageOnly
        }
    }

    private let menuBarTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private func formatTime(_ date: Date) -> String {
        menuBarTimeFormatter.string(from: date)
    }

    @objc func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

// MARK: - Settings Manager
class SettingsManager: ObservableObject {
    static let shared = SettingsManager()

    @Published var showNextPrayer: Bool {
        didSet {
            UserDefaults.standard.set(showNextPrayer, forKey: "showNextPrayer")
            NotificationCenter.default.post(name: .refreshMenuBar, object: nil)
        }
    }

    @Published var prayerNameDisplay: PrayerNameDisplay {
        didSet {
            UserDefaults.standard.set(prayerNameDisplay.rawValue, forKey: "prayerNameDisplay")
            NotificationCenter.default.post(name: .refreshMenuBar, object: nil)
        }
    }

    @Published var prayerTimeDisplay: PrayerTimeDisplay {
        didSet {
            UserDefaults.standard.set(prayerTimeDisplay.rawValue, forKey: "prayerTimeDisplay")
            NotificationCenter.default.post(name: .refreshMenuBar, object: nil)
        }
    }

    @Published var showIcon: Bool {
        didSet {
            UserDefaults.standard.set(showIcon, forKey: "showIcon")
            NotificationCenter.default.post(name: .refreshMenuBar, object: nil)
        }
    }

    @Published var arabicMode: Bool {
        didSet { UserDefaults.standard.set(arabicMode, forKey: "arabicMode") }
    }

    @Published var startAtLogin: Bool {
        didSet {
            UserDefaults.standard.set(startAtLogin, forKey: "startAtLogin")
            updateLoginItem()
        }
    }
    @Published var showBackground: Bool {
        didSet { UserDefaults.standard.set(showBackground, forKey: "showBackground") }
    }
    @Published var backgroundOpacity: Double {
        didSet { UserDefaults.standard.set(backgroundOpacity, forKey: "backgroundOpacity") }
    }

    @Published var asrMethod: AsrMethod {
        didSet { UserDefaults.standard.set(asrMethod.rawValue, forKey: "asrMethod") }
    }

    @Published var fajrIshaMethod: Int {
        didSet { UserDefaults.standard.set(fajrIshaMethod, forKey: "fajrIshaMethod") }
    }

    // Prayer time adjustments (in minutes)
    @Published var fajrAdjustment: Int {
        didSet {
            UserDefaults.standard.set(fajrAdjustment, forKey: "fajrAdjustment")
            refreshPrayerTimesIfNeeded()
        }
    }

    @Published var sunriseAdjustment: Int {
        didSet {
            UserDefaults.standard.set(sunriseAdjustment, forKey: "sunriseAdjustment")
            refreshPrayerTimesIfNeeded()
        }
    }

    @Published var dhuhrAdjustment: Int {
        didSet {
            UserDefaults.standard.set(dhuhrAdjustment, forKey: "dhuhrAdjustment")
            refreshPrayerTimesIfNeeded()
        }
    }

    @Published var asrAdjustment: Int {
        didSet {
            UserDefaults.standard.set(asrAdjustment, forKey: "asrAdjustment")
            refreshPrayerTimesIfNeeded()
        }
    }

    @Published var maghribAdjustment: Int {
        didSet {
            UserDefaults.standard.set(maghribAdjustment, forKey: "maghribAdjustment")
            refreshPrayerTimesIfNeeded()
        }
    }

    @Published var ishaAdjustment: Int {
        didSet {
            UserDefaults.standard.set(ishaAdjustment, forKey: "ishaAdjustment")
            refreshPrayerTimesIfNeeded()
        }
    }

    // Hijri date adjustment (in days)
    @Published var hijriAdjustment: Int {
        didSet {
            UserDefaults.standard.set(hijriAdjustment, forKey: "hijriAdjustment")
            refreshPrayerTimesIfNeeded()
        }
    }

    // MARK: Athan / Audio Settings
    @Published var silentMode: Bool {
        didSet { UserDefaults.standard.set(silentMode, forKey: "silentMode") }
    }
    @Published var fajrAthanEnabled: Bool {
        didSet { UserDefaults.standard.set(fajrAthanEnabled, forKey: "fajrAthanEnabled") }
    }
    @Published var dhuhrAthanEnabled: Bool {
        didSet { UserDefaults.standard.set(dhuhrAthanEnabled, forKey: "dhuhrAthanEnabled") }
    }
    @Published var asrAthanEnabled: Bool {
        didSet { UserDefaults.standard.set(asrAthanEnabled, forKey: "asrAthanEnabled") }
    }
    @Published var maghribAthanEnabled: Bool {
        didSet { UserDefaults.standard.set(maghribAthanEnabled, forKey: "maghribAthanEnabled") }
    }
    @Published var ishaAthanEnabled: Bool {
        didSet { UserDefaults.standard.set(ishaAthanEnabled, forKey: "ishaAthanEnabled") }
    }
    @Published var fajrReciter: AthanReciter {
        didSet { UserDefaults.standard.set(fajrReciter.rawValue, forKey: "fajrReciter") }
    }
    @Published var dhuhrReciter: AthanReciter {
        didSet { UserDefaults.standard.set(dhuhrReciter.rawValue, forKey: "dhuhrReciter") }
    }
    @Published var asrReciter: AthanReciter {
        didSet { UserDefaults.standard.set(asrReciter.rawValue, forKey: "asrReciter") }
    }
    @Published var maghribReciter: AthanReciter {
        didSet { UserDefaults.standard.set(maghribReciter.rawValue, forKey: "maghribReciter") }
    }
    @Published var ishaReciter: AthanReciter {
        didSet { UserDefaults.standard.set(ishaReciter.rawValue, forKey: "ishaReciter") }
    }
    @Published var reminderBeforeFajr: Bool {
        didSet { UserDefaults.standard.set(reminderBeforeFajr, forKey: "reminderBeforeFajr") }
    }
    @Published var reminderFajrMinutes: Int {
        didSet { UserDefaults.standard.set(reminderFajrMinutes, forKey: "reminderFajrMinutes") }
    }
    @Published var reminderBeforeSunrise: Bool {
        didSet { UserDefaults.standard.set(reminderBeforeSunrise, forKey: "reminderBeforeSunrise") }
    }
    @Published var reminderSunriseMinutes: Int {
        didSet { UserDefaults.standard.set(reminderSunriseMinutes, forKey: "reminderSunriseMinutes") }
    }
    @Published var playDuaAfterAdhan: Bool {
        didSet { UserDefaults.standard.set(playDuaAfterAdhan, forKey: "playDuaAfterAdhan") }
    }
    @Published var athanVolume: Double {
        didSet {
            UserDefaults.standard.set(athanVolume, forKey: "athanVolume")
            let vol = athanVolume
            Task { @MainActor in AthanPlayer.shared.setVolume(vol) }
        }
    }

    // Adjustments are applied locally — no network call needed
    private func refreshPrayerTimesIfNeeded() {
        NotificationCenter.default.post(name: .applyAdjustments, object: nil)
    }

    private init() {
        showNextPrayer = UserDefaults.standard.object(forKey: "showNextPrayer") as? Bool ?? true
        prayerNameDisplay = PrayerNameDisplay(rawValue: UserDefaults.standard.integer(forKey: "prayerNameDisplay")) ?? .full
        prayerTimeDisplay = PrayerTimeDisplay(rawValue: UserDefaults.standard.integer(forKey: "prayerTimeDisplay")) ?? .countdown
        showIcon = UserDefaults.standard.object(forKey: "showIcon") as? Bool ?? true
        arabicMode = UserDefaults.standard.object(forKey: "arabicMode") as? Bool ?? true
        startAtLogin = UserDefaults.standard.object(forKey: "startAtLogin") as? Bool ?? true
        showBackground = UserDefaults.standard.object(forKey: "showBackground") as? Bool ?? true
        backgroundOpacity = UserDefaults.standard.object(forKey: "backgroundOpacity") as? Double ?? 0.25
        asrMethod = AsrMethod(rawValue: UserDefaults.standard.integer(forKey: "asrMethod")) ?? .standard
        fajrIshaMethod = UserDefaults.standard.object(forKey: "fajrIshaMethod") as? Int ?? 3

        // Load adjustments
        fajrAdjustment = UserDefaults.standard.object(forKey: "fajrAdjustment") as? Int ?? 0
        sunriseAdjustment = UserDefaults.standard.object(forKey: "sunriseAdjustment") as? Int ?? 0
        dhuhrAdjustment = UserDefaults.standard.object(forKey: "dhuhrAdjustment") as? Int ?? 0
        asrAdjustment = UserDefaults.standard.object(forKey: "asrAdjustment") as? Int ?? 0
        maghribAdjustment = UserDefaults.standard.object(forKey: "maghribAdjustment") as? Int ?? 0
        ishaAdjustment = UserDefaults.standard.object(forKey: "ishaAdjustment") as? Int ?? 0
        hijriAdjustment = UserDefaults.standard.object(forKey: "hijriAdjustment") as? Int ?? 0

        // Load athan settings
        silentMode = UserDefaults.standard.object(forKey: "silentMode") as? Bool ?? false
        fajrAthanEnabled    = UserDefaults.standard.object(forKey: "fajrAthanEnabled")    as? Bool ?? true
        dhuhrAthanEnabled   = UserDefaults.standard.object(forKey: "dhuhrAthanEnabled")   as? Bool ?? true
        asrAthanEnabled     = UserDefaults.standard.object(forKey: "asrAthanEnabled")     as? Bool ?? true
        maghribAthanEnabled = UserDefaults.standard.object(forKey: "maghribAthanEnabled") as? Bool ?? true
        ishaAthanEnabled    = UserDefaults.standard.object(forKey: "ishaAthanEnabled")    as? Bool ?? true
        fajrReciter    = AthanReciter(rawValue: UserDefaults.standard.string(forKey: "fajrReciter")    ?? "") ?? .afasyDubai
        dhuhrReciter   = AthanReciter(rawValue: UserDefaults.standard.string(forKey: "dhuhrReciter")   ?? "") ?? .afasyDubai
        asrReciter     = AthanReciter(rawValue: UserDefaults.standard.string(forKey: "asrReciter")     ?? "") ?? .afasyDubai
        maghribReciter = AthanReciter(rawValue: UserDefaults.standard.string(forKey: "maghribReciter") ?? "") ?? .afasyDubai
        ishaReciter    = AthanReciter(rawValue: UserDefaults.standard.string(forKey: "ishaReciter")    ?? "") ?? .afasyDubai
        reminderBeforeFajr    = UserDefaults.standard.object(forKey: "reminderBeforeFajr")    as? Bool ?? false
        reminderFajrMinutes   = UserDefaults.standard.object(forKey: "reminderFajrMinutes")   as? Int  ?? 30
        reminderBeforeSunrise = UserDefaults.standard.object(forKey: "reminderBeforeSunrise") as? Bool ?? false
        reminderSunriseMinutes = UserDefaults.standard.object(forKey: "reminderSunriseMinutes") as? Int ?? 30
        playDuaAfterAdhan = UserDefaults.standard.object(forKey: "playDuaAfterAdhan") as? Bool ?? false
        athanVolume = UserDefaults.standard.object(forKey: "athanVolume") as? Double ?? 0.8
    }

    func athanEnabled(for prayerName: String) -> Bool {
        switch prayerName {
        case "Fajr":    return fajrAthanEnabled
        case "Dhuhr":   return dhuhrAthanEnabled
        case "Asr":     return asrAthanEnabled
        case "Maghrib": return maghribAthanEnabled
        case "Isha":    return ishaAthanEnabled
        default:        return false
        }
    }

    private func updateLoginItem() {
        if #available(macOS 13.0, *) {
            do {
                if startAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                print("Failed: \(error)")
            }
        }
    }
}

extension Notification.Name {
    static let refreshMenuBar = Notification.Name("refreshMenuBar")
    static let refreshPrayerTimes = Notification.Name("refreshPrayerTimes")
    static let applyAdjustments = Notification.Name("applyAdjustments")
}

enum PrayerNameDisplay: Int, CaseIterable { case full = 0, abbreviation = 1, none = 2 }
enum PrayerTimeDisplay: Int, CaseIterable { case countdown = 0, time = 1, none = 2 }
enum AsrMethod: Int, CaseIterable { case standard = 0, hanbali = 1 }

// MARK: - Models
struct Prayer: Identifiable, Codable, Equatable {
    let id: UUID
    let name: String
    let arabicName: String
    var time: Date
    var isEnabled: Bool

    init(id: UUID = UUID(), name: String, arabicName: String, time: Date, isEnabled: Bool) {
        self.id = id
        self.name = name
        self.arabicName = arabicName
        self.time = time
        self.isEnabled = isEnabled
    }

    static func == (lhs: Prayer, rhs: Prayer) -> Bool { lhs.id == rhs.id }

    /// Returns the display name based on the current language setting
    var localizedName: String {
        SettingsManager.shared.arabicMode ? arabicName : name
    }
}

/// Translates an English prayer key to the display name based on language setting.
/// Use this for hardcoded strings in settings views that don't have a Prayer object.
func prayerDisplayName(_ englishName: String) -> String {
    guard SettingsManager.shared.arabicMode else { return englishName }
    switch englishName {
    case "Fajr":    return "فجر"
    case "Sunrise": return "شروق"
    case "Dhuhr":   return "ظهر"
    case "Asr":     return "عصر"
    case "Maghrib": return "مغرب"
    case "Isha":    return "عشاء"
    default:        return englishName
    }
}

/// Main UI string localizer — returns Arabic when arabicMode is enabled
func L(_ english: String) -> String {
    guard SettingsManager.shared.arabicMode else { return english }
    switch english {
    // Tabs
    case "General":             return "عام"
    case "Location":            return "الموقع"
    case "Prayer":              return "الصلاة"
    case "Adjust":              return "ضبط"
    case "Athan":               return "الأذان"
    case "Done":                return "تم"
    case "Settings":            return "الإعدادات"
    case "Refresh":             return "تحديث"
    case "About":               return "عن التطبيق"
    case "Quit":                return "خروج"
    case "Qibla":               return "القبلة"
    case "from North":          return "من الشمال"
    case "Duaa":                return "الدعاء"
    case "Shuffle":             return "خلط"
    // General settings
    case "Menu Bar Display":    return "شريط القائمة"
    case "Show Next Prayer":    return "عرض الصلاة القادمة"
    case "Show Icon":           return "عرض الأيقونة"
    case "Prayer Name":         return "اسم الصلاة"
    case "Full":                return "كامل"
    case "Abbrev":              return "مختصر"
    case "None":                return "بدون"
    case "Prayer Time":         return "وقت الصلاة"
    case "Countdown":           return "عداد تنازلي"
    case "Time":                return "الوقت"
    case "Language":            return "اللغة"
    case "English":             return "English"
    case "Startup":             return "التشغيل"
    case "Start at Login":      return "تشغيل عند بدء الجهاز"
    case "Background Image":    return "صورة الخلفية"
    case "Show Background":     return "عرض الخلفية"
    case "Opacity":             return "الشفافية"
    case "Choose Image":        return "اختر صورة"
    case "Change Image":        return "تغيير الصورة"
    case "Remove background image": return "حذف الخلفية"
    // Prayer method settings
    case "Current Method":      return "الطريقة الحالية"
    case "Fajr & Isha Method":  return "طريقة الفجر والعشاء"
    case "Asr Method":          return "طريقة العصر"
    case "Fajr angle":          return "زاوية الفجر"
    case "Isha angle":          return "زاوية العشاء"
    case "Used in: ":           return "تستخدم في: "
    case "Standard — Shafi'i, Maliki, Hanbali": return "المعيار — شافعي، مالكي، حنبلي"
    case "Hanafi (later time)": return "حنفي (وقت متأخر)"
    case "Methods differ in the angle of the sun below the horizon used to calculate Fajr and Isha times.":
        return "تختلف الطرق في زاوية الشمس تحت الأفق لحساب أوقات الفجر والعشاء."
    case "Lower angle = earlier Fajr / later Isha.":
        return "الزاوية الأصغر = فجر أبكر / عشاء أمتأخر."
    // Adjustments
    case "Prayer Time Adjustments (minutes)": return "ضبط أوقات الصلاة (دقائق)"
    case "Hijri Date Adjustment (days)":      return "ضبط التاريخ الهجري (أيام)"
    case "Days":                return "أيام"
    case "Positive = later date, Negative = earlier date":
        return "موجب = تاريخ متأخر، سالب = تاريخ مبكر"
    case "Reset All Adjustments": return "إعادة ضبط الكل"
    case "Use these adjustments if prayer times seem inaccurate for your location.":
        return "استخدم هذه الإعدادات إذا بدت الأوقات غير دقيقة لموقعك."
    case "Changes apply immediately.": return "تُطبق التغييرات فوراً."
    // Athan settings
    case "Audio":               return "الصوت"
    case "Silent mode":         return "وضع الصمت"
    case "Athan Reciter":       return "قارئ الأذان"
    case "Reminders":           return "التذكيرات"
    case "Reminder":            return "تذكير"
    case "Volume":              return "الصوت"
    case "Play dua after adhan": return "تشغيل الدعاء بعد الأذان"
    case "Notifications":       return "الإشعارات"
    case "Configure in System Settings": return "إعداد في تفضيلات النظام"
    case "Athan audio streams from cdn.aladhan.com — no internet, no sound.":
        return "صوت الأذان من cdn.aladhan.com — بدون انترنت، بدون صوت."
    case "Play":                return "تشغيل"
    case "Stop":                return "إيقاف"
    // Location
    case "Current Location (IP)": return "الموقع الحالي (IP)"
    case "Use My Location":     return "استخدم موقعي"
    case "Search City":         return "بحث عن مدينة"
    case "Popular Cities":      return "المدن الشهيرة"
    case "Search Results":      return "نتائج البحث"
    case "City name":           return "اسم المدينة"
    // Popover
    case "Next Prayer":         return "الصلاة القادمة"
    case "Athan · Now":         return "الأذان · الآن"
    case "All prayers completed": return "انتهت أوقات الصلاة"
    case "No prayer times available": return "لا توجد أوقات صلاة"
    case "Loading...":          return "جارٍ التحميل..."
    case "Stop Athan":          return "إيقاف الأذان"
    case "Athan on — tap to mute": return "الأذان مفعّل — اضغط للكتم"
    case "Athan off — tap to enable": return "الأذان معطّل — اضغط للتفعيل"
    case "Hijri":               return "هجري"
    // About
    case "Mobile Developer":    return "مطور تطبيقات"
    case "Prayer Times for macOS": return "أوقات الصلاة لـ macOS"
    case "Version 1.1.0":         return "الإصدار 1.1.0"
    case "Made with ♥ by":      return "صُنع بـ ♥ من قِبل"
    case "Buy Me a Coffee — Ko-fi": return "ادعمني على Ko-fi ☕"
    case "Prayer times powered by AlAdhan API": return "أوقات الصلاة من AlAdhan API"
    case "Caching ":            return "تخزين "
    case "Salaati provides accurate prayer times, athan notifications, and a beautiful menu bar experience — built for Muslim users on macOS.":
        return "صلاتي يوفر أوقات صلاة دقيقة، وإشعارات الأذان، وتجربة جميلة في شريط القائمة — مصمم لمستخدمي macOS المسلمين."
    default:                    return english
    }
}

// MARK: - Prayer Times Manager
@MainActor
class PrayerTimesManager: ObservableObject {
    @Published var prayers: [Prayer] = []
    @Published var locationName: String = "Casablanca"
    @Published var latitude: Double = 33.5731
    @Published var longitude: Double = -7.5898
    @Published var currentPrayerIndex: Int = 0
    @Published var hijriDate: String = ""
    @Published var timezone: TimeZone = TimeZone(identifier: "Africa/Casablanca")!
    @Published var isLoading: Bool = false

    // Raw (unadjusted) prayer times from API — adjustments are applied locally
    private var rawPrayers: [Prayer] = []

    init() {
        loadSavedLocation()
        Task { await fetchPrayerTimes() }

        // Listen for full refresh requests (location/method changes)
        NotificationCenter.default.addObserver(forName: .refreshPrayerTimes, object: nil, queue: .main) { [weak self] _ in
            Task { await self?.fetchPrayerTimes() }
        }
        // Listen for adjustment-only updates (no network call)
        NotificationCenter.default.addObserver(forName: .applyAdjustments, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.applyAdjustmentsLocally() }
        }

        scheduleMidnightRefresh()
    }

    // Re-applies minute adjustments to the cached raw prayer times without an API call
    func applyAdjustmentsLocally() {
        guard !rawPrayers.isEmpty else { return }
        let s = SettingsManager.shared
        let offsets = [s.fajrAdjustment, s.sunriseAdjustment, s.dhuhrAdjustment,
                       s.asrAdjustment, s.maghribAdjustment, s.ishaAdjustment]
        prayers = rawPrayers.enumerated().map { (i, prayer) in
            var p = prayer
            if offsets[i] != 0 {
                p.time = Calendar.current.date(byAdding: .minute, value: offsets[i], to: prayer.time) ?? prayer.time
            }
            return p
        }
        updateCurrentPrayer()
        save()
        objectWillChange.send()
        NotificationCenter.default.post(name: .refreshMenuBar, object: nil)
    }

    // Schedules a refresh at midnight so times stay accurate across days
    private func scheduleMidnightRefresh() {
        let calendar = Calendar.current
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: Date()),
              let midnight = calendar.date(bySettingHour: 0, minute: 0, second: 5, of: tomorrow) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + midnight.timeIntervalSinceNow) { [weak self] in
            Task { await self?.fetchPrayerTimes() }
            self?.scheduleMidnightRefresh()
        }
    }

    func loadSavedLocation() {
        if let name = UserDefaults.standard.string(forKey: "locationName") {
            locationName = name
        }
        if UserDefaults.standard.object(forKey: "latitude") != nil {
            latitude = UserDefaults.standard.double(forKey: "latitude")
            longitude = UserDefaults.standard.double(forKey: "longitude")
        }
        if let tz = UserDefaults.standard.string(forKey: "timezone"),
           let timezone = TimeZone(identifier: tz) {
            self.timezone = timezone
        }
    }

    func fetchPrayerTimes() async {
        isLoading = true
        print("Fetching prayer times for: \(locationName) (\(latitude), \(longitude))")

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "dd-MM-yyyy"
        let dateString = dateFormatter.string(from: Date())

        let settings = SettingsManager.shared
        let method = settings.fajrIshaMethod
        let school = settings.asrMethod.rawValue  // 0 = Shafi'i/Maliki/Hanbali, 1 = Hanafi

        // Use coordinates API — `school` controls Asr shadow ratio
        let urlString = "https://api.aladhan.com/v1/timings/\(dateString)?latitude=\(latitude)&longitude=\(longitude)&method=\(method)&school=\(school)"

        guard let url = URL(string: urlString) else {
            prayers = getDefaultPrayers()
            isLoading = false
            return
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let response = try JSONDecoder().decode(AlAdhanResponse.self, from: data)

            guard let timings = response.data.timings else {
                prayers = getDefaultPrayers()
                isLoading = false
                return
            }

            let calendar = Calendar.current
            let today = Date()

            // Apply hijri adjustment
            let hijriDay = (Int(response.data.date.hijri.day) ?? 0) + settings.hijriAdjustment
            let hijriMonthAr = response.data.date.hijri.month.ar
            _ = response.data.date.hijri.month.en ?? ""
            hijriDate = "\(hijriDay) \(hijriMonthAr) \(response.data.date.hijri.year)"
            print("Hijri date: \(hijriDate)")

            // Store raw (unadjusted) times — adjustments are applied in applyAdjustmentsLocally()
            rawPrayers = [
                Prayer(name: "Fajr",    arabicName: "فجر",  time: parseTime(timings.fajr,    calendar: calendar, today: today), isEnabled: true),
                Prayer(name: "Sunrise", arabicName: "شروق", time: parseTime(timings.sunrise, calendar: calendar, today: today), isEnabled: true),
                Prayer(name: "Dhuhr",   arabicName: "ظهر",  time: parseTime(timings.dhuhr,   calendar: calendar, today: today), isEnabled: true),
                Prayer(name: "Asr",     arabicName: "عصر",  time: parseTime(timings.asr,     calendar: calendar, today: today), isEnabled: true),
                Prayer(name: "Maghrib", arabicName: "مغرب", time: parseTime(timings.maghrib, calendar: calendar, today: today), isEnabled: true),
                Prayer(name: "Isha",    arabicName: "عشاء", time: parseTime(timings.isha,    calendar: calendar, today: today), isEnabled: true)
            ]
            applyAdjustmentsLocally()
            // Schedule notifications after a real fetch (not on every adjustment)
            NotificationManager.shared.schedulePrayerNotifications(prayers: prayers, locationName: locationName)
            print("Prayer times updated successfully")
        } catch {
            print("Error: \(error)")
            prayers = getDefaultPrayers()
        }

        isLoading = false
    }

    private func parseTime(_ timeString: String, calendar: Calendar, today: Date) -> Date {
        let components = timeString.split(separator: ":")
        guard components.count >= 2,
              let hour = Int(components[0]),
              let minute = Int(components[1]) else { return today }
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: today) ?? today
    }

    private func getDefaultPrayers() -> [Prayer] {
        let calendar = Calendar.current
        let today = Date()
        return [
            Prayer(name: "Fajr", arabicName: "فجر", time: calendar.date(bySettingHour: 5, minute: 26, second: 0, of: today)!, isEnabled: true),
            Prayer(name: "Sunrise", arabicName: "شروق", time: calendar.date(bySettingHour: 6, minute: 49, second: 0, of: today)!, isEnabled: true),
            Prayer(name: "Dhuhr", arabicName: "ظهر", time: calendar.date(bySettingHour: 12, minute: 41, second: 0, of: today)!, isEnabled: true),
            Prayer(name: "Asr", arabicName: "عصر", time: calendar.date(bySettingHour: 15, minute: 30, second: 0, of: today)!, isEnabled: true),
            Prayer(name: "Maghrib", arabicName: "مغرب", time: calendar.date(bySettingHour: 18, minute: 33, second: 0, of: today)!, isEnabled: true),
            Prayer(name: "Isha", arabicName: "عشاء", time: calendar.date(bySettingHour: 19, minute: 51, second: 0, of: today)!, isEnabled: true)
        ]
    }

    func updateCurrentPrayer() {
        let now = Date()
        for (index, prayer) in prayers.enumerated() {
            if prayer.time > now && prayer.isEnabled {
                currentPrayerIndex = index
                return
            }
        }
        currentPrayerIndex = max(0, prayers.count - 1)
    }

    func getNextPrayer() -> Prayer? {
        let now = Date()
        return prayers.first(where: { $0.time > now && $0.isEnabled })
    }

    func timeRemaining() -> String {
        let now = Date()
        if let nextPrayer = prayers.first(where: { $0.time > now && $0.isEnabled }) {
            let components = Calendar.current.dateComponents([.hour, .minute], from: now, to: nextPrayer.time)
            if let hours = components.hour, let minutes = components.minute {
                return String(format: "%02d:%02d", hours, minutes)
            }
        }
        return "00:00"
    }

    func save() {
        UserDefaults.standard.set(locationName, forKey: "locationName")
        UserDefaults.standard.set(latitude, forKey: "latitude")
        UserDefaults.standard.set(longitude, forKey: "longitude")
        UserDefaults.standard.set(timezone.identifier, forKey: "timezone")
    }

    func updateLocation(name: String, lat: Double, lon: Double, tz: TimeZone? = nil) {
        print("Updating location to: \(name) (\(lat), \(lon))")
        locationName = name
        latitude = lat
        longitude = lon
        if let tz = tz { timezone = tz }
        save()
        Task { await fetchPrayerTimes() }
    }
}

// MARK: - Qibla Manager
@MainActor
class QiblaManager: ObservableObject {
    static let shared = QiblaManager()
    @Published var direction: Double? = nil  // degrees from North
    @Published var isLoading = false
    @Published var error: String? = nil

    func fetch(latitude: Double, longitude: Double) async {
        isLoading = true
        error = nil
        let urlString = "https://api.aladhan.com/v1/qibla/\(latitude)/\(longitude)"
        guard let url = URL(string: urlString) else { isLoading = false; return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let dataObj = json["data"] as? [String: Any],
               let dir = dataObj["direction"] as? Double {
                direction = dir
            }
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }
}

// MARK: - Qibla View
struct QiblaView: View {
    @ObservedObject var manager: PrayerTimesManager
    @StateObject private var qibla = QiblaManager.shared
    @ObservedObject private var settings = SettingsManager.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {

                if qibla.isLoading {
                    ProgressView().progressViewStyle(CircularProgressViewStyle(tint: Color(hex: "E94560")))
                        .padding(.top, 40)

                } else if let direction = qibla.direction {
                    // Compass rose
                    ZStack {
                        // Outer ring
                        Circle()
                            .stroke(Color.white.opacity(0.08), lineWidth: 1.5)
                            .frame(width: 220, height: 220)

                        // Cardinal directions
                        ForEach([(0.0, "N"), (90.0, "E"), (180.0, "S"), (270.0, "W")], id: \.1) { angle, label in
                            Text(label)
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.white.opacity(0.4))
                                .offset(y: -95)
                                .rotationEffect(.degrees(angle))
                        }

                        // Degree ticks
                        ForEach(0..<36) { i in
                            Rectangle()
                                .fill(Color.white.opacity(i % 9 == 0 ? 0.3 : 0.1))
                                .frame(width: 1, height: i % 9 == 0 ? 10 : 5)
                                .offset(y: -105)
                                .rotationEffect(.degrees(Double(i) * 10))
                        }

                        // Qibla arrow
                        VStack(spacing: 0) {
                            // Arrowhead
                            Triangle()
                                .fill(Color(hex: "E94560"))
                                .frame(width: 14, height: 18)
                            // Shaft
                            Rectangle()
                                .fill(Color(hex: "E94560"))
                                .frame(width: 3, height: 60)
                            // Kaaba icon at tip
                            Image(systemName: "cube.fill")
                                .font(.system(size: 14))
                                .foregroundColor(Color(hex: "E94560"))
                                .padding(.top, 4)
                        }
                        .rotationEffect(.degrees(direction))
                        .animation(.easeInOut(duration: 0.8), value: direction)

                        // Center dot
                        Circle()
                            .fill(Color.white.opacity(0.6))
                            .frame(width: 8, height: 8)
                    }
                    .padding(.top, 16)

                    // Direction info
                    VStack(spacing: 6) {
                        Text(String(format: "%.1f°", direction))
                            .font(.system(size: 36, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                        Text("from North")
                            .font(.system(size: 13))
                            .foregroundColor(.white.opacity(0.5))
                    }

                    // Instructions
                    VStack(spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: "iphone")
                                .foregroundColor(Color(hex: "E94560"))
                                .font(.system(size: 14))
                            Text("Use your iPhone compass to face \(String(format: "%.0f°", direction)) from North")
                                .font(.system(size: 12))
                                .foregroundColor(.white.opacity(0.5))
                                .multilineTextAlignment(.leading)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.04)))

                        Text("Based on \(manager.locationName)")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.3))
                    }
                    .padding(.horizontal, 4)

                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "location.slash")
                            .font(.system(size: 32))
                            .foregroundColor(.white.opacity(0.3))
                            .padding(.top, 40)
                        Text("Set your location first")
                            .font(.system(size: 14))
                            .foregroundColor(.white.opacity(0.5))
                    }
                }
            }
            .padding()
        }
        .task {
            await qibla.fetch(latitude: manager.latitude, longitude: manager.longitude)
        }
    }
}

struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Duaa
struct Duaa: Identifiable {
    let id = UUID()
    let arabic: String
    let transliteration: String
    let translation: String
    let occasion: String
}

let allDuaa: [Duaa] = [
    Duaa(arabic: "اللَّهُمَّ إِنِّي أَسْأَلُكَ عِلْمًا نَافِعًا، وَرِزْقًا طَيِّبًا، وَعَمَلًا مُتَقَبَّلًا",
         transliteration: "Allahumma inni as'aluka 'ilman nafi'an, wa rizqan tayyiban, wa 'amalan mutaqabbalan",
         translation: "O Allah, I ask You for beneficial knowledge, pure provision, and accepted deeds.",
         occasion: "Morning"),
    Duaa(arabic: "رَبِّ اشْرَحْ لِي صَدْرِي وَيَسِّرْ لِي أَمْرِي",
         transliteration: "Rabbi ishrah li sadri wa yassir li amri",
         translation: "My Lord, expand my chest and ease my task for me.",
         occasion: "Before work"),
    Duaa(arabic: "اللَّهُمَّ بِكَ أَصْبَحْنَا وَبِكَ أَمْسَيْنَا، وَبِكَ نَحْيَا وَبِكَ نَمُوتُ وَإِلَيْكَ النُّشُورُ",
         transliteration: "Allahumma bika asbahna wa bika amsayna, wa bika nahya wa bika namutu wa ilayka al-nushur",
         translation: "O Allah, by You we enter the morning and by You we enter the evening, by You we live and by You we die, and to You is the resurrection.",
         occasion: "Morning"),
    Duaa(arabic: "اللَّهُمَّ أَعِنِّي عَلَى ذِكْرِكَ وَشُكْرِكَ وَحُسْنِ عِبَادَتِكَ",
         transliteration: "Allahumma a'inni 'ala dhikrika wa shukrika wa husni 'ibadatika",
         translation: "O Allah, help me to remember You, to be grateful to You, and to worship You in an excellent manner.",
         occasion: "After prayer"),
    Duaa(arabic: "حَسْبُنَا اللَّهُ وَنِعْمَ الْوَكِيلُ",
         transliteration: "Hasbunallahu wa ni'mal wakil",
         translation: "Allah is sufficient for us, and He is the best disposer of affairs.",
         occasion: "Hardship"),
    Duaa(arabic: "رَبَّنَا آتِنَا فِي الدُّنْيَا حَسَنَةً وَفِي الآخِرَةِ حَسَنَةً وَقِنَا عَذَابَ النَّارِ",
         transliteration: "Rabbana atina fid-dunya hasanatan wa fil-akhirati hasanatan wa qina 'adhab an-nar",
         translation: "Our Lord, give us good in this world and good in the hereafter and save us from the punishment of the Fire.",
         occasion: "General"),
    Duaa(arabic: "اللَّهُمَّ إِنِّي أَعُوذُ بِكَ مِنَ الْهَمِّ وَالْحَزَنِ",
         transliteration: "Allahumma inni a'udhu bika minal-hammi wal-hazan",
         translation: "O Allah, I seek refuge in You from worry and grief.",
         occasion: "Anxiety"),
    Duaa(arabic: "سُبْحَانَ اللَّهِ وَبِحَمْدِهِ سُبْحَانَ اللَّهِ الْعَظِيمِ",
         transliteration: "Subhanallahi wa bihamdihi, subhanallahil 'adhim",
         translation: "Glory be to Allah and His is the praise, glory be to Allah the Magnificent.",
         occasion: "Dhikr"),
    Duaa(arabic: "اللَّهُمَّ اغْفِرْ لِي وَلِوَالِدَيَّ وَلِلْمُؤْمِنِينَ يَوْمَ يَقُومُ الْحِسَابُ",
         transliteration: "Allahummaghfir li wa liwalidayya wa lil mu'minin yawma yaqumul hisab",
         translation: "O Allah, forgive me, my parents, and the believers on the Day of Reckoning.",
         occasion: "For parents"),
    Duaa(arabic: "اللَّهُمَّ أَنْتَ السَّلَامُ وَمِنْكَ السَّلَامُ تَبَارَكْتَ يَا ذَا الْجَلَالِ وَالْإِكْرَامِ",
         transliteration: "Allahumma antas-salam wa minkas-salam tabarakta ya dhal-jalali wal-ikram",
         translation: "O Allah, You are Peace and from You is peace. Blessed are You, O possessor of glory and honour.",
         occasion: "After prayer"),
    Duaa(arabic: "رَبِّ زِدْنِي عِلْمًا",
         transliteration: "Rabbi zidni 'ilma",
         translation: "My Lord, increase me in knowledge.",
         occasion: "Seeking knowledge"),
    Duaa(arabic: "اللَّهُمَّ إِنِّي أَسْأَلُكَ الْعَافِيَةَ فِي الدُّنْيَا وَالآخِرَةِ",
         transliteration: "Allahumma inni as'alukal-'afiyata fid-dunya wal-akhirah",
         translation: "O Allah, I ask You for well-being in this world and the hereafter.",
         occasion: "General"),
]

// MARK: - Duaa View (shown in popover)
struct DuaaCardView: View {
    @State private var currentIndex = Int.random(in: 0..<allDuaa.count)
    @ObservedObject private var settings = SettingsManager.shared

    private var duaa: Duaa { allDuaa[currentIndex] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "hands.sparkles")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "E94560"))
                Text(settings.arabicMode ? "دعاء" : "Duaa · \(duaa.occasion)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color(hex: "E94560"))
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        currentIndex = (currentIndex + 1) % allDuaa.count
                    }
                } label: {
                    Image(systemName: "shuffle")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.4))
                }
                .buttonStyle(.plain)
                .help("Show another duaa")
            }

            Text(duaa.arabic)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.white)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .lineSpacing(4)

            if !settings.arabicMode {
                Text(duaa.transliteration)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.4))
                    .italic()

                Text(duaa.translation)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.6))
                    .lineSpacing(2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.04))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(hex: "E94560").opacity(0.15), lineWidth: 1)))
    }
}

// MARK: - Full Duaa List View (in settings)
struct DuaaListView: View {
    @ObservedObject private var settings = SettingsManager.shared
    @State private var shuffled = allDuaa.shuffled()

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                HStack {
                    Text(settings.arabicMode ? "أدعية يومية" : "\(allDuaa.count) daily supplications")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.4))
                    Spacer()
                    Button {
                        withAnimation { shuffled = allDuaa.shuffled() }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "shuffle")
                            Text(settings.arabicMode ? "خلط" : "Shuffle")
                        }
                        .font(.system(size: 12))
                        .foregroundColor(Color(hex: "E94560"))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 4)

                ForEach(shuffled) { duaa in
                    VStack(alignment: .trailing, spacing: 8) {
                        HStack {
                            Text(duaa.occasion)
                                .font(.system(size: 10))
                                .foregroundColor(.white.opacity(0.3))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Color.white.opacity(0.05)))
                            Spacer()
                        }
                        Text(duaa.arabic)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.white)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .lineSpacing(4)
                        if !settings.arabicMode {
                            Text(duaa.translation)
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.5))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.04)))
                }
            }
            .padding()
        }
    }
}

// MARK: - API Models
struct AlAdhanResponse: Codable { let data: AlAdhanData }
struct AlAdhanData: Codable { let timings: Timings?; let date: DateInfo }
struct DateInfo: Codable { let hijri: HijriDate }
struct HijriDate: Codable { let day: String; let month: HijriMonth; let year: String }
struct HijriMonth: Codable { let ar: String; let en: String? }
struct Timings: Codable {
    let fajr: String
    let sunrise: String
    let dhuhr: String
    let asr: String
    let maghrib: String
    let isha: String

    enum CodingKeys: String, CodingKey {
        case fajr = "Fajr"
        case sunrise = "Sunrise"
        case dhuhr = "Dhuhr"
        case asr = "Asr"
        case maghrib = "Maghrib"
        case isha = "Isha"
    }
}

// MARK: - App Background
// Base64 fallback — paste your base64 image string here if you prefer embedding
private let kBackgroundImageBase64: String = ""

struct AppBackground: View {
    @ObservedObject private var settings = SettingsManager.shared
    @State private var loadedImage: NSImage? = nil
    @State private var isLoading = false

    private var imagePath: String? {
        guard settings.showBackground else { return nil }
        // Prefer bookmark (sandbox-safe, persists across launches)
        if let bookmarkData = UserDefaults.standard.data(forKey: "backgroundImageBookmark") {
            var isStale = false
            if let url = try? URL(resolvingBookmarkData: bookmarkData, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale) {
                return url.path
            }
        }
        // Fallback to plain path (non-sandboxed builds)
        if let path = UserDefaults.standard.string(forKey: "backgroundImagePath"), !path.isEmpty {
            return path
        }
        return nil
    }

    var body: some View {
        ZStack {
            LinearGradient(
                gradient: Gradient(colors: [Color(hex: "1A1A2E"), Color(hex: "16213E")]),
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            if settings.showBackground {
                if isLoading {
                    // Subtle shimmer placeholder while image loads
                    Rectangle()
                        .fill(Color.white.opacity(0.04))
                        .ignoresSafeArea()
                        .overlay(
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .scaleEffect(0.7)
                                .opacity(0.4)
                        )
                } else if let img = loadedImage {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFill()
                        .opacity(settings.backgroundOpacity)
                        .ignoresSafeArea()
                        .clipped()
                        .allowsHitTesting(false)
                        .transition(.opacity.animation(.easeIn(duration: 0.4)))
                } else if !kBackgroundImageBase64.isEmpty {
                    // Base64 fallback (already in memory, no async needed)
                    if let data = Data(base64Encoded: kBackgroundImageBase64, options: .ignoreUnknownCharacters),
                       let img = NSImage(data: data) {
                        Image(nsImage: img)
                            .resizable()
                            .scaledToFill()
                            .opacity(settings.backgroundOpacity)
                            .ignoresSafeArea()
                            .clipped()
                            .allowsHitTesting(false)
                    }
                }
            }
        }
        .task(id: imagePath) {
            await loadImage(path: imagePath)
        }
    }

    private func loadImage(path: String?) async {
        guard let path else { loadedImage = nil; return }
        if loadedImage != nil,
           UserDefaults.standard.string(forKey: "backgroundImagePath") == path { return }

        isLoading = true
        loadedImage = nil

        // Start security-scoped access if we have a bookmark
        var scopedURL: URL? = nil
        if let bookmarkData = UserDefaults.standard.data(forKey: "backgroundImageBookmark") {
            var isStale = false
            if let url = try? URL(resolvingBookmarkData: bookmarkData, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale) {
                url.startAccessingSecurityScopedResource()
                scopedURL = url
            }
        }

        // Load data on background thread (avoids NSImage Sendable issue pre-macOS 14)
        let imgData = await Task.detached(priority: .background) {
            try? Data(contentsOf: URL(fileURLWithPath: path))
        }.value

        scopedURL?.stopAccessingSecurityScopedResource()

        let img: NSImage? = imgData.flatMap { NSImage(data: $0) }

        withAnimation { isLoading = false }
        if let img { withAnimation(.easeIn(duration: 0.4)) { loadedImage = img } }
    }
}

// MARK: - Menu Bar Popover View
struct MenuBarPopoverView: View {
    @ObservedObject var manager: PrayerTimesManager
    @ObservedObject private var settings = SettingsManager.shared
    @ObservedObject private var player = AthanPlayer.shared
    weak var appDelegate: AppDelegate?
    @State private var showingSettings = false
    @State private var showingAbout = false
    @State private var glowPulse = false

    var body: some View {
        VStack(spacing: 0) {
            headerView

            // Loading indicator
            if manager.isLoading {
                HStack {
                    ProgressView()
                        .scaleEffect(0.8)
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    Text(L("Loading...")).font(.system(size: 12)).foregroundColor(.white.opacity(0.7))
                }.padding(.vertical, 20)
            } else if !manager.prayers.isEmpty {
                nextPrayerCard.padding(.horizontal, 16).padding(.vertical, 12)
                prayerTimesList
            } else {
                Text(L("No prayer times available")).foregroundColor(.white.opacity(0.5)).padding(.vertical, 40)
            }

            footerView
        }
        .frame(width: 380, height: 750)
        .background(AppBackground())
        .onReceive(NotificationCenter.default.publisher(for: .refreshMenuBar)) { _ in
            appDelegate?.refreshMenuBar()
        }
        .onReceive(NotificationCenter.default.publisher(for: .refreshPrayerTimes)) { _ in
            // Force view refresh when prayer times change
            appDelegate?.refreshMenuBar()
        }
        .preferredColorScheme(.dark)
    }

    private var headerView: some View {
        VStack(spacing: 6) {
            HStack { Image(systemName: "location.fill").font(.caption); Text(manager.locationName).font(.system(size: 13, weight: .medium)) }.foregroundColor(.white.opacity(0.7))
            if !manager.hijriDate.isEmpty {
                VStack(spacing: 2) {
                    Text(manager.hijriDate).font(.system(size: 20, weight: .bold)).foregroundColor(.white)
                    Text(L("Hijri")).font(.system(size: 10)).foregroundColor(.white.opacity(0.4))
                }
            }
            Text(formattedDate()).font(.system(size: 11)).foregroundColor(.white.opacity(0.5))
        }.padding(.top, 16).padding(.bottom, 8)
    }

    @ViewBuilder
    private var nextPrayerCard: some View {
        let isAthanPlaying = player.isPlaying
        let ringingPrayerName = player.currentlyPlayingPrayerName

        // Resolve display name — ringing prayer if athan is active, else next upcoming
        let cardPrayer: Prayer? = isAthanPlaying
            ? manager.prayers.first(where: { $0.name == ringingPrayerName })
            : manager.getNextPrayer()

        if let prayer = cardPrayer {
            let displayName = prayer.localizedName

            VStack(spacing: 4) {
                // Label row
                HStack(spacing: 6) {
                    if isAthanPlaying {
                        if #available(macOS 14.0, *) {
                            Image(systemName: "waveform")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(Color(hex: "E94560"))
                                .symbolEffect(.variableColor.iterative, isActive: true)
                        } else {
                            Image(systemName: "waveform")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(Color(hex: "E94560"))
                        }
                    }
                    Text(isAthanPlaying ? L("Athan · Now") : L("Next Prayer"))
                        .font(.system(size: 11))
                        .foregroundColor(isAthanPlaying ? Color(hex: "E94560") : .white.opacity(0.6))
                }

                Text(displayName)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(Color(hex: "E94560"))
                    .scaleEffect(isAthanPlaying ? (glowPulse ? 1.04 : 1.0) : 1.0)

                if isAthanPlaying {
                    Text(timeFormatter.string(from: prayer.time))
                        .font(.system(size: 22, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                } else {
                    Text(manager.timeRemaining())
                        .font(.system(size: 22, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                    Text(timeFormatter.string(from: prayer.time))
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.5))
                }

                // Stop button — always in hierarchy, visible only when athan plays
                Button(action: { AthanPlayer.shared.stop() }) {
                    HStack(spacing: 5) {
                        Image(systemName: "stop.fill").font(.system(size: 9, weight: .bold))
                        Text(L("Stop Athan")).font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundColor(Color(hex: "E94560"))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(Color(hex: "E94560").opacity(0.15))
                            .overlay(Capsule().strokeBorder(Color(hex: "E94560").opacity(0.5), lineWidth: 1))
                    )
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
                .opacity(isAthanPlaying ? 1 : 0)
                .frame(height: isAthanPlaying ? nil : 0)
                .clipped()
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isAthanPlaying
                          ? Color(hex: "E94560").opacity(glowPulse ? 0.18 : 0.08)
                          : Color.white.opacity(0.1))
                    .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: glowPulse)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        Color(hex: "E94560").opacity(isAthanPlaying ? (glowPulse ? 0.9 : 0.3) : 0.3),
                        lineWidth: isAthanPlaying ? (glowPulse ? 2 : 1) : 1
                    )
                    .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: glowPulse)
            )
            .shadow(
                color: isAthanPlaying ? Color(hex: "E94560").opacity(glowPulse ? 0.5 : 0.1) : .clear,
                radius: glowPulse ? 16 : 6
            )
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: glowPulse)
            .onChange(of: isAthanPlaying) { playing in
                if playing {
                    glowPulse = true
                } else {
                    withAnimation(.easeOut(duration: 0.3)) { glowPulse = false }
                }
            }
        } else {
            VStack { Text(L("All prayers completed")).foregroundColor(.white.opacity(0.7)) }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.1)))
        }
    }

    private var prayerTimesList: some View {
        ScrollView {
            VStack(spacing: 6) {
                ForEach(manager.prayers) { prayer in
                    let displayName = prayer.localizedName
                    let athanOn = prayer.name != "Sunrise" && settings.athanEnabled(for: prayer.name)
                    let isCurrent = isCurrentPrayer(prayer)

                    HStack(spacing: 0) {
                        // Prayer name
                        Text(displayName)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(prayer.isEnabled ? .white : .white.opacity(0.4))

                        Spacer()

                        // Athan bell toggle (hidden for Sunrise)
                        if prayer.name != "Sunrise" && !settings.silentMode {
                            Button {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    toggleAthan(for: prayer.name)
                                }
                            } label: {
                                Image(systemName: athanOn ? "bell.fill" : "bell.slash")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(athanOn ? Color(hex: "E94560") : .white.opacity(0.25))
                                    .frame(width: 28, height: 28)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(athanOn ? L("Athan on — tap to mute") : L("Athan off — tap to enable"))
                        }

                        // Time
                        Text(timeFormatter.string(from: prayer.time))
                            .font(.system(size: 14, weight: .medium, design: .monospaced))
                            .foregroundColor(prayer.isEnabled ? .white : .white.opacity(0.4))
                            .frame(width: 52, alignment: .trailing)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(isCurrent ? Color(hex: "E94560").opacity(0.15) : Color.white.opacity(0.03))
                    )
                }
            }.padding(.horizontal, 12)
            
            // Duaa card at bottom of list
            DuaaCardView()
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
        }
    }

    private func toggleAthan(for prayerName: String) {
        switch prayerName {
        case "Fajr":    settings.fajrAthanEnabled.toggle()
        case "Dhuhr":   settings.dhuhrAthanEnabled.toggle()
        case "Asr":     settings.asrAthanEnabled.toggle()
        case "Maghrib": settings.maghribAthanEnabled.toggle()
        case "Isha":    settings.ishaAthanEnabled.toggle()
        default: break
        }
    }

    private var footerView: some View {
        VStack(spacing: 0) {
            // Stop bar — slides in when athan is playing
            if player.isPlaying {
                Button(action: { AthanPlayer.shared.stop() }) {
                    HStack(spacing: 6) {
                        Image(systemName: "stop.circle.fill").font(.system(size: 14))
                        Text(L("Stop Athan"))
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color(hex: "E94560"))
                }
                .buttonStyle(.plain)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            HStack(spacing: 20) {
                Button(action: { showingSettings = true }) {
                    HStack(spacing: 4) { Image(systemName: "gearshape"); Text(L("Settings")) }
                        .font(.system(size: 12)).foregroundColor(.white.opacity(0.7))
                }.buttonStyle(.plain)
                Button(action: { Task { await manager.fetchPrayerTimes() } }) {
                    HStack(spacing: 4) { Image(systemName: "arrow.clockwise"); Text(L("Refresh")) }
                        .font(.system(size: 12)).foregroundColor(.white.opacity(0.7))
                }.buttonStyle(.plain)
                Button(action: { showingAbout = true }) {
                    HStack(spacing: 4) { Image(systemName: "info.circle"); Text(L("About")) }
                        .font(.system(size: 12)).foregroundColor(.white.opacity(0.7))
                }.buttonStyle(.plain)
                Button(action: { NSApplication.shared.terminate(nil) }) {
                    HStack(spacing: 4) { Image(systemName: "power"); Text(L("Quit")) }
                        .font(.system(size: 12)).foregroundColor(.white.opacity(0.7))
                }.buttonStyle(.plain)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
            .background(Color.black.opacity(0.2))
        }
        .animation(.easeInOut(duration: 0.25), value: player.isPlaying)
        .sheet(isPresented: $showingSettings) { SettingsView(manager: manager, appDelegate: appDelegate) }
        .sheet(isPresented: $showingAbout) { AboutView() }
    }

    private func isCurrentPrayer(_ prayer: Prayer) -> Bool {
        guard let index = manager.prayers.firstIndex(where: { $0.id == prayer.id }) else { return false }
        return index == manager.currentPrayerIndex
    }

    private func formattedDate() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMMM d, yyyy"
        formatter.locale = SettingsManager.shared.arabicMode
            ? Locale(identifier: "ar_MA")
            : Locale(identifier: "en_US")
        return formatter.string(from: Date())
    }

    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
}

// MARK: - Settings View
struct SettingsView: View {
    @ObservedObject var manager: PrayerTimesManager
    weak var appDelegate: AppDelegate?
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedTab) {
                Text(L("General")).tag(0)
                Text(L("Location")).tag(1)
                Text(L("Prayer")).tag(2)
                Text(L("Adjust")).tag(3)
                Text(L("Athan")).tag(4)
                Text(L("Qibla")).tag(5)
                Text(L("Duaa")).tag(6)
            }.pickerStyle(.segmented).padding()

            TabView(selection: $selectedTab) {
                GeneralSettingsView(appDelegate: appDelegate).tag(0)
                LocationSettingsView(manager: manager, appDelegate: appDelegate).tag(1)
                PrayerTimesSettingsView(manager: manager, appDelegate: appDelegate).tag(2)
                AdjustmentsSettingsView(manager: manager).tag(3)
                AthanSettingsView().tag(4)
                QiblaView(manager: manager).tag(5)
                DuaaListView().tag(6)
            }.tabViewStyle(.automatic)

            HStack { Spacer(); Button(L("Done")) { dismiss() }.foregroundColor(Color(hex: "E94560")).padding() }
        }
        .frame(width: 380, height: 500)
        .background(AppBackground())
        .onReceive(NotificationCenter.default.publisher(for: .refreshPrayerTimes)) { _ in
            // Force refresh when location/prayer times change
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - General Settings
struct GeneralSettingsView: View {
    weak var appDelegate: AppDelegate?
    @ObservedObject var settingsManager = SettingsManager.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                SettingsSection(title: L("Menu Bar Display")) {
                    Toggle(L("Show Next Prayer"), isOn: $settingsManager.showNextPrayer).tint(Color(hex: "E94560"))
                    Toggle(L("Show Icon"), isOn: $settingsManager.showIcon).tint(Color(hex: "E94560"))
                }

                SettingsSection(title: L("Prayer Name")) {
                    Picker("Display", selection: $settingsManager.prayerNameDisplay) {
                        Text(L("Full")).tag(PrayerNameDisplay.full)
                        Text(L("Abbrev")).tag(PrayerNameDisplay.abbreviation)
                        Text(L("None")).tag(PrayerNameDisplay.none)
                    }.pickerStyle(.segmented)
                }

                SettingsSection(title: L("Prayer Time")) {
                    Picker("Display", selection: $settingsManager.prayerTimeDisplay) {
                        Text(L("Countdown")).tag(PrayerTimeDisplay.countdown)
                        Text(L("Time")).tag(PrayerTimeDisplay.time)
                        Text(L("None")).tag(PrayerTimeDisplay.none)
                    }.pickerStyle(.segmented)
                }

                SettingsSection(title: L("Language")) {
                    Picker("Display", selection: $settingsManager.arabicMode) {
                        Text(L("English")).tag(false)
                        Text("عربي  (Arabic)").tag(true)
                    }.pickerStyle(.segmented)
                }

                SettingsSection(title: L("Startup")) {
                    Toggle(L("Start at Login"), isOn: $settingsManager.startAtLogin).tint(Color(hex: "E94560"))
                }

                SettingsSection(title: L("Background Image")) {
                    VStack(spacing: 10) {
                        Toggle(L("Show Background"), isOn: $settingsManager.showBackground).tint(Color(hex: "E94560"))

                        if settingsManager.showBackground {
                            // Opacity slider
                            HStack(spacing: 8) {
                                Text(L("Opacity")).font(.system(size: 13)).foregroundColor(.white)
                                Slider(value: $settingsManager.backgroundOpacity, in: 0.05...0.6)
                                    .tint(Color(hex: "E94560"))
                                Text("\(Int(settingsManager.backgroundOpacity * 100))%")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(Color(hex: "E94560"))
                                    .frame(width: 36, alignment: .trailing)
                            }

                            // Current image name
                            if let bookmarkData = UserDefaults.standard.data(forKey: "backgroundImageBookmark"),
                               let url = { var s = false; return try? URL(resolvingBookmarkData: bookmarkData, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &s) }() {
                                HStack {
                                    Image(systemName: "photo").foregroundColor(.white.opacity(0.5)).font(.system(size: 11))
                                    Text(url.lastPathComponent)
                                        .font(.system(size: 11))
                                        .foregroundColor(.white.opacity(0.5))
                                        .lineLimit(1)
                                    Spacer()
                                    Button {
                                        UserDefaults.standard.removeObject(forKey: "backgroundImageBookmark")
                                        UserDefaults.standard.removeObject(forKey: "backgroundImagePath")
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundColor(.white.opacity(0.4))
                                            .font(.system(size: 13))
                                    }
                                    .buttonStyle(.plain)
                                    .help("Remove background image")
                                }
                            }

                            // Pick image button
                            Button {
                                let panel = NSOpenPanel()
                                panel.allowedContentTypes = [.jpeg, .png, .heic, .webP, .bmp, .tiff]
                                panel.allowsMultipleSelection = false
                                panel.canChooseDirectories = false
                                panel.message = "Choose a background image"
                                if panel.runModal() == .OK, let url = panel.url {
                                    // Store both bookmark (sandbox-safe) and plain path (fallback)
                                    if let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                                        UserDefaults.standard.set(bookmark, forKey: "backgroundImageBookmark")
                                    }
                                    UserDefaults.standard.set(url.path, forKey: "backgroundImagePath")
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "photo.badge.plus")
                                    Text(UserDefaults.standard.data(forKey: "backgroundImageBookmark") != nil ? L("Change Image") : L("Choose Image"))
                                }
                                .font(.system(size: 13))
                                .foregroundColor(Color(hex: "E94560"))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }.padding()
        }
    }
}

// MARK: - Location Settings
struct LocationSettingsView: View {
    @ObservedObject var manager: PrayerTimesManager
    weak var appDelegate: AppDelegate?

    @State private var cityInput: String = ""
    @State private var latitude: String = ""
    @State private var longitude: String = ""
    @State private var selectedTimezone: String = "Africa/Casablanca"
    @State private var isSearching: Bool = false
    @State private var searchError: String?
    @State private var searchResults: [SearchResult] = []
    @State private var showResults: Bool = false

    struct SearchResult: Identifiable {
        let id = UUID()
        let name: String
        let country: String
        let lat: Double
        let lon: Double
        let admin: String
        let timezone: String
    }

    private let timezones = TimeZone.knownTimeZoneIdentifiers.sorted()

    private let popularCities = [
        ("Casablanca", 33.5731, -7.5898, "Africa/Casablanca"),
        ("Rabat", 34.0209, -6.8416, "Africa/Casablanca"),
        ("Marrakech", 31.6295, -7.9811, "Africa/Casablanca"),
        ("London", 51.5074, -0.1278, "Europe/London"),
        ("Paris", 48.8566, 2.3522, "Europe/Paris"),
        ("Dubai", 25.2048, 55.2708, "Asia/Dubai"),
        ("Istanbul", 41.0082, 28.9784, "Europe/Istanbul"),
        ("New York", 40.7128, -74.0060, "America/New_York")
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                SettingsSection(title: L("Current Location (IP)")) {
                    Button(action: useCurrentLocation) {
                        HStack {
                            if isSearching {
                                ProgressView().scaleEffect(0.8)
                            } else {
                                Image(systemName: "location.fill")
                            }
                            Text(L("Use My Location"))
                        }
                    }.disabled(isSearching)
                }

                SettingsSection(title: L("Search City")) {
                    HStack {
                        TextField("City name", text: $cityInput).textFieldStyle(.roundedBorder)
                            .onSubmit { searchCity() }
                        Button(action: searchCity) {
                            if isSearching {
                                ProgressView().scaleEffect(0.8)
                            } else {
                                Image(systemName: "magnifyingglass")
                            }
                        }.disabled(isSearching || cityInput.isEmpty)
                    }
                }

                // Search Results
                if showResults && !searchResults.isEmpty {
                    SettingsSection(title: L("Search Results")) {
                        ForEach(searchResults) { result in
                            Button(action: {
                                let fullName = result.admin.isEmpty ? "\(result.name), \(result.country)" : "\(result.name), \(result.admin), \(result.country)"
                                setLocation(city: fullName, lat: result.lat, lon: result.lon, tz: result.timezone)
                            }) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(result.name).font(.system(size: 14, weight: .medium)).foregroundColor(.white)
                                        Text("\(result.admin), \(result.country)").font(.system(size: 11)).foregroundColor(.white.opacity(0.6))
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").foregroundColor(.white.opacity(0.4)).font(.caption)
                                }.padding(.vertical, 4)
                            }.buttonStyle(.plain)
                        }
                    }
                }

                SettingsSection(title: L("Popular Cities")) {
                    ForEach(popularCities, id: \.0) { city, lat, lon, tz in
                        Button(action: {
                            setLocation(city: city, lat: lat, lon: lon, tz: tz)
                        }) {
                            HStack {
                                Text(city).foregroundColor(.white)
                                Spacer()
                                if manager.locationName == city || manager.locationName.contains(city) {
                                    Image(systemName: "checkmark").foregroundColor(Color(hex: "E94560"))
                                }
                            }.padding(.vertical, 4)
                        }.buttonStyle(.plain)
                    }
                }

                if let error = searchError {
                    Text(error).font(.caption).foregroundColor(.red)
                }

                // Current location display
                if !manager.locationName.isEmpty {
                    HStack {
                        Image(systemName: "mappin.circle.fill").foregroundColor(Color(hex: "E94560"))
                        Text("Current: \(manager.locationName)").font(.system(size: 12)).foregroundColor(.white.opacity(0.7))
                    }.padding(.top, 8)
                }
            }.padding()
        }.onAppear { loadCurrentSettings() }
    }

    private func loadCurrentSettings() {
        cityInput = manager.locationName
        latitude = String(manager.latitude)
        longitude = String(manager.longitude)
        selectedTimezone = manager.timezone.identifier
    }

    private func setLocation(city: String, lat: Double, lon: Double, tz: String) {
        // Clear search results
        searchResults = []
        showResults = false
        cityInput = ""
        
        // Update location and fetch new prayer times
        manager.updateLocation(name: city, lat: lat, lon: lon, tz: TimeZone(identifier: tz))
        
        // Force a refresh immediately
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            Task {
                await self.manager.fetchPrayerTimes()
                // Close settings and reopen main popover
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    appDelegate?.popover.performClose(nil)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        if let button = appDelegate?.statusItem.button {
                            appDelegate?.popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                        }
                    }
                }
            }
        }
    }

    private func useCurrentLocation() {
        isSearching = true
        searchError = nil

        Task {
            guard let url = URL(string: "https://ipapi.co/json/") else {
                await MainActor.run {
                    searchError = "Invalid URL"
                    isSearching = false
                }
                return
            }

            do {
                let (data, response) = try await URLSession.shared.data(from: url)

                guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                    await MainActor.run {
                        searchError = "Could not get location"
                        isSearching = false
                    }
                    return
                }

                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let city = json["city"] as? String,
                      let country = json["country_name"] as? String,
                      let lat = json["latitude"] as? Double,
                      let lon = json["longitude"] as? Double,
                      let tzString = json["timezone"] as? String else {
                    await MainActor.run {
                        searchError = "Could not parse location data"
                        isSearching = false
                    }
                    return
                }

                await MainActor.run {
                    manager.updateLocation(name: "\(city), \(country)", lat: lat, lon: lon, tz: TimeZone(identifier: tzString))
                    isSearching = false

                    // Force UI refresh
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        appDelegate?.refreshMenuBar()
                        NotificationCenter.default.post(name: .refreshPrayerTimes, object: nil)
                    }
                }
            } catch {
                await MainActor.run {
                    searchError = "Error: \(error.localizedDescription)"
                    isSearching = false
                }
            }
        }
    }

    private func searchCity() {
        guard !cityInput.isEmpty else { return }
        isSearching = true
        searchError = nil
        searchResults = []
        showResults = false

        Task {
            let query = cityInput.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? cityInput
            let urlString = "https://geocoding-api.open-meteo.com/v1/search?name=\(query)&count=5&language=en&format=json"

            guard let url = URL(string: urlString) else {
                await MainActor.run {
                    searchError = "Invalid URL"
                    isSearching = false
                }
                return
            }

            do {
                let (data, response) = try await URLSession.shared.data(from: url)

                guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                    await MainActor.run {
                        searchError = "Server error"
                        isSearching = false
                    }
                    return
                }

                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let results = json["results"] as? [[String: Any]] else {
                    await MainActor.run {
                        searchError = "City not found"
                        isSearching = false
                    }
                    return
                }

                let parsedResults = results.compactMap { result -> SearchResult? in
                    guard let name = result["name"] as? String,
                          let lat = result["latitude"] as? Double,
                          let lon = result["longitude"] as? Double else { return nil }

                    let country = result["country"] as? String ?? ""
                    let admin = result["admin1"] as? String ?? ""
                    // Open-Meteo returns a "timezone" field (e.g. "Europe/London")
                    let timezone = result["timezone"] as? String ?? TimeZone.current.identifier
                    return SearchResult(name: name, country: country, lat: lat, lon: lon, admin: admin, timezone: timezone)
                }

                await MainActor.run {
                    if parsedResults.isEmpty {
                        searchError = "No results found"
                    } else {
                        searchResults = parsedResults
                        showResults = true
                    }
                    isSearching = false
                }
            } catch {
                await MainActor.run {
                    searchError = "Error: \(error.localizedDescription)"
                    isSearching = false
                }
            }
        }
    }
}

// MARK: - Prayer Times Settings
struct PrayerTimesSettingsView: View {
    @ObservedObject var manager: PrayerTimesManager
    weak var appDelegate: AppDelegate?
    @ObservedObject var settingsManager = SettingsManager.shared

    private let calculationMethods: [(id: Int, name: String, fajr: String, isha: String, usedIn: String)] = [
        (0, "Muslim World League", "18°", "17°", "Europe, Africa, Middle East"),
        (1, "ISNA", "15°", "15°", "North America"),
        (2, "Egyptian", "19.5°", "17.5°", "Egypt, Sudan"),
        (3, "Umm al-Qura", "18.5°", "90 min", "Saudi Arabia"),
        (4, "Ministry of Awqaf", "19.5°", "17.5°", "Kuwait, Qatar"),
        (5, "Geophysics", "17.5°", "19°", "Arabian Gulf"),
        (6, "Habib Al Syed", "18°", "18°", "India, Pakistan")
    ]

    private var currentMethod: (id: Int, name: String, fajr: String, isha: String, usedIn: String)? {
        calculationMethods.first { $0.id == settingsManager.fajrIshaMethod }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Current method info
                if let method = currentMethod {
                    SettingsSection(title: L("Current Method")) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(method.name).font(.system(size: 14, weight: .bold)).foregroundColor(.white)
                            HStack(spacing: 16) {
                                VStack(alignment: .leading) {
                                    Text(L("Fajr angle")).font(.system(size: 11)).foregroundColor(.white.opacity(0.5))
                                    Text(method.fajr).font(.system(size: 13, weight: .medium)).foregroundColor(Color(hex: "E94560"))
                                }
                                VStack(alignment: .leading) {
                                    Text(L("Isha angle")).font(.system(size: 11)).foregroundColor(.white.opacity(0.5))
                                    Text(method.isha).font(.system(size: 13, weight: .medium)).foregroundColor(Color(hex: "E94560"))
                                }
                            }
                            Text("\(L("Used in: "))\(method.usedIn)").font(.system(size: 11)).foregroundColor(.white.opacity(0.5))
                        }
                    }
                }

                SettingsSection(title: L("Fajr & Isha Method")) {
                    Picker("Method", selection: $settingsManager.fajrIshaMethod) {
                        ForEach(calculationMethods, id: \.0) { method in
                            Text(method.name).tag(method.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: settingsManager.fajrIshaMethod) { _ in
                        Task { await manager.fetchPrayerTimes() }
                        appDelegate?.refreshMenuBar()
                    }
                }

                SettingsSection(title: L("Asr Method")) {
                    Picker("Method", selection: $settingsManager.asrMethod) {
                        Text(L("Standard — Shafi'i, Maliki, Hanbali")).tag(AsrMethod.standard)
                        Text(L("Hanafi (later time)")).tag(AsrMethod.hanbali)
                    }
                    .pickerStyle(.menu)
                    .onChange(of: settingsManager.asrMethod) { _ in
                        Task { await manager.fetchPrayerTimes() }
                        appDelegate?.refreshMenuBar()
                    }
                }

                // Info text
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Methods differ in the angle of the sun below the horizon used to calculate Fajr and Isha times.")).font(.system(size: 10)).foregroundColor(.white.opacity(0.4))
                    Text(L("Lower angle = earlier Fajr / later Isha.")).font(.system(size: 10)).foregroundColor(.white.opacity(0.4))
                }
            }.padding()
        }
    }
}

// MARK: - Adjustments Settings
struct AdjustmentsSettingsView: View {
    @ObservedObject var manager: PrayerTimesManager
    @ObservedObject var settingsManager = SettingsManager.shared

    private let prayers = ["Fajr", "Sunrise", "Dhuhr", "Asr", "Maghrib", "Isha"]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Prayer time adjustments
                SettingsSection(title: L("Prayer Time Adjustments (minutes)")) {
                    VStack(spacing: 8) {
                        adjustmentRow(prayer: "Fajr", adjustment: $settingsManager.fajrAdjustment)
                        adjustmentRow(prayer: "Sunrise", adjustment: $settingsManager.sunriseAdjustment)
                        adjustmentRow(prayer: "Dhuhr", adjustment: $settingsManager.dhuhrAdjustment)
                        adjustmentRow(prayer: "Asr", adjustment: $settingsManager.asrAdjustment)
                        adjustmentRow(prayer: "Maghrib", adjustment: $settingsManager.maghribAdjustment)
                        adjustmentRow(prayer: "Isha", adjustment: $settingsManager.ishaAdjustment)
                    }
                }

                // Hijri date adjustment
                SettingsSection(title: L("Hijri Date Adjustment (days)")) {
                    VStack(spacing: 8) {
                        HStack {
                            Text(L("Days")).font(.system(size: 13)).foregroundColor(.white)
                            Spacer()
                            Stepper(value: $settingsManager.hijriAdjustment, in: -30...30) {
                                Text("\(settingsManager.hijriAdjustment) days")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(settingsManager.hijriAdjustment == 0 ? .white : Color(hex: "E94560"))
                            }
                        }
                        Text(L("Positive = later date, Negative = earlier date"))
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.4))
                    }
                }

                // Reset button
                Button(action: resetAdjustments) {
                    HStack {
                        Image(systemName: "arrow.counterclockwise")
                        Text(L("Reset All Adjustments"))
                    }
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.7))
                }
                .padding(.top, 8)

                // Info
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Use these adjustments if prayer times seem inaccurate for your location.")).font(.system(size: 10)).foregroundColor(.white.opacity(0.4))
                    Text(L("Changes apply immediately.")).font(.system(size: 10)).foregroundColor(.white.opacity(0.4))
                }
            }.padding()
        }
    }

    private func adjustmentRow(prayer: String, adjustment: Binding<Int>) -> some View {
        HStack {
            Text(prayerDisplayName(prayer)).font(.system(size: 13)).foregroundColor(.white)
            Spacer()
            Stepper(value: adjustment, in: -60...60) {
                Text("\(adjustment.wrappedValue) min")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(adjustment.wrappedValue == 0 ? .white : Color(hex: "E94560"))
                    .frame(width: 70, alignment: .trailing)
            }
        }
    }

    private func resetAdjustments() {
        settingsManager.fajrAdjustment = 0
        settingsManager.sunriseAdjustment = 0
        settingsManager.dhuhrAdjustment = 0
        settingsManager.asrAdjustment = 0
        settingsManager.maghribAdjustment = 0
        settingsManager.ishaAdjustment = 0
        settingsManager.hijriAdjustment = 0
    }
}

// MARK: - Athan Settings
struct AthanSettingsView: View {
    @ObservedObject var settings = SettingsManager.shared
    @ObservedObject var player = AthanPlayer.shared

    private let prayers: [(String, ReferenceWritableKeyPath<SettingsManager, AthanReciter>, ReferenceWritableKeyPath<SettingsManager, Bool>)] = [
        ("Fajr",    \.fajrReciter,    \.fajrAthanEnabled),
        ("Dhuhr",   \.dhuhrReciter,   \.dhuhrAthanEnabled),
        ("Asr",     \.asrReciter,     \.asrAthanEnabled),
        ("Maghrib", \.maghribReciter, \.maghribAthanEnabled),
        ("Isha",    \.ishaReciter,    \.ishaAthanEnabled)
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {

                // Prefetch status
                let total = AthanReciter.allCases.count
                if player.prefetchProgress < total {
                    HStack(spacing: 8) {
                        ProgressView(value: Double(player.prefetchProgress), total: Double(total))
                            .tint(Color(hex: "E94560"))
                        Text("\(L("Caching "))\(player.prefetchProgress)/\(total)")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.5))
                    }
                    .padding(.horizontal, 4)
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(Color(hex: "E94560"))
                            .font(.system(size: 11))
                        Text("All athan audio cached — instant playback ready")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.5))
                    }
                }

                // Silent mode
                SettingsSection(title: L("Audio")) {
                    Toggle(L("Silent mode"), isOn: $settings.silentMode).tint(Color(hex: "E94560"))
                }

                // Per-prayer reciter + Play button
                SettingsSection(title: L("Athan Reciter")) {
                    VStack(spacing: 10) {
                        ForEach(prayers, id: \.0) { prayerName, reciterKey, enabledKey in
                            reciterRow(prayerName: prayerName, keyPath: reciterKey, enabledKeyPath: enabledKey)
                        }
                    }
                }

                // Reminders
                SettingsSection(title: L("Reminders")) {
                    VStack(spacing: 10) {
                        HStack(spacing: 8) {
                            Toggle("", isOn: $settings.reminderBeforeFajr).tint(Color(hex: "E94560")).labelsHidden()
                            Text(L("Reminder")).foregroundColor(.white).font(.system(size: 13))
                            Stepper(value: $settings.reminderFajrMinutes, in: 5...60, step: 5) {
                                Text("\(settings.reminderFajrMinutes)").font(.system(size: 13, weight: .medium)).foregroundColor(Color(hex: "E94560")).frame(width: 28, alignment: .trailing)
                            }
                            Text("minutes before \(prayerDisplayName("Fajr"))").foregroundColor(.white).font(.system(size: 13))
                            Spacer()
                        }
                        HStack(spacing: 8) {
                            Toggle("", isOn: $settings.reminderBeforeSunrise).tint(Color(hex: "E94560")).labelsHidden()
                            Text(L("Reminder")).foregroundColor(.white).font(.system(size: 13))
                            Stepper(value: $settings.reminderSunriseMinutes, in: 5...60, step: 5) {
                                Text("\(settings.reminderSunriseMinutes)").font(.system(size: 13, weight: .medium)).foregroundColor(Color(hex: "E94560")).frame(width: 28, alignment: .trailing)
                            }
                            Text("minutes before \(prayerDisplayName("Sunrise"))").foregroundColor(.white).font(.system(size: 13))
                            Spacer()
                        }
                    }
                }

                // Volume
                SettingsSection(title: L("Volume")) {
                    HStack {
                        Image(systemName: "speaker.fill").foregroundColor(.white.opacity(0.5)).font(.system(size: 11))
                        Slider(value: $settings.athanVolume, in: 0...1)
                            .tint(Color(hex: "E94560"))
                        Image(systemName: "speaker.wave.3.fill").foregroundColor(.white.opacity(0.5)).font(.system(size: 11))
                    }
                }

                // System notifications link
                SettingsSection(title: L("Notifications")) {
                    Button {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!)
                    } label: {
                        HStack {
                            Image(systemName: "bell.badge")
                            Text(L("Configure in System Settings"))
                            Spacer()
                            Image(systemName: "arrow.up.right.square").font(.system(size: 11))
                        }
                        .font(.system(size: 13))
                        .foregroundColor(Color(hex: "E94560"))
                    }
                    .buttonStyle(.plain)
                }

                Text(L("Athan audio streams from cdn.aladhan.com — no internet, no sound."))
                    .font(.system(size: 10)).foregroundColor(.white.opacity(0.4))
            }.padding()
        }
    }

    private func reciterRow(prayerName: String,
                            keyPath: ReferenceWritableKeyPath<SettingsManager, AthanReciter>,
                            enabledKeyPath: ReferenceWritableKeyPath<SettingsManager, Bool>) -> some View {
        let reciter = settings[keyPath: keyPath]
        let isEnabled = settings[keyPath: enabledKeyPath]
        let isThisRowActive = player.currentlyPlayingReciter == reciter
        let isThisRowLoading = isThisRowActive && player.isLoading

        return VStack(spacing: 8) {
            HStack(spacing: 10) {

                // Pill toggle
                Button {
                    settings[keyPath: enabledKeyPath].toggle()
                } label: {
                    HStack(spacing: 5) {
                        // Dot indicator
                        Circle()
                            .fill(isEnabled ? Color(hex: "E94560") : Color.white.opacity(0.2))
                            .frame(width: 7, height: 7)
                        Text(prayerDisplayName(prayerName))
                            .font(.system(size: 12, weight: isEnabled ? .semibold : .regular))
                            .foregroundColor(isEnabled ? .white : .white.opacity(0.4))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(isEnabled ? Color(hex: "E94560").opacity(0.18) : Color.white.opacity(0.04))
                            .overlay(
                                Capsule()
                                    .strokeBorder(
                                        isEnabled ? Color(hex: "E94560").opacity(0.6) : Color.white.opacity(0.1),
                                        lineWidth: 1
                                    )
                            )
                    )
                }
                .buttonStyle(.plain)
                .animation(.easeInOut(duration: 0.15), value: isEnabled)

                // Reciter picker — dimmed when disabled
                Picker("", selection: Binding(
                    get: { settings[keyPath: keyPath] },
                    set: { settings[keyPath: keyPath] = $0 }
                )) {
                    ForEach(AthanReciter.allCases, id: \.self) { r in
                        Text(r.displayName).tag(r)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity)
                .opacity(isEnabled ? 1 : 0.35)
                .disabled(!isEnabled)

                // Play / Stop button
                Button {
                    if isThisRowActive {
                        player.stop()
                    } else {
                        AthanPlayer.shared.play(reciter: reciter, isFajr: prayerName == "Fajr")
                    }
                } label: {
                    Group {
                        if isThisRowLoading {
                            ProgressView()
                                .scaleEffect(0.7)
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        } else {
                            Text(isThisRowActive ? "Stop" : "Play")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.white)
                        }
                    }
                    .frame(width: 44, height: 24)
                    .background(RoundedRectangle(cornerRadius: 6)
                        .fill(isEnabled ? Color(hex: "E94560") : Color.white.opacity(0.1)))
                }
                .buttonStyle(.plain)
                .disabled(settings.silentMode || !isEnabled)
                .opacity(isEnabled ? 1 : 0.4)
            }
        }
    }
}

// MARK: - About View
struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings = SettingsManager.shared

    // ── Update these two lines ──────────────────────────────────────────
    private let portfolioURL = "https://any.ma/portfolio/mehdigriche/"
    // ────────────────────────────────────────────────────────────────────

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 10) {
                if let logo = NSImage(named: "AppLogo") {
                    Image(nsImage: logo)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 80, height: 80)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .shadow(color: Color(hex: "E94560").opacity(0.3), radius: 12)
                        .padding(.top, 32)
                } else {
                    Image(systemName: "moon.stars.fill")
                        .font(.system(size: 48))
                        .foregroundColor(Color(hex: "E94560"))
                        .padding(.top, 32)
                }

                Text("Salaati")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(.white)

                Text(L("Prayer Times for macOS"))
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.5))

                Text(L("Version 1.1.0"))
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.3))
                    .padding(.bottom, 8)
            }

            Divider().background(Color.white.opacity(0.08))

            // Developer card
            VStack(spacing: 12) {
                Text(L("Made with ♥ by"))
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.4))

                Button {
                    NSWorkspace.shared.open(URL(string: portfolioURL)!)
                } label: {
                    HStack(spacing: 10) {
                        ZStack {
                            Circle()
                                .fill(Color(hex: "E94560").opacity(0.2))
                                .frame(width: 44, height: 44)
                            Text("M")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundColor(Color(hex: "E94560"))
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Mehdi Griche")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white)
                            Text(L("Mobile Developer"))
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.5))
                        }
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.3))
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.05)))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)

            Divider().background(Color.white.opacity(0.08))

            // Description
            VStack(spacing: 8) {
                Text(L("Salaati provides accurate prayer times, athan notifications, and a beautiful menu bar experience — built for Muslim users on macOS."))
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.45))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 16)

            // Tip Jar
            TipJarView()
                .padding(.horizontal, 24)

            // Prayer times API credit
            Text(L("Prayer times powered by AlAdhan API"))
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.25))
                .padding(.top, 12)
                .padding(.bottom, 6)

            // Done
            Button(L("Done")) { dismiss() }
                .foregroundColor(Color(hex: "E94560"))
                .font(.system(size: 13))
                .padding(.bottom, 20)
        }
        .frame(width: 340)
        .background(
            ZStack {
                Color(hex: "1A1A2E")
                AppBackground()
            }
        )
        .preferredColorScheme(.dark)
    }
}

// MARK: - Tip Jar View
struct TipJarView: View {
    @StateObject private var tipJar = TipJarManager.shared
    @State private var showThankYou = false

    var body: some View {
        VStack(spacing: 10) {
            if tipJar.isLoading {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: Color(hex: "E94560")))
                    .scaleEffect(0.8)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)

            } else if showThankYou {
                HStack(spacing: 8) {
                    Image(systemName: "heart.fill")
                        .foregroundColor(Color(hex: "E94560"))
                    Text("Jazakum Allahu Khayran 🤍")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.07)))

            } else if tipJar.products.isEmpty {
                // Products not loaded yet — tap to load
                Button {
                    tipJar.fetchProducts()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "cup.and.saucer.fill")
                        Text("Support Development")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color(hex: "E94560")))
                }
                .buttonStyle(.plain)

            } else {
                // Show tip options
                Text("Support Development")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.5))

                HStack(spacing: 8) {
                    ForEach(tipJar.products, id: \.productIdentifier) { product in
                        Button {
                            tipJar.purchase(product)
                        } label: {
                            VStack(spacing: 3) {
                                Text(tipEmoji(product.productIdentifier))
                                    .font(.system(size: 18))
                                Text(product.localizedPrice)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.white)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color(hex: "E94560").opacity(0.15))
                                    .overlay(RoundedRectangle(cornerRadius: 10)
                                        .strokeBorder(Color(hex: "E94560").opacity(0.4), lineWidth: 1))
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(tipJar.isPurchasing)
                    }
                }

                if tipJar.isPurchasing {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: Color(hex: "E94560")))
                        .scaleEffect(0.7)
                }
            }
        }
        .onAppear { tipJar.fetchProducts() }
        .onChange(of: tipJar.purchaseState) { state in
            if case .success = state {
                withAnimation { showThankYou = true }
            }
        }
    }

    private func tipEmoji(_ productID: String) -> String {
        if productID.contains("small")  { return "☕️" }
        if productID.contains("medium") { return "🧆" }
        if productID.contains("large")  { return "🎁" }
        return "🤍"
    }
}

extension SKProduct {
    var localizedPrice: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = priceLocale
        return formatter.string(from: price) ?? "\(price)"
    }
}

struct SettingsSection<Content: View>: View {
    let title: String
    let content: Content
    init(title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundColor(.white.opacity(0.6))
            content.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.05)))
        }
    }
}

// MARK: - Notification Manager
class NotificationManager {
    static let shared = NotificationManager()
    private init() {}

    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func schedulePrayerNotifications(prayers: [Prayer], locationName: String) {
        let center = UNUserNotificationCenter.current()
        let settings = SettingsManager.shared
        let today = Calendar.current.startOfDay(for: Date())
        let todayKey = "notif-scheduled-\(Int(today.timeIntervalSince1970))"

        // Only fully reschedule once per calendar day — avoids re-delivering
        // notifications that already fired when the user refreshes mid-day.
        // Individual identifiers still prevent stacking within a session.
        let alreadyScheduledToday = UserDefaults.standard.bool(forKey: todayKey)

        // Always remove stale pending from previous days
        if !alreadyScheduledToday {
            center.removeAllPendingNotificationRequests()
            center.removeAllDeliveredNotifications()
            // Mark this day as scheduled
            UserDefaults.standard.set(true, forKey: todayKey)
            // Clean up keys older than 2 days
            let yesterday = Calendar.current.date(byAdding: .day, value: -2, to: today)!
            UserDefaults.standard.removeObject(forKey: "notif-scheduled-\(Int(yesterday.timeIntervalSince1970))")
        }

        for prayer in prayers where prayer.isEnabled && prayer.name != "Sunrise" {
            guard settings.athanEnabled(for: prayer.name) else { continue }
            let content = UNMutableNotificationContent()
            content.title = "🕌 \(prayer.name) · \(prayer.arabicName)"
            content.body = locationName
            content.sound = .none
            schedule(content: content, at: prayer.time, identifier: "prayer-\(prayer.name)")
        }

        // Reminder before Fajr
        if settings.reminderBeforeFajr, let fajr = prayers.first(where: { $0.name == "Fajr" }) {
            let content = UNMutableNotificationContent()
            content.title = "Fajr in \(settings.reminderFajrMinutes) minutes"
            content.body = "Prepare for Fajr prayer · \(locationName)"
            content.sound = .default
            let reminderTime = fajr.time.addingTimeInterval(Double(-settings.reminderFajrMinutes * 60))
            schedule(content: content, at: reminderTime, identifier: "reminder-fajr")
        }

        // Reminder before Sunrise
        if settings.reminderBeforeSunrise, let sunrise = prayers.first(where: { $0.name == "Sunrise" }) {
            let content = UNMutableNotificationContent()
            content.title = "Sunrise in \(settings.reminderSunriseMinutes) minutes"
            content.body = "Fajr time ends at sunrise · \(locationName)"
            content.sound = .default
            let reminderTime = sunrise.time.addingTimeInterval(Double(-settings.reminderSunriseMinutes * 60))
            schedule(content: content, at: reminderTime, identifier: "reminder-sunrise")
        }
    }

    private func schedule(content: UNMutableNotificationContent, at date: Date, identifier: String) {
        // Only schedule if the date is in the future (within today)
        guard date > Date() else { return }

        // Use full year+month+day+hour+minute so each notification fires exactly once today
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)

        // Replace any existing request with same identifier (no stacking)
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.add(request, withCompletionHandler: nil)
    }
}

// MARK: - Athan Reciter
// MARK: - Athan Reciter
// Audio served directly from cdn.aladhan.com — no bundled files needed
enum AthanReciter: String, CaseIterable, Codable {
    case afasyDubai   = "Al-Afasy (Dubai TV)"
    case afasyClassic = "Al-Afasy (Classic)"
    case afasyVariant = "Al-Afasy (Variant)"
    case nafees       = "Ahmad al-Nafees"
    case ozcan        = "Mustafa Özcan (Turkey)"
    case zahrani      = "Mansour Al-Zahrani"

    var displayName: String { rawValue }

    var cdnURL: URL {
        switch self {
        case .afasyDubai:   return URL(string: "https://cdn.aladhan.com/audio/adhans/a4.mp3")!
        case .afasyClassic: return URL(string: "https://cdn.aladhan.com/audio/adhans/a7.mp3")!
        case .afasyVariant: return URL(string: "https://cdn.aladhan.com/audio/adhans/a9.mp3")!
        case .nafees:       return URL(string: "https://cdn.aladhan.com/audio/adhans/a1.mp3")!
        case .ozcan:        return URL(string: "https://cdn.aladhan.com/audio/adhans/a2.mp3")!
        case .zahrani:      return URL(string: "https://cdn.aladhan.com/audio/adhans/a11-mansour-al-zahrani.mp3")!
        }
    }
}

// MARK: - Athan Player
@MainActor
class AthanPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = AthanPlayer()
    private var athanPlayer: AVAudioPlayer?
    private var downloadTask: URLSessionDataTask?

    /// In-memory cache: reciter rawValue → MP3 Data
    private var cache: [String: Data] = [:]

    /// Which reciter is currently active (nil when stopped)
    @Published var currentlyPlayingReciter: AthanReciter? = nil

    /// Which prayer name triggered this athan (e.g. "Asr"), nil when stopped
    @Published var currentlyPlayingPrayerName: String? = nil

    /// How many reciters have finished downloading (for progress UI)
    @Published var prefetchProgress: Int = 0
    @Published var isPlaying = false
    @Published var isLoading = false

    // Persistent cache directory inside Application Support
    private let cacheDir: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Salaati/AthanCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private override init() { super.init() }

    // MARK: Prefetch — called once at app launch
    func prefetchAll() {
        Task.detached(priority: .background) {
            await withTaskGroup(of: Void.self) { group in
                for reciter in AthanReciter.allCases {
                    group.addTask { await self.prefetch(reciter: reciter) }
                }
            }
        }
    }

    private func prefetch(reciter: AthanReciter) async {
        let key = reciter.rawValue
        let fileURL = cacheDir.appendingPathComponent("\(key).mp3")

        // Already on disk — load into memory and we're done
        if FileManager.default.fileExists(atPath: fileURL.path),
           let data = try? Data(contentsOf: fileURL) {
            await MainActor.run {
                self.cache[key] = data
                self.prefetchProgress += 1
            }
            return
        }

        // Download and persist
        do {
            let (data, response) = try await URLSession.shared.data(from: reciter.cdnURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }
            try data.write(to: fileURL, options: .atomic)
            await MainActor.run {
                self.cache[key] = data
                self.prefetchProgress += 1
            }
        } catch {
            print("AthanPlayer: prefetch failed for \(key) — \(error.localizedDescription)")
        }
    }

    // MARK: Playback
    func play(reciter: AthanReciter, isFajr: Bool = false, prayerName: String? = nil) {
        stop()
        currentlyPlayingReciter = reciter
        currentlyPlayingPrayerName = prayerName
        let volume = Float(SettingsManager.shared.athanVolume)
        let key = reciter.rawValue

        // Cache hit → instant playback
        if let data = cache[key] {
            startPlayback(data: data, volume: volume)
            return
        }

        // Disk hit (race: prefetch wrote but hasn't updated cache yet)
        let fileURL = cacheDir.appendingPathComponent("\(key).mp3")
        if let data = try? Data(contentsOf: fileURL) {
            cache[key] = data
            startPlayback(data: data, volume: volume)
            return
        }

        // Last resort: download on-demand (shouldn't happen after prefetch)
        isLoading = true
        downloadTask = URLSession.shared.dataTask(with: reciter.cdnURL) { [weak self] data, _, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isLoading = false
                guard let data, error == nil else {
                    let msg = error?.localizedDescription ?? "unknown"
                    print("AthanPlayer: on-demand download failed — \(msg)")
                    return
                }
                try? data.write(to: fileURL, options: .atomic)
                self.cache[key] = data
                self.startPlayback(data: data, volume: volume)
            }
        }
        downloadTask?.resume()
    }

    private func startPlayback(data: Data, volume: Float) {
        do {
            athanPlayer = try AVAudioPlayer(data: data)
            athanPlayer?.volume = volume
            athanPlayer?.delegate = self
            athanPlayer?.prepareToPlay()
            athanPlayer?.play()
            isPlaying = true
        } catch {
            print("AthanPlayer: playback error — \(error)")
        }
    }

    func stop() {
        downloadTask?.cancel()
        downloadTask = nil
        athanPlayer?.stop()
        athanPlayer = nil
        isPlaying = false
        isLoading = false
        currentlyPlayingReciter = nil
        currentlyPlayingPrayerName = nil
    }

    func setVolume(_ volume: Double) {
        athanPlayer?.volume = Float(volume)
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isPlaying = false
            self.currentlyPlayingReciter = nil
            self.currentlyPlayingPrayerName = nil
        }
    }
}

// MARK: - Tip Jar Manager
@MainActor
class TipJarManager: NSObject, ObservableObject, SKProductsRequestDelegate, SKPaymentTransactionObserver {
    static let shared = TipJarManager()

    static let productIDs: Set<String> = [
        "com.mehdigriche.salaati.tip.small",
        "com.mehdigriche.salaati.tip.medium",
        "com.mehdigriche.salaati.tip.large"
    ]

    @Published var products: [SKProduct] = []
    @Published var isLoading = false
    @Published var isPurchasing = false
    @Published var purchaseState: PurchaseState = .idle

    enum PurchaseState: Equatable {
        case idle, success, restored
        case failed(String)
    }

    private override init() {
        super.init()
        SKPaymentQueue.default().add(self)
    }

    func fetchProducts() {
        guard products.isEmpty else { return }
        isLoading = true
        let request = SKProductsRequest(productIdentifiers: Self.productIDs)
        request.delegate = self
        request.start()
    }

    nonisolated func productsRequest(_ request: SKProductsRequest, didReceive response: SKProductsResponse) {
        Task { @MainActor in
            self.products = response.products.sorted {
                ($0.price as Decimal) < ($1.price as Decimal)
            }
            self.isLoading = false
        }
    }

    nonisolated func request(_ request: SKRequest, didFailWithError error: Error) {
        Task { @MainActor in
            self.isLoading = false
        }
    }

    func purchase(_ product: SKProduct) {
        guard SKPaymentQueue.canMakePayments() else { return }
        isPurchasing = true
        SKPaymentQueue.default().add(SKPayment(product: product))
    }

    nonisolated func paymentQueue(_ queue: SKPaymentQueue, updatedTransactions transactions: [SKPaymentTransaction]) {
        for transaction in transactions {
            Task { @MainActor in
                switch transaction.transactionState {
                case .purchased:
                    SKPaymentQueue.default().finishTransaction(transaction)
                    self.isPurchasing = false
                    self.purchaseState = .success
                case .restored:
                    SKPaymentQueue.default().finishTransaction(transaction)
                    self.isPurchasing = false
                    self.purchaseState = .restored
                case .failed:
                    SKPaymentQueue.default().finishTransaction(transaction)
                    self.isPurchasing = false
                    if (transaction.error as? SKError)?.code != .paymentCancelled {
                        self.purchaseState = .failed(transaction.error?.localizedDescription ?? "Purchase failed")
                    }
                default: break
                }
            }
        }
    }
}

// MARK: - Color Extension
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default: (a, r, g, b) = (1, 1, 1, 0)
        }
        self.init(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, opacity: Double(a) / 255)
    }
}
