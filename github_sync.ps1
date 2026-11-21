[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$ProjectPath,
    [ValidateSet('Menu', 'Init', 'Start', 'Backup', 'Deploy', 'Status', 'Version')]
    [string]$Action = 'Menu',
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
# 사용자에게 새 버전을 배포할 때 버전과 마지막 수정 날짜를 함께 갱신한다.
$ToolVersion = '3.1.7'
$ToolUpdated = '2026-11-21'
$ReleaseLabel = "v$ToolVersion | 최종 수정 $ToolUpdated"
$QuietGit = @(if ($Action -eq 'Menu') { '--quiet' })
$DefaultPrivatePattern = '(^|/)(\.private|\.git|data|outputs)(/|$)|(^|/)\.clasp(?:rc)?\.json$|(^|/)\.env($|\.)|\.(pem|key|pfx|p12)$|(^|/)([^/]*(credential|oauth|secret|token)[^/]*\.(json|env)|회원설정\.json|배포정보\.json|독서기록[^/]*\.json|[^/]*전체백업[^/]*\.json)$'

function Find-Git {
    $command = Get-Command git.exe -CommandType Application -TotalCount 1 -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    foreach ($path in @(
        "$env:ProgramFiles\Git\cmd\git.exe",
        "$env:LOCALAPPDATA\Programs\Git\cmd\git.exe",
        "$env:USERPROFILE\.cache\codex-runtimes\codex-primary-runtime\dependencies\native\git\cmd\git.exe"
    )) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $env:PATH = (Split-Path -Parent $path) + ';' + $env:PATH
            return $path
        }
    }
    throw 'Git for Windows를 설치한 다음 다시 실행하세요.'
}

function Invoke-Git {
    & $GitExe --no-pager @args
    if ($LASTEXITCODE -ne 0) {
        $exitCode = $LASTEXITCODE
        $commandIndex = 0
        while ($args[$commandIndex] -in @('-c', '-C', '--no-optional-locks')) {
            if ($args[$commandIndex] -eq '--no-optional-locks') { $commandIndex++ }
            else { $commandIndex += 2 }
        }
        throw "git $($args[$commandIndex]) 실패 (종료 코드 $exitCode)."
    }
}

function Test-Ref([string]$Ref) {
    & $GitExe show-ref --verify --quiet $Ref
    return $LASTEXITCODE -eq 0
}

function Test-Ancestor([string]$Older, [string]$Newer) {
    & $GitExe merge-base --is-ancestor $Older $Newer
    switch ($LASTEXITCODE) {
        0 { return $true }
        1 { return $false }
        default { throw '브랜치 이력을 비교하지 못했습니다.' }
    }
}

function Get-NulPaths {
    $raw = @(Invoke-Git @args) -join "`n"
    foreach ($path in $raw.Split([char]0)) {
        if ($path.Length) { $path }
    }
}

function Get-Branch {
    $branch = & $GitExe symbolic-ref --quiet --short HEAD
    if ($LASTEXITCODE -ne 0) { throw '먼저 작업 브랜치로 전환하세요.' }
    return $branch
}

function Assert-NoPendingOperation {
    foreach ($name in @('MERGE_HEAD','CHERRY_PICK_HEAD','REVERT_HEAD','rebase-merge','rebase-apply','sequencer','BISECT_START')) {
        $path = Invoke-Git rev-parse --git-path $name
        if (Test-Path -LiteralPath $path) { throw '진행 중인 Git 작업을 완료하거나 취소한 뒤 다시 실행하세요.' }
    }
}

function Assert-Clean {
    param([switch]$AllowNewConfig)
    $changes = @(Invoke-Git status --porcelain=v1 --untracked-files=all --ignore-submodules=none)
    if ($AllowNewConfig -and $changes.Count -eq 1 -and $changes[0] -ceq '?? sync.config.json') { return }
    if ($changes.Count) {
        Invoke-Git -c core.quotepath=false status --short | Out-Host
        throw '작업 트리에 미커밋 변경이 있습니다. 위에 표시된 파일을 확인하세요.'
    }
}

function Assert-WorkBranch {
    $currentBranch = Get-Branch
    if ($currentBranch -cne $WorkBranch) { throw "현재 브랜치는 $currentBranch 입니다. 작업 브랜치인 $WorkBranch 로 전환하세요." }
}

function Get-ProjectFile([string]$RelativePath) {
    if (-not $RelativePath -or [IO.Path]::IsPathRooted($RelativePath) -or $RelativePath.Contains(':')) {
        throw '프로젝트 내부 상대 경로를 사용하세요.'
    }
    $prefix = $ProjectRoot.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    $path = [IO.Path]::GetFullPath((Join-Path $ProjectRoot $RelativePath))
    if (-not $path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw '프로젝트 밖 경로는 사용할 수 없습니다.'
    }
    return $path
}

function Assert-Array($Value, [string]$Field) {
    if ($Value -isnot [array]) { throw "$Field 설정에는 JSON 배열을 사용하세요." }
}

function Assert-Steps($Steps, [string]$Field) {
    Assert-Array $Steps $Field
    foreach ($step in $Steps) {
        if ($step -isnot [pscustomobject] -or $step.command -isnot [string] -or
            $step.command -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]*$') {
            throw "$Field 검사/배포 단계에는 실행 파일 이름(command)을 지정하세요."
        }
        if ($step.PSObject.Properties['args']) {
            Assert-Array $step.args "$Field.args"
            foreach ($item in $step.args) {
                if ($item -isnot [string] -or $item -match '[\x00\r\n]') {
                    throw "$Field.args에는 한 줄 문자열을 사용하세요."
                }
            }
        }
    }
}

