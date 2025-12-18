#!/bin/bash

# Edge Management - Script central de gestion des passerelles Buildy Edge
#
# Ce script permet de :
#  - Lister les peers NetBird disponibles
#  - Se connecter en SSH a un peer et lancer la mise a jour
#  - Exporter la liste des peers en CSV
#
# Prerequis :
#  - Etre connecte au reseau NetBird avec le client Mac
#  - jq installe (brew install jq)
#
# Usage : ./edge_management.sh
#
set -euo pipefail

# ============================================
# CONFIGURATION
# ============================================
readonly SCRIPT_VERSION="1.5.21"
readonly NETBIRD_API_URL="https://api.netbird.io/api/peers"
readonly GITHUB_RAW_URL="https://raw.githubusercontent.com/buildy-bms/edge-management/main"
readonly CACHE_DIR="/tmp/edge-management"
readonly CACHE_FILE="$CACHE_DIR/peers_cache.json"
readonly LOG_CACHE_DIR="$CACHE_DIR/logs"
readonly DEBUG_LOG="$CACHE_DIR/debug.log"
readonly CACHE_TTL=300  # 5 minutes
readonly CONFIG_DIR="$HOME/.config/edge-management"
readonly CONFIG_FILE="$CONFIG_DIR/config"
readonly FAVORITES_FILE="$CONFIG_DIR/favorites"

# Utilisateurs SSH
readonly SSH_USER_DEBIAN_11="kalessi"
readonly SSH_USER_DEBIAN_12="buildy"

# Chemin distant du repo edge-scripts
readonly REMOTE_EDGE_SCRIPTS_PATH="/media/.edge/edge-scripts"

# ============================================
# COULEURS (utiliser $'...' pour interpreter les sequences d'echappement)
# ============================================
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
BLUE=$'\033[0;34m'
MAGENTA=$'\033[0;35m'
CYAN=$'\033[0;36m'
NC=$'\033[0m'

# ============================================
# AUTO-MISE A JOUR
# ============================================

check_for_updates() {
    # Skip si --no-update passe en argument
    [[ "${1:-}" == "--no-update" ]] && return 0

    # Verifier la connectivite (timeout 2s)
    if ! curl -s --connect-timeout 2 -o /dev/null "$GITHUB_RAW_URL/edge_management.sh"; then
        return 0  # Pas de connexion, continuer sans mise a jour
    fi

    # Recuperer la version distante
    local remote_version
    remote_version=$(curl -s --connect-timeout 5 "$GITHUB_RAW_URL/edge_management.sh" 2>/dev/null | grep -E '^readonly SCRIPT_VERSION=' | cut -d'"' -f2)

    if [[ -z "$remote_version" ]]; then
        return 0  # Impossible de recuperer la version
    fi

    # Comparer les versions (simple comparaison de chaines)
    if [[ "$remote_version" != "$SCRIPT_VERSION" ]]; then
        # Verifier si la version distante est plus recente
        local local_parts remote_parts
        IFS='.' read -ra local_parts <<< "$SCRIPT_VERSION"
        IFS='.' read -ra remote_parts <<< "$remote_version"

        local is_newer=false
        for i in 0 1 2; do
            local lp="${local_parts[$i]:-0}"
            local rp="${remote_parts[$i]:-0}"
            if [[ "$rp" -gt "$lp" ]]; then
                is_newer=true
                break
            elif [[ "$rp" -lt "$lp" ]]; then
                break
            fi
        done

        if [[ "$is_newer" == "true" ]]; then
            echo ""
            echo -e "${YELLOW}══════════════════════════════════════════════════════════════════════════${NC}"
            echo -e "${YELLOW}  MISE A JOUR DISPONIBLE${NC}"
            echo -e "${YELLOW}══════════════════════════════════════════════════════════════════════════${NC}"
            echo -e "  Version actuelle : ${RED}$SCRIPT_VERSION${NC}"
            echo -e "  Nouvelle version : ${GREEN}$remote_version${NC}"
            echo ""
            read -rp "  Mettre a jour maintenant ? (O/n) " update_choice

            if [[ ! "$update_choice" =~ ^[nN]$ ]]; then
                local script_path
                script_path=$(realpath "$0")

                echo -e "  ${CYAN}Telechargement...${NC}"
                if curl -fsSL "$GITHUB_RAW_URL/edge_management.sh" -o "${script_path}.new"; then
                    chmod +x "${script_path}.new"
                    mv "${script_path}.new" "$script_path"
                    echo -e "  ${GREEN}Mise a jour effectuee !${NC}"
                    echo ""
                    # Relancer le script avec --no-update pour eviter boucle infinie
                    exec "$script_path" --no-update
                else
                    echo -e "  ${RED}Echec du telechargement${NC}"
                    rm -f "${script_path}.new"
                fi
            fi
            echo ""
        fi
    fi
}

# Verifier les mises a jour au demarrage
check_for_updates "$@"

# ============================================
# CHARGEMENT DU TOKEN API NETBIRD
# ============================================

# Charger ou demander le token API Netbird personnel
load_or_prompt_token() {
    # 1. Variable d'environnement (prioritaire)
    if [[ -n "${NETBIRD_API_TOKEN:-}" ]]; then
        echo "$NETBIRD_API_TOKEN"
        return
    fi

    # 2. Fichier config existant
    if [[ -f "$CONFIG_FILE" ]]; then
        local token
        token=$(grep -E "^NETBIRD_API_TOKEN=" "$CONFIG_FILE" 2>/dev/null | cut -d'=' -f2- | tr -d '"'"'") || true
        if [[ -n "$token" ]]; then
            echo "$token"
            return
        fi
    fi

    # 3. Premiere utilisation : demander le token
    echo ""
    echo -e "${YELLOW}══════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}  CONFIGURATION INITIALE${NC}"
    echo -e "${YELLOW}══════════════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "Ce script necessite votre token API Netbird personnel."
    echo -e "Vous pouvez le trouver sur : ${CYAN}https://app.netbird.io/settings${NC}"
    echo ""
    read -rp "Entrez votre token API Netbird : " user_token

    if [[ -z "$user_token" ]]; then
        echo -e "${RED}Token vide. Abandon.${NC}"
        exit 1
    fi

    # Sauvegarder
    mkdir -p "$CONFIG_DIR"
    echo "NETBIRD_API_TOKEN=$user_token" > "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
    echo -e "${GREEN}Token sauvegarde dans $CONFIG_FILE${NC}"
    echo ""

    echo "$user_token"
}

NETBIRD_API_TOKEN=$(load_or_prompt_token)

# ============================================
# FONCTIONS UTILITAIRES
# ============================================

log_message() {
    echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $1"
}

# Debug logging - ecrit dans /tmp/edge-management/debug.log
debug_log() {
    mkdir -p "$CACHE_DIR"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$DEBUG_LOG"
}

# Attendre que l'utilisateur appuie sur 'q' pour continuer
# Usage: attendre_q [message]
attendre_q() {
    local msg="${1:-Appuyez sur 'q' pour continuer...}"
    echo -e "\n  ${CYAN}$msg${NC}"
    while true; do
        read -rsn1 key
        [[ "$key" == "q" || "$key" == "Q" ]] && break
    done
}

# Lecture simple pour menus - validation avec Entree
# Usage: result=$(read_menu_input)
read_menu_input() {
    local input
    read -r input
    echo "$input"
}

