<#
  HPE Smart Array → NDJSON Export (Console + TCP to Logstash)
  - Nutzt ssacli/hpssacli (Windows)
  - Gibt jede NDJSON-Zeile auf STDOUT aus und sendet sie zusätzlich per TCP an Logstash
  - Setzt KEIN event.dataset und KEIN service.name (macht Logstash-Input)
#>

param(
  [string]$Slot = $env:HPE_SLOT,
  [string]$SsaCli = 'C:\Program Files\Smart Storage Administrator\ssacli\bin\ssacli.exe',
  [string]$LogstashHost = '192.168.168.161',
  [int]$LogstashPort = 10540
)

# --- Defaults ---
if ([string]::IsNullOrWhiteSpace($Slot)) { $Slot = '3' }

# --- Helpers ---
function Convert-SizeToBytes([string]$s) {
  if ([string]::IsNullOrWhiteSpace($s)) { return $null }
  $s = $s.Trim()
  if ($s -match '^(?<num>[\d\.,]+)\s*(?<unit>[A-Za-z]+)$') {
    $num = [double]::Parse(($matches['num'] -replace ',', '.'), [Globalization.CultureInfo]::InvariantCulture)
    switch ($matches['unit']) {
      'TB'  { return [long]([math]::Round($num * 1e12)) }
      'GB'  { return [long]([math]::Round($num * 1e9)) }
      'MB'  { return [long]([math]::Round($num * 1e6)) }
      'KB'  { return [long]([math]::Round($num * 1024)) }   # bewusst 1024 für Blockgrößen
      'TiB' { return [long]($num * [math]::Pow(1024,4)) }
      'GiB' { return [long]($num * [math]::Pow(1024,3)) }
      'MiB' { return [long]($num * [math]::Pow(1024,2)) }
      'KiB' { return [long]($num * 1024) }
      default { return $null }
    }
  }
  return $null
}




function Parse-Bool([string]$s) {
  if ([string]::IsNullOrWhiteSpace($s)) { return $null }
  $v = $s.Trim().ToLower()
  if ($v -in @('true','yes','enabled')) { return $true }
  if ($v -in @('false','no','disabled')) { return $false }
  return $null
}
function Null-If([string]$s) {
  if ([string]::IsNullOrWhiteSpace($s)) { return $null }
  $v = $s.Trim()
  if ($v -in @('Unknown','Not Supported','None')) { return $null }
  return $v
}
function Out-NDJSON([string]$line, [System.Net.Sockets.TcpClient]$tcp, [System.IO.Stream]$stream) {
  Write-Output $line
  if ($tcp -and $tcp.Connected -and $stream) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($line + "`n")
    $stream.Write($bytes,0,$bytes.Length)
    $stream.Flush()
  }
}

# --- ssacli Pfad finden ---
if (-not (Test-Path $SsaCli)) {
  $alt = 'C:\Program Files (x86)\Hewlett-Packard\hpssacli\bin\hpssacli.exe'
  if (Test-Path $alt) { $SsaCli = $alt }
}

$hostName = $env:COMPUTERNAME
$ts = (Get-Date).ToUniversalTime().ToString('o')

# --- Logstash TCP verbinden ---
$tcp = $null; $stream = $null
try {
  $tcp = [System.Net.Sockets.TcpClient]::new()
  $tcp.Connect($LogstashHost, $LogstashPort)
  $stream = $tcp.GetStream()
} catch {
  Write-Warning ("TCP connect zu {0}:{1} fehlgeschlagen: {2}" -f $LogstashHost, $LogstashPort, $_.Exception.Message)
}

# --- Fehlerdokument senden ---
function Send-ErrorDoc([string]$msg) {
  $doc = @{
    '@timestamp' = $ts
    event  = @{ category='storage'; kind='event'; type='error'; outcome='failure'; dataset='hpe.smartarray' }
    service= @{ type='hpe.smartarray' }
    host   = @{ name=$hostName; ip=@() }
    observer = @{ vendor='HPE'; product='Smart Array' }
    error  = @{ message=$msg }
  }
  $json = $doc | ConvertTo-Json -Compress -Depth 10
  Out-NDJSON $json $tcp $stream
}