function Get-DefaultRemote {
    $remotes = @(Invoke-Git remote)
    if ($remotes.Count -eq 0 -or $remotes -ccontains 'origin') { return 'origin' }
    if ($remotes.Count -eq 1) { return $remotes[0] }
    $branch = & $GitExe symbolic-ref --quiet --short HEAD
    if ($LASTEXITCODE -eq 0) {
        $upstreamRemote = & $GitExe config --get "branch.$branch.remote"
        if ($LASTEXITCODE -eq 0 -and $remotes -ccontains $upstreamRemote) { return $upstreamRemote }
    }
    throw 'Git 원격이 여러 개 있습니다. 저장소의 sync.config.json에 사용할 remote 별칭을 지정하세요.'
}

function Get-DefaultReleaseBranch([string]$RemoteName) {
    $prefix = "refs/remotes/$RemoteName/"
    $defaultRef = & $GitExe symbolic-ref --quiet "${prefix}HEAD"
    if ($LASTEXITCODE -eq 0 -and $defaultRef.StartsWith($prefix) -and (Test-Ref $defaultRef)) {
        return $defaultRef.Substring($prefix.Length)
    }
    foreach ($name in @('main','master')) {
        if (Test-Ref "$prefix$name") { return $name }
    }
    foreach ($name in @('main','master')) {
        if (Test-Ref "refs/heads/$name") { return $name }
    }
    $branch = & $GitExe symbolic-ref --quiet HEAD
    $localPrefix = 'refs/heads/'
    if ($LASTEXITCODE -eq 0 -and $branch.StartsWith($localPrefix)) { return $branch.Substring($localPrefix.Length) }
    return 'main'
}

function Read-SyncConfig {
    $config = [pscustomobject]@{
        workBranch = 'dev'; releaseBranch = $null; remote = $null; minNodeVersion = 22
        checkTasks = @(); checkCommands = @(); deployment = $null
        dataNotice = '개인 파일과 인증 정보는 Git 밖에 보관'; extraSensitivePattern = ''
    }
    $custom = $null
    if (Test-Path -LiteralPath $ConfigPath) {
        $json = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8
        $custom = ConvertFrom-Json -InputObject $json
        if ($custom -isnot [pscustomobject] -or $json -notmatch '^\s*\{') {
            throw 'sync.config.json의 최상위 값은 JSON 객체여야 합니다.'
        }
        foreach ($property in $custom.PSObject.Properties) {
            if (-not $config.PSObject.Properties[$property.Name]) { throw "알 수 없는 설정: $($property.Name)" }
            $config.($property.Name) = $property.Value
        }
    }
    if (-not $custom -or -not $custom.PSObject.Properties['remote']) { $config.remote = Get-DefaultRemote }
    if ($config.remote -isnot [string] -or $config.remote -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
        throw 'remote에는 origin 같은 Git 원격 별칭을 사용하세요.'
    }
    if (-not $custom -or -not $custom.PSObject.Properties['releaseBranch']) {
        $config.releaseBranch = Get-DefaultReleaseBranch $config.remote
    }
    foreach ($field in @('workBranch','releaseBranch')) {
        $branch = $config.$field
        if ($branch -isnot [string] -or -not $branch -or $branch.StartsWith('-') -or $branch -ceq 'HEAD') {
            throw "브랜치 이름 오류: $field"
        }
        & $GitExe check-ref-format "refs/heads/$branch"
        if ($LASTEXITCODE -ne 0) { throw "브랜치 이름 오류: $field" }
    }
    if ([string]$config.minNodeVersion -notmatch '^[1-9][0-9]{0,2}$') { throw 'minNodeVersion에는 Node.js 주 버전 숫자를 사용하세요.' }
    Assert-Array $config.checkTasks 'checkTasks'
    foreach ($task in $config.checkTasks) {
        if ($task -isnot [string] -or $task -notmatch '^[A-Za-z0-9][A-Za-z0-9_.:-]*$') { throw 'checkTasks에 잘못된 npm 작업 이름이 있습니다.' }
    }
    Assert-Steps $config.checkCommands 'checkCommands'
    if ($config.extraSensitivePattern -isnot [string]) { throw 'extraSensitivePattern에는 문자열을 사용하세요.' }
    $deploy = $config.deployment
    if ($null -ne $deploy) {
        if ($deploy -isnot [pscustomobject]) { throw 'deployment에는 객체 또는 null을 사용하세요.' }
        if (-not $deploy.mode -and $deploy.script) { $deploy | Add-Member NoteProperty mode 'legacy' -Force }
        switch -CaseSensitive ($deploy.mode) {
            'backup-push' {}
            'release-branch' {
                if ($config.workBranch -eq $config.releaseBranch) { throw 'release-branch에 서로 다른 작업/배포 브랜치를 지정하세요.' }
                if ($deploy.PSObject.Properties['createReleaseBranch'] -and $deploy.createReleaseBranch -isnot [bool]) {
                    throw 'deployment.createReleaseBranch에는 true 또는 false를 사용하세요.'
                }
            }
            'github-actions' {
                if ($deploy.workflow -isnot [string] -or $deploy.workflow -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]*\.ya?ml$') {
                    throw 'deployment.workflow에는 GitHub Actions 워크플로 파일명을 사용하세요.'
                }
                if ($deploy.PSObject.Properties['commitInput'] -and
                    ($deploy.commitInput -isnot [string] -or $deploy.commitInput -notmatch '^[A-Za-z][A-Za-z0-9_-]*$')) {
                    throw 'deployment.commitInput에는 워크플로 입력 이름을 사용하세요.'
                }
            }
            'commands' {
                Assert-Steps $deploy.commands 'deployment.commands'
                if ($deploy.commands.Count -eq 0) { throw 'deployment.commands에 실행 단계를 추가하세요.' }
            }
            'legacy' {
                $null = Get-ProjectFile $deploy.script
                if ([IO.Path]::GetExtension($deploy.script) -ne '.ps1') { throw 'deployment.script는 .ps1 파일이어야 합니다.' }
            }
            default { throw 'deployment.mode는 backup-push, release-branch, github-actions, commands, legacy 중 하나여야 합니다.' }
        }
    }
    return $config
}

