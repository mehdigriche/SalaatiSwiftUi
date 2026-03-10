import SwiftUI
import AppKit
import UserNotifications
import ServiceManagement

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
        popover.contentViewController = NSHostingController(rootView: MenuBarPopoverView(manager: prayerManager, appDelegate: self))
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshMenuBar()
                self?.prayerManager.updateCurrentPrayer()
            }
        }
    }

    func refreshMenuBar() {
        guard let button = statusItem.button else { return }
        let settings = SettingsManager.shared

        // Always show icon
        if settings.showIcon {
            button.image = NSImage(systemSymbolName: "moon.stars.fill", accessibilityDescription: "Salaati")
        } else {
            button.image = nil
        }

        // Build text
        var text = ""

        if settings.showNextPrayer {
            if let nextPrayer = prayerManager.getNextPrayer() {
                // Name
                if settings.prayerNameDisplay == .full {
                    text += settings.arabicMode ? nextPrayer.arabicName : nextPrayer.name
                } else if settings.prayerNameDisplay == .abbreviation {
                    text += String((settings.arabicMode ? nextPrayer.arabicName : nextPrayer.name).prefix(3))
                }

                // Time
                if settings.prayerTimeDisplay == .countdown {
                    if !text.isEmpty { text += " " }
                    text += prayerManager.timeRemaining()
                } else if settings.prayerTimeDisplay == .time {
                    if !text.isEmpty { text += " " }
                    text += formatTime(nextPrayer.time)
                }
            }
        }

        button.title = text

        // Icon position
        if settings.showIcon && !text.isEmpty {
            button.imagePosition = .imageLeading
        } else if settings.showIcon {
            button.imagePosition = .imageOnly
        }
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
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

    // Helper to refresh prayer times (for adjustments - just updates display without API call)
    private func refreshPrayerTimesIfNeeded() {
        print("Applying adjustments to prayer times...")
        if let manager = SettingsManager.prayerManager {
            Task { @MainActor in
                await manager.fetchPrayerTimes()
            }
        } else {
            print("ERROR: No prayer manager found!")
        }
    }

    // Reference to prayer manager for direct refresh
    static var prayerManager: PrayerTimesManager?

    private init() {
        showNextPrayer = UserDefaults.standard.object(forKey: "showNextPrayer") as? Bool ?? true
        prayerNameDisplay = PrayerNameDisplay(rawValue: UserDefaults.standard.integer(forKey: "prayerNameDisplay")) ?? .full
        prayerTimeDisplay = PrayerTimeDisplay(rawValue: UserDefaults.standard.integer(forKey: "prayerTimeDisplay")) ?? .countdown
        showIcon = UserDefaults.standard.object(forKey: "showIcon") as? Bool ?? true
        arabicMode = UserDefaults.standard.object(forKey: "arabicMode") as? Bool ?? true
        startAtLogin = UserDefaults.standard.object(forKey: "startAtLogin") as? Bool ?? false
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

    init() {
        // Store reference for SettingsManager
        SettingsManager.prayerManager = self

        loadSavedLocation()
        Task { await fetchPrayerTimes() }

        // Listen for refresh requests
        NotificationCenter.default.addObserver(forName: .refreshPrayerTimes, object: nil, queue: .main) { [weak self] _ in
            Task { await self?.fetchPrayerTimes() }
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

        let method = SettingsManager.shared.fajrIshaMethod

        // Use coordinates API
        let urlString = "https://api.aladhan.com/v1/timings/\(dateString)?latitude=\(latitude)&longitude=\(longitude)&method=\(method)"

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

            let settings = SettingsManager.shared

            // Apply hijri adjustment
            let hijriDay = (Int(response.data.date.hijri.day) ?? 0) + settings.hijriAdjustment
            hijriDate = "\(hijriDay) \(response.data.date.hijri.month.ar) \(response.data.date.hijri.year)"

            prayers = [
                Prayer(name: "Fajr", arabicName: "فجر", time: parseTime(timings.fajr, calendar: calendar, today: today, adjustment: settings.fajrAdjustment), isEnabled: true),
                Prayer(name: "Sunrise", arabicName: "شروق", time: parseTime(timings.sunrise, calendar: calendar, today: today, adjustment: settings.sunriseAdjustment), isEnabled: false),
                Prayer(name: "Dhuhr", arabicName: "ظهر", time: parseTime(timings.dhuhr, calendar: calendar, today: today, adjustment: settings.dhuhrAdjustment), isEnabled: true),
                Prayer(name: "Asr", arabicName: "عصر", time: parseTime(timings.asr, calendar: calendar, today: today, adjustment: settings.asrAdjustment), isEnabled: true),
                Prayer(name: "Maghrib", arabicName: "مغرب", time: parseTime(timings.maghrib, calendar: calendar, today: today, adjustment: settings.maghribAdjustment), isEnabled: true),
                Prayer(name: "Isha", arabicName: "عشاء", time: parseTime(timings.isha, calendar: calendar, today: today, adjustment: settings.ishaAdjustment), isEnabled: true)
            ]

            updateCurrentPrayer()
            save()
            NotificationManager.shared.schedulePrayerNotifications(prayers: prayers, locationName: locationName)
            
            // Force UI refresh
            self.objectWillChange.send()
            NotificationCenter.default.post(name: .refreshMenuBar, object: nil)
            print("Prayer times updated successfully")
        } catch {
            print("Error: \(error)")
            prayers = getDefaultPrayers()
        }

        isLoading = false
    }

    private func parseTime(_ timeString: String, calendar: Calendar, today: Date, adjustment: Int = 0) -> Date {
        let components = timeString.split(separator: ":")
        guard components.count >= 2,
              let hour = Int(components[0]),
              let minute = Int(components[1]) else { return today }

        var date = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: today) ?? today

        // Apply adjustment in minutes
        if adjustment != 0 {
            date = calendar.date(byAdding: .minute, value: adjustment, to: date) ?? date
        }

        return date
    }

    private func getDefaultPrayers() -> [Prayer] {
        let calendar = Calendar.current
        let today = Date()
        return [
            Prayer(name: "Fajr", arabicName: "فجر", time: calendar.date(bySettingHour: 5, minute: 26, second: 0, of: today)!, isEnabled: true),
            Prayer(name: "Sunrise", arabicName: "شروق", time: calendar.date(bySettingHour: 6, minute: 49, second: 0, of: today)!, isEnabled: false),
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
            let components = Calendar.current.dateComponents([.hour, .minute, .second], from: now, to: nextPrayer.time)
            if let hours = components.hour, let minutes = components.minute, let seconds = components.second {
                return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
            }
        }
        return "00:00:00"
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

// MARK: - API Models
struct AlAdhanResponse: Codable { let data: AlAdhanData }
struct AlAdhanData: Codable { let timings: Timings?; let date: DateInfo }
struct DateInfo: Codable { let hijri: HijriDate }
struct HijriDate: Codable { let day: String; let month: HijriMonth; let year: String }
struct HijriMonth: Codable { let ar: String }
struct Timings: Codable {
    let fajr: String, sunrise: String, dhuhr: String, asr: String, maghrib: String, isha: String
}

// MARK: - Menu Bar Popover View
struct MenuBarPopoverView: View {
    @ObservedObject var manager: PrayerTimesManager
    weak var appDelegate: AppDelegate?
    @State private var showingSettings = false

    var body: some View {
        ZStack {
            LinearGradient(gradient: Gradient(colors: [Color(hex: "1A1A2E"), Color(hex: "16213E")]), startPoint: .top, endPoint: .bottom).ignoresSafeArea()

            VStack(spacing: 0) {
                headerView

                // Loading indicator
                if manager.isLoading {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.8)
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        Text("Loading...").font(.system(size: 12)).foregroundColor(.white.opacity(0.7))
                    }.padding(.vertical, 20)
                } else if !manager.prayers.isEmpty {
                    nextPrayerCard.padding(.horizontal, 16).padding(.vertical, 12)
                    prayerTimesList
                } else {
                    Text("No prayer times available").foregroundColor(.white.opacity(0.5)).padding(.vertical, 40)
                }

                footerView
            }
        }.frame(width: 380, height: 550)
        .onReceive(NotificationCenter.default.publisher(for: .refreshMenuBar)) { _ in
            appDelegate?.refreshMenuBar()
        }
        .onReceive(NotificationCenter.default.publisher(for: .refreshPrayerTimes)) { _ in
            // Force view refresh when prayer times change
            appDelegate?.refreshMenuBar()
        }
    }

    private var headerView: some View {
        VStack(spacing: 4) {
            HStack { Image(systemName: "location.fill").font(.caption); Text(manager.locationName).font(.system(size: 13, weight: .medium)) }.foregroundColor(.white.opacity(0.7))
            if !manager.hijriDate.isEmpty { Text(manager.hijriDate).font(.system(size: 18, weight: .bold)).foregroundColor(.white) }
            Text(formattedDate()).font(.system(size: 11)).foregroundColor(.white.opacity(0.5))
        }.padding(.top, 16).padding(.bottom, 8)
    }

    private var nextPrayerCard: some View {
        let nextPrayer = manager.getNextPrayer()
        guard let prayer = nextPrayer else {
            return AnyView(VStack { Text("All prayers completed").foregroundColor(.white.opacity(0.7)) }.frame(maxWidth: .infinity).padding(.vertical, 16).background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.1))))
        }

        let displayName = SettingsManager.shared.arabicMode ? prayer.arabicName : prayer.name

        return AnyView(VStack(spacing: 4) {
            Text("Next Prayer").font(.system(size: 11)).foregroundColor(.white.opacity(0.6))
            Text(displayName).font(.system(size: 24, weight: .bold)).foregroundColor(Color(hex: "E94560"))
            Text(manager.timeRemaining()).font(.system(size: 22, weight: .bold, design: .monospaced)).foregroundColor(.white)
            Text(timeFormatter.string(from: prayer.time)).font(.system(size: 12)).foregroundColor(.white.opacity(0.5))
        }.frame(maxWidth: .infinity).padding(.vertical, 16).background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.1)).overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(hex: "E94560").opacity(0.3), lineWidth: 1))))
    }

    private var prayerTimesList: some View {
        ScrollView {
            VStack(spacing: 6) {
                ForEach(manager.prayers) { prayer in
                    let displayName = SettingsManager.shared.arabicMode ? prayer.arabicName : prayer.name
                    HStack {
                        Text(displayName).font(.system(size: 14, weight: .medium)).foregroundColor(prayer.isEnabled ? .white : .white.opacity(0.4))
                        Spacer()
                        Text(timeFormatter.string(from: prayer.time)).font(.system(size: 14, weight: .medium, design: .monospaced)).foregroundColor(prayer.isEnabled ? .white : .white.opacity(0.4))
                    }.padding(.horizontal, 16).padding(.vertical, 10).background(RoundedRectangle(cornerRadius: 8).fill(isCurrentPrayer(prayer) ? Color(hex: "E94560").opacity(0.15) : Color.white.opacity(0.03)))
                }
            }.padding(.horizontal, 12)
        }
    }

    private var footerView: some View {
        HStack(spacing: 20) {
            Button(action: { showingSettings = true }) { HStack(spacing: 4) { Image(systemName: "gearshape"); Text("Settings") }.font(.system(size: 12)).foregroundColor(.white.opacity(0.7)) }.buttonStyle(.plain)
            Button(action: { Task { await manager.fetchPrayerTimes() } }) { HStack(spacing: 4) { Image(systemName: "arrow.clockwise"); Text("Refresh") }.font(.system(size: 12)).foregroundColor(.white.opacity(0.7)) }.buttonStyle(.plain)
            Button(action: { NSApplication.shared.terminate(nil) }) { HStack(spacing: 4) { Image(systemName: "power"); Text("Quit") }.font(.system(size: 12)).foregroundColor(.white.opacity(0.7)) }.buttonStyle(.plain)
        }.padding(.vertical, 12).padding(.horizontal, 16).background(Color.black.opacity(0.2))
        .sheet(isPresented: $showingSettings) { SettingsView(manager: manager, appDelegate: appDelegate) }
    }

    private func isCurrentPrayer(_ prayer: Prayer) -> Bool {
        guard let index = manager.prayers.firstIndex(where: { $0.id == prayer.id }) else { return false }
        return index == manager.currentPrayerIndex
    }

    private func formattedDate() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMMM d, yyyy"
        return formatter.string(from: Date())
    }

    private var timeFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "hh:mm a"
        return formatter
    }
}

