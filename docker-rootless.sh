#!/usr/bin/env bash
# docker-rootless.sh — installation Docker en mode ROOTLESS sur Debian, point d'entrée unique.
#
#   ./docker-rootless.sh [--user NOM] [--yes] [--dry-run] [--no-test] [--keep-rootful-docker]
#
# Fait la partie ADMIN (root, ré-élévation sudo automatique), puis installe et
# exécute la partie UTILISATEUR (docker-rootless-user.sh, embarquée plus bas)
# sous le compte cible, sans seconde session.
#
# Références (documentation officielle Docker) :
#   [R]  https://docs.docker.com/engine/security/rootless/
#   [D]  https://docs.docker.com/engine/install/debian/
#   [RT] https://docs.docker.com/engine/security/rootless/troubleshoot/
set -euo pipefail

PROG="docker-rootless.sh"
ORIG_ARGS=("$@")
TARGET_USER=""
DRY_RUN=0
NO_TEST=0
KEEP_ROOTFUL=0
APT_SUITE=""
USER_FORCE=0
# Création du compte cible : auto = proposer si un terminal est disponible,
# toujours = créer sans demander, jamais = refuser (défaut : auto).
CREATE_USER="auto"
ADD_SUDO=0          # --sudo : ajoute au groupe sudo le compte créé
CREATE_NEW=0        # interne : le compte cible n'existe pas encore
# Mot de passe du compte créé : soit fourni (--password/--password-stdin), soit
# demandé sur le terminal, soit explicitement désactivé (--no-password).
PASSWORD=""                 # valeur de --password (visible dans ps : avertissement)
PASSWORD_STDIN=0            # --password-stdin : lu sur l'entrée standard
NO_PASSWORD=0               # --no-password : compte verrouillé, clé SSH uniquement
# Mode guidé : ce qui manque est demandé sur le terminal (fd 3 = /dev/tty) ;
# --yes n'interroge jamais et retient les valeurs par défaut.
ASSUME_YES=0        # --yes / -y
INTERACTIVE=0       # interne : 1 = questions possibles
ASKED=0             # interne : nombre de questions posées (récapitulatif si > 0)
SSH_KEY=""          # clé publique à installer sur le compte créé (pas un secret)
SSH_KEY_ARG=""      # --ssh-key : clé ou chemin de fichier .pub (supprime la question)

# [D] « Install using the apt repository », étape 2 (+ docker-ce-rootless-extras, [R] « With packages »).
DOCKER_PKGS=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras)
# [D] « Uninstall old versions » : paquets non officiels en conflit.
CONFLICT_PKGS=(docker.io docker-compose docker-doc docker-buildx podman-docker containerd runc)
DOCKER_KEY=/etc/apt/keyrings/docker.asc
DOCKER_SOURCES=/etc/apt/sources.list.d/docker.sources
DOCKER_GPG_SRC=""            # --docker-key-file : cle GPG fournie localement (machine filtree)
USER_SCRIPT_NAME=docker-rootless-user.sh

# util-linux fournit runuser dans /usr/sbin, qui ne figure pas dans tous les PATH
# (env -i, cron, shells non-login) : on le résout une fois au lieu de dépendre du PATH.
RUNUSER=""
for _c in /usr/sbin/runuser /sbin/runuser /usr/bin/runuser; do
    [[ -x "$_c" ]] && { RUNUSER="$_c"; break; }
done
if [[ -z "$RUNUSER" ]]; then
    RUNUSER="$(command -v runuser 2>/dev/null || true)"
fi

