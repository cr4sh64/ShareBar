import Foundation
import NetFS
import Network

/// Un backend sait monter un partage. Pour un futur type que NetFS ne gère pas
/// (sshfs, rclone…), il suffit d'écrire un autre backend et de le router dans App.backend(for:).
protocol MountBackend {
    /// allowUI = false : aucune fenêtre système (ni mot de passe, ni alerte d'échec).
    func mount(_ share: Share, allowUI: Bool, completion: @escaping (Result<URL?, Error>) -> Void)
}

struct MountError: LocalizedError {
    let code: Int32
    var isCancel: Bool { code == -128 || code == ECANCELED }
    /// Réessayer ne sert à rien si l'utilisateur a annulé ou si le mot de passe est refusé.
    var isRetryable: Bool { !isCancel && ![EAUTH, EACCES, EPERM].contains(code) }
    var errorDescription: String? {
        switch code {
        case -128, ECANCELED: return "Annulé"
        case EAUTH, EACCES, EPERM: return "Mot de passe manquant ou refusé, clique sur le partage pour le saisir"
        case ENOENT: return "Partage introuvable"
        case ETIMEDOUT, EHOSTUNREACH, EHOSTDOWN, ENETUNREACH: return "Serveur injoignable"
        case let c where c > 0: return String(cString: strerror(c))
        default: return "Erreur \(code)"
        }
    }
}

/// Montage via le framework système NetFS (smb, afp, nfs, webdav).
/// Mot de passe nil → NetFS utilise le trousseau et affiche la fenêtre de connexion si besoin.
final class NetFSBackend: MountBackend {
    func mount(_ share: Share, allowUI: Bool, completion: @escaping (Result<URL?, Error>) -> Void) {
        guard let url = share.url else { return completion(.failure(MountError(code: EINVAL))) }
        // Valeurs de kNAUIOptionKey / kNAUIOptionNoUI (macros CFSTR non importées en Swift).
        let openOptions: CFMutableDictionary? = allowUI ? nil : (NSMutableDictionary(dictionary: ["UIOption": "NoUI"]) as CFMutableDictionary)
        var requestID: AsyncRequestID?
        let rc = NetFSMountURLAsync(url as CFURL, nil, share.user.map { $0 as CFString }, nil,
                                    openOptions, nil, &requestID, .main) { status, _, mountpoints in
            if status == 0 || status == EEXIST {
                let path = ((mountpoints as NSArray?) as? [String])?.first
                completion(.success(path.map { URL(fileURLWithPath: $0) }))
            } else {
                completion(.failure(MountError(code: status)))
            }
        }
        if rc != 0 { completion(.failure(MountError(code: rc))) }
    }
}

enum Volumes {
    static func key(scheme: String, host: String, path: String) -> String {
        let h = host.precomposedStringWithCanonicalMapping.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let p = path.precomposedStringWithCanonicalMapping.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return "\(scheme.lowercased())://\(h)/\(p)"
    }

    /// Volumes réseau actuellement montés : clé → point de montage. Lecture ponctuelle, pas de polling.
    static func mounted() -> [String: URL] {
        let keys: [URLResourceKey] = [.volumeURLForRemountingKey]
        let vols = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                          options: [.skipHiddenVolumes]) ?? []
        var map = [String: URL]()
        for v in vols {
            guard let r = try? v.resourceValues(forKeys: Set(keys)).volumeURLForRemounting,
                  let scheme = r.scheme, let host = r.host else { continue }
            map[key(scheme: scheme, host: host, path: r.path)] = v
        }
        return map
    }

    static func unmount(_ url: URL, completion: @escaping (Error?) -> Void) {
        FileManager.default.unmountVolume(at: url, options: []) { err in
            DispatchQueue.main.async { completion(err) }
        }
    }
}

enum Route {
    /// Adresse locale que macOS utiliserait pour joindre `host`, nil s'il n'y a aucune route.
    /// connect() en UDP consulte seulement la table de routage : rien n'est envoyé sur le réseau.
    /// Elle change quand le Wi-Fi revient ou qu'un VPN prend la route du NAS.
    static func source(to host: String) -> String? {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_DGRAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, "445", &hints, &res) == 0, let ai = res?.pointee else { return nil }
        defer { freeaddrinfo(res) }
        let fd = socket(ai.ai_family, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard connect(fd, ai.ai_addr, ai.ai_addrlen) == 0 else { return nil }
        var ss = sockaddr_storage()
        var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
        var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let ok = withUnsafeMutablePointer(to: &ss) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len) == 0
                    && getnameinfo($0, len, &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0
            }
        }
        return ok ? String(cString: buf) : nil
    }
}

enum Probe {
    /// Ouvre puis referme une connexion TCP : true si le service répond en moins de `timeout` s.
    /// Résultat sur la file principale.
    static func tcp(host: String, port: UInt16, timeout: TimeInterval = 2, completion: @escaping (Bool) -> Void) {
        let conn = NWConnection(host: .init(host), port: .init(rawValue: port)!, using: .tcp)
        var done = false
        let finish = { (ok: Bool) in
            guard !done else { return }
            done = true
            conn.cancel()
            completion(ok)
        }
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready: finish(true)
            case .failed, .waiting: finish(false) // .waiting : pas de route ou connexion refusée
            default: break
            }
        }
        conn.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { finish(false) }
    }
}
