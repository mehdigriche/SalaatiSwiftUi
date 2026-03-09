import SwiftUI
import CoreLocation

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
    let Fajr: String
    let Sunrise: String
    let Dhuhr: String
    let Asr: String
    let Maghrib: String
    let Isha: String
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
    @Published var errorMessage: String?
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
        errorMessage = nil
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "dd-MM-yyyy"
        let dateString = dateFormatter.string(from: Date())
        
        let urlString = "https://api.aladhan.com/v1/timings/\(dateString)?latitude=\(latitude)&longitude=\(longitude)&method=3"
        
        guard let url = URL(string: urlString) else {
            errorMessage = "Invalid URL"
            isLoading = false
            return
        }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let prayerData = try JSONDecoder().decode([String: AnyCodable].self, from: data)
            
            guard let dataObj = prayerData["data"],
                  let dataDict = dataObj.value as? [String: Any],
                  let timingsAny = dataDict["timings"],
                  let timingsDict = timingsAny as? [String: String] else {
                errorMessage = "Invalid response format"
                isLoading = false
                return
            }
            
            let calendar = Calendar.current
            let today = Date()
            
            // Get Hijri date
            if let dateAny = dataDict["date"],
               let dateDict = dateAny as? [String: Any],
               let hijriAny = dateDict["hijri"],
               let hijriDict = hijriAny as? [String: Any] {
                let day = hijriDict["day"] as? String ?? ""
                let month = (hijriDict["month"] as? [String: Any])?["ar"] as? String ?? ""
                let year = hijriDict["year"] as? String ?? ""
                hijriDate = "\(day) \(month) \(year)"
            }
            
            prayers = [
                Prayer(name: "Fajr", arabicName: "فجر", time: parseTime(timingsDict["Fajr"] ?? "05:26", calendar: calendar, today: today), isEnabled: true),
                Prayer(name: "Sunrise", arabicName: "شروق", time: parseTime(timingsDict["Sunrise"] ?? "06:00", calendar: calendar, today: today), isEnabled: false),
                Prayer(name: "Dhuhr", arabicName: "ظهر", time: parseTime(timingsDict["Dhuhr"] ?? "12:00", calendar: calendar, today: today), isEnabled: true),
                Prayer(name: "Asr", arabicName: "عصر", time: parseTime(timingsDict["Asr"] ?? "15:00", calendar: calendar, today: today), isEnabled: true),
                Prayer(name: "Maghrib", arabicName: "مغرب", time: parseTime(timingsDict["Maghrib"] ?? "18:00", calendar: calendar, today: today), isEnabled: true),
                Prayer(name: "Isha", arabicName: "عشاء", time: parseTime(timingsDict["Isha"] ?? "20:00", calendar: calendar, today: today), isEnabled: true)
            ]
            
            updateCurrentPrayer()
            save()
        } catch {
            errorMessage = "Error: \(error.localizedDescription)"
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
        // If all prayers passed, show Isha
        currentPrayerIndex = max(0, prayers.count - 1)
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
        if let data = try? JSONEncoder().encode(prayers) {
            UserDefaults.standard.set(data, forKey: "prayers")
        }
    }
    
    func updateLocation(name: String, lat: Double, lon: Double) {
        locationName = name
        latitude = lat
        longitude = lon
        save()
        Task { await fetchPrayerTimes() }
    }
}

// MARK: - AnyCodable for flexible JSON parsing
struct AnyCodable: Codable {
    let value: Any
    
    init(_ value: Any) {
        self.value = value
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues { $0.value }
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map { $0.value }
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else {
            value = NSNull()
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let dict = value as? [String: Any] {
            try container.encode(dict.mapValues { AnyCodable($0) })
        } else if let array = value as? [Any] {
            try container.encode(array.map { AnyCodable($0) })
        } else if let string = value as? String {
            try container.encode(string)
        } else if let int = value as? Int {
            try container.encode(int)
        } else if let double = value as? Double {
            try container.encode(double)
        } else if let bool = value as? Bool {
            try container.encode(bool)
        }
    }
}

// MARK: - Tab Enum
enum AppTab: String, CaseIterable {
    case home = "Home"
    case qibla = "Qibla"
    case quran = "Quran"
    case dua = "Dua"
    case settings = "Settings"
    
    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .qibla: return "safari.fill"
        case .quran: return "book.closed.fill"
        case .dua: return "hands.sparkles.fill"
        case .settings: return "gearshape.fill"
        }
    }
}