function Find-NodeRuntime {
    $installed = Get-Command node.exe -CommandType Application -All -ErrorAction SilentlyContinue
    foreach ($candidate in @(
        $installed.Source
        "$env:ProgramFiles\nodejs\node.exe"
        "$env:USERPROFILE\.cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe"
    )) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            $version = & $candidate --version
            if ($LASTEXITCODE -eq 0 -and $version -match '^v(\d+)\.' -and [int]$Matches[1] -ge $SyncConfig.minNodeVersion) {
                $env:PATH = (Split-Path -Parent $candidate) + ';' + $env:PATH
                return $candidate
            }
        }
    }
    throw "Node.js $($SyncConfig.minNodeVersion) 이상이 필요합니다."
}

function Get-Executable([string]$Name) {
    if ($Name -in @('node','node.exe')) { return Find-NodeRuntime }
    $command = Get-Command $Name -CommandType Application -TotalCount 1 -ErrorAction SilentlyContinue
    if (-not $command) { throw "실행 파일을 찾지 못했습니다: $Name" }
    return $command.Source
}

function Invoke-Step([string]$Executable, [object[]]$Arguments, [string]$Label, [switch]$QuietOnSuccess) {
    Write-Host "실행: $Label"
    if ($QuietOnSuccess) {
        # Windows PowerShell 5.1에서는 리디렉션한 stderr도 오류 레코드로 표시된다.
        $ErrorActionPreference = 'Continue'
        $global:LASTEXITCODE = $null
        $output = & $Executable @Arguments 2>&1
        $exitCode = $LASTEXITCODE
        if ($null -eq $exitCode -or $exitCode -ne 0) {
            $output | ForEach-Object { [string]$_ } | Out-Host
            if ($null -eq $exitCode) { throw "$Label 실행을 시작하지 못했습니다." }
            throw "$Label 실패 (종료 코드 $exitCode)."
        }
        return
    }
    & $Executable @Arguments | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "$Label 실패 (종료 코드 $LASTEXITCODE)." }
}

function Invoke-NpmIfDefined([string]$Task) {
    $package = Get-Content -LiteralPath 'package.json' -Raw -Encoding UTF8 | ConvertFrom-Json
    $taskEntry = $package.scripts.PSObject.Properties[$Task]
    if (-not $taskEntry) { throw "package.json에 '$Task' 작업이 없습니다." }
    $node = Find-NodeRuntime
    $npm = Get-Command npm.cmd -CommandType Application -TotalCount 1 -ErrorAction SilentlyContinue
    if ($npm) {
        Invoke-Step $npm.Source @('run', $Task) "npm run $Task" -QuietOnSuccess
    } elseif ($taskEntry.Value -match '^node ([A-Za-z0-9_./-]+\.(?:cjs|mjs|js))$' -and
        -not $package.scripts.PSObject.Properties["pre$Task"] -and -not $package.scripts.PSObject.Properties["post$Task"]) {
        $taskFile = Get-ProjectFile $Matches[1]
        Invoke-Step $node @($taskFile) $Task -QuietOnSuccess
    } else {
        throw "'$Task' 실행에는 npm이 필요합니다."
    }
}

function Invoke-ProjectChecks {
    $checkCount = $SyncConfig.checkTasks.Count + $SyncConfig.checkCommands.Count
    if (-not $checkCount) {
        throw '배포 전 검사 설정이 필요합니다. sync.config.json의 checkTasks 또는 checkCommands를 지정하세요.'
    }
    Write-Host '  프로젝트 검사 명령을 실행합니다.'
    foreach ($task in $SyncConfig.checkTasks) { Invoke-NpmIfDefined $task }
    foreach ($step in $SyncConfig.checkCommands) {
        Invoke-Step (Get-Executable $step.command) $step.args $step.command -QuietOnSuccess
    }
    Write-Host "  프로젝트 검사 통과: $checkCount 단계"
}

function Write-WorkStep([int]$Number, [int]$Total, [string]$Message) {
    if ($Action -eq 'Menu') {
        Write-Host ''
        Write-Host "  $Number/$Total   $Message" -ForegroundColor Cyan
    }
}

function Assert-AllowedPaths([string[]]$Paths) {
    $blocked = @($Paths | Where-Object {
        $_ -match $DefaultPrivatePattern -or ($ExtraPrivateRegex -and $ExtraPrivateRegex.IsMatch($_))
    } | Sort-Object -Unique)
    if ($blocked.Count) {
        $blocked | Out-Host
        throw '개인 데이터 또는 인증 파일 경로가 포함되어 작업을 중단했습니다.'
    }
}

function Get-OutgoingPaths([string]$From, [string]$To) {
    $revisions = @(if ($From) { "${From}..${To}" } else { $To; '--not'; "--remotes=$Remote" })
    Get-NulPaths log --root -m --format= --name-only -z --no-renames --diff-filter=ACMT @revisions --
}

function Update-RemoteRefs {
    if (@(Invoke-Git remote) -cnotcontains $Remote) {
        throw "원격 '$Remote'가 등록되어 있지 않습니다. Git 원격을 등록하거나 sync.config.json의 remote를 바꾸세요."
    }
    $fetchUrls = @(Invoke-Git remote get-url --all $Remote)
    $pushUrls = @(Invoke-Git remote get-url --push --all $Remote)
    if ($fetchUrls.Count -ne 1 -or $pushUrls.Count -ne 1 -or $fetchUrls[0] -cne $pushUrls[0]) {
        throw '이 도구에서 사용할 원격은 가져오기와 보내기 URL이 같은 단일 저장소여야 합니다.'
    }
    Invoke-Git fetch @QuietGit --prune --no-tags --no-recurse-submodules --refmap= $Remote "+refs/heads/*:refs/remotes/$Remote/*" | Out-Host
}

