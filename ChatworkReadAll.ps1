# ChatworkReadAll.ps1
# Path: ChatworkReadAll.ps1
# Summary: Chatwork API token settings and a Windows confirmation dialog that marks unread rooms as read.

param(
    [switch]$Settings,
    [switch]$InstallStartup,
    [switch]$UninstallStartup,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'

$Script:AppName = 'Chatwork Read All'
$Script:ApiBaseUrl = 'https://api.chatwork.com/v2'
$Script:ConfigDir = Join-Path $env:APPDATA 'ChatworkReadAll'
$Script:ConfigPath = Join-Path $Script:ConfigDir 'config.json'
$Script:StartupShortcutName = 'Chatwork Read All.lnk'
$Script:ChatworkToken = $null
$Script:RateLimitRemaining = $null
$Script:RateLimitResetEpoch = $null
$Script:RequestCount = 0
$Script:GuiInitialized = $false

function Get-CurrentScriptPath {
    # Returns the script path used by the startup shortcut.
    if (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) {
        return $PSCommandPath
    }

    return $MyInvocation.MyCommand.Path
}

function Get-UnixTimeSeconds {
    # PowerShell 5.1 compatibility wrapper for Unix epoch seconds.
    return [int64](([DateTime]::UtcNow - [DateTime]'1970-01-01T00:00:00Z').TotalSeconds)
}

function Initialize-AppDirectory {
    # Creates the per-user application data directory if it does not exist.
    if (-not (Test-Path -LiteralPath $Script:ConfigDir)) {
        New-Item -ItemType Directory -Path $Script:ConfigDir | Out-Null
    }
}

function Read-AppConfig {
    # Reads persisted settings. API tokens are stored encrypted, not as plain text.
    if (-not (Test-Path -LiteralPath $Script:ConfigPath)) {
        return [pscustomobject]@{}
    }

    $raw = Get-Content -LiteralPath $Script:ConfigPath -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return [pscustomobject]@{}
    }

    return ConvertFrom-Json -InputObject $raw
}

function Save-ApiToken {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Token
    )

    # ConvertFrom-SecureString uses the current Windows user's DPAPI protection by default.
    Initialize-AppDirectory
    $secureToken = ConvertTo-SecureString -String $Token -AsPlainText -Force
    $config = [ordered]@{
        apiTokenProtected = ConvertFrom-SecureString -SecureString $secureToken
        savedAt = (Get-Date).ToString('o')
    }

    $config | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $Script:ConfigPath -Encoding UTF8
}

function Get-SavedApiToken {
    # Decrypts the API token for the current Windows user only.
    $config = Read-AppConfig
    if ($null -eq $config.PSObject.Properties['apiTokenProtected']) {
        return ''
    }

    $protectedToken = [string]$config.apiTokenProtected
    if ([string]::IsNullOrWhiteSpace($protectedToken)) {
        return ''
    }

    $secureToken = ConvertTo-SecureString -String $protectedToken
    $credential = New-Object System.Management.Automation.PSCredential('chatwork-token', $secureToken)
    return $credential.GetNetworkCredential().Password
}

function Initialize-Gui {
    # Loads Windows Forms once. The app is intentionally small and uses native Windows UI only.
    if ($Script:GuiInitialized) {
        return
    }

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()
    $Script:GuiInitialized = $true
}

function Get-StartupShortcutPath {
    # Resolves the current user's Startup folder shortcut path.
    $startupFolder = [Environment]::GetFolderPath('Startup')
    return Join-Path $startupFolder $Script:StartupShortcutName
}

function Install-StartupShortcut {
    # Registers this script to run at Windows sign-in for the current user.
    $scriptPath = Get-CurrentScriptPath
    if ([string]::IsNullOrWhiteSpace($scriptPath) -or -not (Test-Path -LiteralPath $scriptPath)) {
        throw 'Script path could not be resolved.'
    }

    $shortcutPath = Get-StartupShortcutPath
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = Join-Path $PSHOME 'powershell.exe'
    $shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""
    $shortcut.WorkingDirectory = Split-Path -Parent $scriptPath
    $shortcut.IconLocation = Join-Path $PSHOME 'powershell.exe'
    $shortcut.WindowStyle = 1
    $shortcut.Save()

    Write-Host "Startup shortcut installed: $shortcutPath"
}