log()  { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
err()  { printf '[x] %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }
step() { printf '\n[+] ==== %s ====\n' "$*"; }

# Vérifié ici, une fois die() définie : sans runuser, la partie utilisateur ne peut
# pas être exécutée sous le compte cible.
if [[ $EUID -eq 0 && -z "$RUNUSER" ]]; then
    die "runuser introuvable (paquet util-linux) : nécessaire pour exécuter la partie utilisateur."
fi

# Exécute une commande, ou l'affiche seulement en --dry-run.
run() {
    if (( DRY_RUN )); then
        printf '[+] (dry-run) %s\n' "$*"
    else
        "$@"
    fi
}

usage() {
    cat <<EOF
Usage: $PROG [options]

Installe Docker en mode rootless pour un utilisateur (Debian).
Lancé en non-root, le script se ré-élève via sudo.

Options :
  --user NOM              Compte cible (défaut : \$SUDO_USER, sinon l'unique
                          compte humain, sinon choix interactif). S'il n'existe
                          pas, sa création est proposée (voir --create-user).
  --create-user           Crée le compte s'il n'existe pas, sans demander.
  --no-create-user        Ne crée jamais de compte : échec clair s'il est absent.
  --sudo                  Si le compte est créé, l'ajouter au groupe sudo.
  --password MDP          Mot de passe du compte créé. ATTENTION : cette valeur est
                          visible dans « ps », l'historique du shell et les logs du
                          système ; préférez --password-stdin ou la saisie masquée.
  --password-stdin        Lit le mot de passe sur l'entrée standard (première ligne),
                          sans qu'il apparaisse nulle part, par exemple :
                            printf '%s\n' "\$MDP" | sudo ./docker-rootless.sh --user NOM --create-user --password-stdin
  --no-password           Ne définit aucun mot de passe (compte verrouillé : connexion
                          uniquement par clé SSH, sudo inutilisable).
  Sans option de mot de passe, il est demandé sur le terminal à la création du compte
  (saisie masquée, double vérification par passwd).
  --ssh-key CLÉ|FICHIER   Clé publique SSH (« ssh-ed25519 AAAA… » ou fichier .pub) à
                          installer dans ~/.ssh/authorized_keys du compte CRÉÉ
                          (ignorée pour un compte existant).
  -y, --yes               Aucune question : valeurs par défaut retenues, pas de
                          confirmation (automatisation). Ne crée pas de compte sans
                          --create-user et n'invente aucune valeur.
  Mode guidé : avec un terminal, ce qui manque (compte, création, mot de passe, clé
  SSH du compte créé, groupe sudo) est demandé, défaut entre crochets (Entrée =
  défaut), puis un récapitulatif est soumis à confirmation avant toute modification.
  --dry-run              Affiche tout ce qui serait fait (parties admin et
                          utilisateur) ; n'écrit rien, ne (re)démarre rien.
  --no-test               Ne lance pas « docker run --rm hello-world ».
  --keep-rootful-docker   Ne désactive pas le Docker rootful (docker.service) ;
                          le setuptool est alors lancé avec --force.
  --apt-suite CODENAME    Suite du dépôt Docker si VERSION_CODENAME n'y existe
                          pas (Debian testing/dérivées), ex. : trixie.
  --docker-key-file FICH  Cle GPG du depot Docker deja telechargee (machine sans
                          acces a download.docker.com). Copie typique :
                          /etc/apt/keyrings/docker.asc d'une machine qui y accede.
  --print-user-script     Affiche le script utilisateur embarqué et quitte.
  -h, --help              Cette aide.
EOF
}

# ---------------------------------------------------------------------------
# Script utilisateur embarqué (copie conforme de docker-rootless-user.sh)
# ---------------------------------------------------------------------------
user_script_content() {
    cat <<'__DOCKER_ROOTLESS_USER_SH__'
#!/usr/bin/env bash
# docker-rootless-user.sh — partie UTILISATEUR de l'installation Docker rootless (Debian).
#
# À lancer sous le compte non-root qui fera tourner Docker. Normalement exécuté
# automatiquement par docker-rootless.sh (installé dans ~/.local/bin/), mais
# fonctionne aussi seul :  ~/.local/bin/docker-rootless-user.sh [--dry-run]
#
# Références (documentation officielle Docker) :
#   [R]  https://docs.docker.com/engine/security/rootless/
#   [RT] https://docs.docker.com/engine/security/rootless/troubleshoot/
set -euo pipefail

PROG="docker-rootless-user.sh"
DRY_RUN=0
NO_TEST=0
FORCE=0

SETUPTOOL=/usr/bin/dockerd-rootless-setuptool.sh
ENV_MARK_BEGIN="# >>> docker rootless (docker-rootless-user.sh) >>>"
ENV_MARK_END="# <<< docker rootless (docker-rootless-user.sh) <<<"
# Lignes exactes recommandées par [R] « Install / With packages ». Écrites
# littéralement : $PATH et $(id -u) sont évalués à l'ouverture du shell.
# shellcheck disable=SC2016
ENV_LINES=(
    'export PATH=/usr/bin:$PATH'
    'export DOCKER_HOST=unix:///run/user/$(id -u)/docker.sock'
)

log()  { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
err()  { printf '[x] %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

# Exécute une commande, ou l'affiche seulement en --dry-run.
run() {
    if (( DRY_RUN )); then
        printf '[+] (dry-run) %s\n' "$*"
    else
        "$@"
    fi
}

usage() {
    cat <<EOF
Usage: $PROG [options]

Partie utilisateur de l'installation Docker rootless (à lancer SANS sudo).

Options :
  --dry-run   Affiche ce qui serait fait, n'écrit rien, ne démarre rien.
  --no-test   Ne lance pas « docker run --rm hello-world » à la fin.
  --force     Passe --force à dockerd-rootless-setuptool.sh (Docker rootful
              encore actif). Détecté automatiquement si le service tourne.
  -h, --help  Cette aide.

Codes de sortie : 0 = rootless vérifié et fonctionnel ; 1 = échec ;
                  2 = session systemd utilisateur indisponible.
EOF
}

while (( $# )); do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --no-test) NO_TEST=1 ;;
        --force)   FORCE=1 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "Option inconnue : $1" ;;
    esac
    shift
done

# ---------------------------------------------------------------------------
# 0. Contexte
# ---------------------------------------------------------------------------
# [R] « Install » : le setuptool doit être lancé en non-root ; il refuse root.
(( EUID != 0 )) || die "Ne pas lancer ce script en root. Utilisez docker-rootless.sh (qui l'exécute sous le bon compte)."

USER_NAME="$(id -un)"
USER_UID="$(id -u)"
: "${HOME:?HOME doit être défini}"
(( DRY_RUN )) && log "Mode --dry-run : aucune modification ne sera faite."
log "Utilisateur : $USER_NAME (uid $USER_UID), HOME=$HOME"

# [RT] « could not get XDG_RUNTIME_DIR » / « Failed to connect to bus » :
# sur un hôte systemd, la session utilisateur expose /run/user/<uid> et le bus.
# Si on arrive via runuser/sudo, ces variables manquent : on les reconstruit.
if [[ -z "${XDG_RUNTIME_DIR:-}" && -d "/run/user/$USER_UID" ]]; then
    export XDG_RUNTIME_DIR="/run/user/$USER_UID"
fi
if [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" && -n "${XDG_RUNTIME_DIR:-}" && -S "$XDG_RUNTIME_DIR/bus" ]]; then
    export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
fi
SOCK_PATH="/run/user/$USER_UID/docker.sock"
DOCKER_HOST_URL="unix://$SOCK_PATH"

systemd_user_ok() {
    [[ -n "${XDG_RUNTIME_DIR:-}" && -w "${XDG_RUNTIME_DIR}" ]] \
        && systemctl --user show-environment >/dev/null 2>&1
}

print_systemd_fix() {
    err "La session systemd utilisateur n'est pas disponible (systemctl --user)."
    err "Cause habituelle : changement d'utilisateur par 'su'/'sudo -iu' sans pam_systemd [RT]."
    err "Action corrective (une seule suffit) :"
    err "  1) sudo ./docker-rootless.sh --user $USER_NAME   (script admin : linger + user@$USER_UID, puis relance ce script)"
    err "  2) sudo loginctl enable-linger $USER_NAME && sudo systemctl start user@$USER_UID.service"
    err "     puis : export XDG_RUNTIME_DIR=/run/user/$USER_UID && $0"
    err "  3) se connecter via 'ssh $USER_NAME@localhost' ou 'sudo machinectl shell $USER_NAME@' et relancer $0"
}

# ---------------------------------------------------------------------------
# 1. Pré-vérifications (lecture seule)
# ---------------------------------------------------------------------------
missing=0
# [R] « Prerequisites » : newuidmap/newgidmap (paquet uidmap).
if ! command -v newuidmap >/dev/null 2>&1 || ! command -v newgidmap >/dev/null 2>&1; then
    err "newuidmap/newgidmap absents (paquet 'uidmap')."; missing=1
fi
# [R] « Prerequisites » : >= 65536 sous-UID/GID.
for f in /etc/subuid /etc/subgid; do
    n="$(awk -F: -v u="$USER_NAME" -v i="$USER_UID" '($1==u||$1==i){s+=$3} END{print s+0}' "$f" 2>/dev/null || echo 0)"
    if (( n == 0 )); then
        err "Aucune entrée pour $USER_NAME dans $f."; missing=1
    elif (( n < 65536 )); then
        warn "$f : seulement $n identifiants pour $USER_NAME (< 65536) : certaines images échoueront (« lchown … invalid argument », [RT] docker pull errors)."
    else
        log "$f : $n identifiants subordonnés pour $USER_NAME."
    fi
done
# [R] « With packages » : setuptool fourni par docker-ce-rootless-extras.
if [[ ! -x "$SETUPTOOL" ]]; then
    err "$SETUPTOOL absent : installer 'docker-ce-rootless-extras' ([R] « With packages »)."; missing=1
fi
# Le setuptool lance dockerd (docker-ce) et crée le contexte CLI avec docker (docker-ce-cli).
for b in dockerd docker; do
    command -v "$b" >/dev/null 2>&1 || { err "Binaire '$b' absent (paquets docker-ce / docker-ce-cli)."; missing=1; }
done
if (( missing )); then
    if (( DRY_RUN )); then
        warn "Prérequis manquants (normal en --dry-run si la partie admin n'a pas encore tourné)."
    else
        die "Prérequis manquants. Lancez d'abord la partie admin : sudo docker-rootless.sh --user $USER_NAME"
    fi
fi

# [R] « Install » (note) : si le démon rootful tourne encore, il faut --force.
# Le setuptool n'abandonne que si /var/run/docker.sock est accessible en écriture.
if (( ! FORCE )); then
    if systemctl is-active --quiet docker.service 2>/dev/null \
       || systemctl is-active --quiet docker.socket 2>/dev/null \
       || [[ -w /var/run/docker.sock ]]; then
        warn "Un Docker rootful est actif (docker.service/docker.socket ou /var/run/docker.sock accessible) : ajout de --force."
        FORCE=1
    elif [[ -S /var/run/docker.sock ]]; then
        warn "/var/run/docker.sock existe mais aucun démon rootful actif (socket orphelin, sans effet ici ; 'sudo rm -f /var/run/docker.sock')."
    fi
fi

# ---------------------------------------------------------------------------
# 2. Session systemd utilisateur ([RT] « Failed to connect to bus »)
# ---------------------------------------------------------------------------
if systemd_user_ok; then
    log "Session systemd utilisateur disponible (XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR)."
else
    # Tentative corrective sans mot de passe : polkit autorise souvent
    # un utilisateur à activer son propre linger (set-self-linger).
    if (( DRY_RUN )); then
        warn "Session systemd utilisateur indisponible (attendu en --dry-run avant la partie admin)."
        log "(dry-run) loginctl enable-linger $USER_NAME   # tentative corrective"
    else
        warn "Session systemd utilisateur indisponible : tentative 'loginctl enable-linger $USER_NAME'."
        if loginctl --no-ask-password enable-linger "$USER_NAME" 2>/dev/null; then
            for _ in $(seq 1 20); do
                [[ -d "/run/user/$USER_UID" ]] && break
                sleep 0.5
            done
            export XDG_RUNTIME_DIR="/run/user/$USER_UID"
            [[ -S "$XDG_RUNTIME_DIR/bus" ]] && export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
        fi
        if ! systemd_user_ok; then
            print_systemd_fix
            exit 2
        fi
        log "Session systemd utilisateur disponible après correction."
    fi
fi

# [RT] « docker run errors » (cgroup v2) : le bus D-Bus utilisateur doit tourner.
if (( ! DRY_RUN )) && ! systemctl --user is-active --quiet dbus.socket 2>/dev/null; then
    warn "dbus.socket utilisateur inactif : 'systemctl --user start dbus.socket' ([RT])."
    systemctl --user start dbus.socket || warn "Impossible de démarrer dbus.socket (paquet dbus-user-session installé ?)."
fi

# ---------------------------------------------------------------------------
# 3. dockerd-rootless-setuptool.sh install ([R] « Install / With packages »)
#    Idempotent : le setuptool saute l'unité et le contexte s'ils existent.
# ---------------------------------------------------------------------------
setup_args=(install)
(( FORCE )) && setup_args+=(--force)
log "Installation du démon rootless : $SETUPTOOL ${setup_args[*]}"
if (( DRY_RUN )); then
    run "$SETUPTOOL" "${setup_args[@]}"
    if [[ -x "$SETUPTOOL" ]] && systemd_user_ok; then
        log "(dry-run) vérification des prérequis par le setuptool : $SETUPTOOL check"
        "$SETUPTOOL" check || warn "Le setuptool signale des prérequis manquants (voir ci-dessus)."
    fi
else
    "$SETUPTOOL" "${setup_args[@]}" || die "dockerd-rootless-setuptool.sh install a échoué (journal : journalctl --user -u docker.service -n 50 --no-pager)."
fi

# ---------------------------------------------------------------------------
# 4. Variables d'environnement dans ~/.bashrc et ~/.profile, sans doublon
#    ([R] « Install » : « Make sure the following environment variable(s) are set »)
# ---------------------------------------------------------------------------
add_env_block() {
    local file="$1" line missing_lines=()
    for line in "${ENV_LINES[@]}"; do
        if [[ -f "$file" ]] && grep -Fxq -- "$line" "$file"; then
            continue
        fi
        missing_lines+=("$line")
    done
    if (( ${#missing_lines[@]} == 0 )); then
        log "$file : variables déjà présentes, rien à faire."
        return 0
    fi
    if (( DRY_RUN )); then
        log "(dry-run) ajout dans $file : ${missing_lines[*]}"
        return 0
    fi
    {
        printf '\n%s\n' "$ENV_MARK_BEGIN"
        printf '%s\n' "${missing_lines[@]}"
        printf '%s\n' "$ENV_MARK_END"
    } >>"$file"
    log "$file : ajouté ${missing_lines[*]}"
}
add_env_block "$HOME/.bashrc"
add_env_block "$HOME/.profile"

# ---------------------------------------------------------------------------
# 5. systemctl --user enable --now docker.service
#    ([R] « Install » : « To control docker.service… »)
# ---------------------------------------------------------------------------
log "Activation du service : systemctl --user enable --now docker.service"
if (( DRY_RUN )); then
    run systemctl --user enable --now docker.service
else
    systemctl --user enable --now docker.service \
        || die "Échec de 'systemctl --user enable --now docker.service' (journalctl --user -u docker.service -n 50 --no-pager)."
    for _ in $(seq 1 60); do
        [[ -S "$SOCK_PATH" ]] && break
        sleep 0.5
    done
    [[ -S "$SOCK_PATH" ]] || die "Le socket $SOCK_PATH n'est pas apparu (journalctl --user -u docker.service -n 50 --no-pager)."
    log "Socket présent : $SOCK_PATH"
fi

# [RT] « The daemon does not start up automatically » : il faut le linger.
if [[ -e "/var/lib/systemd/linger/$USER_NAME" ]]; then
    log "Linger actif : le démon démarrera au boot."
else
    warn "Linger inactif : le démon ne démarrera pas au boot. Correctif : sudo loginctl enable-linger $USER_NAME"
fi

# ---------------------------------------------------------------------------
# 6. Vérification réelle ([R] fin de « Install » : docker info)
# ---------------------------------------------------------------------------
if (( DRY_RUN )); then
    log "(dry-run) env -u DOCKER_HOST docker info   -> attendu : Context: rootless"
    log "(dry-run) docker -H $DOCKER_HOST_URL info   -> attendu : 'rootless' dans Security Options"
    (( NO_TEST )) || run docker -H "$DOCKER_HOST_URL" run --rm hello-world
    log "Dry-run utilisateur terminé."
    exit 0
fi

export PATH="/usr/bin:$PATH"
fail=0
# Contexte CLI : le setuptool crée et sélectionne « rootless ». DOCKER_HOST, s'il
# est défini, prime sur le contexte (le CLI afficherait alors « default ») : on
# l'enlève pour contrôler le contexte, puis on interroge explicitement le socket.
# `docker info` aligne la valeur avec des espaces : on les retire, sinon la
# comparaison echoue alors que le contexte est correct («    rootless »).
ctx="$(env -u DOCKER_HOST docker info 2>/dev/null \
    | awk -F: '/^[[:space:]]*Context:/{gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); print $2; exit}')"
if [[ "$ctx" == "rootless" ]]; then
    log "docker info : Context: rootless"
else
    err "docker info : contexte '${ctx:-?}' au lieu de 'rootless' (docker context use rootless)."; fail=1
fi
secopts="$(docker -H "$DOCKER_HOST_URL" info --format '{{range .SecurityOptions}}{{.}} {{end}}' 2>&1)" || {
    err "docker info sur $DOCKER_HOST_URL a échoué : $secopts"; fail=1; secopts=""
}
if [[ " $secopts " == *"name=rootless"* ]]; then
    log "docker info : Security Options contient 'rootless' ($secopts)"
else
    err "docker info : 'rootless' absent des Security Options (${secopts:-vide})."; fail=1
fi
cgdrv="$(docker -H "$DOCKER_HOST_URL" info --format '{{.CgroupDriver}} / cgroup v{{.CgroupVersion}}' 2>/dev/null || true)"
[[ -n "$cgdrv" ]] && log "docker info : cgroup $cgdrv"

if (( ! NO_TEST && ! fail )); then
    log "Test : docker run --rm hello-world"
    if out="$(docker -H "$DOCKER_HOST_URL" run --rm hello-world 2>&1)" && grep -q "Hello from Docker!" <<<"$out"; then
        log "hello-world : OK"
    else
        printf '%s\n' "$out" >&2
        err "docker run --rm hello-world a échoué."; fail=1
    fi
elif (( NO_TEST )); then
    log "Test hello-world sauté (--no-test)."
fi

if (( fail )); then
    die "Vérification rootless ÉCHOUÉE. Voir [RT] et : journalctl --user -u docker.service -n 50 --no-pager"
fi
log "Docker rootless opérationnel pour $USER_NAME (DOCKER_HOST=$DOCKER_HOST_URL)."
exit 0
__DOCKER_ROOTLESS_USER_SH__
}

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
while (( $# )); do
    case "$1" in
        --user)       [[ $# -ge 2 && -n "$2" ]] || die "--user attend un nom"; TARGET_USER="$2"; shift ;;
        --user=*)     TARGET_USER="${1#--user=}" ;;
        --dry-run)    DRY_RUN=1 ;;
        --no-test)    NO_TEST=1 ;;
        --keep-rootful-docker) KEEP_ROOTFUL=1 ;;
        --create-user) CREATE_USER="always" ;;
        --no-create-user) CREATE_USER="never" ;;
        --sudo)       ADD_SUDO=1 ;;
        --password)   [[ $# -ge 2 ]] || die "--password attend une valeur"; PASSWORD="$2"; shift ;;
        --password=*) PASSWORD="${1#--password=}" ;;
        --password-stdin) PASSWORD_STDIN=1 ;;
        --no-password) NO_PASSWORD=1 ;;
        -y|--yes)     ASSUME_YES=1 ;;
        --ssh-key)    [[ $# -ge 2 && -n "$2" ]] || die "--ssh-key attend une clé publique ou un fichier .pub"; SSH_KEY_ARG="$2"; shift ;;
        --ssh-key=*)  SSH_KEY_ARG="${1#--ssh-key=}" ;;
        --apt-suite) [[ $# -ge 2 && -n "$2" ]] || die "--apt-suite attend un nom de suite"; APT_SUITE="$2"; shift ;;
        --apt-suite=*) APT_SUITE="${1#--apt-suite=}" ;;
        --docker-key-file) [[ $# -ge 2 && -n "$2" ]] || die "--docker-key-file attend un chemin"; DOCKER_GPG_SRC="$2"; shift ;;
        --docker-key-file=*) DOCKER_GPG_SRC="${1#--docker-key-file=}" ;;
        --print-user-script) user_script_content; exit 0 ;;
        -h|--help)    usage; exit 0 ;;
        *) usage >&2; die "Option inconnue : $1" ;;
    esac
    shift