// MARK: - Main App View
struct SalaatiApp: View {
    @State private var selectedTab: AppTab = .home
    
    var body: some View {
        ZStack(alignment: .bottom) {
            // Content
            Group {
                switch selectedTab {
                case .home: HomeView()
                case .qibla: QiblaView()
                case .quran: QuranView()
                case .dua: DuaView()
                case .settings: SettingsTabView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            
            // Bottom Navigation Bar
            bottomNavBar
        }
        .ignoresSafeArea(.keyboard)
    }
    
    private var bottomNavBar: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases, id: \.self) { tab in
                Button(action: { selectedTab = tab }) {
                    VStack(spacing: 4) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 20))
                        Text(tab.rawValue)
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundColor(selectedTab == tab ? Color(hex: "E94560") : .gray)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(hex: "1A1A2E"))
                .shadow(color: .black.opacity(0.3), radius: 10, y: -5)
        )
        .padding(.horizontal)
    }
}

// MARK: - Home View
struct HomeView: View {
    @StateObject private var manager = PrayerTimesManager()
    @State private var showingSettings = false
    
    var body: some View {
        ZStack {
            // Background gradient
            LinearGradient(
                gradient: Gradient(colors: [Color(hex: "1A1A2E"), Color(hex: "16213E")]),
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            
            ScrollView {
                VStack(spacing: 16) {
                    // Location & Date Header
                    VStack(spacing: 4) {
                        HStack {
                            Image(systemName: "location.fill").font(.caption)
                            Text(manager.locationName).font(.subheadline)
                        }
                        .foregroundColor(.white.opacity(0.7))
                        
                        if !manager.hijriDate.isEmpty {
                            Text(manager.hijriDate)
                                .font(.system(size: 16, weight: .medium))
                                .foregroundColor(.white)
                        }
                        
                        Text(formattedDate())
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.5))
                    }
                    .padding(.top, 20)
                    
                    // Next Prayer Card
                    if !manager.prayers.isEmpty {
                        nextPrayerCard
                    }
                    
                    // Prayer Times List
                    if !manager.prayers.isEmpty {
                        prayerTimesList
                    }
                    
                    if manager.isLoading {
                        ProgressView().progressViewStyle(CircularProgressViewStyle(tint: .white)).padding(.top, 40)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 80) // Space for nav bar
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(manager: manager)
        }
        .onAppear {
            if let button = NSApp.windows.first?.standardWindowButton(.closeButton) {
                // Settings accessible via tab
            }
        }
    }
    
    private var nextPrayerCard: some View {
        let enabledPrayers = manager.prayers.filter { $0.isEnabled }
        guard let currentIndex = enabledPrayers.firstIndex(where: { $0.time > Date() }),
              currentIndex < enabledPrayers.count else {
            return AnyView(emptyCard)
        }
        
        let nextPrayer = enabledPrayers[currentIndex]
        
        return AnyView(VStack(spacing: 8) {
            Text("الموعد القادم").font(.subheadline).foregroundColor(.white.opacity(0.7))
            
            Text(nextPrayer.name)
                .font(.system(size: 32, weight: .bold))
                .foregroundColor(Color(hex: "E94560"))
            
            Text(nextPrayer.arabicName)
                .font(.system(size: 18))
                .foregroundColor(.white.opacity(0.8))
            
            Text(manager.timeRemaining())
                .font(.system(size: 28, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
            
            Text("at \(timeFormatter.string(from: nextPrayer.time))")
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color.white.opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(Color.white.opacity(0.2), lineWidth: 1)
                )
        ))
    }
    
    private var emptyCard: some View {
        AnyView(VStack {
            Text("جميع الصلوات انتهت")
                .foregroundColor(.white.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color.white.opacity(0.1))
        ))
    }
    
    private var prayerTimesList: some View {
        VStack(spacing: 8) {
            ForEach(manager.prayers) { prayer in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(prayer.name)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.white)
                        Text(prayer.arabicName)
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.6))
                    }
                    
                    Spacer()
                    
                    Text(timeFormatter.string(from: prayer.time))
                        .font(.system(size: 16, weight: .medium, design: .monospaced))
                        .foregroundColor(prayer.isEnabled ? .white : .white.opacity(0.4))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(prayer.isEnabled ? Color.white.opacity(0.1) : Color.white.opacity(0.03))
                )
            }
        }
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

