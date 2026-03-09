import SwiftUI
import AppKit
import UserNotifications
import ServiceManagement

// MARK: - App Entry Point
@main
struct SalaatiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

// MARK: - App Delegate
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var popover: NSPopover!
    var timer: Timer?
    var prayerManager = PrayerTimesManager()
    var settingsManager = SettingsManager.shared
    
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
        updateStatusItem()
    }
    
    private func setupPopover() {
        popover = NSPopover()
        popover.contentSize = NSSize(width: 380, height: 550)
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(rootView: MenuBarPopoverView(manager: prayerManager))
    }
    
    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateStatusItem()
                self?.prayerManager.updateCurrentPrayer()
            }
        }
    }
    
    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        
        if settingsManager.showIcon {
            button.image = NSImage(systemSymbolName: "moon.stars.fill", accessibilityDescription: "Salaati")
            button.imagePosition = (settingsManager.prayerNameDisplay != .none || settingsManager.prayerTimeDisplay != .none) ? .imageLeading : .imageOnly
        } else {
            button.image = nil
        }
        
        guard settingsManager.showNextPrayer else {
            button.title = ""
            return
        }
        
        var menuText = ""
        
        if settingsManager.prayerNameDisplay != .none, let nextPrayer = prayerManager.getNextPrayer() {
            let name = settingsManager.arabicMode ? nextPrayer.arabicName : nextPrayer.name
            switch settingsManager.prayerNameDisplay {
            case .full: menuText = name
            case .abbreviation: menuText = String(name.prefix(3))
            case .none: break
            }
        }
        
        if settingsManager.prayerTimeDisplay == .countdown {
            if !menuText.isEmpty { menuText += " " }
            menuText += prayerManager.timeRemaining()
        } else if settingsManager.prayerTimeDisplay == .time, let nextPrayer = prayerManager.getNextPrayer() {
            if !menuText.isEmpty { menuText += " " }
            menuText += timeFormatter.string(from: nextPrayer.time)
        }
        
        button.title = menuText
    }
    
    private var timeFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "hh:mm"
        return formatter
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
        didSet { UserDefaults.standard.set(showNextPrayer, forKey: "showNextPrayer") }
    }
    
    @Published var prayerNameDisplay: PrayerNameDisplay {
        didSet { UserDefaults.standard.set(prayerNameDisplay.rawValue, forKey: "prayerNameDisplay") }
    }
    
    @Published var prayerTimeDisplay: PrayerTimeDisplay {
        didSet { UserDefaults.standard.set(prayerTimeDisplay.rawValue, forKey: "prayerTimeDisplay") }
    }
    
    @Published var showIcon: Bool {
        didSet { UserDefaults.standard.set(showIcon, forKey: "showIcon") }
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
    
    private init() {
        showNextPrayer = UserDefaults.standard.object(forKey: "showNextPrayer") as? Bool ?? true
        prayerNameDisplay = PrayerNameDisplay(rawValue: UserDefaults.standard.integer(forKey: "prayerNameDisplay")) ?? .full
        prayerTimeDisplay = PrayerTimeDisplay(rawValue: UserDefaults.standard.integer(forKey: "prayerTimeDisplay")) ?? .countdown
        showIcon = UserDefaults.standard.object(forKey: "showIcon") as? Bool ?? true
        arabicMode = UserDefaults.standard.object(forKey: "arabicMode") as? Bool ?? true
        startAtLogin = UserDefaults.standard.object(forKey: "startAtLogin") as? Bool ?? false
        asrMethod = AsrMethod(rawValue: UserDefaults.standard.integer(forKey: "asrMethod")) ?? .standard
        fajrIshaMethod = UserDefaults.standard.object(forKey: "fajrIshaMethod") as? Int ?? 3
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
                print("Failed to update login item: \(error)")
            }
        }
    }
}

enum PrayerNameDisplay: Int, CaseIterable {
    case full = 0
    case abbreviation = 1
    case none = 2
}

enum PrayerTimeDisplay: Int, CaseIterable {
    case countdown = 0
    case time = 1
    case none = 2
}

enum AsrMethod: Int, CaseIterable {
    case standard = 0
    case hanbali = 1
}

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
    
    static func == (lhs: Prayer, rhs: Prayer) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Prayer Times Manager
@MainActor
class PrayerTimesManager: ObservableObject {
    @Published var prayers: [Prayer] = []
    @Published var locationName: String = "Casablanca, Morocco"
    @Published var latitude: Double = 33.5731
    @Published var longitude: Double = -7.5898
    @Published var currentPrayerIndex: Int = 0
    @Published var hijriDate: String = ""
    @Published var timezone: TimeZone = TimeZone(identifier: "Africa/Casablanca")!
    
