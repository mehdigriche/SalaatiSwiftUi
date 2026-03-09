import SwiftUI
import CoreLocation

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
    
    enum CodingKeys: String, CodingKey {
        case Fajr, Sunrise, Dhuhr, Asr, Maghrib, Isha
    }
}

@MainActor
class PrayerTimesManager: ObservableObject {
    @Published var prayers: [Prayer] = []
    @Published var locationName: String = "Casablanca, Morocco"
    @Published var latitude: Double = 33.5731
    @Published var longitude: Double = -7.5898
    
    @Published var currentPrayerIndex: Int = 0
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    
    private let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "hh:mm a"
        return formatter
    }()
    
    init() {
        loadSavedLocation()
        Task {
            await fetchPrayerTimes()
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
            
            let decoder = JSONDecoder()
            let prayerData = try decoder.decode([String: PrayerTimesResponse].self, from: data)
            
            guard let timings = prayerData["data"]?.timings else {
                errorMessage = "Invalid response format"
                isLoading = false
                return
            }
            
            let calendar = Calendar.current
            let today = Date()
            
            prayers = [
                Prayer(name: "Fajr", arabicName: "فجر", time: parseTime(timings.Fajr, calendar: calendar, today: today), isEnabled: true),
                Prayer(name: "Dhuhr", arabicName: "ظهر", time: parseTime(timings.Dhuhr, calendar: calendar, today: today), isEnabled: true),
                Prayer(name: "Asr", arabicName: "عصر", time: parseTime(timings.Asr, calendar: calendar, today: today), isEnabled: true),
                Prayer(name: "Maghrib", arabicName: "مغرب", time: parseTime(timings.Maghrib, calendar: calendar, today: today), isEnabled: true),
                Prayer(name: "Isha", arabicName: "عشاء", time: parseTime(timings.Isha, calendar: calendar, today: today), isEnabled: true)
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
              let minute = Int(components[1]) else {
            return today
        }
        
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: today) ?? today
    }
    
    private func getDefaultPrayers() -> [Prayer] {
        let calendar = Calendar.current
        let today = Date()
        
        return [
            Prayer(name: "Fajr", arabicName: "فجر", time: calendar.date(bySettingHour: 5, minute: 26, second: 0, of: today)!, isEnabled: true),
            Prayer(name: "Dhuhr", arabicName: "ظهر", time: calendar.date(bySettingHour: 12, minute: 41, second: 0, of: today)!, isEnabled: true),
            Prayer(name: "Asr", arabicName: "عصر", time: calendar.date(bySettingHour: 16, minute: 1, second: 0, of: today)!, isEnabled: true),
            Prayer(name: "Maghrib", arabicName: "مغرب", time: calendar.date(bySettingHour: 18, minute: 33, second: 0, of: today)!, isEnabled: true),
            Prayer(name: "Isha", arabicName: "عشاء", time: calendar.date(bySettingHour: 19, minute: 51, second: 0, of: today)!, isEnabled: true)
        ]
    }
    
    func updateCurrentPrayer() {
        let now = Date()
        for (index, prayer) in prayers.enumerated() {
            if prayer.time > now {
                currentPrayerIndex = max(0, index)
                return
            }
        }
        currentPrayerIndex = prayers.count - 1
    }
    
    func timeRemaining() -> String {
        let now = Date()
        if let nextPrayer = prayers.first(where: { $0.time > now }) {
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
    
    func loadSavedPrayers() {
        if let data = UserDefaults.standard.data(forKey: "prayers"),
           let savedPrayers = try? JSONDecoder().decode([Prayer].self, from: data) {
            prayers = savedPrayers
        }
    }
    
    func updateLocation(name: String, lat: Double, lon: Double) {
        locationName = name
        latitude = lat
        longitude = lon
        save()
        Task {
            await fetchPrayerTimes()
        }
    }
}

struct ContentView: View {
    @StateObject private var manager = PrayerTimesManager()
    @State private var showingSettings = false
    
    var body: some View {
        ZStack {
            LinearGradient(
                gradient: Gradient(colors: [
                    Color(hex: "1A1A2E"),
                    Color(hex: "16213E"),
                    Color(hex: "0F3460")
                ]),
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Salaati")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                        
                        Text(manager.locationName)
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.7))
                    }
                    
                    Spacer()
                    
                    Button(action: { showingSettings = true }) {
                        Image(systemName: "gearshape.fill")
                            .font(.title2)
                            .foregroundColor(.white.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 16)
                
                Text(formattedDate())
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.6))
                    .padding(.bottom, 20)
                
                if manager.isLoading {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(1.5)
                        .padding(.vertical, 40)
                } else if let error = manager.errorMessage {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundColor(.orange)
                        Text(error)
                            .foregroundColor(.white.opacity(0.7))
                        Button("Retry") {
                            Task {
                                await manager.fetchPrayerTimes()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color(hex: "E94560"))
                    }
                    .padding(.vertical, 40)
                } else {
                    nextPrayerCard
                        .padding(.horizontal, 24)
                        .padding(.bottom, 24)
                    
                    ScrollView {
                        VStack(spacing: 10) {
                            ForEach($manager.prayers) { $prayer in
                                PrayerRow(
                                    prayer: prayer,
                                    isCurrent: manager.prayers.firstIndex(where: { $0.id == prayer.id }) == manager.currentPrayerIndex
                                )
                                .onTapGesture {
                                    prayer.isEnabled.toggle()
                                    manager.save()
                                }
                            }
                        }
                        .padding(.horizontal, 24)
                    }
                }
            }
        }
        .frame(minWidth: 400, minHeight: 500)
        .sheet(isPresented: $showingSettings) {
            SettingsView(manager: manager)
        }
    }
    
    private var nextPrayerCard: some View {
        VStack(spacing: 8) {
            Text("Next Prayer")
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.7))
            
            let prayerIndex = min(manager.currentPrayerIndex, manager.prayers.count - 1)
            Text(manager.prayers[prayerIndex].name)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundColor(Color(hex: "E94560"))
            
            Text(manager.timeRemaining())
                .font(.system(size: 20, weight: .medium, design: .monospaced))
                .foregroundColor(.white)
            
            Text("at \(timeFormatter.string(from: manager.prayers[prayerIndex].time))")
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white.opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.white.opacity(0.2), lineWidth: 1)
                )
        )
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

