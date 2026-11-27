# Projects Hub

Utilitaire console pour piloter les applications du workspace depuis un seul
endroit : état git de chaque appli, ouverture de la version web locale, commit et push.

## Lancer

Depuis la racine du workspace, double-cliquer sur
`.\Applications-legal\tools\projects-hub\projects-hub.cmd` (ou sur l'ancien
`.\projects-hub.cmd` s'il est present), ou :

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Applications-legal\tools\projects-hub\projects-hub.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\Applications-legal\tools\projects-hub\projects-hub.ps1 -NoFetch   # hors-ligne
```

Au premier démarrage, le hub analyse les projets et effectue un `git fetch` sur
chaque dépôt ayant un remote. Les démarrages suivants affichent immédiatement
la dernière analyse enregistrée. `R` permet de rafraîchir tous les projets
(`*`) ou une sélection de numéros (par exemple `1,3`). Un rafraîchissement
complet détecte aussi les projets ajoutés ou supprimés. `-NoFetch` évite tout
fetch pendant ces analyses.
Par defaut, le workspace est le dossier parent du depot Applications-legal.
Utiliser `-Root <chemin>` pour choisir une autre racine.

Le cache est enregistré par workspace dans `%LOCALAPPDATA%\ProjectsHub` : il
contient les chemins, les états Git et les derniers messages de commit, et n'est
pas versionné. La date de chaque ligne indique la dernière analyse locale ;
après ouverture d'un projet, cette analyse locale est mise à jour sans fetch.
Les données distantes peuvent donc être plus anciennes. L'état local est relu
avant les actions du menu, mais les changements externes ne sont visibles dans
le tableau qu'après actualisation. Un cache illisible est signalé, puis remplacé
par une nouvelle analyse. Une erreur d'enregistrement est également signalée.

## Écran principal

```
 #   Projet               Web    Android         iOS             Analyse locale      Git
 1   Applications-legal   -      -               -               2026-11-26 09:00:00 [MOD] 1 modif(s) (main)
 2   echo                 non    oui (1.0.0+1)   non             2026-11-26 09:00:01 [OK] à jour (main)
 3   jurney               oui    oui (1.10.1+16) oui (1.10.1+16) 2026-11-26 09:00:02 [OK] à jour (main)
```

| Libellé | Sens |
|---|---|
| `[OK] à jour` | rien à commiter, rien à pousser, rien à récupérer |
| `[MOD] n modif(s)` | fichiers modifiés / non suivis à commiter |
| `[UP] n à pousser` | commits locaux absents du remote |
| `[DOWN] n à récupérer` | commits distants absents en local |
| `[--] pas de remote` | dépôt git sans `origin` : impossible de pousser |
| `[--] pas d'upstream` | branche locale jamais poussée (le push créera l'upstream) |
| `[?] fetch échoué` | remote injoignable (hors-ligne, clé SSH non chargée) |
| `[XX] pas de git` | dossier sans dépôt git |
| `[!!] erreur git` | `git status` a échoué, le message est affiché |

Colonne **Web** : `oui` = projet Flutter avec dossier `web/`, `non` = projet Flutter sans
plateforme web (activable depuis le menu), `-` = pas un projet Flutter.
Les colonnes **Android** et **iOS** indiquent `non` si le dossier de plateforme
est absent, `-` pour un projet non Flutter, ou `oui (version+build)` lorsqu'il
est present. La version est lue dans `pubspec.yaml`, commune aux plateformes ;
`oui (?)` indique une version absente ou non reconnue. Elle ne confirme ni la
version publiee ni une eventuelle surcharge lors d'une compilation.

