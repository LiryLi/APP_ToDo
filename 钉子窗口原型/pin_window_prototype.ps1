#requires -version 5.1
<#
桌面ToDo · Windows 置顶窗口原型（R11 置顶模式）— PowerShell + WPF 版
====================================================================

演示「电脑端置顶窗口」的核心系统级行为：

  1. 置顶       窗口无边框、置顶常驻桌面，进入只读态（不可添加 / 不可编辑）
  2. 悬停穿透   鼠标悬停在窗口上时整体透明度 50%，且鼠标点击穿透到下方的桌面 / 窗口
  3. 放大折叠   置顶态可展开为完整清单，或折叠为一行常驻小条（只显示最上面一条未完成）
  4. 取消置顶   恢复为普通窗口：可编辑、不可穿透、不再强制置顶

置顶态的交互方式：

  Ctrl + Alt + P     置顶 / 取消置顶
  Ctrl + Alt + E     展开 / 折叠（置顶态）
  双击窗口           折叠 / 展开（置顶态；鼠标移入后约 1 秒内有效，
                     之后进入穿透态，移出再移入可再次双击）

运行：
  双击同目录「启动置顶窗口.cmd」，或
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
  - 双击折叠:   移入后有 1000ms 缓冲期（此期间点击落在窗口上，可双击折叠）；
                悬停满 300ms 后进入穿透；单击后 500ms 内保持可点（等待第二击）
#>
[CmdletBinding()]
param([switch]$Selftest, [switch]$ClickTest)

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
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint flags);
    [DllImport("user32.dll")] public static extern bool SetLayeredWindowAttributes(IntPtr h, uint crKey, byte bAlpha, uint flags);
    [DllImport("user32.dll")] public static extern bool GetLayeredWindowAttributes(IntPtr h, out uint crKey, out byte bAlpha, out uint flags);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
}
'@
Add-Type -TypeDefinition $win32cs
# 必须在创建任何窗口之前声明 DPI 感知：
# 否则 WPF(DIP)、GetWindowRect/SetCursorPos(物理像素)、屏幕截图坐标在 125% 缩放下互相错位
[void][Win32Pin]::SetProcessDPIAware()

$GWL_EXSTYLE       = -20
$WS_EX_LAYERED     = 0x00080000
$WS_EX_TRANSPARENT  = 0x00000020
$VK_CONTROL, $VK_MENU, $VK_P, $VK_E = 0x11, 0x12, 0x50, 0x45
$HOVER_ALPHA = 0.2   # 悬停时窗口 alpha=20%（能隐约看到下层内容）
$DWELL_MS    = 1000   # 光标移入后多久进入穿透（此期间可双击折叠）
$ABSORB_MS   = 1000   # 单击后保持可点击多久（等待可能的第二击）

$script:BrushConv = New-Object System.Windows.Media.BrushConverter
function B([string]$hex) { $script:BrushConv.ConvertFromString($hex) }

# ---------------- 界面（XAML） ----------------
$xamlText = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="桌面ToDo · 置顶窗口原型"
        Width="400" Height="500" WindowStartupLocation="Manual"
        Background="#1f2127" FontFamily="Microsoft YaHei UI" FontSize="12"
        ResizeMode="NoResize" WindowStyle="None" AllowsTransparency="True">
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
            <DockPanel x:Name="HeaderBar" Grid.Row="0">
                <StackPanel DockPanel.Dock="Left" Orientation="Horizontal">
                    <TextBlock Text="桌面ToDo" FontSize="14" FontWeight="Bold" Foreground="#e8eaf0" VerticalAlignment="Center"/>
                    <TextBlock Text=" 置顶窗口原型" FontSize="10" Foreground="#98a0ad" VerticalAlignment="Center" Margin="4,2,0,0"/>
                </StackPanel>
                <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
                    <Button x:Name="BtnPin" Content="📌 置顶" Background="#5b8cff" Foreground="White"
                            BorderThickness="0" FontSize="11" Padding="12,4" Margin="0,0,4,0" Cursor="Hand"/>
                    <Button x:Name="BtnClose" Content="✕" Background="#1f2127" Foreground="#98a0ad"
                            BorderThickness="0" FontSize="10" Padding="8,3" Cursor="Hand"/>
                </StackPanel>
                <TextBlock/>
            </DockPanel>

            <!-- 1 置顶态提示条 -->
            <DockPanel x:Name="HintBar" Grid.Row="1" Margin="0,8,0,2" Visibility="Collapsed">
                <TextBlock Text="已置顶 · 只读 · 双击折叠" Foreground="#5b8cff" FontSize="11" VerticalAlignment="Center"/>
                <TextBlock Text="Ctrl+Alt+P 取消 · Ctrl+Alt+E 折叠" Foreground="#98a0ad" FontSize="9"
                           HorizontalAlignment="Right" VerticalAlignment="Center"/>
            </DockPanel>

            <!-- 2 添加行（仅普通模式，置顶态不可添加） -->
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

            <!-- 4 折叠条（仅置顶态折叠时）：只显示最上面一条未完成 -->
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
                           Text="置顶后：悬停 1 秒 = 20% 透明 + 点击穿透（点击落到下方）｜ 移入后 1 秒内双击 = 折叠/展开 ｜ 热键 Ctrl+Alt+P · Ctrl+Alt+E"/>
            </StackPanel>
        </Grid>
    </Border>