// MARK: - Qibla View
struct QiblaView: View {
    @State private var degrees: Double = 0
    
    var body: some View {
        ZStack {
            LinearGradient(gradient: Gradient(colors: [Color(hex: "1A1A2E"), Color(hex: "16213E")]), startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            
            VStack(spacing: 30) {
                Text("القبله").font(.system(size: 28, weight: .bold)).foregroundColor(.white)
                
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.2), lineWidth: 2)
                        .frame(width: 250, height: 250)
                    
                    Circle()
                        .stroke(Color(hex: "E94560"), lineWidth: 3)
                        .frame(width: 200, height: 200)
                    
                    Image(systemName: "location.north.fill")
                        .font(.system(size: 40))
                        .foregroundColor(Color(hex: "E94560"))
                        .rotationEffect(.degrees(degrees))
                }
                
                VStack(spacing: 8) {
                    Text("اتجاه القبله").font(.subheadline).foregroundColor(.white.opacity(0.7))
                    Text("95°").font(.system(size: 32, weight: .bold)).foregroundColor(.white)
                }
            }
        }
    }
}

// MARK: - Quran View
struct QuranView: View {
    let surahs = [
        ("الفاتحه", "Al-Fatiha", 7),
        ("البقره", "Al-Baqarah", 286),
        ("ال عمران", "Ali Imran", 200),
        ("النساء", "An-Nisa", 176),
        ("المائده", "Al-Ma'idah", 120),
        ("الانعام", "Al-An'am", 165),
        ("الاعراف", "Al-A'raf", 206),
        ("الانفال", "Al-Anfal", 75),
        ("التوبه", "At-Tawbah", 129),
        ("يونس", "Yunus", 109)
    ]
    
    var body: some View {
        ZStack {
            LinearGradient(gradient: Gradient(colors: [Color(hex: "1A1A2E"), Color(hex: "16213E")]), startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            
            ScrollView {
                VStack(spacing: 8) {
                    Text("القرآن الكريم")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.vertical, 20)
                    
                    ForEach(0..<surahs.count, id: \.self) { index in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(surahs[index].0)
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundColor(.white)
                                Text(surahs[index].1)
                                    .font(.system(size: 12))
                                    .foregroundColor(.white.opacity(0.6))
                            }
                            Spacer()
                            Text("\(surahs[index].2) verses")
                                .font(.system(size: 12))
                                .foregroundColor(.white.opacity(0.5))
                        }
                        .padding(16)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.white.opacity(0.05))
                        )
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 80)
            }
        }
    }
}

// MARK: - Dua View
struct DuaView: View {
    let duas = [
        ("دعاء الاستخاره", "Istikhara Prayer", "اللهم اني استخيرك بعلمك"),
        ("دعاء الصباح", "Morning Prayer", "اللهم بك أصبحنا"),
        ("دعاء المساء", "Evening Prayer", "اللهم بك أمسيت"),
        ("دعاء перед сном", "Before Sleep", "باسمك اللهم أموت وأحيا"),
        ("دعاء الدخول للمسجد", "Entering Mosque", "اللهم افتح لي أبواب رحمتك")
    ]
    
