//
//  Utilities.swift
//  
//
//  Created by John Biggs on 10.10.23.
//

import Foundation

extension Substring {
    func advanced(by n: Int) -> Self {
        let start = (0..<n)
            .reduce(into: startIndex) { result, _ in
                result = self.index(after: result)
            }
        return self[start...]
    }
}

extension URL {
    var canonicalPath: String? {
        get throws {
            try resourceValues(forKeys: [.canonicalPathKey]).canonicalPath
        }
    }

    static func createFromPathOrThrow(_ path: String) throws -> Self {
        guard let url = Self(string: path) else {
            throw GluonError.invalidPath(path)
        }
        return url
    }
}

extension FileHandle: TextOutputStream {
    public func write(_ string: String) {
        try? write(contentsOf: string.data(using: .utf8) ?? Data())
    }
}

extension FileHandle {
    static var stderr: TextOutputStream = FileHandle.standardError
}

extension RandomAccessCollection {
    /// - Warning: The collection *must* be sorted according to the predicate.
    func binarySearch(predicate: (Iterator.Element) -> Bool) -> Index {
        var low = startIndex
        var high = endIndex
        while low != high {
            let mid = index(low, offsetBy: distance(from: low, to: high) / 2)
            if predicate(self[mid]) {
                low = index(after: mid)
            } else {
                high = mid
            }
        }
        return low
    }
}
