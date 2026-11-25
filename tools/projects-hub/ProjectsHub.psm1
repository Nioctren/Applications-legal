# ProjectsHub.psm1 - Logique de l'utilitaire Projects Hub (sans interface).
# Toutes les fonctions sont testables indépendamment du menu interactif.
# Compatible Windows PowerShell 5.1 et PowerShell 7.

Set-StrictMode -Version Latest

# Dossiers de la racine qui ne sont pas des applications.
$script:ExcludedFolders = @('.github', 'projects-hub')

# Serveurs web locaux lancés pendant la session : chemin projet -> infos serveur.
$script:HubServers = @{}

# ---------------------------------------------------------------------------
# Découverte des projets
# ---------------------------------------------------------------------------

function Resolve-HubWorkspaceRoot {
    [CmdletBinding()]
    param([string]$HubDirectory = $PSScriptRoot)

    return [IO.Path]::GetFullPath((Join-Path $HubDirectory '..\..\..'))
}

function Get-HubProjects {
    <#
    .SYNOPSIS
    Liste les applications (dossiers) sous la racine, hors dossiers techniques.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root)

    $folders = Get-ChildItem -LiteralPath $Root -Directory |
        Where-Object {
            $script:ExcludedFolders -notcontains $_.Name -and
            -not $_.Name.StartsWith('.') -and
            -not ($_.Attributes -band [System.IO.FileAttributes]::Hidden)
        } |
        Sort-Object Name

    foreach ($folder in $folders) {
        [pscustomobject]@{
            Name      = $folder.Name
            Path      = $folder.FullName
            IsFlutter = Test-Path -LiteralPath (Join-Path $folder.FullName 'pubspec.yaml')
            HasWeb    = Test-Path -LiteralPath (Join-Path $folder.FullName 'web\index.html')
        }
    }
}

# ---------------------------------------------------------------------------
# Git : lecture d'état
# ---------------------------------------------------------------------------

function Invoke-HubGit {
    <#
    .SYNOPSIS
    Exécute git dans un dossier et renvoie code de sortie + sortie texte.
    Ne lève jamais d'exception : l'appelant décide quoi faire du code retour.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    # 'Continue' évite qu'un message git sur stderr soit converti en exception (PS 5.1).
    $ErrorActionPreference = 'Continue'
    $previousPrompt = $env:GIT_TERMINAL_PROMPT
    $env:GIT_TERMINAL_PROMPT = '0'
    try {
        # safe.directory=* : les dépôts sur un disque sans propriétaire NTFS (exFAT volumes) sont acceptés.
        $output = & git -c safe.directory=* -C $Path @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $env:GIT_TERMINAL_PROMPT = $previousPrompt
    }

    # stdout arrive en [string], stderr en ErrorRecord : on les sépare pour ne jamais
    # confondre un "warning:" git avec une vraie donnée.
    $stdout = @($output | Where-Object { $_ -is [string] })
    $stderr = @($output | Where-Object { $_ -isnot [string] } | ForEach-Object { "$_" })

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output   = $stdout
        Errors   = $stderr
    }
}

