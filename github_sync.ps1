[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
$ToolVersion = '2.0.3'
$ToolUpdated = '2026-11-08'
$DocPattern = '\.(md|txt)$'
$RiskyPattern = '(^|/)(\.private|\.git)/|(^|/)\.clasprc\.json$|(^|/)\.env($|\.)|\.(pem|key)$|(^|/)([^/]*(credential|oauth|secret|token)[^/]*\.(json|env)|회원설정\.json|배포정보\.json|독서기록[^/]*\.json|[^/]*전체백업[^/]*\.json)$'

function Get-ProjectFile {
    param([string]$RelativePath)
    if ([IO.Path]::IsPathRooted($RelativePath)) { throw '프로젝트 내부 상대 경로만 사용하세요.' }
    $rootPath = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') + '\'
    $fullPath = [IO.Path]::GetFullPath((Join-Path $rootPath $RelativePath))
    if (-not $fullPath.StartsWith($rootPath, [StringComparison]::OrdinalIgnoreCase)) { throw '프로젝트 밖 경로는 사용할 수 없습니다.' }
    return $fullPath
}

function Read-SyncConfig {
    $config = [pscustomobject]@{
        workBranch='dev'; releaseBranch='main'; remote='origin'; minNodeVersion=22
        checkTasks=@(); checkCommands=@(); deployment=$null
        dataNotice='개인 데이터: 프로젝트별 저장 위치 확인'; extraSensitivePattern=''
    }
    $path = Join-Path $PSScriptRoot 'sync.config.json'
    if (Test-Path -LiteralPath $path) {
        $custom = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($property in $custom.PSObject.Properties) {
            if (-not $config.PSObject.Properties[$property.Name]) { throw "알 수 없는 설정: $($property.Name)" }
            $config.($property.Name) = $property.Value
        }
    }
    foreach ($name in @('workBranch','releaseBranch','remote')) {
        $value = [string]$config.$name
        if ($value -notmatch '^[A-Za-z0-9][A-Za-z0-9._/-]*$' -or $value -match '\.\.|//|\.lock($|/)|[./]$') { throw "브랜치/원격 설정 오류: $name" }
    }
    if ($config.remote -match '/') { throw 'remote는 origin 같은 별칭이어야 합니다.' }
    if ($config.workBranch -eq $config.releaseBranch) { throw '작업/배포 브랜치는 달라야 합니다.' }
    if ($config.minNodeVersion -notmatch '^\d+$' -or [int]$config.minNodeVersion -lt 16) { throw 'Node 최소 버전 설정 오류' }
    if ($null -ne $config.deployment) {
        if (-not $config.deployment.script -or -not $config.deployment.workflow -or $config.deployment.workflow -notmatch '^[A-Za-z0-9_.-]+\.ya?ml$') { throw '배포 script/workflow 설정 오류' }
        $null = Get-ProjectFile ([string]$config.deployment.script)
    }
    if ($config.extraSensitivePattern) { $null = [regex]::new([string]$config.extraSensitivePattern) }
    return $config
}

function Invoke-ProjectChecks {
    $count = 0
    $script:RunStats.ChecksPlanned = @($SyncConfig.checkTasks).Count + @($SyncConfig.checkCommands).Count
    $script:RunStats.CheckNote = '실행 중'
    foreach ($task in @($SyncConfig.checkTasks)) {
        if (-not $task) { throw '빈 검사 작업 설정' }
        Invoke-NpmIfDefined ([string]$task)
        $count++
        $script:RunStats.ChecksPassed++
    }
    foreach ($step in @($SyncConfig.checkCommands)) {
        if (-not $step.command) { throw '검사 실행 파일 설정 누락' }
        if ($step.command -in @('node','node.exe')) { $executable = Find-NodeRuntime }
        else {
            $command = Get-Command ([string]$step.command) -CommandType Application -ErrorAction SilentlyContinue
            if (-not $command) { throw "검사 실행 파일 없음: $($step.command)" }
            $executable = $command.Source
        }
        $commandArgs = @($step.args)
        & $executable @commandArgs
        if ($LASTEXITCODE -ne 0) { throw '프로젝트 검사 실패. 업로드를 중단합니다.' }
        $count++
        $script:RunStats.ChecksPassed++
    }
    $script:RunStats.CheckNote = if ($count) { '완료' } else { '설정 없음' }
    if (-not $count) { Write-Host '검사 설정 없음 / Git 백업만 진행' }
}

function Invoke-Git {
    & git --no-pager @args
    if ($LASTEXITCODE -ne 0) {
        throw "Git 명령 실패: git $($args -join ' ')"
    }
}

function Test-Ref {
    param([string]$Ref)
    & git --no-pager show-ref --verify --quiet $Ref
    return ($LASTEXITCODE -eq 0)
}

function Assert-NoPendingOperation {
    foreach ($name in @(
        "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD",
        "rebase-merge", "rebase-apply"
    )) {
        $path = & git --no-pager rev-parse --git-path $name
        if ($LASTEXITCODE -ne 0) {
            throw "Git 상태를 확인하지 못했습니다."
        }
        if (Test-Path -LiteralPath $path) {
            throw "진행 중인 병합 또는 rebase가 있습니다. 먼저 해결해 주세요."
        }
    }
}

function Get-Branch {
    $branch = & git --no-pager symbolic-ref --quiet --short HEAD
    if ($LASTEXITCODE -ne 0) {
        throw "일반 브랜치가 아닙니다. 브랜치 상태를 먼저 확인해 주세요."
    }
    return $branch
}

function Assert-Clean {
    $status = & git --no-pager -c core.quotepath=false status --porcelain
    if ($LASTEXITCODE -ne 0) {
        throw "작업 폴더 상태 확인 실패."
    }
    if ($status) {
        $status | Out-Host
        throw "미커밋 변경이 있습니다. 기존 작업을 먼저 정리해 주세요."
    }
}

function Find-NodeRuntime {
    $candidates = @()
    $command = Get-Command node.exe -ErrorAction SilentlyContinue
    if ($command) { $candidates += $command.Source }
    $candidates += (Join-Path $env:USERPROFILE '.cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe')
    if ($env:ProgramFiles) { $candidates += (Join-Path $env:ProgramFiles 'nodejs\node.exe') }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $version = & $candidate --version
            if ($LASTEXITCODE -eq 0 -and $version -match '^v(\d+)\.' -and [int]$Matches[1] -ge [int]$SyncConfig.minNodeVersion) {
                $env:PATH = (Split-Path -Parent $candidate) + [IO.Path]::PathSeparator + $env:PATH
                return $candidate
            }
        }
    }
    throw "Node.js $($SyncConfig.minNodeVersion) 이상을 찾지 못했습니다. Node.js 설치 후 다시 실행해 주세요."
}