// MARK: - Settings View
struct SettingsView: View {
    @ObservedObject var manager: PrayerTimesManager
    weak var appDelegate: AppDelegate?
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab = 0

    var body: some View {
        ZStack {
            Color(hex: "1A1A2E").ignoresSafeArea()
            VStack(spacing: 0) {
                Picker("", selection: $selectedTab) {
                    Text("General").tag(0)
                    Text("Location").tag(1)
                    Text("Prayer").tag(2)
                    Text("Adjust").tag(3)
                }.pickerStyle(.segmented).padding()

                TabView(selection: $selectedTab) {
                    GeneralSettingsView(appDelegate: appDelegate).tag(0)
                    LocationSettingsView(manager: manager, appDelegate: appDelegate).tag(1)
                    PrayerTimesSettingsView(manager: manager, appDelegate: appDelegate).tag(2)
                    AdjustmentsSettingsView(manager: manager).tag(3)
                }.tabViewStyle(.automatic)

                HStack { Spacer(); Button("Done") { dismiss() }.foregroundColor(Color(hex: "E94560")).padding() }
            }
        }.frame(width: 380, height: 500)
        .onReceive(NotificationCenter.default.publisher(for: .refreshPrayerTimes)) { _ in
            // Force refresh when location/prayer times change
        }
    }
}

