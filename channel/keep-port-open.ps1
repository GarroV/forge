# Держит порт канала доступным снаружи (Tailscale/LAN) на MUSPELHEIM.
#
# Проблема, уже выученная на этом сервере: Docker Desktop при старте вешает
# inbound-BLOCK на свой backend в профилях Private+Public, а block в Windows
# Firewall перекрывает любой allow. Порт при этом слушается на 0.0.0.0 и локально
# по своему IP отвечает — loopback идёт мимо inbound-фильтра, и это путает
# диагностику: «с сервера работает, с Mac нет».
#
# Скрипт снимает блок и гарантирует allow-правило. Ставится задачей планировщика
# (при старте + каждые 10 минут, от SYSTEM), потому что Docker пересоздаёт блок
# при каждом своём запуске.
#
# Своя копия, а не переиспользование задачи n8n: канал не должен зависеть от того,
# что рядом жив другой проект. Снятие блока идемпотентно — если оба скрипта его
# снимут, ничего не сломается.
#
# ASCII-only в логе: PowerShell 5.1 и кодировки.

$ErrorActionPreference = 'Continue'

$port = 8090
$ruleName = "Forge Channel Docker $port"
$log = 'C:\projects\forge-channel\keep-port-open.log'

function Log($m) {
    Add-Content -Path $log -Value ("[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m)
}

# 1. Снять блок Docker-бэкенда, если он включён.
#    Get-NetFirewallRule ОБЯЗАТЕЛЬНО с фильтром по имени: полное перечисление
#    правил гидрирует их через WMI, пережимает CPU и вешает sshd — а SSH здесь
#    единственная удалённая дверь.
$blocked = Get-NetFirewallRule -DisplayName 'Docker Desktop Backend' -ErrorAction SilentlyContinue |
    Where-Object { $_.Enabled -eq 'True' }
if ($blocked) {
    $blocked | Disable-NetFirewallRule
    Log ("Disabled {0} 'Docker Desktop Backend' block rule(s)" -f @($blocked).Count)
}

# 2. Гарантировать allow-правило на входящий порт канала.
if (-not (Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -LocalPort $port `
        -Protocol TCP -Action Allow -Profile Any | Out-Null
    Log ("Recreated allow rule {0}" -f $ruleName)
}

# Ретеншн лога: не больше ~200 строк.
if (Test-Path $log) {
    $lines = Get-Content $log
    if ($lines.Count -gt 200) { $lines | Select-Object -Last 200 | Set-Content $log }
}