    var settingsManager = SettingsManager.shared
    
    init() {
        loadSavedLocation()
        Task { await fetchPrayerTimes() }
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
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "dd-MM-yyyy"
        let dateString = dateFormatter.string(from: Date())
        
        let method = settingsManager.fajrIshaMethod
        let urlString = "https://api.aladhan.com/v1/timings/\(dateString)?latitude=\(latitude)&longitude=\(longitude)&method=\(method)"
        
        guard let url = URL(string: urlString) else { return }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let response = try JSONDecoder().decode(AlAdhanResponse.self, from: data)
            
            guard let timings = response.data.timings else { return }
            
            let calendar = Calendar.current
            let today = Date()
            
            hijriDate = "\(response.data.date.hijri.day) \(response.data.date.hijri.month.ar) \(response.data.date.hijri.year)"
            
            prayers = [
                Prayer(name: "Fajr", arabicName: "فجر", time: parseTime(timings.fajr, calendar: calendar, today: today), isEnabled: true),
                Prayer(name: "Sunrise", arabicName: "شروق", time: parseTime(timings.sunrise, calendar: calendar, today: today), isEnabled: false),
                Prayer(name: "Dhuhr", arabicName: "ظهر", time: parseTime(timings.dhuhr, calendar: calendar, today: today), isEnabled: true),
                Prayer(name: "Asr", arabicName: "عصر", time: parseTime(timings.asr, calendar: calendar, today: today), isEnabled: true),
                Prayer(name: "Maghrib", arabicName: "مغرب", time: parseTime(timings.maghrib, calendar: calendar, today: today), isEnabled: true),
                Prayer(name: "Isha", arabicName: "عشاء", time: parseTime(timings.isha, calendar: calendar, today: today), isEnabled: true)
            ]
            
            updateCurrentPrayer()
            save()
            NotificationManager.shared.schedulePrayerNotifications(prayers: prayers, locationName: locationName)
        } catch {
            prayers = getDefaultPrayers()
        }
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
            Prayer(name: "Sunrise", arabicName: "شروق", time: calendar.date(bySettingHour: 6, minute: 49, second: 0, of: today)!, isEnabled: false),
            Prayer(name: "Dhuhr", arabicName: "ظهر", time: calendar.date(bySettingHour: 12, minute: 41, second: 0, of: today)!, isEnabled: true),
            Prayer(name: "Asr", arabicName: "عصر", time: calendar.date(bySettingHour: 16, minute: 1, second: 0, of: today)!, isEnabled: true),
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
    @ObservedObject var settingsManager = SettingsManager.shared
    @State private var showingSettings = false
    
