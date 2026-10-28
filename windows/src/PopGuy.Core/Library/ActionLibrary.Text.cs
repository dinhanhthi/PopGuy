using PopGuy.Core.Actions;

namespace PopGuy.Core.Library;

// Text Transform presets (macOS ActionLibrary+Text.swift): the zsh transforms rewritten in PowerShell (Windows
// PowerShell 5.1 and PowerShell 7). The selection comes only from $env:POPGUY_TEXT, never from the script source; the
// result goes to stdout, which the engine trims.
public static partial class ActionLibrary
{
    private static LibraryPreset[] TextPresets() =>
    [
        PowerShell("text.uppercase", LibraryCategory.TextTransform, "UPPERCASE", "characters.uppercase",
            AfterRunBehavior.PasteResult, "Convert the selected text to UPPERCASE.",
            """
            $text = [string]$env:POPGUY_TEXT
            Write-Output ($text.ToUpperInvariant())
            """),
        PowerShell("text.lowercase", LibraryCategory.TextTransform, "lowercase", "characters.lowercase",
            AfterRunBehavior.PasteResult, "Convert the selected text to lowercase.",
            """
            $text = [string]$env:POPGUY_TEXT
            Write-Output ($text.ToLowerInvariant())
            """),
        PowerShell("text.titlecase", LibraryCategory.TextTransform, "Title Case", "textformat",
            AfterRunBehavior.PasteResult, "Convert the selected text to Title Case (every word capitalised).",
            """
            $text = [string]$env:POPGUY_TEXT
            $titleCase = [Text.RegularExpressions.MatchEvaluator]{
                param($word)
                $lower = $word.Value.ToLowerInvariant()
                $lower.Substring(0, 1).ToUpperInvariant() + $lower.Substring(1)
            }
            Write-Output ([regex]::Replace($text, '\w+', $titleCase))
            """),
        PowerShell("text.capitalize", LibraryCategory.TextTransform, "Capitalize Words", "textformat",
            AfterRunBehavior.PasteResult, "Capitalise the first letter of each word; preserve the rest.",
            """
            $text = [string]$env:POPGUY_TEXT
            # awk: each line's blank-separated words, rejoined with one space; a blank line stays as is.
            $lines = foreach ($line in $text -split '\r?\n') {
                $words = @($line -split '[ \t]+' | Where-Object { $_ })
                if ($words.Count -eq 0) { $line }
                else { ($words | ForEach-Object { $_.Substring(0, 1).ToUpperInvariant() + $_.Substring(1) }) -join ' ' }
            }
            Write-Output (@($lines) -join "`n")
            """),
        PowerShell("text.sentencecase", LibraryCategory.TextTransform, "Sentence Case", "textformat",
            AfterRunBehavior.PasteResult, "Convert to sentence case: first letter of each sentence is capitalised.",
            """
            $text = [string]$env:POPGUY_TEXT
            $upperFirst = [Text.RegularExpressions.MatchEvaluator]{
                param($match)
                $match.Groups[1].Value + $match.Groups[2].Value.ToUpperInvariant()
            }
            Write-Output ([regex]::Replace($text.ToLowerInvariant(), '(?m)([.!?]\s+|^\s*)(\w)', $upperFirst))
            """),
        PowerShell("text.slugify", LibraryCategory.TextTransform, "Slugify", "link",
            AfterRunBehavior.PasteResult, "Convert text to a URL-safe slug (lowercase, accents removed, spaces to hyphens).",
            """
            $text = [string]$env:POPGUY_TEXT
            $plain = $text.Normalize([Text.NormalizationForm]::FormD) -creplace '\p{M}', ''
            Write-Output (($plain.ToLowerInvariant() -creplace '[^a-z0-9]+', '-').Trim('-'))
            """),
        PowerShell("text.hyphenate", LibraryCategory.TextTransform, "Hyphenate", "minus",
            AfterRunBehavior.PasteResult, "Replace spaces with hyphens.",
            """
            $text = [string]$env:POPGUY_TEXT
            Write-Output ($text.Replace(' ', '-'))
            """),
        PowerShell("text.underscore", LibraryCategory.TextTransform, "Underscore", "minus",
            AfterRunBehavior.PasteResult, "Replace spaces with underscores.",
            """
            $text = [string]$env:POPGUY_TEXT
            Write-Output ($text.Replace(' ', '_'))
            """),
        PowerShell("text.removespaces", LibraryCategory.TextTransform, "Remove Spaces", "arrow.left.and.right",
            AfterRunBehavior.PasteResult, "Remove all whitespace characters from the selected text.",
            """
            $text = [string]$env:POPGUY_TEXT
            Write-Output ($text -creplace '\s', '')
            """),
        PowerShell("text.joinlines", LibraryCategory.TextTransform, "Join Lines", "arrow.down.to.line",
            AfterRunBehavior.PasteResult, "Join all lines into a single line, separated by spaces.",
            """
            $text = [string]$env:POPGUY_TEXT
            Write-Output (($text -split '\r?\n') -join ' ')
            """),
        PowerShell("text.sortlines", LibraryCategory.TextTransform, "Sort Lines", "arrow.up.arrow.down",
            AfterRunBehavior.PasteResult, "Sort lines alphabetically (ascending).",
            """
            $text = [string]$env:POPGUY_TEXT
            $lines = $text -split '\r?\n'
            [Array]::Sort($lines, [StringComparer]::InvariantCulture)
            Write-Output ($lines -join "`n")
            """),
        PowerShell("text.reverselineorder", LibraryCategory.TextTransform, "Reverse Line Order", "arrow.uturn.down",
            AfterRunBehavior.PasteResult, "Reverse the order of lines (last line becomes first).",
            """
            $text = [string]$env:POPGUY_TEXT
            $lines = $text -split '\r?\n'
            [Array]::Reverse($lines)
            Write-Output ($lines -join "`n")
            """),
        PowerShell("text.shufflelines", LibraryCategory.TextTransform, "Shuffle Lines", "shuffle",
            AfterRunBehavior.PasteResult, "Randomly shuffle the order of lines.",
            """
            $text = [string]$env:POPGUY_TEXT
            $lines = $text -split '\r?\n'
            $random = [Random]::new()
            for ($i = $lines.Length - 1; $i -gt 0; $i--) {
                $j = $random.Next($i + 1)
                $lines[$i], $lines[$j] = $lines[$j], $lines[$i]
            }
            Write-Output ($lines -join "`n")
            """),
        PowerShell("text.alternatingcase", LibraryCategory.TextTransform, "aLtErNaTiNg CaSe", "textformat",
            AfterRunBehavior.PasteResult, "Alternate UPPER and lower casing on each alphabetic character.",
            """
            $text = [string]$env:POPGUY_TEXT
            # Letters alternate upper/lower; other characters are kept and do not count.
            $result = [Text.StringBuilder]::new()
            $letters = 0
            for ($i = 0; $i -lt $text.Length; $i += $length) {
                $length = if ([char]::IsSurrogatePair($text, $i)) { 2 } else { 1 }
                $character = $text.Substring($i, $length)
                if ([char]::IsLetter($text, $i)) {
                    $character = if ($letters % 2 -eq 0) { $character.ToUpperInvariant() } else { $character.ToLowerInvariant() }
                    $letters++
                }
                [void]$result.Append($character)
            }
            Write-Output $result.ToString()
            """),
        PowerShell("text.rot13", LibraryCategory.TextTransform, "ROT13", "arrow.triangle.2.circlepath",
            AfterRunBehavior.PasteResult, "Apply ROT13 encoding (rotate letters by 13 positions; apply twice to decode).",
            """
            $text = [string]$env:POPGUY_TEXT
            $characters = $text.ToCharArray()
            for ($i = 0; $i -lt $characters.Length; $i++) {
                $code = [int]$characters[$i]
                if ($code -ge 65 -and $code -le 90) { $characters[$i] = [char](65 + ($code - 65 + 13) % 26) }
                elseif ($code -ge 97 -and $code -le 122) { $characters[$i] = [char](97 + ($code - 97 + 13) % 26) }
            }
            Write-Output ([string]::new($characters))
            """),
        PowerShell("text.reversestring", LibraryCategory.TextTransform, "Reverse String", "arrow.uturn.left",
            AfterRunBehavior.PasteResult, "Reverse the entire character sequence of the selected text.",
            """
            $text = [string]$env:POPGUY_TEXT
            # Reversed by text element, so an accent or an emoji stays whole.
            $elements = [Collections.Generic.List[string]]::new()
            $enumerator = [Globalization.StringInfo]::GetTextElementEnumerator($text)
            while ($enumerator.MoveNext()) { $elements.Add($enumerator.GetTextElement()) }
            $elements.Reverse()
            Write-Output ($elements -join '')
            """),
    ];
}
