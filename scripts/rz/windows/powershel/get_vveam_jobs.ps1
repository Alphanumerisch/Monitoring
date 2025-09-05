<# Veeam Jobs -> JSON (ECS-nah), ISO-8601 Zeiten, PS5-kompatibel #>

# -------- Konfig Logstash TCP --------
$LogstashIp   = "192.168.168.195"
$LogstashPort = 10520


function To-IsoUtc($dt) {
    if (-not $dt) { return $null }

    if ($dt -is [datetime]) { return $dt.ToUniversalTime().ToString('o') }

    if ($dt -is [string]) {
        $styles  = [System.Globalization.DateTimeStyles]::AssumeLocal
        $cultDE  = [System.Globalization.CultureInfo]::GetCultureInfo('de-DE')
        $cultInv = [System.Globalization.CultureInfo]::InvariantCulture
        $parsed  = [datetime]::MinValue

        # 1) TryParse mit de-DE
        if ([datetime]::TryParse($dt, $cultDE, $styles, [ref]$parsed)) { return $parsed.ToUniversalTime().ToString('o') }

        # 2) TryParse mit Invariant
        $parsed = [datetime]::MinValue
        if ([datetime]::TryParse($dt, $cultInv, $styles, [ref]$parsed)) { return $parsed.ToUniversalTime().ToString('o') }

        # 3) TryParseExact mit bekannten Formaten
        $formats = @(
            'dd.MM.yyyy HH:mm:ss','dd.MM.yyyy H:mm:ss',
            'yyyy-MM-dd HH:mm:ss','yyyy-MM-ddTHH:mm:ss','o'
        )
        $parsed = [datetime]::MinValue
        if ([datetime]::TryParseExact($dt, $formats, $cultDE,  $styles, [ref]$parsed)) { return $parsed.ToUniversalTime().ToString('o') }
        $parsed = [datetime]::MinValue
        if ([datetime]::TryParseExact($dt, $formats, $cultInv, $styles, [ref]$parsed)) { return $parsed.ToUniversalTime().ToString('o') }

        # Fallback: unverändert zurückgeben
        return $dt
    }

    return $dt.ToString()
}



$HostName = $env:COMPUTERNAME
# $LogstashUrl = "http://logstash.local:8080/veeam"   # optional

# Alle Jobs
$jobs = Get-VBRJob

$result = foreach ($j in $jobs) {
    # letzte Session zum Job
    $last = $null
    try {
        $last = Get-VBRSession -Job $j | Sort-Object CreationTime -Descending | Select-Object -First 1
    } catch {}
    if (-not $last) {
        try {
            $last = Get-VBRBackupSession | Where-Object { $_.JobId -eq $j.Id } |
                    Sort-Object EndTime -Descending | Select-Object -First 1
        } catch {}
    }

    # Zeiten aus Session holen
    $start = $null; $end = $null
    if ($last) {
        $p = $last.PSObject.Properties.Name
        if ($p -contains 'CreationTime'   -and $last.CreationTime)   { $start = $last.CreationTime }
        elseif ($p -contains 'CreationTimeUTC' -and $last.CreationTimeUTC) { $start = $last.CreationTimeUTC }
        if ($p -contains 'EndTime'        -and $last.EndTime)        { $end   = $last.EndTime }
        elseif ($p -contains 'EndTimeUTC' -and $last.EndTimeUTC)     { $end   = $last.EndTimeUTC }
    }

    # Schedule holen (Info.ScheduleOptions oder Cmdlet)
    $enabled = $null; $next = $null
    try { $so = $j.Info.ScheduleOptions; if ($so) { $enabled = $so.IsEnabled; $next = $so.NextRun } } catch {}
    if (-not $next) {
        try { $opt = $j | Get-VBRJobScheduleOptions; if ($opt) { $enabled = $opt.IsEnabled; $next = $opt.NextRun } } catch {}
    }

    # Result/Status
    $raw    = if ($last) { $last.Result.ToString() } else { 'None' }
    $status = if ($raw -eq 'Success') { 'success' } else { 'failed' }

    [pscustomobject]@{
        "@timestamp"      = (Get-Date).ToUniversalTime().ToString('o')
        "service"         = @{ "type" = "veeam" }
        "observer"        = @{ "hostname" = $HostName }
        "jobName"         = $j.Name
        "scheduleEnabled" = $enabled
        "nextRun"         = (To-IsoUtc $next)
        "lastRun"         = @{
                               "start" = (To-IsoUtc $start)
                               "end"   = (To-IsoUtc $end)
                             }
        "lastResultRaw"   = $raw
        "status"          = $status
    }
}

$payload = $result | ConvertTo-Json -Depth 6

# JSON-Sonderzeichen zurückkonvertieren (PS5-Workaround)
$payload = $payload `
  -replace '\\u003e','>' `
  -replace '\\u003c','<' `
  -replace '\\u0026','&' `
  -replace '\\u0027',"'" 

$payload

# Optional direkt posten:
# try {
#   Invoke-RestMethod -Method POST -Uri $LogstashUrl -ContentType 'application/json' -Body $payload | Out-Null
# } catch {
#   Write-Warning "POST an Logstash fehlgeschlagen: $_"
# }

# -------- Versand als json_lines via TCP --------
$client = New-Object System.Net.Sockets.TcpClient($LogstashIp, $LogstashPort)
$stream = $client.GetStream()
$enc    = New-Object System.Text.UTF8Encoding($false)  # UTF-8 ohne BOM
$writer = New-Object System.IO.StreamWriter($stream, $enc)
$writer.AutoFlush = $true

foreach ($obj in $result) {
    $line = ($obj | ConvertTo-Json -Depth 6 -Compress) `
        -replace '\\u003e','>' `
        -replace '\\u003c','<' `
        -replace '\\u0026','&' `
        -replace '\\u0027',"'" 
    $writer.WriteLine($line)
}

$writer.Dispose()
$stream.Dispose()
$client.Dispose()