# package.json에 해당 스크립트가 있을 때만 실행 (없으면 건너뜀)
function Invoke-NpmIfDefined {
    param([string]$Task)
    if (-not (Test-Path -LiteralPath "package.json")) {
        throw "검사 $Task 설정이 있으나 package.json이 없습니다."
    }
    $pkg = Get-Content -LiteralPath "package.json" -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $pkg.scripts -or -not $pkg.scripts.PSObject.Properties[$Task]) {
        throw "설정된 npm 검사 작업이 없습니다: $Task"
    }
    # Codex Node.js에는 npm이 없을 수 있으므로 지원하는 검사는 직접 실행한다.
    $taskCommand = [string]$pkg.scripts.PSObject.Properties[$Task].Value
    if ($taskCommand -match '^node ([A-Za-z0-9_./-]+\.(?:cjs|mjs|js))$') {
        $taskFile = Get-ProjectFile $Matches[1]
        $nodePath = Find-NodeRuntime
        & $nodePath $taskFile
    }
    else {
        if (-not (Get-Command npm.cmd -ErrorAction SilentlyContinue)) {
            throw "이 검사에는 npm이 필요합니다. Node.js 정식 설치 후 다시 실행해 주세요."
        }
        & npm.cmd run $Task
    }
    if ($LASTEXITCODE -ne 0) {
        throw "$Task 검사 실패. 업로드하지 않았습니다."
    }
}