function Get-HubGitState {
    <#
    .SYNOPSIS
    Calcule l'état git d'un dossier : modifs locales, commits à pousser / à récupérer.
    .PARAMETER NoFetch
    Ne contacte pas le remote (mode hors-ligne) : Behind reflète le dernier fetch connu.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$NoFetch
    )

    $state = [pscustomobject]@{
        IsRepo      = $false
        Branch      = $null
        RemoteName  = $null
        HasRemote   = $false
        HasUpstream = $false
        Dirty       = 0
        Ahead       = 0
        Behind      = 0
        FetchFailed = $false
        LastCommit  = $null
        Error       = $null
    }

    if (-not (Test-Path -LiteralPath (Join-Path $Path '.git'))) { return $state }
    $state.IsRepo = $true

    $result = Invoke-HubGit -Path $Path -Arguments @('remote')
    $remotes = @($result.Output | Where-Object { $_ -ne '' })
    if ($result.ExitCode -eq 0 -and $remotes.Count -gt 0) {
        $state.HasRemote = $true
        $state.RemoteName = $remotes[0]
    }

    if ($state.HasRemote -and -not $NoFetch) {
        # BatchMode : un remote SSH sans clé chargée échoue immédiatement au lieu de bloquer.
        $previousSsh = $env:GIT_SSH_COMMAND
        $env:GIT_SSH_COMMAND = 'ssh -oBatchMode=yes'
        try {
            $result = Invoke-HubGit -Path $Path -Arguments @('fetch', '--quiet')
            $state.FetchFailed = ($result.ExitCode -ne 0)
        }
        finally {
            $env:GIT_SSH_COMMAND = $previousSsh
        }
    }

    # Un seul appel donne branche, upstream, ahead/behind et fichiers modifiés.
    # Fonctionne aussi sur une branche sans commit ("branch.oid (initial)").
    $result = Invoke-HubGit -Path $Path -Arguments @('status', '--porcelain=v2', '--branch')
    if ($result.ExitCode -eq 0) {
        foreach ($line in $result.Output) {
            if ($line -match '^# branch\.head (.+)$') { $state.Branch = $Matches[1] }
            elseif ($line -match '^# branch\.upstream ') { $state.HasUpstream = $true }
            elseif ($line -match '^# branch\.ab \+(\d+) -(\d+)$') {
                $state.Ahead = [int]$Matches[1]
                $state.Behind = [int]$Matches[2]
            }
            elseif ($line -ne '' -and -not $line.StartsWith('#')) { $state.Dirty++ }
        }
        if ($state.Branch -eq '(detached)') { $state.Branch = 'HEAD détaché' }
    }
    else {
        $state.Error = ($result.Errors -join ' ').Trim()
        if (-not $state.Error) { $state.Error = "git status a échoué (code $($result.ExitCode))" }
    }
    $result = Invoke-HubGit -Path $Path -Arguments @('log', '-1', '--date=short', '--format=%h %ad %s')
    if ($result.ExitCode -eq 0 -and $result.Output.Count -gt 0) { $state.LastCommit = $result.Output[0] }

    return $state
}

function Format-HubGitState {
    <#
    .SYNOPSIS
    Transforme un état git en libellé court lisible dans le tableau du menu.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$State)

    if (-not $State.IsRepo) { return '[XX] pas de git' }
    if ($State.Error) { return "[!!] erreur git : $($State.Error)" }

    $parts = @()
    if ($State.Dirty -gt 0) { $parts += "[MOD] $($State.Dirty) modif(s)" }
    if ($State.Ahead -gt 0) { $parts += "[UP] $($State.Ahead) à pousser" }
    if ($State.Behind -gt 0) { $parts += "[DOWN] $($State.Behind) à récupérer" }
    if (-not $State.HasRemote) { $parts += '[--] pas de remote' }
    elseif (-not $State.HasUpstream) { $parts += '[--] pas d''upstream' }
    if ($State.FetchFailed) { $parts += '[?] fetch échoué' }
    if ($parts.Count -eq 0) { $parts += '[OK] à jour' }

    $label = $parts -join ' · '
    if ($State.Branch) { $label += " ($($State.Branch))" }
    return $label
}

function Test-HubGitSynced {
    <#
    .SYNOPSIS
    Vrai si rien à commiter, rien à pousser, rien à récupérer.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$State)
    return ($State.IsRepo -and $State.Dirty -eq 0 -and $State.Ahead -eq 0 -and $State.Behind -eq 0)
}

# ---------------------------------------------------------------------------
# Git : actions (commit / push / pull)
# ---------------------------------------------------------------------------

function New-HubActionResult {
    param([bool]$Success, [string[]]$Output = @(), [string]$Message = '')
    return [pscustomobject]@{ Success = $Success; Output = $Output; Message = $Message }
}

function Get-HubDefaultCommitMessage {
    <#
    .SYNOPSIS
    Message de commit proposé par défaut : "chore: sync yyyy-MM-dd".
    #>
    [CmdletBinding()]
    param([datetime]$Date = (Get-Date))
    return "chore: sync $($Date.ToString('yyyy-MM-dd'))"
}

function Get-HubGitSummary {
    <#
    .SYNOPSIS
    Lignes à afficher avant un commit : fichiers modifiés + statistiques de diff.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $lines = @()
    $status = Invoke-HubGit -Path $Path -Arguments @('status', '--short')
    $lines += $status.Output
    $diff = Invoke-HubGit -Path $Path -Arguments @('diff', 'HEAD', '--stat')
    if ($diff.ExitCode -eq 0 -and $diff.Output.Count -gt 0) {
        $lines += ''
        $lines += $diff.Output
    }
    return $lines
}

