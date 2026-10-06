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