function Uninstall-StartupShortcut {
    # Removes the current user's startup shortcut.
    $shortcutPath = Get-StartupShortcutPath
    if (Test-Path -LiteralPath $shortcutPath) {
        Remove-Item -LiteralPath $shortcutPath
        Write-Host "Startup shortcut removed: $shortcutPath"
        return
    }

    Write-Host "Startup shortcut was not found: $shortcutPath"
}

function Get-HeaderValue {
    param(
        $Headers,
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($null -eq $Headers) {
        return $null
    }

    try {
        $value = $Headers[$Name]
        if ($null -eq $value) {
            return $null
        }

        if ($value -is [array]) {
            return [string]$value[0]
        }

        return [string]$value
    }
    catch {
        return $null
    }
}

function Update-ChatworkRateLimit {
    param($Headers)

    # Tracks Chatwork's global API limit and pauses before the next call if needed.
    $remaining = Get-HeaderValue -Headers $Headers -Name 'x-ratelimit-remaining'
    $reset = Get-HeaderValue -Headers $Headers -Name 'x-ratelimit-reset'

    if ($remaining -match '^\d+$') {
        $Script:RateLimitRemaining = [int]$remaining
    }

    if ($reset -match '^\d+$') {
        $Script:RateLimitResetEpoch = [int64]$reset
    }
}

function Wait-ChatworkRateLimit {
    # Avoids knowingly sending a request while the API reports no remaining quota.
    if (($null -eq $Script:RateLimitRemaining) -or ($null -eq $Script:RateLimitResetEpoch)) {
        return
    }

    if ($Script:RateLimitRemaining -gt 2) {
        return
    }

    $waitSeconds = $Script:RateLimitResetEpoch - (Get-UnixTimeSeconds) + 2
    if ($waitSeconds -gt 0) {
        Start-Sleep -Seconds ([Math]::Min($waitSeconds, 300))
    }
}

function Read-WebResponseText {
    param($Response)

    if ($null -eq $Response) {
        return ''
    }

    try {
        $stream = $Response.GetResponseStream()
        if ($null -eq $stream) {
            return ''
        }

        $reader = New-Object System.IO.StreamReader($stream)
        return $reader.ReadToEnd()
    }
    catch {
        return ''
    }
}

function Convert-ChatworkErrorMessages {
    param([string]$ErrorText)

    if ([string]::IsNullOrWhiteSpace($ErrorText)) {
        return @()
    }

    try {
        $errorJson = ConvertFrom-Json -InputObject $ErrorText
        if ($null -ne $errorJson.PSObject.Properties['errors']) {
            return @($errorJson.errors | ForEach-Object { [string]$_ })
        }
    }
    catch {
        return @($ErrorText)
    }

    return @($ErrorText)
}

function Invoke-ChatworkRequest {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('GET', 'PUT')]
        [string]$Method,

        [Parameter(Mandatory = $true)]
        [string]$Path,

        [hashtable]$Body
    )

    # Sends one authenticated Chatwork API request. PUT bodies are form-urlencoded per current API rules.
    if ([string]::IsNullOrWhiteSpace($Script:ChatworkToken)) {
        return [pscustomobject]@{
            Success = $false
            StatusCode = 0
            Data = $null
            Errors = @('API token is not configured.')
            ErrorText = ''
        }
    }

    Wait-ChatworkRateLimit

    if ($Path -match '^https?://') {
        $uri = $Path
    }
    else {
        $uri = "$($Script:ApiBaseUrl)$Path"
    }

    $parameters = @{
        Uri = $uri
        Method = $Method
        Headers = @{ 'x-chatworktoken' = $Script:ChatworkToken }
        TimeoutSec = 30
        UseBasicParsing = $true
        ErrorAction = 'Stop'
    }

    if ($null -ne $Body) {
        $parameters.Body = $Body
        $parameters.ContentType = 'application/x-www-form-urlencoded'
    }

    try {
        $response = Invoke-WebRequest @parameters
        $Script:RequestCount++
        Update-ChatworkRateLimit -Headers $response.Headers

        $data = $null
        $content = [string]$response.Content
        if (([int]$response.StatusCode -ne 204) -and -not [string]::IsNullOrWhiteSpace($content)) {
            $data = ConvertFrom-Json -InputObject $content
        }

        return [pscustomobject]@{
            Success = $true
            StatusCode = [int]$response.StatusCode
            Data = $data
            Errors = @()
            ErrorText = ''
        }
    }
    catch {
        $webResponse = $_.Exception.Response
        $statusCode = 0
        $errorText = ''

        if ($null -ne $webResponse) {
            try {
                $statusCode = [int]$webResponse.StatusCode
            }
            catch {
                $statusCode = 0
            }

            Update-ChatworkRateLimit -Headers $webResponse.Headers
            $errorText = Read-WebResponseText -Response $webResponse
        }
        elseif ($null -ne $_.Exception.Message) {
            $errorText = $_.Exception.Message
        }

        return [pscustomobject]@{
            Success = $false
            StatusCode = $statusCode
            Data = $null
            Errors = Convert-ChatworkErrorMessages -ErrorText $errorText
            ErrorText = $errorText
        }
    }
}

