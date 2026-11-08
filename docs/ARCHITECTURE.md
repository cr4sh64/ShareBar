# Architecture

ShareBar est une app de barre des menus (sans icône dans le Dock) qui délègue le
montage à macOS. Elle ne fait rien tant qu'aucun événement système ne la réveille.

## Arborescence

```
ShareBar/
├── Package.swift                 Package Swift (swift build / swift test)
├── build.sh                      Assemble, signe et installe ShareBar.app
├── Resources/
│   └── Info.plist                Identité de l'app (LSUIElement : pas d'icône Dock)
├── Sources/ShareBar/
│   ├── main.swift                Point d'entrée
│   ├── App.swift                 Menu, événements système, logique de montage auto
│   ├── Share.swift               Modèle d'un partage, lecture de la config
│   └── Mounting.swift            Montage NetFS, volumes, route, test du serveur
├── Tests/ShareBarTests/          Tests unitaires (XCTest)
├── docs/ARCHITECTURE.md          Ce fichier
└── .github/workflows/ci.yml      Tests et build à chaque push
```

## Les fichiers

### `main.swift`
Crée l'application, lui attache `AppDelegate` et la passe en mode « accessoire » :
elle n'apparaît que dans la barre des menus.

### `App.swift` — `AppDelegate`
Le cœur de l'app.

- **Démarrage** : crée l'icône, charge la config et démarre le moniteur réseau. Le
  premier montage auto part quand le moniteur trouve une route vers les NAS, donc
  seulement une fois le réseau prêt.
- **Événements écoutés** (aucun polling) :
  - **changement réseau** (`NWPathMonitor`) → voir [Montage auto](#montage-auto) ;
  - **réveil de veille** → nouvel essai sur tous les NAS joignables, 6 s plus tard ;
  - **montage / démontage d'un volume** → mise à jour de l'infobulle (« 3/4 monté(s) »).
- **Menu** reconstruit à chaque ouverture (`menuNeedsUpdate`) à partir de l'état réel
  des volumes : un élément par partage (coché s'il est monté, ⌥ + clic pour démonter),
  Tout monter / Tout démonter, dernière erreur en grisé, Modifier les partages…,
  Ouvrir au démarrage (`SMAppService`), Quitter.
- **`backend(for:)`** : choisit le moteur de montage selon le type de partage. Point
  d'extension pour des protocoles non gérés par NetFS.
- **`pending`** : partages en cours de montage, tentatives comprises, pour ne jamais
  lancer deux fois le même montage.

### `Share.swift`
- **`ShareProtocol`** : types supportés (`smb`, `afp`, `nfs`, `webdav`, `webdavs`),
  avec leur schéma d'URL et le port testé avant montage.
- **`Share`** : un partage de la config. Construit son URL et son identifiant de
  comparaison. Les champs facultatifs ont une valeur par défaut, ce qui garde les
  anciennes configs valides quand une option est ajoutée.
- **`ConfigStore`** : lit `~/Library/Application Support/ShareBar/shares.json`, crée
  un exemple s'il n'existe pas, et ne relit le fichier que si sa date a changé.

### `Mounting.swift`
- **`MountBackend`** : contrat d'un moteur de montage,
  `mount(share, allowUI, completion)`.
- **`NetFSBackend`** : montage via le framework système NetFS, le même que Finder ›
  Se connecter au serveur. Avec `allowUI: false`, NetFS n'affiche aucune fenêtre
  (ni mot de passe, ni alerte d'échec). Aucun mot de passe ne transite par l'app.
- **`MountError`** : traduit les codes d'erreur système en messages lisibles, et dit
  si une erreur est une annulation ou mérite un nouvel essai.
- **`Volumes`** : liste les volumes réseau montés et les associe aux partages
  (hôte + chemin, sans tenir compte de la casse ni de la normalisation Unicode),
  et démonte un volume.
- **`Route.source(to:)`** : adresse locale par laquelle macOS joindrait un hôte, ou
  `nil` s'il n'y a pas de route. Un `connect()` UDP consulte la table de routage
  sans rien envoyer sur le réseau.
- **`Probe.tcp`** : ouvre puis referme une connexion TCP vers le port du partage.
  Réponse en 2 s au plus.

## Montage auto

```
 NWPathMonitor ──► Route.source() par NAS ──► route changée ? ──non──► rien
                                                   │ oui
                                                   ▼
                        (3 s de regroupement des événements)
                                                   │
                                                   ▼
            pour chaque partage autoMount non monté de cet hôte :
                Probe.tcp (2 s) ──échec──► nouvel essai dans 10 s (mountAttempts)
                      │ ok
                      ▼
                NetFS, sans fenêtre ──échec──► idem, sauf annulation / mot de passe refusé
                      │ ok
                      ▼
                   monté ✓
```

Pourquoi ces étapes :

- **Route plutôt que type d'interface.** Les interfaces VPN (`utun`) envoient des
  notifications réseau en continu. Réagir à chacune relançait les montages en boucle,
  même sans réseau. Comparer la route vers chaque NAS ignore ce bruit et réagit
  pourtant au retour du Wi-Fi comme à la connexion d'un VPN.
- **Test du serveur avant NetFS.** Sur un serveur absent, NetFS peut bloquer
  plusieurs minutes. Le test répond en 2 s au plus et évite toute tentative inutile,
  par exemple hors de chez soi, quand la route par défaut fait croire le NAS
  joignable.
- **Pas de fenêtre en auto.** Une alerte par tentative serait insupportable. Les
  erreurs vont dans le menu. Un clic manuel, lui, autorise les fenêtres macOS pour
  saisir un mot de passe.
- **Pas de nouvel essai sur une annulation ou un mot de passe refusé.** Ça ne
  servirait à rien et pourrait verrouiller le compte.
- **Tentatives interrompues si la route disparaît**, pour reprendre proprement au
  retour du réseau.

## Choix anti-fuite

| Choix | Effet |
|---|---|
| Aucun `Timer`, aucun ping périodique | Rien ne tourne en arrière-plan |
| Menu reconstruit à l'ouverture puis libéré | Pas d'objets d'interface conservés |
| Closures en `[weak self]` | Pas de cycles de références |
| Montage délégué à NetFS | Aucune connexion ni tampon réseau gardés par l'app |
| Config relue seulement si modifiée | Pas de lecture disque inutile |

## Tests

`swift test` couvre la logique sans état : lecture de la config et valeurs par
défaut, URL et identifiants des partages, comparaison avec les volumes montés
(casse, Unicode), classement des erreurs, route et test du serveur. Les tests réseau
n'utilisent que `127.0.0.1` et une adresse réservée aux tests (`192.0.2.1`) : ils
passent sans NAS, y compris en CI.

Non couvert par les tests automatiques : l'enchaînement des événements dans
`AppDelegate` (réveil, changement de route, tentatives) et le vrai montage NetFS.
À vérifier à la main : démonter un partage, couper puis rétablir le Wi-Fi, et
vérifier qu'il remonte sans fenêtre.

## Faire évoluer

| Besoin | Où intervenir |
|---|---|
| Nouveau type géré par NetFS | Un cas dans `ShareProtocol` (schéma + port) |
| Protocole non natif (sshfs, rclone, S3…) | Une classe conforme à `MountBackend`, routée dans `backend(for:)` |
| Nouvelle option par partage | Un champ dans `Share` avec sa valeur par défaut dans `init(from:)` |
| Nouvelle action de menu | `menuNeedsUpdate` dans `App.swift` |
| Interface de configuration | Une fenêtre qui écrit `shares.json`, le reste ne change pas |
