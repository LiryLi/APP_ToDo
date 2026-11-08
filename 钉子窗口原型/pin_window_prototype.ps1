#requires -version 5.1
<#
桌面ToDo · Windows 钉子窗口原型（R11 钉子模式）— PowerShell + WPF 版
====================================================================

演示「电脑端钉子窗口」的核心系统级行为：

  1. 钉住       窗口无边框、置顶常驻桌面，进入只读态（不可添加 / 不可编辑）
  2. 悬停穿透   鼠标悬停在窗口上时整体透明度 50%，且鼠标点击穿透到下方的桌面 / 窗口
  3. 放大折叠   钉住态可展开为完整清单，或折叠为一行常驻小条（只显示最上面一条未完成）
  4. 取消钉住   恢复为普通窗口：可编辑、不可穿透、不再强制置顶

钉住态的交互方式：

  Ctrl + Alt + P     钉住 / 取消钉住
  Ctrl + Alt + E     展开 / 折叠（钉住态）
  双击窗口           折叠 / 展开（钉住态；鼠标移入后约 0.3 秒内有效，
                     之后进入穿透态，移出再移入可再次双击）

运行：
  双击同目录「启动钉子窗口.cmd」，或
  powershell -NoProfile -ExecutionPolicy Bypass -File .\pin_window_prototype.ps1
自检：
  powershell -NoProfile -ExecutionPolicy Bypass -File .\pin_window_prototype.ps1 -Selftest
  （自检会用 SetCursorPos / mouse_event 短暂移动鼠标并模拟双击）
数据：
  同目录 todos.json（首次运行自动生成示例数据）
排障：
  同目录 tick_error.log（轮询循环异常时自动追加）

技术要点（可迁移到正式客户端）：
  - 置顶:       WPF Window.Topmost（Win32 HWND_TOPMOST）
  - 悬停穿透:   WS_EX_LAYERED | WS_EX_TRANSPARENT 扩展样式 + Window.Opacity 0.5
  - 穿透态检测: 鼠标轮询（GetCursorPos 与 GetWindowRect 比较），
                穿透开启后窗口收不到任何鼠标事件，只能靠轮询感知光标位置
  - 双击折叠:   移入后有 300ms 缓冲期（此期间点击落在窗口上，可双击折叠）；
                悬停满 300ms 后进入穿透；单击后 500ms 内保持可点（等待第二击）
#>
[CmdletBinding()]
param([switch]$Selftest)

$ErrorActionPreference = 'Stop'

# ---------------- Win32 互操作 ----------------
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$win32cs = @'
using System;
using System.Runtime.InteropServices;
public static class Win32Pin
{
    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int x; public int y; }
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int left, top, right, bottom; }
    [DllImport("user32.dll")] public static extern int  GetWindowLong(IntPtr h, int i);
    [DllImport("user32.dll")] public static extern int  SetWindowLong(IntPtr h, int i, int v);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int k);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
}
'@
Add-Type -TypeDefinition $win32cs

$GWL_EXSTYLE       = -20
$WS_EX_LAYERED     = 0x00080000
$WS_EX_TRANSPARENT  = 0x00000020
$VK_CONTROL, $VK_MENU, $VK_P, $VK_E = 0x11, 0x12, 0x50, 0x45
$HOVER_ALPHA = 0.5
$DWELL_MS    = 300    # 光标移入后多久进入穿透（此期间可双击折叠）
$ABSORB_MS   = 500    # 单击后保持可点击多久（等待可能的第二击）

$script:BrushConv = New-Object System.Windows.Media.BrushConverter
function B([string]$hex) { $script:BrushConv.ConvertFromString($hex) }

