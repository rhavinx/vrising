#!/bin/bash

APPID=1829350
GAMENAME="V Rising"
README_URL="https://github.com/rhavinx/vrising/blob/main/README.md"

BINARY="VRisingServer.exe"
FIRSTRUNCHECKFILE="VRisingServer.exe"
SETTINGS_TEMPLATES="VRisingServer_Data/StreamingAssets/Settings"

OK='✅: \033[1;92m'
INFO='➡️: \033[1;94m'
WARN='⚠️: \033[1;93m'
ERR='❌: \033[1;91m'
HILITE='👉: \033[38;5;208m'
NC='\033[0m'

TZ="${TZ:-UTC}"
PUID="${PUID:-1000}"
PGID="${PGID:-1000}"
SKIP_UPDATE="${SKIP_UPDATE:-0}"
GAME_PORT="${GAME_PORT:-9876}"
QUERY_PORT="${QUERY_PORT:-9877}"
SAVE_NAME="${SAVE_NAME:-world1}"
LIST_ON_STEAM="${LIST_ON_STEAM:-false}"
REMOVE_SERVER_FILES="${REMOVE_SERVER_FILES:-0}"

if ! [[ "${PUID}" =~ ^[0-9]+$ ]] || ! [[ "${PGID}" =~ ^[0-9]+$ ]]; then
  echo -e "${ERR}PUID and PGID must be numeric (got PUID='${PUID}', PGID='${PGID}')${NC}"
  exit 1
fi

if getent group steam >/dev/null; then
  groupmod -o -g "${PGID}" steam >/dev/null 2>&1
else
  groupadd -o -g "${PGID}" steam >/dev/null 2>&1
fi

if id steam >/dev/null 2>&1; then
  usermod -o -u "${PUID}" -g "${PGID}" steam >/dev/null 2>&1
else
  useradd -o -u "${PUID}" -g "${PGID}" -ms /bin/bash steam >/dev/null 2>&1
fi

chown -R steam:steam "${SERVERHOME}"
chown -R steam:steam "${GAMEDATA}"

echo "${TZ}" > /etc/timezone 2>&1
ln -snf "/usr/share/zoneinfo/${TZ}" /etc/localtime 2>&1
dpkg-reconfigure -f noninteractive tzdata >/dev/null 2>&1

settings=$(cat<<EOF

${HILITE}Please see the README for this container at: ${README_URL}${NC}

Container Settings:
-------------------
 TZ:                  ${INFO}${TZ}${NC}
 PUID:                ${INFO}${PUID}${NC}
 PGID:                ${INFO}${PGID}${NC}
 SKIP_UPDATE:         $(if [[ "${SKIP_UPDATE}" == "1" ]]; then echo -e "${WARN}1 WARNING: Server files will not update${NC}"; else echo -e "${INFO}0${NC}"; fi)
 REMOVE_SERVER_FILES: $(if [[ "${REMOVE_SERVER_FILES}" == "1" ]]; then echo -e "${WARN}1${NC} ${HILITE}!! UNSET FOR NEXT LAUNCH !!${NC}"; else echo -e "${INFO}0${NC}"; fi)
 SERVERHOME:          ${INFO}${SERVERHOME}${NC}
 GAMEDATA:            ${INFO}${GAMEDATA}${NC}

Server Settings:
----------------
 SERVER_NAME:         ${INFO}${SERVER_NAME:-"(not set, using existing)"}${NC}
 SERVER_DESCRIPTION:  ${INFO}${SERVER_DESCRIPTION:-"(not set, using existing)"}${NC}
 SERVER_PASSWORD:     $(if [[ -n "${SERVER_PASSWORD}" ]]; then echo -e "${HILITE}SET${NC}"; else echo -e "${INFO}NOT SET${NC}"; fi)
 MAX_PLAYERS:         ${INFO}${MAX_PLAYERS:-"(not set, using existing)"}${NC}
 MAX_ADMINS:          ${INFO}${MAX_ADMINS:-"(not set, using existing)"}${NC}

 GAME_PORT:           ${INFO}${GAME_PORT}${NC}
 QUERY_PORT:          ${INFO}${QUERY_PORT}${NC}
 SAVE_NAME:           ${INFO}${SAVE_NAME}${NC}
 LIST_ON_STEAM:       ${INFO}${LIST_ON_STEAM}${NC}

EOF
)
echo -e "${settings}"

