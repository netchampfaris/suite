import SwiftUI

/// Creates an event, or edits one the person organizes.
struct EventForm: View {
    /// The event being edited, or nil for a new one.
    let event: CalendarEvent?

    @Environment(Workspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @State private var change: EventChange
    @State private var isSaving = false
    @State private var failure: String?
    private let start: EventChange

    init(day: Date) {
        event = nil
        var change = EventChange(day: day)
        change.addsMeeting = true
        _change = State(initialValue: change)
        start = change
    }

    init(editing event: CalendarEvent, me: String) {
        self.event = event
        let change = EventChange(event, me: me)
        _change = State(initialValue: change)
        start = change
    }

    private var isRecurring: Bool { event?.record?.isRecurring ?? false }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Title", text: $change.title)
                Section {
                    Toggle("All day", isOn: $change.isAllDay)
                    DatePicker("Starts", selection: $change.start, displayedComponents: change.isAllDay ? .date : [.date, .hourAndMinute])
                    DatePicker("Ends", selection: $change.end, in: change.start..., displayedComponents: change.isAllDay ? .date : [.date, .hourAndMinute])
                } footer: {
                    if isRecurring {
                        Text("This event repeats. Changes to the title, place, guests, and notes apply to every occurrence. Change its time in the web app.")
                    }
                }
                .disabled(isRecurring)
                Section {
                    if event == nil {
                        Toggle("Add a Meet link", isOn: $change.addsMeeting)
                    }
                    TextField("Location", text: $change.location)
                    TextField("Guests", text: $change.guests, prompt: Text("Email addresses"), axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.emailAddress)
                        .accessibilityLabel("Guests")
                } footer: {
                    if !change.guestList.isEmpty { Text("Guests get an email about the event.") }
                }
                Section("Notes") {
                    TextField("Notes", text: $change.notes, axis: .vertical)
                        .lineLimit(3...)
                }
                if workspace.calendarWriter == nil {
                    Section {
                        Text("This is a sample calendar. Events are not saved.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(event == nil ? "New event" : "Edit event")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(isSaving || change != start)
            .onChange(of: change.start) { old, new in
                // Moving the start keeps the event's length, as in Calendar.
                change.end = new.addingTimeInterval(max(change.end.timeIntervalSince(old), 0))
            }
            .alert("Could not save the event", isPresented: Binding { failure != nil } set: { _ in failure = nil }) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(failure ?? "")
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button(event == nil ? "Add" : "Save") { save() }
                            .disabled(change.title.trimmingCharacters(in: .whitespaces).isEmpty || change == start)
                    }
                }
            }
        }
    }

    private func save() {
        if let wrong = change.guestList.first(where: { !Draft.isAddress($0) }) {
            failure = "“\(wrong)” is not an email address."
            return
        }
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                try await workspace.changeCalendar { writer in
                    if let event { try await writer.update(event, to: change) } else { try await writer.create(change) }
                }
                dismiss()
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}
