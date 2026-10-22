import SwiftUI

/// No chrome: the label shrinks a little while pressed and springs back.
struct PressStyle: ButtonStyle {
	func makeBody(configuration: Configuration) -> some View {
		configuration.label
			.scaleEffect(configuration.isPressed ? Theme.pressScale : 1)
			.animation(.spring(duration: 0.3, bounce: 0.5), value: configuration.isPressed)
	}
}