# ---------------- 界面（XAML） ----------------
$xamlText = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="桌面ToDo · 钉子窗口原型"
        Width="400" Height="500" WindowStartupLocation="Manual"
        Background="#1f2127" FontFamily="Microsoft YaHei UI" FontSize="12"
        ResizeMode="CanResize" WindowStyle="SingleBorderWindow">
    <Border Background="#1f2127" Padding="10">
        <Grid>
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>

            <!-- 0 头部 -->
            <DockPanel Grid.Row="0">
                <StackPanel DockPanel.Dock="Left" Orientation="Horizontal">
                    <TextBlock Text="桌面ToDo" FontSize="14" FontWeight="Bold" Foreground="#e8eaf0" VerticalAlignment="Center"/>
                    <TextBlock Text=" 钉子窗口原型" FontSize="10" Foreground="#98a0ad" VerticalAlignment="Center" Margin="4,2,0,0"/>
                </StackPanel>
                <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
                    <Button x:Name="BtnPin" Content="📌 钉住" Background="#5b8cff" Foreground="White"
                            BorderThickness="0" FontSize="11" Padding="12,4" Margin="0,0,4,0" Cursor="Hand"/>
                    <Button x:Name="BtnClose" Content="✕" Background="#1f2127" Foreground="#98a0ad"
                            BorderThickness="0" FontSize="10" Padding="8,3" Cursor="Hand"/>
                </StackPanel>
                <TextBlock/>
            </DockPanel>

            <!-- 1 钉住态提示条 -->
            <DockPanel x:Name="HintBar" Grid.Row="1" Margin="0,8,0,2" Visibility="Collapsed">
                <TextBlock Text="已钉住 · 只读 · 双击折叠" Foreground="#5b8cff" FontSize="11" VerticalAlignment="Center"/>
                <TextBlock Text="Ctrl+Alt+P 取消 · Ctrl+Alt+E 折叠" Foreground="#98a0ad" FontSize="9"
                           HorizontalAlignment="Right" VerticalAlignment="Center"/>
            </DockPanel>

            <!-- 2 添加行（仅普通模式，钉住态不可添加） -->
            <DockPanel x:Name="AddPanel" Grid.Row="2" Margin="0,10,0,8">
                <Button x:Name="BtnAdd" DockPanel.Dock="Right" Content="添加" Background="#5b8cff" Foreground="White"
                        BorderThickness="0" FontSize="11" Padding="12,5" Margin="8,0,0,0" Cursor="Hand"/>
                <TextBox x:Name="InputBox" Background="#262932" Foreground="#e8eaf0" BorderThickness="0"
                         Padding="8,6" FontSize="12" VerticalContentAlignment="Center" CaretBrush="#e8eaf0"/>
            </DockPanel>

            <!-- 3 清单 -->
            <ScrollViewer x:Name="ListScroll" Grid.Row="3" VerticalScrollBarVisibility="Auto" Background="Transparent">
                <StackPanel x:Name="ListPanel" Margin="0,2,4,0"/>
            </ScrollViewer>

            <!-- 4 折叠条（仅钉住态折叠时）：只显示最上面一条未完成 -->
            <Border x:Name="CollapseBar" Grid.Row="4" Height="42" Visibility="Collapsed"
                    Background="#16181d" BorderBrush="#3a3f4c" BorderThickness="1">
                <DockPanel>
                    <TextBlock Text="Ctrl+Alt+E / 双击" DockPanel.Dock="Right" Foreground="#98a0ad" FontSize="9"
                               VerticalAlignment="Center" Margin="0,0,10,0"/>
                    <TextBlock x:Name="CollapseText" Text="📌" Foreground="#e8eaf0" FontSize="12"
                               VerticalAlignment="Center" Margin="12,0,4,0" TextTrimming="CharacterEllipsis"/>
                </DockPanel>
            </Border>

            <!-- 5 页脚 -->
            <StackPanel x:Name="Footer" Grid.Row="5" Margin="0,8,0,0">
                <TextBlock x:Name="CountText" Foreground="#98a0ad" FontSize="10"/>
                <TextBlock Foreground="#6b7280" FontSize="9" TextWrapping="Wrap" Margin="0,2,0,0"
                           Text="钉住后：悬停 ≈0.3 秒 = 50% 透明 + 点击穿透（点击落到下方）｜ 移入后快速双击 = 折叠/展开 ｜ 热键 Ctrl+Alt+P · Ctrl+Alt+E"/>
            </StackPanel>
        </Grid>
    </Border>