function Invoke-HubCommit {
    <#
    .SYNOPSIS
    git add -A puis git commit -m <message>.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Message
    )

    $add = Invoke-HubGit -Path $Path -Arguments @('add', '-A')
    if ($add.ExitCode -ne 0) {
        return New-HubActionResult -Success $false -Output $add.Errors -Message 'git add a échoué.'
    }

    $commit = Invoke-HubGit -Path $Path -Arguments @('commit', '-m', $Message)
    if ($commit.ExitCode -ne 0) {
        return New-HubActionResult -Success $false -Output ($commit.Output + $commit.Errors) -Message 'git commit a échoué.'
    }
    return New-HubActionResult -Success $true -Output $commit.Output -Message 'Commit créé.'
}

function Invoke-HubPush {
    <#
    .SYNOPSIS
    git push (jamais --force). Crée l'upstream si la branche n'en a pas encore.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $state = Get-HubGitState -Path $Path -NoFetch
    if (-not $state.IsRepo) { return New-HubActionResult -Success $false -Message 'Pas un dépôt git.' }
    if (-not $state.HasRemote) { return New-HubActionResult -Success $false -Message 'Aucun remote configuré : impossible de pousser.' }
    if (-not $state.Branch) { return New-HubActionResult -Success $false -Message 'Aucune branche courante.' }

    if ($state.HasUpstream) {
        $arguments = @('push')
    }
    else {
        $arguments = @('push', '-u', $state.RemoteName, $state.Branch)
    }

    $push = Invoke-HubGit -Path $Path -Arguments $arguments
    if ($push.ExitCode -ne 0) {
        return New-HubActionResult -Success $false -Output ($push.Output + $push.Errors) -Message 'git push a échoué.'
    }
    return New-HubActionResult -Success $true -Output ($push.Output + $push.Errors) -Message 'Push effectué.'
}

function Invoke-HubPullRebase {
    <#
    .SYNOPSIS
    git pull --rebase. En cas de conflit, s'arrête et laisse l'utilisateur résoudre.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $pull = Invoke-HubGit -Path $Path -Arguments @('pull', '--rebase')
    if ($pull.ExitCode -ne 0) {
        $hint = 'git pull --rebase a échoué. Résoudre à la main (ou "git rebase --abort" pour annuler).'
        return New-HubActionResult -Success $false -Output ($pull.Output + $pull.Errors) -Message $hint
    }
    return New-HubActionResult -Success $true -Output ($pull.Output + $pull.Errors) -Message 'Dépôt mis à jour.'
}

# ---------------------------------------------------------------------------
# Web : build Flutter + serveur local
# ---------------------------------------------------------------------------

function Resolve-HubFlutterCommand {
    <#
    .SYNOPSIS
    Trouve flutter : PATH, puis toolchain.json de la foundation, puis dossier voisin de Projects.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root)

    $fromPath = Get-Command flutter -ErrorAction SilentlyContinue
    if ($fromPath) { return $fromPath.Source }

    $toolchain = Join-Path $Root '.github\foundation\config\toolchain.json'
    if (Test-Path -LiteralPath $toolchain) {
        $config = Get-Content -LiteralPath $toolchain -Raw | ConvertFrom-Json
        if ($config.flutterRoot) {
            $flutterRoot = $config.flutterRoot
            if (-not [IO.Path]::IsPathRooted($flutterRoot)) {
                $flutterRoot = Join-Path (Split-Path -Parent $toolchain) $flutterRoot
            }
            $candidate = Join-Path $flutterRoot 'bin\flutter.bat'
            if (Test-Path -LiteralPath $candidate) { return [IO.Path]::GetFullPath($candidate) }
        }
    }

    $sibling = Join-Path (Split-Path $Root -Parent) 'Flutter\flutter\bin\flutter.bat'
    if (Test-Path -LiteralPath $sibling) { return $sibling }

    return $null
}

function Resolve-HubPythonCommand {
    <#
    .SYNOPSIS
    Trouve python (ou le lanceur py) pour servir le dossier build\web.
    #>
    [CmdletBinding()]
    param([string]$Root = (Resolve-HubWorkspaceRoot))
    foreach ($name in @('python', 'py')) {
        $command = Get-Command $name -ErrorAction SilentlyContinue
        if ($command -and $command.Source -notlike '*\Microsoft\WindowsApps\*') { return $command.Source }
    }
    $portable = Join-Path (Split-Path $Root -Parent) 'Python\python.exe'
    if (Test-Path -LiteralPath $portable) { return $portable }
    return $null
}

