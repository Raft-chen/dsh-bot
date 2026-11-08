# 常驻 DSH Remote 网关。
#
# 为什么需要它：
#   DSH Remote 网关是插件 spawn 出来的子进程，
#   1) DSH 一重启网关就没了；
#   2) 通过交互式脚本启动的进程还可能被父进程树回收 —— 看起来起来了，几分钟后消失。
#
# 解决办法：用 Windows 计划任务把它放到系统层运行；本脚本负责
#   - 自动探测当前 DSH Web 的上游端口（DSH 每次启动端口会变）
#   - 网关不在就拉起，退了就重拉
#
# 探测原理：DSH Web 对未认证请求返回 401，
#           所以扫描本机监听端口、找返回 401 的那个即可。

# ---------------- 配置 ----------------
$GatewayScript = "$env:USERPROFILE\.dsh\profiles\desktop\node_modules\dsh-remote-plugin\gateway.cjs"
$Port          = 8787
$LogDir        = "$env:USERPROFILE\.dsh-remote"
# --------------------------------------

$node = "node.exe"
foreach ($c in @("D:\Program Files\nodejs\node.exe", "$env:ProgramFiles\nodejs\node.exe")) {
    if (Test-Path $c) { $node = $c; break }
}

if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null }
$log = Join-Path $LogDir "gateway-wrapper.log"

function Write-Log($msg) {
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $msg
    Add-Content -Path $log -Value $line -Encoding UTF8
}

function Test-Gateway {
    return [bool](Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue)
}

function Find-DshUpstream {
    $ports = @()
    try {
        $ports += Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
            Where-Object { $_.LocalPort -ne $Port } |
            Select-Object -ExpandProperty LocalPort -Unique
    } catch {}

    $unauthorized = @()
    foreach ($p in ($ports | Sort-Object -Unique)) {
        try {
            $req = [System.Net.WebRequest]::Create("http://127.0.0.1:$p/")
            $req.Timeout = 2500
            $req.AllowAutoRedirect = $false
            $resp = $req.GetResponse()
            $code = [int]$resp.StatusCode
            $resp.Close()
            if ($code -eq 401) { $unauthorized += $p }
        } catch {
            $code = $null
            try { $code = [int]$_.Exception.Response.StatusCode } catch {}
            if ($code -eq 401) { $unauthorized += $p }
        }
    }

    if ($unauthorized.Count -gt 0) {
        $pick = ($unauthorized | Sort-Object -Descending)[0]
        Write-Log "detected DSH upstream: 127.0.0.1:$pick"
        return "http://127.0.0.1:$pick"
    }
    return $null
}

Write-Log "gateway wrapper started (pid $PID)"

while ($true) {
    if (Test-Gateway) { Start-Sleep -Seconds 15; continue }

    if (-not (Test-Path $GatewayScript)) {
        Write-Log "gateway script not found: $GatewayScript"
        Start-Sleep -Seconds 60
        continue
    }

    $upstream = Find-DshUpstream
    if (-not $upstream) {
        Write-Log "no DSH upstream found, retry in 10s"
        Start-Sleep -Seconds 10
        continue
    }

    Write-Log "starting gateway: PORT=$Port DSH_UPSTREAM=$upstream"
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $node
        $psi.Arguments = "`"$GatewayScript`""
        $psi.WorkingDirectory = Split-Path $GatewayScript
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.EnvironmentVariables["PORT"] = "$Port"
        $psi.EnvironmentVariables["HOST"] = "0.0.0.0"
        $psi.EnvironmentVariables["DSH_UPSTREAM"] = $upstream
        $p = [System.Diagnostics.Process]::Start($psi)
        Write-Log "gateway pid $($p.Id)"

        $ready = $false
        for ($i = 0; $i -lt 20; $i++) {
            Start-Sleep -Seconds 1
            if (Test-Gateway) { $ready = $true; break }
            if ($p.HasExited) { Write-Log "gateway exited (code $($p.ExitCode))"; break }
        }
        if ($ready) {
            Write-Log "gateway ready"
            $p.WaitForExit()
            Write-Log "gateway exited (code $($p.ExitCode))"
        } else {
            Write-Log "gateway not ready, killing"
            try { if (-not $p.HasExited) { $p.Kill() } } catch {}
        }
    } catch {
        Write-Log "start failed: $($_.Exception.Message)"
    }
    Start-Sleep -Seconds 5
}