// MARK: - General Settings
struct GeneralSettingsView: View {
    weak var appDelegate: AppDelegate?
    @ObservedObject var settingsManager = SettingsManager.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                SettingsSection(title: "Menu Bar Display") {
                    Toggle("Show Next Prayer", isOn: $settingsManager.showNextPrayer).tint(Color(hex: "E94560"))
                    Toggle("Show Icon", isOn: $settingsManager.showIcon).tint(Color(hex: "E94560"))
                }

                SettingsSection(title: "Prayer Name") {
                    Picker("Display", selection: $settingsManager.prayerNameDisplay) {
                        Text("Full").tag(PrayerNameDisplay.full)
                        Text("Abbrev").tag(PrayerNameDisplay.abbreviation)
                        Text("None").tag(PrayerNameDisplay.none)
                    }.pickerStyle(.segmented)
                }

                SettingsSection(title: "Prayer Time") {
                    Picker("Display", selection: $settingsManager.prayerTimeDisplay) {
                        Text("Countdown").tag(PrayerTimeDisplay.countdown)
                        Text("Time").tag(PrayerTimeDisplay.time)
                        Text("None").tag(PrayerTimeDisplay.none)
                    }.pickerStyle(.segmented)
                }

                SettingsSection(title: "Language") {
                    Toggle("Arabic Mode", isOn: $settingsManager.arabicMode).tint(Color(hex: "E94560"))
                }

