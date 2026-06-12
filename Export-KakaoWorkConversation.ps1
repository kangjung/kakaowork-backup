param(
    [string] $OutputDirectory = (Join-Path $PSScriptRoot 'exports'),
    [int] $MaximumScrolls = 500,
    [int] $ScrollDelayMilliseconds = 700,
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

$script:TextCacheRequest = New-Object Windows.Automation.CacheRequest
$script:TextCacheRequest.Add(
    [Windows.Automation.AutomationElement]::NameProperty
)
$script:TextCacheRequest.Add(
    [Windows.Automation.AutomationElement]::AutomationIdProperty
)
$script:TextCondition = New-Object Windows.Automation.PropertyCondition(
    [Windows.Automation.AutomationElement]::ControlTypeProperty,
    [Windows.Automation.ControlType]::Text
)

function Get-DescendantTexts {
    param([Windows.Automation.AutomationElement] $Element)

    # Only Text controls are needed, and Name/AutomationId are fetched in a
    # single batched cross-process call via the cache request. Walking the whole
    # subtree with per-element .Current.* reads was the main bottleneck.
    $result = @()
    $activation = $script:TextCacheRequest.Activate()
    try {
        $elements = $Element.FindAll(
            [Windows.Automation.TreeScope]::Descendants,
            $script:TextCondition
        )
        for ($index = 0; $index -lt $elements.Count; $index++) {
            $child = $elements.Item($index)
            $text = $child.Cached.Name
            if (-not [string]::IsNullOrWhiteSpace($text)) {
                $result += [PSCustomObject]@{
                    AutomationId = $child.Cached.AutomationId
                    Text = $text
                }
            }
        }
    }
    finally {
        $activation.Dispose()
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

function ConvertTo-PixelRectangle {
    # UI Automation reports an empty/unrendered element's BoundingRectangle with
    # infinite or NaN edges. Converting those to Int32 throws, so return $null
    # for such elements and let callers skip them.
    param($BoundingRectangle)

    $bounds = $BoundingRectangle
    if (
        $null -eq $bounds -or
        [double]::IsInfinity($bounds.Left) -or [double]::IsNaN($bounds.Left) -or
        [double]::IsInfinity($bounds.Top) -or [double]::IsNaN($bounds.Top) -or
        [double]::IsInfinity($bounds.Right) -or [double]::IsNaN($bounds.Right) -or
        [double]::IsInfinity($bounds.Bottom) -or [double]::IsNaN($bounds.Bottom)
    ) {
        return $null
    }
    return [Drawing.Rectangle]::FromLTRB(
        [int][Math]::Round($bounds.Left),
        [int][Math]::Round($bounds.Top),
        [int][Math]::Round($bounds.Right),
        [int][Math]::Round($bounds.Bottom)
    )
}

function Find-MessageImageControls {
    param([Windows.Automation.AutomationElement] $Item)

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
    $result = @()
    for ($index = 0; $index -lt $elements.Count; $index++) {
        $result += $elements.Item($index)
    }
    return $result
}

function Save-MessageImages {
    param(
        [Windows.Automation.AutomationElement[]] $ImageElements,
        [string] $ImageDirectory,
        $Frame,
        [Drawing.Rectangle] $ViewportRectangle
    )

    if ($SkipImages -or $null -eq $ImageElements) {
        return @()
    }

    $savedFiles = @()

    foreach ($element in $ImageElements) {
        $captureRectangle = ConvertTo-PixelRectangle $element.Current.BoundingRectangle
        if ($null -eq $captureRectangle) {
            continue
        }
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
        [hashtable] $FrameHolder,
        [Drawing.Rectangle] $ViewportRectangle,
        [hashtable] $Cache
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
    $rawOtherTexts = @(
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
    # KakaoWork timestamps (e.g. an "AM/PM h:mm" string) have no AutomationId, so
    # they fall into this catch-all bucket, where a lone time is mis-read as a
    # date divider and a time rendered once vs twice destabilises the de-dup
    # signature. Detect them with an ASCII-only rule (an h:mm time inside a short
    # string) so no Hangul literal is needed in the source - PowerShell 5.1 reads
    # .ps1 as the system code page and would corrupt literal Hangul. Move matches
    # to a dedicated Time field and de-duplicate the rest.
    $isTimeText = {
        param($value)
        $value -match '\d{1,2}:\d{2}' -and $value.Trim().Length -le 10
    }
    $time = (
        @($rawOtherTexts | Where-Object { & $isTimeText $_ }) |
            Select-Object -Unique
    ) -join ' '
    $otherTexts = @(
        $rawOtherTexts |
            Where-Object { -not (& $isTimeText $_) } |
            Select-Object -Unique
    )

    # Locate image controls without capturing yet. Their count, on-screen state
    # and properties let us build a stable cache key and decide whether this
    # item can be safely reused on a later scroll instead of re-captured.
    $imageElements = @(Find-MessageImageControls $Item)
    $imageMeta = @()
    $allImagesNamed = $true
    $allImagesFullyVisible = $true
    foreach ($element in $imageElements) {
        $name = $element.Current.Name
        if ([string]::IsNullOrWhiteSpace($name)) {
            $allImagesNamed = $false
        }
        $elementRectangle = ConvertTo-PixelRectangle $element.Current.BoundingRectangle
        if ($null -eq $elementRectangle) {
            # No on-screen bounds: cannot be reliably captured this pass, so
            # never treat the item as fully visible (do not cache it).
            $allImagesFullyVisible = $false
            $imageMeta += ('{0}|offscreen' -f $name)
            continue
        }
        if (-not $ViewportRectangle.Contains($elementRectangle)) {
            $allImagesFullyVisible = $false
        }
        $imageMeta += '{0}|{1}x{2}' -f `
            $name, $elementRectangle.Width, $elementRectangle.Height
    }

    # Reuse a cached record only when re-capturing is guaranteed to produce the
    # same result: no images, or every image is fully on screen AND has a
    # distinguishing Name. Items with clipped or unnamed images fall through to
    # capture on every pass (slower, but never loses or merges an image).
    $cacheable = ($imageElements.Count -eq 0) -or
        ($allImagesNamed -and $allImagesFullyVisible)
    $stableKey = @(
        $sender,
        $body,
        $translation,
        $time,
        ($otherTexts -join "`n"),
        $Item.Current.Name,
        ($imageMeta -join "`n")
    ) -join [char]31

    if ($cacheable -and $null -ne $Cache -and $Cache.ContainsKey($stableKey)) {
        return $Cache[$stableKey]
    }

    # Capture the window frame lazily: only the first time an item with images
    # actually needs it this pass, so image-free scrolls skip PrintWindow.
    if (
        $imageElements.Count -gt 0 -and
        -not $SkipImages -and -not $ScreenCapture -and
        $null -ne $FrameHolder -and $null -eq $FrameHolder.Frame
    ) {
        $FrameHolder.Frame = Get-WindowFrame $windowHandle
    }
    $frame = if ($null -ne $FrameHolder) { $FrameHolder.Frame } else { $null }
    $imageFiles = @(Save-MessageImages $imageElements $ImageDirectory $frame $ViewportRectangle)

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
        $time,
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

    $record = [PSCustomObject]@{
        Signature = $signature
        Kind = $kind
        Sender = $sender
        Body = $body
        Translation = $translation
        Time = $time
        OtherTexts = $otherTexts
        ImageFiles = $imageFiles
    }

    if ($cacheable -and $null -ne $Cache) {
        $Cache[$stableKey] = $record
    }
    return $record
}

function Get-KakaoWorkChatWindowHandle {
    # KakaoWork has several top-level windows and the process MainWindowHandle is
    # often NOT the chat window. Locate the window that actually contains the
    # conversation UI instead.
    $processIds = @(
        Get-Process KakaoWork -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty Id
    )
    if ($processIds.Count -eq 0) {
        return [IntPtr]::Zero
    }

    $windowCondition = New-Object Windows.Automation.PropertyCondition(
        [Windows.Automation.AutomationElement]::ControlTypeProperty,
        [Windows.Automation.ControlType]::Window
    )
    $messageListCondition = New-Object Windows.Automation.PropertyCondition(
        [Windows.Automation.AutomationElement]::AutomationIdProperty,
        'ConversationMessageListBox'
    )
    $roomListCondition = New-Object Windows.Automation.PropertyCondition(
        [Windows.Automation.AutomationElement]::AutomationIdProperty,
        'ConversationListBox'
    )

    $desktop = [Windows.Automation.AutomationElement]::RootElement
    $windows = $desktop.FindAll(
        [Windows.Automation.TreeScope]::Children,
        $windowCondition
    )

    $fallbackHandle = [IntPtr]::Zero
    for ($index = 0; $index -lt $windows.Count; $index++) {
        $window = $windows.Item($index)
        if ($window.Current.ProcessId -notin $processIds) {
            continue
        }
        # Prefer the window that actually holds an open conversation.
        if ($null -ne $window.FindFirst(
                [Windows.Automation.TreeScope]::Descendants, $messageListCondition)) {
            return [IntPtr]$window.Current.NativeWindowHandle
        }
        if (
            $fallbackHandle -eq [IntPtr]::Zero -and
            $null -ne $window.FindFirst(
                [Windows.Automation.TreeScope]::Descendants, $roomListCondition)
        ) {
            $fallbackHandle = [IntPtr]$window.Current.NativeWindowHandle
        }
    }
    return $fallbackHandle
}

$windowHandle = Get-KakaoWorkChatWindowHandle
if ($windowHandle -eq [IntPtr]::Zero) {
    throw 'KakaoWork main window was not found.'
}

# KakaoWork is brought to the foreground and maximized so its messages and
# images render reliably for reading and capture. Each scroll re-activates this
# window, so the computer cannot be used for other work while the export runs.
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

# A stop request is signalled by creating this file (the HTA's stop button does
# so). The export then finishes gracefully with whatever has been collected.
$stopSignalPath = Join-Path $OutputDirectory '_stop_requested.flag'
Remove-Item -LiteralPath $stopSignalPath -Force -ErrorAction SilentlyContinue

if ($scrollPattern.Current.VerticallyScrollable) {
    $scrollPattern.SetScrollPercent(
        [Windows.Automation.ScrollPattern]::NoScroll,
        100
    )
    Start-Sleep -Seconds 1
}

$records = [Collections.Generic.List[object]]::new()
$known = [Collections.Generic.HashSet[string]]::new()
$recordCache = @{}
$topStableCount = 0
$previousCount = -1
$scrollCount = 0
$stopped = $false

while ($scrollCount -lt $MaximumScrolls) {
    if (Test-Path -LiteralPath $stopSignalPath) {
        Remove-Item -LiteralPath $stopSignalPath -Force -ErrorAction SilentlyContinue
        $stopped = $true
        break
    }

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

    $frameHolder = @{ Frame = $null }

    $newItems = [Collections.Generic.List[object]]::new()
    try {
        for ($index = 0; $index -lt $items.Count; $index++) {
            $record = Get-MessageRecord `
                $items.Item($index) $imageDirectory $frameHolder $viewportRectangle $recordCache
            if ($known.Add($record.Signature)) {
                $newItems.Add($record)
            }
        }
    }
    finally {
        if ($null -ne $frameHolder.Frame) {
            $frameHolder.Frame.Bitmap.Dispose()
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
        Start-Sleep -Milliseconds $ScrollDelayMilliseconds
    }
    else {
        $scrollPattern.Scroll(
            [Windows.Automation.ScrollAmount]::NoAmount,
            [Windows.Automation.ScrollAmount]::LargeDecrement
        )
        Start-Sleep -Milliseconds $ScrollDelayMilliseconds
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
    StoppedEarly = $stopped
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
[void]$builder.AppendLine('.sender{font-weight:700}.body,.other{white-space:pre-wrap;margin-top:4px}.separator{text-align:center;color:#666;margin:20px 0}.meta{color:#777;font-size:12px}.time{color:#999;font-size:11px;margin-top:4px}')
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
    if ($record.Time) {
        [void]$builder.AppendFormat(
            '<div class="time">{0}</div>',
            [Web.HttpUtility]::HtmlEncode($record.Time)
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
    StoppedEarly = $stopped
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
