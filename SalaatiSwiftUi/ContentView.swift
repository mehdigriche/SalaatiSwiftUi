import SwiftUI
import AppKit
import UserNotifications

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
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupPopover()
        startTimer()
        
        // Request notification permission
        NotificationManager.shared.requestPermission()
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
    }
    
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "moon.stars.fill", accessibilityDescription: "Salaati")
            button.action = #selector(togglePopover)
            button.target = self
        }
        
        updateStatusItemTitle()
    }
    
    private func setupPopover() {
        popover = NSPopover()
        popover.contentSize = NSSize(width: 360, height: 520)
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(rootView: MenuBarPopoverView(manager: prayerManager))
    }
    
    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateStatusItemTitle()
                self?.prayerManager.updateCurrentPrayer()
            }
        }
    }
    
    private func updateStatusItemTitle() {
        guard let button = statusItem.button else { return }
        
        let nextPrayer = prayerManager.getNextPrayer()
        if let prayer = nextPrayer {
            let remaining = prayerManager.timeRemaining()
            button.title = " \(prayer.name) \(remaining)"
            button.imagePosition = .imageLeading
        } else {
            button.title = " Done"
            button.imagePosition = .imageLeading
        }
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

struct PrayerTimesResponse: Codable {
    let timings: Timings
}

struct Timings: Codable {
    let fajr: String
    let sunrise: String
    let dhuhr: String
    let asr: String
    let maghrib: String
    let isha: String
}

// MARK: - Prayer Times Manager
@MainActor
class PrayerTimesManager: ObservableObject {
    @Published var prayers: [Prayer] = []
    @Published var locationName: String = "Casablanca, Morocco"
    @Published var latitude: Double = 33.5731
    @Published var longitude: Double = -7.5898
    @Published var currentPrayerIndex: Int = 0
    @Published var isLoading: Bool = false
    @Published var hijriDate: String = ""
    
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
    }
    
    func fetchPrayerTimes() async {
        isLoading = true
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "dd-MM-yyyy"
        let dateString = dateFormatter.string(from: Date())
        
        let urlString = "https://api.aladhan.com/v1/timings/\(dateString)?latitude=\(latitude)&longitude=\(longitude)&method=3"
        
        guard let url = URL(string: urlString) else {
            isLoading = false
            return
        }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let response = try JSONDecoder().decode(AlAdhanResponse.self, from: data)
            
            guard let timings = response.data.timings else {
                isLoading = false
                return
            }
            
            let calendar = Calendar.current
            let today = Date()
            
            // Get Hijri date
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
            scheduleNotifications()
            
        } catch {
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
    }
    
    func updateLocation(name: String, lat: Double, lon: Double) {
        locationName = name
        latitude = lat
        longitude = lon
        save()
        Task { await fetchPrayerTimes() }
    }
    
    private func scheduleNotifications() {
        NotificationManager.shared.schedulePrayerNotifications(prayers: prayers, locationName: locationName)
    }
}

// MARK: - Al-Adhan API Response Models
struct AlAdhanResponse: Codable {
    let data: AlAdhanData
}

struct AlAdhanData: Codable {
    let timings: Timings?
    let date: DateInfo
}

struct DateInfo: Codable {
    let hijri: HijriDate
}

struct HijriDate: Codable {
    let day: String
    let month: HijriMonth
    let year: String
}

struct HijriMonth: Codable {
    let ar: String
}

// MARK: - Menu Bar Popover View
struct MenuBarPopoverView: View {
    @ObservedObject var manager: PrayerTimesManager
    @State private var showingSettings = false
    
    var body: some View {
        ZStack {
            LinearGradient(
                gradient: Gradient(colors: [Color(hex: "1A1A2E"), Color(hex: "16213E")]),
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            
            VStack(spacing: 0) {
                headerView
                
                if !manager.prayers.isEmpty {
                    nextPrayerCard
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                }
                
                if !manager.prayers.isEmpty {
                    prayerTimesList
                }
                
                footerView
            }
        }
        .frame(width: 360, height: 520)
    }
    
    private var headerView: some View {
        VStack(spacing: 4) {
            HStack {
                Image(systemName: "location.fill").font(.caption)
                Text(manager.locationName)
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundColor(.white.opacity(0.7))
            
            if !manager.hijriDate.isEmpty {
                Text(manager.hijriDate)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
            }
            
            Text(formattedDate())
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.5))
        }
        .padding(.top, 16)
        .padding(.bottom, 8)
    }
    
    private var nextPrayerCard: some View {
        let enabledPrayers = manager.prayers.filter { $0.isEnabled }
        guard let nextPrayer = enabledPrayers.first(where: { $0.time > Date() }) else {
            return AnyView(VStack {
                Text("All prayers completed")
                    .foregroundColor(.white.opacity(0.7))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white.opacity(0.1))
            ))
        }
        
        return AnyView(VStack(spacing: 4) {
            Text("Next Prayer")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.6))
            
            Text(nextPrayer.name)
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(Color(hex: "E94560"))
            
