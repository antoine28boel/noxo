# Passation — projet Noxo

Document de reprise pour une session Claude Code locale (PC Windows).
Tout ce qui a été décidé jusqu'ici est ici ; le code est sur `main`.

## 1. Préférences de l'utilisateur (à respecter)

- Répondre en français, strictement à ce qui est demandé, sans étapes non
  sollicitées, sans récap final ni disclaimer, réponses courtes.
- Ne pas créer de fichier/document/artifact sans demande explicite.
- **Prévenir avant** toute demande qui dépasserait ~10 % de la session.
- « oui » / « ok » = ne pas développer.

## 2. Vision

Un **assistant de vie** nommé **Noxo**, un hibou :

- résumé de la journée, agenda, gestion financière, tâches ;
- intégré à **Home Assistant** (HA), mais **disponible en permanence, même
  hors ligne**, sur **PC Windows** et **téléphone Android** (vraies apps, pas
  de PWA) ;
- finances via **Actual Budget** (+ liaison bancaire à étudier : GoCardless
  fermé aux nouveaux comptes, voir Enable Banking selon version d'Actual,
  sinon import OFX/CSV) ;
- plus tard : **robot physique** (hibou détachable sur une **perche** qui
  héberge le serveur HA et sert de station de recharge), et dans un « avenir
  fou » un **drone** d'intérieur qui le suit.

### Identité

- Nom : **Noxo** (veille nocturne, veille techno, « déconnexion du cloud » :
  tout tourne en local). Devise possible : « Noxo veille. Tes données dorment
  chez toi. » Mot d'éveil vocal : « Hey Noxo ».
- Style retenu : **A — mignon & arrondi** (façon peluche : plumage brun
  `#8B6B4F`, ventre crème, grands yeux ambrés, joues roses, aigrettes
  arrondies). Le design précis sera retravaillé plus tard.
- Espèce de référence : petit-duc / chevêche (compact, léger → drone).
- Plus tard : un **caractère unique qui évolue**.

## 3. Fonctionnalités à garder en tête (liste validée)

★ = prioritaire (MVP assistant)