# --- Wenn ssacli fehlt: Fehlerdokument und Exit ---
if (-not (Test-Path $SsaCli)) {
  Send-ErrorDoc 'ssacli/hpssacli not found'
  if ($stream) { $stream.Dispose() }; if ($tcp) { $tcp.Close() }
  exit 2
}

# --- Controller: show detail ---
$ctrlDetail = & $SsaCli "ctrl" "slot=$Slot" "show" "detail" 2>&1
if ($LASTEXITCODE -ne 0 -or -not $ctrlDetail) {
  Send-ErrorDoc ("ssacli ctrl slot={0} show detail failed ({1})" -f $Slot, $LASTEXITCODE)
  if ($stream) { $stream.Dispose() }; if ($tcp) { $tcp.Close() }
  exit 3
}

# Header "Smart Array P840 in Slot 3"
$ctrlModel = ($ctrlDetail | Select-String -Pattern 'Smart Array\s+(.+?)\s+in\s+Slot\s+\d+' -AllMatches).Matches | Select-Object -First 1
$ctrlModelName = if ($ctrlModel) { $ctrlModel.Groups[1].Value.Trim() } else { 'HPE Smart Array' }

# Key:Value in Hashtable parsen
$kv = @{}
foreach ($line in $ctrlDetail) {
  if ($line -match '^\s*([^:]+):\s*(.*)$') {
    $k = $matches[1].Trim()
    $v = $matches[2].Trim()
    $kv[$k] = $v
  }
}