</Window>
'@

$window = [Windows.Markup.XamlReader]::Parse($xamlText)
$names = 'BtnPin','BtnClose','BtnAdd','InputBox','HintBar','AddPanel',
          'ListScroll','ListPanel','CollapseBar','CollapseText','Footer','CountText'
$ctl = @{}
foreach ($n in $names) { $ctl[$n] = $window.FindName($n) }

# ---------------- 数据 ----------------
$script:DataFile = Join-Path $PSScriptRoot 'todos.json'
$script:TickLog  = Join-Path $PSScriptRoot 'tick_error.log'
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$script:Seed = @(
    [pscustomobject]@{ text = '评审钉子窗口原型（试试悬停穿透）'; tag = '今日'; done = $false }
    [pscustomobject]@{ text = '回复项目合作邮件';                 tag = '今日'; done = $false }
    [pscustomobject]@{ text = '同步市场调研结论到飞书';           tag = '今日'; done = $true  }
    [pscustomobject]@{ text = '读书笔记：第三章';                 tag = '远程'; done = $false }
    [pscustomobject]@{ text = '整理竞品对照矩阵';                 tag = '远程'; done = $false }
)

function Load-Todos {
    for ($i = 0; $i -lt 3; $i++) {   # E 盘偶发 IO 抖动，重试 3 次
        try {
            $raw = [IO.File]::ReadAllText($script:DataFile)
            $d = $raw | ConvertFrom-Json
            $items = @($d.items)
            if ($items.Count -gt 0) { return @{ items = $items; pos = @($d.pos) } }
            return @{ items = $script:Seed; pos = $null }
        } catch [System.IO.FileNotFoundException] {
            return @{ items = $script:Seed; pos = $null }
        } catch {
            Start-Sleep -Milliseconds 200
        }
    }
    return @{ items = $script:Seed; pos = $null }
}

function Save-Todos {
    $payload = @{ items = $script:items; pos = @($window.Left, $window.Top) } | ConvertTo-Json -Depth 4
    for ($i = 0; $i -lt 3; $i++) {
        try { [IO.File]::WriteAllText($script:DataFile, $payload, $script:Utf8NoBom); return }
        catch { Start-Sleep -Milliseconds 200 }
    }
}

$loaded = Load-Todos
$script:items = $loaded.items
$script:winPos = $loaded.pos

# ---------------- 状态 ----------------
$script:mode = 'normal'          # normal | pinned
$script:collapsed = $false
$script:hoverVisual = $false     # 悬停视觉（50% 透明）
$script:passthrough = $false     # 点击穿透（WS_EX_TRANSPARENT）
$script:enterTick = 0            # 光标进入窗口的时刻
$script:absorbUntil = 0          # 在此时刻之前保持可点击（等待双击第二击）
$script:hkPin = $false
$script:hkFold = $false
$script:lastWinClick = 0     # 最近一次落在窗口上的单击时刻（手动判定双击）
$script:dbgClicks = 0        # 调试计数：窗口实际收到的点击数
$script:normalRect = $null
$script:hoverPoll = -not [bool]$Selftest   # 自检前半段关闭轮询，端到端阶段再打开

# 初始位置：优先用上次位置，否则放屏幕右侧偏上
if ($script:winPos -and $script:winPos.Count -ge 2 -and $script:winPos[0] -is [double] -and $script:winPos[1] -is [double]) {
    $window.Left = $script:winPos[0]; $window.Top = $script:winPos[1]
} else {
    $window.Left = [System.Windows.SystemParameters]::WorkArea.Right - 460
    $window.Top = 80
}

# ---------------- 窗口句柄 / 悬停与穿透 ----------------
function Get-Hwnd {
    return ([System.Windows.Interop.HwndSource]::FromVisual($window)).Handle
}

function Set-VisualHover([bool]$on) {
    if ($on -eq $script:hoverVisual) { return }
    $script:hoverVisual = $on
    if ($on) { $window.Opacity = $HOVER_ALPHA } else { $window.Opacity = 1.0 }
}

