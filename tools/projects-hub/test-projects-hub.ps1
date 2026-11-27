<#
.SYNOPSIS
Tests de ProjectsHub.psm1 sur des dépôts git temporaires (aucun projet réel touché).

.EXAMPLE
powershell -NoProfile -ExecutionPolicy Bypass -File .\Applications-legal\tools\projects-hub\test-projects-hub.ps1
#>
[CmdletBinding()]
param(
    [switch]$KeepArtifacts,
    [string]$FlutterSdkRoot
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ProjectsHub.psm1') -Force

$script:Passed = 0
$script:Failed = 0

function Assert-True([bool]$Condition, [string]$Message) {
    if ($Condition) { $script:Passed++; Write-Host "  PASS  $Message" -ForegroundColor Green }
    else { $script:Failed++; Write-Host "  FAIL  $Message" -ForegroundColor Red }
}

function Assert-Equal($Expected, $Actual, [string]$Message) {
    Assert-True ($Expected -eq $Actual) "$Message (attendu: '$Expected', obtenu: '$Actual')"
}

function Invoke-Git([string]$Path, [string[]]$Arguments) {
    $result = Invoke-HubGit -Path $Path -Arguments $Arguments
    if ($result.ExitCode -ne 0) { throw "git $($Arguments -join ' ') a échoué dans $Path : $($result.Errors -join ' ')" }
    return $result.Output
}

function New-Repo([string]$Path) {
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
    Invoke-Git $Path @('init', '-q', '-b', 'main') | Out-Null
    Invoke-Git $Path @('config', 'user.email', 'hub-tests@example.invalid') | Out-Null
    Invoke-Git $Path @('config', 'user.name', 'Hub Tests') | Out-Null
}

function Add-Commit([string]$Path, [string]$FileName, [string]$Message) {
    Set-Content -LiteralPath (Join-Path $Path $FileName) -Value (Get-Date).Ticks
    Invoke-Git $Path @('add', '-A') | Out-Null
    Invoke-Git $Path @('commit', '-q', '-m', $Message) | Out-Null
}

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("projects-hub-tests-" + [guid]::NewGuid().ToString('N'))
$projectsRoot = Join-Path $tempRoot 'projects'
$bareRoot = Join-Path $tempRoot 'bare'
New-Item -ItemType Directory -Force -Path $projectsRoot, $bareRoot | Out-Null

try {
    Write-Host "Fixtures dans $tempRoot" -ForegroundColor Cyan

    # Dossiers à exclure de la liste des projets.
    New-Item -ItemType Directory -Force -Path (Join-Path $projectsRoot '.github'), (Join-Path $projectsRoot 'projects-hub') | Out-Null

    # not_git : simple dossier.
    $notGit = Join-Path $projectsRoot 'not_git'
    New-Item -ItemType Directory -Force -Path $notGit | Out-Null

    # no_remote : repo propre sans remote.
    $noRemote = Join-Path $projectsRoot 'no_remote'
    New-Repo $noRemote
    Add-Commit $noRemote 'a.txt' 'init'

    # empty_branch : repo sans aucun commit (cas "echo").
    $emptyBranch = Join-Path $projectsRoot 'empty_branch'
    New-Repo $emptyBranch
    Set-Content -LiteralPath (Join-Path $emptyBranch 'draft.txt') -Value 'x'

    # synced / dirty / ahead / behind : repos reliés à un remote bare.
    foreach ($name in @('synced', 'dirty', 'ahead', 'behind')) {
        $bare = Join-Path $bareRoot "$name.git"
        Invoke-Git $bareRoot @('init', '-q', '--bare', '-b', 'main', $bare) | Out-Null
        $repo = Join-Path $projectsRoot $name
        New-Repo $repo
        Add-Commit $repo 'a.txt' 'init'
        Invoke-Git $repo @('remote', 'add', 'origin', $bare) | Out-Null
        Invoke-Git $repo @('push', '-q', '-u', 'origin', 'main') | Out-Null
    }
    Set-Content -LiteralPath (Join-Path $projectsRoot 'dirty\b.txt') -Value 'new'
    Add-Commit (Join-Path $projectsRoot 'ahead') 'b.txt' 'local only'

    # behind : un second clone pousse un commit que "behind" n'a pas encore.
    $otherClone = Join-Path $tempRoot 'other_clone'
    Invoke-Git $tempRoot @('clone', '-q', (Join-Path $bareRoot 'behind.git'), $otherClone) | Out-Null
    Invoke-Git $otherClone @('config', 'user.email', 'hub-tests@example.invalid') | Out-Null
    Invoke-Git $otherClone @('config', 'user.name', 'Hub Tests') | Out-Null
    Add-Commit $otherClone 'remote.txt' 'remote only'
    Invoke-Git $otherClone @('push', '-q') | Out-Null

    # flutter_app : faux projet Flutter avec plateforme web.
    $flutterApp = Join-Path $projectsRoot 'flutter_app'
    New-Item -ItemType Directory -Force -Path (Join-Path $flutterApp 'web') | Out-Null
    Set-Content -LiteralPath (Join-Path $flutterApp 'pubspec.yaml') -Value @('name: flutter_app', 'version: 1.10.1+16 # application')
    Set-Content -LiteralPath (Join-Path $flutterApp 'web\index.html') -Value '<html></html>'
    New-Item -ItemType Directory -Force -Path (Join-Path $flutterApp 'android'), (Join-Path $flutterApp 'ios') | Out-Null

    # flutter_noweb : projet Flutter sans dossier web.
    $flutterNoWeb = Join-Path $projectsRoot 'flutter_noweb'
    New-Item -ItemType Directory -Force -Path $flutterNoWeb | Out-Null
    Set-Content -LiteralPath (Join-Path $flutterNoWeb 'pubspec.yaml') -Value 'name: flutter_noweb'

    # Stub flutter : "build web" crée build\web\index.html dans le dossier courant.
    $stubFlutter = Join-Path $tempRoot 'flutter.cmd'
    $stubLines = @(
        '@echo off',
        'echo %* >> hub-flutter-arguments.txt',
        'echo %* | findstr /c:"--pwa-strategy" >nul && exit /b 9',
        'if "%1"=="analyze" exit /b 0',
        'if "%1"=="test" exit /b 0',
        'if "%1"=="build" if "%2"=="appbundle" (',
        '  if not "%3"=="--release" exit /b 8',
        '  mkdir build\app\outputs\bundle\release 2>nul',
        '  echo bundle > build\app\outputs\bundle\release\app-release.aab',
        '  exit /b 0',
        ')',
        'if "%1"=="build" if "%2"=="web" (',
        '  mkdir build\web 2>nul',
        '  echo built > build\web\index.html',
        '  if exist source-preview.txt type source-preview.txt > build\web\index.html',
        '  echo _flutter.loader.load({serviceWorkerSettings: {serviceWorkerVersion: "123"}}^); > build\web\flutter_bootstrap.js',
        '  echo obsolete > build\web\flutter_service_worker.js',
        '  exit /b 0',
        ')',
        'if "%1"=="create" (',
        '  mkdir web 2>nul',
        '  echo created > web\index.html',
        '  exit /b 0',
        ')',
        'exit /b 1'
    )
    [System.IO.File]::WriteAllLines($stubFlutter, $stubLines, [System.Text.ASCIIEncoding]::new())

    # -----------------------------------------------------------------------
    # 1. Découverte des projets
    # -----------------------------------------------------------------------
    Write-Host '1. Get-HubProjects' -ForegroundColor Cyan
    Assert-Equal (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) (Resolve-HubWorkspaceRoot) 'racine par defaut : parent de Applications-legal'
    $fixtureHub = Join-Path $projectsRoot 'Applications-legal\tools\projects-hub'
    Assert-Equal $projectsRoot (Resolve-HubWorkspaceRoot -HubDirectory $fixtureHub) 'racine calculee depuis le nouvel emplacement'
    $originalPath = $env:PATH
    try {
        $env:PATH = ''
        Assert-True (-not (Resolve-HubPythonCommand -Root $projectsRoot)) 'Python portable absent : aucun interpreteur'
        $portablePython = Join-Path $tempRoot 'Python\python.exe'
        New-Item -ItemType Directory -Path (Split-Path -Parent $portablePython) | Out-Null
        New-Item -ItemType File -Path $portablePython | Out-Null
        Assert-Equal $portablePython (Resolve-HubPythonCommand -Root $projectsRoot) 'Python portable : chemin relatif a la racine fournie'
    }
    finally {
        $env:PATH = $originalPath
    }
    $emptyRoot = Join-Path $tempRoot 'empty_projects'
    New-Item -ItemType Directory -Path $emptyRoot | Out-Null
    Assert-Equal 0 @(Get-HubProjects -Root $emptyRoot).Count 'racine vide : liste vide'
    $projects = @(Get-HubProjects -Root $projectsRoot)
    $names = @($projects | ForEach-Object { $_.Name })
    Assert-True ($names -notcontains '.github') 'exclut .github'
    Assert-True ($names -notcontains 'projects-hub') 'exclut projects-hub'
    Assert-Equal 9 $projects.Count 'compte les 9 projets'
    Assert-Equal (($names | Sort-Object) -join ',') ($names -join ',') 'tri alphabétique'
    $flutterRow = $projects | Where-Object { $_.Name -eq 'flutter_app' }
    Assert-True ($flutterRow.IsFlutter -and $flutterRow.HasWeb) 'flutter_app : IsFlutter + HasWeb'
    Assert-True ($flutterRow.HasAndroid -and $flutterRow.HasIos) 'plateformes Android et iOS presentes'
    Assert-Equal '1.10.1+16' $flutterRow.Version 'version et build lus depuis pubspec'
    Assert-Equal 'oui (1.10.1+16)' (Format-HubPlatform $flutterRow.IsFlutter $flutterRow.HasAndroid $flutterRow.Version) 'affichage Android avec version'
    Assert-Equal 'oui (1.10.1+16)' (Format-HubPlatform $flutterRow.IsFlutter $flutterRow.HasIos $flutterRow.Version) 'affichage iOS avec version'
    $noWebRow = $projects | Where-Object { $_.Name -eq 'flutter_noweb' }
    Assert-True ($noWebRow.IsFlutter -and -not $noWebRow.HasWeb) 'flutter_noweb : IsFlutter sans web'
    Assert-True (-not $noWebRow.HasAndroid -and -not $noWebRow.HasIos) 'plateformes absentes'
    Assert-Equal 'non' (Format-HubPlatform $noWebRow.IsFlutter $noWebRow.HasIos $noWebRow.Version) 'plateforme Flutter absente'
    Assert-Equal 'oui (?)' (Format-HubPlatform $true $true $noWebRow.Version) 'version manquante signalee'
    $notGitRow = $projects | Where-Object { $_.Name -eq 'not_git' }
    Assert-True (-not $notGitRow.IsFlutter -and -not $notGitRow.HasWeb) 'not_git : ni Flutter ni web'
    Assert-Equal '-' (Format-HubPlatform $notGitRow.IsFlutter $notGitRow.HasAndroid $notGitRow.Version) 'projet non Flutter'
    Set-Content -LiteralPath (Join-Path $flutterApp 'pubspec.yaml') -Value @('name: flutter_app', 'version: "2.0.0-beta.1+7"')
    $quotedRow = @(Get-HubProjects -Root $projectsRoot | Where-Object { $_.Name -eq 'flutter_app' })[0]
    Assert-Equal '2.0.0-beta.1+7' $quotedRow.Version 'version prerelease entre guillemets'
    Set-Content -LiteralPath (Join-Path $flutterApp 'pubspec.yaml') -Value @('name: flutter_app', 'version: invalid')
    $invalidRow = @(Get-HubProjects -Root $projectsRoot | Where-Object { $_.Name -eq 'flutter_app' })[0]
    Assert-Equal 'oui (?)' (Format-HubPlatform $invalidRow.IsFlutter $invalidRow.HasAndroid $invalidRow.Version) 'version invalide signalee'
    Set-Content -LiteralPath (Join-Path $flutterApp 'pubspec.yaml') -Value @('name: flutter_app', 'version: 1.0.0', 'version: 2.0.0')
    $duplicateRow = @(Get-HubProjects -Root $projectsRoot | Where-Object { $_.Name -eq 'flutter_app' })[0]
    Assert-Equal 'oui (?)' (Format-HubPlatform $duplicateRow.IsFlutter $duplicateRow.HasIos $duplicateRow.Version) 'version ambigue signalee'
    Set-Content -LiteralPath (Join-Path $flutterApp 'pubspec.yaml') -Value @('name: flutter_app', 'version: 1.10.1+16')

    # -----------------------------------------------------------------------
    # Cache et rafraichissement selectif
    # -----------------------------------------------------------------------
    Write-Host '1b. Cache et rafraichissement' -ForegroundColor Cyan
    $cacheDirectory = Join-Path $tempRoot 'cache'
    $cachePath = Get-HubCachePath -Root $projectsRoot -CacheDirectory $cacheDirectory
    Assert-Equal $cachePath (Get-HubCachePath -Root $projectsRoot.ToUpperInvariant() -CacheDirectory $cacheDirectory) 'cache partage pour les variantes de casse Windows'
    Assert-True ($cachePath -ne (Get-HubCachePath -Root $emptyRoot -CacheDirectory $cacheDirectory)) 'cache distinct par workspace'
    Save-HubCache -Path $cachePath -Root $projectsRoot -Rows @()
    Assert-Equal 0 @(Read-HubCache -Path $cachePath -Root $projectsRoot).Count 'cache vide : aller-retour'
    Assert-Equal '1,3' (@(ConvertFrom-HubSelection -Text '1, 3 1' -Count 3) -join ',') 'selection multiple dedupliquee'
    $invalidSelection = $false
    try { ConvertFrom-HubSelection -Text '1,4' -Count 3 | Out-Null } catch { $invalidSelection = $true }
    Assert-True $invalidSelection 'selection hors limites refusee'
    $invalidSelection = $false
    try { ConvertFrom-HubSelection -Text '1,x' -Count 3 | Out-Null } catch { $invalidSelection = $true }
    Assert-True $invalidSelection 'selection non numerique refusee'
    Set-Content -LiteralPath $cachePath -Value '{invalid json'
    $invalidCache = $false
    try { Read-HubCache -Path $cachePath -Root $projectsRoot | Out-Null } catch { $invalidCache = $true }
    Assert-True $invalidCache 'cache corrompu signale'

    $originalLocalAppData = $env:LOCALAPPDATA
    try {
        $env:LOCALAPPDATA = Join-Path $tempRoot 'localappdata'
        $hubScript = Join-Path $PSScriptRoot 'projects-hub.ps1'
        $firstOutput = @('q' | & powershell -NoProfile -ExecutionPolicy Bypass -File $hubScript -Root $projectsRoot -NoFetch 6>&1) -join "`n"
        Assert-Equal 0 $LASTEXITCODE 'premier lancement reussi'
        Assert-True ($firstOutput -match 'Analyse 1/') 'premier lancement analyse les projets'
        $sessionCache = Get-HubCachePath -Root $projectsRoot
        $cachedRows = @(Read-HubCache -Path $sessionCache -Root $projectsRoot)
        Assert-Equal $projects.Count $cachedRows.Count 'premier lancement enregistre les projets'
        $dirtyIndex = (@($cachedRows | Where-Object { $_.Project.Name -eq 'dirty' }))[0].Index
        $noRemoteIndex = (@($cachedRows | Where-Object { $_.Project.Name -eq 'no_remote' }))[0].Index
        $syncedBefore = (@($cachedRows | Where-Object { $_.Project.Name -eq 'synced' }))[0].RefreshedAt
        Set-Content -LiteralPath (Join-Path $projectsRoot 'dirty\extra.txt') -Value 'x'
        Set-Content -LiteralPath (Join-Path $projectsRoot 'no_remote\extra.txt') -Value 'x'
        $cachedOutput = @('q' | & powershell -NoProfile -ExecutionPolicy Bypass -File $hubScript -Root $projectsRoot -NoFetch 6>&1) -join "`n"
        Assert-Equal 0 $LASTEXITCODE 'lancement depuis cache reussi'
        Assert-True ($cachedOutput -notmatch 'Analyse 1/') 'lancement depuis cache sans analyse'
        $selectionOutput = @(@('r', "$dirtyIndex,$noRemoteIndex", 'q') | & powershell -NoProfile -ExecutionPolicy Bypass -File $hubScript -Root $projectsRoot -NoFetch 6>&1) -join "`n"
        Assert-Equal 0 $LASTEXITCODE 'rafraichissement selectif reussi'
        Assert-True ($selectionOutput -match 'Analyse : dirty' -and $selectionOutput -match 'Analyse : no_remote') 'seuls les projets choisis sont analyses'
        $afterRows = @(Read-HubCache -Path $sessionCache -Root $projectsRoot)
        Assert-Equal 2 (@($afterRows | Where-Object { $_.Project.Name -eq 'dirty' }))[0].State.Dirty 'cache du premier projet actualise'
        Assert-Equal 1 (@($afterRows | Where-Object { $_.Project.Name -eq 'no_remote' }))[0].State.Dirty 'cache du second projet actualise'
        Assert-Equal $syncedBefore (@($afterRows | Where-Object { $_.Project.Name -eq 'synced' }))[0].RefreshedAt 'autre projet non actualise'
        $newProject = Join-Path $projectsRoot 'new_project'
        New-Item -ItemType Directory -Path $newProject | Out-Null
        $fullOutput = @(@('r', '*', 'q') | & powershell -NoProfile -ExecutionPolicy Bypass -File $hubScript -Root $projectsRoot -NoFetch 6>&1) -join "`n"
        Assert-Equal 0 $LASTEXITCODE 'rafraichissement complet reussi'
        Assert-True ($fullOutput -match 'new_project') 'rafraichissement complet detecte un nouveau projet'
        Remove-Item -LiteralPath $newProject
        Set-Content -LiteralPath $sessionCache -Value '{invalid json'
        $recoveryOutput = @(@('', 'q') | & powershell -NoProfile -ExecutionPolicy Bypass -File $hubScript -Root $projectsRoot -NoFetch 6>&1) -join "`n"
        Assert-Equal 0 $LASTEXITCODE 'recuperation apres cache corrompu'
        Assert-True ($recoveryOutput -match 'Cache illisible' -and $recoveryOutput -match 'Analyse 1/') 'cache corrompu signale et analyse refaite'
        Remove-Item -LiteralPath (Join-Path $projectsRoot 'dirty\extra.txt'), (Join-Path $projectsRoot 'no_remote\extra.txt')

        $fetchRoot = Join-Path $tempRoot 'fetch_projects'
        $fetchBare = Join-Path $tempRoot 'fetch_remote.git'
        New-Item -ItemType Directory -Path $fetchRoot | Out-Null
        Invoke-Git $tempRoot @('init', '-q', '--bare', '-b', 'main', $fetchBare) | Out-Null
        $fetchRepo = Join-Path $fetchRoot 'app'
        New-Repo $fetchRepo
        Add-Commit $fetchRepo 'first.txt' 'initial'
        Invoke-Git $fetchRepo @('remote', 'add', 'origin', $fetchBare) | Out-Null
        Invoke-Git $fetchRepo @('push', '-q', '-u', 'origin', 'main') | Out-Null
        $fetchOther = Join-Path $tempRoot 'fetch_other'
        Invoke-Git $tempRoot @('clone', '-q', $fetchBare, $fetchOther) | Out-Null
        Invoke-Git $fetchOther @('config', 'user.email', 'hub-tests@example.invalid') | Out-Null
        Invoke-Git $fetchOther @('config', 'user.name', 'Hub Tests') | Out-Null
        Add-Commit $fetchOther 'second.txt' 'remote'
        Invoke-Git $fetchOther @('push', '-q') | Out-Null
        @('q') | & powershell -NoProfile -ExecutionPolicy Bypass -File $hubScript -Root $fetchRoot -NoFetch 6>&1 | Out-Null
        @('r', '1', 'q') | & powershell -NoProfile -ExecutionPolicy Bypass -File $hubScript -Root $fetchRoot -NoFetch 6>&1 | Out-Null
        $fetchCache = Get-HubCachePath -Root $fetchRoot
        Assert-Equal 0 (@(Read-HubCache -Path $fetchCache -Root $fetchRoot))[0].State.Behind 'selection hors ligne ne fait pas de fetch'
        @('r', '1', 'q') | & powershell -NoProfile -ExecutionPolicy Bypass -File $hubScript -Root $fetchRoot 6>&1 | Out-Null
        Assert-Equal 0 $LASTEXITCODE 'rafraichissement avec fetch reussi'
        Assert-Equal 1 (@(Read-HubCache -Path $fetchCache -Root $fetchRoot))[0].State.Behind 'selection avec fetch detecte le commit distant'
    }
    finally { $env:LOCALAPPDATA = $originalLocalAppData }

    # -----------------------------------------------------------------------
    # 2. État git
    # -----------------------------------------------------------------------
    Write-Host '2. Get-HubGitState' -ForegroundColor Cyan
    $s = Get-HubGitState -Path $notGit
    Assert-True (-not $s.IsRepo) 'not_git : IsRepo = false'
    Assert-Equal '[XX] pas de git' (Format-HubGitState $s) 'not_git : libellé'

    $s = Get-HubGitState -Path $noRemote
    Assert-True ($s.IsRepo -and -not $s.HasRemote -and $s.Dirty -eq 0) 'no_remote : repo propre sans remote'
    Assert-Equal 'main' $s.Branch 'no_remote : branche main'
    Assert-Equal '[--] pas de remote (main)' (Format-HubGitState $s) 'no_remote : libellé'
    Assert-True ($s.LastCommit -like '* init') 'no_remote : dernier commit lu'

    $s = Get-HubGitState -Path $emptyBranch
    Assert-Equal 'main' $s.Branch 'empty_branch : branche lue sans commit'
    Assert-Equal 1 $s.Dirty 'empty_branch : 1 fichier non suivi'
    Assert-True ($null -eq $s.LastCommit) 'empty_branch : pas de dernier commit'

    $s = Get-HubGitState -Path (Join-Path $projectsRoot 'synced')
    Assert-True ($s.HasRemote -and $s.HasUpstream) 'synced : remote + upstream'
    Assert-Equal 'origin' $s.RemoteName 'synced : nom du remote'
    Assert-True (Test-HubGitSynced $s) 'synced : Test-HubGitSynced'
    Assert-Equal '[OK] à jour (main)' (Format-HubGitState $s) 'synced : libellé'
    Assert-True (-not $s.FetchFailed) 'synced : fetch réussi'

    $s = Get-HubGitState -Path (Join-Path $projectsRoot 'dirty')
    Assert-Equal 1 $s.Dirty 'dirty : 1 modif'
    Assert-Equal '[MOD] 1 modif(s) (main)' (Format-HubGitState $s) 'dirty : libellé'
    Assert-True (-not (Test-HubGitSynced $s)) 'dirty : pas synchronisé'

    $s = Get-HubGitState -Path (Join-Path $projectsRoot 'ahead')
    Assert-Equal 1 $s.Ahead 'ahead : 1 à pousser'
    Assert-Equal 0 $s.Behind 'ahead : 0 à récupérer'
    Assert-Equal '[UP] 1 à pousser (main)' (Format-HubGitState $s) 'ahead : libellé'

    $behindPath = Join-Path $projectsRoot 'behind'
    $s = Get-HubGitState -Path $behindPath -NoFetch
    Assert-Equal 0 $s.Behind 'behind -NoFetch : ne voit pas encore le commit distant'
    $s = Get-HubGitState -Path $behindPath
    Assert-Equal 1 $s.Behind 'behind avec fetch : 1 à récupérer'
    Assert-Equal '[DOWN] 1 à récupérer (main)' (Format-HubGitState $s) 'behind : libellé'

    # Libellé combiné et cas d'erreur, construits à la main.
    $combined = Get-HubGitState -Path (Join-Path $projectsRoot 'ahead') -NoFetch
    $combined.Dirty = 2; $combined.Behind = 3; $combined.FetchFailed = $true
    Assert-Equal '[MOD] 2 modif(s) · [UP] 1 à pousser · [DOWN] 3 à récupérer · [?] fetch échoué (main)' (Format-HubGitState $combined) 'libellé combiné'
    $combined.Error = 'boom'
    Assert-Equal '[!!] erreur git : boom' (Format-HubGitState $combined) 'libellé erreur'

    # -----------------------------------------------------------------------
    # 3. Actions git
    # -----------------------------------------------------------------------
    Write-Host '3. Commit / push / pull' -ForegroundColor Cyan
    Assert-Equal 'chore: sync 2026-01-02' (Get-HubDefaultCommitMessage -Date ([datetime]'2026-01-02')) 'message par défaut'

    $summary = @(Get-HubGitSummary -Path (Join-Path $projectsRoot 'dirty'))
    Assert-True (($summary -join "`n") -match '\?\? b\.txt') 'résumé : fichier non suivi listé'

    $commit = Invoke-HubCommit -Path (Join-Path $projectsRoot 'dirty') -Message 'test: commit hub'
    Assert-True $commit.Success 'commit : succès'
    $s = Get-HubGitState -Path (Join-Path $projectsRoot 'dirty') -NoFetch
    Assert-True ($s.Dirty -eq 0 -and $s.Ahead -eq 1) 'commit : arbre propre, 1 à pousser'
    $log = @(Invoke-Git (Join-Path $projectsRoot 'dirty') @('log', '-1', '--format=%s'))
    Assert-Equal 'test: commit hub' $log[0] 'commit : message présent dans le log'

    $commitNothing = Invoke-HubCommit -Path (Join-Path $projectsRoot 'synced') -Message 'rien'
    Assert-True (-not $commitNothing.Success) 'commit sans modif : échec propre'

    $push = Invoke-HubPush -Path (Join-Path $projectsRoot 'ahead')
    Assert-True $push.Success 'push : succès'
    $s = Get-HubGitState -Path (Join-Path $projectsRoot 'ahead')
    Assert-Equal 0 $s.Ahead 'push : plus rien à pousser'

    $pushNoRemote = Invoke-HubPush -Path $noRemote
    Assert-True (-not $pushNoRemote.Success -and $pushNoRemote.Message -like '*remote*') 'push sans remote : refus explicite'

    # push -u : branche locale sans upstream.
    $newBranchRepo = Join-Path $projectsRoot 'synced'
    Invoke-Git $newBranchRepo @('checkout', '-q', '-b', 'feature') | Out-Null
    Add-Commit $newBranchRepo 'f.txt' 'feature'
    $pushU = Invoke-HubPush -Path $newBranchRepo
    Assert-True $pushU.Success 'push -u : succès'
    $s = Get-HubGitState -Path $newBranchRepo -NoFetch
    Assert-True $s.HasUpstream 'push -u : upstream créé'

    $pull = Invoke-HubPullRebase -Path $behindPath
    Assert-True $pull.Success 'pull --rebase : succès'
    $s = Get-HubGitState -Path $behindPath
    Assert-Equal 0 $s.Behind 'pull --rebase : plus rien à récupérer'

    # -----------------------------------------------------------------------
    # 4. Web
    # -----------------------------------------------------------------------
    Write-Host '4. Web preview' -ForegroundColor Cyan
    $port = Get-HubFreePort -Start 18080
    Assert-True ($port -ge 18080) 'port libre >= Start'

    $buildNoWeb = Invoke-HubWebBuild -Path $flutterNoWeb -FlutterCommand $stubFlutter
    Assert-True (-not $buildNoWeb.Success -and $buildNoWeb.Message -like '*web/*') 'build sans web/ : refus explicite'

    $enable = Enable-HubWebPlatform -Path $flutterNoWeb -FlutterCommand $stubFlutter
    Assert-True ($enable.Success -and (Test-Path (Join-Path $flutterNoWeb 'web\index.html'))) 'enable web : dossier web créé'

    $build = Invoke-HubWebBuild -Path $flutterApp -FlutterCommand $stubFlutter -InformationVariable buildProgress
    Assert-True $build.Success 'build web : succès'
    Assert-True (Test-Path (Join-Path $flutterApp 'build\web\index.html')) 'build web : index.html produit'
    Assert-True (-not (Test-Path (Join-Path $flutterApp 'build\web\flutter_service_worker.js'))) 'build web : ancien service worker supprimé'
    $bootstrapText = Get-Content (Join-Path $flutterApp 'build\web\flutter_bootstrap.js') -Raw
    Assert-True ($bootstrapText -match 'serviceWorkerSettings: undefined') 'build : enregistrement du service worker desactive sans option PWA'
    Assert-Equal (Join-Path $flutterApp 'build\web') $build.Output[0] 'build web : dossier renvoyé'
    $messages = ($buildProgress | ForEach-Object { "$_" }) -join "`n"
    Assert-True ($messages -match '\[1/3\]' -and $messages -match '\[2/3\]' -and $messages -match '\[3/3\]') 'build : trois etapes affichees'
    Assert-True ($messages -match '\[build\] \d+s') 'build : temps ecoule visible pendant la compilation'
    $flutterArgs = Get-Content (Join-Path $flutterApp 'hub-flutter-arguments.txt') -Raw
    Assert-True ($flutterArgs -notmatch '--pwa-strategy') 'build : option depreciee absente'

    $projectConfig = Join-Path $flutterApp 'project-hub.json'
    Set-Content -LiteralPath $projectConfig -Value '{"webBuildArguments":["--dart-define=POLLUP_CONNECTED=true","--dart-define-from-file=config\\public.json"],"webPort":18187}'
    $configured = Get-HubProjectConfig -Path $flutterApp
    Assert-Equal 18187 $configured.WebPort 'configuration : port fixe'
    Assert-Equal 2 $configured.WebBuildArguments.Count 'configuration : arguments publics'
    $configuredBuild = Invoke-HubWebBuild -Path $flutterApp -FlutterCommand $stubFlutter
    Assert-True $configuredBuild.Success 'build configure : succes'
    $configuredArgs = Get-Content (Join-Path $flutterApp 'hub-flutter-arguments.txt') -Raw
    Assert-True ($configuredArgs -match '--dart-define=POLLUP_CONNECTED=true' -and $configuredArgs -match '--dart-define-from-file=config\\public.json') 'build configure : arguments transmis a Flutter'
    Set-Content -LiteralPath $projectConfig -Value '{"webBuildArguments":["--output=another-project"],"webPort":18187}'
    $invalidConfig = $false
    try { Get-HubProjectConfig -Path $flutterApp | Out-Null } catch { $invalidConfig = $true }
    Assert-True $invalidConfig 'configuration : arguments non autorises refuses'
    Remove-Item -LiteralPath $projectConfig

    $checks = Invoke-HubProjectChecks -Path $flutterApp -FlutterCommand $stubFlutter
    Assert-True $checks.Success 'tests : fallback analyze puis test'
    $checkArgs = Get-Content (Join-Path $flutterApp 'hub-flutter-arguments.txt') -Raw
    Assert-True ($checkArgs -match 'analyze' -and $checkArgs -match 'test') 'tests : commandes Flutter lancees'
    $scripts = Join-Path $flutterApp 'scripts'
    New-Item -ItemType Directory -Path $scripts | Out-Null
    $checkScript = Join-Path $scripts 'check.ps1'
    Set-Content -LiteralPath $checkScript -Value 'Set-Content -LiteralPath "check-ran.txt" -Value "yes"; exit 0'
    $beforeCheck = Get-Content (Join-Path $flutterApp 'hub-flutter-arguments.txt') -Raw
    $checks = Invoke-HubProjectChecks -Path $flutterApp -FlutterCommand $stubFlutter
    Assert-True ($checks.Success -and (Test-Path (Join-Path $flutterApp 'check-ran.txt'))) 'tests : script du projet prioritaire'
    Assert-Equal $beforeCheck (Get-Content (Join-Path $flutterApp 'hub-flutter-arguments.txt') -Raw) 'tests : pas de fallback duplique'
    Set-Content -LiteralPath $checkScript -Value 'exit 7'
    $checks = Invoke-HubProjectChecks -Path $flutterApp -FlutterCommand $stubFlutter
    Assert-True (-not $checks.Success) 'tests : echec du script signale'
    Remove-Item -LiteralPath $checkScript

    $failedFlutter = Join-Path $tempRoot 'flutter-fail.cmd'
    [System.IO.File]::WriteAllText($failedFlutter, "@echo off`r`necho simulated compile failure`r`nexit /b 1`r`n")
    $failedBuild = Invoke-HubWebBuild -Path $flutterApp -FlutterCommand $failedFlutter
    Assert-True (-not $failedBuild.Success) 'build : echec signale meme si un ancien build existe'

    Write-Host '4b. Android App Bundle' -ForegroundColor Cyan
    $androidArgs = Join-Path $flutterNoWeb 'hub-flutter-arguments.txt'
    $beforeAndroid = Get-Content -LiteralPath $androidArgs -Raw
    $missingAndroid = Invoke-HubAndroidAppBundle -Path $flutterNoWeb -FlutterCommand $stubFlutter
    Assert-True (-not $missingAndroid.Success -and $missingAndroid.Message -like '*Android absente*') 'AAB : plateforme absente signalee'
    Assert-Equal $beforeAndroid (Get-Content -LiteralPath $androidArgs -Raw) 'AAB : Flutter non invoque sans plateforme Android'
    New-Item -ItemType Directory -Force -Path (Join-Path $flutterApp 'android') | Out-Null
    $bundle = Invoke-HubAndroidAppBundle -Path $flutterApp -FlutterCommand $stubFlutter
    $bundlePath = Join-Path $flutterApp 'build\app\outputs\bundle\release\app-release.aab'
    Assert-True ($bundle.Success -and (Test-Path -LiteralPath $bundlePath)) 'AAB : build release produit'
    Assert-Equal $bundlePath $bundle.Output[0] 'AAB : chemin du bundle renvoye'
    Assert-True ($bundle.Message -like '*signature*') 'AAB : signature non certifiee'
    $bundleArgs = Get-Content -LiteralPath (Join-Path $flutterApp 'hub-flutter-arguments.txt') -Raw
    Assert-True ($bundleArgs -match 'build appbundle --release') 'AAB : commande release transmise a Flutter'
    $failedBundle = Invoke-HubAndroidAppBundle -Path $flutterApp -FlutterCommand $failedFlutter
    Assert-True (-not $failedBundle.Success -and $failedBundle.Message -like '*ancien AAB*') 'AAB : echec signale malgre ancien bundle'
    $emptyFlutter = Join-Path $tempRoot 'flutter-no-bundle.cmd'
    [System.IO.File]::WriteAllText($emptyFlutter, "@echo off`r`nexit /b 0`r`n")
    $missingBundle = Invoke-HubAndroidAppBundle -Path $flutterNoWeb -FlutterCommand $emptyFlutter
    Assert-True (-not $missingBundle.Success) 'AAB : aucun succes sans plateforme'
    New-Item -ItemType Directory -Path (Join-Path $flutterNoWeb 'android') | Out-Null
    $missingBundle = Invoke-HubAndroidAppBundle -Path $flutterNoWeb -FlutterCommand $emptyFlutter
    Assert-True (-not $missingBundle.Success -and $missingBundle.Message -like '*introuvable*') 'AAB : sortie absente signalee meme si Flutter reussit'

    $python = Resolve-HubPythonCommand
    if ($python) {
        $server = Start-HubWebServer -Path $flutterApp -Directory $build.Output[0] -PythonCommand $python -StartPort 18080
        $readyResponse = Invoke-WebRequest -Uri $server.Url -UseBasicParsing -TimeoutSec 5
        Assert-Equal 200 $readyResponse.StatusCode 'serveur : disponible dès le retour de Start'
        Set-Content -LiteralPath (Join-Path $flutterNoWeb 'project-hub.json') -Value ("{`"webPort`":$($server.Port)}")
        $occupied = $false
        try { Start-HubWebServer -Path $flutterNoWeb -Directory $build.Output[0] -PythonCommand $python | Out-Null }
        catch { $occupied = $_.Exception.Message -like '*Aucun port libre*' }
        Assert-True $occupied 'serveur : port OAuth occupe refuse sans port alternatif'
        Remove-Item -LiteralPath (Join-Path $flutterNoWeb 'project-hub.json')
        $again = Start-HubWebServer -Path $flutterApp -Directory $build.Output[0] -PythonCommand $python -StartPort 18080
        Assert-Equal $server.Port $again.Port 'serveur : réutilisé pour le même projet'
        Assert-Equal 1 @(Get-HubWebServers).Count 'serveur : 1 actif'
        $secondServer = Start-HubWebServer -Path $flutterNoWeb -Directory $build.Output[0] -PythonCommand $python -StartPort 18080
        Stop-HubWebServers -Path $flutterNoWeb
        Assert-True $secondServer.Process.HasExited 'arret cible : processus arrete'
        Assert-Equal 1 @(Get-HubWebServers).Count 'arret cible : autre application preservee'
        $response = $null
        try { $response = Invoke-WebRequest -Uri $server.Url -UseBasicParsing -TimeoutSec 5 } catch { }
        Assert-True ($null -ne $response -and $response.Content -match 'built') 'serveur : répond avec le build'
        Stop-HubWebServers
        Assert-Equal 0 @(Get-HubWebServers).Count 'serveur : arrêté'
        $fixedPort = Get-HubFreePort -Start 18187
        Set-Content -LiteralPath (Join-Path $flutterApp 'project-hub.json') -Value ("{`"webPort`":$fixedPort}")
        $fixedServer = Start-HubWebServer -Path $flutterApp -Directory $build.Output[0] -PythonCommand $python
        Assert-Equal $fixedPort $fixedServer.Port 'serveur : port fixe utilise sans StartPort explicite'
        Stop-HubWebServers -Path $flutterApp
        Remove-Item -LiteralPath (Join-Path $flutterApp 'project-hub.json')

        $failedServer = $false
        try {
            Start-HubWebServer -Path $flutterApp -Directory $build.Output[0] -PythonCommand $stubFlutter -StartPort 18080 | Out-Null
        }
        catch { $failedServer = $_.Exception.Message -like '*Serveur web indisponible*' }
        Assert-True $failedServer 'serveur : démarrage échoué signalé explicitement'
        Assert-Equal 0 @(Get-HubWebServers).Count 'serveur : aucun faux serveur enregistré après échec'

        # Charger uniquement les fonctions de previsualisation, sans demarrer le menu.
        $tokens = $null; $parseErrors = $null
        $menuAst = [System.Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $PSScriptRoot 'projects-hub.ps1'), [ref]$tokens, [ref]$parseErrors)
        Assert-Equal 0 @($parseErrors).Count 'menu : syntaxe valide'
        foreach ($name in @('Write-Result', 'Invoke-WebPreview')) {
            $definition = $menuAst.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
            }, $true)
            . ([scriptblock]::Create($definition.Extent.Text))
        }
        $script:OpenedUrls = @()
        function Open-HubUrl([string]$Url) { $script:OpenedUrls += $Url; return "$Url`?v=test" }
        $script:FlutterCommand = $stubFlutter
        $script:PythonCommand = $python
        $project = [pscustomobject]@{ Path = $flutterApp; IsFlutter = $true; HasWeb = $true }
        $argumentLog = Join-Path $flutterApp 'hub-flutter-arguments.txt'
        $before = [System.IO.File]::ReadAllText($argumentLog)
        Set-Content -LiteralPath (Join-Path $flutterApp 'source-preview.txt') -Value 'updated-local-code'
        Invoke-WebPreview -Project $project -SkipBuild
        Assert-Equal $before ([System.IO.File]::ReadAllText($argumentLog)) 'relance sans compilation : Flutter non invoque'
        Assert-Equal 1 $script:OpenedUrls.Count 'relance sans compilation : navigateur ouvert'
        $firstPort = @(Get-HubWebServers)[0].Port
        $previousResponse = Invoke-WebRequest -Uri @(Get-HubWebServers)[0].Url -UseBasicParsing -TimeoutSec 5
        Assert-True ($previousResponse.Content -match 'built' -and $previousResponse.Content -notmatch 'updated-local-code') 'sans compilation : dernier build conserve malgre les modifications locales'
        Invoke-WebPreview -Project $project
        Assert-Equal $firstPort @(Get-HubWebServers)[0].Port 'relance avec compilation : meme serveur reutilise'
        Assert-True ([System.IO.File]::ReadAllText($argumentLog).Length -gt $before.Length) 'relance avec compilation : nouveau build effectue'
        $updatedResponse = Invoke-WebRequest -Uri @(Get-HubWebServers)[0].Url -UseBasicParsing -TimeoutSec 5
        Assert-True ($updatedResponse.Content -match 'updated-local-code') 'avec compilation : serveur expose les nouvelles modifications'
        Stop-HubWebServers -Path $flutterApp
        Invoke-WebPreview -Project $project -SkipBuild
        Assert-Equal 1 @(Get-HubWebServers).Count 'apres arret : dernier build relance sans compiler'
        Stop-HubWebServers -Path $flutterApp
        $missingProject = [pscustomobject]@{ Path = $notGit; IsFlutter = $true }
        $openedBefore = $script:OpenedUrls.Count
        Invoke-WebPreview -Project $missingProject -SkipBuild
        Assert-Equal $openedBefore $script:OpenedUrls.Count 'sans ancien build : aucun navigateur ouvert'
        Assert-Equal 0 @(Get-HubWebServers).Count 'sans ancien build : aucun serveur lance'
    }
    else {
        Write-Host '  SKIP  python introuvable : tests serveur ignorés' -ForegroundColor Yellow
    }

    $sdkRoot = Join-Path $tempRoot 'portable-sdk'
    New-Item -ItemType Directory -Force -Path (Join-Path $sdkRoot 'bin') | Out-Null
    $sdkFlutter = Join-Path $sdkRoot 'bin\flutter.bat'
    [System.IO.File]::WriteAllText($sdkFlutter, "@echo off`r`nexit /b 0`r`n")
    $configDirectory = Join-Path $projectsRoot '.github\foundation\config'
    New-Item -ItemType Directory -Force -Path $configDirectory | Out-Null
    $toolchainPath = Join-Path $configDirectory 'toolchain.json'
    $toolchainConfig = [ordered]@{ flutterRoot = '../../../../portable-sdk' }
    [System.IO.File]::WriteAllText($toolchainPath, ($toolchainConfig | ConvertTo-Json), [System.Text.UTF8Encoding]::new($false))
    $savedPath = $env:Path
    try {
        $env:Path = ''
        $resolved = Resolve-HubFlutterCommand -Root $projectsRoot
    } finally { $env:Path = $savedPath }
    Assert-Equal $sdkFlutter $resolved 'Resolve-HubFlutterCommand : chemin relatif depuis toolchain.json'

    $toolchainConfig.flutterRoot = $sdkRoot
    [System.IO.File]::WriteAllText($toolchainPath, ($toolchainConfig | ConvertTo-Json), [System.Text.UTF8Encoding]::new($false))
    try {
        $env:Path = ''
        $resolved = Resolve-HubFlutterCommand -Root $projectsRoot
    } finally { $env:Path = $savedPath }
    Assert-Equal $sdkFlutter $resolved 'Resolve-HubFlutterCommand : ancien chemin absolu toujours accepté'

    if ($FlutterSdkRoot) {
        $shared = Get-Content (Join-Path $FlutterSdkRoot 'bin\internal\shared.bat') -Raw
        $guardedCalls = [regex]::Matches($shared, "DriveFormat -ne 'exFAT'\) \{ Unblock-File")
        Assert-Equal 2 $guardedCalls.Count 'SDK : les deux Unblock-File ignorent exFAT'
        $versionOutput = & (Join-Path $FlutterSdkRoot 'bin\flutter.bat') --version 2>&1 | Out-String
        Assert-Equal 0 $LASTEXITCODE 'SDK : flutter --version fonctionne'
        Assert-True ($versionOutput -notmatch 'Unblock-File|Zone.Identifier') 'SDK : aucun avertissement Unblock-File'
    }

    & {
        $tokens = $null; $parseErrors = $null
        $menuAst = [System.Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $PSScriptRoot 'projects-hub.ps1'), [ref]$tokens, [ref]$parseErrors)
        Assert-Equal 0 @($parseErrors).Count 'menu AAB : syntaxe valide'
        if (@($parseErrors).Count -ne 0) { return }
        $definition = $menuAst.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Show-ProjectMenu'
        }, $true)
        . ([scriptblock]::Create($definition.Extent.Text))
        function Get-HubGitState { param($Path, [switch]$NoFetch) return [pscustomobject]@{ LastCommit = ''; IsRepo = $false } }
        function Format-HubGitState { param($State) return '' }
        function Get-HubWebServers { return @() }
        function Clear-Host {}
        function Write-Title { param($Text) }
        function Wait-Key {}
        function Read-Host { param($Prompt) $choice = $script:MenuChoices[0]; $script:MenuChoices = @($script:MenuChoices | Select-Object -Skip 1); return $choice }
        function Read-Confirmation { param($Question) return $script:MenuConfirmed }
        function Invoke-HubAndroidAppBundle { param($Path, $FlutterCommand) $script:MenuBuilds++; return [pscustomobject]@{ Success = $true; Output = @(); Message = 'ok' } }
        function Write-Result { param($Result) }
        $script:FlutterCommand = $stubFlutter
        $script:MenuBuilds = 0
        $script:MenuConfirmed = $false
        $script:MenuChoices = @('10', '0')
        $flutterRow = [pscustomobject]@{ Project = [pscustomobject]@{ Name = 'test'; Path = $flutterApp; IsFlutter = $true } }
        $menuOutput = @((Show-ProjectMenu $flutterRow) 6>&1) -join "`n"
        Assert-True ($menuOutput -like '*10*Android App Bundle*') 'menu AAB : option visible pour Flutter'
        Assert-Equal 0 $script:MenuBuilds 'menu AAB : confirmation refusee ne lance pas de build'
        $script:MenuConfirmed = $true
        $script:MenuChoices = @('10', '0')
        Show-ProjectMenu $flutterRow 6>&1 | Out-Null
        Assert-Equal 1 $script:MenuBuilds 'menu AAB : confirmation lance un build'
        $script:FlutterCommand = $null
        $script:MenuChoices = @('10', '0')
        $menuOutput = @((Show-ProjectMenu $flutterRow) 6>&1) -join "`n"
        Assert-True ($menuOutput -like '*Flutter introuvable*') 'menu AAB : Flutter absent signale'
        Assert-Equal 1 $script:MenuBuilds 'menu AAB : aucun build sans Flutter'
        $script:FlutterCommand = $stubFlutter
        $script:MenuChoices = @('10', '0')
        $nonFlutterRow = [pscustomobject]@{ Project = [pscustomobject]@{ Name = 'test'; Path = $notGit; IsFlutter = $false } }
        $menuOutput = @((Show-ProjectMenu $nonFlutterRow) 6>&1) -join "`n"
        Assert-True ($menuOutput -notlike '*Android App Bundle*') 'menu AAB : option masquee hors Flutter'
        Assert-Equal 1 $script:MenuBuilds 'menu AAB : choix ignore hors Flutter'
    }
}
finally {
    Stop-HubWebServers
    if (-not $KeepArtifacts) { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host ''
Write-Host "Résultat : $script:Passed réussi(s), $script:Failed échec(s)" -ForegroundColor (@('Green', 'Red')[[int]($script:Failed -gt 0)])
if ($script:Failed -gt 0) { exit 1 }
exit 0