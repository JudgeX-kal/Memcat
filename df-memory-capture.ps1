
$ErrorActionPreference = 'Stop'

$CaptureExe = 'C:\DF\memory_capture_go_winpmem.exe'

# Create a unique timestamped log for each execution.
$Timestamp = Get-Date -Format 'yyyyMMdd_HHmmss_fff'
$LogFile = Join-Path $PSScriptRoot "capture_$Timestamp.log"

function Write-Log {
    param(
        [string]$Message
    )

    $LogTimestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
    "[$LogTimestamp] $Message" |
        Out-File -FilePath $LogFile -Append -Encoding utf8
}

try {
    Write-Log '=== DF MEMORY ACQUISITION STARTED ==='

    # Read Wazuh Active Response input.
    Write-Log 'Waiting for Wazuh STDIN input.'

    $line = [Console]::In.ReadLine()

    if ([string]::IsNullOrWhiteSpace($line)) {
        throw 'Missing Wazuh active-response input.'
    }

    Write-Log "STDIN received. Length: $($line.Length)"

    # Parse JSON.
    $message = $line | ConvertFrom-Json -ErrorAction Stop

    Write-Log "JSON parsed. Command: $($message.command)"

    if ($message.command -ne 'add') {
        throw 'Unsupported active-response command.'
    }

    $argsList = @($message.parameters.extra_args)

    if ($argsList.Count -lt 2 -or $argsList.Count -gt 3) {
        throw 'Expected case ID, analyst ID, and optional public key.'
    }

    # Support both key=value and positional arguments.
    $ticket = ''
    $analyst = ''
    $pubkey = ''

    $isKeyValue = @($argsList | Where-Object { $_ -match '=' }).Count -gt 0

    if ($isKeyValue) {
        $parsedArgs = @{}

        foreach ($arg in $argsList) {
            $parts = [string]$arg -split '=', 2

            if ($parts.Count -ne 2) {
                throw 'Mixed or invalid argument format.'
            }

            $parsedArgs[$parts[0]] = $parts[1]
        }

        $ticket = [string]$parsedArgs['case_id']
        $analyst = [string]$parsedArgs['analyst_id']

        if ($parsedArgs.ContainsKey('pubkey')) {
            $pubkey = [string]$parsedArgs['pubkey']
        }
    }
    else {
        $ticket = [string]$argsList[0]
        $analyst = [string]$argsList[1]

        if ($argsList.Count -eq 3) {
            $pubkey = [string]$argsList[2]
        }
    }

    Write-Log "Case ID received: $ticket"
    Write-Log "Analyst ID received: $analyst"
    Write-Log "Public key supplied: $($pubkey -ne '')"

    # Validate arguments.
    if ($ticket -notmatch '^[A-Za-z0-9][A-Za-z0-9._/-]{1,79}$') {
        throw 'Invalid case ID.'
    }

    if ($analyst -notmatch '^[A-Za-z0-9._@-]{2,100}$') {
        throw 'Invalid analyst identifier.'
    }

    if ($pubkey -ne '' -and $pubkey -notmatch '^(?:[0-9a-fA-F]{2}){32}$') {
        throw 'Invalid X25519 public key.'
    }

    Write-Log 'Input validation successful.'

    if (-not (Test-Path -LiteralPath $CaptureExe -PathType Leaf)) {
        throw "Capture executable not found: $CaptureExe"
    }

    Write-Log "Capture executable found: $CaptureExe"

    # Prepare WinPmem arguments.
    # Create a dedicated directory for this case.

    $OutputRoot = 'C:\DF\Acquisitions'
    $OutputDir = Join-Path $OutputRoot $ticket

    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

    Write-Log "Acquisition output directory: $OutputDir"

    $captureArgs = @(
      '--ticket', $ticket,
      '--analyst', $analyst,
      '--output', $OutputDir
    )

    if ($pubkey -ne '') {
      $captureArgs += @('--pubkey', $pubkey)
     }

    Write-Log 'Starting memory acquisition.'

    # Execute capture tool and collect its output.
    $captureOutput = @(& $CaptureExe @captureArgs 2>&1)

    # Capture the native executable exit code immediately.
    $captureExitCode = $LASTEXITCODE

    foreach ($outputLine in $captureOutput) {
        Write-Log "Capture output: $outputLine"
    }

    Write-Log "Capture executable exit code: $captureExitCode"

    if ($captureExitCode -ne 0) {
        throw "Memory capture failed with exit code $captureExitCode."
    }

    Write-Log 'Memory acquisition executable completed successfully.'
    Write-Log '=== DF MEMORY ACQUISITION COMPLETED ==='

    exit 0
}
catch {
    Write-Log "ERROR: $($_.Exception.Message)"
    Write-Log '=== DF MEMORY ACQUISITION FAILED ==='

    [Console]::Error.WriteLine(
        "DF memory response failed: $($_.Exception.Message)"
    )

    exit 1
}