# Telecharger un fichier avec indicateur de progression
# Usage: download_with_progress URL TIMEOUT
# Retourne le contenu via stdout, affiche la progression sur stderr
download_with_progress() {
    local url="$1"
    local timeout="${2:-10}"
    local temp_file=$(mktemp)
    local start_time=$(date +%s)

    # Recuperer la taille totale via HEAD request
    local total_size=0
    total_size=$(curl -sI --connect-timeout 3 "$url" 2>/dev/null | grep -i "^Content-Length:" | awk '{print $2}' | tr -d '\r\n' || echo "0")
    [ -z "$total_size" ] && total_size=0

    # Indicateur en arriere-plan avec temps, taille et pourcentage
    (
        local chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
        local i=0
        while true; do
            local elapsed=$(($(date +%s) - start_time))
            local size_now=""
            local percent_str=""
            if [ -f "$temp_file" ]; then
                local bytes=$(wc -c < "$temp_file" 2>/dev/null | tr -d ' ')
                if [ "$bytes" -gt 1048576 ] 2>/dev/null; then
                    size_now="$(awk "BEGIN {printf \"%.1f\", $bytes/1048576}") MB"
                elif [ "$bytes" -gt 1024 ] 2>/dev/null; then
                    size_now="$(awk "BEGIN {printf \"%.0f\", $bytes/1024}") KB"
                elif [ "$bytes" -gt 0 ] 2>/dev/null; then
                    size_now="${bytes} o"
                fi
                # Calculer pourcentage si on connait la taille totale
                if [ "$total_size" -gt 0 ] 2>/dev/null && [ "$bytes" -gt 0 ] 2>/dev/null; then
                    local pct=$(awk "BEGIN {printf \"%.0f\", ($bytes * 100) / $total_size}")
                    [ "$pct" -gt 100 ] 2>/dev/null && pct=100
                    percent_str=" (${pct}%)"
                fi
            fi
            printf "\r  ${CYAN}${chars:$i:1}${NC} Telechargement... ${YELLOW}%ds${NC} ${CYAN}%s${NC}${GREEN}%s${NC}        " "$elapsed" "$size_now" "$percent_str" >&2
            i=$(( (i + 1) % ${#chars} ))
            sleep 0.3
        done
    ) &
    local spinner_pid=$!

    # Telecharger silencieusement
    curl -s --connect-timeout "$timeout" "$url" -o "$temp_file" 2>/dev/null
    local curl_status=$?

    # Arreter le spinner (|| true pour eviter erreur avec set -e)
    kill $spinner_pid 2>/dev/null || true
    wait $spinner_pid 2>/dev/null || true

    if [ $curl_status -eq 0 ] && [ -f "$temp_file" ] && [ -s "$temp_file" ]; then
        local actual_size=$(wc -c < "$temp_file" | tr -d ' ')
        local size_display=""
        if [ "$actual_size" -gt 1048576 ]; then
            size_display="$(awk "BEGIN {printf \"%.1f\", $actual_size/1048576}") MB"
        elif [ "$actual_size" -gt 1024 ]; then
            size_display="$(awk "BEGIN {printf \"%.0f\", $actual_size/1024}") KB"
        else
            size_display="$actual_size octets"
        fi
        local line_count=$(wc -l < "$temp_file" | tr -d ' ')
        local elapsed=$(($(date +%s) - start_time))
        echo -e "\r  ${GREEN}✓${NC} Telecharge : ${CYAN}$size_display${NC} (${line_count} lignes) en ${YELLOW}${elapsed}s${NC}        " >&2
        cat "$temp_file"
    else
        echo -e "\r  ${RED}✗${NC} Echec du telechargement                              " >&2
    fi

    rm -f "$temp_file"
    return $curl_status
}

colorize_logs() {
    # Colorise les logs avec mise en evidence des elements importants
    # et pretty print du JSON
    local input="$1"

    echo "$input" | while IFS= read -r line; do
        # Detecter si la ligne contient du JSON (commence par { ou contient ":{")
        if [[ "$line" =~ \{.*\} ]]; then
            # Extraire la partie avant le JSON
            local prefix="${line%%\{*}"
            local json_part="{${line#*\{}"

            # Coloriser le prefix
            prefix=$(echo "$prefix" | sed \
                -e "s/\[ERROR\]/${RED}[ERROR]${NC}/g" \
                -e "s/\[WARN\]/${YELLOW}[WARN]${NC}/g" \
                -e "s/\[INFO\]/${CYAN}[INFO]${NC}/g" \
                -e "s/\[DEBUG\]/${MAGENTA}[DEBUG]${NC}/g")

            # Coloriser le timestamp au debut - supporte deux formats:
            # [YYYY-MM-DD HH:MM:SS] ou [DD/MM/YYYY HH:MM:SS:mmm]
            prefix=$(echo "$prefix" | sed -E "s/^(\[[0-9]{2}\/[0-9]{2}\/[0-9]{4} [0-9]{2}:[0-9]{2}:[0-9]{2}:[0-9]{3}\])/${BLUE}\1${NC}/")
            prefix=$(echo "$prefix" | sed -E "s/^(\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\])/${BLUE}\1${NC}/")

            # Pretty print et coloriser le JSON
            local pretty_json
            pretty_json=$(echo "$json_part" | jq -C '.' 2>/dev/null)
            if [ $? -eq 0 ] && [ -n "$pretty_json" ]; then
                echo -e "${prefix}"
                echo "$pretty_json" | sed 's/^/    /'
            else
                # JSON invalide, afficher tel quel avec colorisation basique
                echo -e "${prefix}${CYAN}${json_part}${NC}"
            fi
        else
            # Pas de JSON, coloriser la ligne normalement
            local colored_line="$line"

            # Coloriser le timestamp au debut - supporte deux formats:
            # [YYYY-MM-DD HH:MM:SS] ou [DD/MM/YYYY HH:MM:SS:mmm]
            colored_line=$(echo "$colored_line" | sed -E "s/^(\[[0-9]{2}\/[0-9]{2}\/[0-9]{4} [0-9]{2}:[0-9]{2}:[0-9]{2}:[0-9]{3}\])/${BLUE}\1${NC}/")
            colored_line=$(echo "$colored_line" | sed -E "s/^(\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\])/${BLUE}\1${NC}/")

            # Coloriser les niveaux de log
            colored_line=$(echo "$colored_line" | sed \
                -e "s/\[ERROR\]/${RED}[ERROR]${NC}/g" \
                -e "s/\[WARN\]/${YELLOW}[WARN]${NC}/g" \
                -e "s/\[INFO\]/${CYAN}[INFO]${NC}/g" \
                -e "s/\[DEBUG\]/${MAGENTA}[DEBUG]${NC}/g")

            # Mettre en evidence les mots-cles importants
            colored_line=$(echo "$colored_line" | sed \
                -e "s/Successfully/${GREEN}Successfully${NC}/g" \
                -e "s/Failed/${RED}Failed${NC}/g" \
                -e "s/ECHEC/${RED}ECHEC${NC}/g" \
                -e "s/connected/${GREEN}connected${NC}/gi" \
                -e "s/disconnected/${RED}disconnected${NC}/gi" \
                -e "s/offline/${RED}offline${NC}/gi" \
                -e "s/online/${GREEN}online${NC}/gi" \
                -e "s/timeout/${YELLOW}timeout${NC}/gi")

            echo -e "$colored_line"
        fi
    done
}

display_with_paging() {
    # Affiche du contenu avec pagination interactive
    # Usage: display_with_paging "$content" [lines_per_page] [header_info]
    local content="$1"
    local lines_per_page="${2:-50}"
    local header_info="${3:-}"

    local total_lines
    total_lines=$(echo "$content" | wc -l | tr -d ' ')

    # Si peu de lignes, afficher tout d'un coup
    if [ "$total_lines" -le "$lines_per_page" ]; then
        colorize_logs "$content"
        return 0
    fi

    local current_line=1
    local page=1
    local total_pages=$(( (total_lines + lines_per_page - 1) / lines_per_page ))

    while true; do
        clear
        echo ""
        echo -e "${YELLOW}══════════════════════════════════════════════════════════════════════════════${NC}"
        if [ -n "$header_info" ]; then
            echo -e "  $header_info"
        fi
        echo -e "${YELLOW}  Page ${CYAN}$page${YELLOW}/${CYAN}$total_pages${NC}  ${YELLOW}|  Lignes ${CYAN}$current_line-$(( current_line + lines_per_page - 1 > total_lines ? total_lines : current_line + lines_per_page - 1 ))${YELLOW}/${CYAN}$total_lines${NC}"
        echo -e "${YELLOW}══════════════════════════════════════════════════════════════════════════════${NC}"
        echo ""

        # Extraire et afficher la page courante
        local page_content
        page_content=$(echo "$content" | sed -n "${current_line},$((current_line + lines_per_page - 1))p")
        colorize_logs "$page_content"

        echo ""
        echo -e "${YELLOW}══════════════════════════════════════════════════════════════════════════════${NC}"

        # Navigation
        if [ "$page" -lt "$total_pages" ]; then
            echo -e "  ${GREEN}Entree${NC} Page suivante  |  ${YELLOW}p${NC} Page precedente  |  ${YELLOW}d${NC} Debut  |  ${YELLOW}f${NC} Fin  |  ${RED}q${NC} Quitter"
        else
            echo -e "  ${YELLOW}p${NC} Page precedente  |  ${YELLOW}d${NC} Debut  |  ${RED}q${NC} Quitter (fin du log)"
        fi
        echo ""

        read -rsn1 key

        case "$key" in
            ""|" ")
                # Entree ou Espace = page suivante
                if [ "$page" -lt "$total_pages" ]; then
                    ((page++))
                    current_line=$((current_line + lines_per_page))
                fi
                ;;
            p|P)
                # Page precedente
                if [ "$page" -gt 1 ]; then
                    ((page--))
                    current_line=$((current_line - lines_per_page))
                fi
                ;;
            d|D)
                # Debut
                page=1
                current_line=1
                ;;
            f|F)
                # Fin
                page=$total_pages
                current_line=$(( (total_pages - 1) * lines_per_page + 1 ))
                ;;
            q|Q)
                return 0
                ;;
        esac
    done
}

