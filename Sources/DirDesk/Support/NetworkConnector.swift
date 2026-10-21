import AppKit
import NetFS

/// Mounts network shares through NetFS; macOS handles sign-in, DirDesk stores no passwords.
@MainActor
enum NetworkConnector {
    struct ConnectError: Error {
        let message: String
    }

    static let supportedSchemes: Set<String> = ["smb", "afp", "nfs", "ftp", "http", "https"]

    /// Validates an address: a scheme from the supported set, a host, no embedded password,
    /// no query or fragment. A missing scheme defaults to SMB.
    static func normalize(_ address: String) throws -> URL {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ConnectError(message: L("Enter a server address.")) }
        if !text.contains("://") { text = "smb://" + text }
        guard let components = URLComponents(string: text), let scheme = components.scheme?.lowercased() else {
            throw ConnectError(message: L("macOS could not open this server address."))
        }
        guard supportedSchemes.contains(scheme) else {
            throw ConnectError(message: L("Use an SMB, AFP, NFS, FTP, or WebDAV (HTTPS/HTTP) server address."))
        }
        guard let host = components.host, !host.isEmpty else {
            throw ConnectError(message: L("The server address needs a computer name or IP address."))
        }
        if components.password != nil {
            throw ConnectError(message: L("Do not include a password in the server address. macOS will ask for credentials securely."))
        }
        if components.query != nil || components.fragment != nil {
            throw ConnectError(message: L("Check the server address, port, and folder path. Query strings and fragments are not supported."))
        }
        return components.url!
    }

    static func connect(address: String, completion: @escaping @MainActor (Result<URL, ConnectError>) -> Void) {
        let url: URL
        do {
            url = try normalize(address)
        } catch let error as ConnectError {
            completion(.failure(error))
            return
        } catch {
            completion(.failure(ConnectError(message: error.localizedDescription)))
            return
        }
        let openOptions = NSMutableDictionary()
        openOptions[kNAUIOptionKey] = kNAUIOptionAllowUI
        var requestID: AsyncRequestID?
        let status = NetFSMountURLAsync(url as CFURL, nil, nil, nil, openOptions, nil, &requestID, DispatchQueue.main) { result, _, mountPoints in
            let points = (mountPoints as? [String]) ?? []
            MainActor.assumeIsolated {
                if result == 0, let first = points.first {
                    completion(.success(URL(fileURLWithPath: first, isDirectory: true)))
                } else if result == Int32(ECANCELED) || result == -128 {
                    completion(.failure(ConnectError(message: L("The operation could not be completed."))))
                } else if result == Int32(ETIMEDOUT) {
                    completion(.failure(ConnectError(message: L("The server connection timed out."))))
                } else {
                    completion(.failure(ConnectError(message: L("macOS could not open this server address.") + " (\(result))")))
                }
            }
        }
        if status != 0 {
            completion(.failure(ConnectError(message: L("macOS could not open this server address.") + " (\(status))")))
        }
    }
}