### FUNCTIONS ###

term_handler() {
    echo -e "${INFO}Shutting down ${GAMENAME} server...${NC}"
    local PID
    PID=$(pgrep -f "VRisingServer.exe" | head -1)
    if [[ -z "${PID}" ]]; then
        echo -e "${WARN}Could not find ${GAMENAME} server PID. Assuming dead...${NC}"
    else
        kill -TERM "${PID}"
        local timeout=30
        while kill -0 "${PID}" 2>/dev/null && [[ ${timeout} -gt 0 ]]; do
            sleep 1
            (( timeout-- ))
        done
        if kill -0 "${PID}" 2>/dev/null; then
            echo -e "${WARN}Server did not stop gracefully, forcing...${NC}"
            kill -9 "${PID}" 2>/dev/null
        fi
    fi
    wineserver -k 2>/dev/null || true
    sleep 1
    echo -e "${INFO}Shutdown complete.${NC}"
    exit 0
}

trap 'term_handler' SIGTERM

install_server() {
    echo -e "${INFO}-> Installing / updating ${GAMENAME} server files...${NC}"
    gosu steam:steam /depotdownloader/DepotDownloader \
        -app ${APPID} \
        -dir "${SERVERHOME}" \
        -validate
}

copy_settings_templates() {
    echo -e "${INFO}Checking for missing settings files in data volume...${NC}"
    mkdir -p "${GAMEDATA}/Settings"
    local templates="${SERVERHOME}/${SETTINGS_TEMPLATES}"
    for f in ServerGameSettings.json ServerHostSettings.json adminlist.txt banlist.txt; do
        if [[ ! -f "${GAMEDATA}/Settings/${f}" ]] && [[ -f "${templates}/${f}" ]]; then
            cp "${templates}/${f}" "${GAMEDATA}/Settings/${f}"
            echo -e "${OK}Copied default ${f} to data volume.${NC}"
        fi
    done
    chown -R steam:steam "${GAMEDATA}/Settings"
}