function Set-Passthrough([bool]$on) {
    if ($on -eq $script:passthrough) { return }
    $script:passthrough = $on
    $hwnd = Get-Hwnd
    $style = [Win32Pin]::GetWindowLong($hwnd, $GWL_EXSTYLE)
    if ($on) {
        [void][Win32Pin]::SetWindowLong($hwnd, $GWL_EXSTYLE, $style -bor ($WS_EX_LAYERED -bor $WS_EX_TRANSPARENT))
    } else {
        [void][Win32Pin]::SetWindowLong($hwnd, $GWL_EXSTYLE, $style -band (-bnot $WS_EX_TRANSPARENT))
    }
}

function Test-CursorInside {
    $pt = New-Object Win32Pin+POINT
    [void][Win32Pin]::GetCursorPos([ref]$pt)
    $rc = New-Object Win32Pin+RECT
    [void][Win32Pin]::GetWindowRect((Get-Hwnd), [ref]$rc)
    return ($pt.x -ge ($rc.left - 2)) -and ($pt.x -le ($rc.right + 2)) -and
           ($pt.y -ge ($rc.top - 2)) -and ($pt.y -le ($rc.bottom + 2))
}

# ---------------- 清单 UI ----------------
function New-Row([pscustomobject]$item, [int]$i, [bool]$readOnly) {
    $border = New-Object System.Windows.Controls.Border
    $border.Background = B '#2a2e39'
    $border.CornerRadius = New-Object System.Windows.CornerRadius 3
    $border.Padding = New-Object System.Windows.Thickness 8,5,8,5
    $border.Margin = New-Object System.Windows.Thickness 0,1,0,1

    $dock = New-Object System.Windows.Controls.DockPanel

    # 删除按钮（仅普通模式）
    if (-not $readOnly) {
        $del = New-Object System.Windows.Controls.Button
        $del.Content = [string][char]0xD7   # ×
        $del.Tag = $i
        $del.Background = B '#2a2e39'; $del.Foreground = B '#98a0ad'
        $del.BorderThickness = New-Object System.Windows.Thickness 0
        $del.FontSize = 11; $del.Cursor = [System.Windows.Input.Cursors]::Hand
        $del.Add_Click({ param($s, $e) Remove-ItemAt ([int]$s.Tag) })
        [System.Windows.Controls.DockPanel]::SetDock($del, 'Right')
        $dock.Children.Add($del) | Out-Null
    }

    # 标签
    $tagT = New-Object System.Windows.Controls.TextBlock
    $tagT.Text = $item.tag
    $tagT.FontSize = 10
    $tagT.Foreground = B $(if ($item.tag -eq '今日') { '#5b8cff' } else { '#ffb454' })
    $tagT.VerticalAlignment = 'Center'
    $tagT.Margin = New-Object System.Windows.Thickness 6,0,2,0
    [System.Windows.Controls.DockPanel]::SetDock($tagT, 'Right')
    $dock.Children.Add($tagT) | Out-Null

    # 勾选：普通模式用 CheckBox，钉住态只读用 ✓/○ 文本
    if ($readOnly) {
        $mark = New-Object System.Windows.Controls.TextBlock
        $mark.Text = $(if ($item.done) { [string][char]0x2713 } else { [string][char]0x25CB })
        $mark.FontSize = 10
        $mark.Foreground = B $(if ($item.done) { '#5b8cff' } else { '#98a0ad' })
        $mark.VerticalAlignment = 'Center'
        $mark.Margin = New-Object System.Windows.Thickness 0,0,6,0
        $dock.Children.Add($mark) | Out-Null
    } else {
        $chk = New-Object System.Windows.Controls.CheckBox
        $chk.IsChecked = $item.done
        $chk.Tag = $i
        $chk.Cursor = [System.Windows.Input.Cursors]::Hand
        $chk.VerticalAlignment = 'Center'
        $chk.Margin = New-Object System.Windows.Thickness 0,0,6,0
        $chk.Add_Click({ param($s, $e) Toggle-DoneAt ([int]$s.Tag) })
        $dock.Children.Add($chk) | Out-Null
    }

    # 正文（最后一个子元素自动填充）
    $txt = New-Object System.Windows.Controls.TextBlock
    $txt.Text = $item.text
    $txt.TextWrapping = 'Wrap'
    $txt.Foreground = B $(if ($item.done) { '#98a0ad' } else { '#e8eaf0' })
    $txt.VerticalAlignment = 'Center'
    $dock.Children.Add($txt) | Out-Null

    $border.Child = $dock
    return $border
}