# Controller-Dokument
$ctrlDoc = @{
  '@timestamp' = $ts
  event  = @{ category='storage'; kind='state'; type='info'; outcome='success'; dataset='hpe.smartarray' }
  service= @{ type='hpe.smartarray' }
  host   = @{ name=$hostName; ip=@() }
  observer = @{ vendor='HPE'; product='Smart Array'; version=(Null-If $kv['Firmware Version']) }
  hpe = @{
    ctrl = @{
      slot = $Slot
      model = $ctrlModelName
      status = Null-If $kv['Controller Status']
      firmware = Null-If $kv['Firmware Version']
      bus_interface = Null-If $kv['Bus Interface']
      serial_number = Null-If $kv['Serial Number']
      cache_serial_number = Null-If $kv['Cache Serial Number']
      hardware_revision = Null-If $kv['Hardware Revision']
      firmware_online_activation_supported = (Parse-Bool $kv['Firmware Supports Online Firmware Activation'])
      rebuild_priority = Null-If $kv['Rebuild Priority']
      expand_priority = Null-If $kv['Expand Priority']
      surface_scan_delay_secs = if ($kv['Surface Scan Delay'] -match '(\d+)') { [int]$matches[1] } else { $null }
      surface_scan_mode = Null-If $kv['Surface Scan Mode']
      parallel_surface_scan_supported = (Parse-Bool $kv['Parallel Surface Scan Supported'])
      parallel_surface_scan_current = if ($kv['Current Parallel Surface Scan Count']) { [int]$kv['Current Parallel Surface Scan Count'] } else { $null }
      parallel_surface_scan_max     = if ($kv['Max Parallel Surface Scan Count']) { [int]$kv['Max Parallel Surface Scan Count'] } else { $null }
      queue_depth = Null-If $kv['Queue Depth']
      monitor_performance_delay_min = if ($kv['Monitor and Performance Delay'] -match '(\d+)') { [int]$matches[1] } else { $null }
      elevator_sort_enabled = (Parse-Bool $kv['Elevator Sort'])
      degraded_performance_optimization_enabled = (Parse-Bool $kv['Degraded Performance Optimization'])
      inconsistency_repair_policy_enabled = (Parse-Bool $kv['Inconsistency Repair Policy'])
      wait_for_cache_room_enabled = (Parse-Bool $kv['Wait for Cache Room'])
      surface_analysis_inconsistency_notification_enabled = (Parse-Bool $kv['Surface Analysis Inconsistency Notification'])
      post_prompt_timeout_secs = if ($kv['Post Prompt Timeout'] -match '(\d+)') { [int]$matches[1] } else { $null }
      cache_board_present = (Parse-Bool $kv['Cache Board Present'])
      drive_write_cache_enabled = (Parse-Bool $kv['Drive Write Cache'])
      total_cache_size_gb = if ($kv['Total Cache Size']) { [double]$kv['Total Cache Size'] } else { $null }
      total_cache_memory_available_gb = if ($kv['Total Cache Memory Available']) { [double]$kv['Total Cache Memory Available'] } else { $null }
      no_battery_write_cache_enabled = (Parse-Bool $kv['No-Battery Write Cache'])
      ssd_caching_raid5_writeback_enabled = (Parse-Bool $kv['SSD Caching RAID5 WriteBack Enabled'])
      ssd_caching_version = if ($kv['SSD Caching Version']) { [int]$kv['SSD Caching Version'] } else { $null }
      cache_backup_power_source = Null-If $kv['Cache Backup Power Source']
      sata_ncq_supported = (Parse-Bool $kv['SATA NCQ Supported'])
      spare_activation_mode = Null-If $kv['Spare Activation Mode']
      temperature_c = if ($kv['Controller Temperature (C)']) { [int]$kv['Controller Temperature (C)'] } else { $null }
      cache_module_temperature_c = if ($kv['Cache Module Temperature (C)']) { [int]$kv['Cache Module Temperature (C)'] } else { $null }
      ports = @{
        count = if ($kv['Number of Ports'] -match '(\d+)') { [int]$matches[1] } else { $null }
        description = if ($kv['Number of Ports'] -match '^\d+\s*(.*)$') { ($matches[1].Trim()) } else { $null }
      }
      encryption = Null-If $kv['Encryption']
      express_local_encryption = (Parse-Bool $kv['Express Local Encryption'])
      driver = @{ name = Null-If $kv['Driver Name']; version = Null-If $kv['Driver Version'] }
      pci = @{ address = Null-If $kv['PCI Address (Domain:Bus:Device.Function)'] }
      pcie_negotiated_data_rate = Null-If $kv['Negotiated PCIe Data Rate']
      mode = Null-If $kv['Controller Mode']
      pending_mode = Null-If $kv['Pending Controller Mode']
      port_max_phy_rate_limiting_supported = (Parse-Bool $kv['Port Max Phy Rate Limiting Supported'])
      latency_scheduler_setting = Null-If $kv['Latency Scheduler Setting']
      power_mode = Null-If $kv['Current Power Mode']
      survival_mode_enabled = (Parse-Bool $kv['Survival Mode'])
      host_serial_number = Null-If $kv['Host Serial Number']
      sanitize_erase_supported = (Parse-Bool $kv['Sanitize Erase Supported'])
      primary_boot_volume = Null-If $kv['Primary Boot Volume']
      secondary_boot_volume = Null-If $kv['Secondary Boot Volume']
      cache = @{ status = Null-If $kv['Cache Status']; write_policy = Null-If $kv['Drive Write Cache'] }
      battery = @{ count = if ($kv['Battery/Capacitor Count']) { [int]$kv['Battery/Capacitor Count'] } else { $null }; status = Null-If $kv['Battery/Capacitor Status'] }
      raid6_status = Null-If $kv['RAID 6 (ADG) Status']
    }
  }
}

Out-NDJSON ($ctrlDoc | ConvertTo-Json -Compress -Depth 10) $tcp $stream

# --- Physical Drives ---
$pdOut = & $SsaCli "ctrl" "slot=$Slot" "pd" "all" "show" "detail" 2>&1
$pdBlocks = @(); $current = @()
foreach ($line in $pdOut) {
  if ($line -match '^\s*physicaldrive\s+\S+') {
    if ($current.Count -gt 0) { $pdBlocks += ,@($current); $current = @() }
    $current += $line
  } elseif ($current.Count -gt 0) {
    $current += $line
  }
}
if ($current.Count -gt 0) { $pdBlocks += ,@($current) }

