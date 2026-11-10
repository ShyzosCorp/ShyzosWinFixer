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

    Compatible Windows PowerShell 5.1 et PowerShell 7. Rien n'est installé.
#>

function Invoke-ShyzosWinFixer {
    [CmdletBinding()]
    param(
        [switch]$Standby,
        [switch]$NoWsl,
        [switch]$NoPause,
        [switch]$Plain,
        [switch]$Elevated
    )

    $version = '1.1.1'

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
    #  Interface : animations si la console le permet, texte simple sinon
    # ======================================================================
    $anim = (-not $Plain) -and (-not [Console]::IsOutputRedirected)
    if ($anim) { try { $anim = [ShyzosWinFixer.Con]::EnableVT() } catch { $anim = $false } }
    $wt = [bool]$env:WT_SESSION   # Windows Terminal : police avec plus de symboles

    $E    = [char]27
    $RST  = "$E[0m"
    $DIM  = "$E[38;2;120;128;150m"
    $BOLD = "$E[1m"
    $GRN  = "$E[38;2;74;222;128m"
    $YEL  = "$E[38;2;250;204;21m"
    $RED  = "$E[38;2;248;113;113m"
    $WHT  = "$E[38;2;255;255;255m"

    if ($wt) {
        $SPIN = @('⠋','⠙','⠹','⠸','⠼','⠴','⠦','⠧','⠇','⠏')
        $SYM  = @{ ok = '✔'; warn = '⚠'; err = '✖'; star = '✦'; dot = '·' }
    } else {
        $SPIN = @('|','/','-','\')
        $SYM  = @{ ok = '+'; warn = '!'; err = 'x'; star = '*'; dot = '-' }
    }

    # Dégradé cyan -> indigo -> magenta (64 nuances pré-calculées)
    $GRAD = New-Object 'string[]' 64
    $stops = @(@(0,229,255), @(110,99,255), @(217,70,239))
    for ($k = 0; $k -lt 64; $k++) {
        $t = $k / 63.0
        if ($t -lt 0.5) { $u = $t * 2; $p = $stops[0]; $q = $stops[1] } else { $u = ($t - 0.5) * 2; $p = $stops[1]; $q = $stops[2] }
        $r = [int]($p[0] + ($q[0] - $p[0]) * $u)
        $g = [int]($p[1] + ($q[1] - $p[1]) * $u)
        $b = [int]($p[2] + ($q[2] - $p[2]) * $u)
        $GRAD[$k] = "$E[38;2;$r;$g;${b}m"
    }

    function Out-Raw([string]$text) { [Console]::Write($text) }

    function Get-Painted([string]$text, [int]$shine = -100) {
        $sb = New-Object Text.StringBuilder
        $n = [math]::Max(1, $text.Length - 1)
        for ($i = 0; $i -lt $text.Length; $i++) {
            $ch = $text[$i]
            if ($ch -eq ' ') { [void]$sb.Append(' '); continue }
            $dist = [math]::Abs($i - $shine)
            if ($dist -le 1)     { [void]$sb.Append($WHT) }
            elseif ($dist -le 3) { [void]$sb.Append("$E[38;2;200;235;255m") }
            else                 { [void]$sb.Append($GRAD[[int](($i / $n) * 63)]) }
            [void]$sb.Append($ch)
        }
        [void]$sb.Append($RST)
        $sb.ToString()
    }

    function Get-Bar([double]$frac, [int]$width) {
        # 0.0 / 1.0 (et pas 0 / 1) : sinon PowerShell choisit la version "entiers" de Min/Max et arrondit
        $frac = [math]::Min([double]1.0, [math]::Max([double]0.0, $frac))
        $full = [int][math]::Round($frac * $width)
        $sb = New-Object Text.StringBuilder
        for ($i = 0; $i -lt $width; $i++) {
            if ($i -lt $full) { [void]$sb.Append($GRAD[[int](($i / [math]::Max(1, $width - 1)) * 63)] + '█') }
            else              { [void]$sb.Append("$E[38;2;55;60;80m" + '░') }
        }
        [void]$sb.Append($RST)
        $sb.ToString()
    }

    $LOGO = @(
        '███████╗██╗  ██╗██╗   ██╗███████╗ ██████╗ ███████╗',
        '██╔════╝██║  ██║╚██╗ ██╔╝╚══███╔╝██╔═══██╗██╔════╝',
        '███████╗███████║ ╚████╔╝   ███╔╝ ██║   ██║███████╗',
        '╚════██║██╔══██║  ╚██╔╝   ███╔╝  ██║   ██║╚════██║',
        '███████║██║  ██║   ██║   ███████╗╚██████╔╝███████║',
        '╚══════╝╚═╝  ╚═╝   ╚═╝   ╚══════╝ ╚═════╝ ╚══════╝'
    )

    function Show-Banner {
        if (-not $anim) {
            Write-Host ''
            Write-Host "  ShyzosWinFixer v$version - vidage de RAM" -ForegroundColor Magenta
            Write-Host '  ----------------------------------------' -ForegroundColor DarkGray
            return
        }
        Out-Raw "`n"
        foreach ($line in $LOGO) {                       # apparition ligne par ligne
            Out-Raw ('  ' + (Get-Painted $line) + "`n")
            Start-Sleep -Milliseconds 35
        }
        $w = $LOGO[0].Length
        for ($s = -4; $s -le $w + 4; $s += 4) {          # reflet qui balaie le logo
            $frame = New-Object Text.StringBuilder
            [void]$frame.Append("$E[$($LOGO.Count)A")
            foreach ($line in $LOGO) { [void]$frame.Append("`r  " + (Get-Painted $line $s) + "`n") }
            Out-Raw $frame.ToString()
            Start-Sleep -Milliseconds 16
        }
        $sub = 'W  I  N     F  I  X  E  R'
        $pad = ' ' * [math]::Max(0, [int](($w - $sub.Length) / 2))
        Out-Raw ('  ' + $pad + (Get-Painted $sub) + "`n")
        Out-Raw ("  $DIM" + (' ' * [math]::Max(0, [int](($w - 36) / 2))) + "v$version $($SYM.dot) vidage de RAM sans rien fermer$RST`n`n")
    }

    # Lance un bloc en arrière-plan et anime un spinner pendant qu'il tourne
    function Invoke-Step([string]$label, [scriptblock]$script, $argument) {
        if (-not $anim) {
            Write-Host "  > $label" -ForegroundColor Cyan
            return (& $script $argument)
        }
        $ps = [PowerShell]::Create()
        [void]$ps.AddScript($script.ToString()).AddArgument($argument)
        $handle = $ps.BeginInvoke()
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $i = 0
        while (-not $handle.IsCompleted -or $sw.ElapsedMilliseconds -lt 500) {
            $dots = '.' * ([int]($i / 3) % 4)
            Out-Raw ("`r  " + $GRAD[($i * 4) % 64] + $SPIN[$i % $SPIN.Count] + "$RST $label$DIM$dots$RST$E[K")
            Start-Sleep -Milliseconds 70
            $i++
        }
        try { $out = $ps.EndInvoke($handle) } finally { $ps.Dispose() }
        # Attention : une collection qui contient seulement 0 est "fausse" en PowerShell,
        # donc on teste $null et Count explicitement.
        if ($null -ne $out -and $out.Count -gt 0) { return $out[$out.Count - 1] }
        return $null
    }

    function Complete-Step([string]$state, [string]$text) {
        if (-not $anim) {
            switch ($state) {
                'ok'   { Write-Host "  + $text" -ForegroundColor Green }
                'warn' { Write-Host "  ! $text" -ForegroundColor Yellow }
                default { Write-Host "  x $text" -ForegroundColor Red }
            }
            return
        }
        switch ($state) {
            'ok'   { $c = $GRN; $s = $SYM.ok }
            'warn' { $c = $YEL; $s = $SYM.warn }
            default { $c = $RED; $s = $SYM.err }
        }
        Out-Raw ("`r  $c$s$RST $text$E[K`n")
    }

    function Show-Note([string]$state, [string]$text) {
        if (-not $anim) {
            if ($state -eq 'warn') { Write-Host "  ! $text" -ForegroundColor Yellow } else { Write-Host "  $text" }
            return
        }
        $c = if ($state -eq 'warn') { $YEL } else { $DIM }
        $s = if ($state -eq 'warn') { $SYM.warn } else { $SYM.dot }
        Out-Raw ("  $c$s $text$RST`n")
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

    function Show-Result($before, $after) {
        $gain = $before.Used - $after.Used
        if (-not $anim) {
            Write-Host ''
            Write-Host ('  Avant : {0,5:N1} Go utilisés' -f $before.Used)
            Write-Host ('  Après : {0,5:N1} Go utilisés' -f $after.Used)
            if ($gain -gt 0) { Write-Host ('  Gain  : {0,5:N1} Go libérés' -f $gain) -ForegroundColor Green }
            else { Write-Host '  Gain  : rien de plus à libérer pour le moment.' -ForegroundColor Yellow }
            Write-Host ''
            Write-Host '  Normal : ça remonte petit à petit, chaque programme recharge ce dont il a besoin.' -ForegroundColor DarkGray
            return
        }
        $W = 46
        $border = "$E[38;2;70;76;105m"
        # Coins arrondis seulement dans Windows Terminal (la console classique ne les affiche pas)
        if ($wt) { $cTL = '╭'; $cTR = '╮'; $cBL = '╰'; $cBR = '╯' } else { $cTL = '┌'; $cTR = '┐'; $cBL = '└'; $cBR = '┘' }
        $steps = 22
        for ($f = 0; $f -le $steps; $f++) {
            # Attention : pas de variable "$e" ici, PowerShell ne distingue pas $e de $E (caractère d'échappement)
            $ease = 1 - [math]::Pow(1 - ($f / $steps), 3)        # easeOutCubic
            $bv = '{0,5:N1}' -f ($before.Used * $ease)
            $av = '{0,5:N1}' -f ($after.Used * $ease)
            $gv = '{0:N1}' -f ([math]::Max([double]0.0, [double]$gain) * $ease)
            $rows = @(
                @(('  Avant    ' + ('x' * 24) + "  $bv Go"),
                  ("  ${DIM}Avant$RST    " + (Get-Bar (($before.Used / $before.Total) * $ease) 24) + "  $bv Go")),
                @(('  Après    ' + ('x' * 24) + "  $av Go"),
                  ("  ${BOLD}Après$RST    " + (Get-Bar (($after.Used / $after.Total) * $ease) 24) + "  $BOLD$av$RST Go")),
                @('', '')
            )
            if ($gain -gt 0.05) {
                $rows += ,@(("  $($SYM.star) Libéré   + $gv Go"),
                            ("  " + $GRAD[[int]($ease * 63)] + "$($SYM.star)$RST ${BOLD}Libéré$RST   $GRN$BOLD+ $gv Go$RST"))
            } else {
                $rows += ,@(("  $($SYM.star) Rien de plus à libérer pour l'instant"),
                            ("  $YEL$($SYM.star) Rien de plus à libérer pour l'instant$RST"))
            }
            $sb = New-Object Text.StringBuilder
            if ($f -gt 0) { [void]$sb.Append("$E[$($rows.Count + 2)A") }
            [void]$sb.Append("`r  $border$cTL" + ('─' * $W) + "$cTR$RST$E[K`n")
            foreach ($row in $rows) {
                $padding = ' ' * [math]::Max(0, $W - $row[0].Length)
                [void]$sb.Append("`r  $border│$RST" + $row[1] + $padding + "$border│$RST$E[K`n")
            }
            [void]$sb.Append("`r  $border$cBL" + ('─' * $W) + "$cBR$RST$E[K`n")
            Out-Raw $sb.ToString()
            Start-Sleep -Milliseconds 28
        }
        Out-Raw "`n"
        Show-Note 'info' 'Normal : ça remonte petit à petit, chaque programme recharge ce dont il a besoin.'
        Out-Raw ("`n  " + (Get-Painted "$($SYM.star) Merci d'avoir utilisé ShyzosWinFixer") + "`n")
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
            if ($anim) { Out-Raw ("`n  " + (Get-Painted "$($SYM.star) ShyzosWinFixer") + "  ${DIM}v$version$RST`n") }
            else { Write-Host ''; Write-Host "  ShyzosWinFixer v$version" -ForegroundColor Magenta }
            Show-Note 'info' 'Droits administrateur nécessaires : Windows va te demander une confirmation (UAC).'
            $body = "function Invoke-ShyzosWinFixer {`n" + ${function:Invoke-ShyzosWinFixer}.ToString() + "`n}`nInvoke-ShyzosWinFixer @args`n"
            $tmp = Join-Path $env:TEMP 'ShyzosWinFixer.ps1'
            [IO.File]::WriteAllText($tmp, $body, (New-Object Text.UTF8Encoding($true)))
            $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$tmp`"", '-Elevated')
            if ($Standby) { $argList += '-Standby' }
            if ($NoWsl)   { $argList += '-NoWsl' }
            if ($NoPause) { $argList += '-NoPause' }
            if ($Plain)   { $argList += '-Plain' }
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

        # --- Avertissement si un jeu tourne ---
        $games = 'FortniteClient-Win64-Shipping','VALORANT-Win64-Shipping','cs2','RobloxPlayerBeta',
                 'r5apex','GTA5','League of Legends','RainbowSix','cod','FC25','FC26','eldenring','javaw'
        $runningGames = Get-Process -ErrorAction SilentlyContinue | Where-Object { $games -contains $_.Name } |
                        Select-Object -ExpandProperty Name -Unique
        if ($runningGames) {
            Show-Note 'warn' ("Jeu en cours ({0}) : petit lag possible quelques secondes." -f ($runningGames -join ', '))
        }

        $before = Get-RamState
        Show-Note 'info' ('RAM utilisée : {0:N1} Go sur {1:N1} Go' -f $before.Used, $before.Total)
        if ($anim) { Out-Raw "`n" } else { Write-Host '' }

        # --- WSL : vide le cache disque de Linux (sans arrêter les distributions) ---
        if (-not $NoWsl -and (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
            try {
                $all     = @((& wsl.exe -l -q 2>$null) | ForEach-Object { ($_ -replace "`0", '').Trim() } | Where-Object { $_ })
                $running = @((& wsl.exe -l --running -q 2>$null) | ForEach-Object { ($_ -replace "`0", '').Trim() } |
                             Where-Object { $_ -and ($all -contains $_) })
                foreach ($d in $running) {
                    $code = Invoke-Step "WSL ($d) : vidage du cache Linux" {
                        param($distro)
                        & wsl.exe -d $distro -u root -- sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches' 2>$null | Out-Null
                        $LASTEXITCODE
                    } $d
                    if ($code -eq 0) { Complete-Step 'ok' "WSL ($d) : cache vidé" }
                    else { Complete-Step 'warn' "WSL ($d) : impossible de vider le cache" }
                }
            } catch {
                Complete-Step 'warn' 'WSL : ignoré (erreur pendant la détection)'
            }
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

        # --- Attend que Windows ait fini de libérer (stable 3 mesures, 30 s max) ---
        $last = (Get-RamState).Used
        $stable = 0
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $nextPoll = 600
        $i = 0
        if (-not $anim) { Write-Host '  > Libération de la mémoire' -ForegroundColor Cyan }
        while ($stable -lt 3 -and $sw.ElapsedMilliseconds -lt 30000) {
            if ($anim) {
                $label = 'Libération de la mémoire  ' + (Get-Bar ($last / $before.Total) 24) + ('  {0,5:N1} Go' -f $last)
                Out-Raw ("`r  " + $GRAD[($i * 4) % 64] + $SPIN[$i % $SPIN.Count] + "$RST $label$E[K")
                Start-Sleep -Milliseconds 80
                $i++
            } else {
                Start-Sleep -Milliseconds 600
            }
            if ($sw.ElapsedMilliseconds -ge $nextPoll) {
                $now = (Get-RamState).Used
                if ([math]::Abs($last - $now) -lt 0.1) { $stable++ } else { $stable = 0 }
                $last = $now
                $nextPoll = $sw.ElapsedMilliseconds + 600
            }
        }
        Complete-Step 'ok' 'Mémoire stabilisée'

        $after = Get-RamState
        if ($anim) { Out-Raw "`n" }
        Show-Result $before $after
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