done

# ---------------------------------------------------------------------------
# Ré-élévation
# ---------------------------------------------------------------------------
if (( EUID != 0 )); then
    if (( DRY_RUN )); then
        warn "Non-root + --dry-run : pas de sudo, inspection en lecture seule (rien n'est écrit de toute façon)."
    else
        self="$(readlink -f -- "${BASH_SOURCE[0]}" 2>/dev/null || true)"
        [[ -n "$self" && -f "$self" ]] || die "Impossible de localiser le script pour la ré-élévation : relancez avec 'sudo bash docker-rootless.sh'."
        command -v sudo >/dev/null 2>&1 || die "sudo absent : relancez ce script en root (su -c '$self')."
        log "Ré-élévation via sudo (le mot de passe est demandé par sudo, jamais passé en argument)."
        exec sudo -- "${BASH:-bash}" "$self" "${ORIG_ARGS[@]}"
    fi
fi

(( DRY_RUN )) && log "Mode --dry-run : aucune modification ne sera faite."
[[ -r /etc/debian_version ]] || warn "Ce script cible Debian ; /etc/debian_version introuvable."
[[ -z "$DOCKER_GPG_SRC" || -s "$DOCKER_GPG_SRC" ]] || die "--docker-key-file : fichier absent ou vide : $DOCKER_GPG_SRC"
command -v systemctl >/dev/null 2>&1 || die "systemd requis (systemctl introuvable)."

# ---------------------------------------------------------------------------
# Choix du compte cible
# ---------------------------------------------------------------------------
UID_MIN="$(awk '$1=="UID_MIN"{print $2}' /etc/login.defs 2>/dev/null)"; UID_MIN="${UID_MIN:-1000}"
UID_MAX="$(awk '$1=="UID_MAX"{print $2}' /etc/login.defs 2>/dev/null)"; UID_MAX="${UID_MAX:-60000}"

