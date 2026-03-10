#Requires -RunAsAdministrator

$ErrorActionPreference = 'Stop'

$script:StateRoot = 'C:\ProgramData\FFUBuilder\State'
$script:StatePath = Join-Path $script:StateRoot 'capabilities.state.json'
$script:ConfigPath = Join-Path $PSScriptRoot 'WindowsCapabilities.json'
$script:RunOncePath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
$script:RunOnceName = 'FFUBuilderOrchestratorResume'
$script:OrchestratorPath = Join-Path $PSScriptRoot 'Orchestrator.ps1'
$script:MaxAttempts = 3
$script:RetryDelaySeconds = 20
$script:InstallTimeoutSeconds = 1800
$script:NetworkTargets = @(
    'fe2.update.microsoft.com',
    'www.msftconnecttest.com'
)

function Ensure-StateDirectory {
    if (-not (Test-Path -Path $script:StateRoot -PathType Container)) {
        New-Item -Path $script:StateRoot -ItemType Directory -Force | Out-Null
    }
}

function Get-RequestedCapabilities {
    if (-not (Test-Path -Path $script:ConfigPath -PathType Leaf)) {
        return @()
    }

    $capabilities = @()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    try {
        $raw = Get-Content -Path $script:ConfigPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($null -ne $raw -and $null -ne $raw.Capabilities) {
            foreach ($capability in @($raw.Capabilities)) {
                $trimmed = [string]$capability
                if ($null -eq $trimmed) {
                    continue
                }
                $trimmed = $trimmed.Trim()
                if ([string]::IsNullOrWhiteSpace($trimmed)) {
                    continue
                }
                if ($seen.Add($trimmed)) {
                    $capabilities += $trimmed
                }
            }
        }
    }
    catch {
        throw "Failed to parse Windows capabilities payload at '$($script:ConfigPath)': $($_.Exception.Message)"
    }

    return $capabilities
}

function Get-CapabilityState {
    $state = [ordered]@{
        Version       = 1
        PendingReboot = $false
        Completed     = $false
        Capabilities  = @{}
        LastUpdatedUtc = $null
    }

    if (-not (Test-Path -Path $script:StatePath -PathType Leaf)) {
        return $state
    }

    try {
        $raw = Get-Content -Path $script:StatePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($null -ne $raw -and $null -ne $raw.PendingReboot) { $state.PendingReboot = [bool]$raw.PendingReboot }
        if ($null -ne $raw -and $null -ne $raw.Completed) { $state.Completed = [bool]$raw.Completed }
        if ($null -ne $raw -and $null -ne $raw.LastUpdatedUtc) { $state.LastUpdatedUtc = [string]$raw.LastUpdatedUtc }

        if ($null -ne $raw -and $null -ne $raw.Capabilities -and $raw.Capabilities.PSObject -and $raw.Capabilities.PSObject.Properties) {
            foreach ($prop in $raw.Capabilities.PSObject.Properties) {
                $entry = $prop.Value
                $state.Capabilities[$prop.Name] = [ordered]@{
                    Status         = if ($null -ne $entry.Status) { [string]$entry.Status } else { '' }
                    Attempts       = if ($null -ne $entry.Attempts) { [int]$entry.Attempts } else { 0 }
                    LastAttemptUtc = if ($null -ne $entry.LastAttemptUtc) { [string]$entry.LastAttemptUtc } else { $null }
                    LastError      = if ($null -ne $entry.LastError) { [string]$entry.LastError } else { $null }
                    RestartNeeded  = if ($null -ne $entry.RestartNeeded) { [bool]$entry.RestartNeeded } else { $false }
                }
            }
        }
    }
    catch {
        Write-Warning "Windows capability state file is invalid. Reinitializing state. Error: $($_.Exception.Message)"
    }

    return $state
}

function Save-CapabilityState {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$State
    )

    $State.LastUpdatedUtc = (Get-Date).ToUniversalTime().ToString('o')
    $State | ConvertTo-Json -Depth 8 | Set-Content -Path $script:StatePath -Encoding UTF8
}

function Ensure-CapabilityEntry {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$State,
        [Parameter(Mandatory = $true)]
        [string]$CapabilityName
    )

    if (-not $State.Capabilities.ContainsKey($CapabilityName)) {
        $State.Capabilities[$CapabilityName] = [ordered]@{
            Status         = 'Pending'
            Attempts       = 0
            LastAttemptUtc = $null
            LastError      = $null
            RestartNeeded  = $false
        }
    }

    return $State.Capabilities[$CapabilityName]
}

function Test-TcpPort {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ComputerName,
        [int]$Port = 443,
        [int]$TimeoutMs = 5000
    )

    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect($ComputerName, $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) {
            return $false
        }
        $client.EndConnect($iar)
        return $true
    }
    catch {
        return $false
    }
    finally {
        if ($null -ne $client) { $client.Close() }
    }
}

function Test-WindowsCapabilityNetwork {
    foreach ($target in $script:NetworkTargets) {
        if (Test-TcpPort -ComputerName $target -Port 443 -TimeoutMs 5000) {
            Write-Host "Windows capability network test passed using $target:443"
            return $true
        }
    }
    return $false
}

function Test-CapabilityInstalled {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CapabilityName
    )

    try {
        $capability = Get-WindowsCapability -Online -Name $CapabilityName -ErrorAction Stop
        return ($capability.State -eq 'Installed')
    }
    catch {
        throw "Failed to query capability '$CapabilityName': $($_.Exception.Message)"
    }
}

