# 常驻 SSH 反向隧道：把本机端口映射到服务器的 127.0.0.1。
#
# 用途：让服务器上的 nginx 能 proxy_pass 到 127.0.0.1:<port>，
#       从而在不需要公网 IP、不需要端口映射的情况下对外提供服务。
#
# 用法：
#   1. 改下面 4 个变量
#   2. 用计划任务在登录时启动本脚本（见 README）
#   3. 服务器上 `ss -lnt | grep <RemotePort>` 应能看到 127.0.0.1:<RemotePort>
#
# 计划任务示例：
#   schtasks /create /tn "Tunnel" ^
#     /tr "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File <本文件路径>" ^
#     /sc onlogon /rl highest /f

# ---------------- 配置 ----------------
$SshHost    = "myserver"     # ~/.ssh/config 里的 Host 别名，或 user@host
$RemotePort = 8787           # 服务器上要监听的端口（只绑 127.0.0.1）
$LocalPort  = 8787           # 本机要暴露的端口
$LogDir     = "$env:USERPROFILE\.dsh-tunnel"
# --------------------------------------

$ssh = "C:\Windows\System32\OpenSSH\ssh.exe"
if (-not (Test-Path $ssh)) { $ssh = "ssh.exe" }

if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null }
$log = Join-Path $LogDir "tunnel.log"

function Write-Log($msg) {
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $msg
    Add-Content -Path $log -Value $line -Encoding UTF8
}

Write-Log "tunnel supervisor started (pid $PID)"

while ($true) {
    Write-Log "connecting: remote $RemotePort -> local $LocalPort"
    # -C 压缩：文本资源在窄上行下能省 5~8 倍
    # ExitOnForwardFailure：端口被占用时立刻失败，别假装连上了
    & $ssh -N `
        -C `
        -o ServerAliveInterval=30 `
        -o ServerAliveCountMax=3 `
        -o ExitOnForwardFailure=yes `
        -o StrictHostKeyChecking=accept-new `
        -o ConnectTimeout=15 `
        -R "${RemotePort}:127.0.0.1:${LocalPort}" `
        $SshHost 2>&1 | ForEach-Object { Write-Log $_ }

    Write-Log "ssh exited (code $LASTEXITCODE), retry in 10s"
    Start-Sleep -Seconds 10
}