# Comptes humains : UID dans [UID_MIN, UID_MAX] et shell de connexion valide.
human_users() {
    local name uid shell
    while IFS=: read -r name _ uid _ _ _ shell; do
        (( uid >= UID_MIN && uid <= UID_MAX )) || continue
        case "$shell" in */nologin|*/false|"") continue ;; esac
        grep -Fxq -- "$shell" /etc/shells 2>/dev/null || continue
        printf '%s\n' "$name"
    done < <(getent passwd)
}
mapfile -t HUMANS < <(human_users)
is_human() { local u; for u in "${HUMANS[@]}"; do [[ "$u" == "$1" ]] && return 0; done; return 1; }
user_exists() { getent passwd "$1" >/dev/null 2>&1; }
valid_name()  { [[ "$1" =~ ^[a-z_][a-z0-9_-]*$ ]]; }
# Premier UID libre à partir d'UID_MIN : utilisé en --dry-run, avant la création.
next_free_uid() {
    local min u
    min="$(awk '$1=="UID_MIN"{print $2}' /etc/login.defs 2>/dev/null)"; min="${min:-1000}"
    u="$min"
    while getent passwd "$u" >/dev/null 2>&1; do u=$((u + 1)); done
    printf '%s' "$u"
}

# ---------------------------------------------------------------------------
# Questions (mode guidé) : lues sur le terminal, jamais sur stdin (qui peut
# porter --password-stdin). Rien n'est demandé avec --yes ni sans terminal.
# ---------------------------------------------------------------------------
if (( ! ASSUME_YES )) && [[ -t 0 || -t 2 ]] && { exec 3</dev/tty; } 2>/dev/null; then
    INTERACTIVE=1
fi

trim() {
    local s="${1//$'\r'/}"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# ask_yn QUESTION o|n : succès si oui. Entrée = défaut (en majuscule entre crochets).
ask_yn() {
    local q="$1" def="$2" hint rep
    if [[ "$def" == o ]]; then hint="O/n"; else hint="o/N"; fi
    ASKED=$((ASKED + 1))
    while :; do
        printf '[?] %s [%s] ' "$q" "$hint" >&2
        IFS= read -r rep <&3 || die "Lecture du terminal impossible."
        rep="$(trim "$rep")"; rep="${rep:-$def}"
        case "${rep,,}" in
            o|oui|y|yes) return 0 ;;
            n|non|no)    return 1 ;;
        esac
        warn "Répondez o (oui) ou n (non)."
    done
}

