<#
    ShyzosWinFixer - petites réparations Windows en une commande.

    Pour l'instant : vide la RAM sans fermer aucun programme.
      - réduit la mémoire de travail de tous les processus (comme "RAMMap -Ew")
      - vide le cache disque de WSL si une distribution tourne
      - option -Standby : vide aussi la liste de pages en attente (cache)

    Utilisation (PowerShell, de préférence en administrateur) :
      irm https://raw.githubusercontent.com/ShyzosCorp/ShyzosWinFixer/main/ShyzosWinFixer.ps1 | iex

    Ou en local :
      .\ShyzosWinFixer.ps1            # vidage standard
      .\ShyzosWinFixer.ps1 -Standby   # vide aussi le cache en attente
      .\ShyzosWinFixer.ps1 -NoWsl     # ne touche pas à WSL
      .\ShyzosWinFixer.ps1 -Plain     # sans animation
      .\ShyzosWinFixer.ps1 -NoStats   # n'enregistre pas l'XP / le grade

    Compatible Windows PowerShell 5.1 et PowerShell 7. Rien n'est installé.
#>

function Invoke-ShyzosWinFixer {
    [CmdletBinding()]
    param(
        [switch]$Standby,
        [switch]$NoWsl,
        [switch]$NoPause,
        [switch]$Plain,
        [switch]$NoStats,
        [ValidateSet('zombie', 'tactique')]
        [string]$Theme = 'zombie',
        [switch]$Elevated
    )

    $version = '1.2.0'

    # ======================================================================
    #  Fonctions natives (Windows)
    # ======================================================================
    if (-not ('ShyzosWinFixer.Mem' -as [type])) {
        Add-Type -ErrorAction Stop -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace ShyzosWinFixer {
    public static class Mem {
        [StructLayout(LayoutKind.Sequential, Pack = 4)]
        struct TokenPrivileges { public int Count; public long Luid; public int Attributes; }

        [DllImport("ntdll.dll")]
        static extern int NtSetSystemInformation(int infoClass, ref int info, int length);
        [DllImport("advapi32.dll", SetLastError = true)]
        static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
        [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        static extern bool LookupPrivilegeValue(string system, string name, out long luid);
        [DllImport("advapi32.dll", SetLastError = true)]
        static extern bool AdjustTokenPrivileges(IntPtr token, bool disableAll, ref TokenPrivileges state, int length, IntPtr previous, IntPtr returnLength);
        [DllImport("kernel32.dll")]
        static extern IntPtr GetCurrentProcess();
        [DllImport("kernel32.dll")]
        static extern bool CloseHandle(IntPtr handle);

        public static bool EnablePrivilege(string name) {
            IntPtr token;
            if (!OpenProcessToken(GetCurrentProcess(), 0x0028, out token)) return false; // ADJUST_PRIVILEGES | QUERY
            try {
                long luid;
                if (!LookupPrivilegeValue(null, name, out luid)) return false;
                TokenPrivileges tp = new TokenPrivileges { Count = 1, Luid = luid, Attributes = 0x2 }; // SE_PRIVILEGE_ENABLED
                if (!AdjustTokenPrivileges(token, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero)) return false;
                return Marshal.GetLastWin32Error() == 0;
            } finally { CloseHandle(token); }
        }

        // SystemMemoryListInformation = 80
        // 2 = MemoryEmptyWorkingSets, 4 = MemoryPurgeStandbyList
        public static int Command(int command) {
            return NtSetSystemInformation(80, ref command, sizeof(int));
        }
    }

    public static class Con {
        [DllImport("kernel32.dll")] static extern IntPtr GetStdHandle(int handle);
        [DllImport("kernel32.dll")] static extern bool GetConsoleMode(IntPtr handle, out uint mode);
        [DllImport("kernel32.dll")] static extern bool SetConsoleMode(IntPtr handle, uint mode);

        // Active les couleurs/séquences ANSI (ENABLE_VIRTUAL_TERMINAL_PROCESSING)
        public static bool EnableVT() {
            IntPtr h = GetStdHandle(-11);
            uint mode;
            if (!GetConsoleMode(h, out mode)) return false;
            if ((mode & 0x4) != 0) return true;
            return SetConsoleMode(h, mode | 0x4);
        }
    }
}
'@
    }

    # ======================================================================
    #  Interface animée + thèmes ("zombie" par défaut, ou "tactique")
    #  (pièges PowerShell évités : pas de variable $e car $e = $E ; Min/Max avec des doubles)
    # ======================================================================
    $anim = (-not $Plain) -and (-not [Console]::IsOutputRedirected)
    if ($anim) { try { $anim = [ShyzosWinFixer.Con]::EnableVT() } catch { $anim = $false } }
    $wt = [bool]$env:WT_SESSION   # Windows Terminal : police avec plus de symboles

    $ESC = [char]27
    function Get-Rgb([int]$red, [int]$green, [int]$blue) { "$ESC[38;2;$red;$green;${blue}m" }
    $RST  = "$ESC[0m"
    $BOLD = "$ESC[1m"
    $WHT  = Get-Rgb 255 255 255
    $RED  = Get-Rgb 255 60 60
    $ORG  = Get-Rgb 255 128 32

    # Windows Terminal a une police riche ; la console classique n'affiche pas ► ▲ … ★ ☠ (vérifié)
    if ($wt) {
        $SPIN = @('⠋','⠙','⠹','⠸','⠼','⠴','⠦','⠧','⠇','⠏')
        $SYM  = @{ hit = '✕'; star = '★'; warn = '⚠'; up = '▲'; cut = '…'; skull = '☠'; bio = '☣' }
        $ARW  = '►'
    } else {
        $SPIN = @('|','/','-','\')
        $SYM  = @{ hit = 'x'; star = '*'; warn = '!'; up = '^'; cut = '~'; skull = 'x'; bio = '!' }
        $ARW  = '»'
    }

    if ($Theme -eq 'tactique') {
        $AMB   = Get-Rgb 255 184 28      # couleur d'accent (ambre HUD)
        $GRN   = Get-Rgb 120 230 100     # succès
        $DIM   = Get-Rgb 128 128 114
        $DRK   = Get-Rgb 62 64 56
        $stops = @(@(255,214,10), @(255,140,0), @(255,58,40))      # or -> orange -> rouge
        $T = @{
            subtitle   = 'OPÉRATION RAM PURGE'
            plainTitle = 'opération RAM PURGE'
            briefTitle = ' BRIEFING '
            rows       = @('OPÉRATION', 'OBJECTIF', 'CIBLES', 'RAM', 'HEURE')
            rowVals    = @('RAM PURGE', 'libérer la RAM sans rien fermer', '{0} processus', '{0:N1} / {1:N1} Go utilisés')
            alertTag   = "$($SYM.warn) ALERTE"
            countdown  = "DÉBUT DE L'OPÉRATION DANS"
            go         = 'GO GO GO'
            killTitle  = 'CIBLES NEUTRALISÉES'
            killNone   = 'aucune cible significative'
            killMark   = $SYM.hit
            firstTag   = ''
            banner     = 'M I S S I O N   A C C O M P L I E'
            bannerPlain= 'MISSION ACCOMPLIE'
            streakLbl  = 'SÉRIE'
            streaks    = @(@(8, 'FRAPPE MAXIMALE', 'red'), @(4, 'RAFALE DÉVASTATRICE', 'org'), @(2, 'DOUBLE PURGE', 'acc'), @(0.5, 'PURGE RÉUSSIE', 'ok'), @(-999, 'RECONNAISSANCE', 'dim'))
            report     = ' RAPPORT DE MISSION '
            repGain    = 'Mémoire récupérée'
            repCount   = 'Cibles neutralisées'
            repTime    = "Durée de l'opération"
            gradeLbl   = 'GRADE'
            ranks      = @('RECRUE', 'SOLDAT', 'CAPORAL', 'SERGENT', 'LIEUTENANT', 'CAPITAINE', 'COMMANDANT', 'COLONEL', 'GÉNÉRAL', 'LÉGENDE')
            total      = '{0} opération(s) · {1:N1} Go récupérés au total'
            outro      = "$($SYM.star) FIN DE TRANSMISSION $($SYM.star) SHYZOS WIN FIXER"
            noise      = '▓▒░#%&@$'
        }
    } else {
        $AMB   = Get-Rgb 120 255 60      # couleur d'accent (vert toxique)
        $GRN   = Get-Rgb 150 255 90      # succès
        $DIM   = Get-Rgb 120 132 112
        $DRK   = Get-Rgb 52 66 48
        $stops = @(@(140,255,40), @(200,210,30), @(210,25,25))     # vert toxique -> jaune malade -> rouge sang
        $T = @{
            subtitle   = 'SURVIE : LA HORDE DE LA RAM'
            plainTitle = 'survie face à la horde de la RAM'
            briefTitle = ' DOSSIER INFECTION '
            rows       = @('ZONE', 'MISSION', 'HORDE', 'INFECTION', 'HEURE')
            rowVals    = @('mémoire vive', 'survivre sans rien fermer', '{0} processus infectés', '{0:N1} / {1:N1} Go contaminés')
            alertTag   = "$($SYM.bio) ALERTE"
            countdown  = 'LA HORDE ARRIVE DANS'
            go         = 'VAGUE {0} : SURVIS !'
            killTitle  = 'ZOMBIES ÉLIMINÉS'
            killNone   = 'aucun zombie en vue'
            killMark   = $SYM.skull
            firstTag   = 'HEADSHOT'
            banner     = 'V A G U E   S U R V É C U E'
            bannerPlain= 'VAGUE SURVÉCUE'
            streakLbl  = 'SÉRIE'
            streaks    = @(@(8, 'EXTINCTION DE LA HORDE', 'red'), @(4, 'CARNAGE', 'org'), @(2, 'MASSACRE', 'acc'), @(0.5, 'BONNE CHASSE', 'ok'), @(-999, 'SURVIE TRANQUILLE', 'dim'))
            report     = ' RAPPORT DE SURVIE '
            repGain    = 'Mémoire sauvée'
            repCount   = 'Zombies éliminés'
            repTime    = 'Durée de la vague'
            gradeLbl   = 'RANG'
            ranks      = @('SURVIVANT', 'ÉCLAIREUR', 'CHASSEUR', 'TRAQUEUR', 'VÉTÉRAN', 'SENTINELLE', 'NETTOYEUR', 'FLÉAU DES MORTS', 'DERNIER REMPART', "LÉGENDE DE L'APOCALYPSE")
            total      = '{0} vague(s) survécue(s) · {1:N1} Go sauvés au total'
            outro      = "$($SYM.skull) FIN DE LA VAGUE $($SYM.skull) SHYZOS WIN FIXER"
            noise      = '▓▒░#%&@§'
        }
    }

    # Dégradé du thème (64 nuances pré-calculées)
    $GRAD = New-Object 'string[]' 64
    for ($k = 0; $k -lt 64; $k++) {
        $tt = $k / 63.0
        if ($tt -lt 0.5) { $u = $tt * 2; $p = $stops[0]; $q = $stops[1] } else { $u = ($tt - 0.5) * 2; $p = $stops[1]; $q = $stops[2] }
        $GRAD[$k] = Get-Rgb ([int]($p[0] + ($q[0] - $p[0]) * $u)) ([int]($p[1] + ($q[1] - $p[1]) * $u)) ([int]($p[2] + ($q[2] - $p[2]) * $u))
    }

    function Out-Raw([string]$text) { [Console]::Write($text) }
    function Get-Ease([double]$x) { 1 - [math]::Pow(1 - $x, 3) }   # easeOutCubic

    function Get-Painted([string]$text) {
        $sb = New-Object Text.StringBuilder
        $n = [math]::Max(1, $text.Length - 1)
        for ($i = 0; $i -lt $text.Length; $i++) {
            $ch = $text[$i]
            if ($ch -eq ' ') { [void]$sb.Append(' '); continue }
            [void]$sb.Append($GRAD[[int](($i / $n) * 63)]); [void]$sb.Append($ch)
        }
        [void]$sb.Append($RST)
        $sb.ToString()
    }

    function Get-Bar([double]$frac, [int]$width) {
        $frac = [math]::Min([double]1.0, [math]::Max([double]0.0, $frac))
        $full = [int][math]::Round($frac * $width)
        $sb = New-Object Text.StringBuilder
        for ($i = 0; $i -lt $width; $i++) {
            if ($i -lt $full) { [void]$sb.Append($GRAD[[int](($i / [math]::Max(1, $width - 1)) * 63)] + '█') }
            else              { [void]$sb.Append($DRK + '░') }
        }
        [void]$sb.Append($RST)
        $sb.ToString()
    }

    function Format-Size([double]$mb) {
        if ($mb -ge 1024) { '{0:N1} Go' -f ($mb / 1024) } else { '{0:N0} Mo' -f $mb }
    }

    $LOGO = @(
        '███████╗██╗  ██╗██╗   ██╗███████╗ ██████╗ ███████╗',
        '██╔════╝██║  ██║╚██╗ ██╔╝╚══███╔╝██╔═══██╗██╔════╝',
        '███████╗███████║ ╚████╔╝   ███╔╝ ██║   ██║███████╗',
        '╚════██║██╔══██║  ╚██╔╝   ███╔╝  ██║   ██║╚════██║',
        '███████║██║  ██║   ██║   ███████╗╚██████╔╝███████║',
        '╚══════╝╚═╝  ╚═╝   ╚═╝   ╚══════╝ ╚═════╝ ╚══════╝'
    )
    $logoW = $LOGO[0].Length

    function Get-Centered([string]$text, [int]$width) { (' ' * [math]::Max(0, [int](($width - $text.Length) / 2))) + $text }

    # --- Logo : "décryptage" depuis du bruit, puis flash de verrouillage ---
    function Show-Banner {
        if (-not $anim) {
            Write-Host ''
            Write-Host "  SHYZOS WIN FIXER v$version - $($T.plainTitle)" -ForegroundColor $(if ($Theme -eq 'zombie') { 'Green' } else { 'Yellow' })
            Write-Host '  ------------------------------------------------' -ForegroundColor DarkGray
            return
        }
        $rng = New-Object Random
        $noise = $T.noise.ToCharArray()
        $flash = if ($Theme -eq 'zombie') { Get-Rgb 255 40 40 } else { $WHT }     # zombie : flash rouge sang
        $front2 = if ($Theme -eq 'zombie') { $AMB } else { $WHT }               # bord de la "contamination"
        $frames = 16
        Out-Raw "`n"
        for ($f = 0; $f -le $frames + 2; $f++) {
            $front = [int](($f / $frames) * ($logoW + 10)) - 5
            $sb = New-Object Text.StringBuilder
            if ($f -gt 0) { [void]$sb.Append("$ESC[$($LOGO.Count)A") }
            foreach ($line in $LOGO) {
                [void]$sb.Append("`r  ")
                for ($i = 0; $i -lt $line.Length; $i++) {
                    $ch = $line[$i]
                    if ($ch -eq ' ') { [void]$sb.Append(' '); continue }
                    if ($f -eq $frames + 1)      { [void]$sb.Append($flash + $ch) }                  # flash
                    elseif ($i -lt $front)       { [void]$sb.Append($GRAD[[int](($i / ($logoW - 1)) * 63)] + $ch) }
                    elseif ($i -lt $front + 5)   { [void]$sb.Append($front2 + $noise[$rng.Next($noise.Length)]) }
                    else                         { [void]$sb.Append($DRK + $noise[$rng.Next($noise.Length)]) }
                }
                [void]$sb.Append("$RST$ESC[K`n")
            }
            Out-Raw $sb.ToString()
            Start-Sleep -Milliseconds $(if ($f -eq $frames + 1) { 60 } else { 22 })
        }
        $sub = 'W  I  N     F  I  X  E  R'
        Out-Raw ('  ' + (' ' * [math]::Max(0, [int](($logoW - $sub.Length) / 2))) + (Get-Painted $sub) + "`n")
        Out-Raw ("  $DIM" + (Get-Centered "v$version · $($T.subtitle)" $logoW) + "$RST`n`n")
    }

    # --- Texte tapé à la machine (par paquets, pour rester rapide) ---
    function Write-Typed([string]$text, [string]$color) {
        $chunk = [math]::Max(1, [int][math]::Ceiling($text.Length / 7.0))
        for ($i = 0; $i -lt $text.Length; $i += $chunk) {
            Out-Raw ($color + $text.Substring($i, [math]::Min($chunk, $text.Length - $i)) + $RST)
            Start-Sleep -Milliseconds 14
        }
    }

    # --- Briefing de mission ---
    function Show-Briefing($rows) {
        if (-not $anim) {
            foreach ($row in $rows) { Write-Host ('  {0,-11}: {1}' -f $row[0], $row[1]) }
            return
        }
        $boxW = 60
        $title = $T.briefTitle
        Out-Raw ("  $DRK┌─$RST$AMB$BOLD$title$RST$DRK" + ('─' * ($boxW - $title.Length - 1)) + "┐$RST`n")
        foreach ($row in $rows) {
            $label = '{0,-11}' -f $row[0]
            Out-Raw ("  $DRK│$RST  $DIM$label$RST${DRK}: $RST")
            Write-Typed $row[1] $row[2]
            Out-Raw ((' ' * [math]::Max(0, $boxW - (15 + $row[1].Length))) + "$DRK│$RST`n")
        }
        Out-Raw ("  $DRK└" + ('─' * $boxW) + "┘$RST`n")
    }

    function Show-Countdown {
        if (-not $anim) { Write-Host ''; return }
        Out-Raw "`n"
        foreach ($n in '3', '2', '1') {
            Out-Raw ("`r  $AMB$BOLD$ARW $($T.countdown) $WHT$n$RST$ESC[K")
            Start-Sleep -Milliseconds 220
        }
        $goColor = if ($Theme -eq 'zombie') { $RED } else { $GRN }
        Out-Raw ("`r  $goColor$BOLD$ARW " + ($T.go -f $wave) + "$RST$ESC[K`n`n")
    }

    # --- Étapes : le travail tourne en arrière-plan pendant que le spinner tourne ---
    function Invoke-Step([string]$label, [scriptblock]$script, $argument) {
        if (-not $anim) {
            Write-Host "  [ .. ] $label"
            return (& $script $argument)
        }
        $ps = [PowerShell]::Create()
        [void]$ps.AddScript($script.ToString()).AddArgument($argument)
        $handle = $ps.BeginInvoke()
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $i = 0
        while (-not $handle.IsCompleted -or $sw.ElapsedMilliseconds -lt 450) {
            $dots = '.' * ([int]($i / 3) % 4)
            Out-Raw ("`r  $DRK[$RST $AMB" + $SPIN[$i % $SPIN.Count] + "$RST  $DRK]$RST $label$DIM$dots$RST$ESC[K")
            Start-Sleep -Milliseconds 70
            $i++
        }
        try { $out = $ps.EndInvoke($handle) } finally { $ps.Dispose() }
        # Une collection qui contient seulement 0 est "fausse" en PowerShell : on teste $null et Count
        if ($null -ne $out -and $out.Count -gt 0) { return $out[$out.Count - 1] }
        return $null
    }

    function Complete-Step([string]$state, [string]$text) {
        switch ($state) {
            'ok'    { $tag = ' OK '; $c = $GRN; $cc = 'Green' }
            'warn'  { $tag = 'WARN'; $c = $AMB; $cc = 'Yellow' }
            default { $tag = 'FAIL'; $c = $RED; $cc = 'Red' }
        }
        if (-not $anim) { Write-Host "  [$tag] $text" -ForegroundColor $cc; return }
        Out-Raw ("`r  $DRK[$RST$c$BOLD$tag$RST$DRK]$RST $text$ESC[K`n")
    }

    function Show-Note([string]$state, [string]$text) {
        if (-not $anim) {
            if ($state -eq 'warn') { Write-Host "  ! $text" -ForegroundColor Yellow } else { Write-Host "  $text" }
            return
        }
        if ($state -eq 'warn') { Out-Raw ("  $RED$BOLD$($T.alertTag)$RST $AMB$text$RST`n") }
        else { Out-Raw ("  $DIM$ARW $text$RST`n") }
    }

    # --- Kill feed : les vrais processus qui ont libéré le plus de RAM ---
    function Show-Killfeed($targets, [int]$count) {
        if (-not $anim) {
            Write-Host ''
            Write-Host "  $($T.killTitle) : $count"
            foreach ($tg in $targets) { Write-Host ('    {0,-24} -{1}' -f $tg.Name, (Format-Size $tg.Freed)) }
            return
        }
        $title = " $($T.killTitle) : $count "
        Out-Raw ("`n  $DRK──$RST$AMB$BOLD$title$RST$DRK" + ('─' * [math]::Max(0, 46 - $title.Length)) + "$RST`n")
        if (-not $targets) { Out-Raw "  $DIM$ARW $($T.killNone)$RST`n"; return }
        $mark = $T.killMark
        $first = $true
        foreach ($tg in $targets) {
            $nm = [string]$tg.Name
            if ($nm.Length -gt 22) { $nm = $nm.Substring(0, 21) + $SYM.cut }
            $lead = '·' * [math]::Max(2, 26 - $nm.Length)
            $amt = ('-' + (Format-Size $tg.Freed)).PadLeft(9)
            $base = "`r  $AMB$ARW$RST $WHT$nm$RST $DRK$lead$RST "
            $tag = if ($first) { "  $RED$BOLD$($T.firstTag)$RST" } else { '' }
            Out-Raw ($base + "$RED$BOLD$mark$RST  $WHT$BOLD$amt$RST$ESC[K")       # hitmarker
            Start-Sleep -Milliseconds $(if ($first) { 140 } else { 70 })
            Out-Raw ($base + "$DIM$mark$RST  $AMB$amt$RST$tag$ESC[K`n")
            Start-Sleep -Milliseconds 35
            $first = $false
        }
    }

    # --- "MISSION ACCOMPLIE" qui se déploie depuis le centre ---
    function Show-MissionBanner([string]$streak, [string]$streakColor) {
        if (-not $anim) {
            Write-Host ''
            Write-Host "  $($T.bannerPlain)" -ForegroundColor Green
            Write-Host "  $($T.streakLbl) : $streak"
            return
        }
        $text = $T.banner
        $bw = 52
        $half = [int]($bw / 2)
        $tpad = ' ' * [math]::Max(0, [int](($bw - $text.Length) / 2))
        Out-Raw "`n`n`n`n"
        $steps = 9
        for ($s = 0; $s -le $steps + 6; $s++) {
            $k = [int]([math]::Min([double]1.0, $s / [double]$steps) * $half)
            $line = (' ' * ($half - $k)) + ('═' * (2 * $k))
            $shown = $text.Substring(0, [int]($text.Length * [math]::Min([double]1.0, $s / [double]$steps)))
            if ($s -gt $steps) { $tc = $(if ($s % 2 -eq 0) { $WHT } else { $GRN }) } else { $tc = $WHT }   # flash
            Out-Raw ("$ESC[3A`r  $AMB$line$RST$ESC[K`n`r  $tc$BOLD$tpad$shown$RST$ESC[K`n`r  $AMB$line$RST$ESC[K`n")
            Start-Sleep -Milliseconds $(if ($s -gt $steps) { 70 } else { 20 })
        }
        Out-Raw ("$ESC[2A`r  $GRN$BOLD$tpad$text$RST$ESC[K`n$ESC[1B")
        $sl = "$ARW $($T.streakLbl) : "
        Out-Raw ("  " + (' ' * [math]::Max(0, [int](($bw - $sl.Length - $streak.Length) / 2))) + "$DIM$sl$RST$streakColor$BOLD$streak$RST`n")
    }

    # --- Rapport de mission (barres + compteurs animés) ---
    function Show-Report($before, $after, [int]$count, [double]$secs) {
        $gain = $before.Used - $after.Used
        if (-not $anim) {
            Write-Host ''
            Write-Host ('  Avant               : {0,5:N1} Go utilisés' -f $before.Used)
            Write-Host ('  Après               : {0,5:N1} Go utilisés' -f $after.Used)
            if ($gain -gt 0) { Write-Host ('  {0,-19} : {1:N1} Go' -f $T.repGain, $gain) -ForegroundColor Green }
            else { Write-Host ('  {0,-19} : rien de plus pour le moment' -f $T.repGain) -ForegroundColor Yellow }
            Write-Host ('  {0,-19} : {1}' -f $T.repCount, $count)
            Write-Host ('  Durée               : {0:N1} s' -f $secs)
            return
        }
        $boxW = 52
        $title = $T.report
        $lg = $T.repGain.PadRight(22); $lc = $T.repCount.PadRight(22); $lt = $T.repTime.PadRight(22)
        $frames = 20
        for ($f = 0; $f -le $frames; $f++) {
            $ease = Get-Ease ($f / [double]$frames)
            $bv = '{0,5:N1}' -f ($before.Used * $ease)
            $av = '{0,5:N1}' -f ($after.Used * $ease)
            $gv = '{0:N1}' -f ([math]::Max([double]0.0, [double]$gain) * $ease)
            $cv = [int]($count * $ease)
            $rows = @(
                @(('  Avant       ' + ('x' * 24) + "  $bv Go"), ("  ${DIM}Avant$RST       " + (Get-Bar (($before.Used / $before.Total) * $ease) 24) + "  $bv Go")),
                @(('  Après       ' + ('x' * 24) + "  $av Go"), ("  ${BOLD}Après$RST       " + (Get-Bar (($after.Used / $after.Total) * $ease) 24) + "  $BOLD$av$RST Go")),
                @('', '')
            )
            if ($gain -gt 0.05) { $rows += ,@(("  $lg+ $gv Go"), ("  $DIM$lg$RST$GRN$BOLD+ $gv Go$RST")) }
            else { $rows += ,@(("  ${lg}rien de plus pour le moment"), ("  $DIM$lg$RST${AMB}rien de plus pour le moment$RST")) }
            $rows += ,@(("  $lc$cv"), ("  $DIM$lc$RST$WHT$cv$RST"))
            $rows += ,@(("  $lt" + ('{0:N1} s' -f $secs)), ("  $DIM$lt$RST$WHT" + ('{0:N1} s' -f $secs) + $RST))
            $sb = New-Object Text.StringBuilder
            if ($f -gt 0) { [void]$sb.Append("$ESC[$($rows.Count + 2)A") }
            [void]$sb.Append("`r  $DRK┌─$RST$AMB$BOLD$title$RST$DRK" + ('─' * ($boxW - $title.Length - 1)) + "┐$RST$ESC[K`n")
            foreach ($row in $rows) {
                [void]$sb.Append("`r  $DRK│$RST" + $row[1] + (' ' * [math]::Max(0, $boxW - $row[0].Length)) + "$DRK│$RST$ESC[K`n")
            }
            [void]$sb.Append("`r  $DRK└" + ('─' * $boxW) + "┘$RST$ESC[K`n")
            Out-Raw $sb.ToString()
            Start-Sleep -Milliseconds 26
        }
    }

    # --- XP et grades (sauvegardés dans %LOCALAPPDATA%\ShyzosWinFixer\stats.json) ---
    $xpSteps = @(0, 500, 1500, 3000, 5500, 9000, 14000, 21000, 30000, 45000)
    $RANKS = @()
    for ($i = 0; $i -lt $xpSteps.Count; $i++) { $RANKS += ,@($T.ranks[$i], $xpSteps[$i]) }

    function Get-Stats {
        $s = [pscustomobject]@{ xp = 0; runs = 0; totalGB = 0.0 }
        if ($NoStats) { return $s }
        try {
            $file = Join-Path (Join-Path $env:LOCALAPPDATA 'ShyzosWinFixer') 'stats.json'
            if (Test-Path $file) {
                $o = Get-Content $file -Raw | ConvertFrom-Json
                $s.xp = [int]$o.xp; $s.runs = [int]$o.runs; $s.totalGB = [double]$o.totalGB
            }
        } catch { }
        $s
    }
    function Get-RankIndex([int]$xp) {
        $idx = 0
        for ($i = 0; $i -lt $RANKS.Count; $i++) { if ($xp -ge $RANKS[$i][1]) { $idx = $i } }
        $idx
    }

    function Update-Stats([double]$gainGB) {
        $gained = [int]([math]::Max([double]0.0, $gainGB) * 100) + 25      # 100 XP par Go + 25 XP de mission
        $res = [pscustomobject]@{ OldXp = 0; NewXp = $gained; Gained = $gained; Runs = 1; TotalGB = [math]::Max([double]0.0, $gainGB) }
        if ($NoStats) { return $res }
        try {
            $dir  = Join-Path $env:LOCALAPPDATA 'ShyzosWinFixer'
            $file = Join-Path $dir 'stats.json'
            if (Test-Path $file) {
                $old = Get-Content $file -Raw | ConvertFrom-Json
                $res.OldXp   = [int]$old.xp
                $res.NewXp   = $res.OldXp + $gained
                $res.Runs    = [int]$old.runs + 1
                $res.TotalGB = [double]$old.totalGB + $res.TotalGB
            }
            if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            @{ xp = $res.NewXp; runs = $res.Runs; totalGB = [math]::Round($res.TotalGB, 2) } | ConvertTo-Json | Set-Content -Path $file -Encoding UTF8
        } catch { }
        $res
    }

    function Show-Rank($st) {
        $oldIdx = Get-RankIndex $st.OldXp
        $newIdx = Get-RankIndex $st.NewXp
        if (-not $anim) {
            Write-Host ''
            Write-Host ("  {0} : {1}  ({2} XP, +{3} XP)" -f $T.gradeLbl, $RANKS[$newIdx][0], $st.NewXp, $st.Gained)
            if ($newIdx -gt $oldIdx) { Write-Host ("  PROMOTION : {0}" -f $RANKS[$newIdx][0]) -ForegroundColor Green }
            return
        }
        Out-Raw "`n"
        $frames = 22
        for ($f = 0; $f -le $frames; $f++) {
            $xp  = [int]($st.OldXp + $st.Gained * (Get-Ease ($f / [double]$frames)))
            $idx = Get-RankIndex $xp
            $cur = $RANKS[$idx][1]
            $nxt = if ($idx + 1 -lt $RANKS.Count) { $RANKS[$idx + 1][1] } else { $cur + 10000 }
            $frac = ($xp - $cur) / [double]($nxt - $cur)
            $name = $RANKS[$idx][0]
            $gainTxt = "+$([int]($st.Gained * (Get-Ease ($f / [double]$frames)))) XP"
            $l1 = "  $AMB$BOLD$($SYM.star) $($T.gradeLbl) : $WHT$name$RST" + (' ' * [math]::Max(1, 40 - $name.Length - ($T.gradeLbl.Length - 5))) + "$GRN$BOLD$gainTxt$RST$ESC[K"
            $l2 = '  ' + (Get-Bar $frac 34) + "  $DIM" + ('{0} / {1} XP' -f $xp, $nxt) + "$RST$ESC[K"
            if ($f -gt 0) { Out-Raw "$ESC[2A" }
            Out-Raw ("`r$l1`n`r$l2`n")
            Start-Sleep -Milliseconds 28
        }
        if ($newIdx -gt $oldIdx) {
            $promo = "$($SYM.star) PROMOTION : $($RANKS[$newIdx][0]) $($SYM.star)"
            Out-Raw "`n"
            for ($j = 0; $j -lt 6; $j++) {
                $c = if ($j % 2 -eq 0) { $WHT } else { $AMB }
                Out-Raw ("`r  $c$BOLD$($SYM.up) $promo $($SYM.up)$RST$ESC[K")
                Start-Sleep -Milliseconds 90
            }
            Out-Raw "`n"
        }
    }

    function Get-RamState {
        $os = Get-CimInstance Win32_OperatingSystem
        $totalGB = $os.TotalVisibleMemorySize / 1MB
        $freeGB  = $os.FreePhysicalMemory / 1MB
        [pscustomobject]@{ Total = $totalGB; Used = $totalGB - $freeGB }
    }

    function Wait-Key {
        if ($Elevated -and -not $NoPause) {
            if ($anim) { Out-Raw "`n  ${DIM}Appuie sur Entrée pour fermer$RST "; [void][Console]::ReadLine() }
            else { Write-Host ''; [void](Read-Host 'Appuie sur Entrée pour fermer') }
        }
    }

    # ======================================================================
    #  Programme
    # ======================================================================
    $cursor = $null
    if ($anim) { try { $cursor = [Console]::CursorVisible; [Console]::CursorVisible = $false } catch { } }
    try {
        # --- Droits administrateur : on se relance tout seul en admin si besoin ---
        $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
                   ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        if (-not $isAdmin) {
            if ($Elevated) {
                Show-Banner
                Complete-Step 'err' "Impossible d'obtenir les droits administrateur."
                Wait-Key
                return
            }
            # Pas de grand logo ici : il s'affichera une seule fois, dans la fenêtre admin
            if ($anim) { Out-Raw ("`n  " + (Get-Painted "$($SYM.star) SHYZOS WIN FIXER") + "  ${DIM}v$version$RST`n") }
            else { Write-Host ''; Write-Host "  SHYZOS WIN FIXER v$version" -ForegroundColor Yellow }
            Show-Note 'info' 'Droits administrateur nécessaires : Windows va te demander une confirmation (UAC).'
            $body = "function Invoke-ShyzosWinFixer {`n" + ${function:Invoke-ShyzosWinFixer}.ToString() + "`n}`nInvoke-ShyzosWinFixer @args`n"
            $tmp = Join-Path $env:TEMP 'ShyzosWinFixer.ps1'
            [IO.File]::WriteAllText($tmp, $body, (New-Object Text.UTF8Encoding($true)))
            $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$tmp`"", '-Elevated')
            if ($Standby) { $argList += '-Standby' }
            if ($NoWsl)   { $argList += '-NoWsl' }
            if ($NoPause) { $argList += '-NoPause' }
            if ($Plain)   { $argList += '-Plain' }
            if ($NoStats) { $argList += '-NoStats' }
            $argList += @('-Theme', $Theme)
            $hostExe = (Get-Process -Id $PID).Path
            try {
                Start-Process -FilePath $hostExe -ArgumentList $argList -Verb RunAs -ErrorAction Stop | Out-Null
                Complete-Step 'ok' 'La suite se passe dans la fenêtre administrateur qui vient de s''ouvrir.'
            } catch {
                Complete-Step 'err' 'Confirmation UAC refusée : rien n''a été modifié.'
            }
            return
        }

        Show-Banner

        # --- Reconnaissance ---
        $games = 'FortniteClient-Win64-Shipping','VALORANT-Win64-Shipping','cs2','RobloxPlayerBeta',
                 'r5apex','GTA5','League of Legends','RainbowSix','cod','FC25','FC26','eldenring','javaw'
        $allProcs = @(Get-Process -ErrorAction SilentlyContinue)
        $runningGames = $allProcs | Where-Object { $games -contains $_.Name } | Select-Object -ExpandProperty Name -Unique
        $snap = @{}
        foreach ($pr in $allProcs) { $snap[$pr.Id] = @($pr.ProcessName, $pr.WorkingSet64) }
        $before = Get-RamState

        $distros = @()
        if (-not $NoWsl -and (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
            try {
                $all     = @((& wsl.exe -l -q 2>$null) | ForEach-Object { ($_ -replace "`0", '').Trim() } | Where-Object { $_ })
                $distros = @((& wsl.exe -l --running -q 2>$null) | ForEach-Object { ($_ -replace "`0", '').Trim() } |
                             Where-Object { $_ -and ($all -contains $_) })
            } catch { $distros = @() }
        }

        $targetsTxt = $T.rowVals[2] -f $allProcs.Count
        if ($distros.Count -gt 0) { $targetsTxt += " · WSL ($($distros -join ', '))" }
        $wave = (Get-Stats).runs + 1
        $zone = if ($Theme -eq 'zombie') { "$($T.rowVals[0]) · vague $wave" } else { $T.rowVals[0] }
        Show-Briefing @(
            @($T.rows[0], $zone, "$AMB$BOLD"),
            @($T.rows[1], $T.rowVals[1], $WHT),
            @($T.rows[2], $targetsTxt, $WHT),
            @($T.rows[3], ($T.rowVals[3] -f $before.Used, $before.Total), $WHT),
            @($T.rows[4], (Get-Date -Format 'HH:mm:ss'), $WHT)
        )
        if ($runningGames) {
            Show-Note 'warn' ("jeu détecté ({0}) : petit lag possible quelques secondes" -f ($runningGames -join ', '))
        }
        Show-Countdown
        $opWatch = [Diagnostics.Stopwatch]::StartNew()

        # --- WSL : vide le cache disque de Linux (sans arrêter les distributions) ---
        foreach ($dist in $distros) {
            $code = Invoke-Step "WSL ($dist) : vidage du cache Linux" {
                param($distro)
                & wsl.exe -d $distro -u root -- sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches' 2>$null | Out-Null
                $LASTEXITCODE
            } $dist
            if ($code -eq 0) { Complete-Step 'ok' "WSL ($dist) : cache vidé" }
            else { Complete-Step 'warn' "WSL ($dist) : impossible de vider le cache" }
        }

        # --- Appel direct à Windows (même fonction que RAMMap) ---
        if (-not [ShyzosWinFixer.Mem]::EnablePrivilege('SeProfileSingleProcessPrivilege')) {
            Complete-Step 'err' 'Privilège système refusé (SeProfileSingleProcessPrivilege).'
            Wait-Key
            return
        }
        [void][ShyzosWinFixer.Mem]::EnablePrivilege('SeIncreaseQuotaPrivilege')

        $status = Invoke-Step 'Réduction de la mémoire des processus' { param($x) [ShyzosWinFixer.Mem]::Command(2) } $null
        if ($null -eq $status) {
            Complete-Step 'err' 'Pas de réponse de Windows pour la réduction de mémoire.'
            Wait-Key
            return
        }
        if ($status -ne 0) {
            Complete-Step 'err' ('Windows a refusé la commande (code 0x{0:X8}).' -f [int]$status)
            Wait-Key
            return
        }
        Complete-Step 'ok' 'Mémoire des processus réduite'

        if ($Standby) {
            $status = Invoke-Step 'Vidage du cache en attente' { param($x) [ShyzosWinFixer.Mem]::Command(4) } $null
            if ($status -eq 0) { Complete-Step 'ok' 'Cache en attente vidé' }
            else { Complete-Step 'warn' ('Cache en attente : refusé (code 0x{0:X8})' -f [int]$status) }
        }

        # --- Stabilisation : attend que la RAM arrête de descendre (2 mesures de suite, 12 s max) ---
        #     (si un jeu tourne, la RAM remonte vite : on ne cherche pas une valeur parfaitement stable)
        $last = (Get-RamState).Used
        $stable = 0
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $nextPoll = 600
        $i = 0
        if (-not $anim) { Write-Host '  [ .. ] Stabilisation de la mémoire' }
        while ($stable -lt 2 -and $sw.ElapsedMilliseconds -lt 12000) {
            if ($anim) {
                Out-Raw ("`r  $DRK[$RST $AMB" + $SPIN[$i % $SPIN.Count] + "$RST  $DRK]$RST Stabilisation  " +
                         (Get-Bar ($last / $before.Total) 24) + ('  {0,5:N1} Go' -f $last) + "$ESC[K")
                Start-Sleep -Milliseconds 80
                $i++
            } else {
                Start-Sleep -Milliseconds 600
            }
            if ($sw.ElapsedMilliseconds -ge $nextPoll) {
                $now = (Get-RamState).Used
                if (($last - $now) -lt 0.1) { $stable++ } else { $stable = 0 }   # ne descend plus (ou remonte)
                $last = $now
                $nextPoll = $sw.ElapsedMilliseconds + 600
            }
        }
        Complete-Step 'ok' 'Mémoire stabilisée'
        $opWatch.Stop()

        # --- Bilan : qui a libéré quoi ---
        $after = Get-RamState
        $freedByName = @{}
        $count = 0
        foreach ($pr in @(Get-Process -ErrorAction SilentlyContinue)) {
            if ($snap.ContainsKey($pr.Id)) {
                $delta = ($snap[$pr.Id][1] - $pr.WorkingSet64) / 1MB
                if ($delta -gt 1) {
                    $count++
                    $freedByName[$pr.ProcessName] = [double]$freedByName[$pr.ProcessName] + $delta
                }
            }
        }
        $targets = @($freedByName.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 6 |
                     ForEach-Object { [pscustomobject]@{ Name = $_.Key; Freed = $_.Value } })

        $gain = $before.Used - $after.Used
        $palette = @{ red = $RED; org = $ORG; acc = $AMB; ok = $GRN; dim = $DIM }
        foreach ($sk in $T.streaks) {
            if ($gain -ge $sk[0]) { $streak = $sk[1]; $streakColor = $palette[$sk[2]]; break }
        }

        Show-Killfeed $targets $count
        Show-MissionBanner $streak $streakColor
        Show-Report $before $after $count $opWatch.Elapsed.TotalSeconds
        $st = Update-Stats $gain
        Show-Rank $st

        if ($anim) {
            Out-Raw ("`n  $DIM$ARW Normal : ça remonte petit à petit, chaque programme recharge ce dont il a besoin.$RST`n")
            Out-Raw ("  $DIM$ARW " + ($T.total -f $st.Runs, $st.TotalGB) + "$RST`n")
            Out-Raw ("`n  " + (Get-Painted $T.outro) + "`n")
        } else {
            Write-Host ''
            Write-Host '  Normal : ça remonte petit à petit, chaque programme recharge ce dont il a besoin.' -ForegroundColor DarkGray
            Write-Host ('  ' + ($T.total -f $st.Runs, $st.TotalGB)) -ForegroundColor DarkGray
        }
        Wait-Key
    }
    finally {
        if ($anim) {
            Out-Raw $RST
            try { if ($null -ne $cursor) { [Console]::CursorVisible = $cursor } else { [Console]::CursorVisible = $true } } catch { }
        }
    }
}

Invoke-ShyzosWinFixer @args
