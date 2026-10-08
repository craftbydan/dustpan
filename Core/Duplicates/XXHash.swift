import CXXHash

/// Thin Swift wrapper over the vendored xxHash C library.
enum XXHash {
    /// 64-bit xxHash3 of a byte buffer.
    static func hash64(_ bytes: UnsafeRawBufferPointer, seed: UInt64 = 0) -> UInt64 {
        XXH3_64bits_withSeed(bytes.baseAddress, bytes.count, seed)
    }

    /// Streaming XXH3-64: feed chunks with `update`, read the result with `digest`. Not shared
    /// between threads; one per file being hashed.
    final class Stream {
        private let state: OpaquePointer?

        init() {
            state = XXH3_createState()
            if let state { XXH3_64bits_reset(state) }
        }

        deinit {
            if let state { XXH3_freeState(state) }
        }

        /// False only if xxHash couldn't allocate its state.
        var isValid: Bool { state != nil }

        func update(_ bytes: UnsafeRawBufferPointer) {
            guard let state, bytes.count > 0 else { return }
            XXH3_64bits_update(state, bytes.baseAddress, bytes.count)
        }

        func digest() -> UInt64 {
            guard let state else { return 0 }
            return XXH3_64bits_digest(state)
        }
    }
}