function Get-ChatworkErrorSummary {
    param($Response)

    if (($null -ne $Response.Errors) -and (@($Response.Errors).Count -gt 0)) {
        return (@($Response.Errors) -join '; ')
    }

    if (-not [string]::IsNullOrWhiteSpace($Response.ErrorText)) {
        return $Response.ErrorText
    }

    return 'Unknown API error.'
}

function Assert-ChatworkSuccess {
    param(
        [Parameter(Mandatory = $true)]
        $Response,

        [Parameter(Mandatory = $true)]
        [string]$Operation
    )

    if ($Response.Success) {
        return
    }

    $message = Get-ChatworkErrorSummary -Response $Response
    throw "$Operation failed. HTTP $($Response.StatusCode): $message"
}

function Get-IntProperty {
    param(
        [Parameter(Mandatory = $true)]
        $Object,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if (($null -eq $Object) -or ($null -eq $Object.PSObject.Properties[$Name])) {
        return 0
    }

    $value = $Object.$Name
    if ($null -eq $value) {
        return 0
    }

    return [int]$value
}

function Test-AlreadyReadError {
    param($Response)

    # Chatwork returns 400 when the target message is already read; this is harmless in a race.
    if ($Response.StatusCode -ne 400) {
        return $false
    }

    $summary = Get-ChatworkErrorSummary -Response $Response
    return ($summary -match '(already|既読)')
}

function Test-ChatworkToken {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Token
    )

    # Validates the token with GET /me before saving it.
    $oldToken = $Script:ChatworkToken
    $Script:ChatworkToken = $Token

    try {
        $response = Invoke-ChatworkRequest -Method 'GET' -Path '/me'
        if (-not $response.Success) {
            return [pscustomobject]@{
                Success = $false
                Name = ''
                Message = Get-ChatworkErrorSummary -Response $response
            }
        }

        return [pscustomobject]@{
            Success = $true
            Name = [string]$response.Data.name
            Message = ''
        }
    }
    finally {
        $Script:ChatworkToken = $oldToken
    }
}

function Get-ChatworkStatus {
    # Returns own unread counts from GET /my/status.
    $response = Invoke-ChatworkRequest -Method 'GET' -Path '/my/status'
    Assert-ChatworkSuccess -Response $response -Operation 'GET /my/status'
    return $response.Data
}

function Get-ChatworkRooms {
    # Lists rooms visible to the token owner.
    $response = Invoke-ChatworkRequest -Method 'GET' -Path '/rooms'
    Assert-ChatworkSuccess -Response $response -Operation 'GET /rooms'
    return @($response.Data)
}