Touches : numéro du projet, `R` rafraîchir tout ou une sélection, `Q` quitter
(propose d'arrêter les serveurs web lancés).

## Menu d'un projet

| Option | Action |
|---|---|
| 1 | **Lancer / relancer avec compilation** : `flutter build web`, puis serveur Python sur un port libre (≥ 8080), puis ouverture du navigateur avec un paramètre anti-cache. Si `web/` manque, propose `flutter create --platforms web .` (ajoute des fichiers à commiter). Un serveur déjà actif pour ce projet est réutilisé. |
| 2 | Détail git : branche, remote, dernier commit, `git status --short`, `git diff HEAD --stat` |
| 3 | Commiter : affiche les modifs, propose `chore: sync yyyy-MM-dd` (modifiable), `git add -A` + `git commit` |
| 4 | Pousser : `git push` (ou `git push -u origin <branche>` si pas d'upstream). Jamais `--force`. |
| 5 | Commiter puis pousser |
| 6 | Récupérer : `git pull --rebase` (affiché seulement si des commits distants manquent) |
| 7 | **Rouvrir sans compilation** : sert le dernier `build\web` existant, sans invoquer Flutter. Ne prend pas en compte de nouvelles modifications Dart ; utiliser 1 pour cela. Fonctionne aussi après l'arrêt du serveur. |
| 8 | **Arrêter l'aperçu** : arrête uniquement le serveur de l'application sélectionnée, sans fermer son onglet navigateur ni toucher aux autres applications. Visible si ce serveur est actif. |
| 9 | **Verifier et tester** : lance `scripts\check.ps1` lorsqu'il existe (formatage, analyse, tests selon le projet), sinon `flutter analyze` puis `flutter test`. Un echec est signale et interrompt la suite. |
| 10 | **Construire un Android App Bundle (AAB)** : apres confirmation, lance `flutter build appbundle --release` et affiche `build\app\outputs\bundle\release\app-release.aab`. Necessite la plateforme Android. |

Un projet peut fournir `project-hub.json` avec `webBuildArguments` (uniquement
`--dart-define=...` et `--dart-define-from-file=...`) et `webPort`. Sans ce fichier,
le comportement existant est conserve. N'y mettre aucune cle secrete : les Dart
defines sont inclus dans le build navigateur. Un port fixe occupe provoque une
erreur explicite, sans choisir silencieusement une autre adresse OAuth.

PollUp utilise son fichier public `config\connected-preview.json` et le port
**8787** : option **1** compile le vrai mode connecte, **7** le rouvre, **9** lance
ses verifications completes. Autoriser `http://127.0.0.1:8787/` dans Supabase
Authentication / URL Configuration avant la connexion Google. Aucun build Android
ou partage natif ne peut etre certifie par cette previsualisation navigateur.
Si un apercu a deja ete lance hors de ce hub (par exemple par Copilot), arreter
ce serveur depuis son outil d'origine avant de lancer l'option 1 ou 7. Le hub
ne tue pas un processus externe occupant le port OAuth. Les serveurs lances
dans la meme session du hub sont reutilises.

Chaque action qui modifie quelque chose demande une confirmation `o/N`.

Pour Google Play, configurer au prealable la signature release de chaque application
et verifier le certificat du bundle : le hub ne verifie pas la signature. Certains
projets peuvent utiliser une cle debug par defaut, inutilisable pour publier. Le hub
ne publie pas l'application et ne transmet pas les `webBuildArguments` au build Android ;
les eventuels parametres propres a Android restent a configurer dans le projet.

Pendant la compilation : étapes numérotées, sortie Flutter en direct et temps écoulé
actualisé toutes les cinq secondes. Aucun pourcentage artificiel : Flutter n'en fournit pas.
En cas d'échec, le hub n'ouvre pas un ancien build à la place du nouveau.

L'option dépréciée `--pwa-strategy` n'est plus utilisée. Le hub désactive les réglages
`serviceWorkerSettings` dans le bootstrap généré et supprime le service worker du build,
sans modifier les sources de l'application. Un bootstrap personnalisé avec une
configuration imbriquée non prise en charge provoque une erreur explicite.

## Prérequis

- `git` dans le PATH
- `flutter` : PATH, sinon `flutterRoot` de `.github\foundation\config\toolchain.json`,
  sinon `<parent de Projects>\Flutter\flutter\bin\flutter.bat`
- `python` (ou `py`) pour le serveur local ; sinon `<parent de Projects>\Python\python.exe`.
  Le raccourci WindowsApps sans interpreteur n'est pas considere comme Python.
- Windows PowerShell 5.1 ou PowerShell 7

## Fichiers

```
workspace root\
  projects-hub.cmd                 ancien lanceur local facultatif
  Applications-legal\tools\projects-hub\
    projects-hub.cmd               lanceur versionne
    projects-hub.ps1               menu interactif
    ProjectsHub.psm1               logique (découverte, git, web) — testable sans menu
    test-projects-hub.ps1          tests
    README.md
```

Les dossiers `.github` et `projects-hub` ne sont jamais listés comme applications.

## Tests

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Applications-legal\tools\projects-hub\test-projects-hub.ps1
# Inclure la verification de la correction du SDK local :
powershell -NoProfile -ExecutionPolicy Bypass -File .\Applications-legal\tools\projects-hub\test-projects-hub.ps1 -FlutterSdkRoot ..\Flutter\flutter
```

Les tests créent des dépôts git jetables dans `%TEMP%` (non-git, sans remote, sans commit,
synchronisé, modifié, en avance, en retard), un faux projet Flutter et un stub `flutter.cmd`.
Aucun projet réel n'est touché. `-KeepArtifacts` conserve les fixtures pour inspection.

## Limites connues

- Les appels git du hub passent `-c safe.directory=*` : nécessaire sur les volumes exFAT, qui ne stockent pas
  le propriétaire des fichiers. The foundation installer configures the Git include path
  for the current development root.
- Le fetch SSH utilise `BatchMode=yes` : sans clé chargée dans l'agent, il échoue vite et
  affiche `[?]` au lieu de bloquer sur une passphrase.
- Le premier `flutter build web` d'un projet prend de 30 s à 2 min.
- Les fichiers Flutter générés doivent référencer `le chemin du SDK Flutter`. Après un déplacement
  du SDK, lancer `flutter pub get` dans les applications concernées.
- `volume exFAT` utilise exFAT : aucune junction n'est nécessaire sur ce disque. Les scripts
  utilisent directement `.github\foundation\scripts`, `config` et `templates`.
- Le SDK local a une correction ciblée dans `bin\internal\shared.bat` : ses deux appels
  `Unblock-File` sont ignorés sur exFAT, qui ne supporte pas le flux `Zone.Identifier`.
  Le déblocage reste actif sur les autres systèmes de fichiers. Une mise à jour du SDK
  peut écraser cette modification ; le test avec `-FlutterSdkRoot` le détecte.
- Le serveur Python tourne dans une fenêtre séparée ; il est arrêté à la sortie si on le demande.