display_with_time_paging_file() {
    # Affiche un fichier log avec less + menu interactif
    local input_file="$1"
    local header_info="${2:-Log}"
    local json_mode=0
    local JSON_LIMIT=2000
    local HEADER_LINES=4
    local start_time=""

    debug_log "display_with_time_paging_file: start, input=$input_file"

    if [[ ! -f "$input_file" ]]; then
        echo -e "${YELLOW}Fichier non trouve.${NC}"; return 1
    fi
    if [[ ! -s "$input_file" ]]; then
        echo -e "${YELLOW}Fichier vide.${NC}"; return 1
    fi

    local processed_file=$(mktemp)
    local final_file=$(mktemp)
    cleanup_files() { rm -f "$processed_file" "$final_file" 2>/dev/null; }

    local R=$'\033[0;31m' Y=$'\033[0;33m' C=$'\033[0;36m' M=$'\033[0;35m' B=$'\033[0;34m' N=$'\033[0m' G=$'\033[0;32m'
    local total_lines=$(wc -l < "$input_file" 2>/dev/null | tr -d ' ') || total_lines=0

    # Fonction de traitement
    process_file() {
        if [[ $json_mode -eq 1 ]]; then
            (
                set +e
                tmp_awk=$(mktemp)
                tail -n "$JSON_LIMIT" "$input_file" | awk -v R="$R" -v Y="$Y" -v C="$C" -v M="$M" -v B="$B" -v N="$N" '
                {
                    line = $0
                    gsub(/\[ERROR\]/, R "[ERROR]" N, line)
                    gsub(/\[WARN\]/, Y "[WARN]" N, line)
                    gsub(/\[INFO\]/, C "[INFO]" N, line)
                    gsub(/\[DEBUG\]/, M "[DEBUG]" N, line)
                    if (match(line, /\{\".*\}$/)) {
                        prefix = substr(line, 1, RSTART-1)
                        json = substr(line, RSTART, RLENGTH)
                        print "PREFIX:" prefix
                        print "JSON:" json
                        print "---END---"
                    } else { print line }
                }' > "$tmp_awk"
                while IFS= read -r line || [[ -n "$line" ]]; do
                    if [[ "$line" == "PREFIX:"* ]]; then
                        prefix="${line#PREFIX:}"
                        read -r json_line || json_line=""
                        json_part="${json_line#JSON:}"
                        read -r _ || true
                        formatted=$(echo "$json_part" | jq -C . 2>/dev/null) || formatted=""
                        if [[ -n "$formatted" && "$formatted" != "null" ]]; then
                            echo -e "$prefix"
                            echo "$formatted"
                        else
                            echo -e "${prefix}${json_part}"
                        fi
                    else
                        echo "$line"
                    fi
                done < "$tmp_awk"
                rm -f "$tmp_awk"
            ) > "$processed_file" 2>&1
        else
            awk -v R="$R" -v Y="$Y" -v C="$C" -v M="$M" -v B="$B" -v N="$N" '
            BEGIN { last_min = "" }
            {
                line = $0; min = ""
                if (match(line, /\[[0-9][0-9]\/[0-9][0-9]\/[0-9][0-9][0-9][0-9] ([0-9][0-9]:[0-9][0-9]):/)) min = substr(line, RSTART+12, 5)
                else if (match(line, /\[[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] ([0-9][0-9]:[0-9][0-9]):/)) min = substr(line, RSTART+12, 5)
                if (min != "" && last_min != "" && min != last_min) { print ""; print B "──────────── " C min N " " B "────────────" N; print "" }
                if (min != "") last_min = min
                gsub(/\[ERROR\]/, R "[ERROR]" N, line)
                gsub(/\[WARN\]/, Y "[WARN]" N, line)
                gsub(/\[INFO\]/, C "[INFO]" N, line)
                gsub(/\[DEBUG\]/, M "[DEBUG]" N, line)
                print line
            }' "$input_file" > "$processed_file"
        fi
    }

    # Boucle menu principal
    while true; do
        local mode_str
        [[ $json_mode -eq 1 ]] && mode_str="${M}JSON Pretty${N}" || mode_str="${G}Normal${N}"
        local time_str=""
        [[ -n "$start_time" ]] && time_str=" | Depart: ${C}$start_time${N}"

        clear
        echo -e "${Y}════════════════════════════════════════════════════════════════════════════════${N}"
        echo -e "  ${C}$header_info${N} | ${G}$total_lines${N} lignes | $mode_str$time_str"
        echo -e "${Y}════════════════════════════════════════════════════════════════════════════════${N}"
        echo ""
        echo -e "  ${CYAN}Entree${NC}  Voir le log"
        echo -e "  ${CYAN}h${NC}       Aller a une heure (HH:MM)"
        echo -e "  ${YELLOW}j${NC}       Basculer JSON pretty"
        echo -e "  ${GREEN}e${NC}       Exporter"
        echo -e "  ${RED}q${NC}       Quitter"
        echo ""
        echo -ne "  ▸ "

        local choice
        read -rsn1 choice

        case "$choice" in
            h|H)
                echo ""
                echo -ne "  Heure (HHMM ou HH:MM) : "
                read -r time_input
                # Accepter HHMM (ex: 1430) ou HH:MM (ex: 14:30) ou H:MM (ex: 9:30)
                if [[ "$time_input" =~ ^[0-9]{4}$ ]]; then
                    # Format HHMM -> HH:MM
                    start_time="${time_input:0:2}:${time_input:2:2}"
                elif [[ "$time_input" =~ ^[0-9]{1,2}:[0-9]{2}$ ]]; then
                    # Format HH:MM ou H:MM - normaliser en HH:MM
                    if [[ ${#time_input} -eq 4 ]]; then
                        start_time="0$time_input"
                    else
                        start_time="$time_input"
                    fi
                elif [[ "$time_input" =~ ^[0-9]{3}$ ]]; then
                    # Format HMM (ex: 930) -> 09:30
                    start_time="0${time_input:0:1}:${time_input:1:2}"
                else
                    echo -e "  ${RED}Format invalide (ex: 1430 ou 14:30)${NC}"
                    sleep 1
                    continue
                fi
                echo -e "  ${GREEN}Heure: $start_time${NC}"
                sleep 0.5
                ;;
            j|J)
                json_mode=$((1 - json_mode))
                ;;
            e|E)
                echo -e "\n  ${CYAN}Traitement...${NC}"
                process_file
                local export_file="${input_file%.log}_export_$(date +%Y%m%d_%H%M%S).log"
                sed 's/\x1b\[[0-9;]*m//g' "$processed_file" > "$export_file" 2>/dev/null
                echo -e "  ${GREEN}Exporte: $export_file${NC}"
                sleep 2
                ;;
            ""|v|V)
                echo -e "\n  ${CYAN}Traitement...${NC}"

                # Si une heure est specifiee, extraire a partir de cette heure du fichier ORIGINAL
                local work_file="$input_file"
                if [[ -n "$start_time" ]]; then
                    local orig_line="" found_time=""

                    # D'abord essayer l'heure exacte
                    orig_line=$(grep -n " $start_time:" "$input_file" 2>/dev/null | head -1 | cut -d: -f1) || true

                    if [[ -z "$orig_line" || ! "$orig_line" =~ ^[0-9]+$ ]]; then
                        # Heure exacte non trouvee - chercher l'heure la plus proche <= start_time
                        local search_hh="${start_time:0:2}"
                        local search_mm="${start_time:3:2}"
                        local search_mins=$((10#$search_hh * 60 + 10#$search_mm)) || search_mins=0

                        # Trouver la derniere ligne avec une heure <= demandee
                        local result=""
                        result=$(awk -v target="$search_mins" '
                        {
                            if (match($0, /\[[0-9][0-9]\/[0-9][0-9]\/[0-9][0-9][0-9][0-9] [0-9][0-9]:[0-9][0-9]:/)) {
                                hh = substr($0, RSTART+12, 2) + 0
                                mm = substr($0, RSTART+15, 2) + 0
                                mins = hh * 60 + mm
                                if (mins <= target) {
                                    last_line = NR
                                    last_hh = hh
                                    last_mm = mm
                                }
                            }
                        }
                        END {
                            if (last_line) printf "%d:%02d:%02d\n", last_line, last_hh, last_mm
                        }' "$input_file" 2>/dev/null) || true

                        if [[ -n "$result" ]]; then
                            orig_line="${result%%:*}"
                            found_time="${result#*:}"
                        fi
                    else
                        found_time="$start_time"
                    fi

                    if [[ -n "$orig_line" && "$orig_line" =~ ^[0-9]+$ && "$orig_line" -gt 0 ]]; then
                        work_file=$(mktemp)
                        # En mode JSON, limiter aux premieres JSON_LIMIT lignes, sinon tout
                        if [[ $json_mode -eq 1 ]]; then
                            { tail -n "+$orig_line" "$input_file" 2>/dev/null | head -n "$JSON_LIMIT" > "$work_file"; } || true
                        else
                            tail -n "+$orig_line" "$input_file" > "$work_file" 2>/dev/null || true
                        fi
                        if [[ "$found_time" != "$start_time" ]]; then
                            echo -e "  ${GREEN}✓${NC} Depart a ${CYAN}$found_time${NC} (proche de $start_time, ligne $orig_line)"
                        else
                            echo -e "  ${GREEN}✓${NC} Depart a $start_time (ligne $orig_line)"
                        fi
                        start_time="$found_time"
                    else
                        echo -e "  ${YELLOW}Aucune heure <= $start_time, affichage integral${NC}"
                        sleep 1
                        start_time=""
                    fi
                fi

                # Traiter le fichier (original ou extrait)
                local saved_input="$input_file"
                input_file="$work_file"
                process_file
                input_file="$saved_input"

                # Nettoyer le fichier temporaire si cree
                [[ "$work_file" != "$input_file" ]] && rm -f "$work_file"

                if [[ -s "$processed_file" ]]; then
                    local file_lines=$(wc -l < "$processed_file" | tr -d ' ')
                    # Creer header pour less
                    {
                        echo -e "${Y}════════════════════════════════════════════════════════════════════════════════════════════════════════════════${N}"
                        echo -e "  ${C}$header_info${N} | ${G}$file_lines${N} lignes | $mode_str$time_str"
                        echo -e "  ${C}Espace${N}=suiv ${C}b${N}=prec ${C}<${N}/${C}g${N}=debut ${C}>${N}/${C}G${N}=fin ${C}/${N}=chercher ${C}n${N}/${C}N${N}=nav.match ${R}q${N}=retour menu (h/j/e)"
                        echo -e "${Y}════════════════════════════════════════════════════════════════════════════════════════════════════════════════${N}"
                        cat "$processed_file"
                    } > "$final_file"
                    less -R --header=$HEADER_LINES "$final_file" || true
                else
                    echo -e "${YELLOW}Aucune donnee.${NC}"
                    sleep 1
                fi
                ;;
            q|Q)
                break
                ;;
        esac
    done

    cleanup_files
    debug_log "display_with_time_paging_file: end"
}

display_with_time_paging() {
    # ANCIENNE VERSION - garde pour compatibilite
    # Preferer display_with_time_paging_file pour les gros fichiers
    # Usage: display_with_time_paging "$content" [header_info]
    local content="$1"
    local header_info="${2:-}"

    # Creer un fichier temporaire et utiliser la version fichier
    local temp_file=$(mktemp)
    echo "$content" > "$temp_file"
    display_with_time_paging_file "$temp_file" "$header_info"
    rm -f "$temp_file"
}

get_cache_age() {
    # Retourne l'age du cache en format lisible (ex: "2 min", "30 sec")
    if [ ! -f "$CACHE_FILE" ]; then
        echo "aucun cache"
        return
    fi

    local cache_mtime cache_age_sec
    if [[ "$OSTYPE" == "darwin"* ]]; then
        cache_mtime=$(stat -f%m "$CACHE_FILE" 2>/dev/null) || cache_mtime=""
    else
        cache_mtime=$(stat -c%Y "$CACHE_FILE" 2>/dev/null) || cache_mtime=""
    fi

    # Si stat a echoue ou retourne vide ou non numerique
    if [[ -z "$cache_mtime" || ! "$cache_mtime" =~ ^[0-9]+$ ]]; then
        echo "inconnu"
        return
    fi

    cache_age_sec=$(($(date +%s) - cache_mtime))

    # Protection contre valeurs negatives ou aberrantes
    if [[ "$cache_age_sec" -lt 0 ]]; then
        echo "inconnu"
    elif [[ "$cache_age_sec" -lt 60 ]]; then
        echo "${cache_age_sec} sec"
    elif [[ "$cache_age_sec" -lt 3600 ]]; then
        echo "$((cache_age_sec / 60)) min"
    elif [[ "$cache_age_sec" -lt 86400 ]]; then
        echo "$((cache_age_sec / 3600)) h"
    else
        echo "$((cache_age_sec / 86400)) j"
    fi
}

parse_quick_action() {
    # Parse une entree comme "2s", "2l", "2i", "12s" etc.
    # Retourne "peer_num:action" ou "invalid"
    local input="$1"
    input=$(echo "$input" | tr '[:upper:]' '[:lower:]')

    # Pattern: un ou plusieurs chiffres suivis optionnellement d'une lettre (s/l/i)
    if [[ "$input" =~ ^([0-9]+)([sli])?$ ]]; then
        local peer_num="${BASH_REMATCH[1]}"
        local action="${BASH_REMATCH[2]:-menu}"  # Default: ouvrir sous-menu
        echo "${peer_num}:${action}"
    else
        echo "invalid"
    fi
}

# ============================================
# GESTION DES FAVORIS
# ============================================

init_favorites() {
    mkdir -p "$CONFIG_DIR"
    touch "$FAVORITES_FILE"
}

is_favorite() {
    local peer_id="$1"
    [ -f "$FAVORITES_FILE" ] && grep -q "^${peer_id}$" "$FAVORITES_FILE"
}

add_favorite() {
    local peer_id="$1"
    init_favorites
    if ! is_favorite "$peer_id"; then
        echo "$peer_id" >> "$FAVORITES_FILE"
    fi
}

remove_favorite() {
    local peer_id="$1"
    if [ -f "$FAVORITES_FILE" ]; then
        local temp_file
        temp_file=$(mktemp)
        grep -v "^${peer_id}$" "$FAVORITES_FILE" > "$temp_file" || true
        mv "$temp_file" "$FAVORITES_FILE"
    fi
}

get_favorites_count() {
    if [ -f "$FAVORITES_FILE" ]; then
        wc -l < "$FAVORITES_FILE" | tr -d ' '
    else
        echo "0"
    fi
}

display_favorites() {
    if [ ! -f "$FAVORITES_FILE" ] || [ ! -s "$FAVORITES_FILE" ]; then
        log_message "${YELLOW}Aucun favori enregistre.${NC}"
        return 1
    fi

    if [ ! -f "$CACHE_FILE" ]; then
        log_message "${RED}Aucun cache disponible.${NC}"
        return 1
    fi

    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}                              PEERS FAVORIS                                    ${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════════════════${NC}"
    echo ""

    printf "${CYAN}%-5s${NC}| ${CYAN}%-25s${NC} | ${CYAN}%-15s${NC} | ${CYAN}%-20s${NC} | ${CYAN}%-6s${NC}\n" \
        "#" "Nom" "IP NetBird" "OS" "Statut"
    echo "-----+---------------------------+-----------------+----------------------+-------"

    local fav_index=1
    while IFS= read -r peer_id; do
        [ -z "$peer_id" ] && continue

        # Chercher le peer dans le cache
        local peer_json
        peer_json=$(jq -c ".[] | select(.id == \"$peer_id\")" "$CACHE_FILE" 2>/dev/null)

        if [ -n "$peer_json" ] && [ "$peer_json" != "null" ]; then
            local name hostname ip os connected
            name=$(echo "$peer_json" | jq -r '.name // ""')
            hostname=$(echo "$peer_json" | jq -r '.hostname // ""')
            ip=$(echo "$peer_json" | jq -r '.ip // "N/A"')
            os=$(echo "$peer_json" | jq -r '.os // "N/A"' | cut -c1-20)
            connected=$(echo "$peer_json" | jq -r '.connected // false')

            local display_name="${name:-$hostname}"
            display_name="${display_name:0:25}"

            local status_text status_color status_symbol
            if [ "$connected" = "true" ]; then
                status_text="Connecte"
                status_color="${GREEN}"
                status_symbol="✓"
            else
                status_text="Offline"
                status_color="${RED}"
                status_symbol="✗"
            fi

            local index_display="${status_symbol} ${fav_index}"
            printf "${status_color}%-5s${NC}| %-25s | %-15s | %-20s | ${status_color}%-6s${NC}\n" \
                "$index_display" "$display_name" "$ip" "$os" "$status_text"
        fi

        ((fav_index++))
    done < "$FAVORITES_FILE"

    echo ""
    return 0
}

get_favorite_peer_by_index() {
    local index=$1
    if [ ! -f "$FAVORITES_FILE" ]; then
        return
    fi

    local peer_id
    peer_id=$(sed -n "${index}p" "$FAVORITES_FILE")

    if [ -n "$peer_id" ] && [ -f "$CACHE_FILE" ]; then
        jq -c ".[] | select(.id == \"$peer_id\")" "$CACHE_FILE" 2>/dev/null
    fi
}

confirm_action() {
    while true; do
        read -rp "$1 (o/n) : " response
        case "$response" in
            [Oo]) return 0 ;;
            [Nn]) return 1 ;;
            *) echo "Veuillez repondre par 'o' ou 'n'" ;;
        esac
    done
}

check_dependencies() {
    local missing=()

    if ! command -v jq &>/dev/null; then
        missing+=("jq")
    fi

    if ! command -v netbird &>/dev/null; then
        missing+=("netbird")
    fi

    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${RED}Dependances manquantes : ${missing[*]}${NC}"
        echo ""

        if command -v brew &>/dev/null; then
            if confirm_action "Installer les dependances via Homebrew ?"; then
                for dep in "${missing[@]}"; do
                    echo -e "${YELLOW}Installation de $dep...${NC}"
                    if [ "$dep" = "netbird" ]; then
                        brew install netbirdio/tap/netbird
                    else
                        brew install "$dep"
                    fi
                done
                echo -e "${GREEN}Installation terminee.${NC}"
            else
                echo -e "${RED}Installation annulee. Le script ne peut pas continuer.${NC}"
                exit 1
            fi
        else
            echo -e "${RED}Homebrew n'est pas installe.${NC}"
            echo "Installez les dependances manuellement :"
            echo "  brew install jq"
            echo "  brew install netbirdio/tap/netbird"
            exit 1
        fi
    fi
}

# ============================================
# FONCTIONS NETBIRD
# ============================================

check_netbird_connection() {
    if ! command -v netbird &>/dev/null; then
        echo -e "${RED}NetBird CLI n'est pas installe.${NC}"
        return 1
    fi

    # Verifier le statut NetBird
    local netbird_status
    netbird_status=$(netbird status 2>/dev/null || echo "")

    if echo "$netbird_status" | grep -q "Connected"; then
        return 0
    fi

    # Non connecte - proposer de se connecter
    echo ""
    echo -e "${RED}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║              NETBIRD NON CONNECTE                             ║${NC}"
    echo -e "${RED}╚═══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "Statut actuel :"
    echo "$netbird_status" | head -5
    echo ""

    if confirm_action "Lancer 'netbird up' pour se connecter ?"; then
        echo ""
        log_message "${YELLOW}Connexion a NetBird en cours...${NC}"
        netbird up

        # Attendre quelques secondes et reverifier
        sleep 3

        if netbird status 2>/dev/null | grep -q "Connected"; then
            echo ""
            log_message "${GREEN}Connexion NetBird etablie !${NC}"
            sleep 1
            return 0
        else
            echo ""
            log_message "${RED}La connexion n'a pas pu etre etablie.${NC}"
            echo -e "Verifiez votre configuration NetBird et reessayez."
            return 1
        fi
    else
        echo ""
        log_message "${RED}Connexion NetBird requise pour utiliser ce script.${NC}"
        return 1
    fi
}

fetch_peers() {
    local force_refresh="${1:-false}"

    mkdir -p "$CACHE_DIR"

    # Verifier la validite du cache
    if [ "$force_refresh" = "false" ] && [ -f "$CACHE_FILE" ]; then
        local cache_age
        if [[ "$OSTYPE" == "darwin"* ]]; then
            cache_age=$(($(date +%s) - $(stat -f%m "$CACHE_FILE" 2>/dev/null || echo 0)))
        else
            cache_age=$(($(date +%s) - $(stat -c%Y "$CACHE_FILE" 2>/dev/null || echo 0)))
        fi

        if [ "$cache_age" -lt "$CACHE_TTL" ]; then
            return 0
        fi
    fi

    log_message "${YELLOW}Recuperation des peers NetBird...${NC}"

    local response
    response=$(curl -s -X GET "$NETBIRD_API_URL" \
        -H "Authorization: Token $NETBIRD_API_TOKEN" \
        -H "Content-Type: application/json" 2>/dev/null)

    if [ -z "$response" ]; then
        log_message "${RED}Erreur : Impossible de contacter l'API NetBird.${NC}"
        return 1
    fi

    if ! echo "$response" | jq -e 'type == "array"' >/dev/null 2>&1; then
        log_message "${RED}Erreur : Reponse API invalide.${NC}"
        echo "$response" | head -c 200
        return 1
    fi

    echo "$response" > "$CACHE_FILE"
    local count
    count=$(echo "$response" | jq 'length')
    log_message "${GREEN}$count peers recuperes.${NC}"
}

display_peers_list() {
    if [ ! -f "$CACHE_FILE" ]; then
        log_message "${RED}Aucun cache disponible. Lancez d'abord une recuperation.${NC}"
        return 1
    fi

    # Recuperer les routes pour les IPs LAN (silencieux)
    fetch_routes_silent

    # Compter les peers et recuperer l'age du cache
    local peer_count cache_age cache_warning=""
    peer_count=$(jq 'length' "$CACHE_FILE" 2>/dev/null || echo "0")
    cache_age=$(get_cache_age)

    # Avertissement si cache > 4 min
    local cache_mtime cache_age_sec=0
    if [[ "$OSTYPE" == "darwin"* ]]; then
        cache_mtime=$(stat -f%m "$CACHE_FILE" 2>/dev/null) || cache_mtime=""
    else
        cache_mtime=$(stat -c%Y "$CACHE_FILE" 2>/dev/null) || cache_mtime=""
    fi
    if [[ -n "$cache_mtime" && "$cache_mtime" =~ ^[0-9]+$ && "$cache_mtime" -gt 0 ]]; then
        cache_age_sec=$(($(date +%s) - cache_mtime))
    fi
    if [[ "$cache_age_sec" -gt 240 ]]; then
        cache_warning=" ${RED}(obsolete)${NC}"
    fi

    echo ""
    echo -e "${YELLOW}════════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}                         PEERS NETBIRD DISPONIBLES${NC} ${CYAN}(${peer_count} peers - maj il y a ${cache_age})${NC}${cache_warning}"
    echo -e "${YELLOW}════════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
    echo ""

    # En-tete du tableau
    printf "${CYAN}  #  ${NC}| ${CYAN}%-25s${NC} | ${CYAN}%-15s${NC} | ${CYAN}%-18s${NC} | ${CYAN}%-20s${NC} | ${CYAN}SSH${NC}\n" \
        "Nom" "IP NetBird" "Reseau LAN" "OS"
    echo "-----+---------------------------+-----------------+--------------------+----------------------+-----"

    local index=1
    # Tri alphabetique par nom (ou hostname si name vide)
    while IFS= read -r peer; do
        local id name hostname ip os ssh_enabled connected lan_network
        id=$(echo "$peer" | jq -r '.id // ""')
        name=$(echo "$peer" | jq -r '.name // ""')
        hostname=$(echo "$peer" | jq -r '.hostname // ""')
        ip=$(echo "$peer" | jq -r '.ip // "N/A"')
        os=$(echo "$peer" | jq -r '.os // "N/A"' | cut -c1-20)
        ssh_enabled=$(echo "$peer" | jq -r '.ssh_enabled // false')
        connected=$(echo "$peer" | jq -r '.connected // false')

        # Recuperer le reseau LAN depuis les routes
        lan_network=$(get_lan_network_for_peer "$id")
        lan_network="${lan_network:-N/A}"
        lan_network="${lan_network:0:18}"

        # Utiliser name ou hostname
        local display_name="${name:-$hostname}"
        display_name="${display_name:0:25}"

        # Couleur et symbole selon connexion
        local status_color="${RED}"
        local status_symbol="✗"
        if [ "$connected" = "true" ]; then
            status_color="${GREEN}"
            status_symbol="✓"
        fi

        # SSH status
        local ssh_status="${RED}Non${NC}"
        if [ "$ssh_enabled" = "true" ]; then
            ssh_status="${GREEN}Oui${NC}"
        fi

        # Format: "✓  1" ou "✗ 12" - symbole + index aligne a droite sur 3 chars
        printf "${status_color}%s %2d${NC} | %-25s | %-15s | %-18s | %-20s | %b\n" \
            "$status_symbol" "$index" "$display_name" "$ip" "$lan_network" "$os" "$ssh_status"

        ((index++))
    done < <(jq -c 'sort_by(.name // .hostname | ascii_downcase) | .[]' "$CACHE_FILE")

    echo ""
    echo -e "${CYAN}Legende :${NC} ${GREEN}✓${NC} Connecte | ${RED}✗${NC} Deconnecte"
    echo ""
}

get_peer_by_index() {
    local index=$1
    # Meme tri que display_peers_list pour correspondance des numeros
    jq -c "sort_by(.name // .hostname | ascii_downcase) | .[$((index - 1))]" "$CACHE_FILE" 2>/dev/null
}

# ============================================
# FONCTIONS SSH
# ============================================

detect_debian_version() {
    local peer_json="$1"
    local os_info
    os_info=$(echo "$peer_json" | jq -r '.os // ""')

    if echo "$os_info" | grep -qi "debian.*12\|bookworm"; then
        echo "12"
    elif echo "$os_info" | grep -qi "debian.*11\|bullseye"; then
        echo "11"
    else
        echo "unknown"
    fi
}

suggest_ssh_user() {
    local debian_version="$1"

    case "$debian_version" in
        "12") echo "$SSH_USER_DEBIAN_12" ;;
        "11") echo "$SSH_USER_DEBIAN_11" ;;
        *)    echo "$SSH_USER_DEBIAN_12" ;;
    esac
}