foreach ($block in $pdBlocks) {
  $text = $block -join "`n"
  if ($text -notmatch '^\s*physicaldrive\s+(\S+)') { continue }
  $bayId = $matches[1]
  $kvp = @{}
  foreach ($ln in $block) {
    if ($ln -match '^\s*([^:]+):\s*(.*)$') {
      $k = $matches[1].Trim()
      $v = $matches[2].Trim()
      $kvp[$k] = $v
    }
  }
  $driveType = Null-If $kvp['Drive Type']
  $role = if ($driveType -and $driveType -match 'Spare') { 'spare' } elseif ($driveType) { 'data' } else { $null }
  $lb = $null; $pb = $null
  if ($kvp['Logical/Physical Block Size'] -match '^\s*(\d+)\s*/\s*(\d+)\s*$') { $lb=[int]$matches[1]; $pb=[int]$matches[2] }

  $doc = @{
    '@timestamp' = $ts
    event  = @{ category='storage'; kind='metric'; type='info'; outcome='success'; dataset='hpe.smartarray' }
    service= @{ type='hpe.smartarray' }
    host   = @{ name=$hostName; ip=@() }
    observer = @{ vendor='HPE'; product='Smart Array'; version=(Null-If $kv['Firmware Version']) }
    hpe = @{
      ctrl = @{ slot = $Slot }
      pd = @{
        bay = $bayId
        port = Null-If $kvp['Port']
        box  = Null-If $kvp['Box']
        bay_number = if ($kvp['Bay']) { [int]$kvp['Bay'] } else { $null }
        drive_type = $driveType
        role = $role
        interface = Null-If $kvp['Interface Type']
        size_bytes = Convert-SizeToBytes $kvp['Size']
        status = Null-If $kvp['Status']
        temperature_c = if ($kvp['Current Temperature (C)']) { [int]$kvp['Current Temperature (C)'] } else { $null }
        temperature_max_c = if ($kvp['Maximum Temperature (C)']) { [int]$kvp['Maximum Temperature (C)'] } else { $null }
        model = Null-If $kvp['Model']
        serial = Null-If $kvp['Serial Number']
        firmware = Null-If $kvp['Firmware Revision']
        wwid = Null-If $kvp['WWID']
        media_error_count = if ($kvp['Media Error Count']) { [int]$kvp['Media Error Count'] } else { $null }
        recoverable_error_count = if ($kvp['Recoverable Error Count']) { [int]$kvp['Recoverable Error Count'] } else { $null }
        ssd_wear_percent = $null
        exposed_to_os = Parse-Bool $kvp['Drive exposed to OS']
        logical_block_size_bytes = $lb
        physical_block_size_bytes = $pb
        ssd_smart_trip_wearout = Null-If $kvp['SSD Smart Trip Wearout']
        phy = @{
          count = if ($kvp['PHY Count']) { [int]$kvp['PHY Count'] } else { $null }
          transfer_rate = Null-If $kvp['PHY Transfer Rate']
          physical_link_rate = Null-If $kvp['PHY Physical Link Rate']
          maximum_link_rate = Null-If $kvp['PHY Maximum Link Rate']
        }
        auth = @{ status = Null-If $kvp['Drive Authentication Status'] }
        carrier = @{
          app_version = Null-If $kvp['Carrier Application Version']
          bootloader_version = Null-If $kvp['Carrier Bootloader Version']
        }
        sanitize = @{
          erase_supported = Parse-Bool $kvp['Sanitize Erase Supported']
          unrestricted_supported = Parse-Bool $kvp['Unrestricted Sanitize Supported']
        }
        smr = @{ support = Null-If $kvp['Shingled Magnetic Recording Support'] }
        sata_ncq = @{
          capable = Parse-Bool $kvp['SATA NCQ Capable']
          enabled = Parse-Bool $kvp['SATA NCQ Enabled']
        }
      }
    }
  }
  Out-NDJSON ($doc | ConvertTo-Json -Compress -Depth 10) $tcp $stream
}

