param(
    [string] $OutputDirectory = (Join-Path $PSScriptRoot 'exports'),
    [int] $MaximumScrolls = 500,
    [string] $ConversationTitle,
    [switch] $SkipImages,
    [switch] $ScreenCapture
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Web
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace KakaoExport {
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
    public static class Win32 {
        [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
        [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
        [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
        [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
        [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdcBlt, uint nFlags);
        [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
        [DllImport("user32.dll")] public static extern IntPtr SetProcessDpiAwarenessContext(IntPtr value);
    }
}
'@

function Set-ProcessDpiAwareness {
    try {
        if ([KakaoExport.Win32]::SetProcessDpiAwarenessContext([IntPtr](-4))) {
            return
        }
    }
    catch {
    }
    try {
        [void][KakaoExport.Win32]::SetProcessDPIAware()
    }
    catch {
    }
}
Set-ProcessDpiAwareness

function Find-ByAutomationId {
    param(
        [Windows.Automation.AutomationElement] $Root,
        [string] $AutomationId
    )

    $condition = New-Object Windows.Automation.PropertyCondition(
        [Windows.Automation.AutomationElement]::AutomationIdProperty,
        $AutomationId
    )
    return $Root.FindFirst(
        [Windows.Automation.TreeScope]::Descendants,
        $condition
    )
}

function Get-DescendantTexts {
    param([Windows.Automation.AutomationElement] $Element)

    $elements = $Element.FindAll(
        [Windows.Automation.TreeScope]::Descendants,
        [Windows.Automation.Condition]::TrueCondition
    )

    $result = @()
    for ($index = 0; $index -lt $elements.Count; $index++) {
        $child = $elements.Item($index)
        if (
            $child.Current.ControlType -eq [Windows.Automation.ControlType]::Text -and
            -not [string]::IsNullOrWhiteSpace($child.Current.Name)
        ) {
            $result += [PSCustomObject]@{
                AutomationId = $child.Current.AutomationId
                Text = $child.Current.Name
            }
        }
    }
    return $result
}

function Get-WindowFrame {
    param([IntPtr] $WindowHandle)

    $rectangle = New-Object KakaoExport.RECT
    if (-not [KakaoExport.Win32]::GetWindowRect($WindowHandle, [ref]$rectangle)) {
        return $null
    }
    $width = $rectangle.Right - $rectangle.Left
    $height = $rectangle.Bottom - $rectangle.Top
    if ($width -le 0 -or $height -le 0) {
        return $null
    }

    $bitmap = New-Object Drawing.Bitmap($width, $height)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    $captured = $false
    try {
        $hdc = $graphics.GetHdc()
        try {
            $captured = [KakaoExport.Win32]::PrintWindow($WindowHandle, $hdc, 2)
        }
        finally {
            $graphics.ReleaseHdc($hdc)
        }
    }
    finally {
        $graphics.Dispose()
    }

    if (-not $captured) {
        $bitmap.Dispose()
        return $null
    }
    return [PSCustomObject]@{
        Bitmap = $bitmap
        Left = $rectangle.Left
        Top = $rectangle.Top
    }
}

function Save-MessageImages {
    param(
        [Windows.Automation.AutomationElement] $Item,
        [string] $ImageDirectory,
        $Frame,
        [Drawing.Rectangle] $ViewportRectangle
    )

    if ($SkipImages) {
        return @()
    }

    $imageCondition = New-Object Windows.Automation.AndCondition(
        (
            New-Object Windows.Automation.PropertyCondition(
                [Windows.Automation.AutomationElement]::ControlTypeProperty,
                [Windows.Automation.ControlType]::Image
            )
        ),
        (
            New-Object Windows.Automation.PropertyCondition(
                [Windows.Automation.AutomationElement]::AutomationIdProperty,
                'NormalImageCtrl'
            )
        )
    )
    $elements = $Item.FindAll(
        [Windows.Automation.TreeScope]::Descendants,
        $imageCondition
    )
    $savedFiles = @()

    for ($index = 0; $index -lt $elements.Count; $index++) {
        $rectangle = $elements.Item($index).Current.BoundingRectangle
        $captureRectangle = [Drawing.Rectangle]::FromLTRB(
            [int][Math]::Round($rectangle.Left),
            [int][Math]::Round($rectangle.Top),
            [int][Math]::Round($rectangle.Right),
            [int][Math]::Round($rectangle.Bottom)
        )
        $captureRectangle.Intersect($ViewportRectangle)

        if ($captureRectangle.Width -lt 40 -or $captureRectangle.Height -lt 40) {
            continue
        }

        $bitmap = New-Object Drawing.Bitmap(
            $captureRectangle.Width,
            $captureRectangle.Height
        )
        $graphics = [Drawing.Graphics]::FromImage($bitmap)
        $stream = New-Object IO.MemoryStream

        try {
            if ($null -ne $Frame) {
                $sourceRectangle = [Drawing.Rectangle]::new(
                    $captureRectangle.X - $Frame.Left,
                    $captureRectangle.Y - $Frame.Top,
                    $captureRectangle.Width,
                    $captureRectangle.Height
                )
                $sourceRectangle.Intersect(
                    [Drawing.Rectangle]::new(
                        0, 0, $Frame.Bitmap.Width, $Frame.Bitmap.Height
                    )
                )
                if ($sourceRectangle.Width -lt 40 -or $sourceRectangle.Height -lt 40) {
                    continue
                }
                $graphics.DrawImage(
                    $Frame.Bitmap,
                    [Drawing.Rectangle]::new(
                        0, 0, $sourceRectangle.Width, $sourceRectangle.Height
                    ),
                    $sourceRectangle,
                    [Drawing.GraphicsUnit]::Pixel
                )
            }
            else {
                $graphics.CopyFromScreen(
                    $captureRectangle.Location,
                    [Drawing.Point]::Empty,
                    $captureRectangle.Size
                )
            }
            $bitmap.Save($stream, [Drawing.Imaging.ImageFormat]::Png)
            $bytes = $stream.ToArray()
            $sha = [Security.Cryptography.SHA256]::Create()
            try {
                $hash = (
                    $sha.ComputeHash($bytes) |
                        ForEach-Object { $_.ToString('x2') }
                ) -join ''
            }
            finally {
                $sha.Dispose()
            }

            $fileName = $hash + '.png'
            $filePath = Join-Path $ImageDirectory $fileName
            if (-not (Test-Path -LiteralPath $filePath)) {
                [IO.File]::WriteAllBytes($filePath, $bytes)
            }
            $savedFiles += $fileName
        }
        finally {
            $stream.Dispose()
            $graphics.Dispose()
            $bitmap.Dispose()
        }
    }

    return $savedFiles
}

function Get-MessageRecord {
    param(
        [Windows.Automation.AutomationElement] $Item,
        [string] $ImageDirectory,
        $Frame,
        [Drawing.Rectangle] $ViewportRectangle
    )

    $texts = @(Get-DescendantTexts $Item)
    $sender = @(
        $texts |
            Where-Object AutomationId -eq 'Txt_Name' |
            Select-Object -ExpandProperty Text
    ) -join ' '
    $body = @(
        $texts |
            Where-Object AutomationId -eq 'text' |
            Select-Object -ExpandProperty Text
    ) -join "`n"
    $translation = @(
        $texts |
            Where-Object AutomationId -eq 'translateText' |
            Select-Object -ExpandProperty Text
    ) -join "`n"
    $otherTexts = @(
        $texts |
            Where-Object {
                $_.AutomationId -notin @(
                    'Txt_Name',
                    'text',
                    'translateText',
                    'LeftDumy',
                    'RightDumy',
                    'unReadCountTextBlock'
                )
            } |
            Select-Object -ExpandProperty Text
    )
    $imageFiles = @(Save-MessageImages $Item $ImageDirectory $Frame $ViewportRectangle)

    $kind = if ($imageFiles.Count -gt 0) {
        'image'
    }
    elseif ($body -or $sender) {
        'message'
    }
    elseif ($otherTexts.Count -eq 1) {
        'separator'
    }
    else {
        'attachment-or-system'
    }

    $rawSignature = @(
        $kind,
        $sender,
        $body,
        $translation,
        ($otherTexts -join "`n"),
        ($imageFiles -join "`n"),
        $Item.Current.Name
    ) -join [char]31
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $signature = (
            $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($rawSignature)) |
                ForEach-Object { $_.ToString('x2') }
        ) -join ''
    }
    finally {
        $sha.Dispose()
    }

    return [PSCustomObject]@{
        Signature = $signature
        Kind = $kind
        Sender = $sender
        Body = $body
        Translation = $translation
        OtherTexts = $otherTexts
        ImageFiles = $imageFiles
    }
}

$process = Get-Process KakaoWork -ErrorAction Stop |
    Where-Object MainWindowHandle -ne 0 |
    Select-Object -First 1
if ($null -eq $process) {
    throw 'KakaoWork main window was not found.'
}

$windowHandle = $process.MainWindowHandle
if ([KakaoExport.Win32]::IsIconic($windowHandle)) {
    [void][KakaoExport.Win32]::ShowWindow($windowHandle, 9)  # SW_RESTORE
    Start-Sleep -Milliseconds 300
}
[void][KakaoExport.Win32]::ShowWindow($windowHandle, 3)      # SW_MAXIMIZE
[void][KakaoExport.Win32]::SetForegroundWindow($windowHandle)
Start-Sleep -Milliseconds 600

$root = [Windows.Automation.AutomationElement]::FromHandle(
    $windowHandle
)
$messageList = Find-ByAutomationId $root 'ConversationMessageListBox'
if ($null -eq $messageList) {
    throw 'Open a conversation before running the exporter.'
}

$titleView = Find-ByAutomationId $root 'ConversationTitleView'
$titleTexts = if ($null -ne $titleView) {
    @(Get-DescendantTexts $titleView | Select-Object -ExpandProperty Text)
}
else {
    @()
}
$detectedConversationTitle = if ($titleTexts.Count -gt 0) {
    $titleTexts |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Sort-Object Length -Descending |
        Select-Object -First 1
}
else {
    'KakaoWork conversation'
}
$exportTitle = if ([string]::IsNullOrWhiteSpace($ConversationTitle)) {
    $detectedConversationTitle
}
else {
    $ConversationTitle.Trim()
}

$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$safeTitle = ($exportTitle -replace '[\\/:*?"<>|]', '_').Trim()
if ([string]::IsNullOrWhiteSpace($safeTitle)) {
    $safeTitle = 'conversation'
}
$baseName = '{0}_{1}' -f $safeTitle, $timestamp

$scrollPattern = $messageList.GetCurrentPattern(
    [Windows.Automation.ScrollPattern]::Pattern
)

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$imageDirectoryName = $baseName + '_images'
$imageDirectory = Join-Path $OutputDirectory $imageDirectoryName
if (-not $SkipImages) {
    New-Item -ItemType Directory -Path $imageDirectory -Force | Out-Null
}
$checkpointPath = Join-Path $OutputDirectory '_selected_conversation_checkpoint.json'

if ($scrollPattern.Current.VerticallyScrollable) {
    $scrollPattern.SetScrollPercent(
        [Windows.Automation.ScrollPattern]::NoScroll,
        100
    )
    Start-Sleep -Seconds 1
}

$records = [Collections.Generic.List[object]]::new()
$known = [Collections.Generic.HashSet[string]]::new()
$topStableCount = 0
$previousCount = -1
$scrollCount = 0

while ($scrollCount -lt $MaximumScrolls) {
    Start-Sleep -Milliseconds 250
    $items = $messageList.FindAll(
        [Windows.Automation.TreeScope]::Children,
        (
            New-Object Windows.Automation.PropertyCondition(
                [Windows.Automation.AutomationElement]::ControlTypeProperty,
                [Windows.Automation.ControlType]::ListItem
            )
        )
    )

    $listRectangle = $messageList.Current.BoundingRectangle
    $viewportRectangle = [Drawing.Rectangle]::FromLTRB(
        [int][Math]::Round($listRectangle.Left),
        [int][Math]::Round($listRectangle.Top),
        [int][Math]::Round($listRectangle.Right),
        [int][Math]::Round($listRectangle.Bottom)
    )
    $viewportRectangle.Intersect([Windows.Forms.SystemInformation]::VirtualScreen)

    $frame = $null
    if (-not $SkipImages -and -not $ScreenCapture) {
        $frame = Get-WindowFrame $windowHandle
    }

    $newItems = [Collections.Generic.List[object]]::new()
    try {
        for ($index = 0; $index -lt $items.Count; $index++) {
            $record = Get-MessageRecord `
                $items.Item($index) $imageDirectory $frame $viewportRectangle
            if ($known.Add($record.Signature)) {
                $newItems.Add($record)
            }
        }
    }
    finally {
        if ($null -ne $frame) {
            $frame.Bitmap.Dispose()
        }
    }

    if ($newItems.Count -gt 0) {
        $records.InsertRange(0, $newItems)
    }

    $percent = $scrollPattern.Current.VerticalScrollPercent
    if ($percent -le 0) {
        if ($records.Count -eq $previousCount) {
            $topStableCount++
        }
        else {
            $topStableCount = 0
        }
        if ($topStableCount -ge 5) {
            break
        }
        $scrollPattern.Scroll(
            [Windows.Automation.ScrollAmount]::NoAmount,
            [Windows.Automation.ScrollAmount]::SmallDecrement
        )
        Start-Sleep -Milliseconds 800
    }
    else {
        $scrollPattern.Scroll(
            [Windows.Automation.ScrollAmount]::NoAmount,
            [Windows.Automation.ScrollAmount]::LargeDecrement
        )
        Start-Sleep -Milliseconds 800
    }

    $previousCount = $records.Count
    $scrollCount++

    if (($scrollCount % 25) -eq 0) {
        [PSCustomObject]@{
            ConversationTitle = $exportTitle
            DetectedConversationTitle = $detectedConversationTitle
            SavedAt = (Get-Date).ToString('o')
            RecordCount = $records.Count
            VerticalScrollPercent = $percent
            ScrollCount = $scrollCount
            RecordsOldestToNewest = @($records)
        } | ConvertTo-Json -Depth 6 |
            Set-Content -LiteralPath $checkpointPath -Encoding UTF8

        Write-Progress `
            -Activity 'Exporting KakaoWork conversation' `
            -Status "$($records.Count) records collected" `
            -PercentComplete ([Math]::Max(0, 100 - [int]$percent))
    }
}

$ordered = @($records)
[array]::Reverse($ordered)

$jsonPath = Join-Path $OutputDirectory ($baseName + '.json')
$htmlPath = Join-Path $OutputDirectory ($baseName + '.html')

$export = [PSCustomObject]@{
    ConversationTitle = $exportTitle
    DetectedConversationTitle = $detectedConversationTitle
    ExportedAt = (Get-Date).ToString('o')
    RecordCount = $ordered.Count
    ReachedStableTop = ($topStableCount -ge 5)
    ScrollCount = $scrollCount
    Records = $ordered
}
$export | ConvertTo-Json -Depth 6 |
    Set-Content -LiteralPath $jsonPath -Encoding UTF8

$builder = [Text.StringBuilder]::new()
[void]$builder.AppendLine('<!doctype html>')
[void]$builder.AppendLine('<html lang="ko"><head><meta charset="utf-8">')
[void]$builder.AppendLine('<meta name="viewport" content="width=device-width,initial-scale=1">')
[void]$builder.AppendLine('<style>')
[void]$builder.AppendLine('body{font-family:Segoe UI,Malgun Gothic,sans-serif;max-width:900px;margin:32px auto;padding:0 20px;background:#f5f6f8;color:#202124}')
[void]$builder.AppendLine('.message,.system{background:white;border:1px solid #ddd;border-radius:10px;padding:10px 14px;margin:8px 0}')
[void]$builder.AppendLine('.sender{font-weight:700}.body,.other{white-space:pre-wrap;margin-top:4px}.separator{text-align:center;color:#666;margin:20px 0}.meta{color:#777;font-size:12px}')
[void]$builder.AppendLine('</style></head><body>')
[void]$builder.AppendFormat(
    '<h1>{0}</h1><p class="meta">Exported {1} | Records {2}</p>',
    [Web.HttpUtility]::HtmlEncode($exportTitle),
    [Web.HttpUtility]::HtmlEncode((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')),
    $ordered.Count
)

foreach ($record in $ordered) {
    if ($record.Kind -eq 'separator') {
        [void]$builder.AppendFormat(
            '<div class="separator">{0}</div>',
            [Web.HttpUtility]::HtmlEncode(($record.OtherTexts -join ' '))
        )
        continue
    }

    $cssClass = if ($record.Kind -eq 'message') { 'message' } else { 'system' }
    [void]$builder.AppendFormat('<div class="{0}">', $cssClass)
    if ($record.Sender) {
        [void]$builder.AppendFormat(
            '<div class="sender">{0}</div>',
            [Web.HttpUtility]::HtmlEncode($record.Sender)
        )
    }
    if ($record.Body) {
        [void]$builder.AppendFormat(
            '<div class="body">{0}</div>',
            [Web.HttpUtility]::HtmlEncode($record.Body)
        )
    }
    if ($record.Translation) {
        [void]$builder.AppendFormat(
            '<div class="body">{0}</div>',
            [Web.HttpUtility]::HtmlEncode($record.Translation)
        )
    }
    foreach ($imageFile in $record.ImageFiles) {
        $relativeImagePath = (
            $imageDirectoryName + '/' + $imageFile
        ).Replace('\', '/')
        [void]$builder.AppendFormat(
            '<div class="body"><img src="{0}" alt="KakaoWork image" style="max-width:100%;height:auto;border-radius:8px"></div>',
            [Web.HttpUtility]::HtmlAttributeEncode($relativeImagePath)
        )
    }
    if ($record.OtherTexts.Count -gt 0) {
        [void]$builder.AppendFormat(
            '<div class="other">{0}</div>',
            [Web.HttpUtility]::HtmlEncode(($record.OtherTexts -join "`n"))
        )
    }
    [void]$builder.AppendLine('</div>')
}

[void]$builder.AppendLine('</body></html>')
$builder.ToString() | Set-Content -LiteralPath $htmlPath -Encoding UTF8
Remove-Item -LiteralPath $checkpointPath -Force -ErrorAction SilentlyContinue
Write-Progress -Activity 'Exporting KakaoWork conversation' -Completed

[PSCustomObject]@{
    ConversationTitle = $exportTitle
    DetectedConversationTitle = $detectedConversationTitle
    RecordCount = $ordered.Count
    ReachedStableTop = ($topStableCount -ge 5)
    ScrollCount = $scrollCount
    JsonPath = $jsonPath
    HtmlPath = $htmlPath
    ImageDirectory = if ($SkipImages) { $null } else { $imageDirectory }
    ImageCount = if ($SkipImages) {
        0
    }
    else {
        @(Get-ChildItem -LiteralPath $imageDirectory -Filter '*.png').Count
    }
}
