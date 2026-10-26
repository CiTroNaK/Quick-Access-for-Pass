import AppKit
import Observation
import SwiftUI
import Testing

/// Minimal synthetic control: preserve the presenter while changing its presentation binding.
@Suite("Native sheet harness", .serialized)
@MainActor
struct NativeSheetHarnessTests {
    @Test("A mounted plain text sheet closes through its binding", .timeLimit(.minutes(1)))
    func plainSheetLifecycle() async throws {
        let events = AsyncStream<String>.makeStream()
        defer { events.continuation.finish() }
        let state = PlainSheetHarnessState()
        let host = NSHostingView(rootView: PlainSheetHarnessRoot(state: state, events: events.continuation))
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 720, height: 480),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { state.isPresented = true }
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        host.layoutSubtreeIfNeeded()
        var iterator = events.stream.makeAsyncIterator()
        let appeared = await iterator.next()
        try #require(appeared == "appeared")
        do {
            let sheet = try #require(window.attachedSheet)
            sheet.contentView?.layoutSubtreeIfNeeded()
            sheet.contentView?.displayIfNeeded()
        }
        withTransaction(transaction) { state.isPresented = false }
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        host.layoutSubtreeIfNeeded()
        var dismissed = false
        while let event = await iterator.next() {
            if event == "dismissed" { dismissed = true; break }
        }
        #expect(dismissed)
        #expect(window.attachedSheet == nil)
    }
}

@MainActor @Observable
private final class PlainSheetHarnessState {
    var isPresented = false
}

@MainActor
private struct PlainSheetHarnessRoot: View {
    @Bindable var state: PlainSheetHarnessState
    let events: AsyncStream<String>.Continuation

    var body: some View {
        Color.white.frame(width: 720, height: 480)
            .sheet(isPresented: $state.isPresented, onDismiss: { events.yield("dismissed") }, content: {
                Text("Synthetic fixture").frame(width: 720, height: 480)
                    .onAppear { events.yield("appeared") }
                    .onDisappear { events.yield("disappeared") }
            })
            .transaction { $0.disablesAnimations = true; $0.animation = nil }
    }
}