function Get-HubFreePort {
    <#
    .SYNOPSIS
    Premier port TCP libre à partir de Start.
    #>
    [CmdletBinding()]
    param([int]$Start = 8080, [int]$Count = 100)

    $properties = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties()
    $used = @($properties.GetActiveTcpListeners() | ForEach-Object { $_.Port })
    for ($port = $Start; $port -lt ($Start + $Count); $port++) {
        if ($used -notcontains $port) { return $port }
    }
    throw "Aucun port libre entre $Start et $($Start + $Count - 1)."
}

function Enable-HubWebPlatform {
    <#
    .SYNOPSIS
    Ajoute le dossier web/ à un projet Flutter (flutter create --platforms web .).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$FlutterCommand
    )

    Push-Location -LiteralPath $Path
    try {
        & $FlutterCommand create --platforms web . | Out-Host
        $exitCode = $LASTEXITCODE
    }
    finally { Pop-Location }

    $created = Test-Path -LiteralPath (Join-Path $Path 'web\index.html')
    if ($exitCode -ne 0 -or -not $created) {
        return New-HubActionResult -Success $false -Message 'flutter create --platforms web a échoué.'
    }
    return New-HubActionResult -Success $true -Message 'Plateforme web ajoutée (dossier web/).'
}

function Get-HubProjectConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $file = Join-Path $Path 'project-hub.json'
    $arguments = @()
    $port = $null
    if (Test-Path -LiteralPath $file) {
        $config = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
        if ($config.PSObject.Properties['webBuildArguments']) {
            foreach ($argument in $config.webBuildArguments) {
                if ($argument -isnot [string] -or $argument -notmatch '^--dart-define(?:-from-file)?=.+$' -or $argument -match '[\r\n"&|<>]') {
                    throw 'project-hub.json : seuls les arguments --dart-define et --dart-define-from-file sont acceptes.'
                }
                $arguments += $argument
            }
        }
        if ($config.PSObject.Properties['webPort']) {
            if ($config.webPort -isnot [int] -or $config.webPort -lt 1024 -or $config.webPort -gt 65535) {
                throw 'project-hub.json : webPort doit etre un entier entre 1024 et 65535.'
            }
            $port = $config.webPort
        }
    }
    return [pscustomobject]@{ WebBuildArguments = $arguments; WebPort = $port }
}

function Invoke-HubProjectChecks {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$FlutterCommand
    )
    $check = Join-Path $Path 'scripts\check.ps1'
    Push-Location -LiteralPath $Path
    $savedPath = $env:Path
    try {
        $env:Path = "$(Split-Path -Parent $FlutterCommand);$savedPath"
        if (Test-Path -LiteralPath $check) {
            $shell = (Get-Process -Id $PID).Path
            & $shell -NoProfile -ExecutionPolicy Bypass -File $check | Out-Host
            if ($LASTEXITCODE -ne 0) {
                return New-HubActionResult -Success $false -Message 'scripts\check.ps1 a echoue.'
            }
        } else {
            & $FlutterCommand analyze | Out-Host
            if ($LASTEXITCODE -ne 0) {
                return New-HubActionResult -Success $false -Message 'flutter analyze a echoue ; tests non lances.'
            }
            & $FlutterCommand test | Out-Host
            if ($LASTEXITCODE -ne 0) {
                return New-HubActionResult -Success $false -Message 'flutter test a echoue.'
            }
        }
        return New-HubActionResult -Success $true -Message 'Verifications et tests reussis.'
    } finally {
        $env:Path = $savedPath
        Pop-Location
    }
}

function Invoke-HubAndroidAppBundle {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$FlutterCommand
    )

    if (-not (Test-Path -LiteralPath (Join-Path $Path 'android') -PathType Container)) {
        return New-HubActionResult -Success $false -Message 'Plateforme Android absente : ajouter android/ au projet avant de compiler.'
    }

    Push-Location -LiteralPath $Path
    try {
        & $FlutterCommand build appbundle --release | Out-Host
        $exitCode = $LASTEXITCODE
    }
    finally { Pop-Location }

    $bundle = Join-Path $Path 'build\app\outputs\bundle\release\app-release.aab'
    if ($null -eq $exitCode -or $exitCode -ne 0) {
        return New-HubActionResult -Success $false -Message 'flutter build appbundle --release a echoue ; un ancien AAB ne doit pas etre utilise.'
    }
    if (-not (Test-Path -LiteralPath $bundle -PathType Leaf)) {
        return New-HubActionResult -Success $false -Message "Build termine mais AAB introuvable : $bundle"
    }
    return New-HubActionResult -Success $true -Message 'AAB genere. Verifier sa signature release et la configuration Google Play avant publication.' -Output @($bundle)
}