    var body: some View {
        ZStack {
            LinearGradient(gradient: Gradient(colors: [Color(hex: "1A1A2E"), Color(hex: "16213E")]), startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            
            VStack(spacing: 0) {
                headerView
                if !manager.prayers.isEmpty {
                    nextPrayerCard.padding(.horizontal, 16).padding(.vertical, 12)
                }
                if !manager.prayers.isEmpty { prayerTimesList }
                footerView
            }
        }.frame(width: 380, height: 550)
    }
    
    private var headerView: some View {
        VStack(spacing: 4) {
            HStack {
                Image(systemName: "location.fill").font(.caption)
                Text(manager.locationName).font(.system(size: 13, weight: .medium))
            }.foregroundColor(.white.opacity(0.7))
            
            if !manager.hijriDate.isEmpty {
                Text(manager.hijriDate).font(.system(size: 18, weight: .bold)).foregroundColor(.white)
            }
            Text(formattedDate()).font(.system(size: 11)).foregroundColor(.white.opacity(0.5))
        }.padding(.top, 16).padding(.bottom, 8)
    }
    
    private var nextPrayerCard: some View {
        let enabledPrayers = manager.prayers.filter { $0.isEnabled }
        guard let nextPrayer = enabledPrayers.first(where: { $0.time > Date() }) else {
            return AnyView(VStack { Text("All prayers completed").foregroundColor(.white.opacity(0.7)) }
                .frame(maxWidth: .infinity).padding(.vertical, 16)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.1))))
        }
        
        let displayName = settingsManager.arabicMode ? nextPrayer.arabicName : nextPrayer.name
        
        return AnyView(VStack(spacing: 4) {
            Text("Next Prayer").font(.system(size: 11)).foregroundColor(.white.opacity(0.6))
            Text(displayName).font(.system(size: 24, weight: .bold)).foregroundColor(Color(hex: "E94560"))
            Text(manager.timeRemaining()).font(.system(size: 22, weight: .bold, design: .monospaced)).foregroundColor(.white)
            Text(timeFormatter.string(from: nextPrayer.time)).font(.system(size: 12)).foregroundColor(.white.opacity(0.5))
        }.frame(maxWidth: .infinity).padding(.vertical, 16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.1)).overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(hex: "E94560").opacity(0.3), lineWidth: 1))))
    }
    
    private var prayerTimesList: some View {
        ScrollView {
            VStack(spacing: 6) {
                ForEach(manager.prayers) { prayer in
                    let displayName = settingsManager.arabicMode ? prayer.arabicName : prayer.name
                    HStack {
                        Text(displayName).font(.system(size: 14, weight: .medium)).foregroundColor(prayer.isEnabled ? .white : .white.opacity(0.4))
                        Spacer()
                        Text(timeFormatter.string(from: prayer.time)).font(.system(size: 14, weight: .medium, design: .monospaced)).foregroundColor(prayer.isEnabled ? .white : .white.opacity(0.4))
                    }.padding(.horizontal, 16).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(isCurrentPrayer(prayer) ? Color(hex: "E94560").opacity(0.15) : Color.white.opacity(0.03)))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(isCurrentPrayer(prayer) ? Color(hex: "E94560").opacity(0.5) : Color.clear, lineWidth: 1))
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
        .sheet(isPresented: $showingSettings) { SettingsView(manager: manager) }
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
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab = 0
    
    var body: some View {
        ZStack {
            Color(hex: "1A1A2E").ignoresSafeArea()
            VStack(spacing: 0) {
                Picker("", selection: $selectedTab) {
                    Text("General").tag(0)
                    Text("Location").tag(1)
                    Text("Prayer Times").tag(2)
                }.pickerStyle(.segmented).padding()
                
                TabView(selection: $selectedTab) {
                    GeneralSettingsView().tag(0)
                    LocationSettingsView(manager: manager).tag(1)
                    PrayerTimesSettingsView().tag(2)
                }.tabViewStyle(.automatic)
                
                HStack { Spacer(); Button("Done") { dismiss() }.foregroundColor(Color(hex: "E94560")).padding() }
            }
        }.frame(width: 380, height: 500)
    }
}

// MARK: - General Settings
struct GeneralSettingsView: View {
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
                        Text("Full Name").tag(PrayerNameDisplay.full)
                        Text("Abbreviation").tag(PrayerNameDisplay.abbreviation)
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
                    Toggle("Arabic Mode (Prayer Names)", isOn: $settingsManager.arabicMode).tint(Color(hex: "E94560"))
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
    
    @State private var cityInput: String = ""
    @State private var latitude: String = ""
    @State private var longitude: String = ""
    @State private var selectedTimezone: String = "Africa/Casablanca"
    @State private var isSearching: Bool = false
    @State private var searchError: String?
    
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
                SettingsSection(title: "Current Location") {
                    Button(action: useCurrentLocation) {
                        HStack { Image(systemName: "location.fill"); Text("Use Current Location") }
                    }.disabled(isSearching)
                }
                
                SettingsSection(title: "Enter City or Zip Code") {
                    TextField("City name or zip code", text: $cityInput).textFieldStyle(.roundedBorder).onSubmit { searchCity() }
                    
                    HStack {
                        TextField("Latitude", text: $latitude).textFieldStyle(.roundedBorder)
                        TextField("Longitude", text: $longitude).textFieldStyle(.roundedBorder)
                    }
                    
                    if let error = searchError {
                        Text(error).font(.caption).foregroundColor(.red)
                    }
                    
                    Button("Search & Set Location") {
                        if !cityInput.isEmpty { searchCity() }
                        else if !latitude.isEmpty && !longitude.isEmpty { setManualLocation() }
                    }.disabled(isSearching)
                }
                
                SettingsSection(title: "Timezone") {
                    Picker("Select Timezone", selection: $selectedTimezone) {
                        ForEach(timezones, id: \.self) { tz in Text(tz).tag(tz) }
                    }.onChange(of: selectedTimezone) { _ in applyTimezone() }
                }
                
                SettingsSection(title: "Popular Cities") {
                    ForEach(popularCities, id: \.0) { city, lat, lon, tz in
                        Button(action: {
                            cityInput = city
                            latitude = String(lat)
                            longitude = String(lon)
                            selectedTimezone = tz
                            manager.updateLocation(name: city, lat: lat, lon: lon, tz: TimeZone(identifier: tz))
                        }) {
                            HStack {
                                Text(city).foregroundColor(.white)
                                Spacer()
                                if manager.locationName == city {
                                    Image(systemName: "checkmark").foregroundColor(Color(hex: "E94560"))
                                }
                            }.padding(.vertical, 4)
                        }.buttonStyle(.plain)
                    }
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
    
    private func useCurrentLocation() {
        isSearching = true
        searchError = nil
        
        Task {
            if let url = URL(string: "http://ipapi.co/json/"),
               let (data, _) = try? await URLSession.shared.data(from: url),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let city = json["city"] as? String,
               let country = json["country_name"] as? String,
               let lat = json["latitude"] as? Double,
               let lon = json["longitude"] as? Double,
               let tzString = json["timezone"] as? String {
                await MainActor.run {
                    manager.updateLocation(name: "\(city), \(country)", lat: lat, lon: lon, tz: TimeZone(identifier: tzString))
                    selectedTimezone = tzString
                    isSearching = false
                }
            } else {
                await MainActor.run { searchError = "Could not determine location"; isSearching = false }
            }
        }
    }
    
    private func searchCity() {
        isSearching = true
        searchError = nil
        
        Task {
            let query = cityInput.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? cityInput
            if let url = URL(string: "https://geocoding-api.open-meteo.com/v1/search?name=\(query)&count=1&language=en&format=json"),
               let (data, _) = try? await URLSession.shared.data(from: url),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let results = json["results"] as? [[String: Any]],
               let first = results.first,
               let lat = first["latitude"] as? Double,
               let lon = first["longitude"] as? Double,
               let name = first["name"] as? String {
                await MainActor.run {
                    latitude = String(lat)
                    longitude = String(lon)
                    manager.updateLocation(name: name, lat: lat, lon: lon)
                    isSearching = false
                }
            } else {
                await MainActor.run { searchError = "City not found"; isSearching = false }
            }
        }
    }
    
    private func setManualLocation() {
        if let lat = Double(latitude), let lon = Double(longitude) {
            manager.updateLocation(name: cityInput, lat: lat, lon: lon, tz: TimeZone(identifier: selectedTimezone))
        }
    }
    
    private func applyTimezone() {
        if let tz = TimeZone(identifier: selectedTimezone) {
            manager.timezone = tz
            UserDefaults.standard.set(selectedTimezone, forKey: "timezone")
        }
    }
}

// MARK: - Prayer Times Settings
struct PrayerTimesSettingsView: View {
    @ObservedObject var settingsManager = SettingsManager.shared
    
    private let calculationMethods = [
        (0, "Muslim World League"),
        (1, "Islamic Society of North America"),
        (2, "Egyptian General Authority"),
        (3, "Umm al-Qura"),
        (4, "Ministry of Religious Affairs"),
        (5, "Institute of Geophysics"),
        (6, "Habib Al Syed")
    ]
    
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                SettingsSection(title: "Fajr & Isha Calculation Method") {
                    Picker("Method", selection: $settingsManager.fajrIshaMethod) {
                        ForEach(calculationMethods, id: \.0) { id, name in Text(name).tag(id) }
                    }.onChange(of: settingsManager.fajrIshaMethod) { _ in
                        NotificationCenter.default.post(name: .init("RefreshPrayerTimes"), object: nil)
                    }
                }
                
                SettingsSection(title: "Asr Calculation Method") {
                    Picker("Method", selection: $settingsManager.asrMethod) {
                        Text("Standard (Hanafi/Shafi/Malaki)").tag(AsrMethod.standard)
                        Text("Hanbali").tag(AsrMethod.hanbali)
                    }
                }
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("Calculation Methods:").font(.headline).foregroundColor(.white.opacity(0.7))
                    Text("MWL: Europe, Far East").font(.caption).foregroundColor(.white.opacity(0.5))
                    Text("ISNA: North America").font(.caption).foregroundColor(.white.opacity(0.5))
                    Text("Egyptian: Africa, Middle East").font(.caption).foregroundColor(.white.opacity(0.5))
                    Text("Umm al-Qura: Saudi Arabia").font(.caption).foregroundColor(.white.opacity(0.5))
                }.padding().frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.05)))
            }.padding()
        }
    }
}

struct SettingsSection<Content: View>: View {
    let title: String
    let content: Content
    
    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundColor(.white.opacity(0.6))
            content.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.05)))
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
