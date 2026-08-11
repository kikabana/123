# XPrompt — обновлятор и запускатор.
# Следит за репозиторием, сам качает новые версии программы и расширения,
# перезапускает сервер. Папка data никогда не трогается.

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$Owner = 'kikabana'
$Repo = '123'
$Branch = 'main'
$CheckSeconds = 90

$Base = Split-Path -Parent $MyInvocation.MyCommand.Path
$Data = Join-Path $Base 'data'
$App = Join-Path $Base 'app'
$Tmp = Join-Path $Base '_tmp'

foreach ($d in @($Data, $App)) {
	if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

$ShaFile = Join-Path $Data 'installed.sha'
$BuildFile = Join-Path $Data 'build.txt'
$TokenFile = Join-Path $Data 'token.txt'

$Token = ''
if (Test-Path $TokenFile) { $Token = ((Get-Content $TokenFile -Raw) -replace '\s', '') }

function Line([string]$text, [string]$color) {
	if ($color) { Write-Host $text -ForegroundColor $color } else { Write-Host $text }
}

function GhHeaders() {
	$h = @{ 'User-Agent' = 'XPrompt-Updater'; 'Accept' = 'application/vnd.github+json' }
	if ($Token -ne '') { $h['Authorization'] = 'Bearer ' + $Token }
	return $h
}

function LatestSha() {
	$u = "https://api.github.com/repos/$Owner/$Repo/commits/$Branch"
	$r = Invoke-RestMethod -Uri $u -Headers (GhHeaders) -TimeoutSec 30
	return [string]$r.sha
}

function CurrentBuild() {
	if (Test-Path $BuildFile) {
		try { return [int]((Get-Content $BuildFile -Raw).Trim()) } catch { return 0 }
	}
	return 0
}

# Качает репозиторий целиком и раскладывает по местам.
# Возвращает $true, если обновился сам обновлятор и нужен перезапуск.
function SyncFromRepo([string]$sha) {
	if (Test-Path $Tmp) { Remove-Item $Tmp -Recurse -Force -ErrorAction SilentlyContinue }
	New-Item -ItemType Directory -Path $Tmp -Force | Out-Null

	$zip = Join-Path $Tmp 'src.zip'
	$zipUrl = "https://api.github.com/repos/$Owner/$Repo/zipball/$Branch"
	Invoke-WebRequest -Uri $zipUrl -Headers (GhHeaders) -OutFile $zip -TimeoutSec 180 -UseBasicParsing
	Expand-Archive -Path $zip -DestinationPath $Tmp -Force

	$rootDir = Get-ChildItem -Path $Tmp -Directory | Select-Object -First 1
	if ($null -eq $rootDir) { throw 'в архиве пусто' }
	$root = $rootDir.FullName

	$srcApp = Join-Path $root 'app'
	if (Test-Path $srcApp) {
		Copy-Item -Path (Join-Path $srcApp '*') -Destination $App -Recurse -Force
	}

	$selfChanged = $false
	foreach ($f in @('updater.ps1', 'XPrompt.bat')) {
		$s = Join-Path $root $f
		$d = Join-Path $Base $f
		if (Test-Path $s) {
			$newHash = (Get-FileHash -Path $s -Algorithm SHA256).Hash
			$oldHash = ''
			if (Test-Path $d) { $oldHash = (Get-FileHash -Path $d -Algorithm SHA256).Hash }
			if ($newHash -ne $oldHash) {
				Copy-Item -Path $s -Destination $d -Force
				$selfChanged = $true
			}
		}
	}

	Set-Content -Path $ShaFile -Value $sha -Encoding ASCII
	Set-Content -Path $BuildFile -Value ([string]((CurrentBuild) + 1)) -Encoding ASCII
	Remove-Item $Tmp -Recurse -Force -ErrorAction SilentlyContinue

	return $selfChanged
}

function ServerScript() { return (Join-Path $App 'server.ps1') }

function StartServer() {
	$s = ServerScript
	if (-not (Test-Path $s)) { return $null }
	$args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $s)
	return (Start-Process -FilePath 'powershell.exe' -ArgumentList $args -WindowStyle Minimized -PassThru)
}