# Compte cible demandé : numéro de la liste ou nom (nouveau nom : création proposée ensuite).
ask_target_user() {
    local ans i
    ASKED=$((ASKED + 1))
    if (( ${#HUMANS[@]} )); then
        printf '[?] Compte cible à configurer :\n' >&2
        for i in "${!HUMANS[@]}"; do printf '    %d) %s\n' "$((i + 1))" "${HUMANS[$i]}" >&2; done
    else
        warn "Aucun compte humain (UID $UID_MIN-$UID_MAX avec shell) sur cette machine."
    fi
    while :; do
        if (( ${#HUMANS[@]} )); then
            printf '[?] Numéro, ou nom du compte (nouveau nom : création proposée) : ' >&2
        else
            printf '[?] Nom du compte à créer : ' >&2
        fi
        IFS= read -r ans <&3 || die "Lecture du terminal impossible."
        ans="$(trim "$ans")"
        if [[ "$ans" =~ ^[0-9]+$ ]] && (( ${#HUMANS[@]} )); then
            if (( ans >= 1 && ans <= ${#HUMANS[@]} )); then
                TARGET_USER="${HUMANS[$((ans - 1))]}"; return 0
            fi
        elif valid_name "$ans"; then
            if ! user_exists "$ans" || is_human "$ans"; then
                TARGET_USER="$ans"; return 0
            fi
            warn "'$ans' existe mais n'est pas un compte humain."
            continue
        fi
        warn "Choix invalide : '$ans'"
    done
}

# Clé publique SSH : « type base64 [commentaire] ». Le base64 doit se décoder en
# une suite exacte de champs SSH (longueur sur 4 octets + données) dont le premier
# est le type annoncé : une clé tronquée ou recollée de travers est refusée.
SSH_KEY_TYPES='ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com'
ssh_key_check() {
    local type b64 comment hex type_hex len pos=0 n=0 first=""
    read -r type b64 comment <<<"$1"
    [[ "$type" =~ ^($SSH_KEY_TYPES)$ ]] || return 1
    [[ "$b64" =~ ^[A-Za-z0-9+/]+={0,2}$ ]] || return 1
    (( ${#b64} % 4 == 0 )) || return 1
    hex="$(printf '%s' "$b64" | base64 -d 2>/dev/null | od -An -v -tx1 | tr -d ' \n')" || return 1
    while (( pos < ${#hex} )); do
        (( pos + 8 <= ${#hex} )) || return 1
        len=$((16#${hex:pos:8})); pos=$((pos + 8))
        (( pos + 2 * len <= ${#hex} )) || return 1
        if (( n == 0 )); then first="${hex:pos:2*len}"; fi
        pos=$((pos + 2 * len)); n=$((n + 1))
    done
    (( n >= 2 )) || return 1
    type_hex="$(printf '%s' "$type" | od -An -v -tx1 | tr -d ' \n')"
    [[ "$first" == "$type_hex" ]] || return 1
    printf '%s %s%s' "$type" "$b64" "${comment:+ $comment}"
}

# Recolle une clé coupée sur plusieurs lignes : à chaque coupure, essaie « rien »
# ou « une espace » (coupure dans le base64 ou entre deux champs), première
# combinaison valide retenue. Affiche la clé normalisée sur une ligne.
ssh_key_join() {
    local -a parts=("$@")
    local n=${#parts[@]} max=2 mask i cand
    (( n > 0 )) || return 1
    if (( n <= 8 )); then max=$((1 << (n - 1))); fi
    for (( mask = 0; mask < max; mask++ )); do
        cand="${parts[0]}"
        for (( i = 1; i < n; i++ )); do
            if (( n > 8 && mask == 1 )) || (( n <= 8 && (mask >> (i - 1)) & 1 )); then cand+=" "; fi
            cand+="${parts[i]}"
        done
        ssh_key_check "$cand" && return 0
    done
    return 1
}

# Lit une clé publique dans un fichier (~ = HOME de l'administrateur qui a lancé sudo).
ssh_key_from_file() {
    local f="$1" home="$HOME" line
    local -a lines=()
    if [[ -n "${SUDO_USER:-}" ]]; then
        home="$(getent passwd "$SUDO_USER" | cut -d: -f6)"; home="${home:-$HOME}"
    fi
    case "$f" in
        "~")   f="$home" ;;
        "~/"*) f="$home/${f#"~/"}" ;;
    esac
    if [[ ! -f "$f" || ! -r "$f" ]]; then
        warn "Fichier introuvable ou illisible : $f"; return 1
    fi
    if grep -q 'PRIVATE KEY' "$f" 2>/dev/null; then
        warn "$f est une clé PRIVÉE : elle ne doit jamais être copiée. Donnez la clé PUBLIQUE (fichier .pub)."; return 1
    fi
    if grep -q '^---- BEGIN SSH2 PUBLIC KEY' "$f" 2>/dev/null; then
        warn "$f est au format RFC 4716 : convertissez-le (ssh-keygen -i -f $f) puis collez le résultat."; return 1
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="$(trim "$line")"
        [[ -z "$line" || "$line" == "#"* ]] || lines+=("$line")
    done <"$f"
    if ! ssh_key_join "${lines[@]}"; then
        warn "$f : aucune clé publique valide (une seule clé attendue, format « type base64 [commentaire] »)."; return 1
    fi
}

# Demande la clé publique : collage (éventuellement coupé en plusieurs lignes)
# ou chemin d'un fichier .pub. Résultat dans SSH_KEY ; Entrée vide = aucune clé.
ask_ssh_key() {
    local first line key
    local -a lines
    while :; do
        printf "[?] Collez la clé publique (ssh-ed25519 AAAA…), ou le chemin d'un fichier .pub (Entrée vide : aucune clé) :\n" >&2
        IFS= read -r first <&3 || die "Lecture du terminal impossible."
        first="$(trim "$first")"
        if [[ -z "$first" ]]; then
            warn "Aucune clé SSH ajoutée."; SSH_KEY=""; return 0
        fi
        if [[ "$first" == *"PRIVATE KEY"* ]]; then
            # Le reste du collage (la clé privée) est jeté sans être affiché.
            while IFS= read -r -t 0.5 _ <&3; do :; done
            warn "Ceci est une clé PRIVÉE : elle ne doit jamais être collée ni copiée. Donnez la clé PUBLIQUE (.pub)."
            continue
        fi
        if [[ "$first" =~ ^(ssh-|ecdsa-|sk-) ]]; then
            lines=("$first")
            # Le reste d'un collage multiligne arrive immédiatement.
            while IFS= read -r -t 0.3 line <&3; do
                line="$(trim "$line")"
                [[ -n "$line" ]] || break
                lines+=("$line")
            done
            until key="$(ssh_key_join "${lines[@]}")"; do
                (( ${#lines[@]} < 20 )) || break
                printf '[?] Clé incomplète ou invalide : collez la suite (Entrée vide : recommencer) :\n' >&2
                IFS= read -r line <&3 || die "Lecture du terminal impossible."
                line="$(trim "$line")"
                [[ -n "$line" ]] || break
                lines+=("$line")
            done
            if [[ -z "${key:-}" ]]; then
                warn "Clé refusée : format attendu « type base64 [commentaire] », types ssh-ed25519, ssh-rsa, ecdsa-sha2-*, sk-ssh-* ; clé complète et non modifiée."
                continue
            fi
        elif [[ "$first" == [/~.]* || "$first" == *.pub || -f "$first" ]]; then
            key="$(ssh_key_from_file "$first")" || continue
        else
            warn "Ni une clé publique (ssh-ed25519 AAAA…, ssh-rsa, ecdsa-sha2-*, sk-ssh-*) ni un chemin de fichier : '$first'"
            continue
        fi
        SSH_KEY="$key"
        log "Clé retenue : $SSH_KEY"
        return 0
    done
}

# Compte inexistant : création selon --create-user / --no-create-user / question.
resolve_missing_user() {
    valid_name "$TARGET_USER" || die "--user '$TARGET_USER' : nom de compte invalide (attendu : [a-z_][a-z0-9_-]*)."
    case "$CREATE_USER" in
        never)
            die "Le compte '$TARGET_USER' n'existe pas et --no-create-user interdit sa création." ;;
        always)
            CREATE_NEW=1 ;;
        *)
            if (( INTERACTIVE )); then
                if ask_yn "Le compte $TARGET_USER n'existe pas. Le créer (adduser) ?" n; then
                    CREATE_NEW=1
                else
                    die "Création refusée. Créez le compte (adduser $TARGET_USER) puis relancez, ou utilisez --create-user."
                fi
            elif (( ASSUME_YES )); then
                die "Le compte '$TARGET_USER' n'existe pas et --yes ne le crée pas (réponse par défaut : non). Ajoutez --create-user."
            else
                die "Le compte '$TARGET_USER' n'existe pas. Relancez avec --create-user pour le créer, ou créez-le d'abord (adduser $TARGET_USER)."
            fi ;;
    esac
}

if [[ -n "$TARGET_USER" ]]; then
    if ! user_exists "$TARGET_USER"; then
        resolve_missing_user
    elif ! is_human "$TARGET_USER"; then
        die "--user '$TARGET_USER' existe mais n'est pas un compte humain (choix : ${HUMANS[*]:-aucun})."
    fi
elif [[ -n "${SUDO_USER:-}" ]] && is_human "$SUDO_USER"; then
    TARGET_USER="$SUDO_USER"; log "Compte cible déduit de \$SUDO_USER : $TARGET_USER"
elif (( EUID != 0 )) && is_human "$(id -un)"; then
    TARGET_USER="$(id -un)"; log "Compte cible : utilisateur courant $TARGET_USER"
elif (( ${#HUMANS[@]} == 1 )); then
    TARGET_USER="${HUMANS[0]}"; log "Compte cible : unique compte humain $TARGET_USER"
elif (( INTERACTIVE )); then
    ask_target_user
    user_exists "$TARGET_USER" || resolve_missing_user
elif (( ${#HUMANS[@]} == 0 )); then
    die "Aucun compte humain (UID $UID_MIN-$UID_MAX avec shell) : créez-en un (adduser) puis relancez avec --user."
elif (( ASSUME_YES )); then
    die "--yes et compte cible ambigu (${HUMANS[*]}) : précisez --user NOM."
else
    die "Mode non interactif et compte cible ambigu (${HUMANS[*]}) : précisez --user NOM."
fi

# Source du mot de passe du compte à créer : paramètre, stdin, question, ou refus.
# Résolu AVANT toute modification, pour ne jamais laisser un compte à moitié fait.
PASSWORD_MODE=""
if (( CREATE_NEW )); then
    n_sources=0
    [[ -n "$PASSWORD" ]] && n_sources=$((n_sources + 1))
    if (( PASSWORD_STDIN )); then n_sources=$((n_sources + 1)); fi
    if (( NO_PASSWORD )); then n_sources=$((n_sources + 1)); fi
    if (( n_sources > 1 )); then
        die "Options de mot de passe contradictoires : choisissez --password, --password-stdin ou --no-password."
    fi
    if [[ -n "$PASSWORD" ]]; then
        PASSWORD_MODE=param
        [[ "$PASSWORD" == *$'\n'* || "$PASSWORD" == *$'\r'* ]] && die "Le mot de passe ne doit pas contenir de retour à la ligne."
        (( ${#PASSWORD} < 8 )) && warn "Mot de passe court (${#PASSWORD} caractères) : 8 minimum recommandé."
        warn "--password : la valeur est visible dans 'ps' pendant l'exécution, dans l'historique du shell et dans les journaux. Préférez --password-stdin ou la saisie demandée."
    elif (( PASSWORD_STDIN )); then
        PASSWORD_MODE=stdin
    elif (( NO_PASSWORD )); then
        PASSWORD_MODE=none
    elif (( INTERACTIVE )); then
        if ask_yn "Définir un mot de passe pour $TARGET_USER maintenant (saisie masquée par passwd) ?" o; then
            PASSWORD_MODE=prompt
        else
            PASSWORD_MODE=none
            warn "Sans mot de passe, $TARGET_USER sera verrouillé : connexion par clé SSH uniquement, sudo inutilisable."
        fi
    elif [[ -t 0 || -t 2 ]]; then
        PASSWORD_MODE=prompt    # --yes : réponse par défaut « oui », saisie par passwd
    else
        die "Compte $TARGET_USER à créer : aucun mot de passe possible en non-interactif. Utilisez --password-stdin (recommandé), --password MDP, ou --no-password."
    fi
fi

# Clé SSH : seulement pour un compte créé ici (on ne modifie pas l'accès d'un
# compte existant). Puis groupe sudo, si --sudo ne l'a pas déjà décidé.
if [[ -n "$SSH_KEY_ARG" ]]; then
    if (( ! CREATE_NEW )); then
        warn "--ssh-key ignorée : $TARGET_USER existe déjà (ce script ne modifie l'accès que des comptes qu'il crée)."
    elif [[ "$SSH_KEY_ARG" =~ ^(ssh-|ecdsa-|sk-) ]]; then
        SSH_KEY="$(ssh_key_check "$(trim "$SSH_KEY_ARG")")" \
            || die "--ssh-key : clé publique invalide (format « type base64 [commentaire] », types ssh-ed25519, ssh-rsa, ecdsa-sha2-*, sk-ssh-*)."
    else
        SSH_KEY="$(ssh_key_from_file "$SSH_KEY_ARG")" || die "--ssh-key : fichier refusé (voir ci-dessus)."
    fi
fi
if (( CREATE_NEW && INTERACTIVE )); then
    if [[ -z "$SSH_KEY_ARG" ]] && ask_yn "Ajouter une clé SSH publique au compte $TARGET_USER ?" n; then
        ask_ssh_key
    fi
    if (( ! ADD_SUDO )) && ask_yn "Ajouter $TARGET_USER au groupe sudo ?" n; then
        ADD_SUDO=1
    fi
    if (( ADD_SUDO )) && [[ "$PASSWORD_MODE" == none ]]; then
        warn "$TARGET_USER sera dans le groupe sudo sans mot de passe : sudo restera inutilisable (sauf règle NOPASSWD)."
    fi
elif (( INTERACTIVE )); then
    log "Compte existant $TARGET_USER : aucune clé SSH ajoutée (ce script ne modifie l'accès que des comptes qu'il crée)."
fi

# Récapitulatif soumis à confirmation dès qu'au moins une question a été posée.
if (( INTERACTIVE && ASKED > 0 )); then
    case "$PASSWORD_MODE" in
        prompt) pw_choice="saisi maintenant par passwd (masqué)" ;;
        none)   pw_choice="aucun (compte verrouillé, clé SSH uniquement)" ;;
        param)  pw_choice="fourni par --password (non affiché)" ;;
        stdin)  pw_choice="lu sur l'entrée standard (non affiché)" ;;
        *)      pw_choice="inchangé" ;;
    esac
    step "Choix retenus"
    if (( CREATE_NEW )); then
        printf '    Compte          : %s (à créer, adduser)\n' "$TARGET_USER"
        printf '    Mot de passe    : %s\n' "$pw_choice"
        printf '    Clé SSH         : %s\n' "${SSH_KEY:-aucune}"
        printf '    Groupe sudo     : %s\n' "$( (( ADD_SUDO )) && echo oui || echo non)"
    else
        printf '    Compte          : %s (existant, accès inchangé)\n' "$TARGET_USER"
    fi
    printf '    Docker rootful  : %s\n' "$( (( KEEP_ROOTFUL )) && echo "conservé" || echo "désactivé si présent")"
    printf '    Test hello-world: %s\n' "$( (( NO_TEST )) && echo non || echo oui)"
    if (( DRY_RUN )); then printf '    Mode            : --dry-run (rien ne sera écrit)\n'; fi
    if ! ask_yn "Appliquer ?" o; then
        die "Abandon à la demande : rien n'a été modifié."
    fi
fi
if (( INTERACTIVE )); then exec 3<&-; fi

if (( CREATE_NEW )); then
    step "0. Compte $TARGET_USER"
    log "Création du compte (adduser --disabled-password) : aucun mot de passe, SSH reste à votre main."
    if (( DRY_RUN )); then
        printf "[+] (dry-run) adduser --disabled-password --gecos '' %s\n" "$TARGET_USER"
    else
        adduser --disabled-password --gecos "" "$TARGET_USER"
    fi
    if (( ADD_SUDO )); then
        log "Ajout de $TARGET_USER au groupe sudo."
        run usermod -aG sudo "$TARGET_USER"
    fi
    if (( DRY_RUN )); then
        TARGET_UID="$(next_free_uid)"
        TARGET_HOME="/home/$TARGET_USER"
        TARGET_SHELL=/bin/bash
        warn "(dry-run) compte non créé : uid $TARGET_UID estimé, HOME supposé $TARGET_HOME."
    else
        user_exists "$TARGET_USER" || die "Création de $TARGET_USER échouée."
        log "Compte créé : $TARGET_USER (uid $(id -u "$TARGET_USER"))"
    fi
    case "$PASSWORD_MODE" in
        param)
            if (( DRY_RUN )); then
                printf '[+] (dry-run) chpasswd (mot de passe non affiché)\n'
            else
                printf '%s:%s\n' "$TARGET_USER" "$PASSWORD" | chpasswd
                log "Mot de passe défini pour $TARGET_USER (valeur non journalisée)."
            fi
            PASSWORD="" ;;
        stdin)
            if (( DRY_RUN )); then
                printf '[+] (dry-run) chpasswd avec le mot de passe lu sur stdin (non affiché)\n'
            else
                IFS= read -r _pw || _pw=""
                [[ -n "$_pw" ]] || die "Entrée standard vide : aucun mot de passe reçu (--password-stdin)."
                printf '%s:%s\n' "$TARGET_USER" "$_pw" | chpasswd
                unset _pw
                log "Mot de passe défini pour $TARGET_USER (lu sur stdin, non journalisé)."
            fi ;;
        prompt)
            if (( DRY_RUN )); then
                printf '[+] (dry-run) passwd %s (saisie masquée sur le terminal)\n' "$TARGET_USER"
            else
                log "Définissez le mot de passe de $TARGET_USER (saisie masquée, jamais affichée) :"
                passwd "$TARGET_USER"
            fi ;;
        none)
            warn "Aucun mot de passe ($( (( NO_PASSWORD )) && echo "--no-password" || echo "choix au terminal")) : $TARGET_USER est verrouillé pour l'authentification par mot de passe."
            warn "Connexion uniquement par clé SSH ; sudo sera inutilisable pour ce compte tant qu'aucun mot de passe n'est défini." ;;
    esac

    if [[ -n "$PASSWORD" ]]; then
        unset PASSWORD
    fi

    if [[ -z "$SSH_KEY" ]] && { (( ! ADD_SUDO )) || [[ "$PASSWORD_MODE" == none ]]; }; then
        warn "Ajoutez une clé SSH à $TARGET_USER (depuis root) avant de compter vous y connecter."
    fi
fi

if (( CREATE_NEW && DRY_RUN )); then
    : # uid et HOME estimés ci-dessus : la lecture réelle est impossible avant création
else
    IFS=: read -r _ _ TARGET_UID TARGET_GID _ TARGET_HOME TARGET_SHELL < <(getent passwd "$TARGET_USER")
    [[ -n "${TARGET_UID:-}" ]] || die "Compte $TARGET_USER introuvable."
    [[ -d "$TARGET_HOME" ]] || die "Répertoire personnel de $TARGET_USER introuvable : $TARGET_HOME"
fi

# Clé SSH du compte créé : ~/.ssh (0700) et authorized_keys (0600) écrits EN TANT
# QUE l'utilisateur (propriétaire correct, aucun lien suivi avec les droits root) ;
# ajout seulement si la ligne exacte n'y figure pas déjà.
if (( CREATE_NEW )) && [[ -n "$SSH_KEY" ]]; then
    AUTH_KEYS="$TARGET_HOME/.ssh/authorized_keys"
    if (( DRY_RUN )); then
        log "(dry-run) ajout dans $AUTH_KEYS (~/.ssh 0700, fichier 0600, propriétaire $TARGET_USER) de : $SSH_KEY"
    else
        "$RUNUSER" -u "$TARGET_USER" -- sh -c '
            umask 077
            mkdir -p "$1" && chmod 0700 "$1" && touch "$1/authorized_keys" && chmod 0600 "$1/authorized_keys" || exit 1
            if grep -qxF -- "$2" "$1/authorized_keys"; then exit 3; fi
            if [ -s "$1/authorized_keys" ] && [ -n "$(tail -c 1 "$1/authorized_keys")" ]; then
                echo >>"$1/authorized_keys"
            fi
            printf "%s\n" "$2" >>"$1/authorized_keys"' sh "$TARGET_HOME/.ssh" "$SSH_KEY" && key_rc=0 || key_rc=$?
        case "$key_rc" in
            0) log "Clé SSH ajoutée : $AUTH_KEYS ($(stat -c '%U %a' "$AUTH_KEYS"))" ;;
            3) log "Clé SSH déjà présente dans $AUTH_KEYS : rien à faire." ;;
            *) die "Échec de l'écriture de $AUTH_KEYS (code $key_rc)." ;;
        esac
    fi
fi
RUNTIME_DIR="/run/user/$TARGET_UID"
SOCK="$RUNTIME_DIR/docker.sock"
USER_SCRIPT_DEST="$TARGET_HOME/.local/bin/$USER_SCRIPT_NAME"
log "Compte : $TARGET_USER (uid $TARGET_UID), HOME=$TARGET_HOME"

pkg_state() { dpkg-query -W -f='${db:Status-Abbrev}' "$1" 2>/dev/null | tr -d ' ' || true; }
pkg_installed() { [[ "$(pkg_state "$1")" == "ii" ]]; }

# Tous les appels reseau sont bornes : un pare-feu qui bloque doit produire une
# erreur claire en quelques secondes, jamais un script qui semble fige.
APT=(apt-get -y -o DPkg::Lock::Timeout=120 -o Acquire::http::Timeout=20
     -o Acquire::https::Timeout=20 -o Acquire::Retries=2)
CURL_OPTS=(--connect-timeout 10 --max-time 60 --retry 1 --retry-delay 2)
export DEBIAN_FRONTEND=noninteractive
APT_UPDATED=0
apt_update_once() {
    (( APT_UPDATED )) && return 0
    log "Mise a jour des index APT (borne a 5 min)..."
    run timeout 300 "${APT[@]}" update || die "apt-get update a echoue ou depasse 5 min (reseau, pare-feu ou miroir APT)."
    APT_UPDATED=1
}

# Le depot officiel est servi via un CDN CloudFront : un whitelist par nom ne
# suffit pas toujours. On teste AVANT d'ecrire quoi que ce soit.
verifier_acces_download_docker() {
    local code
    code="$(timeout 25 curl -sS -o /dev/null -m 20 -w '%{http_code}' \
        https://download.docker.com/linux/debian/gpg 2>/dev/null)" || code="000"
    if [[ "$code" == "200" ]]; then
        log "Acces a download.docker.com : OK (HTTP 200)."
        return 0
    fi
    warn "download.docker.com injoignable (code HTTP « $code ») : le pare-feu de cette machine le bloque."
    warn "Le depot est servi par un CDN (*.cloudfront.net) : autorise le nom ET le CDN, ou"
    warn "fournis la cle GPG a la main avec --docker-key-file <fichier docker.asc>."
    return 1
}

# Ecrit la cle GPG du depot dans DOCKER_KEY : depuis un fichier local si fourni,
# sinon par telechargement borne.
recuperer_cle_docker() {
    if [[ -n "$DOCKER_GPG_SRC" ]]; then
        [[ -s "$DOCKER_GPG_SRC" ]] || die "--docker-key-file : fichier absent ou vide : $DOCKER_GPG_SRC"
        if (( DRY_RUN )); then
            printf '[+] (dry-run) installerait %s -> %s\n' "$DOCKER_GPG_SRC" "$DOCKER_KEY"
        else
            install -m 0755 -d /etc/apt/keyrings
            install -m 0644 "$DOCKER_GPG_SRC" "$DOCKER_KEY"
            log "Cle GPG Docker installee depuis $DOCKER_GPG_SRC."
        fi
        return 0
    fi
    if (( DRY_RUN )); then
        printf '[+] (dry-run) telechargerait la cle GPG depuis https://download.docker.com/linux/debian/gpg\n'
        return 0
    fi
    log "Telechargement de la cle GPG Docker (~4 Ko, borne a 60 s)..."
    install -m 0755 -d /etc/apt/keyrings
    if ! timeout 90 curl -fsSL "${CURL_OPTS[@]}" -o "$DOCKER_KEY" \
            https://download.docker.com/linux/debian/gpg; then
        rm -f "$DOCKER_KEY"
        err "Telechargement de la cle GPG impossible (pare-feu ou reseau)."
        err "  1) autorise download.docker.com (et son CDN *.cloudfront.net) sur cette machine, ou"
        err "  2) copie la cle depuis une machine qui y accede, puis relance avec :"
        err "       --docker-key-file /chemin/docker.asc"
        die "Etape cle GPG interrompue : rien n'a ete modifie."
    fi
    chmod a+r "$DOCKER_KEY"
    log "Cle GPG Docker installee : $DOCKER_KEY"
}

# ---------------------------------------------------------------------------
step "1. Prérequis système"
# ---------------------------------------------------------------------------
# [R] « Prerequisites » : newuidmap/newgidmap = paquet uidmap.
# [RT] « docker run errors » (cgroup v2) : dbus-user-session.
# Le setuptool exige aussi iptables (check bloquant de dockerd-rootless-setuptool.sh).
# slirp4netns : pilote réseau par défaut s'il est présent ([RT] « Networking errors »),
#   sinon repli sur gvisor-tap-vsock -> recommandé, non bloquant.
# fuse-overlayfs : utile seulement si noyau < 5.11 ([RT] « Known limitations » : overlay2 dès 5.11).
PREREQ_PKGS=(uidmap dbus-user-session iptables slirp4netns)
kver="$(uname -r)"; kmaj="${kver%%.*}"; kmin="${kver#*.}"; kmin="${kmin%%[!0-9]*}"
if (( kmaj < 5 || (kmaj == 5 && kmin < 11) )); then
    PREREQ_PKGS+=(fuse-overlayfs)
    log "Noyau $kver < 5.11 : fuse-overlayfs ajouté (overlay2 rootless indisponible)."
else
    log "Noyau $kver >= 5.11 : overlay2 natif, fuse-overlayfs non nécessaire."
fi
missing_prereq=()
for p in "${PREREQ_PKGS[@]}"; do pkg_installed "$p" || missing_prereq+=("$p"); done
if (( ${#missing_prereq[@]} )); then
    log "À installer : ${missing_prereq[*]}"
    apt_update_once
    run "${APT[@]}" install "${missing_prereq[@]}"
else
    log "Déjà installés : ${PREREQ_PKGS[*]}"
fi

if [[ "$(stat -fc %T /sys/fs/cgroup 2>/dev/null)" == "cgroup2fs" ]]; then
    log "cgroup v2 détecté : limites --cpus/--memory/--pids-limit utilisables ([RT] « Known limitations »)."
else
    warn "cgroup v1 : --cpus/--memory/--pids-limit seront ignorés en rootless ([RT] « docker run errors »)."
fi
# Debian : kernel.unprivileged_userns_clone doit valoir 1 (instruction du setuptool).
if [[ -f /proc/sys/kernel/unprivileged_userns_clone && "$(cat /proc/sys/kernel/unprivileged_userns_clone)" != 1 ]]; then
    warn "kernel.unprivileged_userns_clone=0 : activation dans /etc/sysctl.d/50-rootless.conf"
    if (( DRY_RUN )); then
        log "(dry-run) echo 'kernel.unprivileged_userns_clone = 1' > /etc/sysctl.d/50-rootless.conf && sysctl --system"
    else
        printf 'kernel.unprivileged_userns_clone = 1\n' >/etc/sysctl.d/50-rootless.conf
        sysctl --system >/dev/null
    fi
fi
if [[ -f /proc/sys/kernel/apparmor_restrict_unprivileged_userns && "$(cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns)" == 1 ]]; then
    warn "AppArmor restreint les userns non privilégiés : le profil rootlesskit du paquet apparmor est requis ([RT] « Distribution-specific hint »)."
fi

# ---------------------------------------------------------------------------
step "2. /etc/subuid et /etc/subgid"
# ---------------------------------------------------------------------------
# [R] « Prerequisites » : au moins 65 536 UID/GID subordonnés. On n'écrase rien :
# ajout via usermod (verrouillage des fichiers) sur une plage libre après la plus haute.
ensure_subids() {
    local file="$1" flag="$2" total start
    [[ -e "$file" ]] || { (( DRY_RUN )) || touch "$file"; }
    total="$(awk -F: -v u="$TARGET_USER" -v i="$TARGET_UID" '($1==u||$1==i){s+=$3} END{print s+0}' "$file" 2>/dev/null || echo 0)"
    if (( total >= 65536 )); then
        log "$file : $TARGET_USER a $total identifiants (OK)."
    elif (( total > 0 )); then
        warn "$file : $TARGET_USER n'a que $total identifiants (< 65536). Laissé tel quel ; corrigez à la main si des images échouent (« lchown … invalid argument »)."
    else
        start="$(awk -F: 'BEGIN{m=100000} NF>=3 && ($2+$3)>m {m=$2+$3} END{print m}' "$file" 2>/dev/null || echo 100000)"
        log "$file : ajout de $TARGET_USER:$start:65536"
        run usermod "$flag" "$start-$((start + 65535))" "$TARGET_USER"
    fi
}
ensure_subids /etc/subuid --add-subuids
ensure_subids /etc/subgid --add-subgids

# ---------------------------------------------------------------------------
step "3. Docker CE depuis le dépôt APT officiel"
# ---------------------------------------------------------------------------
# [D] « Uninstall old versions » : refuser plutôt que supprimer automatiquement.
conflicts=()
for p in "${CONFLICT_PKGS[@]}"; do pkg_installed "$p" && conflicts+=("$p"); done
if (( ${#conflicts[@]} )); then
    err "Paquets en conflit installés : ${conflicts[*]} ([D] « Uninstall old versions »)."
    die "Supprimez-les (sudo apt-get remove ${conflicts[*]}) puis relancez ; non fait automatiquement car destructif."
fi

# [D] « Install using the apt repository », étape 1 — sans dupliquer un dépôt existant.
mapfile -t repo_files < <(grep -rlsE '^[^#]*download\.docker\.com/linux/debian' /etc/apt/sources.list /etc/apt/sources.list.d/ || true)
if (( ${#repo_files[@]} )); then
    log "Dépôt Docker déjà configuré : ${repo_files[*]} (non réécrit)."
    (( ${#repo_files[@]} > 1 )) && warn "Dépôt Docker déclaré dans plusieurs fichiers : risque d'avertissements APT « configured multiple times »."
    # La clé référencée doit exister.
    mapfile -t keys < <(grep -hoiE '(signed-by[=:][[:space:]]*)[^][:space:]]+' "${repo_files[@]}" | sed -E 's/^[Ss]igned-[Bb]y[=:][[:space:]]*//' | sort -u)
    for k in "${keys[@]}"; do
        if [[ -s "$k" ]]; then
            log "Clé du dépôt présente : $k"
        elif [[ "$k" == "$DOCKER_KEY" ]]; then
            warn "Clé $k absente."
            recuperer_cle_docker
            APT_UPDATED=0
        else
            warn "Clé $k référencée par le dépôt mais absente : à corriger manuellement."
        fi
    done
else
    suite="${APT_SUITE:-$(. /etc/os-release && echo "${VERSION_CODENAME:-}")}"
    [[ -n "$suite" ]] || die "VERSION_CODENAME vide : précisez --apt-suite (ex. trixie), cf. note Debian testing de [D]."
    log "Ajout du dépôt Docker (suite '$suite') dans $DOCKER_SOURCES"
    verifier_acces_download_docker || true
    pkg_installed ca-certificates && pkg_installed curl || { apt_update_once; run timeout 300 "${APT[@]}" install ca-certificates curl || die "installation de ca-certificates/curl impossible."; }
    recuperer_cle_docker
    sources_content="Types: deb
URIs: https://download.docker.com/linux/debian
Suites: $suite
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: $DOCKER_KEY"
    if (( DRY_RUN )); then
        log "(dry-run) écriture de $DOCKER_SOURCES :"; printf '%s\n' "$sources_content" | sed 's/^/      /'
    else
        printf '%s\n' "$sources_content" >"$DOCKER_SOURCES"
    fi
    APT_UPDATED=0
fi

# Paquets : seuls les absents ou en état « rc » (supprimé, config restante) / cassé.
# Un état rc est simplement réinstallé par apt-get install (les conffiles sont conservés).
need=(); broken=0
for p in "${DOCKER_PKGS[@]}"; do
    st="$(pkg_state "$p")"
    case "$st" in
        ii) ;;
        ""|un|rc) need+=("$p"); [[ "$st" == rc ]] && log "$p : état rc (supprimé, config restante) -> réinstallation." ;;
        *)  need+=("$p"); broken=1; warn "$p : état dpkg '$st' -> réparation." ;;
    esac
done
if (( broken )); then
    run dpkg --configure -a
fi
if (( ${#need[@]} )); then
    log "À installer : ${need[*]}"
    [[ " ${need[*]} " == *" docker-ce "* ]] && log "Note : le postinst de docker-ce démarre le démon rootful ; il sera désactivé à l'étape 4 (sauf --keep-rootful-docker)."
    apt_update_once
    run timeout 900 "${APT[@]}" install "${need[@]}" || die "installation des paquets Docker impossible (reseau, pare-feu ou depot)."
else
    log "Déjà installés : ${DOCKER_PKGS[*]}"
fi

# ---------------------------------------------------------------------------
step "4. Docker rootful"
# ---------------------------------------------------------------------------
# [R] « Install » (note) : désactiver le démon système, sinon --force.
unit_exists() { [[ -n "$(systemctl list-unit-files --no-legend "$1" 2>/dev/null)" ]]; }
rootful_units=()
for u in docker.service docker.socket; do unit_exists "$u" && rootful_units+=("$u"); done
rootful_active=0
for u in "${rootful_units[@]}"; do
    if systemctl is-active --quiet "$u" || systemctl is-enabled --quiet "$u" 2>/dev/null; then rootful_active=1; fi
done
if (( DRY_RUN )) && [[ " ${need[*]} " == *" docker-ce "* ]]; then
    rootful_active=1   # l'installation de docker-ce l'activerait et le démarrerait
    rootful_units=(docker.service docker.socket)
fi

if (( ! rootful_active )); then
    log "Aucun Docker rootful actif ou activé."
    if [[ -S /var/run/docker.sock ]]; then
        if (( KEEP_ROOTFUL )); then
            warn "/var/run/docker.sock orphelin (aucun démon) laissé en place (--keep-rootful-docker)."
        else
            log "/var/run/docker.sock orphelin (reste d'une désinstallation, aucun démon) : suppression ([R] « Install »)."
            run rm -f /var/run/docker.sock
        fi
    fi
elif (( KEEP_ROOTFUL )); then
    warn "--keep-rootful-docker : Docker rootful laissé actif ; le setuptool sera lancé avec --force."
    USER_FORCE=1
else
    log "Désactivation du Docker rootful ([R] « Install ») :"
    (( ${#rootful_units[@]} )) && run systemctl disable --now "${rootful_units[@]}"
    run rm -f /var/run/docker.sock
fi

# ---------------------------------------------------------------------------
step "5. Linger et gestionnaire systemd de l'utilisateur"
# ---------------------------------------------------------------------------
# [R] « Install » : « sudo loginctl enable-linger <user> » (démarrage au boot) ;
# [RT] « Failed to connect to bus » : sans session pam_systemd, on démarre
# user@<uid>.service pour que systemctl --user fonctionne sans connexion.
if [[ -e "/var/lib/systemd/linger/$TARGET_USER" ]]; then
    log "Linger déjà actif pour $TARGET_USER."
else
    run loginctl enable-linger "$TARGET_USER"
fi
run systemctl start "user@$TARGET_UID.service"
if (( ! DRY_RUN )); then
    for _ in $(seq 1 40); do [[ -S "$RUNTIME_DIR/bus" ]] && break; sleep 0.25; done
    if [[ ! -S "$RUNTIME_DIR/bus" ]]; then
        warn "$RUNTIME_DIR/bus absent : démarrage de dbus.socket utilisateur."
        "$RUNUSER" -u "$TARGET_USER" -- env XDG_RUNTIME_DIR="$RUNTIME_DIR" systemctl --user start dbus.socket || true
    fi
    [[ -S "$RUNTIME_DIR/bus" ]] && log "Bus utilisateur prêt : $RUNTIME_DIR/bus" \
        || warn "Bus D-Bus utilisateur toujours absent (dbus-user-session ?) ; la partie utilisateur le signalera."
fi

# ---------------------------------------------------------------------------
step "6. Script utilisateur : installation et exécution"
# ---------------------------------------------------------------------------
user_args=()
(( DRY_RUN )) && user_args+=(--dry-run)
(( NO_TEST )) && user_args+=(--no-test)
(( USER_FORCE )) && user_args+=(--force)

user_env=(env -i -C "$TARGET_HOME" HOME="$TARGET_HOME" USER="$TARGET_USER" LOGNAME="$TARGET_USER"
          SHELL="$TARGET_SHELL" PATH=/usr/local/bin:/usr/bin:/bin LANG="${LANG:-C.UTF-8}" TERM="${TERM:-dumb}")
[[ -d "$RUNTIME_DIR" ]] && user_env+=(XDG_RUNTIME_DIR="$RUNTIME_DIR" DBUS_SESSION_BUS_ADDRESS="unix:path=$RUNTIME_DIR/bus")

user_rc=0
if (( DRY_RUN )); then
    log "(dry-run) installation de $USER_SCRIPT_DEST (propriétaire $TARGET_USER, mode 0755)"
    # Exécution du script embarqué sans rien écrire sur disque.
    if (( CREATE_NEW )); then
        warn "(dry-run) compte $TARGET_USER inexistant : partie utilisateur non simulée (elle s'exécutera après la création réelle)."
    elif (( EUID == 0 )); then
        log "(dry-run) exécution de la partie utilisateur sous $TARGET_USER :"
        "$RUNUSER" -u "$TARGET_USER" -- "${user_env[@]}" bash -c "$(user_script_content)" "$USER_SCRIPT_NAME" "${user_args[@]}" || user_rc=$?
    elif [[ "$(id -un)" == "$TARGET_USER" ]]; then
        log "(dry-run) exécution de la partie utilisateur (utilisateur courant) :"
        bash -c "$(user_script_content)" "$USER_SCRIPT_NAME" "${user_args[@]}" || user_rc=$?
    else
        warn "(dry-run) non-root : impossible d'exécuter la partie utilisateur sous $TARGET_USER (lancez avec sudo)."
    fi
else
    tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
    user_script_content >"$tmp"; chmod 0644 "$tmp"
    if [[ -f "$USER_SCRIPT_DEST" ]] && cmp -s "$tmp" "$USER_SCRIPT_DEST"; then
        log "$USER_SCRIPT_DEST déjà à jour."
    else
        # Écrit EN TANT QUE l'utilisateur : propriétaire correct, pas de suivi de
        # lien symbolique avec les droits root dans un répertoire qu'il contrôle.
        "$RUNUSER" -u "$TARGET_USER" -- sh -c 'mkdir -p "$1" && install -m 0755 "$2" "$1/$3"' \
            sh "$(dirname "$USER_SCRIPT_DEST")" "$tmp" "$USER_SCRIPT_NAME"
        log "Installé : $USER_SCRIPT_DEST ($(stat -c '%U %a' "$USER_SCRIPT_DEST"))"
    fi
    log "Exécution : $RUNUSER -u $TARGET_USER -- $USER_SCRIPT_DEST ${user_args[*]}"
    "$RUNUSER" -u "$TARGET_USER" -- "${user_env[@]}" "$USER_SCRIPT_DEST" "${user_args[@]}" || user_rc=$?
fi

# ---------------------------------------------------------------------------
step "Récapitulatif"
# ---------------------------------------------------------------------------
created_note=""
if (( CREATE_NEW )); then
    case "$PASSWORD_MODE" in
        none) pw_note="aucun (compte verrouillé, clé SSH uniquement)" ;;
        "")   pw_note="non modifié" ;;
        *)    pw_note="défini (non journalisé)" ;;
    esac
    created_note=" — compte créé par ce script, mot de passe : $pw_note"
    if [[ -n "$SSH_KEY" ]]; then created_note+=", clé SSH ajoutée"; fi
    if (( ADD_SUDO )); then created_note+=", groupe sudo"; fi
fi
cat <<EOF
[+] Compte          : $TARGET_USER (uid $TARGET_UID)$created_note
[+] Socket          : $SOCK
[+] DOCKER_HOST     : unix://$SOCK   (ajouté à ~/.bashrc et ~/.profile)
[+] Script user     : $USER_SCRIPT_DEST
[+] Docker rootful  : $( (( KEEP_ROOTFUL )) && echo "conservé (--keep-rootful-docker)" || echo "désactivé si présent")
[+] Vérification (connecté en tant que $TARGET_USER, via ssh ou 'sudo machinectl shell $TARGET_USER@') :
      systemctl --user status docker.service
      docker context ls            # 'rootless' doit être marqué *
      docker info                  # Security Options : rootless
      docker run --rm hello-world
[+] Vérification depuis root :
      sudo -u $TARGET_USER XDG_RUNTIME_DIR=$RUNTIME_DIR DOCKER_HOST=unix://$SOCK docker info
[+] Relancer seulement la partie utilisateur : $USER_SCRIPT_DEST
EOF
if (( DRY_RUN )); then
    log "Dry-run terminé (code partie utilisateur : $user_rc). Rien n'a été modifié."
    exit "$user_rc"
fi
case "$user_rc" in
    0) log "SUCCÈS : Docker rootless installé et vérifié pour $TARGET_USER." ;;
    2) err "ÉCHEC : session systemd utilisateur indisponible (voir messages ci-dessus)." ;;
    *) err "ÉCHEC de la partie utilisateur (code $user_rc) : voir [RT] et journalctl --user -u docker.service." ;;
esac
exit "$user_rc"