function Invoke-HubWebBuild {
    <#
    .SYNOPSIS
    flutter build web sans service worker : le navigateur voit toujours la dernière version.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$FlutterCommand
    )

    if (-not (Test-Path -LiteralPath (Join-Path $Path 'web\index.html'))) {
        return New-HubActionResult -Success $false -Message 'Le dossier web/ est absent : activer la plateforme web d''abord.'
    }
    $config = Get-HubProjectConfig -Path $Path

    Write-Host ' [1/3] Compilation Flutter (sortie en direct)...' -ForegroundColor Cyan
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    $nextHeartbeat = 0
    $exitCode = $null
    $job = Start-Job -ArgumentList $Path, $FlutterCommand, $config -ScriptBlock {
        param($ProjectPath, $Command, $ProjectConfig)
        $ErrorActionPreference = 'Continue'
        [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
        Set-Location -LiteralPath $ProjectPath -ErrorAction Stop
        $buildArguments = @('build', 'web') + @($ProjectConfig.WebBuildArguments)
        & $Command @buildArguments 2>&1 | ForEach-Object { "$_" }
        [pscustomobject]@{ HubBuildExitCode = $LASTEXITCODE }
    }
    try {
        do {
            foreach ($item in @(Receive-Job -Job $job -ErrorAction Stop)) {
                if ($item.PSObject.Properties['HubBuildExitCode']) {
                    $exitCode = $item.HubBuildExitCode
                }
                else { Write-Host "$item" }
            }
            $elapsed = [int]$timer.Elapsed.TotalSeconds
            Write-Progress -Id 1 -Activity 'Build web Flutter' -Status "Compilation : ${elapsed}s ecoulees" -PercentComplete -1
            if ($elapsed -ge $nextHeartbeat) {
                Write-Host " [build] ${elapsed}s ecoulees - compilation en cours..." -ForegroundColor DarkCyan
                $nextHeartbeat = $elapsed + 5
            }
            if ($job.State -notin @('Running', 'NotStarted')) { break }
            Start-Sleep -Milliseconds 200
        } while ($true)
        # Le job peut terminer entre deux lectures ; vider les derniers messages.
        foreach ($item in @(Receive-Job -Job $job -ErrorAction Stop)) {
            if ($item.PSObject.Properties['HubBuildExitCode']) { $exitCode = $item.HubBuildExitCode }
            else { Write-Host "$item" }
        }
        if ($job.State -eq 'Failed') { throw $job.ChildJobs[0].JobStateInfo.Reason }
    }
    finally {
        Write-Progress -Id 1 -Activity 'Build web Flutter' -Completed
        $timer.Stop()
        if ($job.State -eq 'Running') { Stop-Job -Job $job }
        Remove-Job -Job $job -Force
    }

    Write-Host ' [2/3] Verification du build et nettoyage du service worker...' -ForegroundColor Cyan
    $buildDir = Join-Path $Path 'build\web'
    if ($null -eq $exitCode -or $exitCode -ne 0 -or -not (Test-Path -LiteralPath (Join-Path $buildDir 'index.html'))) {
        return New-HubActionResult -Success $false -Message 'flutter build web a échoué.'
    }

    # Flutter active encore le cache hors-ligne par defaut sans l'option PWA depreciee.
    $bootstrap = Join-Path $buildDir 'flutter_bootstrap.js'
    if (Test-Path -LiteralPath $bootstrap) {
        $text = [System.IO.File]::ReadAllText($bootstrap)
        $text = [regex]::Replace($text, '(?s)\bserviceWorkerSettings\s*:\s*\{[^{}]*\}', 'serviceWorkerSettings: undefined')
        if ($text -match '\bserviceWorkerSettings\s*:\s*\{') {
            throw 'Configuration service worker personnalisee non prise en charge : le build local ne sera pas ouvert.'
        }
        [System.IO.File]::WriteAllText($bootstrap, $text, [System.Text.UTF8Encoding]::new($false))
    }
    $serviceWorker = Join-Path $buildDir 'flutter_service_worker.js'
    if (Test-Path -LiteralPath $serviceWorker) { Remove-Item -LiteralPath $serviceWorker -Force }
    Write-Host " [3/3] Build termine en $([int]$timer.Elapsed.TotalSeconds)s." -ForegroundColor Green
    return New-HubActionResult -Success $true -Message "Build web prêt : $buildDir" -Output @($buildDir)
}