function Publish-Ref([string]$Commit, [string]$Branch) {
    Invoke-Git -c push.followTags=false -c "remote.$Remote.mirror=false" push @QuietGit --recurse-submodules=no $Remote "${Commit}:refs/heads/$Branch" | Out-Host
}

function Confirm-Publish([string]$Target, [switch]$DirectDeploy) {
    if ($Yes) { return }
    if ($Action -ne 'Menu') { throw "배포 대상: $Target. 확인 후 -Yes를 붙여 실행하세요." }
    Write-Host ''
    Write-Host "  배포 대상: $Target" -ForegroundColor Yellow
    if ($DirectDeploy) { return }
    if ((Read-Host '배포 작업을 진행하려면 DEPLOY를 입력하세요 (취소: Enter)') -cne 'DEPLOY') {
        throw [OperationCanceledException]::new('배포 요청을 취소했습니다.')
    }
}

function Start-Project {
    Write-WorkStep 1 3 '작업 트리에 미커밋 변경이 있는지 확인'
    Assert-NoPendingOperation
    Assert-Clean -AllowNewConfig
    Write-WorkStep 2 3 '원격 커밋과 브랜치 정보 가져오기 (fetch)'
    Update-RemoteRefs
    Write-WorkStep 3 3 '작업 브랜치로 전환하고 필요하면 원격 커밋 반영'
    if (Test-Ref "refs/heads/$WorkBranch") {
        Invoke-Git switch @QuietGit --no-overwrite-ignore $WorkBranch | Out-Host
    } elseif (Test-Ref $WorkRef) {
        Invoke-Git switch @QuietGit --no-overwrite-ignore -c $WorkBranch --track $WorkRef | Out-Host
    } elseif (Test-Ref $ReleaseRef) {
        Invoke-Git switch @QuietGit --no-overwrite-ignore --no-track -c $WorkBranch $ReleaseRef | Out-Host
    } else {
        if (@(Invoke-Git for-each-ref --count=1 '--format=%(refname)' "refs/remotes/$Remote/").Count) {
            throw "원격에 $WorkBranch 또는 $ReleaseBranch 브랜치가 없습니다. 프로젝트의 브랜치 설정을 확인하세요."
        }
        if (-not (Test-Ref "refs/heads/$ReleaseBranch")) {
            throw "빈 원격에서 시작하려면 로컬 $ReleaseBranch 브랜치에 첫 커밋이 필요합니다."
        }
        Invoke-Git switch @QuietGit --no-overwrite-ignore --no-track -c $WorkBranch "refs/heads/$ReleaseBranch" | Out-Host
    }
    if (Test-Ref $WorkRef) {
        if ($Action -eq 'Menu') { Write-Host '  새 원격 커밋이 있으면 fast-forward 방식으로 반영합니다.' }
        Invoke-Git merge @QuietGit --ff-only --no-overwrite-ignore $WorkRef | Out-Host
    }
    if ($Action -ne 'Menu') { Show-Status }
}

function Merge-RemoteForBackup([string]$Base, [string]$SavedHead) {
    Write-Host '  로컬 작업 브랜치에 원격 작업 브랜치를 병합합니다.'
    try {
        Invoke-Git merge @QuietGit --no-ff --no-edit --no-autostash --no-overwrite-ignore $Base | Out-Host
    } catch {
        $mergeHead = Invoke-Git rev-parse --git-path MERGE_HEAD
        if (Test-Path -LiteralPath $mergeHead) {
            $conflicts = @(Get-NulPaths diff --name-only -z --diff-filter=U --)
            try {
                Invoke-Git merge --abort | Out-Host
            } catch {
                throw "병합을 자동으로 취소하지 못했습니다. 작업 변경은 로컬 커밋 $SavedHead 에 남아 있습니다."
            }
            if ($conflicts.Count) {
                Write-Host '  병합 충돌이 난 파일:'
                $conflicts | Out-Host
            }
        }
        throw "원격 작업 브랜치를 병합하지 못했습니다. 내 변경은 로컬 커밋 $SavedHead 에 남아 있습니다."
    }
}