# --- Logical Drives ---
$ldOut = & $SsaCli "ctrl" "slot=$Slot" "ld" "all" "show" "detail" 2>&1
$ldBlocks = @(); $cur = @()
foreach ($line in $ldOut) {
  if ($line -match '^\s*Logical Drive:\s*\d+') {
    if ($cur.Count -gt 0) { $ldBlocks += ,@($cur); $cur=@() }
    $cur += $line
  } elseif ($cur.Count -gt 0) {
    $cur += $line
  }
}
if ($cur.Count -gt 0) { $ldBlocks += ,@($cur) }

foreach ($block in $ldBlocks) {
  $num = $null
  if ($block[0] -match 'Logical Drive:\s*(\d+)') { $num = [int]$matches[1] }

  $kv2 = @{}
  $partInfo = @()
  $inPart = $false
  $mg1 = @(); $mg2 = @(); $mg = 0

  foreach ($ln in $block) {
    if ($ln -match '^\s*([^:]+):\s*(.*)$') {
      $k = $matches[1].Trim()
      $v = $matches[2].Trim()
      switch -Regex ($k) {
        '^Disk Partition Information$' { $inPart = $true; continue }
        '^Mirror Group 1' { $mg = 1; continue }
        '^Mirror Group 2' { $mg = 2; continue }
        default { $inPart = $false; $kv2[$k] = $v }
      }
    } else {
      if ($inPart -and ($ln.Trim() -ne '')) { $partInfo += $ln.Trim() }
      elseif ($mg -gt 0 -and ($ln -match 'physicaldrive')) {
        if ($mg -eq 1) { $mg1 += $ln.Trim() } else { $mg2 += $ln.Trim() }
      }
    }
  }

  $ldDoc = @{
    '@timestamp' = $ts
    event  = @{ category='storage'; kind='state'; type='info'; outcome='success'; dataset='hpe.smartarray' }
    service= @{ type='hpe.smartarray' }
    host   = @{ name=$hostName; ip=@() }
    observer = @{ vendor='HPE'; product='Smart Array'; version=(Null-If $kv['Firmware Version']) }
    hpe = @{
      ctrl = @{ slot = $Slot }
      ld = @{
        number = $num
        size_bytes = Convert-SizeToBytes $kv2['Size']
        status = Null-If $kv2['Status']
        raid_level = if ($kv2['Fault Tolerance']) { 'RAID ' + $kv2['Fault Tolerance'] } else { $null }
        fault_tolerance = Null-If $kv2['Fault Tolerance']
        heads = if ($kv2['Heads']) { [int]$kv2['Heads'] } else { $null }
        sectors_per_track = if ($kv2['Sectors Per Track']) { [int]$kv2['Sectors Per Track'] } else { $null }
        cylinders = if ($kv2['Cylinders']) { [int]$kv2['Cylinders'] } else { $null }
        stripe_size_bytes = Convert-SizeToBytes $kv2['Strip Size']
        full_stripe_size_bytes = Convert-SizeToBytes $kv2['Full Stripe Size']
        unrecoverable_media_errors = Null-If $kv2['Unrecoverable Media Errors']
        multidomain_status = Null-If $kv2['MultiDomain Status']
        caching = Null-If $kv2['Caching']
        unique_identifier = Null-If $kv2['Unique Identifier']
        disk_name = Null-If $kv2['Disk Name']
        mount_points = Null-If $kv2['Mount Points']
        partition_info = if ($partInfo.Count -gt 0) { ($partInfo -join ' | ') } else { $null }
        label = Null-If $kv2['Logical Drive Label']
        mirror_group1 = if ($mg1.Count -gt 0) { ($mg1 -join '; ') } else { $null }
        mirror_group2 = if ($mg2.Count -gt 0) { ($mg2 -join '; ') } else { $null }
        drive_type = Null-If $kv2['Drive Type']
        acceleration_method = Null-If $kv2['LD Acceleration Method']
      }
    }
  }

  Out-NDJSON ($ldDoc | ConvertTo-Json -Compress -Depth 10) $tcp $stream
}

# --- Cleanup ---
if ($stream) { $stream.Dispose() }
if ($tcp) { $tcp.Close() }
exit 0
