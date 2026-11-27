<#
.SYNOPSIS
Projects Hub : menu console pour piloter les applications du workspace.

.DESCRIPTION
Affiche la liste des applications avec leur état git, permet d'ouvrir la version
web locale d'une appli (flutter build web + serveur Python) et de commiter / pousser.

.PARAMETER NoFetch
Mode hors-ligne : ne contacte pas les remotes pendant les analyses.

.PARAMETER Root
Racine contenant les applications (par défaut : dossier parent de Applications-legal).
#>
[CmdletBinding()]
param(
    [switch]$NoFetch,
    [string]$Root
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Import-Module (Join-Path $PSScriptRoot 'ProjectsHub.psm1') -Force

# $PSScriptRoot n'est pas disponible dans les valeurs par défaut des paramètres sous PS 5.1.
if (-not $Root) { $Root = Resolve-HubWorkspaceRoot }
$Root = (Resolve-Path -LiteralPath $Root).Path
$script:FlutterCommand = Resolve-HubFlutterCommand -Root $Root
$script:PythonCommand = Resolve-HubPythonCommand -Root $Root
$script:CachePath = Get-HubCachePath -Root $Root

# ---------------------------------------------------------------------------
# Helpers d'affichage et de saisie
# ---------------------------------------------------------------------------

function Write-Title([string]$Text) {
    Write-Host ''
    Write-Host " $Text" -ForegroundColor Cyan
    Write-Host (' ' + ('-' * $Text.Length)) -ForegroundColor DarkCyan
}

function Write-Result($Result) {
    $color = 'Red'
    if ($Result.Success) { $color = 'Green' }
    Write-Host " $($Result.Message)" -ForegroundColor $color
    foreach ($line in $Result.Output) { Write-Host "   $line" -ForegroundColor DarkGray }
}

function Read-Confirmation([string]$Question) {
    $answer = Read-Host " $Question (o/N)"
    return ($answer -match '^[oOyY]$')
}

function Wait-Key {
    Write-Host ''
    Read-Host ' Entrée pour continuer' | Out-Null
}

function Get-StateColor($State) {
    if (-not $State.IsRepo -or $State.Error) { return 'DarkGray' }
    if (Test-HubGitSynced -State $State) {
        if ($State.HasRemote) { return 'Green' }
        return 'Yellow'
    }
    return 'Yellow'
}

# ---------------------------------------------------------------------------
# Chargement des projets et de leur état
# ---------------------------------------------------------------------------

function Get-ProjectRows {
    $projects = @(Get-HubProjects -Root $Root)
    $rows = @()
    $index = 0
    foreach ($project in $projects) {
        $index++
        Write-Host ("`r Analyse {0}/{1} : {2,-30}" -f $index, $projects.Count, $project.Name) -NoNewline
        $state = Get-HubGitState -Path $project.Path -NoFetch:$NoFetch
        $rows += [pscustomobject]@{
            Index       = $index
            Project     = $project
            State       = $state
            RefreshedAt = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        }
    }
    Write-Host ("`r" + (' ' * 60) + "`r") -NoNewline
    return $rows
}

function Save-ProjectRows($Rows) {
    try { Save-HubCache -Path $script:CachePath -Root $Root -Rows @($Rows) }
    catch {
        Write-Host " Impossible d'enregistrer le cache : $($_.Exception.Message)" -ForegroundColor Red
        Wait-Key
    }
}

function Update-ProjectRow($Row, [switch]$LocalOnly) {
    $project = Get-HubProject -Path $Row.Project.Path
    $state = Get-HubGitState -Path $project.Path -NoFetch:($NoFetch -or $LocalOnly)
    $Row.Project = $project
    $Row.State = $state
    $Row.RefreshedAt = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
}

function Show-ProjectTable($Rows) {
    Clear-Host
    $mode = 'fetch activé'
    if ($NoFetch) { $mode = 'hors-ligne (-NoFetch)' }
    Write-Title "Projects Hub — $Root  [$mode]"
    $nameWidth = 20
    $androidWidth = 7
    $iosWidth = 3
    foreach ($row in $Rows) {
        $nameWidth = [Math]::Max($nameWidth, $row.Project.Name.Length)
        $androidWidth = [Math]::Max($androidWidth, (Format-HubPlatform $row.Project.IsFlutter $row.Project.HasAndroid $row.Project.Version).Length)
        $iosWidth = [Math]::Max($iosWidth, (Format-HubPlatform $row.Project.IsFlutter $row.Project.HasIos $row.Project.Version).Length)
    }
    $format = " {0,-3} {1,-$nameWidth} {2,-6} {3,-$androidWidth} {4,-$iosWidth} {5,-19} {6}"
    Write-Host ($format -f '#', 'Projet', 'Web', 'Android', 'iOS', 'Analyse locale', 'Git') -ForegroundColor White
    foreach ($row in $Rows) {
        $web = '-'
        if ($row.Project.HasWeb) { $web = 'oui' }
        elseif ($row.Project.IsFlutter) { $web = 'non' }
        $label = Format-HubGitState -State $row.State
        $android = Format-HubPlatform $row.Project.IsFlutter $row.Project.HasAndroid $row.Project.Version
        $ios = Format-HubPlatform $row.Project.IsFlutter $row.Project.HasIos $row.Project.Version
        Write-Host ($format -f $row.Index, $row.Project.Name, $web, $android, $ios, $row.RefreshedAt, '') -NoNewline
        Write-Host $label -ForegroundColor (Get-StateColor $row.State)
    }
    $servers = @(Get-HubWebServers)
    if ($servers.Count -gt 0) {
        Write-Host ''
        Write-Host " Serveurs web actifs : $($servers.Count)" -ForegroundColor Magenta
        foreach ($server in $servers) { Write-Host "   $($server.Url)  ($(Split-Path -Leaf $server.Path))" -ForegroundColor DarkGray }
    }
    if (-not $script:FlutterCommand) { Write-Host ' Attention : flutter introuvable, les compilations Flutter sont désactivées.' -ForegroundColor Red }
    if (-not $script:PythonCommand) { Write-Host ' Attention : python introuvable, le serveur local est désactivé.' -ForegroundColor Red }
    Write-Host ''
    Write-Host ' Donnees memorisees : les changements externes peuvent ne pas etre affiches.' -ForegroundColor Yellow
    Write-Host " [1-$($Rows.Count)] projet · R rafraichir tout ou selection · Q quitter" -ForegroundColor White
}

# ---------------------------------------------------------------------------
# Actions sur un projet
# ---------------------------------------------------------------------------

function Invoke-WebPreview {
    param($Project, [switch]$SkipBuild)
    if (-not $SkipBuild -and -not $script:FlutterCommand) { Write-Host ' flutter introuvable.' -ForegroundColor Red; return }
    if (-not $script:PythonCommand) { Write-Host ' python introuvable.' -ForegroundColor Red; return }
    if (-not $Project.IsFlutter) { Write-Host ' Ce dossier n''est pas un projet Flutter.' -ForegroundColor Red; return }

    if (-not $SkipBuild -and -not (Test-Path -LiteralPath (Join-Path $Project.Path 'web\index.html'))) {
        Write-Host ' Ce projet n''a pas encore de plateforme web (dossier web/).' -ForegroundColor Yellow
        Write-Host ' flutter create --platforms web . ajoutera des fichiers au dépôt (à commiter ensuite).'
        if (-not (Read-Confirmation 'Ajouter la plateforme web maintenant ?')) { return }
        $enable = Enable-HubWebPlatform -Path $Project.Path -FlutterCommand $script:FlutterCommand
        Write-Result $enable
        if (-not $enable.Success) { return }
        $Project.HasWeb = $true
    }

    $buildDirectory = Join-Path $Project.Path 'build\web'
    if ($SkipBuild) {
        if (-not (Test-Path -LiteralPath (Join-Path $buildDirectory 'index.html'))) {
            Write-Host ' Aucun build web disponible. Utiliser 1 pour compiler d''abord.' -ForegroundColor Red
            return
        }
        Write-Host ' Reouverture du dernier build, sans compiler les modifications Dart.' -ForegroundColor Yellow
    }
    else {
        $build = Invoke-HubWebBuild -Path $Project.Path -FlutterCommand $script:FlutterCommand
        Write-Result $build
        if (-not $build.Success) { return }
        $buildDirectory = $build.Output[0]
    }

    Write-Host ' Verification / demarrage du serveur local...' -ForegroundColor Cyan
    $server = Start-HubWebServer -Path $Project.Path -Directory $buildDirectory -PythonCommand $script:PythonCommand
    $url = Open-HubUrl -Url $server.Url
    Write-Host " Ouvert dans le navigateur : $url" -ForegroundColor Green
    Write-Host ' (le serveur tourne dans une fenêtre séparée ; Q dans le hub propose de l''arrêter)' -ForegroundColor DarkGray
}

function Invoke-CommitFlow($Project, $State) {
    if ($State.Dirty -eq 0) { Write-Host ' Rien à commiter.' -ForegroundColor Green; return $false }

    Write-Title "Modifications dans $($Project.Name)"
    foreach ($line in (Get-HubGitSummary -Path $Project.Path)) { Write-Host "   $line" -ForegroundColor DarkGray }
    Write-Host ''

    $default = Get-HubDefaultCommitMessage
    $message = Read-Host " Message de commit [$default]"
    if ([string]::IsNullOrWhiteSpace($message)) { $message = $default }

    if (-not (Read-Confirmation "Commiter tout (git add -A) avec « $message » ?")) { return $false }
    $result = Invoke-HubCommit -Path $Project.Path -Message $message
    Write-Result $result
    return $result.Success
}

function Invoke-PushFlow($Project, $State) {
    if (-not $State.HasRemote) { Write-Host ' Aucun remote : impossible de pousser.' -ForegroundColor Red; return }
    $target = $State.RemoteName
    if (-not $State.HasUpstream) { $target = "$($State.RemoteName)/$($State.Branch) (création de l'upstream)" }
    if (-not (Read-Confirmation "Pousser vers $target ?")) { return }
    Write-Result (Invoke-HubPush -Path $Project.Path)
}

function Invoke-PullFlow($Project) {
    if (-not (Read-Confirmation 'Récupérer les commits distants (git pull --rebase) ?')) { return }
    Write-Result (Invoke-HubPullRebase -Path $Project.Path)
}

function Show-GitDetails($Project, $State) {
    Write-Title "Détail git : $($Project.Name)"
    Write-Host "   Branche      : $($State.Branch)"
    Write-Host "   Remote       : $($State.RemoteName) (upstream : $($State.HasUpstream))"
    Write-Host "   Dernier commit : $($State.LastCommit)"
    Write-Host "   Modifs / à pousser / à récupérer : $($State.Dirty) / $($State.Ahead) / $($State.Behind)"
    Write-Host ''
    foreach ($line in (Get-HubGitSummary -Path $Project.Path)) { Write-Host "   $line" -ForegroundColor DarkGray }
}

function Show-ProjectMenu($Row) {
    $project = $Row.Project
    while ($true) {
        $state = Get-HubGitState -Path $project.Path -NoFetch
        Clear-Host
        Write-Title "$($project.Name) — $(Format-HubGitState -State $state)"
        if ($state.LastCommit) { Write-Host "   Dernier commit : $($state.LastCommit)" -ForegroundColor DarkGray }
        Write-Host ''
        if ($project.IsFlutter) {
            Write-Host '   1  Lancer / relancer avec compilation (dernieres modifications)'
            Write-Host '   7  Rouvrir le dernier build sans compilation'
            Write-Host '   9  Verifier et lancer les tests (scripts\check.ps1 ou Flutter)'
            Write-Host '  10  Construire un Android App Bundle (AAB) release'
            $activeServer = @(Get-HubWebServers | Where-Object { $_.Path -eq $project.Path })
            if ($activeServer.Count -gt 0) {
                Write-Host "      Serveur actif : $($activeServer[0].Url)" -ForegroundColor Green
                Write-Host '   8  Arreter le serveur de cette application'
            }
        }
        if ($state.IsRepo) {
            Write-Host '   2  Voir le détail git'
            Write-Host "   3  Commiter (message proposé : $(Get-HubDefaultCommitMessage))"
            if ($state.HasRemote) {
                Write-Host '   4  Pousser'
                Write-Host '   5  Commiter + pousser'
            }
            if ($state.Behind -gt 0) { Write-Host '   6  Récupérer (pull --rebase)' }
        }
        Write-Host '   0  Retour'
        Write-Host ''
        $choice = Read-Host ' Choix'

        switch ($choice) {
            '0' { return }
            '1' { if ($project.IsFlutter) { Invoke-WebPreview $project; Wait-Key } }
            '7' { if ($project.IsFlutter) { Invoke-WebPreview -Project $project -SkipBuild; Wait-Key } }
            '9' {
                if ($project.IsFlutter) {
                    if (-not $script:FlutterCommand) { Write-Host ' Flutter introuvable.' -ForegroundColor Red }
                    elseif (Read-Confirmation 'Lancer les verifications et les tests de ce projet ?') {
                        Write-Result (Invoke-HubProjectChecks -Path $project.Path -FlutterCommand $script:FlutterCommand)
                    }
                    Wait-Key
                }
            }
            '10' {
                if ($project.IsFlutter) {
                    if (-not $script:FlutterCommand) { Write-Host ' Flutter introuvable.' -ForegroundColor Red }
                    elseif (Read-Confirmation 'Construire le bundle Android release de ce projet ?') {
                        Write-Host ' La signature release doit etre configuree dans le projet ; elle ne sera pas verifiee par le hub.' -ForegroundColor Yellow
                        Write-Result (Invoke-HubAndroidAppBundle -Path $project.Path -FlutterCommand $script:FlutterCommand)
                    }
                    Wait-Key
                }
            }
            '8' {
                if ($project.IsFlutter -and (Read-Confirmation 'Arreter le serveur de cette application ?')) {
                    Stop-HubWebServers -Path $project.Path
                    Write-Host ' Serveur arrete (l''onglet du navigateur peut etre ferme).' -ForegroundColor Green
                    Wait-Key
                }
            }
            '2' { if ($state.IsRepo) { Show-GitDetails $project $state; Wait-Key } }
            '3' { if ($state.IsRepo) { Invoke-CommitFlow $project $state | Out-Null; Wait-Key } }
            '4' { if ($state.IsRepo -and $state.HasRemote) { Invoke-PushFlow $project $state; Wait-Key } }
            '5' {
                if ($state.IsRepo -and $state.HasRemote) {
                    $committed = Invoke-CommitFlow $project $state
                    if ($committed -or $state.Dirty -eq 0) {
                        $fresh = Get-HubGitState -Path $project.Path -NoFetch
                        Invoke-PushFlow $project $fresh
                    }
                    Wait-Key
                }
            }
            '6' { if ($state.IsRepo -and $state.Behind -gt 0) { Invoke-PullFlow $project; Wait-Key } }
            default { }
        }
    }
}

# ---------------------------------------------------------------------------
# Boucle principale
# ---------------------------------------------------------------------------

$rows = @()
$loadedCache = $false
if (Test-Path -LiteralPath $script:CachePath -PathType Leaf) {
    try {
        $rows = @(Read-HubCache -Path $script:CachePath -Root $Root)
        $loadedCache = $true
    }
    catch {
        Write-Host " Cache illisible ($($_.Exception.Message)) : nouvelle analyse necessaire." -ForegroundColor Yellow
        Wait-Key
    }
}
if (-not $loadedCache) {
    $rows = @(Get-ProjectRows)
    Save-ProjectRows $rows
}
while ($true) {
    Show-ProjectTable $rows
    $choice = Read-Host ' Choix'

    if ($choice -match '^[qQ]$') {
        $servers = @(Get-HubWebServers)
        if ($servers.Count -gt 0 -and (Read-Confirmation "Arrêter les $($servers.Count) serveur(s) web locaux ?")) {
            Stop-HubWebServers
        }
        break
    }
    if ($choice -match '^[rR]$') {
        $selection = Read-Host ' Tout : * ; selection : numeros separes par des virgules ; annuler : entree'
        if ([string]::IsNullOrWhiteSpace($selection)) { continue }
        if ($selection.Trim() -eq '*') {
            $rows = @(Get-ProjectRows)
            Save-ProjectRows $rows
            continue
        }
        try { $numbers = @(ConvertFrom-HubSelection -Text $selection.Trim() -Count $rows.Count) }
        catch { Write-Host $_.Exception.Message -ForegroundColor Red; Wait-Key; continue }
        foreach ($number in $numbers) {
            $row = $rows[$number - 1]
            Write-Host " Analyse : $($row.Project.Name)" -ForegroundColor Cyan
            try { Update-ProjectRow $row }
            catch { Write-Host " Echec pour $($row.Project.Name) : $($_.Exception.Message)" -ForegroundColor Red; Wait-Key }
        }
        Save-ProjectRows $rows
        continue
    }

    $number = 0
    if ([int]::TryParse($choice, [ref]$number) -and $number -ge 1 -and $number -le $rows.Count) {
        $row = $rows[$number - 1]
        try { Update-ProjectRow $row -LocalOnly }
        catch { Write-Host " Impossible d'ouvrir $($row.Project.Name) : $($_.Exception.Message)" -ForegroundColor Red; Wait-Key; continue }
        Show-ProjectMenu $row
        try { Update-ProjectRow $row -LocalOnly }
        catch { Write-Host " Impossible d'actualiser $($row.Project.Name) : $($_.Exception.Message)" -ForegroundColor Red; Wait-Key }
        Save-ProjectRows $rows
    }
}