function Get-ChatworkLatestMessageId {
    param(
        [Parameter(Mandatory = $true)]
        [int64]$RoomId
    )

    # force=1 asks Chatwork for the latest messages instead of only API delta messages.
    $response = Invoke-ChatworkRequest -Method 'GET' -Path "/rooms/$RoomId/messages?force=1"
    if ($response.Success -and ($response.StatusCode -eq 204)) {
        return ''
    }

    Assert-ChatworkSuccess -Response $response -Operation "GET /rooms/$RoomId/messages"

    $messages = @($response.Data)
    if ($messages.Count -eq 0) {
        return ''
    }

    return [string]$messages[$messages.Count - 1].message_id
}

function Set-ChatworkRoomRead {
    param(
        [Parameter(Mandatory = $true)]
        $Room
    )

    # Marks one room read up to the latest message available through the API.
    $roomId = [int64]$Room.room_id
    $roomName = [string]$Room.name

    try {
        $latestMessageId = Get-ChatworkLatestMessageId -RoomId $roomId
        if ([string]::IsNullOrWhiteSpace($latestMessageId)) {
            return [pscustomobject]@{
                RoomId = $roomId
                RoomName = $roomName
                Status = 'Skipped'
                Message = 'No message was returned.'
            }
        }

        $response = Invoke-ChatworkRequest -Method 'PUT' -Path "/rooms/$roomId/messages/read" -Body @{ message_id = $latestMessageId }
        if ($response.Success) {
            return [pscustomobject]@{
                RoomId = $roomId
                RoomName = $roomName
                Status = 'Read'
                Message = $latestMessageId
            }
        }

        if (Test-AlreadyReadError -Response $response) {
            return [pscustomobject]@{
                RoomId = $roomId
                RoomName = $roomName
                Status = 'AlreadyRead'
                Message = 'Already read before this request completed.'
            }
        }

        return [pscustomobject]@{
            RoomId = $roomId
            RoomName = $roomName
            Status = 'Failed'
            Message = Get-ChatworkErrorSummary -Response $response
        }
    }
    catch {
        return [pscustomobject]@{
            RoomId = $roomId
            RoomName = $roomName
            Status = 'Failed'
            Message = $_.Exception.Message
        }
    }
}

function Mark-AllUnreadRoomsRead {
    # Reads room unread counters first, then marks only unread rooms to reduce API calls.
    $rooms = @(Get-ChatworkRooms)
    $unreadRooms = @($rooms | Where-Object { (Get-IntProperty -Object $_ -Name 'unread_num') -gt 0 })
    $results = New-Object System.Collections.Generic.List[object]

    foreach ($room in $unreadRooms) {
        $results.Add((Set-ChatworkRoomRead -Room $room))
        Start-Sleep -Milliseconds 150
    }

    $resultArray = @($results.ToArray())
    return [pscustomobject]@{
        TargetRooms = $unreadRooms.Count
        Results = $resultArray
        Read = @($resultArray | Where-Object { $_.Status -eq 'Read' }).Count
        AlreadyRead = @($resultArray | Where-Object { $_.Status -eq 'AlreadyRead' }).Count
        Skipped = @($resultArray | Where-Object { $_.Status -eq 'Skipped' }).Count
        Failed = @($resultArray | Where-Object { $_.Status -eq 'Failed' }).Count
        RequestCount = $Script:RequestCount
    }
}