$lastResult = ''
while ($true) {
$failed = $false
$lastErrorMessage = ''
$choice = ''
$backupCommitted = $false
$backupPushed = $false
$startedAt = Get-Date
$script:RunStats = [ordered]@{ Files=$null; Added=$null; Deleted=$null; Binary=0; Commits=0; UploadPlanned=$null; Uploaded=$null; ChecksPlanned=0; ChecksPassed=0; CheckNote='미실행'; Hash=''; DownloadCommits=$null; DeployRuns=0; RunId='' }
# Keep previous output in the terminal scrollback.
try {
    Set-Location -LiteralPath $PSScriptRoot

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw "Git for Windows를 먼저 설치해 주세요."
    }

    $root = & git --no-pager rev-parse --show-toplevel
    if ($LASTEXITCODE -ne 0) {
        throw "Git 저장소 폴더가 아닙니다."
    }
    if ((Resolve-Path -LiteralPath $root).Path -ne
        (Resolve-Path -LiteralPath $PSScriptRoot).Path) {
        throw "이 스크립트는 저장소 최상위 폴더에 두어야 합니다."
    }

    $SyncConfig = Read-SyncConfig
    $WorkBranch = [string]$SyncConfig.workBranch
    $ReleaseBranch = [string]$SyncConfig.releaseBranch
    $Remote = [string]$SyncConfig.remote
    $repoName = Split-Path -Leaf $PSScriptRoot
    Write-Host ""
    Write-Host "GitHub 작업 도구 [v$ToolVersion | 최종 수정 $ToolUpdated]"
    Write-Host ""
    if ($SyncConfig.deployment) { Write-Host "프로젝트  $repoName / 작업 $WorkBranch / 배포 $ReleaseBranch" } else { Write-Host "프로젝트  $repoName / 작업 $WorkBranch / GitHub Pages 자동 배포" }
    Write-Host ""
    Write-Host "  [1] 작업 시작"
    Write-Host "  [2] 종료 백업"
    if ($SyncConfig.deployment) { Write-Host "  [3] 프로젝트 배포" } else { Write-Host "  [3] GitHub Pages 배포 (백업 후 자동 배포)" }
    Write-Host "  [4] 상태 확인"
    Write-Host "  [5] 닫기"
    Write-Host ""
    Write-Host "──────────────────────────────────────────────────"
    Write-Host "기능"
    Write-Host "  1  최신 프로그램 가져오기  | 작업 전"
    Write-Host "  2  검사·GitHub 백업        | AI 종료 정리 후"
    if ($SyncConfig.deployment) { Write-Host "  3  실제 서비스에 반영      | 2번 완료 후, 필요 시" } else { Write-Host "  3  GitHub Pages에 반영    | 변경사항 백업 후 자동 배포" }
    Write-Host "  4  변경·업로드 상태 조회   | 변경 없음"
    Write-Host ""
    if ($SyncConfig.deployment) { Write-Host "순서  1 → AI 작업 → AI에게 '종료' → 2 → 필요 시 3" } else { Write-Host "순서  1 → AI 작업 → AI에게 '종료' → 2 또는 3" }
    Write-Host "저장  프로그램: GitHub / $($SyncConfig.dataNotice)"
    Write-Host "주의  가져오기·백업·배포: 인터넷 필요 / 진행 중 창 유지"
    Write-Host "오류  실행 중단 → 오류 화면을 AI에게 전달"
    Write-Host "──────────────────────────────────────────────────"
    Write-Host ""
    if ($lastResult) { Write-Host "직전 결과  $lastResult" -ForegroundColor Cyan; Write-Host "" }
    $choice = (Read-Host "실행할 번호 (1~5)").Trim()
    $startedAt = Get-Date

    if ($choice -eq '3' -and -not $SyncConfig.deployment) {
        Write-Host "GitHub Pages는 dev 백업 시 자동 배포됩니다. 백업을 실행합니다." -ForegroundColor Cyan
        Write-Host "배포 완료 여부는 GitHub Actions 또는 웹사이트에서 확인해 주세요."
        $choice = '2'
    }

    switch ($choice) {
        "1" {
            Assert-NoPendingOperation
            Assert-Clean
            Invoke-Git fetch $Remote

            if (Test-Ref "refs/heads/$WorkBranch") {
                Invoke-Git switch $WorkBranch
            }
            elseif (Test-Ref "refs/remotes/$Remote/$WorkBranch") {
                Invoke-Git switch -c $WorkBranch --track "$Remote/$WorkBranch"
            }
            elseif (Test-Ref "refs/remotes/$Remote/$ReleaseBranch") {
                Invoke-Git switch --no-track -c $WorkBranch "$Remote/$ReleaseBranch"
            }
            else {
                throw "원격 $WorkBranch / $ReleaseBranch 브랜치를 찾지 못했습니다."
            }

            if ((Get-Branch) -ne $WorkBranch) {
                throw "$WorkBranch 전환 실패."
            }

            if (Test-Ref "refs/remotes/$Remote/$WorkBranch") {
                $script:RunStats.DownloadCommits = [int](Invoke-Git rev-list --count "HEAD..${Remote}/${WorkBranch}")
                Invoke-Git pull --rebase $Remote $WorkBranch
                Write-Host "최신 $WorkBranch 반영 완료."
            }
            else {
                Write-Host "원격 $WorkBranch 없음 / $Remote/$ReleaseBranch 기준으로 준비 완료."
            }

            $script:RunStats.Hash = Invoke-Git rev-parse --short HEAD
            Invoke-Git status --short --branch
            Write-Host "이제 AI에게 '시작'이라고 말해 주세요."
        }

        "2" {
            Write-Host "[1/4] 백업 시작 / 작업 상태·원격 연결 확인" -ForegroundColor Cyan
            Assert-NoPendingOperation

            if ((Get-Branch) -ne $WorkBranch) {
                throw "현재 $WorkBranch 브랜치가 아닙니다. 기존 변경을 보존하고 AI에 브랜치 정리를 요청해 주세요."
            }

            Invoke-Git fetch $Remote

            $status = & git --no-pager -c core.quotepath=false status --porcelain
            if ($LASTEXITCODE -ne 0) {
                throw "변경 확인 실패."
            }

            if ($status) {
                Write-Host "[2/4] 변경 파일 검사"
                $tracked = & git --no-pager -c core.quotepath=false diff HEAD --name-only
                if ($LASTEXITCODE -ne 0) {
                    throw "추적 파일 확인 실패."
                }
                $untracked = & git --no-pager -c core.quotepath=false ls-files --others --exclude-standard
                if ($LASTEXITCODE -ne 0) {
                    throw "새 파일 확인 실패."
                }

                $codeFiles = @($tracked) + @($untracked) |
                    Where-Object { $_ -and ($_ -notmatch $DocPattern) }

                if ($codeFiles) {
                    Invoke-ProjectChecks
                }
                else {
                    $script:RunStats.CheckNote = '문서 변경만 있어 생략'
                    Write-Host "문서만 변경됨 - 빌드/테스트 생략"
                }

                Invoke-Git -c core.quotepath=false status --short
                Write-Host ""
                Write-Host "검사를 통과했습니다. 변경 사항을 $WorkBranch 에 자동 백업합니다."

                Invoke-Git add -A

                $staged = @(Invoke-Git -c core.quotepath=false diff --cached --name-only | Where-Object { $_ })
                $risky = @($staged) | Where-Object { $_ -match $RiskyPattern -or ($SyncConfig.extraSensitivePattern -and $_ -match $SyncConfig.extraSensitivePattern) }
                if ($risky) {
                    & git --no-pager reset --quiet
                    $risky | Out-Host
                    throw "개인정보·인증값 의심 파일이 있습니다. 백업을 중단했습니다. (staging만 취소, 파일은 그대로)"
                }

                $script:RunStats.Files = $staged.Count
                $script:RunStats.Added = 0
                $script:RunStats.Deleted = 0
                foreach ($line in @(Invoke-Git diff --cached --numstat)) {
                    $parts = ([string]$line) -split "`t", 3
                    if ($parts.Count -ge 3) {
                        if ($parts[0] -eq '-' -or $parts[1] -eq '-') { $script:RunStats.Binary++ }
                        else { $script:RunStats.Added += [long]$parts[0]; $script:RunStats.Deleted += [long]$parts[1] }
                    }
                }
                & git --no-pager diff --cached --quiet
                $diffCode = $LASTEXITCODE

                if ($diffCode -eq 1) {
                    $timeStr = Get-Date -Format "yyyy-MM-dd HH:mm"
                    Write-Host "[3/4] 변경 사항 커밋"
                    Invoke-Git commit -m "작업 백업 [$env:COMPUTERNAME]: $timeStr"
                    $backupCommitted = $true
                    $script:RunStats.Commits = 1
                }
                elseif ($diffCode -ne 0) {
                    throw "커밋 대상 확인 실패."
                }
            }

            if (Test-Ref "refs/remotes/$Remote/$WorkBranch") {
                Invoke-Git pull --rebase $Remote $WorkBranch
            }

            Assert-NoPendingOperation
            Assert-Clean

            if ((Get-Branch) -ne $WorkBranch) {
                throw "브랜치가 변경되어 업로드를 중단합니다."
            }

            if (-not $status) {
                $script:RunStats.Files = 0; $script:RunStats.Added = 0; $script:RunStats.Deleted = 0
                $script:RunStats.CheckNote = '새 파일 변경 없음'
                Write-Host "[2/4] 새 파일 변경 없음 / 기존 커밋 업로드 확인"
            }
            $pendingRange = if (Test-Ref "refs/remotes/$Remote/$WorkBranch") { "${Remote}/${WorkBranch}..HEAD" } else { 'HEAD' }
            $script:RunStats.UploadPlanned = [int](Invoke-Git rev-list --count $pendingRange)
            Write-Host "[4/4] GitHub 업로드 / 완료 확인 대기"
            Invoke-Git push -u $Remote $WorkBranch
            $backupPushed = $true
            $script:RunStats.Uploaded = $script:RunStats.UploadPlanned
            $script:RunStats.Hash = Invoke-Git rev-parse --short HEAD
            Invoke-Git status --short --branch
            Invoke-Git log -1 --oneline

            if ($SyncConfig.deployment) { Write-Host "GitHub 백업 완료. 실제 웹앱은 그대로입니다. 반영하려면 [3]을 선택하세요." } else { Write-Host "GitHub 백업 완료. GitHub Pages 배포 상태는 Actions 또는 웹사이트에서 확인하세요." }
        }

        "3" {
            if (-not $SyncConfig.deployment) { throw '배포 미설정 / sync.config.json에서 프로젝트 배포 방법을 지정하세요.' }
            $deployFile = Get-ProjectFile ([string]$SyncConfig.deployment.script)
            if (-not (Test-Path -LiteralPath $deployFile -PathType Leaf)) { throw '프로젝트 배포 스크립트가 없습니다.' }
            . $deployFile
            Write-Host "실제 웹앱 반영을 시작합니다. 검사·배포에 몇 분 걸릴 수 있습니다."
            Invoke-WebAppDeployment
        }

        "4" {
            $script:RunStats.Files = @(Invoke-Git -c core.quotepath=false status --porcelain | Where-Object { $_ }).Count
            Invoke-Git -c core.quotepath=false status --short --branch
            Write-Host "파일 앞 M=수정, A=추가, D=삭제, ??=새 파일입니다. 파일 목록이 없으면 로컬 변경은 없습니다."
            Write-Host "${WorkBranch}...${Remote}/${WorkBranch} 뒤 ahead=업로드할 커밋, behind=가져올 커밋입니다. [2] 완료로 백업을 확인하세요."
        }
        "5" {
            return
        }
        default {
            throw '1~5 중에서 선택하세요.'
        }
    }
}
catch {
    if ($script:RunStats.CheckNote -eq '실행 중') { $script:RunStats.CheckNote = '중단' }
    $lastErrorMessage = $_.Exception.Message
    $failed = $true
    Write-Host ""
    Write-Host "중단: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "기존 파일과 커밋은 삭제하지 않았습니다."
    Write-Host "충돌이 표시되면 이 화면을 AI에게 알려 주세요."
}