function Backup-Project([switch]$DirectDeploy) {
    Write-WorkStep 1 4 '작업 브랜치 확인 및 원격 정보 가져오기 (fetch)'
    Assert-NoPendingOperation
    Assert-WorkBranch
    $head = Invoke-Git rev-parse --verify HEAD
    Update-RemoteRefs
    $base = $null
    $incoming = @()
    $combineAfterSaving = $false
    if (Test-Ref $WorkRef) {
        $base = Invoke-Git rev-parse $WorkRef
        if (-not (Test-Ancestor $base $head)) {
            if (-not (Test-Ancestor $head $base)) { throw '로컬과 원격 이력이 갈라졌습니다. 브랜치를 정리한 뒤 다시 실행하세요.' }
            if (@(Invoke-Git status --porcelain=v1 --untracked-files=all --ignore-submodules=none).Count) {
                $combineAfterSaving = $true
                $incoming = @(Get-NulPaths diff --name-only -z --no-renames $head $base --)
                Write-Host '  원격 브랜치에 새 커밋이 있습니다. 로컬에서 먼저 커밋한 뒤 병합합니다.'
            } else {
                if ($Action -eq 'Menu') { Write-Host '  로컬 작업 브랜치에 원격 커밋을 fast-forward 방식으로 반영합니다.' }
                Invoke-Git merge @QuietGit --ff-only --no-overwrite-ignore $base | Out-Host
                $head = $base
            }
        }
    }
    Write-WorkStep 2 4 '커밋할 파일과 보호 경로 확인'
    $outgoing = @(Get-OutgoingPaths $base $head)
    $tracked = @(Get-NulPaths diff HEAD --name-only -z --no-renames --diff-filter=ACMT --)
    $untracked = @(Get-NulPaths ls-files --others --exclude-standard -z --)
    Assert-AllowedPaths ($outgoing + $tracked + $untracked)

    Write-WorkStep 3 4 '변경 스테이징 및 로컬 커밋'
    Assert-NoPendingOperation
    Assert-WorkBranch
    if ((Invoke-Git rev-parse HEAD) -cne $head) { throw '백업 준비 중 커밋이 바뀌었습니다. 다시 실행하세요.' }
    Assert-AllowedPaths (@(Get-NulPaths diff HEAD --name-only -z --no-renames --diff-filter=ACMT --) +
        @(Get-NulPaths ls-files --others --exclude-standard -z --))
    if (@(Invoke-Git status --porcelain=v1 --untracked-files=all --ignore-submodules=none).Count) {
        Invoke-Git add -A -- .
        Assert-AllowedPaths @(Get-NulPaths diff --cached --name-only -z --no-renames --diff-filter=ACMT --)
        $staged = @(Get-NulPaths diff --cached --name-only -z --no-renames --)
        if ($staged.Count) {
            if ($Action -eq 'Menu') { Write-Host "  커밋에 포함할 경로: $($staged.Count)개" }
            else { Invoke-Git -c core.quotepath=false diff --cached --stat | Out-Host }
            Invoke-Git commit @QuietGit -m "작업 백업: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" | Out-Host
            if ($Action -eq 'Menu') { Write-Host "  로컬 커밋 생성: $(Invoke-Git rev-parse --short HEAD)" }
        }
    }
    Assert-Clean
    Assert-WorkBranch
    $savedHead = Invoke-Git rev-parse HEAD
    if ($Action -eq 'Menu' -and $savedHead -ceq $head) { Write-Host '  새로 커밋할 변경이 없습니다.' }
    if ($combineAfterSaving) {
        if ($savedHead -ceq $head) {
            Invoke-Git merge @QuietGit --ff-only --no-overwrite-ignore $base | Out-Host
        } else {
            Merge-RemoteForBackup $base $savedHead
            if ($incoming -contains 'sync.config.json') {
                throw '원격 프로젝트 설정을 로컬에 병합했습니다. 병합된 설정으로 진행하려면 [2] 또는 [3]을 다시 선택하세요.'
            }
            Assert-NoPendingOperation
            Assert-Clean
            Assert-WorkBranch
        }
    }
    $head = Invoke-Git rev-parse HEAD
    if ($base -and -not (Test-Ancestor $base $head)) { throw '로컬 작업 브랜치에 원격 커밋이 포함되어 있지 않아 푸시를 중단했습니다.' }
    if ($head -ceq $base) {
        Write-WorkStep 4 4 '원격 작업 브랜치로 푸시 (push)'
        Write-Host '  로컬과 원격 브랜치의 커밋이 같아 푸시를 건너뜁니다.'
        return
    }
    Assert-AllowedPaths @(Get-OutgoingPaths $base $head)
    if ($SyncConfig.deployment.mode -eq 'backup-push') {
        Write-Host '  이 푸시는 자동 배포를 시작하므로 배포 전 검사를 실행합니다.'
        try { Invoke-ProjectChecks } catch {
            throw "$($_.Exception.Message) 커밋은 로컬에 남아 있습니다."
        }
        Assert-NoPendingOperation
        Assert-Clean
        Assert-WorkBranch
        if ((Invoke-Git rev-parse HEAD) -cne $head) { throw '검사 중 커밋이 바뀌었습니다. 다시 실행하세요.' }
        Confirm-Publish "$Remote/$WorkBranch 백업 및 자동 배포" -DirectDeploy:$DirectDeploy
    }
    Write-WorkStep 4 4 '원격 작업 브랜치로 푸시 (push)'
    Publish-Ref $head $WorkBranch
    if ($Action -eq 'Menu') { Write-Host "  푸시 완료: $Remote/$WorkBranch" }
    else { Write-Host "백업 완료: $Remote/$WorkBranch @ $head" }
    if ($SyncConfig.deployment.mode -eq 'backup-push') { Write-Host '배포 결과는 GitHub Actions 또는 서비스에서 확인하세요.' }
}

function Get-GitHubRepository {
    $url = Invoke-Git remote get-url $Remote
    if ($url -match '^(?:https://github\.com/|git@github\.com:|ssh://git@github\.com/)([A-Za-z0-9_-]+)/([A-Za-z0-9_.-]+?)(?:\.git)?/?$') {
        return "github.com/$($Matches[1])/$($Matches[2])"
    }
    throw 'github-actions 모드에는 github.com Git 원격 주소가 필요합니다.'
}