function Show-TokenSettingsDialog {
    param([string]$ExistingToken)

    # Allows the user to save or replace the Chatwork API token.
    Initialize-Gui

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Chatwork APIキー設定'
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.ClientSize = New-Object System.Drawing.Size(520, 190)

    $description = New-Object System.Windows.Forms.Label
    $description.Location = New-Object System.Drawing.Point(16, 16)
    $description.Size = New-Object System.Drawing.Size(488, 42)
    $description.Text = 'Chatwork APIキーを入力してください。保存済みキーがある場合、空欄のまま保存すると既存キーを再利用します。'
    $form.Controls.Add($description)

    $label = New-Object System.Windows.Forms.Label
    $label.Location = New-Object System.Drawing.Point(16, 70)
    $label.Size = New-Object System.Drawing.Size(110, 24)
    $label.Text = 'APIキー'
    $form.Controls.Add($label)

    $tokenBox = New-Object System.Windows.Forms.TextBox
    $tokenBox.Location = New-Object System.Drawing.Point(130, 68)
    $tokenBox.Size = New-Object System.Drawing.Size(374, 24)
    $tokenBox.UseSystemPasswordChar = $true
    $form.Controls.Add($tokenBox)

    $saveButton = New-Object System.Windows.Forms.Button
    $saveButton.Location = New-Object System.Drawing.Point(298, 126)
    $saveButton.Size = New-Object System.Drawing.Size(96, 32)
    $saveButton.Text = '保存'
    $form.Controls.Add($saveButton)

    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Location = New-Object System.Drawing.Point(408, 126)
    $cancelButton.Size = New-Object System.Drawing.Size(96, 32)
    $cancelButton.Text = 'キャンセル'
    $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.Controls.Add($cancelButton)

    $form.AcceptButton = $saveButton
    $form.CancelButton = $cancelButton

    $saveButton.Add_Click({
        $candidateToken = $tokenBox.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($candidateToken)) {
            $candidateToken = $ExistingToken
        }

        if ([string]::IsNullOrWhiteSpace($candidateToken)) {
            [System.Windows.Forms.MessageBox]::Show(
                'APIキーを入力してください。',
                '入力不足',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            ) | Out-Null
            return
        }

        try {
            [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::WaitCursor
            $testResult = Test-ChatworkToken -Token $candidateToken
            if (-not $testResult.Success) {
                [System.Windows.Forms.MessageBox]::Show(
                    "APIキーの確認に失敗しました。`r`n$($testResult.Message)",
                    '接続失敗',
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Error
                ) | Out-Null
                return
            }

            Save-ApiToken -Token $candidateToken
            $Script:ChatworkToken = $candidateToken
            [System.Windows.Forms.MessageBox]::Show(
                "APIキーを保存しました。`r`nアカウント: $($testResult.Name)",
                '保存完了',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            ) | Out-Null
            $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $form.Close()
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show(
                "APIキーの保存に失敗しました。`r`n$($_.Exception.Message)",
                '保存失敗',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            ) | Out-Null
        }
        finally {
            [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::Default
        }
    })

    return $form.ShowDialog()
}

function Show-ConfirmationDialog {
    param($Status)

    # Presents the exact destructive-action confirmation before changing read state.
    Initialize-Gui
    $unreadRooms = Get-IntProperty -Object $Status -Name 'unread_room_num'
    $unreadMessages = Get-IntProperty -Object $Status -Name 'unread_num'
    $mentionMessages = Get-IntProperty -Object $Status -Name 'mention_num'

    $message = "すべて既読にしますか？`r`n`r`n"
    $message += "未読ルーム: $unreadRooms`r`n"
    $message += "未読メッセージ: $unreadMessages`r`n"
    $message += "自分宛て未読: $mentionMessages`r`n`r`n"
    $message += 'Yesを選ぶと、未読のある全チャットを最新メッセージまで既読にします。'

    return [System.Windows.Forms.MessageBox]::Show(
        $message,
        $Script:AppName,
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question,
        [System.Windows.Forms.MessageBoxDefaultButton]::Button2
    )
}

function Show-ResultDialog {
    param($Summary)

    # Reports the outcome without exposing the API token.
    Initialize-Gui
    $message = "既読化が完了しました。`r`n`r`n"
    $message += "対象ルーム: $($Summary.TargetRooms)`r`n"
    $message += "既読化: $($Summary.Read)`r`n"
    $message += "既読済み: $($Summary.AlreadyRead)`r`n"
    $message += "スキップ: $($Summary.Skipped)`r`n"
    $message += "失敗: $($Summary.Failed)"

    $failedRows = @($Summary.Results | Where-Object { $_.Status -eq 'Failed' } | Select-Object -First 5)
    if ($failedRows.Count -gt 0) {
        $message += "`r`n`r`n失敗の先頭:"
        foreach ($row in $failedRows) {
            $message += "`r`n- $($row.RoomName): $($row.Message)"
        }
    }

    $icon = [System.Windows.Forms.MessageBoxIcon]::Information
    if ($Summary.Failed -gt 0) {
        $icon = [System.Windows.Forms.MessageBoxIcon]::Warning
    }

    [System.Windows.Forms.MessageBox]::Show(
        $message,
        $Script:AppName,
        [System.Windows.Forms.MessageBoxButtons]::OK,
        $icon
    ) | Out-Null
}

function Start-InteractiveApp {
    # Main startup flow: settings if needed, confirmation, then read-all execution.
    Initialize-Gui

    try {
        $savedToken = Get-SavedApiToken
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            "保存済み設定を読み取れません。APIキーを再設定してください。`r`n$($_.Exception.Message)",
            '設定エラー',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
        $savedToken = ''
    }

    if ($Settings) {
        Show-TokenSettingsDialog -ExistingToken $savedToken | Out-Null
        return
    }

    if ([string]::IsNullOrWhiteSpace($savedToken)) {
        [System.Windows.Forms.MessageBox]::Show(
            '初回起動のため、Chatwork APIキーを設定してください。',
            $Script:AppName,
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null

        $settingsResult = Show-TokenSettingsDialog -ExistingToken ''
        if ($settingsResult -ne [System.Windows.Forms.DialogResult]::OK) {
            return
        }

        $savedToken = Get-SavedApiToken
    }

    $Script:ChatworkToken = $savedToken

    try {
        [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::WaitCursor
        $status = Get-ChatworkStatus
    }
    catch {
        [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::Default
        $choice = [System.Windows.Forms.MessageBox]::Show(
            "Chatwork APIに接続できません。APIキー設定を開きますか？`r`n$($_.Exception.Message)",
            '接続失敗',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Error,
            [System.Windows.Forms.MessageBoxDefaultButton]::Button1
        )

        if ($choice -eq [System.Windows.Forms.DialogResult]::Yes) {
            Show-TokenSettingsDialog -ExistingToken $savedToken | Out-Null
        }
        return
    }
    finally {
        [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::Default
    }

    $confirmResult = Show-ConfirmationDialog -Status $status
    if ($confirmResult -ne [System.Windows.Forms.DialogResult]::Yes) {
        return
    }

    try {
        [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::WaitCursor
        $summary = Mark-AllUnreadRoomsRead
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            "既読化に失敗しました。`r`n$($_.Exception.Message)",
            '実行失敗',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
        return
    }
    finally {
        [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::Default
    }

    Show-ResultDialog -Summary $summary
}

function Invoke-SelfTest {
    # Minimal non-network checks for parsing and local helper behavior.
    $fakeAlreadyRead = [pscustomobject]@{
        Success = $false
        StatusCode = 400
        Data = $null
        Errors = @('Already read message.')
        ErrorText = ''
    }

    if (-not (Test-AlreadyReadError -Response $fakeAlreadyRead)) {
        throw 'Already-read error detection failed.'
    }

    $fakeObject = [pscustomobject]@{ unread_num = 3 }
    if ((Get-IntProperty -Object $fakeObject -Name 'unread_num') -ne 3) {
        throw 'Integer property conversion failed.'
    }

    if ([string]::IsNullOrWhiteSpace((Get-StartupShortcutPath))) {
        throw 'Startup shortcut path resolution failed.'
    }

    Write-Host 'SelfTest OK'
}

if ($SelfTest) {
    Invoke-SelfTest
    return
}

if ($InstallStartup) {
    Install-StartupShortcut
    return
}

if ($UninstallStartup) {
    Uninstall-StartupShortcut
    return
}

Start-InteractiveApp
