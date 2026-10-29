import SwiftUI

struct ManualRangeView: View {
    let stream: LiveStream
    let onDownload: (Date, Date) -> Void

    @State private var start: Date
    @State private var end: Date

    init(stream: LiveStream, onDownload: @escaping (Date, Date) -> Void) {
        self.stream = stream
        self.onDownload = onDownload
        // Par défaut : la dernière heure pleine écoulée.
        let cal = Calendar.current
        let hourStart = cal.dateInterval(of: .hour, for: Date())?.start ?? Date()
        _start = State(initialValue: hourStart.addingTimeInterval(-3600))
        _end = State(initialValue: hourStart)
    }

    private var earliest: Date {
        stream.archiveDays > 0
            ? Date().addingTimeInterval(TimeInterval(-stream.archiveDays * 86_400))
            : Date().addingTimeInterval(-30 * 86_400)
    }

    private var problem: String? {
        if end <= start { return "La fin doit être postérieure au début." }
        if end > Date().addingTimeInterval(60) { return "La fin est dans le futur : le replay n'existe pas encore." }
        if start < earliest { return "Le début dépasse la durée de replay de la chaîne (\(stream.archiveDays) jours)." }
        if end.timeIntervalSince(start) > 12 * 3600 { return "Plage supérieure à 12 h — réduisez-la." }
        return nil
    }

    var body: some View {
        Form {
            Section {
                DatePicker("Début", selection: $start, in: earliest...Date(), displayedComponents: [.date, .hourAndMinute])
                DatePicker("Fin", selection: $end, in: earliest...Date().addingTimeInterval(60), displayedComponents: [.date, .hourAndMinute])
                LabeledContent("Durée") {
                    Text(end > start ? DateFormats.durationLabel(end.timeIntervalSince(start)) : "—")
                        .monospacedDigit()
                }
            } header: {
                Text("Plage horaire")
            } footer: {
                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
            }

            Section("Raccourcis") {
                HStack {
                    ForEach([30, 60, 90, 120], id: \.self) { minutes in
                        Button(minutes < 60 ? "\(minutes) min" : DateFormats.durationLabel(TimeInterval(minutes * 60))) {
                            end = start.addingTimeInterval(TimeInterval(minutes * 60))
                        }
                    }
                    Spacer()
                    Button("Dernière heure") {
                        end = Date()
                        start = end.addingTimeInterval(-3600)
                    }
                }
            }

            Section {
                HStack {
                    Spacer()
                    Button {
                        onDownload(start, end)
                    } label: {
                        Label("Télécharger", systemImage: "arrow.down.circle.fill")
                            .padding(.horizontal, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(problem != nil)
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
    }
}
