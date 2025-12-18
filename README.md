# Edge Management

Script de gestion des passerelles Buildy Edge via l'API Netbird.

## Installation

```bash
curl -fsSL https://raw.githubusercontent.com/buildy-bms/edge-management/main/install.sh | bash
```

## Prerequis

- macOS (testé sur Sonoma/Sequoia)
- [jq](https://stedolan.github.io/jq/) (`brew install jq`)
- Client Netbird connecté
- Token API Netbird personnel

## Configuration

Au premier lancement, le script vous demandera votre token API Netbird personnel.

Vous pouvez le trouver sur : https://app.netbird.io/settings

Le token est sauvegardé dans `~/.config/edge-management/config` (permissions 600).

### Configuration manuelle (optionnel)

Vous pouvez aussi créer le fichier de config manuellement :

```bash
mkdir -p ~/.config/edge-management
echo "NETBIRD_API_TOKEN=votre_token_ici" > ~/.config/edge-management/config
chmod 600 ~/.config/edge-management/config
```

Ou exporter la variable d'environnement :

```bash
export NETBIRD_API_TOKEN=votre_token_ici
```

## Utilisation

```bash
# Via l'alias (apres installation)
edge

# Ou directement
~/.local/bin/edge_management.sh
```

## Fonctionnalites

- Liste des peers Netbird avec statut (online/offline)
- Connexion SSH aux passerelles Edge
- Consultation des logs avec filtres (erreurs, MQTT, polling, etc.)
- Export CSV de la liste des peers
- Gestion des favoris
- Mode JSON Pretty pour les logs

## Mise a jour

Pour mettre a jour vers la derniere version :

```bash
curl -fsSL https://raw.githubusercontent.com/buildy-bms/edge-management/main/install.sh | bash
```

## Desinstallation

```bash
rm -f ~/.local/bin/edge_management.sh
rm -rf ~/.config/edge-management
# Optionnel : supprimer l'alias de votre .zshrc ou .bashrc
```

## Support

Pour toute question ou probleme, contactez l'equipe technique Buildy.
