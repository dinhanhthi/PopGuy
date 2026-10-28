using PopGuy.Core.Actions;

namespace PopGuy.Core.Library;

// Developer Tools presets (macOS ActionLibrary+Dev.swift): the zsh tools rewritten in PowerShell (Windows PowerShell
// 5.1 and PowerShell 7). The selection comes only from $env:POPGUY_TEXT and is never run as code; a script that can
// fail reports a one-line error and exits 1.
public static partial class ActionLibrary
{
    private static LibraryPreset[] DevPresets() =>
    [
        PowerShell("dev.base64encode", LibraryCategory.DevTools, "Base64 Encode", "chevron.left.forwardslash.chevron.right",
            AfterRunBehavior.PasteResult, "Encode the selected text as Base64.",
            """
            $text = [string]$env:POPGUY_TEXT
            Write-Output ([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($text)))
            """),
        PowerShell("dev.base64decode", LibraryCategory.DevTools, "Base64 Decode", "chevron.left.forwardslash.chevron.right",
            AfterRunBehavior.PasteResult, "Decode a Base64-encoded string.",
            """
            $ErrorActionPreference = 'Stop'
            trap { [Console]::Error.WriteLine($_.Exception.GetBaseException().Message); exit 1 }
            $text = [string]$env:POPGUY_TEXT
            Write-Output ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($text)))
            """),
        PowerShell("dev.urlencode", LibraryCategory.DevTools, "URL Encode", "link",
            AfterRunBehavior.PasteResult, "Percent-encode the selected text for use in a URL.",
            """
            $text = [string]$env:POPGUY_TEXT
            # Every UTF-8 byte but A-Z a-z 0-9 _ . ~ - becomes %XX.
            $result = [Text.StringBuilder]::new()
            foreach ($byte in [Text.Encoding]::UTF8.GetBytes($text)) {
                $character = [char]$byte
                if ($byte -lt 128 -and ([char]::IsLetterOrDigit($character) -or '_.~-'.IndexOf($character) -ge 0)) {
                    [void]$result.Append($character)
                }
                else { [void]$result.Append('%').Append($byte.ToString('X2')) }
            }
            Write-Output $result.ToString()
            """),
        PowerShell("dev.urldecode", LibraryCategory.DevTools, "URL Decode", "link",
            AfterRunBehavior.PasteResult, "Decode a percent-encoded URL string.",
            """
            $text = [string]$env:POPGUY_TEXT
            Write-Output ([Uri]::UnescapeDataString($text))
            """),
        PowerShell("dev.htmlencode", LibraryCategory.DevTools, "HTML Encode", "chevron.left.forwardslash.chevron.right",
            AfterRunBehavior.PasteResult, "Escape HTML special characters (&, <, >, \").",
            """
            $text = [string]$env:POPGUY_TEXT
            Write-Output ($text.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;').Replace("'", '&#39;'))
            """),
        PowerShell("dev.htmldecode", LibraryCategory.DevTools, "HTML Decode", "chevron.left.forwardslash.chevron.right",
            AfterRunBehavior.PasteResult, "Unescape HTML entities back to plain text.",
            """
            $text = [string]$env:POPGUY_TEXT
            Write-Output ($text.Replace('&lt;', '<').Replace('&gt;', '>').Replace('&quot;', '"').Replace('&#39;', "'").Replace('&amp;', '&'))
            """),
        PowerShell("dev.sha256", LibraryCategory.DevTools, "SHA-256", "number",
            AfterRunBehavior.ShowResult, "Compute the SHA-256 hash of the selected text.",
            """
            $text = [string]$env:POPGUY_TEXT
            $hash = [Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($text))
            Write-Output (($hash | ForEach-Object { $_.ToString('x2') }) -join '')
            """),
        PowerShell("dev.md5", LibraryCategory.DevTools, "MD5", "number",
            AfterRunBehavior.ShowResult, "Compute the MD5 hash of the selected text.",
            """
            $text = [string]$env:POPGUY_TEXT
            $hash = [Security.Cryptography.MD5]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($text))
            Write-Output (($hash | ForEach-Object { $_.ToString('x2') }) -join '')
            """),
        PowerShell("dev.unixtimetodate", LibraryCategory.DevTools, "Unix Time → Date", "clock",
            AfterRunBehavior.ShowResult, "Convert a Unix timestamp (epoch seconds) to a human-readable date.",
            """
            $ErrorActionPreference = 'Stop'
            trap { [Console]::Error.WriteLine($_.Exception.GetBaseException().Message); exit 1 }
            $text = [string]$env:POPGUY_TEXT
            $invariant = [Globalization.CultureInfo]::InvariantCulture
            $date = [DateTimeOffset]::FromUnixTimeSeconds([long]::Parse($text, $invariant)).ToLocalTime()
            # BSD date's layout; Windows has no time zone abbreviations, so the zone is its UTC offset.
            Write-Output ('{0} {1,2} {2}' -f $date.ToString('ddd MMM', $invariant), $date.Day, $date.ToString('HH:mm:ss zzz yyyy', $invariant))
            """),
        PowerShell("dev.datetounixtime", LibraryCategory.DevTools, "Date → Unix Time", "clock",
            AfterRunBehavior.ShowResult, "Convert a date string (YYYY-MM-DD HH:MM:SS) to a Unix timestamp.",
            """
            $ErrorActionPreference = 'Stop'
            trap { [Console]::Error.WriteLine($_.Exception.GetBaseException().Message); exit 1 }
            $text = [string]$env:POPGUY_TEXT
            # The date is local time, as on macOS.
            $date = [datetime]::ParseExact($text, 'yyyy-M-d H:m:s', [Globalization.CultureInfo]::InvariantCulture)
            Write-Output ([DateTimeOffset]::new($date).ToUnixTimeSeconds())
            """),
        PowerShell("dev.jsonprettyprint", LibraryCategory.DevTools, "JSON Pretty-Print", "curlybraces",
            AfterRunBehavior.PasteResult, "Format JSON with indentation for readability.",
            """
            $ErrorActionPreference = 'Stop'
            trap { [Console]::Error.WriteLine($_.Exception.GetBaseException().Message); exit 1 }
            $text = [string]$env:POPGUY_TEXT
            # Like JSON::PP pretty + canonical: 3-space indent, "key" : value, keys sorted. Strings and numbers are kept as written.
            $lexer = [regex]'\G[ \t\r\n]*(?:("(?:[^"\\\x00-\x1F]|\\(?:["\\/bfnrt]|u[0-9A-Fa-f]{4}))*"|-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?|true|false|null|[{}\[\],:])|\z)'
            $tokens = [Collections.Generic.List[string]]::new()
            $position = 0
            while ($true) {
                $match = $lexer.Match($text, $position)
                if (-not $match.Success) { throw "Invalid JSON at character $position." }
                if (-not $match.Groups[1].Success) { break }
                $tokens.Add($match.Groups[1].Value)
                $position += $match.Length
            }
            $script:next = 0

            function Read-Token {
                if ($script:next -ge $tokens.Count) { throw 'Invalid JSON: unexpected end.' }
                $tokens[$script:next]
                $script:next++
            }

            function Format-Value([int]$depth) {
                $token = Read-Token
                $indent = '   ' * ($depth + 1)
                $close = '   ' * $depth
                if ($token -ceq '{') {
                    $members = [Collections.Generic.SortedDictionary[string, string]]::new([StringComparer]::Ordinal)
                    if ($tokens[$script:next] -ceq '}') { $script:next++; return '{}' }
                    do {
                        $key = Read-Token
                        if (-not $key.StartsWith('"') -or (Read-Token) -cne ':') { throw 'Invalid JSON: expected "key" :' }
                        $members[$key] = Format-Value ($depth + 1)
                        $separator = Read-Token
                    } while ($separator -ceq ',')
                    if ($separator -cne '}') { throw 'Invalid JSON: expected , or }' }
                    $lines = foreach ($member in $members.GetEnumerator()) { $indent + $member.Key + ' : ' + $member.Value }
                    return "{`n" + (@($lines) -join ",`n") + "`n$close}"
                }
                if ($token -ceq '[') {
                    if ($tokens[$script:next] -ceq ']') { $script:next++; return '[]' }
                    $items = [Collections.Generic.List[string]]::new()
                    do {
                        $items.Add($indent + (Format-Value ($depth + 1)))
                        $separator = Read-Token
                    } while ($separator -ceq ',')
                    if ($separator -cne ']') { throw 'Invalid JSON: expected , or ]' }
                    return "[`n" + ($items -join ",`n") + "`n$close]"
                }
                if ($token -cin '}', ']', ',', ':') { throw "Invalid JSON: unexpected $token" }
                return $token
            }

            $result = Format-Value 0
            if ($script:next -lt $tokens.Count) { throw 'Invalid JSON: unexpected text after the value.' }
            Write-Output $result
            """),
        PowerShell("dev.wordcount", LibraryCategory.DevTools, "Word Count", "textformat.123",
            AfterRunBehavior.ShowResult, "Count the number of words in the selected text.",
            """
            $text = [string]$env:POPGUY_TEXT
            Write-Output ([regex]::Matches($text, '\S+').Count)
            """),
        PowerShell("dev.charactercount", LibraryCategory.DevTools, "Character Count", "textformat.123",
            AfterRunBehavior.ShowResult, "Count the number of Unicode characters in the selected text.",
            """
            $text = [string]$env:POPGUY_TEXT
            # Unicode characters (code points), not UTF-16 units.
            Write-Output ([Text.Encoding]::UTF32.GetByteCount($text) / 4)
            """),
        PowerShell("dev.linecount", LibraryCategory.DevTools, "Line Count", "list.number",
            AfterRunBehavior.ShowResult, "Count the number of lines in the selected text.",
            """
            $text = [string]$env:POPGUY_TEXT
            # Like wc -l: the number of line breaks.
            Write-Output ([regex]::Matches($text, '\n').Count)
            """),
        PowerShell("dev.calculate", LibraryCategory.DevTools, "Calculate", "function",
            AfterRunBehavior.ShowResult, "Evaluate the selected mathematical expression.",
            """
            $ErrorActionPreference = 'Stop'
            trap { [Console]::Error.WriteLine($_.Exception.GetBaseException().Message); exit 1 }
            $text = [string]$env:POPGUY_TEXT
            # Arithmetic only (+ - * / % ^ and parentheses), parsed here: the text is never run as code.
            $tokens = @([regex]::Matches($text, '[0-9]+(?:\.[0-9]*)?|\.[0-9]+|\S') | ForEach-Object { $_.Value })
            if ($tokens.Count -eq 0) { return }
            $script:next = 0

            function Read-Token {
                if ($script:next -ge $tokens.Count) { throw 'Incomplete expression.' }
                $tokens[$script:next]
                $script:next++
            }

            function Read-Sum {
                $value = Read-Product
                while ($script:next -lt $tokens.Count -and $tokens[$script:next] -cin '+', '-') {
                    if ((Read-Token) -ceq '+') { $value += Read-Product } else { $value -= Read-Product }
                }
                $value
            }

            function Read-Product {
                $value = Read-Power
                while ($script:next -lt $tokens.Count -and $tokens[$script:next] -cin '*', '/', '%') {
                    switch (Read-Token) {
                        '*' { $value *= Read-Power }
                        '/' { $value /= Read-Power }
                        '%' { $value %= Read-Power }
                    }
                }
                $value
            }

            # As in bc, ^ is right-associative with a whole exponent, and a leading minus binds tighter: -2^2 = 4.
            function Read-Power {
                $base = Read-Unary
                if ($script:next -ge $tokens.Count -or $tokens[$script:next] -cne '^') { return $base }
                $script:next++
                $exponent = Read-Power
                if ($exponent -ne [decimal]::Truncate($exponent)) { throw 'The exponent must be a whole number.' }
                $result = [decimal]1
                $square = $base
                for ($n = [Math]::Abs([long]$exponent); $n -gt 0; $n = [Math]::Floor($n / 2)) {
                    if ($n % 2 -eq 1) { $result *= $square }
                    if ($n -gt 1) { $square *= $square }
                }
                if ($exponent -lt 0) { $result = 1 / $result }
                $result
            }

            function Read-Unary {
                $token = Read-Token
                if ($token -ceq '-') { return -(Read-Unary) }
                if ($token -ceq '(') {
                    $value = Read-Sum
                    if ((Read-Token) -cne ')') { throw 'Missing ).' }
                    return $value
                }
                if ($token -cnotmatch '^[0-9.]') { throw "Unexpected '$token'." }
                [decimal]::Parse($token, [Globalization.CultureInfo]::InvariantCulture)
            }

            $value = Read-Sum
            if ($script:next -lt $tokens.Count) { throw "Unexpected '$($tokens[$script:next])'." }
            Write-Output $value.ToString([Globalization.CultureInfo]::InvariantCulture)
            """),
    ];
}
