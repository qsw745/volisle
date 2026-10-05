import Foundation

/// Pages on the website and the public feedback repository, in the language the app is shown in.
enum WebsiteLink {
    case home, help, support, feedback

    var url: URL {
        if self == .feedback { return URL(string: "https://github.com/qsw745/volisle-feedback/issues")! }
        let language = Bundle.main.preferredLocalizations.first == "en" ? "en/" : ""
        let page = switch self {
        case .home, .feedback: ""
        case .help: "help/"
        case .support: "support/"
        }
        return URL(string: "https://qisw.top/volisle/\(language)\(page)")!
    }
}