select_ssh_user() {
    local peer_json="$1"
    local debian_version
    debian_version=$(detect_debian_version "$peer_json")
    local suggested_user
    suggested_user=$(suggest_ssh_user "$debian_version")
    local peer_name
    peer_name=$(echo "$peer_json" | jq -r '.name // .hostname // "peer"')

    # Afficher sur stderr pour ne pas polluer la valeur de retour
    echo "" >&2
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════════${NC}" >&2
    echo -e "${YELLOW}           CHOIX DE L'UTILISATEUR SSH                          ${NC}" >&2
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════════${NC}" >&2
    echo "" >&2
    echo -e "Peer : ${CYAN}$peer_name${NC}" >&2

    if [ "$debian_version" != "unknown" ]; then
        echo -e "OS detecte : ${GREEN}Debian $debian_version${NC}" >&2
        echo -e "Utilisateur suggere : ${GREEN}$suggested_user${NC}" >&2
    else
        echo -e "OS detecte : ${YELLOW}Inconnu${NC}" >&2
        echo -e "Utilisateur par defaut : ${YELLOW}$suggested_user${NC}" >&2
    fi

    echo "" >&2
    echo -e "Quel utilisateur souhaitez-vous utiliser ?" >&2
    echo "" >&2
    echo -e "  ${GREEN}1)${NC} $SSH_USER_DEBIAN_12 (Debian 12 / Bookworm)" >&2
    echo -e "  ${GREEN}2)${NC} $SSH_USER_DEBIAN_11 (Debian 11 / Bullseye)" >&2
    echo -e "  ${GREEN}3)${NC} Saisir un autre utilisateur" >&2
    echo "" >&2

    read -rp "Votre choix [Entree pour $suggested_user] : " user_choice

    case "$user_choice" in
        1) echo "$SSH_USER_DEBIAN_12" ;;
        2) echo "$SSH_USER_DEBIAN_11" ;;
        3)
            read -rp "Nom d'utilisateur : " custom_user
            echo "$custom_user"
            ;;
        *)
            echo "$suggested_user"
            ;;
    esac
}


show_ssh_commands() {
    local peer_json="$1"
    local peer_ip
    peer_ip=$(echo "$peer_json" | jq -r '.ip')
    local peer_name
    peer_name=$(echo "$peer_json" | jq -r '.name // .hostname')

    # Selection de l'utilisateur
    local selected_user
    selected_user=$(select_ssh_user "$peer_json")

    # Commandes
    local ssh_cmd="ssh $selected_user@$peer_ip"
    local update_cmd='cd /media/.edge/edge-scripts 2>/dev/null || cd ~/edge-scripts; git pull; bash update_edge_gateway.sh'

    # Copier la commande SSH dans le presse-papiers
    echo -n "$ssh_cmd" | pbcopy

    echo ""
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  CONNEXION SSH - ${CYAN}$peer_name${NC}"
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${WHITE}1. Ouvrez un nouvel onglet et collez cette commande (deja copiee) :${NC}"
    echo ""
    echo -e "   ${GREEN}$ssh_cmd${NC}"
    echo ""
    echo -e "${WHITE}2. Une fois connecte, executez :${NC}"
    echo ""
    echo -e "   ${CYAN}$update_cmd${NC}"
    echo ""
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}✓ Commande SSH copiee dans le presse-papiers !${NC}"
    echo ""

    read -rp "Appuyez sur Entree pour continuer..."
    return 0
}