function Invoke-CapabilityInstallWithTimeout {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CapabilityName,
        [int]$TimeoutSeconds = 1800
    )

    if (-not (Get-Command -Name Start-Job -ErrorAction SilentlyContinue)) {
        return Add-WindowsCapability -Online -Name $CapabilityName -ErrorAction Stop
    }

    $job = Start-Job -ScriptBlock {
        param($Name)
        $ErrorActionPreference = 'Stop'
        Add-WindowsCapability -Online -Name $Name -ErrorAction Stop
    } -ArgumentList $CapabilityName

    try {
        $finished = Wait-Job -Job $job -Timeout $TimeoutSeconds
        if (-not $finished) {
            Stop-Job -Job $job -Force -ErrorAction SilentlyContinue
            throw "Timed out after $TimeoutSeconds seconds."
        }

        return Receive-Job -Job $job -ErrorAction Stop
    }
    finally {
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    }
}

function Get-RestartNeededFromResult {
    param($Result)

    if ($null -eq $Result) {
        return $false
    }

    foreach ($item in @($Result)) {
        if ($null -ne $item -and $item.PSObject -and ($item.PSObject.Properties.Match('RestartNeeded').Count -gt 0)) {
            if ([bool]$item.RestartNeeded) {
                return $true
            }
        }
    }

    return $false
}

function Register-OrchestratorResume {
    if (-not (Test-Path -Path $script:OrchestratorPath -PathType Leaf)) {
        throw "Unable to register orchestrator resume because '$($script:OrchestratorPath)' was not found."
    }

    $resumeCommand = "powershell.exe -ExecutionPolicy Bypass -File `"$script:OrchestratorPath`""
    New-ItemProperty -Path $script:RunOncePath -Name $script:RunOnceName -Value $resumeCommand -PropertyType String -Force | Out-Null
    Write-Host "Registered RunOnce resume command for Orchestrator.ps1"
}

Ensure-StateDirectory

$requestedCapabilities = Get-RequestedCapabilities
if ($requestedCapabilities.Count -eq 0) {
    Write-Host 'No Windows capabilities requested. Skipping Add-WindowsCapabilities.ps1.'
    return
}

$state = Get-CapabilityState

$pendingCapabilities = @()
foreach ($capabilityName in $requestedCapabilities) {
    if (-not (Test-CapabilityInstalled -CapabilityName $capabilityName)) {
        $pendingCapabilities += $capabilityName
    }
}

if ($pendingCapabilities.Count -gt 0) {
    if (-not (Test-WindowsCapabilityNetwork)) {
        throw "Cannot reach Windows Update endpoints from VM. Windows capability installation requires online access."
    }
}

foreach ($capabilityName in $requestedCapabilities) {
    $entry = Ensure-CapabilityEntry -State $state -CapabilityName $capabilityName

    if (Test-CapabilityInstalled -CapabilityName $capabilityName) {
        $entry.Status = 'Installed'
        $entry.LastError = $null
        $entry.RestartNeeded = $false
        Save-CapabilityState -State $state
        Write-Host "Capability already installed: $capabilityName"
        continue
    }

    Write-Host "Installing Windows capability: $capabilityName"
    $installed = $false

    for ($attempt = 1; $attempt -le $script:MaxAttempts; $attempt++) {
        try {
            $entry.Status = 'Installing'
            $entry.Attempts = [int]$entry.Attempts + 1
            $entry.LastAttemptUtc = (Get-Date).ToUniversalTime().ToString('o')
            $entry.LastError = $null
            $entry.RestartNeeded = $false
            Save-CapabilityState -State $state

            $result = Invoke-CapabilityInstallWithTimeout -CapabilityName $capabilityName -TimeoutSeconds $script:InstallTimeoutSeconds

            if (-not (Test-CapabilityInstalled -CapabilityName $capabilityName)) {
                throw "Add-WindowsCapability completed, but capability state is not Installed."
            }

            $restartNeeded = Get-RestartNeededFromResult -Result $result
            $entry.Status = 'Installed'
            $entry.LastError = $null
            $entry.RestartNeeded = $restartNeeded
            Save-CapabilityState -State $state
            Write-Host "Installed Windows capability: $capabilityName"

            if ($restartNeeded) {
                $state.PendingReboot = $true
                $state.Completed = $false
                Save-CapabilityState -State $state
                Write-Host "Capability install requires reboot. Registering orchestrator resume and restarting."
                Register-OrchestratorResume
                Restart-Computer -Force
                return
            }

            $installed = $true
            break
        }
        catch {
            $entry.Status = 'Failed'
            $entry.LastError = $_.Exception.Message
            Save-CapabilityState -State $state

            if ($attempt -eq $script:MaxAttempts) {
                throw "Failed installing capability '$capabilityName' after $attempt attempts. Last error: $($_.Exception.Message)"
            }

            Write-Warning "Attempt $attempt of $($script:MaxAttempts) failed for '$capabilityName'. Retrying in $($script:RetryDelaySeconds) seconds. Error: $($_.Exception.Message)"
            Start-Sleep -Seconds $script:RetryDelaySeconds
        }
    }

    if (-not $installed) {
        throw "Capability '$capabilityName' was not installed."
    }
}

$state.PendingReboot = $false
$state.Completed = $true
Save-CapabilityState -State $state
Write-Host 'Windows capability installation completed successfully.'