</Window>
'@

$window = [Windows.Markup.XamlReader]::Parse($xamlText)
$names = 'HeaderBar','BtnPin','BtnClose','BtnAdd','InputBox','HintBar','AddPanel',
          'ListScroll','ListPanel','CollapseBar','CollapseText','Footer','CountText'
$ctl = @{}
foreach ($n in $names) { $ctl[$n] = $window.FindName($n) }

# ---------------- 数据 ----------------
$script:DataFile = Join-Path $PSScriptRoot 'todos.json'
$script:TickLog  = Join-Path $PSScriptRoot 'tick_error.log'
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$script:Seed = @(
    [pscustomobject]@{ text = '评审置顶窗口原型（试试悬停穿透）'; tag = '今日'; done = $false }
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
    # T0.2 合并保护：写入前并入其他写入方（飞书守护进程）新增的条目，避免整文件覆盖丢失
    try {
        $disk = [IO.File]::ReadAllText($script:DataFile) | ConvertFrom-Json
        foreach ($it in @($disk.items)) {
            $known = $false
            foreach ($m in @($script:items)) { if ($m.text -eq $it.text) { $known = $true; break } }
            if (-not $known) { $script:items = @($script:items) + $it }
        }
    } catch { }
    $payload = @{ items = $script:items; pos = @($window.Left, $window.Top) } | ConvertTo-Json -Depth 4
    for ($i = 0; $i -lt 3; $i++) {
        try {
            [IO.File]::WriteAllText($script:DataFile, $payload, $script:Utf8NoBom)
            $script:lastSyncStamp = [IO.File]::GetLastWriteTimeUtc($script:DataFile)
            return
        }
        catch { Start-Sleep -Milliseconds 200 }
    }
}

$loaded = Load-Todos
$script:items = $loaded.items
$script:winPos = $loaded.pos
$script:lastSyncStamp = [DateTime]::MinValue
try { if (Test-Path -LiteralPath $script:DataFile) { $script:lastSyncStamp = [IO.File]::GetLastWriteTimeUtc($script:DataFile) } } catch { }

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

# 窗口在 XAML 中以 AllowsTransparency=True 创建：WPF 自身就是分层窗口（UpdateLayeredWindow 渲染），
# Window.Opacity 原生控制整体 alpha；此时 WS_EX_TRANSPARENT 才具备真正的点击穿透语义。
# 注意：不要对普通 WPF 窗口外部强加 WS_EX_LAYERED（DirectX 渲染路径不产生真分层，穿透无效），
# 也不要在普通窗口上混用 Opacity 与手动 LAYERED（WPF 会重写扩展样式把 LAYERED 冲掉）。
function Apply-WindowState {
    $hwnd = Get-Hwnd
    $ex = [Win32Pin]::GetWindowLong($hwnd, $GWL_EXSTYLE)
    $wantTransparent = ($script:mode -eq 'pinned') -and $script:passthrough
    $new = $ex
    if ($wantTransparent) { $new = $new -bor $WS_EX_TRANSPARENT } else { $new = $new -band (-bnot $WS_EX_TRANSPARENT) }
    if ($new -ne $ex) {
        [void][Win32Pin]::SetWindowLong($hwnd, $GWL_EXSTYLE, $new)
        # SetWindowLong 改样式后必须 FRAMECHANGED 才真正生效
        [void][Win32Pin]::SetWindowPos($hwnd, [IntPtr]::Zero, 0, 0, 0, 0, 0x0037)
    }
}