# Alias pour compatibilite
ssh_connect_with_fallback() {
    show_ssh_commands "$1"
}

# ============================================
# EXPORT CSV
# ============================================

readonly ROUTES_CACHE_FILE="$CACHE_DIR/routes_cache.json"

fetch_routes() {
    log_message "${YELLOW}Recuperation des routes NetBird...${NC}"

    local response
    response=$(curl -s -X GET "https://api.netbird.io/api/routes" \
        -H "Authorization: Token $NETBIRD_API_TOKEN" \
        -H "Content-Type: application/json" 2>/dev/null)

    if [ -z "$response" ]; then
        log_message "${RED}Erreur : Impossible de recuperer les routes.${NC}"
        return 1
    fi

    echo "$response" > "$ROUTES_CACHE_FILE"
    local count
    count=$(echo "$response" | jq 'length' 2>/dev/null || echo "0")
    log_message "${GREEN}$count routes recuperees.${NC}"
}

fetch_routes_silent() {
    # Version silencieuse de fetch_routes (pas de log)
    # Utilise le cache si disponible et recent
    if [ -f "$ROUTES_CACHE_FILE" ]; then
        local cache_age
        if [[ "$OSTYPE" == "darwin"* ]]; then
            cache_age=$(($(date +%s) - $(stat -f%m "$ROUTES_CACHE_FILE" 2>/dev/null || echo 0)))
        else
            cache_age=$(($(date +%s) - $(stat -c%Y "$ROUTES_CACHE_FILE" 2>/dev/null || echo 0)))
        fi
        # Cache valide pendant 5 minutes
        if [ "$cache_age" -lt 300 ]; then
            return 0
        fi
    fi

    local response
    response=$(curl -s -X GET "https://api.netbird.io/api/routes" \
        -H "Authorization: Token $NETBIRD_API_TOKEN" \
        -H "Content-Type: application/json" 2>/dev/null)

    if [ -n "$response" ]; then
        echo "$response" > "$ROUTES_CACHE_FILE"
    fi
}

get_lan_network_for_peer() {
    local peer_id="$1"

    if [ ! -f "$ROUTES_CACHE_FILE" ]; then
        return
    fi

    # Chercher la route associee a ce peer
    jq -r ".[] | select(.peer == \"$peer_id\") | .network // empty" "$ROUTES_CACHE_FILE" 2>/dev/null | head -1
}

export_peers_to_csv() {
    if [ ! -f "$CACHE_FILE" ]; then
        fetch_peers
    fi

    # Recuperer les routes pour les IPs LAN
    fetch_routes

    local timestamp
    timestamp=$(date +"%Y-%m-%d_%H-%M-%S")
    local csv_file="netbird_peers_$timestamp.csv"

    log_message "Export vers $csv_file..."

    # En-tete CSV
    echo "name,hostname,dns_label,ip_netbird,connection_ip,lan_network,os,netbird_version,ssh_enabled,groups" > "$csv_file"

    # Donnees - tri alphabetique
    while IFS= read -r peer; do
        local id name hostname dns_label ip connection_ip os version ssh_enabled groups lan_network

        id=$(echo "$peer" | jq -r '.id // ""')
        name=$(echo "$peer" | jq -r '.name // ""')
        hostname=$(echo "$peer" | jq -r '.hostname // ""')
        dns_label=$(echo "$peer" | jq -r '.dns_label // ""')
        ip=$(echo "$peer" | jq -r '.ip // ""')
        connection_ip=$(echo "$peer" | jq -r '.connection_ip // ""')
        os=$(echo "$peer" | jq -r '.os // ""')
        version=$(echo "$peer" | jq -r '.version // ""')
        ssh_enabled=$(echo "$peer" | jq -r '.ssh_enabled // false')
        groups=$(echo "$peer" | jq -r '[.groups[]?.name // empty] | join(";")')

        # Recuperer le reseau LAN depuis les routes
        lan_network=$(get_lan_network_for_peer "$id")

        # Echapper les guillemets pour CSV
        name="${name//\"/\"\"}"
        hostname="${hostname//\"/\"\"}"
        os="${os//\"/\"\"}"

        echo "\"$name\",\"$hostname\",\"$dns_label\",\"$ip\",\"$connection_ip\",\"$lan_network\",\"$os\",\"$version\",$ssh_enabled,\"$groups\"" >> "$csv_file"

    done < <(jq -c 'sort_by(.name // .hostname | ascii_downcase) | .[]' "$CACHE_FILE")

    local count
    count=$(jq 'length' "$CACHE_FILE")

    echo ""
    echo -e "${GREEN}Export termine !${NC}"
    echo -e "Fichier : ${YELLOW}$csv_file${NC}"
    echo -e "Peers exportes : ${GREEN}$count${NC}"
}

# ============================================
# MENU PRINCIPAL
# ============================================

display_local_netbird_status() {
    if command -v netbird &>/dev/null; then
        local status_line ip_line
        status_line=$(netbird status 2>/dev/null | grep "Status:" | head -1 || echo "")
        ip_line=$(netbird status 2>/dev/null | grep "NetBird IP:" | head -1 || echo "")

        if [ -n "$status_line" ]; then
            echo -e "${CYAN}NetBird :${NC} $status_line"
            if [ -n "$ip_line" ]; then
                echo -e "          $ip_line"
            fi
        fi
    fi
}

select_and_connect_peer() {
    echo ""
    read -rp "Numero du peer (ou 'q' pour annuler) : " peer_num

    if [ "$peer_num" = "q" ] || [ "$peer_num" = "Q" ]; then
        return 0
    fi

    # Valider que c'est un nombre
    if ! [[ "$peer_num" =~ ^[0-9]+$ ]]; then
        log_message "${RED}Entree invalide.${NC}"
        return 1
    fi

    # Recuperer le peer
    local peer_json
    peer_json=$(get_peer_by_index "$peer_num")

    if [ -z "$peer_json" ] || [ "$peer_json" = "null" ]; then
        log_message "${RED}Peer non trouve.${NC}"
        return 1
    fi

    local peer_connected peer_name ssh_enabled
    peer_connected=$(echo "$peer_json" | jq -r '.connected')
    peer_name=$(echo "$peer_json" | jq -r '.name // .hostname')
    ssh_enabled=$(echo "$peer_json" | jq -r '.ssh_enabled // false')

    if [ "$peer_connected" != "true" ]; then
        log_message "${YELLOW}Attention : Le peer '$peer_name' n'est pas connecte.${NC}"
        if ! confirm_action "Tenter la connexion quand meme ?"; then
            return 0
        fi
    fi

    if [ "$ssh_enabled" != "true" ]; then
        log_message "${YELLOW}Attention : SSH n'est pas active sur ce peer.${NC}"
        if ! confirm_action "Tenter la connexion quand meme ?"; then
            return 0
        fi
    fi

    ssh_connect_with_fallback "$peer_json"
}

# ============================================
# INTERFACE WEB EDGE (PORT 8080)
# ============================================

fetch_edge_web_info() {
    local peer_ip="$1"
    local peer_name="$2"
    local timeout=5

    log_message "Recuperation des infos depuis http://$peer_ip:8080/..."

    local html
    html=$(curl -s --connect-timeout "$timeout" "http://$peer_ip:8080/" 2>/dev/null)

    if [ -z "$html" ]; then
        log_message "${RED}Impossible de contacter l'interface web du peer.${NC}"
        return 1
    fi

    # Parser le HTML pour extraire les infos (compatible macOS et Linux)
    echo ""
    echo -e "${YELLOW}══════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}                    INFOS GATEWAY - ${CYAN}$peer_name${NC}"
    echo -e "${YELLOW}══════════════════════════════════════════════════════════════════════════════${NC}"
    echo ""

    # Fonction helper pour extraire une valeur
    extract_value() {
        local pattern="$1"
        echo "$html" | sed -n "s/.*${pattern} : \([^<]*\).*/\1/p" | head -1
    }

    # Extraire les infos principales
    local mac version mqtt_status paired site_uuid config_ts
    mac=$(extract_value "Identifiant")
    version=$(extract_value "Version logicielle")
    mqtt_status=$(extract_value "Passerelle connectée au MQTT")
    paired=$(extract_value "Passerelle appairée")
    site_uuid=$(extract_value "UUID du site")
    config_ts=$(extract_value "Timestamp de la config")

    echo -e "${BLUE}Informations Gateway${NC}"
    echo -e "${BLUE}────────────────────${NC}"
    printf "  ${GREEN}%-25s${NC} : %s\n" "Identifiant (MAC)" "${mac:-N/A}"
    printf "  ${GREEN}%-25s${NC} : %s\n" "Version logicielle" "${version:-N/A}"
    printf "  ${GREEN}%-25s${NC} : %s\n" "Connecte MQTT" "${mqtt_status:-N/A}"
    printf "  ${GREEN}%-25s${NC} : %s\n" "Appaire" "${paired:-N/A}"
    printf "  ${GREEN}%-25s${NC} : %s\n" "UUID Site" "${site_uuid:-N/A}"
    printf "  ${GREEN}%-25s${NC} : %s\n" "Config timestamp" "${config_ts:-N/A}"
    echo ""

    # Extraire les infos IP
    local ip_addr gateway_ip dns mask
    ip_addr=$(extract_value "Adresse IP")
    gateway_ip=$(extract_value "Passerelle par défaut")
    dns=$(extract_value "Serveurs DNS")
    mask=$(extract_value "Masque de sous-réseau")

    echo -e "${BLUE}Configuration Reseau${NC}"
    echo -e "${BLUE}────────────────────${NC}"
    printf "  ${GREEN}%-25s${NC} : %s\n" "Adresse IP LAN" "${ip_addr:-N/A}"
    printf "  ${GREEN}%-25s${NC} : %s\n" "Passerelle" "${gateway_ip:-N/A}"
    printf "  ${GREEN}%-25s${NC} : %s\n" "DNS" "${dns:-N/A}"
    printf "  ${GREEN}%-25s${NC} : %s\n" "Masque" "${mask:-N/A}"
    echo ""

    # Compter les points BACnet
    local bacnet_count
    bacnet_count=$(echo "$html" | grep -c '<tr>' || echo "0")
    bacnet_count=$((bacnet_count - 1))  # Soustraire la ligne d'en-tete
    [ "$bacnet_count" -lt 0 ] && bacnet_count=0

    echo -e "${BLUE}Points BACnet${NC}"
    echo -e "${BLUE}─────────────${NC}"
    printf "  ${GREEN}%-25s${NC} : %s\n" "Nombre de points" "$bacnet_count"
    echo ""

    return 0
}

# ============================================
# LOGS DISTANTS (VIA INTERFACE WEB)
# ============================================