function StopServer($p) {
	if ($null -ne $p) {
		try { if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force } } catch {}
	}
}

function ShowPairCode() {
	try {
		$r = Invoke-RestMethod -Uri 'http://127.0.0.1:8765/api/state' -TimeoutSec 5
		if ($r.code) {
			Write-Host '   КОД ПОДКЛЮЧЕНИЯ: ' -NoNewline
			Write-Host $r.code -ForegroundColor Green
		}
	} catch {}
}

Clear-Host
Line ''
Line '  ======================================================' 'DarkGray'
Write-Host '   XPrompt' -ForegroundColor Cyan -NoNewline
Write-Host '  — обновление и запуск'
Line '  ======================================================' 'DarkGray'
Line "   Папка: $Base" 'DarkGray'
Line ''

# ---- первая проверка обновлений ----
$installed = ''
if (Test-Path $ShaFile) { $installed = ((Get-Content $ShaFile -Raw) -replace '\s', '') }

Line '   Проверяю обновления...' 'DarkGray'
$latest = ''
try {
	$latest = LatestSha
} catch {
	Line ''
	Line '   Не смог достучаться до GitHub.' 'Red'
	Line "   $($_.Exception.Message)" 'DarkGray'
	Line ''
	Line '   Если написано 401 или 404 — дело в токене доступа.' 'Yellow'
	Line "   Положи его в файл: $TokenFile" 'Yellow'
	Line ''
}

if ($latest -ne '' -and ($latest -ne $installed -or -not (Test-Path (ServerScript)))) {
	Line '   Есть новая версия, скачиваю...' 'Yellow'
	try {
		$restart = SyncFromRepo $latest
		Line "   Обновлено. Сборка $(CurrentBuild)." 'Green'
		if ($restart) {
			Line '   Обновился сам запускатор, перезапускаюсь...' 'Yellow'
			Start-Sleep -Seconds 2
			exit 7
		}
	} catch {
		Line "   Не смог обновиться: $($_.Exception.Message)" 'Red'
	}
} elseif ($latest -ne '') {
	Line "   Уже самая свежая версия. Сборка $(CurrentBuild)." 'DarkGray'
}

# ---- запуск сервера ----
$proc = $null
if (Test-Path (ServerScript)) {
	$proc = StartServer
	Start-Sleep -Seconds 2
	Line ''
	Line '   Программа запущена:  http://127.0.0.1:8765/' 'Cyan'
	ShowPairCode
} else {
	Line ''
	Line '   Самой программы в репозитории пока нет.' 'Yellow'
	Line '   Как только она туда попадёт — это окно само её скачает и запустит.' 'DarkGray'
}

Line ''
Line "   Слежу за обновлениями каждые $CheckSeconds сек. Окно не закрывай." 'DarkGray'
$stopHint = '   Закрыть всё: Ctrl+C или крестик этого окна.'
Line $stopHint 'DarkGray'
Line ''

# ---- цикл слежения ----
try {
	while ($true) {
		Start-Sleep -Seconds $CheckSeconds

		$now = ''
		try { $now = LatestSha } catch { continue }
		if ($now -eq '') { continue }

		$have = ''
		if (Test-Path $ShaFile) { $have = ((Get-Content $ShaFile -Raw) -replace '\s', '') }
		if ($now -eq $have -and (Test-Path (ServerScript))) { continue }

		$stamp = (Get-Date).ToString('HH:mm')
		Line "   [$stamp] Приехало обновление, ставлю..." 'Yellow'
		StopServer $proc
		Start-Sleep -Seconds 1

		try {
			$restart = SyncFromRepo $now
			Line "   [$stamp] Готово. Сборка $(CurrentBuild)." 'Green'
			if ($restart) {
				Line '   Обновился сам запускатор, перезапускаюсь...' 'Yellow'
				Start-Sleep -Seconds 2
				exit 7
			}
			$proc = StartServer
			Start-Sleep -Seconds 2
			ShowPairCode
		} catch {
			Line "   Ошибка при обновлении: $($_.Exception.Message)" 'Red'
			$proc = StartServer
		}
	}
} finally {
	StopServer $proc
}