function Set-VisualHover([bool]$on) {
    if ($on -eq $script:hoverVisual) { return }
    $script:hoverVisual = $on
    if ($on) { $window.Opacity = $HOVER_ALPHA } else { $window.Opacity = 1.0 }
}

function Set-Passthrough([bool]$on) {
    if ($on -eq $script:passthrough) { return }
    if ($on -and $script:mode -ne 'pinned') { return }
    $script:passthrough = $on
    Apply-WindowState
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

    # 勾选：普通模式用 CheckBox，置顶态只读用 ✓/○ 文本
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

# ---------------- 置顶 / 取消置顶 / 折叠 ----------------
function Get-PinHeight {
    $n = $script:items.Count
    $h = 60 + $n * 34 + 10
    if ($h -gt 430) { $h = 430 }
    if ($h -lt 120) { $h = 120 }
    return [double]$h
}

# ---------------- 独立置顶按钮层（永不变透明、永不穿透、置顶态始终可点击） ----------------
$islandXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        Width="96" Height="30" WindowStartupLocation="Manual"
        WindowStyle="None" AllowsTransparency="True" Topmost="True"
        ShowInTaskbar="False" ShowActivated="False" Background="Transparent">
    <Border Background="#5b8cff" CornerRadius="6" BorderBrush="#8fb0ff" BorderThickness="1">
        <Button Name="IslandPin" Content="📌 取消置顶" Foreground="White" Background="Transparent"
                BorderThickness="0" FontSize="12" Cursor="Hand"/>
    </Border>
</Window>
'@
$pinIsland = [Windows.Markup.XamlReader]::Parse($islandXaml)
$islandBtn = $pinIsland.FindName('IslandPin')
$islandBtn.Add_Click({ if ($script:mode -eq 'pinned') { Invoke-Unpin } })

function Update-PinIsland {
    if ($script:mode -ne 'pinned') {
        if ($pinIsland.IsVisible) { $pinIsland.Hide() }
        return
    }
    # 悬浮在主窗口顶边右上方（独立窗口，主窗口透明/穿透均不影响它）
    $pinIsland.Left = $window.Left + $window.Width - 104
    $it = $window.Top - 36
    if ($it -lt 0) { $it = $window.Top + 8 }   # 主窗口贴屏幕顶边时退回到窗口内部
    $pinIsland.Top = $it
    if (-not $pinIsland.IsVisible) { $pinIsland.Show() }
    $ih = ([System.Windows.Interop.HwndSource]::FromVisual($pinIsland)).Handle
    # 始终保持在主窗口之上（不激活、不抢焦点）
    [void][Win32Pin]::SetWindowPos($ih, (Get-Hwnd), 0, 0, 0, 0, 0x0013)
}

$window.Add_Closed({ try { $pinIsland.Close() } catch { } })

function Invoke-Pin {
    if ($script:mode -eq 'pinned') { return }
    $script:normalRect = @{ L = $window.Left; T = $window.Top; W = $window.Width; H = $window.Height }
    $script:mode = 'pinned'; $script:collapsed = $false
    $script:enterTick = 0; $script:absorbUntil = 0
    Set-VisualHover $false
    Set-Passthrough $false
    $window.Topmost = $true
    $ctl['HeaderBar'].Visibility = 'Visible'
    $ctl['HintBar'].Visibility = 'Visible'
    $ctl['AddPanel'].Visibility = 'Collapsed'
    $ctl['Footer'].Visibility = 'Collapsed'
    $ctl['CollapseBar'].Visibility = 'Collapsed'
    $ctl['ListScroll'].Visibility = 'Visible'
    $ctl['ListPanel'].IsHitTestVisible = $false   # 置顶态只读：清单不响应鼠标
    $window.Width = 330
    $window.Height = Get-PinHeight
    $ctl['BtnPin'].Visibility = 'Collapsed'   # 置顶态改用独立按钮层，避免主窗口上的按钮被透明/穿透
    Update-PinIsland
    Rebuild-Rows
}

function Invoke-Unpin {
    if ($script:mode -eq 'normal') { return }
    Set-VisualHover $false
    Set-Passthrough $false
    $script:mode = 'normal'; $script:collapsed = $false
    $window.Topmost = $false
    $ctl['HeaderBar'].Visibility = 'Visible'
    $ctl['HintBar'].Visibility = 'Collapsed'
    $ctl['AddPanel'].Visibility = 'Visible'
    $ctl['Footer'].Visibility = 'Visible'
    $ctl['CollapseBar'].Visibility = 'Collapsed'
    $ctl['ListScroll'].Visibility = 'Visible'
    $ctl['ListPanel'].IsHitTestVisible = $true
    $ctl['BtnPin'].Visibility = 'Visible'
    Update-PinIsland
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
        # 折叠 = 只留一行条：标题栏 / 提示条 / 清单全部隐藏，否则挤掉折叠条空间
        $ctl['HeaderBar'].Visibility = 'Collapsed'
        $ctl['HintBar'].Visibility = 'Collapsed'
        $ctl['ListScroll'].Visibility = 'Collapsed'
        $ctl['CollapseBar'].Visibility = 'Visible'
        $window.Height = 64
    } else {
        $ctl['HeaderBar'].Visibility = 'Visible'
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

# 置顶态：双击窗口 = 折叠 / 展开（手动计时判定，1000ms 内两击算双击）
# 注意必须用 Preview（隧道阶段）：ScrollViewer 会吞掉清单区域的冒泡点击
$window.Add_PreviewMouseLeftButtonDown({
    param($s, $e)
    if ($script:mode -eq 'pinned') {
        $now = [Environment]::TickCount
        $script:dbgClicks++
        $script:absorbUntil = $now + $ABSORB_MS
        if (($now - $script:lastWinClick) -lt 1000) {
            $script:lastWinClick = 0
            Invoke-ToggleCollapse
            $script:absorbUntil = $now + $ABSORB_MS + 200
        } else {
            $script:lastWinClick = $now
        }
    }
})

# 普通模式：窗口永久无边框（AllowsTransparency 需要），按住标题栏空白处拖动移动窗口
$ctl['HeaderBar'].Add_MouseLeftButtonDown({
    param($s, $e)
    if ($script:mode -ne 'normal') { return }
    $src = $e.OriginalSource
    $isBtn = $false
    while ($src) {
        if ($src -is [System.Windows.Controls.Button]) { $isBtn = $true; break }
        $src = [System.Windows.Media.VisualTreeHelper]::GetParent($src)
    }
    if (-not $isBtn) { try { $window.DragMove() } catch { } }
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
        Update-PinIsland
    } catch {
        try {
            [IO.File]::AppendAllText($script:TickLog,
                ("{0}  {1}{2}" -f [DateTime]::Now.ToString('s'), $_.Exception.Message, [Environment]::NewLine))
        } catch { }
    }
})
$timer.Start()

# T0.2 外部变更感知：飞书守护进程写入 todos.json 后 2 秒内自动刷新
$syncTimer = New-Object System.Windows.Threading.DispatcherTimer
$syncTimer.Interval = [TimeSpan]::FromSeconds(2)
$syncTimer.Add_Tick({
    try {
        if ($script:collapsed) { return }
        if (-not (Test-Path -LiteralPath $script:DataFile)) { return }
        $cur = [IO.File]::GetLastWriteTimeUtc($script:DataFile)
        if ($cur -gt $script:lastSyncStamp) {
            $script:lastSyncStamp = $cur
            $loaded = Load-Todos
            if (@($loaded.items).Count -gt 0) {
                $script:items = $loaded.items
                Rebuild-Rows
            }
        }
    } catch { }
})
$syncTimer.Start()

Rebuild-Rows

# ---------------- 穿透端到端实验：下层受害窗口计数 ----------------
function Invoke-Pump([int]$n = 3) {
    for ($i = 0; $i -lt $n; $i++) {
        [void][System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([action]{}, 'Background')
        Start-Sleep -Milliseconds 60
        [void][System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([action]{}, 'Background')
    }
}

if ($ClickTest) {
    $victimXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        Width="560" Height="560" WindowStartupLocation="Manual" Left="950" Top="450"
        Background="#204020" Title="victim" Topmost="True">
    <TextBlock Name="Vt" Text="VICTIM clicks: 0" Foreground="White" FontSize="24" Margin="20"/>
</Window>
'@
    $victim = [Windows.Markup.XamlReader]::Parse($victimXaml)
    $vt = $victim.FindName('Vt')
    $script:victimClicks = 0
    $victim.Add_MouseLeftButtonDown({ $script:victimClicks++; $vt.Text = "VICTIM clicks: $script:victimClicks" })
    $victim.Show()
    $window.Left = 1000; $window.Top = 500
    $window.Show()
    Invoke-Pump 3
    Invoke-Pin; Invoke-Pump 3
    [void][Win32Pin]::SetCursorPos(20, 20); Invoke-Pump 2
    $rc = New-Object Win32Pin+RECT
    [void][Win32Pin]::GetWindowRect((Get-Hwnd), [ref]$rc)
    $cx = [int](($rc.left + $rc.right) / 2); $cy = [int](($rc.top + $rc.bottom) / 2)
    [void][Win32Pin]::SetCursorPos($cx, $cy)
    Invoke-Pump 35
    $ex = [Win32Pin]::GetWindowLong((Get-Hwnd), $GWL_EXSTYLE)
    Write-Output ("STATE opacity=$($window.Opacity) passthrough=$($script:passthrough) exStyle=0x{0:X8}" -f $ex)
    $script:dbgClicks = 0
    [Win32Pin]::mouse_event(0x02, 0, 0, 0, [UIntPtr]::Zero)
    [Win32Pin]::mouse_event(0x04, 0, 0, 0, [UIntPtr]::Zero)
    Invoke-Pump 3
    Write-Output "RESULT victimClicks=$script:victimClicks protoClicks=$script:dbgClicks"
    [void][Win32Pin]::SetCursorPos(20, 20)
    $victim.Close(); $window.Close()
    exit 0
}

# ---------------- 自检 ----------------
if ($Selftest) {
    # 自检使用独立临时数据文件 + 固定种子数据：绝不读写用户的 todos.json，保证断言确定性
    $script:DataFile = Join-Path $env:TEMP 'pin_selftest_todos.json'
    $script:items = @(
        @{ id = 't1'; text = '评审置顶窗口原型（试试悬停穿透）'; done = $false; remote = $false; time = $null },
        @{ id = 't2'; text = '回复项目合作邮件'; done = $false; remote = $false; time = $null },
        @{ id = 't3'; text = '已完成事项'; done = $true; remote = $false; time = $null }
    )
    Rebuild-Rows
    $script:results = @()
    function Chk([string]$name, [bool]$cond) {
        $script:results += [bool]$cond
        Write-Output ((('PASS','FAIL')[ [int](-not $cond) ]) + ' | ' + $name)
    }
    $window.Show(); Invoke-Pump
    function Save-Shot([string]$name) {
        Add-Type -AssemblyName System.Drawing, System.Windows.Forms
        # 1) 全屏截图（看窗口在屏幕上的真实位置/遮挡情况）
        $b = [System.Windows.Forms.SystemInformation]::VirtualScreen
        $bmp = New-Object System.Drawing.Bitmap($b.Width, $b.Height)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.CopyFromScreen($b.Left, $b.Top, 0, 0, $bmp.Size)
        $bmp.Save((Join-Path $env:TEMP ($name -replace '\.png$','_fs.png')))
        $g.Dispose(); $bmp.Dispose()
        # 2) PrintWindow 直接抓本窗口（不受其他窗口遮挡影响）
        $r = New-Object Win32Pin+RECT
        $hwnd = Get-Hwnd
        [void][Win32Pin]::GetWindowRect($hwnd, [ref]$r)
        $w = $r.right - $r.left; $h = $r.bottom - $r.top
        if ($w -gt 0 -and $h -gt 0) {
            $bmp2 = New-Object System.Drawing.Bitmap($w, $h)
            $g2 = [System.Drawing.Graphics]::FromImage($bmp2)
            $dc = $g2.GetHdc()
            [void][Win32Pin]::PrintWindow($hwnd, $dc, 2)
            $g2.ReleaseHdc($dc)
            $g2.Dispose()
            $bmp2.Save((Join-Path $env:TEMP ($name -replace '\.png$','_pw.png')))
            $bmp2.Dispose()
        }
    }
    # 自检使用独立测试位置，避免与用户正在运行的实例重叠（两窗口会从 todos.json 恢复到同一位置）
    $savedLeft = $window.Left; $savedTop = $window.Top
    $window.Left = 1000; $window.Top = 500
    Invoke-Pump 2

    Chk '01 普通模式: 存在添加入口(可编辑)' ($ctl['AddPanel'].Visibility -eq 'Visible' -and $script:mode -eq 'normal')
    Chk '02 普通模式: 无点击穿透样式位' (-not ([Win32Pin]::GetWindowLong((Get-Hwnd), $GWL_EXSTYLE) -band $WS_EX_TRANSPARENT))
    Chk '03 普通模式: 非置顶' (-not $window.Topmost)

    Invoke-Pin; Invoke-Pump
    Chk '04 置顶: 置顶生效' ([bool]$window.Topmost)
    Chk '05 置顶: 无边框' ($window.WindowStyle -eq 'None')
    Chk '06 置顶: 只读(无添加行且清单不响应鼠标)' ($ctl['AddPanel'].Visibility -eq 'Collapsed' -and -not $ctl['ListPanel'].IsHitTestVisible)
    $ih0 = ([System.Windows.Interop.HwndSource]::FromVisual($pinIsland)).Handle
    Chk '06b 置顶: 独立置顶按钮层可见且不透明' ($pinIsland.IsVisible -and [math]::Abs($pinIsland.Opacity - 1.0) -lt 0.01 -and $ctl['BtnPin'].Visibility -eq 'Collapsed')
    $h1 = $window.Height
    Save-Shot 'pin_expanded.png'

    Invoke-ToggleCollapse; Invoke-Pump
    Chk '07 置顶: 可折叠(高度变小)' ($window.Height -lt $h1)
    Chk '07b 折叠: 标题栏已隐藏且仅一行折叠条可见' ($ctl['HeaderBar'].Visibility -eq 'Collapsed' -and $ctl['CollapseBar'].Visibility -eq 'Visible')
    $firstUndone = $null
    foreach ($it in $script:items) { if (-not $it.done) { $firstUndone = $it.text; break } }
    Chk '08 折叠条: 只显示最上面一条未完成' ($ctl['CollapseText'].Text -eq "📌 $firstUndone")
    # 折叠条截图，供人工核对实际渲染
    $window.UpdateLayout()
    Start-Sleep -Milliseconds 300
    Invoke-Pump 3
    Write-Output ("DBG-CAPTURE h=$($window.Height) header=$($ctl['HeaderBar'].Visibility) " +
        "bar=$($ctl['CollapseBar'].Visibility) barH=$($ctl['CollapseBar'].ActualHeight) " +
        "txtW=$($ctl['CollapseText'].ActualWidth) txt='$($ctl['CollapseText'].Text)'")
    Save-Shot 'pin_collapsed.png'
    Invoke-ToggleCollapse; Invoke-Pump

    Set-VisualHover $true; Set-Passthrough $true; Invoke-Pump 1
    Chk '09 悬停(强制): 透明度=20%' ([math]::Abs($window.Opacity - $HOVER_ALPHA) -lt 0.01)
    Chk '10 悬停(强制): 点击穿透样式位已设置' ([bool]([Win32Pin]::GetWindowLong((Get-Hwnd), $GWL_EXSTYLE) -band $WS_EX_TRANSPARENT))
    Chk '10b 主窗口穿透时: 独立按钮层不透明且无穿透位' (([math]::Abs($pinIsland.Opacity - 1.0) -lt 0.01) -and -not ([Win32Pin]::GetWindowLong($ih0, $GWL_EXSTYLE) -band $WS_EX_TRANSPARENT))

    Set-VisualHover $false; Set-Passthrough $false; Invoke-Pump 1
    Chk '11 光标离开(强制): 透明度恢复100%' ([math]::Abs($window.Opacity - 1.0) -lt 0.01)
    Chk '12 光标离开(强制): 穿透位已清除' (-not ([Win32Pin]::GetWindowLong((Get-Hwnd), $GWL_EXSTYLE) -band $WS_EX_TRANSPARENT))

    Invoke-Unpin; Invoke-Pump
    Chk '13 取消置顶: 恢复可编辑' ($ctl['AddPanel'].Visibility -eq 'Visible' -and $ctl['ListPanel'].IsHitTestVisible)
    Chk '13b 取消置顶: 独立按钮层隐藏且主窗口按钮恢复' (-not $pinIsland.IsVisible -and $ctl['BtnPin'].Visibility -eq 'Visible')
    Chk '14 取消置顶: 已恢复非置顶' (-not $window.Topmost)
    Chk '15 取消置顶: 无穿透位' (-not ([Win32Pin]::GetWindowLong((Get-Hwnd), $GWL_EXSTYLE) -band $WS_EX_TRANSPARENT))

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
    Invoke-Pump 35   # > 1000ms 缓冲期
    $ptNow = New-Object Win32Pin+POINT
    [void][Win32Pin]::GetCursorPos([ref]$ptNow)
    Write-Output ("DBG cursorNow=($($ptNow.x),$($ptNow.y)) inside=$(Test-CursorInside) opacity=$($window.Opacity) passthrough=$($script:passthrough)")
    Chk '17 端到端-悬停: 透明度=20%' ([math]::Abs($window.Opacity - $HOVER_ALPHA) -lt 0.01)
    Chk '18 端到端-悬停: 穿透已启用' ($script:passthrough -and [bool]([Win32Pin]::GetWindowLong((Get-Hwnd), $GWL_EXSTYLE) -band $WS_EX_TRANSPARENT))

    # 18b/18c：真实点击穿透——在下层放计数窗口（顶层 z 序低于本窗口），注入真实点击验证落点
    $victimXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        Width="560" Height="560" WindowStartupLocation="Manual" Left="950" Top="450"
        Background="#204020" Title="victim" Topmost="True">
    <TextBlock Name="Vt" Text="VICTIM clicks: 0" Foreground="White" FontSize="24" Margin="20"/>
</Window>
'@
    $victim = [Windows.Markup.XamlReader]::Parse($victimXaml)
    $vt = $victim.FindName('Vt')
    $script:victimClicks = 0
    $victim.Add_MouseLeftButtonDown({ $script:victimClicks++; $vt.Text = "VICTIM clicks: $script:victimClicks" })
    $victim.Show()
    Invoke-Pump 2
    [void]$window.Activate()   # 保证本窗口在顶层 z 序中位于受害窗口之上
    Invoke-Pump 2
    $script:dbgClicks = 0
    [Win32Pin]::mouse_event(0x02, 0, 0, 0, [UIntPtr]::Zero)
    [Win32Pin]::mouse_event(0x04, 0, 0, 0, [UIntPtr]::Zero)
    Invoke-Pump 3
    Write-Output "DBG passthroughClick victim=$script:victimClicks proto=$script:dbgClicks"
    Chk '18b 端到端-穿透: 点击真正落到下层窗口' ($script:victimClicks -ge 1)
    Chk '18c 端到端-穿透: 本窗口未截获点击' ($script:dbgClicks -eq 0)
    $victim.Close()
    Invoke-Pump 1

    # 18d：独立置顶按钮层真实可点——注入真实点击取消置顶，再重新置顶继续后续测试
    $irc = New-Object Win32Pin+RECT
    [void][Win32Pin]::GetWindowRect($ih0, [ref]$irc)
    [void][Win32Pin]::SetCursorPos([int](($irc.left + $irc.right) / 2), [int](($irc.top + $irc.bottom) / 2))
    Invoke-Pump 3
    [Win32Pin]::mouse_event(0x02, 0, 0, 0, [UIntPtr]::Zero)
    [Win32Pin]::mouse_event(0x04, 0, 0, 0, [UIntPtr]::Zero)
    Invoke-Pump 4
    Chk '18d 端到端: 独立置顶按钮可点击取消置顶' ($script:mode -eq 'normal')
    Invoke-Pin; Invoke-Pump 2

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
    $window.Left = $savedLeft; $window.Top = $savedTop   # 不把测试位置写回用户数据
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
