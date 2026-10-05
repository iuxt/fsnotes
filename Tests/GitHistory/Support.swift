// Minimal stand-ins for unrelated app services. The Git code under test is
// compiled directly from FSNotesCore by run.sh.
import Foundation
import Cgit2

enum UserDefaultsManagement { static var firstLineAsTitle = false }

public enum ReferenceType { case test }
public class RepositoryManager {}
public class Branch {}
public class Branches {
    init(repository: Repository) {}
    func get(spec: String) throws -> Branch { Branch() }
}
public class Statuses { init(repository: Repository) {} }
public class Tags { init(repository: Repository) {} }
public class Remotes { init(repository: Repository) {} }
public class Reference {
    var name = "HEAD"
    init(repository: Repository, name: String, pointer: UnsafeMutablePointer<OpaquePointer?>) throws {
        git_reference_free(pointer.pointee)
        pointer.deallocate()
    }
}
public class Head: Reference {
    func targetReference() throws -> Reference { self }
}
public class Diff {
    init(pointer: UnsafeMutablePointer<OpaquePointer?>) {
        git_diff_free(pointer.pointee)
        pointer.deallocate()
    }
}
extension Date {
    func string(format: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = format
        return formatter.string(from: self)
    }
}