function Deploy-Project {
    $deploy = $SyncConfig.deployment
    if (-not $deploy) { throw '이 프로젝트는 배포 미설정입니다. sync.config.json을 확인하세요.' }
    $directDeploy = $Action -eq 'Menu'
    if ($deploy.mode -eq 'backup-push') { Backup-Project -DirectDeploy:$directDeploy; return }
    Write-WorkStep 1 4 '로컬과 원격 작업 브랜치의 커밋 일치 여부 확인'
    Assert-NoPendingOperation
    Assert-WorkBranch
    Assert-Clean
    Update-RemoteRefs
    $head = Invoke-Git rev-parse HEAD
    if (-not (Test-Ref $WorkRef) -or $head -cne (Invoke-Git rev-parse $WorkRef)) {
        throw "배포하려면 로컬과 원격 작업 브랜치($Remote/$WorkBranch)의 커밋이 같아야 합니다. [1] 또는 [2]를 먼저 실행하세요."
    }

    switch ($deploy.mode) {
        'release-branch' {
            if (Test-Ref $ReleaseRef) {
                $release = Invoke-Git rev-parse $ReleaseRef
                if ($head -ceq $release) { Write-Host '원격 배포 브랜치가 이미 같은 커밋을 가리킵니다. 푸시를 건너뜁니다.'; return }
                if (-not (Test-Ancestor $release $head)) {
                    throw '원격 배포 브랜치에 fast-forward 푸시를 할 수 없습니다. Pull Request에서 병합하세요.'
                }
                Assert-AllowedPaths @(Get-OutgoingPaths $release $head)
                $target = "$Remote/$ReleaseBranch @ $head"
            } elseif ($deploy.createReleaseBranch -eq $true) {
                $target = "새 배포 브랜치 $Remote/$ReleaseBranch 생성 @ $head"
            } else {
                throw "원격 배포 브랜치가 없습니다: $Remote/$ReleaseBranch. 새 브랜치를 만들려면 deployment.createReleaseBranch를 true로 지정하세요."
            }
        }
        'github-actions' {
            $repo = Get-GitHubRepository
            $gh = Get-Executable 'gh'
            $null = Invoke-Git cat-file -e "${head}:.github/workflows/$($deploy.workflow)"
            $target = "$repo / $($deploy.workflow) / $WorkBranch"
        }
        'commands' {
            $executables = @($deploy.commands | ForEach-Object { Get-Executable $_.command })
            $target = "프로젝트 배포 명령 @ $head"
        }
        'legacy' {
            $deployFile = Get-ProjectFile $deploy.script
            if (-not (Test-Path -LiteralPath $deployFile -PathType Leaf)) { throw "기존 배포 스크립트 없음: $($deploy.script)" }
            $target = "$($deploy.script) @ $head"
        }
    }
    Write-WorkStep 2 4 '배포할 커밋에 대해 프로젝트 검사 실행'
    Invoke-ProjectChecks
    Assert-NoPendingOperation
    Assert-Clean
    Assert-WorkBranch
    if ((Invoke-Git rev-parse HEAD) -cne $head) { throw '검사 중 커밋이 바뀌었습니다.' }
    Write-WorkStep 3 4 '배포 대상 확인'
    Confirm-Publish $target -DirectDeploy:$directDeploy

    switch ($deploy.mode) {
        'release-branch' {
            Write-WorkStep 4 4 '원격 배포 브랜치로 푸시 (push)'
            Publish-Ref $head $ReleaseBranch
            Write-Host '  배포 브랜치 푸시 완료. 서비스의 배포 결과는 별도로 확인하세요.'
        }
        'github-actions' {
            Write-WorkStep 4 4 'GitHub Actions 워크플로 실행 요청'
            $parameters = @('workflow', 'run', $deploy.workflow, '--repo', $repo, '--ref', $WorkBranch)
            if ($deploy.commitInput) { $parameters += @('-f', "$($deploy.commitInput)=$head") }
            Invoke-Step $gh $parameters 'GitHub Actions 배포 요청'
            Write-Host '워크플로 실행을 요청했습니다. 완료 여부는 Actions에서 확인하세요.'
        }
        'commands' {
            Write-WorkStep 4 4 '설정된 배포 명령 실행'
            for ($index = 0; $index -lt $executables.Count; $index++) {
                $step = $deploy.commands[$index]
                Invoke-Step $executables[$index] $step.args $step.command
            }
            Write-Host '설정된 배포 명령이 모두 성공했습니다.'
        }
        'legacy' {
            Write-WorkStep 4 4 '기존 프로젝트 배포 스크립트 실행'
            # 기존 필드를 초기화하고 프로젝트가 자체 통계 항목을 추가할 수 있게 한다.
            $script:RunStats = @{
                ChecksPlanned = 0
                ChecksPassed = 0
                CheckNote = ''
                DeployRuns = 0
                RunId = ''
            }
            try {
                . $deployFile
                if (-not (Get-Command Invoke-WebAppDeployment -CommandType Function -ErrorAction SilentlyContinue)) {
                    throw '기존 배포 스크립트에 Invoke-WebAppDeployment 함수가 없습니다.'
                }
                Invoke-WebAppDeployment
            } finally {
                Remove-Variable -Name RunStats -Scope Script -ErrorAction SilentlyContinue
            }
        }
    }
}

function Show-Status {
    if ($Action -eq 'Menu') {
        $currentBranch = Invoke-Git branch --show-current
        $branchLabel = if ($currentBranch) { $currentBranch } else { '분리된 HEAD (브랜치가 선택되지 않음)' }
        Write-Host "  현재 로컬 브랜치: $branchLabel"
        $changes = @(Invoke-Git --no-optional-locks -c core.quotepath=false status --short --untracked-files=all)
        Write-Host "  미커밋 변경 및 미추적 항목: $($changes.Count)개"
        if ($changes.Count) {
            Write-Host ''
            Write-Host '  앞 두 칸: 보통 스테이징 상태 / 작업 트리 상태 순서'
            Write-Host '  주요 표시: M 수정 · A 추가 · D 삭제 · R 이름 변경'
            Write-Host '             U 미병합 · ?? 미추적'
            $changes | Out-Host
        }
        Write-Host ''
    } else {
        Invoke-Git --no-optional-locks -c core.quotepath=false status --short --branch | Out-Host
    }
    if (Test-Ref $WorkRef) {
        $counts = (Invoke-Git rev-list --left-right --count "HEAD...$WorkRef") -split '\s+'
        if ($Action -eq 'Menu') {
            Write-Host "  비교 대상: 마지막으로 가져온 원격 브랜치 $Remote/$WorkBranch"
            Write-Host "  현재 HEAD에만 있는 커밋: $($counts[0])개"
            Write-Host "  원격 브랜치에만 있는 커밋: $($counts[1])개"
        } else {
            Write-Host "현재 HEAD와 로컬에 기록된 $Remote/$WorkBranch 비교: 앞섬 $($counts[0]), 뒤처짐 $($counts[1])"
        }
    } elseif ($Action -eq 'Menu') {
        Write-Host "  비교할 원격 작업 브랜치 기록이 없습니다: $Remote/$WorkBranch"
    }
}

