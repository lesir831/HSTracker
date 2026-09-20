import Foundation

struct AccountProgressReadFailure: Error {
    let scope: String?
    let reason: String
}