Write-Host ""
Write-Host "──────────────────────────────────────────────────"
$elapsed = [int]((Get-Date) - $startedAt).TotalSeconds
if ($failed) {
    if (-not $lastErrorMessage) { $lastResult = "작업 $choice 중단 / 위 오류 확인" } else { $lastResult = "작업 $choice 중단 / $lastErrorMessage" }
    Write-Host "결과  중단 / 완료되지 않음" -ForegroundColor Red
    Write-Host "안내  위 오류 확인 / 진행된 커밋·업로드·배포는 별도 확인 필요"
}
else {
    $summary = switch ($choice) {
        '1' { '작업 준비 완료 / 최신 원격 내용 확인' }
        '2' { if (-not $backupPushed) { throw '백업 완료 상태를 확인하지 못했습니다.' }; if ($backupCommitted) { '새 커밋 생성·GitHub 업로드 완료' } else { '새 커밋 없음·기존 이력 GitHub 업로드 확인 완료' } }
        '3' { '프로젝트 배포 작업 성공 / 서비스 확인' }
        '4' { '상태 조회 완료 / 파일 변경 없음' }
    }
    $lastResult = $summary
    Write-Host ("결과  " + $summary) -ForegroundColor Green
}
if ($choice -eq '2') {
    if ($null -ne $script:RunStats.Files) { Write-Host ("파일  " + $script:RunStats.Files + "개 / 추가 " + $script:RunStats.Added + "줄 / 삭제 " + $script:RunStats.Deleted + "줄 / 바이너리 " + $script:RunStats.Binary + "개") }
    else { Write-Host '파일  집계 전 중단' }
    Write-Host ("검사  " + $script:RunStats.ChecksPassed + "/" + $script:RunStats.ChecksPlanned + "개 작업 통과 / " + $script:RunStats.CheckNote)
    $uploadedLabel = if ($null -eq $script:RunStats.Uploaded) { '미완료·미확인' } else { [string]$script:RunStats.Uploaded + '개' }
    Write-Host ("커밋  새로 생성 " + $script:RunStats.Commits + "개 / 업로드 " + $uploadedLabel)
}
if ($choice -eq '1' -and $null -ne $script:RunStats.DownloadCommits) { Write-Host ("수신  원격 추가 커밋 " + $script:RunStats.DownloadCommits + "개") }
if ($choice -eq '4' -and $null -ne $script:RunStats.Files) { Write-Host ("파일  미백업 변경 " + $script:RunStats.Files + "개") }
if ($choice -eq '3') { Write-Host ("배포  성공 확인 " + $script:RunStats.DeployRuns + "건 / 검사 " + $script:RunStats.ChecksPassed + "/" + $script:RunStats.ChecksPlanned + "개 작업"); if ($script:RunStats.RunId) { Write-Host ("실행  " + $script:RunStats.RunId) } }
if ($script:RunStats.Hash) { Write-Host ("버전  " + $script:RunStats.Hash) }
Write-Host ("시간  " + $elapsed + "초")
Write-Host "──────────────────────────────────────────────────"
$null = Read-Host "엔터 → 아래에 메뉴 표시"
}