struct PrayerRow: View {
    let prayer: Prayer
    let isCurrent: Bool
    
    private let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "hh:mm a"
        return formatter
    }()
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(prayer.name)
                        .font(.headline)
                        .foregroundColor(.white)
                    
                    Text(prayer.arabicName)
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.7))
                }
                
                Text(timeFormatter.string(from: prayer.time))
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.6))
            }
            
            Spacer()
            
            if isCurrent {
                Text("NOW")
                    .font(.caption.bold())
                    .foregroundColor(Color(hex: "E94560"))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(hex: "E94560").opacity(0.2))
                    .cornerRadius(6)
            }
            
            Toggle("", isOn: Binding(
                get: { prayer.isEnabled },
                set: { _ in }
            ))
            .labelsHidden()
            .tint(Color(hex: "E94560"))
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isCurrent ? Color.white.opacity(0.15) : Color.white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isCurrent ? Color(hex: "E94560").opacity(0.5) : Color.clear, lineWidth: 1)
        )
    }
}

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
        ("Fes, Morocco", 34.0181, -5.0078),
        ("Tangier, Morocco", 35.7595, -5.8340),
        ("London, UK", 51.5074, -0.1278),
        ("Paris, France", 48.8566, 2.3522),
        ("Dubai, UAE", 25.2048, 55.2708),
        ("Istanbul, Turkey", 41.0082, 28.9784),
        ("New York, USA", 40.7128, -74.0060)
    ]
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Settings")
                    .font(.title2.bold())
                    .foregroundColor(.primary)
                
                Spacer()
                
                Button("Done") {
                    saveAndClose()
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(hex: "E94560"))
            }
            .padding()
            
            Divider()
            
            Form {
                Section("Location") {
                    TextField("Location Name", text: $locationName)
                        .textFieldStyle(.roundedBorder)
                    
                    HStack {
                        TextField("Latitude", text: $latitude)
                            .textFieldStyle(.roundedBorder)
                        
                        TextField("Longitude", text: $longitude)
                            .textFieldStyle(.roundedBorder)
                    }
                    
                    Button(action: fetchCurrentLocation) {
                        HStack {
                            if isFetchingLocation {
                                ProgressView()
                                    .scaleEffect(0.8)
                            } else {
                                Image(systemName: "location.fill")
                            }
                            Text("Use Current Location")
                        }
                    }
                    .disabled(isFetchingLocation)
                }
                
                Section("Popular Locations") {
                    ForEach(popularLocations, id: \.0) { name, lat, lon in
                        Button(action: {
                            locationName = name
                            latitude = String(lat)
                            longitude = String(lon)
                        }) {
                            HStack {
                                Text(name)
                                    .foregroundColor(.primary)
                                Spacer()
                                if locationName == name {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(Color(hex: "E94560"))
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                
                Section("Prayer Times (Manual Override)") {
                    ForEach($manager.prayers) { $prayer in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(prayer.name)
                                    .font(.headline)
                                Text(prayer.arabicName)
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                            
                            DatePicker("", selection: $prayer.time, displayedComponents: .hourAndMinute)
                                .labelsHidden()
                        }
                    }
                }
                
                Section {
                    Button("Reset to Default Location") {
                        locationName = "Casablanca, Morocco"
                        latitude = "33.5731"
                        longitude = "-7.5898"
                    }
                    .foregroundColor(.red)
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 450, height: 600)
        .onAppear {
            loadSettings()
        }
    }
    
    private func loadSettings() {
        locationName = manager.locationName
        latitude = String(manager.latitude)
        longitude = String(manager.longitude)
    }
    
    private func fetchCurrentLocation() {
        isFetchingLocation = true
        
        Task {
            if let url = URL(string: "http://ipapi.co/json/"),
               let (data, _) = try? await URLSession.shared.data(from: url) {
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let city = json["city"] as? String,
                   let country = json["country_name"] as? String,
                   let lat = json["latitude"] as? Double,
                   let lon = json["longitude"] as? Double {
                    
                    await MainActor.run {
                        locationName = "\(city), \(country)"
                        latitude = String(lat)
                        longitude = String(lon)
                        isFetchingLocation = false
                    }
                    return
                }
            }
            
            await MainActor.run {
                isFetchingLocation = false
            }
        }
    }
    
    private func saveAndClose() {
        if let lat = Double(latitude), let lon = Double(longitude) {
            manager.updateLocation(name: locationName, lat: lat, lon: lon)
        }
        dismiss()
    }
}

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3:
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }
        
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

#Preview {
    ContentView()
}
