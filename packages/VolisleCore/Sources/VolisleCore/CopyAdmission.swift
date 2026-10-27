import Foundation

/// Conservative write footprints. False conflicts wait; missing a conflict could overwrite another job.
enum CopyAdmission {
    static func canonical(_ path: String) -> String {
        path.split(separator: "/").map {
            let original = String($0).precomposedStringWithCanonicalMapping
                .uppercased(with: Locale(identifier: "en_US_POSIX"))
            var component = original
            while component.last == " " || component.last == "." { component.removeLast() }
            return component.isEmpty ? original : component
        }.joined(separator: "/")
    }

    static func claims(for plan: CopyPlan) -> Set<String> {
        var result = Set<String>()
        for item in plan.items {
            guard let top = item.relative.split(separator: "/", maxSplits: 1).first else { continue }
            let root = plan.destination.isEmpty ? String(top) : plan.destination + "/" + top
            result.insert(canonical(root))
            // Nested parts are already below their selected directory's footprint.
            if !item.relative.contains("/"), item.kind != .directory {
                result.insert(canonical(ResumableCopier.partPath(for: "/" + plan.target(item), partID: plan.partID)))
            }
        }
        return result
    }

    static func overlap(_ left: Set<String>, _ right: Set<String>) -> Bool {
        func hasAncestor(_ paths: Set<String>, in ancestors: Set<String>) -> Bool {
            for path in paths {
                var current = path
                while !current.isEmpty {
                    if ancestors.contains(current) { return true }
                    current = (current as NSString).deletingLastPathComponent
                }
            }
            return false
        }
        return hasAncestor(left, in: right) || hasAncestor(right, in: left)
    }
}
