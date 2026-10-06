# Docker rootless sur Debian — installation en une commande

Deux scripts, un seul à lancer :

| Fichier | Rôle |
|---|---|
| `docker-rootless.sh` | **Point d'entrée unique.** Partie admin (root, ré-élévation `sudo` automatique), puis installe et exécute la partie utilisateur sous le compte cible. |
| `docker-rootless-user.sh` | Partie utilisateur. **Embarquée** dans `docker-rootless.sh` (copie identique, heredoc) et installée dans `~/.local/bin/` du compte cible (propriétaire = l'utilisateur, mode 0755). Peut aussi être lancée seule par l'utilisateur. |

Ciblé et testé sur : Debian 13 « trixie », systemd 257, cgroup v2, noyau 6.12.

Sources (documentation officielle Docker), citées dans les commentaires des scripts :

- **[R]** Rootless mode — https://docs.docker.com/engine/security/rootless/
- **[D]** Install Docker Engine on Debian — https://docs.docker.com/engine/install/debian/
- **[RT]** Rootless troubleshooting — https://docs.docker.com/engine/security/rootless/troubleshoot/

## Usage

```bash
# Le cas normal : depuis le compte qui utilisera Docker (sudo demande le mot de passe)
./docker-rootless.sh

# Mode guidé : en root sur une machine neuve, ce qui manque est demandé
# (compte, création, mot de passe, clé SSH, groupe sudo), puis confirmé
sudo ./docker-rootless.sh

# Choisir le compte explicitement (obligatoire en non-interactif s'il y a plusieurs comptes)
sudo ./docker-rootless.sh --user admin

# Machine neuve, tout fourni : aucune question. En script, mot de passe par stdin :
printf '%s\n' "$MDP" | sudo ./docker-rootless.sh --user admin --create-user --sudo \
    --password-stdin --ssh-key ~/.ssh/id_ed25519.pub --yes

# Voir tout ce qui serait fait, sans rien écrire ni redémarrer (les deux parties)
./docker-rootless.sh --dry-run

# Relancer seulement la partie utilisateur (en tant que l'utilisateur, sans sudo)
~/.local/bin/docker-rootless-user.sh
```

### Mode guidé : « soit tout est fourni, soit on vous demande »

- **Tout est fourni** par les options : aucune question, exécution directe.
- **Il manque une valeur et un terminal est disponible** : elle est demandée, la valeur
  par défaut entre crochets (`[o/N]`, `[O/n]` : la majuscule est le défaut, `Entrée`
  l'accepte). Les questions sont lues sur `/dev/tty`, jamais sur l'entrée standard (qui
  peut porter `--password-stdin`).
- **Sans terminal** : auto-détection quand elle existe, sinon arrêt net avec un message qui
  dit quelle option passer. Aucune valeur n'est inventée.
- **`--yes` (`-y`)** : aucune question ni confirmation, valeurs par défaut retenues (pour
  l'automatisation). Les défauts restent prudents : pas de création de compte sans
  `--create-user`, pas de clé SSH ni de groupe `sudo` sans option ; seul le mot de passe
  d'un compte créé, sans option de mot de passe, est saisi par `passwd` si un terminal
  existe (sinon arrêt, comme sans `--yes`).

Questions posées, uniquement si la réponse manque, dans cet ordre :

1. **Compte cible** — si ni `--user`, ni `$SUDO_USER`, ni compte unique ne le détermine :
   liste numérotée des comptes humains, ou saisie d'un nom (un nom nouveau mène à la
   question suivante).
2. **Création** — « Le compte X n'existe pas. Le créer (adduser) ? [o/N] ».
3. **Mot de passe** du compte créé — « Définir un mot de passe maintenant ? [O/n] » : oui =
   saisie masquée par `passwd` ; non = compte verrouillé (clé SSH uniquement, `sudo`
   inutilisable). Supprimée par `--password`, `--password-stdin` ou `--no-password`.
4. **Clé SSH** du compte créé — « Ajouter une clé SSH publique ? [o/N] », puis collez la clé
   (`ssh-ed25519 AAAA…`) ou donnez le chemin d'un fichier `.pub` (`~` = le HOME de
   l'administrateur qui a lancé `sudo`). Supprimée par `--ssh-key`.
5. **Groupe sudo** du compte créé — « Ajouter au groupe sudo ? [o/N] ». Supprimée par `--sudo`.

Ensuite, si au moins une question a été posée, un **récapitulatif** des choix est affiché
et « Appliquer ? [O/n] » est demandé ; `n` arrête le script avant toute modification. En
`--dry-run`, les questions sont posées (elles alimentent la simulation) mais rien n'est écrit.

### Compte cible

Choix du compte cible, dans l'ordre : `--user NOM` → `$SUDO_USER` s'il est un compte
humain → l'utilisateur courant (dry-run sans root) → l'unique compte humain s'il n'y en a
qu'un → question sur le terminal (liste numérotée ou nom). Sans terminal et sans choix
possible, le script s'arrête avec `[x] Mode non interactif et compte cible ambigu … : précisez --user NOM.`
Un « compte humain » a un UID entre `UID_MIN` et `UID_MAX` (`/etc/login.defs`) et un shell
listé dans `/etc/shells` (ni `nologin` ni `false`).

Si le compte désigné est **inexistant**, le script propose de le créer (question posée
sur le terminal, réponse par défaut : non). En non-interactif il faut `--create-user` ;
`--no-create-user` refuse explicitement. Le compte est créé par `adduser --disabled-password`.

**Clé SSH du compte créé** — fournie par `--ssh-key` ou à la question : collage sur une
ligne, collage coupé en plusieurs lignes (recollé automatiquement), ou chemin d'un `.pub`.
Le format est vérifié (`ssh-ed25519`, `ssh-rsa`, `ecdsa-sha2-*`, `sk-ssh-*`/`sk-ecdsa-*`,
suivi d'un base64 dont le contenu doit correspondre au type annoncé) ; une clé tronquée,
une clé privée ou un autre texte est refusé avec un message et la question est reposée.
La clé est ajoutée à `~/.ssh/authorized_keys` **en tant que l'utilisateur** (`~/.ssh` en
0700, fichier en 0600), sans doublon (ligne entière comparée). Elle n'est installée que sur
un compte **créé par ce script** : l'accès d'un compte existant n'est jamais modifié
(`--ssh-key` est alors ignorée avec un avertissement). En `--dry-run`, la clé et le chemin
sont affichés (une clé publique n'est pas un secret), rien n'est écrit. Sans clé, pensez à
en ajouter une avant de compter vous connecter au compte.

**Mot de passe du compte créé** — une source est obligatoire, résolue avant toute
modification pour ne jamais laisser un compte à moitié fait :

- par défaut, il est **demandé sur le terminal** (question « Définir un mot de passe
  maintenant ? [O/n] », puis saisie masquée avec double vérification) ;
- `--password-stdin` le lit sur l'entrée standard — la forme recommandée en non-interactif,
  la valeur n'apparaît nulle part ;
- `--password MDP` l'accepte en paramètre : **déconseillé**, la valeur est visible dans
  `ps` pendant l'exécution, dans l'historique du shell et dans les journaux ;
- `--no-password` n'en définit aucun : le compte est verrouillé, connexion uniquement par
  clé SSH et `sudo` inutilisable pour lui.

En non-interactif, sans option de mot de passe, le script s'arrête **avant** de créer quoi que
ce soit. Le mot de passe n'est jamais journalisé ni affiché (récapitulatif : « défini » /
« aucun »).

`--sudo` (ou « oui » à la question) ajoute le compte créé au groupe `sudo` (non fait par
défaut, pour ne pas élever les privilèges sans le dire) ; il faut alors un mot de passe (ou
une règle `NOPASSWD`) pour que `sudo` soit réellement utilisable.

En `--dry-run` le compte n'est pas créé : l'UID affiché est une estimation, le mot de passe
n'est pas saisi (les questions, elles, sont posées), et la partie utilisateur n'est pas
simulée pour un compte absent.

### Options de `docker-rootless.sh`

| Option | Effet |
|---|---|
| `--user NOM` | Compte cible ; s'il n'existe pas, sa création est proposée. |
| `--create-user` | Crée le compte manquant sans demander. |
| `--no-create-user` | Ne crée jamais de compte : erreur claire s'il est absent. |
| `--sudo` | Si le compte est créé, l'ajouter au groupe `sudo` (non fait par défaut). |
| `--password MDP` | Mot de passe du compte créé, en paramètre (déconseillé : visible dans `ps`, l'historique et les journaux). |
| `--password-stdin` | Lit le mot de passe sur l'entrée standard (recommandé en non-interactif). |
| `--no-password` | Aucun mot de passe : compte verrouillé, clé SSH uniquement, `sudo` inutilisable. |
| `--ssh-key CLÉ\|FICHIER` | Clé publique SSH (texte ou fichier `.pub`) installée dans `~/.ssh/authorized_keys` du compte **créé** ; ignorée pour un compte existant. |
| `-y`, `--yes` | Aucune question ni confirmation : valeurs par défaut retenues (automatisation). |
| `--dry-run` | Affiche toutes les actions (admin + utilisateur) ; n'écrit rien, ne démarre rien. Sans root, il fait une inspection en lecture seule sans `sudo`. |
| `--no-test` | Ne lance pas `docker run --rm hello-world` (utile hors ligne). |
| `--keep-rootful-docker` | Ne désactive pas `docker.service`/`docker.socket` ; le setuptool est lancé avec `--force`. |
| `--apt-suite CODENAME` | Suite du dépôt Docker si `VERSION_CODENAME` n'y existe pas (Debian testing, dérivées), ex. `trixie`. Utilisé seulement si le dépôt doit être créé. |
| `--print-user-script` | Affiche le script utilisateur embarqué. |

### Options de `docker-rootless-user.sh`

`--dry-run`, `--no-test`, `--force` (passé au setuptool ; ajouté automatiquement si un
Docker rootful est actif). Codes de sortie : `0` = rootless **vérifié** (contexte,
Security Options, hello-world) ; `1` = échec ; `2` = session systemd utilisateur indisponible.

`docker-rootless.sh` renvoie le code de la partie utilisateur et imprime toujours un
récapitulatif (compte, socket, `DOCKER_HOST`, commandes de vérification).

Journalisation : `[+]` information/action, `[?]` question, `[!]` avertissement, `[x]` erreur.

## Ce que fait chaque étape

### Partie admin (`docker-rootless.sh`, root)

1. **Prérequis système** — `apt-get install` des paquets manquants seulement :
   - `uidmap` (`newuidmap`/`newgidmap`) — **obligatoire**, [R] « Prerequisites ».
   - `dbus-user-session` — **obligatoire en pratique** sur cgroup v2 : sans bus D-Bus
     utilisateur, `docker run` échoue (« connection reset by peer » sur `/run/systemd/private`),
     [RT] « docker run errors ».
   - `iptables` — vérifié de façon **bloquante** par `dockerd-rootless-setuptool.sh` (déjà présent sur trixie).
   - `slirp4netns` — **recommandé, non obligatoire** : c'est le pilote réseau par défaut
     de RootlessKit s'il est installé ; sinon `dockerd-rootless.sh` se rabat sur `pasta`,
     `vpnkit` puis `gvisor-tap-vsock` (intégré). Voir [RT] « Networking errors » et l'en-tête
     de `/usr/bin/dockerd-rootless.sh`.
   - `fuse-overlayfs` — **seulement si noyau < 5.11** : à partir de 5.11 le pilote `overlay2`
     fonctionne en rootless ([RT] « Known limitations »). Le setuptool le classe lui-même en
     « non essentiel » (TODO dans son code). Sur trixie (6.12) il n'est donc pas installé.
   - Vérifie cgroup v2 et `kernel.unprivileged_userns_clone` (mis à 1 dans
     `/etc/sysctl.d/50-rootless.conf` s'il vaut 0, instruction reprise du setuptool).
2. **`/etc/subuid` / `/etc/subgid`** — [R] « Prerequisites » : au moins 65 536 identifiants.
   Entrée présente et suffisante : rien. Présente mais < 65 536 : **avertissement, pas de
   modification**. Absente : ajout via `usermod --add-subuids/--add-subgids` sur une plage
   libre située après la plus haute plage existante (les lignes des autres comptes ne sont
   jamais touchées).
3. **Docker CE depuis le dépôt APT officiel** — [D] « Install using the apt repository » :
   - Refuse de continuer si des paquets non officiels en conflit sont installés
     (`docker.io`, `podman-docker`, `containerd`, `runc`…, [D] « Uninstall old versions ») :
     la suppression est destructive, elle est laissée à l'humain avec la commande exacte.
   - Si un fichier de `/etc/apt/sources.list*` référence déjà `download.docker.com/linux/debian`,
     **il n'est pas réécrit** ; on vérifie seulement que la clé `Signed-By` existe
     (re-téléchargée si c'est `/etc/apt/keyrings/docker.asc`).
   - Sinon : clé dans `/etc/apt/keyrings/docker.asc`, fichier deb822
     `/etc/apt/sources.list.d/docker.sources` avec `Signed-By:` — exactement comme la doc.
   - Installe uniquement les paquets absents, en état `rc` (supprimé, configuration
     restante — réinstallé normalement par `apt-get install`) ou cassés (`dpkg --configure -a`) :
     `docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras`.
4. **Docker rootful** — [R] « Install » (note) : si `docker.service`/`docker.socket` est
   actif ou activé, `systemctl disable --now docker.service docker.socket` puis
   `rm -f /var/run/docker.sock`. Un socket orphelin (reste d'une désinstallation, aucun
   démon) est simplement supprimé. Avec `--keep-rootful-docker`, rien n'est touché et la
   partie utilisateur reçoit `--force`. Note : le postinst de `docker-ce` démarre le démon
   rootful à l'installation ; c'est pour cela que cette étape vient après l'étape 3.
5. **Linger et gestionnaire systemd** — `loginctl enable-linger <user>` ([R] « Install »,
   [RT] « The daemon does not start up automatically ») puis `systemctl start user@<uid>.service`
   et attente de `/run/user/<uid>/bus`. C'est ce qui rend `systemctl --user` utilisable sans
   que personne ne soit connecté.
6. **Script utilisateur** — écrit `~/.local/bin/docker-rootless-user.sh` **en tant que
   l'utilisateur** (propriétaire correct, aucun suivi de lien symbolique avec les droits root
   dans un répertoire qu'il contrôle), seulement s'il diffère, puis l'exécute :
   `runuser -u <user> -- env -i HOME=… XDG_RUNTIME_DIR=/run/user/<uid> DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/<uid>/bus …`.

### Partie utilisateur (`docker-rootless-user.sh`)

0. Refuse root ; reconstruit `XDG_RUNTIME_DIR`/`DBUS_SESSION_BUS_ADDRESS` s'ils manquent ;
   vérifie `newuidmap`, sous-UID/GID, setuptool, `dockerd`, `docker`.
1. Vérifie `systemctl --user` ([RT] « Failed to connect to bus »). S'il ne répond pas :
   tente `loginctl enable-linger $USER` (autorisé par polkit pour son propre compte dans
   une session active), sinon affiche les trois actions correctives et sort avec le code `2`.
   Démarre `dbus.socket` utilisateur s'il est inactif ([RT] « docker run errors »).
2. `dockerd-rootless-setuptool.sh install` (+ `--force` si un rootful est actif, c.-à-d. service
   actif ou `/var/run/docker.sock` accessible en écriture — la condition exacte du setuptool).
   Idempotent : le setuptool saute l'unité et le contexte `rootless` s'ils existent.
3. Ajoute dans `~/.bashrc` **et** `~/.profile`, dans un bloc balisé, seulement les lignes
   absentes ([R] « Install ») :
   ```sh
   export PATH=/usr/bin:$PATH
   export DOCKER_HOST=unix:///run/user/$(id -u)/docker.sock
   ```
4. `systemctl --user enable --now docker.service`, attente du socket `/run/user/<uid>/docker.sock`.
5. **Vérification réelle** ([R] fin de « Install ») :
   - `docker info` sans `DOCKER_HOST` → `Context: rootless` ;
   - `docker -H unix:///run/user/<uid>/docker.sock info` → `rootless` dans les Security Options ;
   - `docker run --rm hello-world` → doit afficher « Hello from Docker! » (sauf `--no-test`).
   Le code de sortie est non nul si l'un de ces contrôles échoue.

## Cas limites connus

- **`Context: default` au lieu de `rootless`** : la variable `DOCKER_HOST`, que la doc
  recommande d'exporter, **prime sur le contexte CLI** ; `docker info` affiche alors
  `Context: default` tout en parlant bien au démon rootless. C'est pourquoi la vérification
  contrôle le contexte sans `DOCKER_HOST`, puis le démon via le socket explicite.
- **cgroup v2** : nécessaire (avec systemd) pour que `--cpus`, `--memory`, `--pids-limit`
  fonctionnent en rootless ; en cgroup v1 ils sont ignorés ([RT]). Le script le signale.
  Sur cgroup v2, l'absence du bus D-Bus utilisateur casse `docker run` → `dbus-user-session`.
- **Docker rootful encore actif** : désactivé par défaut (doc) ; `--keep-rootful-docker` le
  conserve et force le setuptool. Les deux démons coexistent alors : `docker` utilise le
  contexte `rootless`/`DOCKER_HOST`, `sudo docker` le rootful. Ses règles iptables peuvent
  gêner certains pilotes réseau ([RT] « Network is slow »).
- **Socket rootful orphelin** : un `/var/run/docker.sock` sans démon (cas d'un `docker-ce`
  désinstallé) ne bloque pas le setuptool tant qu'il n'est pas inscriptible par l'utilisateur ;
  la partie admin le supprime.
- **Session systemd absente** (`su`, `sudo -iu`, cron…) : `systemctl --user` échoue avec
  « Failed to connect to bus ». Le script admin la crée (linger + `user@<uid>.service`) ;
  lancé seul, le script utilisateur l'explique et sort en code 2 au lieu d'échouer en silence.
  Pour un shell interactif correct sous un autre compte : `ssh user@localhost` ou
  `sudo machinectl shell user@` (paquet `systemd-container`) ([RT]).
- **Ports < 1024** : interdits en rootless par défaut ; voir [RT] « cannot expose privileged
  port » (`net.ipv4.ip_unprivileged_port_start`). Non modifié par le script (choix de sécurité).
- **`ping` dans les conteneurs** : dépend de `net.ipv4.ping_group_range` ([RT]). Non modifié.
- **Debian testing / dérivées** : si le dépôt doit être créé et que `VERSION_CODENAME`
  n'existe pas chez Docker, utiliser `--apt-suite trixie` ([D], note).
- **`~/.local/share/docker` sur NFS** : non supporté ([RT]) ; définir `data-root` dans
  `~/.config/docker/daemon.json`.
- **`hello-world`** nécessite l'accès à Docker Hub ; hors ligne, utiliser `--no-test`.
- **Sous-UID < 65 536** existants : laissés tels quels (avertissement), à corriger à la main.

## Sécurité

Aucun secret ni mot de passe dans les scripts ou sur une ligne de commande (le mot de
passe éventuel est demandé par `sudo` lui-même). Les opérations destructives (désactivation
du démon rootful, suppression du socket) sont annoncées et visibles en `--dry-run` ; la
suppression de paquets en conflit n'est jamais automatique.

## Maintenance

Le script utilisateur est embarqué dans `docker-rootless.sh` entre les marqueurs
`__DOCKER_ROOTLESS_USER_SH__`. Après modification de `docker-rootless-user.sh`, recopier son
contenu entre ces marqueurs et vérifier :

```bash
diff <(./docker-rootless.sh --print-user-script) docker-rootless-user.sh && echo identique
bash -n docker-rootless.sh && bash -n docker-rootless-user.sh
```
