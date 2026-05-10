import Foundation

/// Minimal byte buffer wrapper compatible with the NIOCore API used here.
public struct ByteBuffer: Sendable {
    public var data: Data

    public init(data: Data) {
        self.data = data
    }

    public init(string: String) {
        self.data = Data(string.utf8)
    }
}
