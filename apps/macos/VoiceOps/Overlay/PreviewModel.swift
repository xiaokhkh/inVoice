import Foundation

@MainActor
final class PreviewModel: ObservableObject {
    enum State: Equatable {
        case idle
        case recording
        case processing
        case result
        case failure
    }

    @Published var text: String = ""
    @Published var state: State = .idle
}