fetch_peer_logs() {
    local peer_ip="$1"
    local peer_name="$2"
    local timeout=5

    echo ""
    log_message "Recuperation de la liste des logs depuis http://$peer_ip:8080/..."

    # Recuperer la page HTML
    local html
    html=$(curl -s --connect-timeout "$timeout" "http://$peer_ip:8080/" 2>/dev/null)

    if [ -z "$html" ]; then
        log_message "${RED}Impossible de contacter l'interface web du peer.${NC}"
        return 1
    fi

    # Extraire les fichiers de log (BACNET-*.log et BACNET-*.log.gz)
    local logs_list
    logs_list=$(echo "$html" | grep -o 'href="BACNET-[^"]*"' | sed 's/href="//;s/"$//' | head -20)

    if [ -z "$logs_list" ]; then
        log_message "${RED}Aucun fichier de log trouve sur ce peer.${NC}"
        return 1
    fi

    # Construire le tableau des fichiers de log
    local -a log_files=()
    while IFS= read -r log_file; do
        log_files+=("$log_file")
    done <<< "$logs_list"

    # Boucle principale pour la navigation dans les logs
    while true; do
        # Afficher la liste des logs disponibles
        clear
        echo ""
        echo -e "${YELLOW}══════════════════════════════════════════════════════════════════════════════${NC}"
        echo -e "${YELLOW}                    LOGS DISPONIBLES - ${CYAN}$peer_name${NC}"
        echo -e "${YELLOW}══════════════════════════════════════════════════════════════════════════════${NC}"
        echo ""

        local index=1
        for log_file in "${log_files[@]}"; do
            local log_date
            log_date=$(echo "$log_file" | sed 's/BACNET-//;s/\.log.*//')
            local compressed=""
            if [[ "$log_file" == *.gz ]]; then
                compressed=" ${YELLOW}(compresse)${NC}"
            fi
            printf "  ${GREEN}%2d.${NC} %s%b\n" "$index" "$log_date" "$compressed"
            ((index++))
        done

        echo ""
        echo -e "  ${CYAN}Fichier (1-${#log_files[@]})${NC} ou ${RED}q${NC} pour quitter"
        echo -ne "  ${CYAN}▸${NC} "
        local log_choice
        log_choice=$(read_menu_input)

        if [ "$log_choice" = "q" ] || [ "$log_choice" = "Q" ]; then
            return 0
        fi

        # Valider le choix
        if ! [[ "$log_choice" =~ ^[0-9]+$ ]] || [ "$log_choice" -lt 1 ] || [ "$log_choice" -gt "${#log_files[@]}" ]; then
            log_message "${RED}Choix invalide.${NC}"
            sleep 0.5
            continue
        fi

        local selected_log="${log_files[$((log_choice - 1))]}"

        # ========================================
        # GESTION DU CACHE DES LOGS
        # ========================================
        mkdir -p "$LOG_CACHE_DIR"

        # Nettoyer le nom du peer pour le cache
        local clean_peer_name
        clean_peer_name=$(echo "$peer_name" | tr ' ' '_' | tr -cd '[:alnum:]_-')
        local log_basename="${selected_log%.gz}"  # Enlever .gz si present
        local cache_file="$LOG_CACHE_DIR/${clean_peer_name}_${log_basename}"
        local log_file="$cache_file"  # Fichier a utiliser pour l'affichage

        # Extraire la date du log (format BACNET-YYYY-MM-DD.log)
        local log_date=""
        if [[ "$selected_log" =~ BACNET-([0-9]{4}-[0-9]{2}-[0-9]{2}) ]]; then
            log_date="${BASH_REMATCH[1]}"
        fi
        local today=$(date '+%Y-%m-%d')
        local is_today_log=false
        [ "$log_date" = "$today" ] && is_today_log=true

        local need_download=true
        echo ""

        # Verifier si le log est en cache
        if [ -f "$cache_file" ] && [ -s "$cache_file" ]; then
            local cache_size=$(wc -c < "$cache_file" | tr -d ' ')
            local cache_lines=$(wc -l < "$cache_file" | tr -d ' ')
            local cache_size_display=""
            if [ "$cache_size" -gt 1048576 ]; then
                cache_size_display="$(awk "BEGIN {printf \"%.1f\", $cache_size/1048576}") MB"
            elif [ "$cache_size" -gt 1024 ]; then
                cache_size_display="$(awk "BEGIN {printf \"%.0f\", $cache_size/1024}") KB"
            else
                cache_size_display="$cache_size octets"
            fi

            if [ "$is_today_log" = true ]; then
                # Log du jour en cache - demander a l'utilisateur
                echo -e "  ${CYAN}⚡${NC} Log en cache : ${CYAN}$cache_size_display${NC} (${cache_lines} lignes)"
                echo ""
                echo -e "  ${GREEN}1${NC}  Utiliser le cache (rapide)"
                echo -e "  ${GREEN}2${NC}  Retelecharger (actualiser)"
                echo ""
                echo -ne "  ${CYAN}▸${NC} "
                local cache_choice
                read -rsn1 cache_choice
                [ -z "$cache_choice" ] && cache_choice="1"

                if [ "$cache_choice" = "1" ]; then
                    need_download=false
                    echo ""
                    echo -e "  ${GREEN}✓${NC} Utilisation du cache"
                fi
            else
                # Log ancien - utiliser le cache directement
                echo -e "  ${GREEN}✓${NC} Cache : ${CYAN}$cache_size_display${NC} (${cache_lines} lignes)"
                need_download=false
            fi
        fi

        # Telecharger si necessaire
        if [ "$need_download" = true ]; then
            if [[ "$selected_log" == *.gz ]]; then
                download_with_progress "http://$peer_ip:8080/$selected_log" "$timeout" | gunzip > "$cache_file" 2>/dev/null
            else
                download_with_progress "http://$peer_ip:8080/$selected_log" "$timeout" > "$cache_file"
            fi

            if [ ! -s "$cache_file" ]; then
                log_message "${RED}Impossible de telecharger le log.${NC}"
                rm -f "$cache_file"
                sleep 1
                continue
            fi
        fi
        echo ""

        # Afficher le nombre de lignes
        local line_count=$(wc -l < "$log_file" | tr -d ' ')
        log_message "${GREEN}$line_count lignes chargees${NC}"
        sleep 0.3

        # Fonction pour normaliser l'heure en HH:MM
        normalize_time() {
            local input="$1"
            input="${input//:}"  # Supprimer les :
            if [[ "$input" =~ ^[0-9]{1}$ ]]; then
                printf "%02d:00" "$input"
            elif [[ "$input" =~ ^[0-9]{2}$ ]]; then
                printf "%02d:00" "$((10#$input))"
            elif [[ "$input" =~ ^[0-9]{3}$ ]]; then
                printf "%02d:%02d" "${input:0:1}" "${input:1:2}"
            elif [[ "$input" =~ ^[0-9]{4}$ ]]; then
                printf "%02d:%02d" "$((10#${input:0:2}))" "$((10#${input:2:2}))"
            else
                echo ""
            fi
        }

        # Boucle pour changer de filtre sur le meme log
        while true; do
            # ========================================
            # MENU DES FILTRES (reorganise par categories)
            # ========================================
            clear
            echo ""
            echo -e "${YELLOW}══════════════════════════════════════════════════════════════════════════${NC}"
            echo -e "  ${YELLOW}FILTRES${NC} - ${CYAN}$selected_log${NC}"
            echo -e "${YELLOW}══════════════════════════════════════════════════════════════════════════${NC}"
            echo ""
            echo -e "  ${MAGENTA}TEMPOREL${NC}"
            echo -e "  ${GREEN}1${NC}   Dernieres N lignes"
            echo -e "  ${GREEN}2${NC}   Plage horaire"
            echo -e "  ${GREEN}3${NC}   Log integral"
            echo ""
            echo -e "  ${MAGENTA}SEVERITE${NC}"
            echo -e "  ${GREEN}4${NC}   Erreurs uniquement"
            echo -e "  ${GREEN}5${NC}   Warnings + erreurs"
            echo ""
            echo -e "  ${MAGENTA}THEMATIQUE${NC}"
            echo -e "  ${GREEN}6${NC}   MQTT (connexion, watchdog)"
            echo -e "  ${GREEN}7${NC}   Polling / valeurs"
            echo -e "  ${GREEN}8${NC}   Connectivite"
            echo -e "  ${GREEN}9${NC}   Keep-alive"
            echo -e "  ${GREEN}10${NC}  Commandes utilisateur"
            echo -e "  ${GREEN}11${NC}  Schedulers"
            echo -e "  ${GREEN}12${NC}  Recherche par mot-cle"
            echo ""
            echo -e "${BLUE}──────────────────────────────────────────────────────────────────────────${NC}"
            echo -e "  ${CYAN}g${NC}  Aller a une heure"
            echo -e "  ${CYAN}l${NC}  Changer de fichier log"
            echo -e "  ${RED}q${NC}  Quitter"
            echo ""
            echo -ne "  ${CYAN}▸${NC} "
            local filter_choice
            filter_choice=$(read_menu_input)

            # Options de navigation
            if [ "$filter_choice" = "q" ] || [ "$filter_choice" = "Q" ]; then
                return 0
            fi
            if [ "$filter_choice" = "l" ] || [ "$filter_choice" = "L" ]; then
                break  # Retour au choix du fichier log
            fi
            if [ "$filter_choice" = "g" ] || [ "$filter_choice" = "G" ]; then
                # Aller a une heure precise - afficher a partir de cette minute
                echo ""
                echo -e "${CYAN}Formats acceptes: 8, 08, 800, 0800, 8:00, 08:00, 8:35, 08:35${NC}"
                read -rp "Aller a quelle heure:minute ? " goto_time

                if [ -n "$goto_time" ]; then
                    local norm_time
                    norm_time=$(normalize_time "$goto_time" 2>/dev/null || echo "")

                    if [ -n "$norm_time" ]; then
                        # Filtrer a partir de cette heure (compatible BSD awk)
                        local goto_filtered_file=$(mktemp)
                        awk -v start="$norm_time" '
                            BEGIN { found=0 }
                            {
                                time = ""
                                # Format [DD/MM/YYYY HH:MM:SS
                                if (match($0, /\[[0-9][0-9]\/[0-9][0-9]\/[0-9][0-9][0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]/)) {
                                    ts = substr($0, RSTART, RLENGTH)
                                    time = substr(ts, 13, 5)
                                }
                                # Format [YYYY-MM-DD HH:MM:SS]
                                else if (match($0, /\[[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]\]/)) {
                                    ts = substr($0, RSTART, RLENGTH)
                                    time = substr(ts, 13, 5)
                                }
                                if (time != "" && time >= start) found=1
                                if (found) print
                            }
                        ' "$log_file" > "$goto_filtered_file"

                        local filter_desc="a partir de $norm_time"

                        # Afficher directement avec pagination
                        if [ -s "$goto_filtered_file" ]; then
                            local header_info="${YELLOW}LOG: ${CYAN}$selected_log${NC} ${YELLOW}| Filtre: ${CYAN}$filter_desc${NC}"
                            display_with_time_paging_file "$goto_filtered_file" "$header_info"
                        else
                            echo -e "${YELLOW}Aucune ligne a partir de $norm_time.${NC}"
                            sleep 2
                        fi
                        rm -f "$goto_filtered_file"
                        continue
                    else
                        echo -e "${RED}Format invalide.${NC}"
                        sleep 1
                        continue
                    fi
                fi
                continue
            fi

            # Variables pour le filtrage (utilise le fichier cache)
            local filtered_file=$(mktemp)
            cat "$log_file" > "$filtered_file"
            local filter_desc="integral"
            local filter_filename="integral"
            local base_file="$log_file"
            local time_range_desc=""
            local time_range_filename=""

            # ========================================
            # MENU 2 : PERIMETRE (pour filtres 4-12)
            # ========================================
            if [[ "$filter_choice" =~ ^(4|5|6|7|8|9|10|11|12)$ ]]; then
                clear
                echo ""
                echo -e "${YELLOW}══════════════════════════════════════════════════════════════════════════${NC}"
                echo -e "  ${YELLOW}PERIMETRE${NC} - ${CYAN}$selected_log${NC}"
                echo -e "${YELLOW}══════════════════════════════════════════════════════════════════════════${NC}"
                echo ""
                echo -e "  ${GREEN}1${NC}  Log integral"
                echo -e "  ${GREEN}2${NC}  Plage horaire"
                echo ""
                echo -ne "  ${CYAN}▸${NC} "
                local scope_choice
                read -rsn1 scope_choice
                [ -z "$scope_choice" ] && scope_choice="1"

                if [ "$scope_choice" = "2" ]; then
                    echo ""
                    echo -e "${CYAN}Formats acceptes: 8, 08, 800, 0800, 8:00, 08:00${NC}"
                    read -rp "Heure de debut : " start_input
                    read -rp "Heure de fin : " end_input

                    local start_time end_time
                    start_time=$(normalize_time "$start_input")
                    end_time=$(normalize_time "$end_input")

                    if [[ -n "$start_time" ]] && [[ -n "$end_time" ]]; then
                        # Creer un fichier temporaire pour le perimetre filtre
                        base_file=$(mktemp)
                        awk -v start="$start_time" -v end="$end_time" '
                            /^\[/ {
                                time = substr($0, 13, 5)
                                if (time >= start && time <= end) print
                            }
                        ' "$log_file" > "$base_file"
                        time_range_desc=" ($start_time - $end_time)"
                        time_range_filename="_${start_time//:/-}-${end_time//:/-}"
                    else
                        log_message "${YELLOW}Format horaire invalide. Application sur log integral.${NC}"
                    fi
                fi
            fi

            # ========================================
            # APPLICATION DU FILTRE (operations sur fichiers)
            # ========================================
            case "$filter_choice" in
                1)
                    echo ""
                    read -rp "Nombre de lignes a afficher [100] : " num_lines
                    num_lines="${num_lines:-100}"
                    if [[ "$num_lines" =~ ^[0-9]+$ ]]; then
                        tail -n "$num_lines" "$log_file" > "$filtered_file"
                        filter_desc="dernieres $num_lines lignes"
                        filter_filename="tail-$num_lines"
                    else
                        log_message "${YELLOW}Nombre invalide. Affichage integral.${NC}"
                    fi
                    ;;
                2)
                    echo ""
                    echo -e "${CYAN}Formats acceptes: 8, 08, 800, 0800, 8:00, 08:00${NC}"
                    read -rp "Heure de debut : " start_input
                    read -rp "Heure de fin : " end_input

                    local start_time end_time
                    start_time=$(normalize_time "$start_input")
                    end_time=$(normalize_time "$end_input")

                    if [[ -n "$start_time" ]] && [[ -n "$end_time" ]]; then
                        awk -v start="$start_time" -v end="$end_time" '
                            /^\[/ {
                                time = substr($0, 13, 5)
                                if (time >= start && time <= end) print
                            }
                        ' "$log_file" > "$filtered_file"
                        filter_desc="$start_time - $end_time"
                        filter_filename="${start_time//:/-}-${end_time//:/-}"
                    else
                        log_message "${YELLOW}Format horaire invalide. Affichage integral.${NC}"
                    fi
                    ;;
                3)
                    # Log integral - le fichier filtre est deja une copie du log
                    filter_desc="integral"
                    filter_filename="integral"
                    ;;
                4)
                    grep -i '\[error\]' "$base_file" > "$filtered_file" 2>/dev/null || true
                    filter_desc="erreurs$time_range_desc"
                    filter_filename="erreurs$time_range_filename"
                    ;;
                5)
                    grep -iE '\[(error|warn)\]' "$base_file" > "$filtered_file" 2>/dev/null || true
                    filter_desc="warnings et erreurs$time_range_desc"
                    filter_filename="warnings$time_range_filename"
                    ;;
                6)
                    # Messages MQTT (statut, watchdog, connexion) - exclut les publish de valeurs
                    grep -iE 'MQTT Broker status|MQTT connected|MQTT disconnected|watchdog|MQTT.*check|Connected to MQTT|Disconnected from MQTT' "$base_file" 2>/dev/null | grep -v 'Publish message' > "$filtered_file" || true
                    filter_desc="messages MQTT$time_range_desc"
                    filter_filename="mqtt$time_range_filename"
                    ;;
                7)
                    grep -iE 'Polling|Received value|Received COV' "$base_file" > "$filtered_file" 2>/dev/null || true
                    filter_desc="polling / valeurs$time_range_desc"
                    filter_filename="polling$time_range_filename"
                    ;;
                8)
                    grep -iE 'internet connectivity|MQTT Broker status|online|offline' "$base_file" > "$filtered_file" 2>/dev/null || true
                    filter_desc="connectivite$time_range_desc"
                    filter_filename="connectivite$time_range_filename"
                    ;;
                9)
                    grep -i 'keep-alive' "$base_file" > "$filtered_file" 2>/dev/null || true
                    filter_desc="keep-alive$time_range_desc"
                    filter_filename="keepalive$time_range_filename"
                    ;;
                10)
                    # Commandes utilisateur depuis apps Buildy (exclut schedulers cloud)
                    # Analyse les 10 lignes suivantes pour verifier si Successfully set/reset
                    awk '
                        /Received message.*source_app/ && !/from_scheduler/ && !/cloud_scheduler/ {
                            cmd_line = $0
                            found_success = 0
                            success_line = ""
                            for (i = 1; i <= 10; i++) {
                                if ((getline next_line) > 0) {
                                    if (next_line ~ /Successfully (set|reset) value/) {
                                        found_success = 1
                                        success_line = next_line
                                        break
                                    }
                                }
                            }
                            if (found_success) {
                                print cmd_line
                                print "  -> " success_line
                                print ""
                            } else {
                                print cmd_line
                                print "  -> [ECHEC] Pas de confirmation dans les 10 lignes suivantes"
                                print ""
                            }
                        }
                    ' "$base_file" > "$filtered_file"
                    filter_desc="commandes utilisateur$time_range_desc"
                    filter_filename="commandes$time_range_filename"
                    ;;
                11)
                    # Programmations horaires (schedulers locaux et cloud)
                    grep -iE 'scheduler_id|from_scheduler|Evaluating conditional' "$base_file" > "$filtered_file" 2>/dev/null || true
                    filter_desc="programmations horaires$time_range_desc"
                    filter_filename="schedulers$time_range_filename"
                    ;;
                12)
                    echo ""
                    read -rp "Mot-cle a rechercher : " keyword
                    if [[ -n "$keyword" ]]; then
                        grep -i "$keyword" "$base_file" > "$filtered_file" 2>/dev/null || true
                        filter_desc="recherche '$keyword'$time_range_desc"
                        # Nettoyer le mot-cle pour le nom de fichier (garder seulement alphanum et tirets)
                        local clean_keyword
                        clean_keyword=$(echo "$keyword" | tr -cd '[:alnum:]-_' | cut -c1-30)
                        filter_filename="search-$clean_keyword$time_range_filename"
                    else
                        log_message "${YELLOW}Mot-cle vide. Affichage integral.${NC}"
                        filter_desc="integral"
                        filter_filename="integral"
                    fi
                    ;;
                *)
                    log_message "${RED}Choix invalide.${NC}"
                    rm -f "$filtered_file"
                    [ "$base_file" != "$log_file" ] && rm -f "$base_file"
                    continue
                    ;;
            esac

            # ========================================
            # AFFICHAGE DES RESULTATS (fichiers)
            # ========================================
            clear
            local line_count=0
            [ -s "$filtered_file" ] && line_count=$(wc -l < "$filtered_file" | tr -d ' ')

            # Header info pour la pagination
            local header_info="${YELLOW}LOG: ${CYAN}$selected_log${NC} ${YELLOW}| Filtre: ${CYAN}$filter_desc${NC}"

            echo ""
            echo -e "${YELLOW}══════════════════════════════════════════════════════════════════════════════${NC}"
            echo -e "${YELLOW}  LOG: ${CYAN}$selected_log${NC} ${YELLOW}| Filtre: ${CYAN}$filter_desc${NC} ${YELLOW}| Lignes: ${CYAN}$line_count${NC}"
            echo -e "${YELLOW}══════════════════════════════════════════════════════════════════════════════${NC}"
            echo ""

            if [ ! -s "$filtered_file" ]; then
                echo -e "${YELLOW}Aucune ligne correspondant au filtre.${NC}"
                sleep 1
            else
                # Affichage avec pagination par tranches de minutes
                display_with_time_paging_file "$filtered_file" "$header_info"
            fi

            # Nettoyer les fichiers temporaires de ce cycle
            rm -f "$filtered_file"
            [ "$base_file" != "$log_file" ] && rm -f "$base_file"
        done  # Fin boucle filtrage
    done  # Fin boucle choix log
}