remove_server_files() {
    echo -e "${INFO}Removing server files from ${SERVERHOME}...${NC}"
    if [[ -f "${SERVERHOME}/${BINARY}" ]]; then
        rm -rf "${SERVERHOME:?}"/*
        echo -e "${OK}Server files removed.${NC}"
    else
        echo -e "${ERR}Did not remove server files. Please manually empty the directory.${NC}"
    fi
}

patch_host_settings() {
    local json_file="${GAMEDATA}/Settings/ServerHostSettings.json"
    if [[ ! -f "${json_file}" ]]; then
        echo -e "${WARN}ServerHostSettings.json not found, skipping patch.${NC}"
        return
    fi

    local tmp
    tmp=$(mktemp)
    cp "${json_file}" "${tmp}"

    [[ -n "${SERVER_NAME}" ]] && \
        jq --arg v "${SERVER_NAME}" '.Name = $v' "${tmp}" > "${tmp}.new" && \
        mv "${tmp}.new" "${tmp}"

    [[ -n "${SERVER_DESCRIPTION}" ]] && \
        jq --arg v "${SERVER_DESCRIPTION}" '.Description = $v' "${tmp}" > "${tmp}.new" && \
        mv "${tmp}.new" "${tmp}"

    [[ -n "${SERVER_PASSWORD}" ]] && \
        jq --arg v "${SERVER_PASSWORD}" '.Password = $v' "${tmp}" > "${tmp}.new" && \
        mv "${tmp}.new" "${tmp}"

    [[ -n "${MAX_PLAYERS}" ]] && \
        jq --argjson v "${MAX_PLAYERS}" '.MaxConnectedUsers = $v' "${tmp}" > "${tmp}.new" && \
        mv "${tmp}.new" "${tmp}"

    [[ -n "${MAX_ADMINS}" ]] && \
        jq --argjson v "${MAX_ADMINS}" '.MaxConnectedAdmins = $v' "${tmp}" > "${tmp}.new" && \
        mv "${tmp}.new" "${tmp}"

    jq --argjson v "${GAME_PORT}" '.Port = $v' "${tmp}" > "${tmp}.new" && mv "${tmp}.new" "${tmp}"
    jq --argjson v "${QUERY_PORT}" '.QueryPort = $v' "${tmp}" > "${tmp}.new" && mv "${tmp}.new" "${tmp}"
    jq --arg v "${SAVE_NAME}" '.SaveName = $v' "${tmp}" > "${tmp}.new" && mv "${tmp}.new" "${tmp}"

    jq --argjson v "${LIST_ON_STEAM}" '.ListOnSteam = $v' "${tmp}" > "${tmp}.new" && mv "${tmp}.new" "${tmp}"

    cp "${tmp}" "${json_file}"
    rm -f "${tmp}" "${tmp}.new"
    chown steam:steam "${json_file}"
    echo -e "${OK}ServerHostSettings.json patched.${NC}"
}

check_avx() {
    local unsupported_dll="${SERVERHOME}/VRisingServer_Data/Plugins/x86_64/lib_burst_generated.dll"
    if ! grep -q 'avx[^ ]*' /proc/cpuinfo; then
        echo -e "${WARN}AVX/AVX2 not detected on this CPU.${NC}"
        if [[ -f "${unsupported_dll}" ]]; then
            echo -e "${WARN}Renaming lib_burst_generated.dll to avoid crash on non-AVX hardware.${NC}"
            mv "${unsupported_dll}" "${unsupported_dll}.bak"
        fi
    fi
}

### MAIN ###

firstrun=1
echo -e "${INFO}Starting ${GAMENAME} Dedicated Server...${NC}"

if [[ -f "${SERVERHOME}/${FIRSTRUNCHECKFILE}" ]]; then
    firstrun=0
fi

if [[ "${REMOVE_SERVER_FILES}" == "1" ]] && [[ ${firstrun} -eq 0 ]]; then
    echo -e "${WARN}Removing existing server files (REMOVE_SERVER_FILES=1)...${NC}"
    remove_server_files
    firstrun=1
fi

if [[ "${SKIP_UPDATE}" == "0" ]] || [[ ! -f "${SERVERHOME}/${BINARY}" ]]; then
    if [[ ! -f "${SERVERHOME}/${BINARY}" ]]; then
        attempt=1
        until [[ -f "${SERVERHOME}/${BINARY}" ]]; do
            echo -e "${HILITE}Attempt #${attempt} to install server files...${NC}"
            install_server
            (( attempt++ ))
        done
    else
        install_server
    fi
fi

check_avx
echo "${APPID}" > "${SERVERHOME}/steam_appid.txt"
copy_settings_templates
patch_host_settings

# Wine prefix in data volume — persistent, initialized once
export WINEPREFIX="${GAMEDATA}/.wine"
export WINEARCH=win64
export WINEDLLOVERRIDES="mscoree,mshtml="
export WINEDEBUG=-all

if [[ ! -d "${WINEPREFIX}" ]]; then
    echo -e "${INFO}Initializing Wine prefix (first run — this may take a moment)...${NC}"
    Xvfb :99 -screen 0 1024x768x16 -nolisten tcp &
    XVFB_PID=$!
    DISPLAY=:99 gosu steam:steam wineboot --init >/dev/null 2>&1
    kill "${XVFB_PID}" 2>/dev/null || true
    chown -R steam:steam "${WINEPREFIX}"
    echo -e "${OK}Wine prefix initialized.${NC}"
fi

echo -e "${INFO}Launching ${GAMENAME} Dedicated Server...${NC}"
cd "${SERVERHOME}" || exit 1
gosu steam:steam xvfb-run --auto-servernum \
    wine "${BINARY}" \
    -persistentDataPath "${GAMEDATA}" \
    -saveName "${SAVE_NAME}" &
ServerPID=$!
wait ${ServerPID}