function Start-HubWebServer {
    <#
    .SYNOPSIS
    Sert un dossier via python -m http.server dans une fenêtre séparée.
    Réutilise le serveur déjà lancé pour ce projet s'il tourne encore.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$PythonCommand,
        [int]$StartPort = 8080
    )

    $existing = $script:HubServers[$Path]
    if ($existing -and -not $existing.Process.HasExited) { return $existing }

    $config = Get-HubProjectConfig -Path $Path
    if ($null -ne $config.WebPort) {
        $port = Get-HubFreePort -Start $config.WebPort -Count 1
    } else {
        $port = Get-HubFreePort -Start $StartPort
    }
    $arguments = @('-m', 'http.server', "$port", '--bind', '127.0.0.1', '--directory', "`"$Directory`"")
    $process = Start-Process -FilePath $PythonCommand -ArgumentList $arguments -WorkingDirectory $Directory -PassThru

    $server = [pscustomobject]@{
        Path    = $Path
        Port    = $port
        Url     = "http://127.0.0.1:$port/"
        Process = $process
    }
    Add-Type -AssemblyName System.Net.Http
    $ready = $false
    $lastError = $null
    $deadline = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $deadline -and -not $process.HasExited) {
        try {
            $response = Invoke-WebRequest -Uri $server.Url -UseBasicParsing -TimeoutSec 1 -ErrorAction Stop
            $ready = ($response.StatusCode -eq 200)
            if ($ready) { break }
        }
        catch [System.Net.WebException] { $lastError = $_.Exception.Message }
        catch [System.Net.Http.HttpRequestException] { $lastError = $_.Exception.Message }
        catch [System.Threading.Tasks.TaskCanceledException] { $lastError = $_.Exception.Message }
        Start-Sleep -Milliseconds 200
    }
    if (-not $ready -or $process.HasExited) {
        if (-not $process.HasExited) {
            $process.Kill()
            if (-not $process.WaitForExit(5000)) { throw "Le serveur non disponible (PID $($process.Id)) ne s'est pas arrete." }
        }
        throw "Serveur web indisponible sur $($server.Url). $lastError"
    }
    $script:HubServers[$Path] = $server
    return $server
}

function Get-HubWebServers {
    <#
    .SYNOPSIS
    Serveurs web locaux encore actifs lancés pendant cette session.
    #>
    [CmdletBinding()]
    param()
    foreach ($key in @($script:HubServers.Keys)) {
        $server = $script:HubServers[$key]
        if ($server.Process.HasExited) { $script:HubServers.Remove($key) }
        else { $server }
    }
}

function Stop-HubWebServers {
    <#
    .SYNOPSIS
    Arrête tous les serveurs web locaux lancés pendant cette session.
    #>
    [CmdletBinding()]
    param([string]$Path)
    foreach ($server in @(Get-HubWebServers)) {
        if ($Path -and $server.Path -ne $Path) { continue }
        if (-not $server.Process.HasExited) { $server.Process.Kill() }
        if (-not $server.Process.WaitForExit(5000)) {
            throw "Le serveur de $($server.Path) (PID $($server.Process.Id)) ne s'est pas arrete."
        }
        $script:HubServers.Remove($server.Path)
    }
}

function Open-HubUrl {
    <#
    .SYNOPSIS
    Ouvre une URL dans le navigateur par défaut, avec un paramètre anti-cache.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Url)
    $stamp = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $target = "$Url`?v=$stamp"
    Start-Process $target | Out-Null
    return $target
}

Export-ModuleMember -Function Get-HubProjects, Invoke-HubGit, Get-HubGitState, Format-HubGitState, Test-HubGitSynced,
    Get-HubDefaultCommitMessage, Get-HubGitSummary, Invoke-HubCommit, Invoke-HubPush, Invoke-HubPullRebase,
    Resolve-HubWorkspaceRoot, Resolve-HubFlutterCommand, Resolve-HubPythonCommand, Get-HubFreePort, Enable-HubWebPlatform, Invoke-HubWebBuild, Get-HubProjectConfig, Invoke-HubProjectChecks, Invoke-HubAndroidAppBundle,
    Start-HubWebServer, Get-HubWebServers, Stop-HubWebServers, Open-HubUrl