    var body: some View {
        ZStack {
            LinearGradient(gradient: Gradient(colors: [Color(hex: "1A1A2E"), Color(hex: "16213E")]), startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            
            ScrollView {
                VStack(spacing: 8) {
                    Text("الأدعية")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.vertical, 20)
                    
                    ForEach(0..<duas.count, id: \.self) { index in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(duas[index].0)
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(Color(hex: "E94560"))
                            Text(duas[index].1)
                                .font(.system(size: 12))
                                .foregroundColor(.white.opacity(0.6))
                            Text(duas[index].2)
                                .font(.system(size: 14))
                                .foregroundColor(.white)
                                .padding(.top, 4)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.white.opacity(0.05))
                        )
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 80)
            }
        }
    }
}

// MARK: - Settings Tab View
struct SettingsTabView: View {
    @StateObject private var manager = PrayerTimesManager()
    
    var body: some View {
        ZStack {
            LinearGradient(gradient: Gradient(colors: [Color(hex: "1A1A2E"), Color(hex: "16213E")]), startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            
            ScrollView {
                VStack(spacing: 16) {
                    Text("الإعدادات")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.top, 20)
                        .padding(.bottom, 10)
                    
                    // Location Section
                    SettingsSection(title: "الموقع") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(manager.locationName)
                                .font(.system(size: 16))
                                .foregroundColor(.white)
                            Text("Lat: \(String(format: "%.4f", manager.latitude)), Lon: \(String(format: "%.4f", manager.longitude))")
                                .font(.system(size: 12))
                                .foregroundColor(.white.opacity(0.6))
                        }
                    }
                    
                    // Calculation Method
                    SettingsSection(title: "طريقة الحساب") {
                        Text("Muslim World League")
                            .foregroundColor(.white.opacity(0.8))
                    }
                    
                    // Notifications
                    SettingsSection(title: "الإشعارات") {
                        Toggle("تفعيل الإشعارات", isOn: .constant(true))
                            .tint(Color(hex: "E94560"))
                            .foregroundColor(.white)
                    }
                    
                    Spacer(minLength: 80)
                }
                .padding(.horizontal)
            }
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
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white.opacity(0.6))
            content
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.white.opacity(0.05))
                )
        }
    }
}

// MARK: - Settings Sheet View
struct SettingsView: View {
    @ObservedObject var manager: PrayerTimesManager
    @Environment(\.dismiss) private var dismiss
    @State private var locationName: String = ""
    @State private var latitude: String = ""
    @State private var longitude: String = ""
    @State private var isFetchingLocation: Bool = false
    
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
        NavigationView {
            ZStack {
                Color(hex: "1A1A2E").ignoresSafeArea()
                
                Form {
                    Section("Location") {
                        TextField("Location Name", text: $locationName).foregroundColor(.white)
                        TextField("Latitude", text: $latitude).foregroundColor(.white)
                        TextField("Longitude", text: $longitude).foregroundColor(.white)
                    }
                    .listRowBackground(Color.white.opacity(0.05))
                    
                    Section("Popular Locations") {
                        ForEach(popularLocations, id: \.0) { name, lat, lon in
                            Button(action: {
                                locationName = name
                                latitude = String(lat)
                                longitude = String(lon)
                            }) {
                                HStack {
                                    Text(name).foregroundColor(.white)
                                    Spacer()
                                    if locationName == name {
                                        Image(systemName: "checkmark").foregroundColor(Color(hex: "E94560"))
                                    }
                                }
                            }
                        }
                    }
                    .listRowBackground(Color.white.opacity(0.05))
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }.foregroundColor(.white)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") { saveAndClose() }.foregroundColor(Color(hex: "E94560"))
                }
            }
        }
        .onAppear { loadSettings() }
    }
    
    private func loadSettings() {
        locationName = manager.locationName
        latitude = String(manager.latitude)
        longitude = String(manager.longitude)
    }
    
    private func saveAndClose() {
        if let lat = Double(latitude), let lon = Double(longitude) {
            manager.updateLocation(name: locationName, lat: lat, lon: lon)
        }
        dismiss()
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

// MARK: - Preview
#Preview {
    SalaatiApp()
}
