# ShareBar

Gestionnaire de partages réseau pour la barre des menus macOS.
Il monte tes partages SMB, AFP, NFS ou WebDAV automatiquement, au Wi-Fi comme en VPN,
sans fenêtre intempestive et sans rien faire tourner en arrière-plan.

- **Swift / AppKit natif**, ~500 lignes, aucune dépendance
- **macOS 13 Ventura** et plus, Apple Silicon et Intel
- **Léger** : aucun timer, ~15–25 Mo de mémoire, stable dans le temps

## Fonctionnalités

- Montage auto au lancement, au réveil de veille et dès que le NAS redevient joignable
  (Wi-Fi revenu, VPN connecté)
- Test rapide du serveur (2 s) avant chaque montage auto : si le NAS est absent,
  rien n'est tenté, donc ni alerte ni attente
- Montages auto silencieux : les erreurs s'affichent dans le menu, pas en fenêtre
- Nombre de tentatives réglable par partage
- Mots de passe gérés par le trousseau macOS, jamais par l'app
- Ouverture au démarrage de la session

## Installer

Prérequis : les outils en ligne de commande Xcode (`xcode-select --install`).

```bash
git clone https://github.com/cr4sh64/ShareBar.git
cd ShareBar
./build.sh --install
```

`build.sh` compile un binaire universel, assemble `build/ShareBar.app`, le signe
localement, puis avec `--install` le copie dans `/Applications` et le lance.

L'app est signée localement, pas par un développeur identifié Apple. Au premier
lancement, macOS peut demander une confirmation : Réglages Système ›
Confidentialité et sécurité › « Ouvrir quand même ».

## Configurer

Menu › **Modifier les partages…** ouvre
`~/Library/Application Support/ShareBar/shares.json` (créé avec un exemple au
premier lancement) :

```json
{
  "shares": [
    {
      "name": "NAS – Documents",
      "type": "smb",
      "host": "192.168.1.10",
      "path": "Documents",
      "user": "moi",
      "autoMount": true,
      "openOnMount": false,
      "mountAttempts": 3
    }
  ]
}
```

| Champ | Obligatoire | Défaut | Rôle |
|---|---|---|---|
| `name` | oui | | Nom affiché dans le menu |
| `host` | oui | | Nom ou adresse IP du serveur |
| `path` | oui | | Nom du partage |
| `type` | | `smb` | `smb`, `afp`, `nfs`, `webdav`, `webdavs` |
| `user` | | | Nom d'utilisateur pré-rempli. Le mot de passe n'est jamais stocké ici |
| `autoMount` | | `false` | Monter automatiquement |
| `openOnMount` | | `false` | Ouvrir une fenêtre Finder à chaque montage auto |
| `mountAttempts` | | `1` | Tentatives en cas d'échec, 10 s d'écart |

Le fichier est relu à la prochaine ouverture du menu.

### Mots de passe

Monte chaque partage une première fois **à la main** (clic dans le menu) : macOS
affiche sa fenêtre de connexion, coche « Mémoriser dans le trousseau ». Les montages
auto suivants utilisent le trousseau sans rien afficher. Si le mot de passe manque
ou change, le menu affiche « Mot de passe manquant ou refusé » : un clic sur le
partage fait réapparaître la fenêtre.

## Utilisation

| Action | Effet |
|---|---|
| Clic sur un partage non monté | Monte, puis ouvre dans le Finder |
| Clic sur un partage monté (✓) | Ouvre dans le Finder |
| **⌥ Option + clic** sur un partage monté | Démonte |
| Tout monter / Tout démonter | Sur tous les partages |
| Ouvrir au démarrage | Lance ShareBar à l'ouverture de session |

Un partage suivi de « … » est en cours de montage.

## Développer

```bash
swift build      # compile
swift test       # lance les tests
./build.sh       # assemble build/ShareBar.app
```

Le fonctionnement interne (événements, montage, détection réseau) est décrit dans
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Limites connues

- Un partage est reconnu comme monté en comparant hôte + chemin. S'il est monté
  ailleurs avec un autre nom d'hôte (IP au lieu de `nas.local`), ShareBar ne le voit
  pas comme monté : utilise le même `host` partout.
- Le test avant montage vérifie que le serveur répond sur son port. Il ne détecte
  ni un mauvais nom de partage ni un mot de passe refusé : ces erreurs s'affichent
  dans le menu après la tentative.

## Licence

[MIT](LICENSE)
