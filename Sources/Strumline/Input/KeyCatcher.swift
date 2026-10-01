import SwiftUI
import UIKit

/// Invisible first responder that forwards hardware key presses (with their
/// real timestamps) to InputManager. GCKeyboard doesn't always deliver keys
/// to a SwiftUI app; this makes the keyboard reliable in menus and in game.
/// It steps aside while a text field is being edited.
struct KeyCatcher: UIViewRepresentable {
    func makeUIView(context: Context) -> CatcherView { CatcherView() }
    func updateUIView(_ v: CatcherView, context: Context) { v.reclaim() }

    final class CatcherView: UIView {
        private var observers: [NSObjectProtocol] = []

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            let nc = NotificationCenter.default
            for name in [UITextField.textDidEndEditingNotification, UITextView.textDidEndEditingNotification, UIApplication.didBecomeActiveNotification] {
                observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self?.reclaim() }
                })
            }
        }
        required init?(coder: NSCoder) { fatalError() }

        // Sheets and alerts take first responder; take it back afterwards.
        private lazy var timer: Timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.reclaim() }
        deinit { observers.forEach(NotificationCenter.default.removeObserver); timer.invalidate() }

        override var canBecomeFirstResponder: Bool { true }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            _ = timer
            reclaim()
        }

        func reclaim() {
            guard window != nil, !isFirstResponder else { return }
            // Don't steal focus from a text field someone is typing in.
            if let r = window?.firstResponderView, r is UITextField || r is UITextView { return }
            becomeFirstResponder()
        }

        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            var unhandled = Set<UIPress>()
            for p in presses {
                if let k = p.key { InputManager.shared.keyEvent(k.keyCode.rawValue, down: true, time: p.timestamp, source: .uikit) } else { unhandled.insert(p) }
            }
            if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
        }

        override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            for p in presses { if let k = p.key { InputManager.shared.keyEvent(k.keyCode.rawValue, down: false, time: p.timestamp, source: .uikit) } }
            super.pressesEnded(presses.filter { $0.key == nil }, with: event)
        }

        override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            pressesEnded(presses, with: event)
        }
    }
}

private extension UIView {
    var firstResponderView: UIView? {
        if isFirstResponder { return self }
        for s in subviews { if let r = s.firstResponderView { return r } }
        return nil
    }
}