select_and_view_peer_logs() {
    echo ""
    read -rp "Numero du peer (ou 'q' pour annuler) : " peer_num

    if [ "$peer_num" = "q" ] || [ "$peer_num" = "Q" ]; then
        return 0
    fi

    # Valider que c'est un nombre
    if ! [[ "$peer_num" =~ ^[0-9]+$ ]]; then
        log_message "${RED}Entree invalide.${NC}"
        return 1
    fi

    # Recuperer le peer
    local peer_json
    peer_json=$(get_peer_by_index "$peer_num")

    if [ -z "$peer_json" ] || [ "$peer_json" = "null" ]; then
        log_message "${RED}Peer non trouve.${NC}"
        return 1
    fi

    local peer_ip peer_name peer_connected
    peer_ip=$(echo "$peer_json" | jq -r '.ip')
    peer_name=$(echo "$peer_json" | jq -r '.name // .hostname')
    peer_connected=$(echo "$peer_json" | jq -r '.connected')

    if [ "$peer_connected" != "true" ]; then
        log_message "${YELLOW}Attention : Le peer '$peer_name' n'est pas connecte.${NC}"
        if ! confirm_action "Tenter quand meme ?"; then
            return 0
        fi
    fi

    fetch_peer_logs "$peer_ip" "$peer_name"
}

select_and_view_peer_info() {
    echo ""
    read -rp "Numero du peer (ou 'q' pour annuler) : " peer_num

    if [ "$peer_num" = "q" ] || [ "$peer_num" = "Q" ]; then
        return 0
    fi

    # Valider que c'est un nombre
    if ! [[ "$peer_num" =~ ^[0-9]+$ ]]; then
        log_message "${RED}Entree invalide.${NC}"
        return 1
    fi

    # Recuperer le peer
    local peer_json
    peer_json=$(get_peer_by_index "$peer_num")

    if [ -z "$peer_json" ] || [ "$peer_json" = "null" ]; then
        log_message "${RED}Peer non trouve.${NC}"
        return 1
    fi

    local peer_ip peer_name peer_connected
    peer_ip=$(echo "$peer_json" | jq -r '.ip')
    peer_name=$(echo "$peer_json" | jq -r '.name // .hostname')
    peer_connected=$(echo "$peer_json" | jq -r '.connected')

    if [ "$peer_connected" != "true" ]; then
        log_message "${YELLOW}Attention : Le peer '$peer_name' n'est pas connecte.${NC}"
        if ! confirm_action "Tenter quand meme ?"; then
            return 0
        fi
    fi

    fetch_edge_web_info "$peer_ip" "$peer_name"
}