function Rebuild-Rows {
    $ctl['ListPanel'].Children.Clear()
    $readOnly = ($script:mode -eq 'pinned')
    for ($i = 0; $i -lt $script:items.Count; $i++) {
        $ctl['ListPanel'].Children.Add((New-Row $script:items[$i] $i $readOnly)) | Out-Null
    }
    if ($script:items.Count -eq 0) {
        $empty = New-Object System.Windows.Controls.TextBlock
        $empty.Text = $(if ($readOnly) { '暂无待办 ✓' } else { '暂无待办，添加一条试试' })
        $empty.Foreground = B '#98a0ad'; $empty.FontSize = 11
        $empty.Margin = New-Object System.Windows.Thickness 4,12,0,12
        $ctl['ListPanel'].Children.Add($empty) | Out-Null
    }
    $pend = @($script:items | Where-Object { -not $_.done }).Count
    $done = $script:items.Count - $pend
    $ctl['CountText'].Text = "$pend 项待办 · $done 已完成"
    # 折叠条：只显示最上面一条未完成
    $next = $null
    foreach ($it in $script:items) { if (-not $it.done) { $next = $it.text; break } }
    $ctl['CollapseText'].Text = $(if ($next) { "📌 $next" } else { '📌 暂无待办' })
}

function Add-Todo {
    $t = $ctl['InputBox'].Text.Trim()
    if ([string]::IsNullOrWhiteSpace($t)) { return }
    $script:items = @([pscustomobject]@{ text = $t; tag = '今日'; done = $false }) + $script:items
    $ctl['InputBox'].Clear()
    Save-Todos
    Rebuild-Rows
}

function Toggle-DoneAt([int]$i) {
    $script:items[$i].done = -not $script:items[$i].done
    Save-Todos
    Rebuild-Rows
}

function Remove-ItemAt([int]$i) {
    $new = New-Object System.Collections.ArrayList
    for ($k = 0; $k -lt $script:items.Count; $k++) {
        if ($k -ne $i) { [void]$new.Add($script:items[$k]) }
    }
    $script:items = @($new)
    Save-Todos
    Rebuild-Rows
}

# ---------------- 钉住 / 取消钉住 / 折叠 ----------------
function Get-PinHeight {
    $n = $script:items.Count
    $h = 60 + $n * 34 + 10
    if ($h -gt 430) { $h = 430 }
    if ($h -lt 120) { $h = 120 }
    return [double]$h
}

function Invoke-Pin {
    if ($script:mode -eq 'pinned') { return }
    $script:normalRect = @{ L = $window.Left; T = $window.Top; W = $window.Width; H = $window.Height }
    $script:mode = 'pinned'; $script:collapsed = $false
    $script:enterTick = 0; $script:absorbUntil = 0
    Set-VisualHover $false
    Set-Passthrough $false
    $window.WindowStyle = 'None'
    $window.Topmost = $true
    $window.ResizeMode = 'NoResize'
    $ctl['HintBar'].Visibility = 'Visible'
    $ctl['AddPanel'].Visibility = 'Collapsed'
    $ctl['Footer'].Visibility = 'Collapsed'
    $ctl['CollapseBar'].Visibility = 'Collapsed'
    $ctl['ListScroll'].Visibility = 'Visible'
    $ctl['ListPanel'].IsHitTestVisible = $false   # 钉住态只读：清单不响应鼠标
    $window.Width = 330
    $window.Height = Get-PinHeight
    Rebuild-Rows
}