                SettingsSection(title: "Startup") {
                    Toggle("Start at Login", isOn: $settingsManager.startAtLogin).tint(Color(hex: "E94560"))
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
                SettingsSection(title: "Current Location (IP)") {
                    Button(action: useCurrentLocation) {
                        HStack {
                            if isSearching {
                                ProgressView().scaleEffect(0.8)
                            } else {
                                Image(systemName: "location.fill")
                            }
                            Text("Use My Location")
                        }
                    }.disabled(isSearching)
                }

                SettingsSection(title: "Search City") {
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
                    SettingsSection(title: "Search Results") {
                        ForEach(searchResults) { result in
                            Button(action: {
                                let fullName = result.admin.isEmpty ? "\(result.name), \(result.country)" : "\(result.name), \(result.admin), \(result.country)"
                                setLocation(city: fullName, lat: result.lat, lon: result.lon, tz: TimeZone.current.identifier)
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

                SettingsSection(title: "Popular Cities") {
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
                    return SearchResult(name: name, country: country, lat: lat, lon: lon, admin: admin)
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
                    SettingsSection(title: "Current Method") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(method.name).font(.system(size: 14, weight: .bold)).foregroundColor(.white)
                            HStack(spacing: 16) {
                                VStack(alignment: .leading) {
                                    Text("Fajr angle").font(.system(size: 11)).foregroundColor(.white.opacity(0.5))
                                    Text(method.fajr).font(.system(size: 13, weight: .medium)).foregroundColor(Color(hex: "E94560"))
                                }
                                VStack(alignment: .leading) {
                                    Text("Isha angle").font(.system(size: 11)).foregroundColor(.white.opacity(0.5))
                                    Text(method.isha).font(.system(size: 13, weight: .medium)).foregroundColor(Color(hex: "E94560"))
                                }
                            }
                            Text("Used in: \(method.usedIn)").font(.system(size: 11)).foregroundColor(.white.opacity(0.5))
                        }
                    }
                }

                SettingsSection(title: "Fajr & Isha Method") {
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

                SettingsSection(title: "Asr Method") {
                    Picker("Method", selection: $settingsManager.asrMethod) {
                        Text("Standard (Shafi'i, Maliki, Hanbali)").tag(AsrMethod.standard)
                        Text("Hanbali (later time)").tag(AsrMethod.hanbali)
                    }
                    .pickerStyle(.menu)
                }

                // Info text
                VStack(alignment: .leading, spacing: 4) {
                    Text("Methods differ in the angle of the sun below the horizon used to calculate Fajr and Isha times.").font(.system(size: 10)).foregroundColor(.white.opacity(0.4))
                    Text("Lower angle = earlier Fajr / later Isha.").font(.system(size: 10)).foregroundColor(.white.opacity(0.4))
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
                SettingsSection(title: "Prayer Time Adjustments (minutes)") {
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
                SettingsSection(title: "Hijri Date Adjustment (days)") {
                    VStack(spacing: 8) {
                        HStack {
                            Text("Days").font(.system(size: 13)).foregroundColor(.white)
                            Spacer()
                            Stepper(value: $settingsManager.hijriAdjustment, in: -30...30) {
                                Text("\(settingsManager.hijriAdjustment) days")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(settingsManager.hijriAdjustment == 0 ? .white : Color(hex: "E94560"))
                            }
                        }
                        Text("Positive = later date, Negative = earlier date")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.4))
                    }
                }

                // Reset button
                Button(action: resetAdjustments) {
                    HStack {
                        Image(systemName: "arrow.counterclockwise")
                        Text("Reset All Adjustments")
                    }
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.7))
                }
                .padding(.top, 8)

                // Info
                VStack(alignment: .leading, spacing: 4) {
                    Text("Use these adjustments if prayer times seem inaccurate for your location.").font(.system(size: 10)).foregroundColor(.white.opacity(0.4))
                    Text("Changes apply immediately.").font(.system(size: 10)).foregroundColor(.white.opacity(0.4))
                }
            }.padding()
        }
    }

    private func adjustmentRow(prayer: String, adjustment: Binding<Int>) -> some View {
        HStack {
            Text(prayer).font(.system(size: 13)).foregroundColor(.white)
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
        center.removeAllPendingNotificationRequests()

        for prayer in prayers where prayer.isEnabled {
            let content = UNMutableNotificationContent()
            content.title = "Time for \(prayer.name)"
            content.body = "\(prayer.name) - \(prayer.arabicName)"
            content.sound = .default

            let calendar = Calendar.current
            let components = calendar.dateComponents([.hour, .minute], from: prayer.time)
            var dateComponents = DateComponents()
            dateComponents.hour = components.hour
            dateComponents.minute = components.minute

            let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)
            let request = UNNotificationRequest(identifier: prayer.id.uuidString, content: content, trigger: trigger)
            center.add(request, withCompletionHandler: nil)
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