- **Journée** : ★ brief du matin (agenda, météo, tâches, finances, alertes ;
  rédigé par l'IA de HA, version simple hors ligne) ; ★ vue « Aujourd'hui »
  (timeline, trajets, heure de départ) ; bilan du soir.
- **Agenda & tâches** : ★ agenda unifié via HA, hors ligne ; ★ tâches et
  rappels (récurrence, rappel géolocalisé via zones HA) ; liste de courses
  synchro HA ; saisie rapide en langage naturel.
- **Finances (Actual)** : ★ soldes et « reste à dépenser » par enveloppe ;
  ★ saisie de dépense hors ligne synchronisée ensuite ; ★ alertes (enveloppe
  presque vide, grosse dépense, solde bas) ; échéancier et solde prévisionnel ;
  détection d'abonnements/hausses ; graphiques.
- **Maison (HA)** : état maison dans le brief (alarme, portes, énergie,
  poubelles), raccourcis scènes, coût énergie lié au budget.
- **IA** : chat (« je peux me permettre un resto ? »), voix, suggestions.
- **Transversal** : ★ notifications PC + téléphone ; ★ synchro multi-appareils
  via HA (gestion des conflits) ; verrouillage biométrique + chiffrement
  local ; widgets.

## 4. Plateformes et choix techniques

- **Flutter** (un seul code Windows + Android ; plus tard écran des yeux du
  robot). Animations : dessin en code pour l'instant, **Rive** envisagé.
- **Windows** : compagnon de bureau façon « screenmate » (petit personnage qui
  vit sur le bureau et interagit avec les fenêtres).
- **Android** : bulle flottante au-dessus des apps, widgets, notification
  permanente, synchro en arrière-plan ; distribution par **APK direct** (pas
  de Play Store). Penser à exclure Noxo de l'optimisation batterie.
- Données : stockage local d'abord (hors ligne), synchro avec HA quand
  joignable (API HA + jeton longue durée). Accès extérieur à HA : Nabu Casa
  ou VPN (Tailscale) — non encore précisé.
- **Mode sage / espiègle** : simple réglage pour l'instant.

## 5. État actuel du code

**Branche de référence : `release`** (et `claude/optimistic-hypatia-8nfz82`,
identique). `main` est en retard : c'est une ancienne version (panneau sans
onglets) ; ne plus partir de `main`. Le dépôt a été renommé
`antoine28boel/noxo` (l'ancienne adresse `nox` redirige). 97 tests
(`flutter test`), `flutter analyze` sans remarque.

| Fichier | Rôle |
|---|---|
| `lib/main.dart` | Fenêtre transparente, icône de notification, réglages (shared_preferences), démarrage auto, panneau, chat (HA puis IA du PC), reprise des réglages de « Nox » |
| `lib/noxo/brain.dart` | Comportement pur Dart : perchage, vol, chute, lancer, sommeil, plein écran, modes, bêtises, île (`docked`) |
| `lib/noxo/noxo_view.dart` | Ticker à cadence adaptative, déplacement de la fenêtre, clic-traversant ; clic sur l'île → `onCall` (chat) |
| `lib/noxo/owl_painter.dart`, `pose.dart`, `feather.dart`, `desktop.dart` | Dessin (style A), pose, plume, interface du bureau |
| `lib/win/win_desktop.dart`, `native.dart` | Win32 (FFI) : fenêtres, icônes du bureau, plume, registre (`hasStartupEntry`) |
| `lib/update/updater.dart` | Mises à jour : release `build-N`, archive `noxo-windows.zip`, installation par la nouvelle version elle-même |
| `lib/assistant/today_panel.dart` | Panneau à 7 onglets + Réglages (HA, agent, IA hors ligne, Vikunja, Spotify, Actual) |
| `lib/assistant/panel_tabs.dart` | Onglets Suivi, Musique, Maison, Agenda, Tâches, Budget |
| `lib/assistant/chat.dart`, `chat_view.dart` | Onglet Discuter : messages, réponses de HA (`/api/conversation/process`), choix de l'agent, réglages IA hors ligne |
| `lib/assistant/ollama.dart` | Client Ollama (réponse en flux, outils, chargement/déchargement) et installation automatique d'Ollama + modèle |
| `lib/assistant/home_tools.dart` | Outils maison donnés à Ollama : chercher, état, commander (serrures/alarmes refusées) |
| `lib/assistant/ha_client.dart` | API REST + WebSocket de HA (états, services, agenda, tâches, tableaux de bord, conversation, pipeline vocal préféré) |
| `lib/assistant/actual_client.dart`, `budget.dart` | Actual Budget via actual-http-api |
| `lib/assistant/vikunja*.dart`, `spotify*.dart` | Suivi de projets (Vikunja), musique (API Spotify, PKCE) |
| `lib/assistant/brief.dart`, `today.dart` | Brief du matin (IA de HA ou texte hors ligne), données du jour, cache |

### Ce que Noxo fait aujourd'hui

- **Hibou de bureau** : perché sur la fenêtre active, vole, tombe, se laisse
  lancer, suit la souris des yeux, caresse, s'endort, se cache en plein
  écran ; modes sage / espiègle ; bêtises désactivables (chasser le curseur,
  plume, picorer une icône, pousser une fenêtre) ; cadence adaptative pour
  la batterie.
- **Île (mode travail)** : clic droit sur Noxo ; île noire en haut ou en bas,
  déplaçable, rétractable ; **un clic ouvre le chat**.
- **Panneau** (double-clic sur Noxo, clic sur l'île ou menu) : Discuter,
  Suivi (Vikunja), Musique (Spotify / lecteurs HA), Maison (tableau de bord
  HA en tuiles), Agenda (+ brief), Tâches (listes HA), Budget (Actual :
  soldes, enveloppes, opérations, saisie de dépense).
- **Chat** :
  - par défaut, l'agent de l'**assistant vocal préféré de HA** (Paramètres →
    Assistants vocaux), ou un agent choisi dans Réglages → Discussion ;
  - si HA est injoignable, ou si « Toujours utiliser l'IA du PC » est
    coché : **Ollama sur le PC**, qui commande la maison via HA (outils
    `home_tools.dart`) quand HA est joignable ; HA prend le relais si
    Ollama échoue ;
  - réponses d'Ollama affichées mot à mot ; modèle **chargé au clic sur
    l'île, déchargé à sa fermeture** (`keep_alive` -1 / 0).
- **IA hors ligne** : au premier lancement, Noxo installe Ollama (installateur
  silencieux, sans droits admin) et le modèle (`qwen2.5:7b` par défaut,
  modifiable), réessaie toutes les heures si interrompu.
- **Brief du matin**, **mises à jour** proposées par Noxo (accepter /
  refuser), **lancement au démarrage**.
- **Renommage Nox → Noxo** : au premier lancement, Noxo copie les réglages
  de `%APPDATA%\fr.nox\nox` et remplace l'entrée de démarrage « Nox ». Une
  Nox installée ne voit pas les mises à jour Noxo (nom d'archive différent) :
  installation manuelle une fois.

### Non vérifié sur un vrai Windows

Installation silencieuse d'Ollama (paramètres Inno Setup), chargement /
déchargement du modèle, outils maison avec le vrai HA, reprise des
réglages et du démarrage depuis « Nox ».

## 6. Prochaines étapes

- **Ollama sur le serveur** (192.168.0.222, Docker, modèles sur
  `/mnt/data/ollama`) et intégration Ollama dans HA, pour une même IA
  partout (maison, hibou physique, apps). Faire d'abord memtest86+ (RAM
  suspecte).
- **Orchestrateur** : étendre les outils au-delà de la maison (`pc.*`,
  agenda, tâches, budget, mémoire) ; confirmation dans l'île pour les
  actions sensibles.
- Notifications apportées dans le bec, rappels, réaction météo/budget.
- App Android (bulle), synchro via HA, Tailscale pour l'accès extérieur.

### Infrastructure (d'après les notes de l'utilisateur)

- Serveur `DomotX-ToinouToya` (192.168.0.222) : Debian 11, 8 cœurs, GPU
  Intel intégré, 15 Gio de RAM, SSD 500 Go + 1 To (`/mnt/data`, Jellyfin),
  Docker. RAM soupçonnée défaillante (corruptions les 04, 09 et 14/11).
- VM Home Assistant OS (VirtualBox) : 192.168.0.10, 4 vCPU, 4 Gio, HA
  2026.11.1. IA actuelle dans HA : Google Generative AI.

## 7. Démarrer en local (Windows)

Prérequis : Flutter stable (le CI utilise 3.47.9) et Visual Studio 2022 avec
la charge « Développement Desktop en C++ ».

```bash
git clone -b release https://github.com/antoine28boel/noxo.git
cd noxo
flutter pub get
flutter test
flutter run -d windows
```

Commits : terminer les messages par les lignes d'attribution habituelles de
Claude Code.

## 8. Compilation : uniquement sur demande

Le workflow ne se lance que sur un push de la branche `release` ou via
« Run workflow » (Actions). Quand l'utilisateur demande une compilation :
pousser le travail sur `release` (avance rapide). Chaque build publie une
release `build-N` que Noxo propose. Dernier build : n° 22.

## 9. Architecture visée

```
Téléphones (HA Compagnon) ─ position, capteurs, notifications ─┐
Noxo PC / Noxo Android ── API + WebSocket (Tailscale dehors) ──┤
Hibou physique (voix « Hey Noxo », yeux) ─ Wyoming/ESPHome ────┤
                                                               ▼
           Home Assistant (VM) ── agent de conversation ── Ollama (serveur)
           états, agenda, tâches, notify, pipeline vocal      même modèle
           Actual, Vikunja à côté                              partout
```

- En ligne : Noxo utilise l'agent de HA ou son orchestrateur (LLM + outils
  exécutés via l'API de HA).
- Hors ligne : Ollama du PC + cache local ; pas d'action sur la maison.
- Synchro : données locales envoyées à HA / Actual / Vikunja dès que
  joignables. La perche héberge le serveur et recharge le hibou physique.
