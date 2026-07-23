# ChatworkReadAll.ps1
# Path: ChatworkReadAll.ps1
# Summary: Chatwork API token settings and a Windows confirmation dialog that marks unread rooms as read.
#
# 機能概要:
# - Windows 10/11標準のWindows PowerShell 5.1とWindows Formsだけで動作する。
# - Chatwork APIキーをDPAPIで現在のWindowsユーザー向けに暗号化し、%APPDATA%配下へ保存する。
# - 任意のタイミングで起動された時だけ未読数を取得し、確認ダイアログで「はい」が選ばれた場合だけ既読化する。
# - Chatwork APIの仕様に合わせ、PUTパラメーターはURLクエリではなくフォームボディで送信する。

param(
    # APIキー設定画面だけを開く。通常実行時は未読確認と既読化確認まで行う。
    [switch]$Settings,
    # ネットワーク通信を行わず、配布前にローカル補助関数の最低限の動作を確認する。
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'

# アプリ全体で共有する固定値と実行時状態。APIキーは起動後に復号し、画面やログには出さない。
$Script:AppName = 'Chatwork Read All'
$Script:ApiBaseUrl = 'https://api.chatwork.com/v2'
$Script:ConfigDir = Join-Path $env:APPDATA 'ChatworkReadAll'
$Script:ConfigPath = Join-Path $Script:ConfigDir 'config.json'
$Script:ChatworkToken = $null
$Script:RateLimitRemaining = $null
$Script:RateLimitResetEpoch = $null
$Script:RequestCount = 0
$Script:GuiInitialized = $false

function Get-UnixTimeSeconds {
    # Chatwork APIのレート制限リセット時刻はUnix秒で返るため、現在時刻をUnix秒に変換する。
    # Windows PowerShell 5.1でも確実に動くよう、DateTimeOffsetではなくUTC基準時との差分で算出する。
    return [int64](([DateTime]::UtcNow - [DateTime]'1970-01-01T00:00:00Z').TotalSeconds)
}

function Initialize-AppDirectory {
    # APIキー設定ファイルの保存先を作成する。
    # 秘密情報をZIP展開先へ置かず、ユーザーごとの %APPDATA% 配下へ分離して保存する。
    if (-not (Test-Path -LiteralPath $Script:ConfigDir)) {
        New-Item -ItemType Directory -Path $Script:ConfigDir | Out-Null
    }
}

function Read-AppConfig {
    # 保存済み設定をJSONとして読み込む。
    # 初回起動や空ファイルでは空オブジェクトを返し、呼び出し側でAPIキー設定画面へ誘導する。
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

    # ConvertFrom-SecureStringはキー未指定の場合、現在のWindowsユーザーに紐づくDPAPIで暗号化する。
    # 設定ファイルを別ユーザーや別端末へコピーしても、そのままAPIキーを復号できないようにする。
    Initialize-AppDirectory
    $secureToken = ConvertTo-SecureString -String $Token -AsPlainText -Force
    $config = [ordered]@{
        apiTokenProtected = ConvertFrom-SecureString -SecureString $secureToken
        savedAt = (Get-Date).ToString('o')
    }

    $config | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $Script:ConfigPath -Encoding UTF8
}

function Get-SavedApiToken {
    # 保存済みAPIキーを現在のWindowsユーザー権限で復号する。
    # 未設定の場合は空文字を返し、通常実行フロー側で初回設定ダイアログを表示する。
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
    # Windows Formsを一度だけ読み込み、設定画面と確認ダイアログを表示できる状態にする。
    # 外部GUIフレームワークを使わず、Windows 10/11標準機能だけで配布できるようにする。
    if ($Script:GuiInitialized) {
        return
    }

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()
    $Script:GuiInitialized = $true
}

function Get-HeaderValue {
    param(
        $Headers,
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    # Invoke-WebRequestのHeadersは配列・単一値・nullの差が出るため、安全に文字列へ正規化する。
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

    # Chatwork APIのレスポンスヘッダーから残りリクエスト数とリセット時刻を記録する。
    # 後続のWait-ChatworkRateLimitでこの値を使い、429エラーを意図的に避ける。
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
    # 直前のAPIレスポンスで残り回数が少ない場合、リセット時刻まで待機する。
    # 一括既読はルーム数に応じてAPI呼び出しが増えるため、大量ルームでも制限に配慮する。
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

    # APIエラー時のレスポンス本文を読み、Chatworkのerrors配列や通信エラー内容をユーザー表示に使えるようにする。
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

    # Chatwork APIはエラー時に {"errors":[...]} 形式を返すため、配列部分だけを取り出す。
    # JSONではない本文の場合は、その本文を1件のエラー文として扱う。
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

    # Chatwork APIへの共通リクエスト処理。
    # 認証ヘッダー付与、レート制限待機、JSON変換、HTTPエラー整形をここに集約する。
    # 既読化APIのmessage_idは現在の仕様に合わせ、クエリではなくフォームボディで送信する。
    if ([string]::IsNullOrWhiteSpace($Script:ChatworkToken)) {
        return [pscustomobject]@{
            Success = $false
            StatusCode = 0
            Data = $null
            Errors = @('API token is not configured.')
            ErrorText = ''
        }
    }

    # 前回レスポンスでAPI残数が逼迫していた場合は、ここで待機してから次のリクエストを送る。
    Wait-ChatworkRateLimit

    # 通常は /rooms のような相対パスを受け取り、必要に応じて完全URLにも対応できるようにする。
    if ($Path -match '^https?://') {
        $uri = $Path
    }
    else {
        $uri = "$($Script:ApiBaseUrl)$Path"
    }

    # APIキーは公式仕様どおり x-chatworktoken ヘッダーへ設定し、URLには含めない。
    $parameters = @{
        Uri = $uri
        Method = $Method
        Headers = @{ 'x-chatworktoken' = $Script:ChatworkToken }
        TimeoutSec = 30
        UseBasicParsing = $true
        ErrorAction = 'Stop'
    }

    # PUTリクエストのフォーム値をボディとして送る。既読化APIのmessage_idはこの経路を通る。
    if ($null -ne $Body) {
        $parameters.Body = $Body
        $parameters.ContentType = 'application/x-www-form-urlencoded'
    }

    try {
        # Invoke-WebRequestはHTTP 4xx/5xxを例外として投げるため、成功レスポンスだけここでJSON化する。
        $response = Invoke-WebRequest @parameters
        $Script:RequestCount++
        Update-ChatworkRateLimit -Headers $response.Headers

        $data = $null
        $content = [string]$response.Content
        # GET /messages はメッセージなしの場合204を返すため、204ではJSON変換しない。
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
        # 失敗時もHTTPステータスとChatworkのerrors配列を保持し、権限不足・既読済み等を後段で判定できるようにする。
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

    # APIレスポンスからダイアログ表示向けの短いエラー文を作る。errors配列を優先し、なければ生本文を使う。
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

    # 取得系APIの失敗は後続処理を続けられないため、ここで例外化して上位のエラーダイアログへ流す。
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

    # Chatwork APIの未読数プロパティが欠けていても処理を止めず、0として扱う。
    # 型差を吸収し、未読ルーム抽出でエラーを起こしにくくする。
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

    # Chatworkは指定メッセージが既に既読の場合に400を返す。
    # 他クライアント操作との競合では正常扱いできるため、専用判定として切り出す。
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

    # APIキー保存前に GET /me で実際に認証できるか確認する。
    # 無効なキーを保存すると通常実行時に毎回失敗するため、設定画面の時点で検出する。
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
    # GET /my/status で、自分の未読ルーム数・未読メッセージ数・自分宛て未読数を取得する。
    # この値は確認ダイアログへ表示し、実行前に影響範囲を判断できるようにする。
    $response = Invoke-ChatworkRequest -Method 'GET' -Path '/my/status'
    Assert-ChatworkSuccess -Response $response -Operation 'GET /my/status'
    return $response.Data
}

function Get-ChatworkRooms {
    # GET /rooms で、APIキー所有者が参加しているチャット一覧を取得する。
    # 全チャット一括既読APIはないため、この一覧から未読のあるルームだけを個別処理する。
    $response = Invoke-ChatworkRequest -Method 'GET' -Path '/rooms'
    Assert-ChatworkSuccess -Response $response -Operation 'GET /rooms'
    return @($response.Data)
}

function Get-ChatworkLatestMessageId {
    param(
        [Parameter(Mandatory = $true)]
        [int64]$RoomId
    )

    # 既読化APIは「どのmessage_idまで既読にするか」を要求するため、対象ルームの最新メッセージIDを取得する。
    # force=1を指定し、前回API取得分との差分ではなく最新100件から末尾のmessage_idを使う。
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

    # 1ルーム分の既読化処理。
    # 最新メッセージIDを取得し、そのIDまでを PUT /messages/read で既読にする。
    # 失敗しても全体を止めず、ルーム単位の結果として最後の結果ダイアログに集約する。
    $roomId = [int64]$Room.room_id
    $roomName = [string]$Room.name

    try {
        # メッセージが取得できないルームは既読化対象IDを決められないため、スキップとして記録する。
        $latestMessageId = Get-ChatworkLatestMessageId -RoomId $roomId
        if ([string]::IsNullOrWhiteSpace($latestMessageId)) {
            return [pscustomobject]@{
                RoomId = $roomId
                RoomName = $roomName
                Status = 'Skipped'
                Message = 'No message was returned.'
            }
        }

        # 既読化対象IDはフォームボディで送る。クエリ送信は現在のChatwork API仕様に合わない。
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
    # 全体の一括既読処理。
    # 参加ルーム一覧の unread_num を見て、未読があるルームだけを処理し、API利用回数と実行時間を抑える。
    $rooms = @(Get-ChatworkRooms)
    $unreadRooms = @($rooms | Where-Object { (Get-IntProperty -Object $_ -Name 'unread_num') -gt 0 })
    $results = New-Object System.Collections.Generic.List[object]

    # ルームごとに順次処理する。短い待機を入れ、連続リクエストによる制限到達を多少緩和する。
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

    # Chatwork APIキーの新規保存・差し替え用ダイアログを表示する。
    # 空欄保存時は既存キーを再利用し、誤って保存済みキーを消さない動きにする。
    Initialize-Gui

    # 固定サイズのシンプルな設定画面にし、Windows 10/11標準ダイアログとして扱いやすくする。
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

    # APIキーは画面上でも伏せ字にする。保存時にも平文ではファイルへ書かない。
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

    # 保存ボタン押下時は、入力確認、Chatwork APIでの認証確認、DPAPI暗号化保存を順に実施する。
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

    # 既読化は取り消しが難しい操作なので、実行直前に必ず確認する。
    # 自分宛て未読数も表示し、重要な未読が含まれる可能性を判断できるようにする。
    Initialize-Gui
    $unreadRooms = Get-IntProperty -Object $Status -Name 'unread_room_num'
    $unreadMessages = Get-IntProperty -Object $Status -Name 'unread_num'
    $mentionMessages = Get-IntProperty -Object $Status -Name 'mention_num'

    $message = "すべて既読にしますか？`r`n`r`n"
    $message += "未読ルーム: $unreadRooms`r`n"
    $message += "未読メッセージ: $unreadMessages`r`n"
    $message += "自分宛て未読: $mentionMessages`r`n`r`n"
    $message += '「はい」を選ぶと、未読のある全チャットを最新メッセージまで既読にします。'

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

    # 一括既読の実行結果を集約して表示する。
    # APIキーやメッセージ本文は表示せず、処理件数と失敗理由だけを示す。
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
    # 通常実行時のメインフロー。
    # 設定読み込み、初回設定誘導、未読状況取得、確認、既読化、結果表示を順に行う。
    # Windows起動時の自動実行や常駐は行わず、利用者がChatworkReadAll.cmdを実行したタイミングだけ動作する。
    Initialize-Gui

    # 保存済み設定が壊れている場合でもアプリを終了せず、再設定へ誘導する。
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

    # Settings.cmd経由では既読化を行わず、APIキー設定画面だけを開いて終了する。
    if ($Settings) {
        Show-TokenSettingsDialog -ExistingToken $savedToken | Out-Null
        return
    }

    # 初回起動時はAPIキーがないため、通常実行でも設定画面を先に表示する。
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

    # 確認ダイアログに表示する未読数を取得する。API接続失敗時は設定再確認へ誘導する。
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

    # 利用者が「はい」を選んだ場合だけ既読化を実行する。「いいえ」ではPUTを呼ばず終了する。
    $confirmResult = Show-ConfirmationDialog -Status $status
    if ($confirmResult -ne [System.Windows.Forms.DialogResult]::Yes) {
        return
    }

    # 各ルームの既読化を実行し、最後に結果ダイアログとして集計を表示する。
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
    # 配布前確認用の軽量テスト。
    # ネットワークやChatwork APIキーを使わず、ローカル補助関数の最低限の動作だけを見る。
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

    Write-Host 'SelfTest OK'
}

# -SelfTest指定時はGUIやAPI通信を行わず、ローカル検証だけで終了する。
if ($SelfTest) {
    Invoke-SelfTest
    return
}

# 通常実行または -Settings 指定時は、Windows Formsの画面を使った対話フローへ進む。
Start-InteractiveApp
