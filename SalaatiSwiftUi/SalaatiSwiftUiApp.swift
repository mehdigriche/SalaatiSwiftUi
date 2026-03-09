import SwiftUI

struct Prayer: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let arabicName: String
    let time: Date
    var isEnabled: Bool
    
    static func == (lhs: Prayer, rhs: Prayer) -> Bool {
        lhs.id == rhs.id
    }
}

struct PrayerTimesView: View {
    @State private var prayers: [Prayer] = [
        Prayer(name: "Fajr", arabicName: "فجر", time: Calendar.current.date(from: DateComponents(hour: 5, minute: 30))!, isEnabled: true),
        Prayer(name: "Dhuhr", arabicName: "ظهر", time: Calendar.current.date(from: DateComponents(hour: 12, minute: 30))!, isEnabled: true),
        Prayer(name: "Asr", arabicName: "عصر", time: Calendar.current.date(from: DateComponents(hour: 15, minute: 45))!, isEnabled: true),
        Prayer(name: "Maghrib", arabicName: "مغرب", time: Calendar.current.date(from: DateComponents(hour: 18, minute: 50))!, isEnabled: true),
        Prayer(name: "Isha", arabicName: "عشاء", time: Calendar.current.date(from: DateComponents(hour: 20, minute: 15))!, isEnabled: true)
    ]
    
    @State private var currentPrayerIndex: Int = 0
    @State private var nextPrayerTime: Date = Date()
    
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "hh:mm a"
        return formatter
    }()
    
    var body: some View {
        NavigationView {
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
                    // Header
                    VStack(spacing: 8) {
                        Text("Salaati")
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                        
                        Text(formattedDate())
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.7))
                    }
                    .padding(.top, 20)
                    .padding(.bottom, 30)
                    
                    // Next prayer card
                    nextPrayerCard
                        .padding(.horizontal, 20)
                        .padding(.bottom, 30)
                    
                    // Prayer list
                    ScrollView {
                        VStack(spacing: 12) {
                            ForEach(prayers.indices, id: \.self) { index in
                                PrayerRow(prayer: prayers[index], isCurrent: index == currentPrayerIndex)
                                    .onTapGesture {
                                        prayers[index].isEnabled.toggle()
                                    }
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                }
            }
            .navigationBarHidden(true)
        }
    }
    
    private var nextPrayerCard: some View {
        VStack(spacing: 10) {
            Text("Next Prayer")
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.7))
            
            Text(prayers[min(currentPrayerIndex, prayers.count - 1)].name)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundColor(Color(hex: "E94560"))
            
            Text(timeRemaining())
                .font(.title2.weight(.medium))
                .foregroundColor(.white)
            
            Text("at \(dateFormatter.string(from: prayers[min(currentPrayerIndex, prayers.count - 1)].time))")
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 25)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color.white.opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(Color.white.opacity(0.2), lineWidth: 1)
                )
        )
    }
    
    private func formattedDate() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMMM d, yyyy"
        return formatter.string(from: Date())
    }
    
    private func timeRemaining() -> String {
        let now = Date()
        let calendar = Calendar.current
        
        if let nextPrayer = prayers.first(where: { $0.time > now }) {
            let components = calendar.dateComponents([.hour, .minute, .second], from: now, to: nextPrayer.time)
            if let hours = components.hour, let minutes = components.minute {
                return "\(hours)h \(minutes)m"
            }
        }
        
        return "All prayers completed"
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
        .padding(16)
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

// Color extension for hex colors
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
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
    PrayerTimesView()
}