function Initialize-Config {
    if (Test-Path -LiteralPath $ConfigPath) { throw 'sync.config.json이 이미 있습니다.' }
    $defaults = Read-SyncConfig
    $sample = [ordered]@{
        workBranch = $defaults.workBranch; releaseBranch = $defaults.releaseBranch; remote = $defaults.remote
        checkTasks = @(); checkCommands = @(); deployment = $null
    } | ConvertTo-Json -Depth 5
    try {
        $stream = [IO.File]::Open($ConfigPath, [IO.FileMode]::CreateNew)
    } catch [IO.IOException] {
        if (Test-Path -LiteralPath $ConfigPath) { throw 'sync.config.json이 이미 있습니다.' }
        throw
    }
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($sample + [Environment]::NewLine)
        $stream.Write($bytes, 0, $bytes.Length)
    } finally { $stream.Dispose() }
    Write-Host "설정 생성: $ConfigPath"
}

function Invoke-Action([string]$SelectedAction) {
    if ($SelectedAction -eq 'Status') { Show-Status; return }
    if ($SelectedAction -eq 'Init') { Initialize-Config; return }
    $lockPath = Invoke-Git rev-parse --path-format=absolute --git-path universal-sync.lock
    try {
        $lock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    } catch [IO.IOException] {
        throw '작업 잠금 파일을 열 수 없습니다. 다른 동기화 창이나 Git 폴더 쓰기 권한을 확인하세요.'
    }
    try {
        switch ($SelectedAction) {
            'Start'  { Start-Project }
            'Backup' { Backup-Project }
            'Deploy' { Deploy-Project }
        }
    } finally { $lock.Dispose() }
}

function Update-ProjectConfig {
    $script:SyncConfig = Read-SyncConfig
    $script:WorkBranch = $SyncConfig.workBranch
    $script:ReleaseBranch = $SyncConfig.releaseBranch
    $script:Remote = $SyncConfig.remote
    $script:WorkRef = "refs/remotes/$Remote/$WorkBranch"
    $script:ReleaseRef = "refs/remotes/$Remote/$ReleaseBranch"
    $script:ExtraPrivateRegex = if ($SyncConfig.extraSensitivePattern) {
        [regex]::new($SyncConfig.extraSensitivePattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase, [TimeSpan]::FromSeconds(1))
    }
}

function Show-ConsolePage([string]$Title) {
    Write-Host ''
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host "  프로젝트: $(Split-Path -Leaf $ProjectRoot)"
}

function Show-ProjectMenu([bool]$HasConfig, [string]$ConfigError, [string]$LastResult) {
    Show-ConsolePage 'GitHub 작업 도구'
    Write-Host "  $ReleaseLabel" -ForegroundColor Gray
    if (-not $ConfigError) { Write-Host "  원격 작업 브랜치: $Remote/$WorkBranch" }
    Write-Host ''
    Write-Host '  [1] 작업 시작       작업 브랜치 전환 및 원격 커밋 반영'
    Write-Host '  [2] 종료 백업       로컬 커밋 및 원격 브랜치 푸시'
    Write-Host ''
    $deployHint = if ($SyncConfig.deployment.mode -eq 'backup-push') {
        '작업 브랜치 푸시로 자동 배포 시작'
    } elseif ($SyncConfig.deployment) {
        '설정된 방식으로 배포 실행'
    } else {
        '사용하려면 배포 설정 필요'
    }
    Write-Host "  [3] 프로젝트 배포  $deployHint"
    Write-Host '  [4] 상태 확인       미커밋 변경 및 로컬·원격 커밋 비교'
    Write-Host ''
    Write-Host '  [0] 처음 설정 / 사용법       [5] 닫기'
    Write-Host ''
    Write-Host '  평소 순서: [1] → AI와 작업 → AI에게 "종료" → [2]'
    if ($SyncConfig.deployment.mode -eq 'backup-push') {
        Write-Host '  이 프로젝트는 [2]에서 푸시하면 자동 배포가 시작되도록 설정되어 있습니다.' -ForegroundColor Yellow
    }
    if ($ConfigError) {
        Write-Host '  설정 확인 필요: [0]에서 안내를 확인하세요.' -ForegroundColor Yellow
    } elseif (-not $HasConfig) {
        Write-Host '  처음이라면 [0]부터 누르세요.' -ForegroundColor Yellow
    }
    if ($LastResult) { Write-Host "  직전 결과: $LastResult" -ForegroundColor Cyan }
    Write-Host ''
}

function Show-ProjectHelp([bool]$HasConfig, [string]$ConfigError) {
    Write-Host ''
    Write-Host '  처음 한 번: 두 실행 파일을 프로젝트 폴더에 두고 설정을 만듭니다.'
    Write-Host "  설정 파일 위치: $ConfigPath"
    if ($SyncConfig.dataNotice) { Write-Host "  $($SyncConfig.dataNotice)" }
    Write-Host ''
    Write-Host '  작업 전: [1]을 누른 뒤 AI에게 "시작"이라고 말합니다.'
    Write-Host '  작업 후: AI에게 "종료"라고 말하고 정리가 끝나면 [2]를 누릅니다.'
    Write-Host ''
    Write-Host '  사이트에 반영할 때: 배포 방식을 설정한 뒤 [3]을 누릅니다.'
    Write-Host '  배포 설정이 필요하면 서비스 이름과 설정 파일 위치를 AI에게 알려 주세요.'
    Write-Host ''
    Write-Host '  Git 용어'
    Write-Host '  fetch      원격의 커밋과 브랜치 정보를 가져옵니다.'
    Write-Host '  스테이징   다음 커밋에 포함할 변경을 지정합니다.'
    Write-Host '  커밋       스테이징한 변경을 로컬 Git 이력에 기록합니다.'
    Write-Host '  푸시       로컬 커밋을 원격 저장소에 보내고 원격 브랜치를 갱신합니다.'
    Write-Host '  병합       다른 브랜치의 커밋을 현재 브랜치에 통합합니다.'
    Write-Host ''
    if ($ConfigError) { Write-Host "설정을 먼저 확인해 주세요: $ConfigError" -ForegroundColor Yellow; return }
    if ($HasConfig) { Write-Host '이 프로젝트에는 이미 설정 파일이 있습니다.'; return }
    $answer = [string](Read-Host '지금 설정 파일을 만들까요? 만들려면 Y, 돌아가려면 Enter')
    if ($answer.Trim() -notin @('y','yes','예')) { return }
    Initialize-Config
    Write-Host '처음 설정을 마쳤습니다. 메뉴로 돌아가 [1] 작업 시작을 누르세요.' -ForegroundColor Green
}

