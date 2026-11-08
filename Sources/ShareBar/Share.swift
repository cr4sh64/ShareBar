import Foundation

/// Types de partages. NetFS sait déjà gérer smb/afp/nfs/webdav :
/// ajouter un type = ajouter un cas ici (et un backend si NetFS ne suffit pas).
enum ShareProtocol: String, Codable {
    case smb, afp, nfs, webdav, webdavs

    var scheme: String {
        switch self {
        case .webdav: return "http"
        case .webdavs: return "https"
        default: return rawValue
        }
    }

    /// Port testé avant un montage auto.
    var port: UInt16 {
        switch self {
        case .smb: return 445
        case .afp: return 548
        case .nfs: return 2049
        case .webdav: return 80
        case .webdavs: return 443
        }
    }
}

struct Share: Codable, Hashable {
    var name: String
    var type: ShareProtocol = .smb
    var host: String
    var path: String              // nom du partage, ex. "Musique"
    var user: String? = nil       // mot de passe : géré par le trousseau macOS
    var autoMount: Bool = false
    var openOnMount: Bool = false
    var mountAttempts: Int = 1     // tentatives en cas d'échec, 10 s d'écart

    /// Clé de comparaison avec les volumes montés (même format que Volumes.key).
    var id: String { Volumes.key(scheme: type.scheme, host: host, path: path) }

    var url: URL? {
        var c = URLComponents()
        c.scheme = type.scheme
        c.host = host
        c.path = "/" + path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return c.url
    }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        type = try c.decodeIfPresent(ShareProtocol.self, forKey: .type) ?? .smb
        host = try c.decode(String.self, forKey: .host)
        path = try c.decode(String.self, forKey: .path)
        user = try c.decodeIfPresent(String.self, forKey: .user)
        autoMount = try c.decodeIfPresent(Bool.self, forKey: .autoMount) ?? false
        openOnMount = try c.decodeIfPresent(Bool.self, forKey: .openOnMount) ?? false
        mountAttempts = max(1, try c.decodeIfPresent(Int.self, forKey: .mountAttempts) ?? 1)
    }
}

private struct Config: Codable { var shares: [Share] }

enum ConfigStore {
    static let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ShareBar", isDirectory: true)
    static let file = dir.appendingPathComponent("shares.json")

    static let example = """
    {
      "shares": [
        {
          "name": "NAS – Documents",
          "type": "smb",
          "host": "nas.local",
          "path": "Documents",
          "user": "moi",
          "autoMount": true,
          "openOnMount": false
        }
      ]
    }
    """

    static func modificationDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
    }

    static func load() throws -> [Share] {
        let fm = FileManager.default
        if !fm.fileExists(atPath: file.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try example.write(to: file, atomically: true, encoding: .utf8)
        }
        return try JSONDecoder().decode(Config.self, from: Data(contentsOf: file)).shares
    }
}