function Invoke-Unpin {
    if ($script:mode -eq 'normal') { return }
    Set-VisualHover $false
    Set-Passthrough $false
    $script:mode = 'normal'; $script:collapsed = $false
    $window.WindowStyle = 'SingleBorderWindow'
    $window.Topmost = $false
    $window.ResizeMode = 'CanResize'
    $ctl['HintBar'].Visibility = 'Collapsed'
    $ctl['AddPanel'].Visibility = 'Visible'
    $ctl['Footer'].Visibility = 'Visible'
    $ctl['CollapseBar'].Visibility = 'Collapsed'
    $ctl['ListScroll'].Visibility = 'Visible'
    $ctl['ListPanel'].IsHitTestVisible = $true
    if ($script:normalRect) {
        $window.Left = $script:normalRect.L; $window.Top = $script:normalRect.T
        $window.Width = $script:normalRect.W; $window.Height = $script:normalRect.H
    } else {
        $window.Width = 400; $window.Height = 500
    }
    Rebuild-Rows
}

function Invoke-ToggleCollapse {
    if ($script:mode -ne 'pinned') { return }
    $script:collapsed = -not $script:collapsed
    if ($script:collapsed) {
        $ctl['HintBar'].Visibility = 'Collapsed'
        $ctl['ListScroll'].Visibility = 'Collapsed'
        $ctl['CollapseBar'].Visibility = 'Visible'
        $window.Height = 46
    } else {
        $ctl['HintBar'].Visibility = 'Visible'
        $ctl['ListScroll'].Visibility = 'Visible'
        $ctl['CollapseBar'].Visibility = 'Collapsed'
        $window.Height = Get-PinHeight
    }
}

# ---------------- 事件 / 轮询 ----------------
$window.Add_Closing({ Save-Todos })
$ctl['BtnClose'].Add_Click({ $window.Close() })
$ctl['BtnPin'].Add_Click({ if ($script:mode -eq 'normal') { Invoke-Pin } else { Invoke-Unpin } })
$ctl['BtnAdd'].Add_Click({ Add-Todo })
$ctl['InputBox'].Add_KeyDown({
    param($s, $e)
    if ($e.Key -eq 'Return') { Add-Todo }
    elseif ($e.Key -eq 'Escape') { $s.Clear() }
})

# 钉住态：双击窗口 = 折叠 / 展开（手动计时判定，450ms 内两击算双击）
# 注意必须用 Preview（隧道阶段）：ScrollViewer 会吞掉清单区域的冒泡点击
$window.Add_PreviewMouseLeftButtonDown({
    param($s, $e)
    if ($script:mode -eq 'pinned') {
        $now = [Environment]::TickCount
        $script:dbgClicks++
        $script:absorbUntil = $now + $ABSORB_MS
        if (($now - $script:lastWinClick) -lt 450) {
            $script:lastWinClick = 0
            Invoke-ToggleCollapse
            $script:absorbUntil = $now + $ABSORB_MS + 200
        } else {
            $script:lastWinClick = $now
        }
    }
})

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(40)
$timer.Add_Tick({
    try {
        $ctrl = [bool]([Win32Pin]::GetAsyncKeyState($VK_CONTROL) -band 0x8000)
        $alt  = [bool]([Win32Pin]::GetAsyncKeyState($VK_MENU)  -band 0x8000)
        $kPin = ($ctrl -and $alt -and [bool]([Win32Pin]::GetAsyncKeyState($VK_P) -band 0x8000))
        $kFold = ($ctrl -and $alt -and [bool]([Win32Pin]::GetAsyncKeyState($VK_E) -band 0x8000))
        if ($kPin -and -not $script:hkPin) {
            if ($script:mode -eq 'normal') { Invoke-Pin } else { Invoke-Unpin }
        }
        $script:hkPin = $kPin
        if ($kFold -and -not $script:hkFold) { Invoke-ToggleCollapse }
        $script:hkFold = $kFold

        if ($script:mode -eq 'pinned' -and $script:hoverPoll) {
            $inside = Test-CursorInside
            Set-VisualHover $inside
            $now = [Environment]::TickCount
            if (-not $inside) {
                $script:enterTick = 0
                Set-Passthrough $false
            } else {
                if ($script:enterTick -eq 0) { $script:enterTick = $now }
                $dwelled  = (($now - $script:enterTick) -ge $DWELL_MS)
                $absorbing = ($now -lt $script:absorbUntil)
                Set-Passthrough ($dwelled -and -not $absorbing)
            }
        }
    } catch {
        try {
            [IO.File]::AppendAllText($script:TickLog,
                ("{0}  {1}{2}" -f [DateTime]::Now.ToString('s'), $_.Exception.Message, [Environment]::NewLine))
        } catch { }
    }
})
$timer.Start()

