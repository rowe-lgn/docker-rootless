#!/usr/bin/env bash
# docker-rootless.sh — installation Docker en mode ROOTLESS sur Debian, point d'entrée unique.
#
#   ./docker-rootless.sh [--user NOM] [--dry-run] [--no-test] [--keep-rootful-docker]
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

# [D] « Install using the apt repository », étape 2 (+ docker-ce-rootless-extras, [R] « With packages »).
DOCKER_PKGS=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras)
# [D] « Uninstall old versions » : paquets non officiels en conflit.
CONFLICT_PKGS=(docker.io docker-compose docker-doc docker-buildx podman-docker containerd runc)
DOCKER_KEY=/etc/apt/keyrings/docker.asc
DOCKER_SOURCES=/etc/apt/sources.list.d/docker.sources
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
                          compte humain, sinon choix interactif).
  --dry-run               Affiche tout ce qui serait fait (parties admin et
                          utilisateur) ; n'écrit rien, ne (re)démarre rien.
  --no-test               Ne lance pas « docker run --rm hello-world ».
  --keep-rootful-docker   Ne désactive pas le Docker rootful (docker.service) ;
                          le setuptool est alors lancé avec --force.
  --apt-suite CODENAME    Suite du dépôt Docker si VERSION_CODENAME n'y existe
                          pas (Debian testing/dérivées), ex. : trixie.
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
ctx="$(env -u DOCKER_HOST docker info 2>/dev/null | awk -F': ' '/^ *Context:/{print $2; exit}')"
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
        --apt-suite)  [[ $# -ge 2 && -n "$2" ]] || die "--apt-suite attend un nom de suite"; APT_SUITE="$2"; shift ;;
        --apt-suite=*) APT_SUITE="${1#--apt-suite=}" ;;
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

if [[ -n "$TARGET_USER" ]]; then
    is_human "$TARGET_USER" || die "--user '$TARGET_USER' n'est pas un compte humain valide (choix : ${HUMANS[*]:-aucun})."
elif [[ -n "${SUDO_USER:-}" ]] && is_human "$SUDO_USER"; then
    TARGET_USER="$SUDO_USER"; log "Compte cible déduit de \$SUDO_USER : $TARGET_USER"
elif (( EUID != 0 )) && is_human "$(id -un)"; then
    TARGET_USER="$(id -un)"; log "Compte cible : utilisateur courant $TARGET_USER"
elif (( ${#HUMANS[@]} == 1 )); then
    TARGET_USER="${HUMANS[0]}"; log "Compte cible : unique compte humain $TARGET_USER"
elif (( ${#HUMANS[@]} == 0 )); then
    die "Aucun compte humain (UID $UID_MIN-$UID_MAX avec shell) : créez-en un (adduser) puis relancez avec --user."
elif [[ -t 0 || -t 2 ]] && { exec 3</dev/tty; } 2>/dev/null; then
    printf '[+] Plusieurs comptes possibles :\n' >&2
    for i in "${!HUMANS[@]}"; do printf '    %d) %s\n' "$((i + 1))" "${HUMANS[$i]}" >&2; done
    while :; do
        printf '[+] Numéro du compte à configurer : ' >&2
        IFS= read -r ans <&3 || die "Lecture du terminal impossible."
        if [[ "$ans" =~ ^[0-9]+$ ]] && (( ans >= 1 && ans <= ${#HUMANS[@]} )); then
            TARGET_USER="${HUMANS[$((ans - 1))]}"; break
        fi
        warn "Choix invalide : '$ans'"
    done
    exec 3<&-
else
    die "Mode non interactif et compte cible ambigu (${HUMANS[*]}) : précisez --user NOM."
fi

IFS=: read -r _ _ TARGET_UID TARGET_GID _ TARGET_HOME TARGET_SHELL < <(getent passwd "$TARGET_USER")
[[ -d "$TARGET_HOME" ]] || die "Répertoire personnel de $TARGET_USER introuvable : $TARGET_HOME"
RUNTIME_DIR="/run/user/$TARGET_UID"
SOCK="$RUNTIME_DIR/docker.sock"
USER_SCRIPT_DEST="$TARGET_HOME/.local/bin/$USER_SCRIPT_NAME"
log "Compte : $TARGET_USER (uid $TARGET_UID), HOME=$TARGET_HOME"

pkg_state() { dpkg-query -W -f='${db:Status-Abbrev}' "$1" 2>/dev/null | tr -d ' ' || true; }
pkg_installed() { [[ "$(pkg_state "$1")" == "ii" ]]; }

APT=(apt-get -y -o DPkg::Lock::Timeout=300)
export DEBIAN_FRONTEND=noninteractive
APT_UPDATED=0
apt_update_once() { (( APT_UPDATED )) && return 0; run "${APT[@]}" update; APT_UPDATED=1; }

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
            warn "Clé $k absente : téléchargement selon [D]."
            run install -m 0755 -d /etc/apt/keyrings
            run curl -fsSL https://download.docker.com/linux/debian/gpg -o "$DOCKER_KEY"
            run chmod a+r "$DOCKER_KEY"
            APT_UPDATED=0
        else
            warn "Clé $k référencée par le dépôt mais absente : à corriger manuellement."
        fi
    done
else
    suite="${APT_SUITE:-$(. /etc/os-release && echo "${VERSION_CODENAME:-}")}"
    [[ -n "$suite" ]] || die "VERSION_CODENAME vide : précisez --apt-suite (ex. trixie), cf. note Debian testing de [D]."
    log "Ajout du dépôt Docker (suite '$suite') dans $DOCKER_SOURCES"
    pkg_installed ca-certificates && pkg_installed curl || { apt_update_once; run "${APT[@]}" install ca-certificates curl; }
    run install -m 0755 -d /etc/apt/keyrings
    run curl -fsSL https://download.docker.com/linux/debian/gpg -o "$DOCKER_KEY"
    run chmod a+r "$DOCKER_KEY"
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
    run "${APT[@]}" install "${need[@]}"
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
    if (( EUID == 0 )); then
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
cat <<EOF
[+] Compte          : $TARGET_USER (uid $TARGET_UID)
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