if ($Action -eq 'Version') {
    Write-Output "GitHub 작업 도구 $ReleaseLabel"
    return
}

$locationPushed = $false
try {
    $GitExe = Find-Git
    if (-not $ProjectPath) {
        $ProjectPath = (Get-Location).Path
        if ($Action -eq 'Menu') {
            & $GitExe -C $ProjectPath rev-parse --show-toplevel 2>$null | Out-Null
            if ($LASTEXITCODE -ne 0) { $ProjectPath = ([string](Read-Host '프로젝트 폴더 경로를 붙여 넣고 Enter를 누르세요')).Trim().Trim('"') }
        }
    }
    if (-not (Test-Path -LiteralPath $ProjectPath -PathType Container)) { throw 'Git 프로젝트 폴더 경로를 지정하세요.' }
    $ProjectRoot = Resolve-Path -LiteralPath (Invoke-Git -C $ProjectPath rev-parse --show-toplevel) | Select-Object -ExpandProperty ProviderPath
    Push-Location -LiteralPath $ProjectRoot
    $locationPushed = $true
    $ConfigPath = Join-Path $ProjectRoot 'sync.config.json'
    if ($Action -eq 'Init') { Invoke-Action Init; return }
    if ($Action -ne 'Menu') { Update-ProjectConfig; Invoke-Action $Action; return }

    $lastResult = ''
    $menuActions = @{ '1' = 'Start'; '2' = 'Backup'; '3' = 'Deploy'; '4' = 'Status' }
    $menuLabels = @{
        '0' = '처음 설정 / 사용법'; '1' = '작업 시작'; '2' = '종료 백업'
        '3' = '프로젝트 배포'; '4' = '상태 확인'
    }
    while ($true) {
        $hasConfig = Test-Path -LiteralPath $ConfigPath
        $configError = ''
        try { Update-ProjectConfig } catch { $SyncConfig = $null; $configError = $_.Exception.Message }
        Show-ProjectMenu $hasConfig $configError $lastResult
        do {
            $inputChoice = Read-Host '원하는 번호를 입력하고 Enter를 누르세요'
            $choice = ([string]$inputChoice).Trim()
            if ($null -ne $inputChoice -and $choice -notmatch '^[0-5]$') {
                Write-Host '  0~5 중 하나를 입력하세요.' -ForegroundColor Yellow
            }
        } while ($null -ne $inputChoice -and $choice -notmatch '^[0-5]$')
        if ($null -eq $inputChoice -or $choice -eq '5') { break }
        $selected = $menuActions[$choice]
        $label = $menuLabels[$choice]
        Show-ConsolePage "[$choice] $label"
        try {
            if ($choice -eq '0') {
                Show-ProjectHelp $hasConfig $configError
                if (-not $hasConfig -and (Test-Path -LiteralPath $ConfigPath)) { $lastResult = '처음 설정 완료. 다음은 [1] 작업 시작입니다.' }
            } elseif ($configError) {
                throw '프로젝트 설정을 읽지 못했습니다. [0]에서 설정 파일 위치와 안내를 확인하세요.'
            } elseif ($selected -eq 'Deploy' -and -not $SyncConfig.deployment) {
                Write-Host ''
                Write-Host '  이 프로젝트에는 배포 방식이 아직 설정되지 않았습니다.' -ForegroundColor Yellow
                Write-Host '  다음: GitHub 백업은 [2], 배포 설정 안내는 [0]을 누르세요.'
                $lastResult = '배포 설정 필요'
            } else {
                Invoke-Action $selected
                $lastResult = if ($selected -eq 'Deploy') { '배포 단계 종료' } else { "$label 완료" }
                $nextStep = switch ($selected) {
                    'Start' { 'AI에게 "시작"이라고 말하고 작업을 시작하세요.' }
                    'Backup' {
                        if ($SyncConfig.deployment.mode -eq 'backup-push') {
                            '자동 배포 결과는 서비스 화면이나 GitHub Actions에서 확인하세요.'
                        } elseif ($SyncConfig.deployment) {
                            '서비스에도 반영하려면 [3]을 누르세요.'
                        } else {
                            '다음 작업을 시작할 때 [1]을 누르세요.'
                        }
                    }
                    'Deploy' { '위에 표시된 결과를 확인하세요.' }
                }
                Write-Host ''
                Write-Host "  결과: $lastResult" -ForegroundColor Green
                if ($nextStep) { Write-Host "  다음: $nextStep" }
            }
        } catch [OperationCanceledException] {
            $lastResult = '배포 취소'
            Write-Host '  확인 단계에서 배포를 취소했습니다.' -ForegroundColor Yellow
        } catch {
            $lastResult = "$label 중단"
            Write-Host ''
            Write-Host "  중단된 이유: $($_.Exception.Message)" -ForegroundColor Red
            Write-Host '  다음: 도움이 필요하면 이 화면을 AI에게 보여 주세요.'
        }
        Write-Host ''
        $null = Read-Host 'Enter를 누르면 메뉴로 돌아갑니다'
    }
} catch {
    Write-Host "중단: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
} finally {
    if ($locationPushed) { Pop-Location }
}
