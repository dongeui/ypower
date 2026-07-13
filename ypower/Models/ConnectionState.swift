import Foundation

enum ConnectionState: Equatable {
    case unknown
    case good
    case degraded
}

enum ConnectionMedium: Equatable {
    case wifi
    case ethernet
    case none
}

enum WiFiBand: Equatable {
    case ghz2_4
    case ghz5
    case ghz6
    case unknown
}