Rebuild-Rows

# ---------------- 自检 ----------------
function Invoke-Pump([int]$n = 3) {
    for ($i = 0; $i -lt $n; $i++) {
        [void][System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([action]{}, 'Background')
        Start-Sleep -Milliseconds 60
        [void][System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([action]{}, 'Background')
    }
}

if ($Selftest) {
    $script:results = @()
    function Chk([string]$name, [bool]$cond) {
        $script:results += [bool]$cond
        Write-Output ((('PASS','FAIL')[ [int](-not $cond) ]) + ' | ' + $name)
    }
    $window.Show(); Invoke-Pump

    Chk '01 普通模式: 存在添加入口(可编辑)' ($ctl['AddPanel'].Visibility -eq 'Visible' -and $script:mode -eq 'normal')
    Chk '02 普通模式: 无点击穿透样式位' (-not ([Win32Pin]::GetWindowLong((Get-Hwnd), $GWL_EXSTYLE) -band $WS_EX_TRANSPARENT))
    Chk '03 普通模式: 非置顶' (-not $window.Topmost)

    Invoke-Pin; Invoke-Pump
    Chk '04 钉住: 置顶生效' ([bool]$window.Topmost)
    Chk '05 钉住: 无边框' ($window.WindowStyle -eq 'None')
    Chk '06 钉住: 只读(无添加行且清单不响应鼠标)' ($ctl['AddPanel'].Visibility -eq 'Collapsed' -and -not $ctl['ListPanel'].IsHitTestVisible)
    $h1 = $window.Height

    Invoke-ToggleCollapse; Invoke-Pump
    Chk '07 钉住: 可折叠(高度变小)' ($window.Height -lt $h1)
    $firstUndone = $null
    foreach ($it in $script:items) { if (-not $it.done) { $firstUndone = $it.text; break } }
    Chk '08 折叠条: 只显示最上面一条未完成' ($ctl['CollapseText'].Text -eq "📌 $firstUndone")
    Invoke-ToggleCollapse; Invoke-Pump

    Set-VisualHover $true; Set-Passthrough $true; Invoke-Pump 1
    Chk '09 悬停(强制): 透明度=50%' ([math]::Abs($window.Opacity - 0.5) -lt 0.01)
    Chk '10 悬停(强制): 点击穿透样式位已设置' ([bool]([Win32Pin]::GetWindowLong((Get-Hwnd), $GWL_EXSTYLE) -band $WS_EX_TRANSPARENT))

    Set-VisualHover $false; Set-Passthrough $false; Invoke-Pump 1
    Chk '11 光标离开(强制): 透明度恢复100%' ([math]::Abs($window.Opacity - 1.0) -lt 0.01)
    Chk '12 光标离开(强制): 穿透位已清除' (-not ([Win32Pin]::GetWindowLong((Get-Hwnd), $GWL_EXSTYLE) -band $WS_EX_TRANSPARENT))

    Invoke-Unpin; Invoke-Pump
    Chk '13 取消钉住: 恢复可编辑' ($ctl['AddPanel'].Visibility -eq 'Visible' -and $ctl['ListPanel'].IsHitTestVisible)
    Chk '14 取消钉住: 取消置顶' (-not $window.Topmost)
    Chk '15 取消钉住: 无穿透位' (-not ([Win32Pin]::GetWindowLong((Get-Hwnd), $GWL_EXSTYLE) -band $WS_EX_TRANSPARENT))

    # ---------- 端到端：真实光标 + 模拟双击（会短暂移动鼠标，结束后复原） ----------
    $orig = New-Object Win32Pin+POINT
    [void][Win32Pin]::GetCursorPos([ref]$orig)
    Invoke-Pin; Invoke-Pump
    $script:hoverPoll = $true

    $rc = New-Object Win32Pin+RECT
    [void][Win32Pin]::GetWindowRect((Get-Hwnd), [ref]$rc)
    $cx = [int](($rc.left + $rc.right) / 2)
    $cy = [int](($rc.top + $rc.bottom) / 2)
    if ($rc.top -ge 80) { $ax = $cx; $ay = $rc.top - 50 } else { $ax = $cx; $ay = $rc.bottom + 50 }
    Write-Output ("DBG rect=($($rc.left),$($rc.top),$($rc.right),$($rc.bottom)) center=($cx,$cy) away=($ax,$ay)")

    [void][Win32Pin]::SetCursorPos($ax, $ay)
    Invoke-Pump 8
    Chk '16 端到端-光标在窗口外: 不透明且无穿透' (([math]::Abs($window.Opacity - 1.0) -lt 0.01) -and -not $script:passthrough)

    [void][Win32Pin]::SetCursorPos($cx, $cy)
    Invoke-Pump 8    # > 300ms 缓冲期
    $ptNow = New-Object Win32Pin+POINT
    [void][Win32Pin]::GetCursorPos([ref]$ptNow)
    Write-Output ("DBG cursorNow=($($ptNow.x),$($ptNow.y)) inside=$(Test-CursorInside) opacity=$($window.Opacity) passthrough=$($script:passthrough)")
    Chk '17 端到端-悬停: 透明度=50%' ([math]::Abs($window.Opacity - 0.5) -lt 0.01)
    Chk '18 端到端-悬停: 穿透已启用' ($script:passthrough -and [bool]([Win32Pin]::GetWindowLong((Get-Hwnd), $GWL_EXSTYLE) -band $WS_EX_TRANSPARENT))

    # 移出再移入并立即双击 → 折叠
    [void][Win32Pin]::SetCursorPos($ax, $ay)
    Invoke-Pump 2
    $script:dbgClicks = 0
    [void][Win32Pin]::SetCursorPos($cx, $cy)
    Start-Sleep -Milliseconds 50
    [Win32Pin]::mouse_event(0x02, 0, 0, 0, [UIntPtr]::Zero)
    [Win32Pin]::mouse_event(0x04, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 80
    [Win32Pin]::mouse_event(0x02, 0, 0, 0, [UIntPtr]::Zero)
    [Win32Pin]::mouse_event(0x04, 0, 0, 0, [UIntPtr]::Zero)
    Invoke-Pump 5
    Write-Output ("DBG clicksReceived=$($script:dbgClicks) collapsed=$($script:collapsed) passthrough=$($script:passthrough)")
    Chk '19 端到端-双击: 窗口已折叠' ($script:collapsed -eq $true)
    Invoke-ToggleCollapse; Invoke-Pump 2

    [void][Win32Pin]::SetCursorPos($orig.x, $orig.y)
    Invoke-Pump 2
    Invoke-Unpin; Invoke-Pump
    Save-Todos
    Chk '20 数据持久化: todos.json 已写入' (Test-Path -LiteralPath $script:DataFile)

    $ok = @($script:results | Where-Object { $_ }).Count -eq $script:results.Count
    Write-Output ('=' * 46)
    Write-Output ("SELFTEST " + $(if ($ok) { 'PASS' } else { 'FAIL' }) + " ($(@($script:results | Where-Object { $_ }).Count)/$($script:results.Count))")
    $window.Close()
    if ($ok) { exit 0 } else { exit 1 }
}

# ---------------- 主循环 ----------------
[void]$window.ShowDialog()
