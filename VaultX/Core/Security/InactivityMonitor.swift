import UIKit

/// Rileva l'inattività osservando i tocchi in tutta l'app (senza intercettarli).
/// Quando passa `timeout` secondi senza interazioni chiama `onTimeout`.
@MainActor
final class InactivityMonitor {

    static let shared = InactivityMonitor()

    private init() {}

    private var timer: Timer?
    private var timeout: TimeInterval = 0
    private var lastActivity = Date()
    private var onTimeout: (() -> Void)?
    private var observer: TouchObserver?

    /// Messo in pausa mentre sono aperti picker/anteprime di sistema,
    /// che non passano i tocchi alla nostra finestra.
    private(set) var isPaused = false

    func start(
        timeout: TimeInterval,
        onTimeout: @escaping () -> Void
    ) {

        stop()

        guard timeout > 0 else {
            return
        }

        self.timeout = timeout
        self.onTimeout = onTimeout
        self.lastActivity = Date()

        installObserver()

        timer = Timer.scheduledTimer(
            withTimeInterval: 1,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
    }

    func stop() {

        timer?.invalidate()
        timer = nil

        onTimeout = nil
        isPaused = false

        if let observer {
            observer.view?.removeGestureRecognizer(observer)
        }

        observer = nil
    }

    func setPaused(_ paused: Bool) {

        isPaused = paused

        if !paused {
            noteActivity()
        }
    }

    func noteActivity() {
        lastActivity = Date()
    }

    private func tick() {

        guard onTimeout != nil, !isPaused else {
            return
        }

        if Date().timeIntervalSince(lastActivity) >= timeout {

            let handler = onTimeout
            stop()
            handler?()
        }
    }

    private func installObserver() {

        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }

        guard let window else {
            return
        }

        let recognizer = TouchObserver(target: nil, action: nil)
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesBegan = false
        recognizer.delaysTouchesEnded = false
        recognizer.onTouch = { [weak self] in
            self?.noteActivity()
        }

        window.addGestureRecognizer(recognizer)
        observer = recognizer
    }
}

/// Gesture recognizer che non riconosce mai nulla: si limita a notare i tocchi.
private final class TouchObserver: UIGestureRecognizer {

    var onTouch: (() -> Void)?

    override func touchesBegan(
        _ touches: Set<UITouch>,
        with event: UIEvent
    ) {
        onTouch?()
    }

    override func touchesMoved(
        _ touches: Set<UITouch>,
        with event: UIEvent
    ) {
        onTouch?()
    }

    override func touchesEnded(
        _ touches: Set<UITouch>,
        with event: UIEvent
    ) {
        onTouch?()
        state = .failed
    }

    override func touchesCancelled(
        _ touches: Set<UITouch>,
        with event: UIEvent
    ) {
        state = .failed
    }
}