peer_context_menu() {
    local peer_json="$1"
    local peer_id peer_ip peer_name peer_os peer_connected ssh_enabled

    peer_id=$(echo "$peer_json" | jq -r '.id')
    peer_ip=$(echo "$peer_json" | jq -r '.ip')
    peer_name=$(echo "$peer_json" | jq -r '.name // .hostname')
    peer_os=$(echo "$peer_json" | jq -r '.os // "N/A"' | cut -c1-30)
    peer_connected=$(echo "$peer_json" | jq -r '.connected')
    ssh_enabled=$(echo "$peer_json" | jq -r '.ssh_enabled // false')

    # Statut affichage
    local status_text status_color
    if [ "$peer_connected" = "true" ]; then
        status_text="Connecte"
        status_color="${GREEN}"
    else
        status_text="Deconnecte"
        status_color="${RED}"
    fi

    local ssh_text
    if [ "$ssh_enabled" = "true" ]; then
        ssh_text="${GREEN}Oui${NC}"
    else
        ssh_text="${RED}Non${NC}"
    fi

    while true; do
        # Verifier si le peer est un favori
        local fav_text fav_action
        if is_favorite "$peer_id"; then
            fav_text="${YELLOW}★${NC} Retirer des favoris"
            fav_action="remove"
        else
            fav_text="☆ Ajouter aux favoris"
            fav_action="add"
        fi

        clear
        echo ""
        echo -e "${CYAN}══════════════════════════════════════════════════════════════════════════════${NC}"
        echo -e "${CYAN}  ${YELLOW}$peer_name${NC} ${CYAN}(${peer_ip}) | ${status_color}$status_text${NC}"
        echo -e "${CYAN}  OS: ${NC}$peer_os ${CYAN}| SSH: ${NC}$ssh_text"
        echo -e "${CYAN}══════════════════════════════════════════════════════════════════════════════${NC}"
        echo ""
        echo -e "  ${GREEN}s${NC}  Connexion SSH (mise a jour)"
        echo -e "  ${GREEN}l${NC}  Voir les logs BACNET"
        echo -e "  ${GREEN}i${NC}  Informations systeme"
        echo -e "  ${GREEN}c${NC}  Copier IP dans le presse-papiers"
        echo -e "  ${GREEN}f${NC}  $fav_text"
        echo ""
        echo -e "${BLUE}──────────────────────────────────────────────────────────────────────────────${NC}"
        echo -e "  ${RED}q${NC}  Retour"
        echo ""
        echo -ne "  ${CYAN}▸${NC} "
        local peer_choice
        read -rsn1 peer_choice

        case "$peer_choice" in
            f|F)
                if [ "$fav_action" = "add" ]; then
                    add_favorite "$peer_id"
                    log_message "${GREEN}★ ${CYAN}$peer_name${GREEN} ajoute aux favoris !${NC}"
                else
                    remove_favorite "$peer_id"
                    log_message "${YELLOW}☆ ${CYAN}$peer_name${YELLOW} retire des favoris.${NC}"
                fi
                sleep 1
                ;;
            s|S)
                if [ "$peer_connected" != "true" ]; then
                    log_message "${YELLOW}Attention : Le peer '$peer_name' n'est pas connecte.${NC}"
                    if ! confirm_action "Tenter la connexion quand meme ?"; then
                        continue
                    fi
                fi
                ssh_connect_with_fallback "$peer_json"
                attendre_q
                ;;
            l|L)
                if [ "$peer_connected" != "true" ]; then
                    log_message "${YELLOW}Attention : Le peer '$peer_name' n'est pas connecte.${NC}"
                    if ! confirm_action "Tenter quand meme ?"; then
                        continue
                    fi
                fi
                fetch_peer_logs "$peer_ip" "$peer_name"
                ;;
            i|I)
                if [ "$peer_connected" != "true" ]; then
                    log_message "${YELLOW}Attention : Le peer '$peer_name' n'est pas connecte.${NC}"
                    if ! confirm_action "Tenter quand meme ?"; then
                        continue
                    fi
                fi
                fetch_edge_web_info "$peer_ip" "$peer_name"
                attendre_q
                ;;
            c|C)
                echo -n "$peer_ip" | pbcopy
                log_message "${GREEN}IP ${CYAN}$peer_ip${GREEN} copiee dans le presse-papiers !${NC}"
                sleep 1
                ;;
            b|B|q|Q)
                return 0
                ;;
            *)
                ;;  # Ignorer les touches invalides
        esac
    done
}

execute_peer_action() {
    # Execute une action sur un peer (appele depuis le menu rapide)
    local peer_num="$1"
    local action="$2"

    # Recuperer le peer
    local peer_json
    peer_json=$(get_peer_by_index "$peer_num")

    if [ -z "$peer_json" ] || [ "$peer_json" = "null" ]; then
        log_message "${RED}Peer #$peer_num non trouve.${NC}"
        sleep 1
        return 1
    fi

    local peer_ip peer_name peer_connected
    peer_ip=$(echo "$peer_json" | jq -r '.ip')
    peer_name=$(echo "$peer_json" | jq -r '.name // .hostname')
    peer_connected=$(echo "$peer_json" | jq -r '.connected')

    case "$action" in
        menu)
            peer_context_menu "$peer_json"
            ;;
        s)
            if [ "$peer_connected" != "true" ]; then
                log_message "${YELLOW}Attention : Le peer '$peer_name' n'est pas connecte.${NC}"
                if ! confirm_action "Tenter la connexion quand meme ?"; then
                    return 0
                fi
            fi
            ssh_connect_with_fallback "$peer_json"
            attendre_q
            ;;
        l)
            if [ "$peer_connected" != "true" ]; then
                log_message "${YELLOW}Attention : Le peer '$peer_name' n'est pas connecte.${NC}"
                if ! confirm_action "Tenter quand meme ?"; then
                    return 0
                fi
            fi
            fetch_peer_logs "$peer_ip" "$peer_name"
            ;;
        i)
            if [ "$peer_connected" != "true" ]; then
                log_message "${YELLOW}Attention : Le peer '$peer_name' n'est pas connecte.${NC}"
                if ! confirm_action "Tenter quand meme ?"; then
                    return 0
                fi
            fi
            fetch_edge_web_info "$peer_ip" "$peer_name"
            attendre_q
            ;;
    esac
}

favorites_menu() {
    while true; do
        clear

        if ! display_favorites; then
            attendre_q
            return 0
        fi

        echo -e "${CYAN}Actions rapides :${NC}"
        echo -e "  ${GREEN}[N]${NC}   Ouvrir le menu du favori N"
        echo -e "  ${GREEN}[N]s${NC}  Connexion SSH directe"
        echo -e "  ${GREEN}[N]l${NC}  Voir les logs"
        echo -e "  ${GREEN}[N]i${NC}  Infos systeme"
        echo ""
        echo -e "${BLUE}──────────────────────────────────────────────────────────────────────────────${NC}"
        echo -e "  ${RED}q${NC}  Retour"
        echo ""
        echo -ne "  ${CYAN}▸${NC} "
        local fav_choice
        fav_choice=$(read_menu_input)

        case "$fav_choice" in
            b|B|q|Q)
                return 0
                ;;
            ""|" ")
                # Rafraichir
                ;;
            *)
                # Parser comme action rapide sur favoris
                local parsed
                parsed=$(parse_quick_action "$fav_choice")

                if [ "$parsed" != "invalid" ]; then
                    local fav_num action
                    fav_num="${parsed%%:*}"
                    action="${parsed##*:}"

                    # Recuperer le peer favori par index
                    local peer_json
                    peer_json=$(get_favorite_peer_by_index "$fav_num")

                    if [ -n "$peer_json" ] && [ "$peer_json" != "null" ]; then
                        local peer_ip peer_name peer_connected
                        peer_ip=$(echo "$peer_json" | jq -r '.ip')
                        peer_name=$(echo "$peer_json" | jq -r '.name // .hostname')
                        peer_connected=$(echo "$peer_json" | jq -r '.connected')

                        case "$action" in
                            menu)
                                peer_context_menu "$peer_json"
                                ;;
                            s)
                                if [ "$peer_connected" != "true" ]; then
                                    log_message "${YELLOW}Attention : Le peer '$peer_name' n'est pas connecte.${NC}"
                                    if ! confirm_action "Tenter la connexion quand meme ?"; then
                                        continue
                                    fi
                                fi
                                ssh_connect_with_fallback "$peer_json"
                                attendre_q
                                ;;
                            l)
                                if [ "$peer_connected" != "true" ]; then
                                    log_message "${YELLOW}Attention : Le peer '$peer_name' n'est pas connecte.${NC}"
                                    if ! confirm_action "Tenter quand meme ?"; then
                                        continue
                                    fi
                                fi
                                fetch_peer_logs "$peer_ip" "$peer_name"
                                ;;
                            i)
                                if [ "$peer_connected" != "true" ]; then
                                    log_message "${YELLOW}Attention : Le peer '$peer_name' n'est pas connecte.${NC}"
                                    if ! confirm_action "Tenter quand meme ?"; then
                                        continue
                                    fi
                                fi
                                fetch_edge_web_info "$peer_ip" "$peer_name"
                                attendre_q
                                ;;
                        esac
                    else
                        log_message "${RED}Favori #$fav_num non trouve.${NC}"
                        sleep 1
                    fi
                else
                    log_message "${RED}Commande invalide : $fav_choice${NC}"
                    sleep 1
                fi
                ;;
        esac
    done
}

main_menu() {
    while true; do
        clear
        echo ""
        echo -e "${YELLOW}═══════════════════════════════════════════════════════════════════════════════${NC}"
        echo -e "${YELLOW}                    EDGE MANAGEMENT - Buildy Edge v${SCRIPT_VERSION}           ${NC}"
        echo -e "${YELLOW}═══════════════════════════════════════════════════════════════════════════════${NC}"
        echo ""

        display_local_netbird_status
        echo ""

        # Afficher la liste des peers automatiquement
        fetch_peers
        display_peers_list

        # Compter les favoris
        local fav_count
        fav_count=$(get_favorites_count)

        # Menu rapide
        echo -e "${CYAN}Actions rapides :${NC}"
        echo -e "  ${GREEN}[N]${NC}   Ouvrir le menu du peer N"
        echo -e "  ${GREEN}[N]s${NC}  Connexion SSH directe au peer N"
        echo -e "  ${GREEN}[N]l${NC}  Voir les logs du peer N"
        echo -e "  ${GREEN}[N]i${NC}  Infos systeme du peer N"
        echo ""
        echo -e "${BLUE}──────────────────────────────────────────────────────────────────────────────${NC}"
        if [ "$fav_count" -gt 0 ]; then
            echo -e "  ${YELLOW}f${NC}  Favoris (${fav_count} peers)"
        else
            echo -e "  ${YELLOW}f${NC}  Favoris"
        fi
        echo -e "  ${YELLOW}r${NC}  Rafraichir la liste"
        echo -e "  ${YELLOW}e${NC}  Exporter en CSV"
        echo -e "  ${RED}q${NC}  Quitter"
        echo ""
        echo -ne "  ${CYAN}▸${NC} "
        local main_choice
        main_choice=$(read_menu_input)

        # Traiter les commandes speciales d'abord
        case "$main_choice" in
            f|F)
                favorites_menu
                ;;
            r|R)
                fetch_peers true
                log_message "${GREEN}Liste rafraichie.${NC}"
                sleep 1
                ;;
            e|E)
                export_peers_to_csv
                attendre_q
                ;;
            q|Q)
                echo ""
                log_message "${GREEN}Au revoir !${NC}"
                exit 0
                ;;
            "")
                # Entree vide = rafraichir l'affichage
                ;;
            *)
                # Essayer de parser comme une action rapide (ex: "2s", "15", "3l")
                local parsed
                parsed=$(parse_quick_action "$main_choice")

                if [ "$parsed" != "invalid" ]; then
                    local peer_num action
                    peer_num="${parsed%%:*}"
                    action="${parsed##*:}"
                    execute_peer_action "$peer_num" "$action"
                else
                    log_message "${RED}Commande invalide : $main_choice${NC}"
                    sleep 1
                fi
                ;;
        esac
    done
}

# ============================================
# POINT D'ENTREE
# ============================================

main() {
    clear
    echo ""
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}          EDGE MANAGEMENT - Buildy Edge v${SCRIPT_VERSION}     ${NC}"
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════════${NC}"
    echo ""

    # Verifier les dependances
    log_message "Verification des dependances..."
    check_dependencies

    # Verifier la connexion NetBird
    log_message "Verification de la connexion NetBird..."
    if ! check_netbird_connection; then
        exit 1
    fi

    # Afficher le statut NetBird
    local netbird_ip
    netbird_ip=$(netbird status 2>/dev/null | grep "NetBird IP:" | awk '{print $3}')
    echo ""
    log_message "${GREEN}NetBird connecte${NC} - IP: ${CYAN}$netbird_ip${NC}"

    # Creer le repertoire de cache
    mkdir -p "$CACHE_DIR"

    # Recuperation initiale des peers (force refresh au demarrage)
    echo ""
    fetch_peers true

    echo ""
    log_message "${GREEN}Initialisation terminee. Demarrage du menu...${NC}"
    sleep 1

    # Lancer le menu principal
    main_menu
}

main "$@"
