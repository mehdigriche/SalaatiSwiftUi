import SwiftUI
import CoreLocation

struct Prayer: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let arabicName: String
    var time: Date
    var isEnabled: Bool
    
    static func == (lhs: Prayer, rhs: Prayer) -> Bool {
        lhs.id == rhs.id
    }
}

@MainActor
class PrayerTimesManager: ObservableObject {
    @Published var prayers: [Prayer] = [
        Prayer(name: "Fajr", arabicName: "فجر", time: Calendar.current.date(from: DateComponents(hour: 5, minute: 30))!, isEnabled: true),
        Prayer(name: "Dhuhr", arabicName: "ظهر", time: Calendar.current.date(from: DateComponents(hour: 12, minute: 30))!, isEnabled: true),
        Prayer(name: "Asr", arabicName: "عصر", time: Calendar.current.date(from: DateComponents(hour: 15, minute: 45))!, isEnabled: true),
        Prayer(name: "Maghrib", arabicName: "مغرب", time: Calendar.current.date(from: DateComponents(hour: 18, minute: 50))!, isEnabled: true),
        Prayer(name: "Isha", arabicName: "عشاء", time: Calendar.current.date(from: DateComponents(hour: 20, minute: 15))!, isEnabled: true)
    ]
    
    @Published var locationName: String = "Casablanca, Morocco"
    @Published var latitude: Double = 33.5731
    @Published var longitude: Double = -7.5898
    
    @Published var currentPrayerIndex: Int = 0
    
    private let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "hh:mm a"
        return formatter
    }()
    
    init() {
        updateCurrentPrayer()
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
    
    func load() {
        if let name = UserDefaults.standard.string(forKey: "locationName") {
            locationName = name
        }
        if UserDefaults.standard.object(forKey: "latitude") != nil {
            latitude = UserDefaults.standard.double(forKey: "latitude")
            longitude = UserDefaults.standard.double(forKey: "longitude")
        }
        
        if let data = UserDefaults.standard.data(forKey: "prayers"),
           let savedPrayers = try? JSONDecoder().decode([Prayer].self, from: data) {
            prayers = savedPrayers
        }
    }
}

struct ContentView: View {
    @StateObject private var manager = PrayerTimesManager()
    @State private var showingSettings = false
    
    var body: some View {
        ZStack {
            // Background gradient
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
                // Header with settings button
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
                
                // Next prayer card
                nextPrayerCard
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                
                // Prayer list
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach($manager.prayers) { $prayer in
                            PrayerRow(prayer: prayer, isCurrent: manager.prayers.firstIndex(where: { $0.id == prayer.id }) == manager.currentPrayerIndex)
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
        .frame(minWidth: 400, minHeight: 500)
        .sheet(isPresented: $showingSettings) {
            SettingsView(manager: manager)
        }
        .onAppear {
            manager.load()
            manager.updateCurrentPrayer()
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
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
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
                }
                
                Section("Prayer Times") {
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
                    Button("Reset to Default Times") {
                        resetToDefaults()
                    }
                    .foregroundColor(.red)
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 450, height: 550)
        .onAppear {
            loadSettings()
        }
    }
    
    private func loadSettings() {
        locationName = manager.locationName
        latitude = String(manager.latitude)
        longitude = String(manager.longitude)
    }
    
    private func saveAndClose() {
        manager.locationName = locationName
        if let lat = Double(latitude) {
            manager.latitude = lat
        }
        if let lon = Double(longitude) {
            manager.longitude = lon
        }
        manager.save()
        dismiss()
    }
    
    private func resetToDefaults() {
        manager.prayers = [
            Prayer(name: "Fajr", arabicName: "فجر", time: Calendar.current.date(from: DateComponents(hour: 5, minute: 30))!, isEnabled: true),
            Prayer(name: "Dhuhr", arabicName: "ظهر", time: Calendar.current.date(from: DateComponents(hour: 12, minute: 30))!, isEnabled: true),
            Prayer(name: "Asr", arabicName: "عصر", time: Calendar.current.date(from: DateComponents(hour: 15, minute: 45))!, isEnabled: true),
            Prayer(name: "Maghrib", arabicName: "مغرب", time: Calendar.current.date(from: DateComponents(hour: 18, minute: 50))!, isEnabled: true),
            Prayer(name: "Isha", arabicName: "عشاء", time: Calendar.current.date(from: DateComponents(hour: 20, minute: 15))!, isEnabled: true)
        ]
        manager.save()
    }
}

// Color extension for hex colors
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
