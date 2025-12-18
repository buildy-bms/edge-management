#!/bin/bash
#
# Script d'installation de Edge Management
# Usage: curl -fsSL https://raw.githubusercontent.com/buildy-bms/edge-management/main/install.sh | bash
#

set -e

# Couleurs
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

REPO_URL="https://raw.githubusercontent.com/buildy-bms/edge-management/main"
SCRIPT_NAME="edge_management.sh"
INSTALL_DIR="$HOME/.local/bin"
ALIAS_NAME="edge"

echo ""
echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  Installation de Edge Management - Buildy                     ${NC}"
echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
echo ""

# Verifier les prerequis
echo -e "${YELLOW}Verification des prerequis...${NC}"

if ! command -v jq &> /dev/null; then
    echo -e "${RED}jq n'est pas installe.${NC}"
    if [[ "$OSTYPE" == "darwin"* ]]; then
        echo -e "Installation avec Homebrew..."
        brew install jq
    else
        echo -e "Installez jq avec: sudo apt install jq"
        exit 1
    fi
fi

if ! command -v curl &> /dev/null; then
    echo -e "${RED}curl n'est pas installe.${NC}"
    exit 1
fi

echo -e "${GREEN}Prerequis OK${NC}"
echo ""

# Creer le dossier d'installation
echo -e "${YELLOW}Creation du dossier d'installation...${NC}"
mkdir -p "$INSTALL_DIR"

# Telecharger le script
echo -e "${YELLOW}Telechargement de $SCRIPT_NAME...${NC}"
curl -fsSL "$REPO_URL/$SCRIPT_NAME" -o "$INSTALL_DIR/$SCRIPT_NAME"
chmod +x "$INSTALL_DIR/$SCRIPT_NAME"

echo -e "${GREEN}Script installe dans $INSTALL_DIR/$SCRIPT_NAME${NC}"
echo ""

# Ajouter au PATH si necessaire
add_to_path() {
    local shell_rc=""

    if [[ -n "$ZSH_VERSION" ]] || [[ "$SHELL" == *"zsh"* ]]; then
        shell_rc="$HOME/.zshrc"
    elif [[ -n "$BASH_VERSION" ]] || [[ "$SHELL" == *"bash"* ]]; then
        shell_rc="$HOME/.bashrc"
        [[ -f "$HOME/.bash_profile" ]] && shell_rc="$HOME/.bash_profile"
    fi

    if [[ -n "$shell_rc" ]]; then
        if ! grep -q "$INSTALL_DIR" "$shell_rc" 2>/dev/null; then
            echo "" >> "$shell_rc"
            echo "# Edge Management - Buildy" >> "$shell_rc"
            echo "export PATH=\"\$PATH:$INSTALL_DIR\"" >> "$shell_rc"
            echo -e "${YELLOW}PATH mis a jour dans $shell_rc${NC}"
        fi

        # Ajouter l'alias
        if ! grep -q "alias $ALIAS_NAME=" "$shell_rc" 2>/dev/null; then
            echo "alias $ALIAS_NAME='$INSTALL_DIR/$SCRIPT_NAME'" >> "$shell_rc"
            echo -e "${YELLOW}Alias '$ALIAS_NAME' ajoute${NC}"
        fi
    fi
}

add_to_path

echo ""
echo -e "${GREEN}══════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Installation terminee !                                      ${NC}"
echo -e "${GREEN}══════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "Pour utiliser Edge Management :"
echo -e "  ${CYAN}1.${NC} Ouvrez un nouveau terminal (ou tapez: source ~/.zshrc)"
echo -e "  ${CYAN}2.${NC} Lancez: ${GREEN}edge${NC} ou ${GREEN}edge_management.sh${NC}"
echo ""
echo -e "Au premier lancement, le script vous demandera votre token API Netbird."
echo -e "Vous pouvez le trouver sur: ${CYAN}https://app.netbird.io/settings${NC}"
echo ""