            Text(nextPrayer.arabicName)
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.7))
            
            Text(manager.timeRemaining())
                .font(.system(size: 20, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
            
            Text(timeFormatter.string(from: nextPrayer.time))
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color(hex: "E94560").opacity(0.3), lineWidth: 1)
                )
        ))
    }
    
    private var prayerTimesList: some View {
        ScrollView {
            VStack(spacing: 6) {
                ForEach(manager.prayers) { prayer in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(prayer.name)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(prayer.isEnabled ? .white : .white.opacity(0.4))
                            Text(prayer.arabicName)
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.5))
                        }
                        
                        Spacer()
                        
                        Text(timeFormatter.string(from: prayer.time))
                            .font(.system(size: 14, weight: .medium, design: .monospaced))
                            .foregroundColor(prayer.isEnabled ? .white : .white.opacity(0.4))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(isCurrentPrayer(prayer) ? Color(hex: "E94560").opacity(0.15) : Color.white.opacity(0.03))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isCurrentPrayer(prayer) ? Color(hex: "E94560").opacity(0.5) : Color.clear, lineWidth: 1)
                    )
                }
            }
            .padding(.horizontal, 12)
        }
    }
    
    private var footerView: some View {
        HStack(spacing: 20) {
            Button(action: { showingSettings = true }) {
                HStack(spacing: 4) {
                    Image(systemName: "gearshape")
                    Text("Settings")
                }
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.7))
            }
            .buttonStyle(.plain)
            
            Button(action: {
                Task { await manager.fetchPrayerTimes() }
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                    Text("Refresh")
                }
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.7))
            }
            .buttonStyle(.plain)
            
            Button(action: {
                NSApplication.shared.terminate(nil)
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "power")
                    Text("Quit")
                }
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.7))
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .background(Color.black.opacity(0.2))
        .sheet(isPresented: $showingSettings) {
            SettingsView(manager: manager)
        }
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
    @State private var locationName: String = ""
    @State private var latitude: String = ""
    @State private var longitude: String = ""
    
    private let popularLocations = [
        ("Casablanca, Morocco", 33.5731, -7.5898),
        ("Rabat, Morocco", 34.0209, -6.8416),
        ("Marrakech, Morocco", 31.6295, -7.9811),
        ("London, UK", 51.5074, -0.1278),
        ("Paris, France", 48.8566, 2.3522),
        ("Dubai, UAE", 25.2048, 55.2708),
        ("Istanbul, Turkey", 41.0082, 28.9784)
    ]
    
    var body: some View {
        ZStack {
            Color(hex: "1A1A2E").ignoresSafeArea()
            
            ScrollView {
                VStack(spacing: 16) {
                    HStack {
                        Text("Settings")
                            .font(.title2.bold())
                            .foregroundColor(.white)
                        Spacer()
                        Button("Done") { dismiss() }
                            .foregroundColor(Color(hex: "E94560"))
                    }
                    .padding(.horizontal)
                    .padding(.top, 20)
                    
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Location")
                            .font(.headline)
                            .foregroundColor(.white.opacity(0.7))
                        
                        TextField("Location Name", text: $locationName)
                            .textFieldStyle(.roundedBorder)
                        
                        HStack {
                            TextField("Latitude", text: $latitude)
                                .textFieldStyle(.roundedBorder)
                            TextField("Longitude", text: $longitude)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.white.opacity(0.05))
                    )
                    .padding(.horizontal)
                    
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Popular Locations")
                            .font(.headline)
                            .foregroundColor(.white.opacity(0.7))
                        
                        ForEach(popularLocations, id: \.0) { name, lat, lon in
                            Button(action: {
                                locationName = name
                                latitude = String(lat)
                                longitude = String(lon)
                            }) {
                                HStack {
                                    Text(name)
                                        .foregroundColor(.white)
                                    Spacer()
                                    if locationName == name {
                                        Image(systemName: "checkmark")
                                            .foregroundColor(Color(hex: "E94560"))
                                    }
                                }
                                .padding(.vertical, 6)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.white.opacity(0.05))
                    )
                    .padding(.horizontal)
                    
                    Spacer()
                }
            }
        }
        .frame(width: 350, height: 450)
        .onAppear { loadSettings() }
    }
    
    private func loadSettings() {
        locationName = manager.locationName
        latitude = String(manager.latitude)
        longitude = String(manager.longitude)
    }
}

// MARK: - Notification Manager
class NotificationManager {
    static let shared = NotificationManager()
    private init() {}
    
    func requestPermission() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error {
                print("Notification permission error: \(error)")
            }
        }
    }
    
    func schedulePrayerNotifications(prayers: [Prayer], locationName: String) {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        
        for prayer in prayers where prayer.isEnabled {
            let content = UNMutableNotificationContent()
            content.title = "Time for \(prayer.name)"
            content.body = "\(prayer.name) - \(prayer.arabicName) at \(timeString(from: prayer.time))"
            content.sound = .default
            
            let calendar = Calendar.current
            let components = calendar.dateComponents([.hour, .minute], from: prayer.time)
            var dateComponents = DateComponents()
            dateComponents.hour = components.hour
            dateComponents.minute = components.minute
            
            let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)
            let request = UNNotificationRequest(identifier: prayer.id.uuidString, content: content, trigger: trigger)
            
            center.add(request) { error in
                if let error = error {
                    print("Error scheduling notification: \(error)")
                }
            }
        }
    }
    
    private func timeString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "hh:mm a"
        return formatter.string(from: date)
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
