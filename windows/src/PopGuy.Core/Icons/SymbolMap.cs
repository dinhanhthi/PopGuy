namespace PopGuy.Core.Icons;

/// <summary>
/// SF Symbol names (the icons of built-in and custom actions, shared with macOS settings) → Segoe Fluent Icons glyphs.
/// Covers every name in macOS <c>IconPickerView.swift</c>'s curated list plus the built-ins' and the Action Library's
/// symbols; each glyph is named after its Segoe Fluent Icons entry. A name with no close glyph gets the nearest one; an
/// unknown name (typed by hand on macOS, or newer than this table) gets <see cref="Sparkles"/>. Only long-standing
/// glyphs: the newer ones are missing from the font on earlier Windows 11 builds.
/// </summary>
public static class SymbolMap
{
    /// <summary>
    /// The default custom icon ("sparkles") and the fallback: FavoriteStar, since Segoe Fluent Icons has no plain
    /// sparkles glyph on every Windows 11 build.
    /// </summary>
    public const string Sparkles = "\uE734";

    /// <summary>The glyph for <paramref name="sfSymbol"/>; <see cref="Sparkles"/> for an unknown name.</summary>
    public static string Glyph(string sfSymbol) =>
        Glyphs.TryGetValue(sfSymbol, out var glyph)
        || (sfSymbol.EndsWith(".fill", StringComparison.Ordinal) && Glyphs.TryGetValue(sfSymbol[..^5], out glyph))
            ? glyph : Sparkles;

    /// <summary>Whether <paramref name="sfSymbol"/> has its own entry (a known name may still map to <see cref="Sparkles"/>).</summary>
    public static bool IsKnown(string sfSymbol) => Glyphs.ContainsKey(sfSymbol);

    private static readonly Dictionary<string, string> Glyphs = new(StringComparer.Ordinal)
    {
        // The built-ins (Improve, Shorten, Proofread, Prompt, Translate, Speak, Look up) not in the curated list.
        ["text.badge.minus"] = "\uE738", // Remove
        ["checkmark.bubble"] = "\uE73E", // CheckMark
        ["bubble.and.pencil"] = "\uE8F2", // ChatBubbles

        // Writing / text.
        ["sparkles"] = Sparkles,
        ["wand.and.stars"] = "\uE70F", // Edit
        ["wand.and.rays"] = "\uE70F", // Edit
        ["pencil"] = "\uE70F", // Edit
        ["pencil.line"] = "\uE70F", // Edit
        ["pencil.and.outline"] = "\uEF60", // TextEdit
        ["square.and.pencil"] = "\uE70B", // QuickNote
        ["highlighter"] = "\uE7E6", // Highlight
        ["textformat"] = "\uE8D2", // Font
        ["textformat.abc"] = "\uE8D2", // Font
        ["textformat.size"] = "\uE8E9", // FontSize
        ["textformat.alt"] = "\uEC34", // FormatText
        ["character"] = "\uE8C1", // Characters
        ["character.cursor.ibeam"] = "\uE8C1", // Characters
        ["abc"] = "\uE8C1", // Characters
        ["text.bubble"] = "\uE8F2", // ChatBubbles
        ["character.bubble"] = "\uE774", // Globe
        ["quote.bubble"] = "\uE90A", // Comment
        ["quote.opening"] = "\uE9B2", // LeftDoubleQuote
        ["quote.closing"] = "\uE9B1", // RightDoubleQuote
        ["text.quote"] = "\uE9B2", // LeftDoubleQuote
        ["captions.bubble"] = "\uE8BA", // Caption
        ["bubble.left"] = "\uE8BD", // Message
        ["bubble.right"] = "\uE8BD", // Message
        ["bubble.left.and.bubble.right"] = "\uE8F2", // ChatBubbles
        ["text.alignleft"] = "\uE8E4", // AlignLeft
        ["text.aligncenter"] = "\uE8E3", // AlignCenter
        ["text.alignright"] = "\uE8E2", // AlignRight
        ["text.justify"] = "\uE8E4", // AlignLeft
        ["text.append"] = "\uE710", // Add
        ["text.insert"] = "\uE710", // Add
        ["text.badge.plus"] = "\uE710", // Add
        ["text.badge.checkmark"] = "\uE73E", // CheckMark

        // Lists, marks, organizing.
        ["list.bullet"] = "\uE8FD", // BulletedList
        ["list.number"] = "\uEA37", // List
        ["list.dash"] = "\uEA37", // List
        ["list.bullet.indent"] = "\uE8FD", // BulletedList
        ["checklist"] = "\uE9D5", // CheckList
        ["checkmark"] = "\uE73E", // CheckMark
        ["checkmark.circle"] = "\uE930", // Completed
        ["checkmark.seal"] = "\uE930", // Completed
        ["tag"] = "\uE8EC", // Tag
        ["tag.fill"] = "\uE8EC", // Tag
        ["bookmark"] = "\uE8A4", // Bookmarks
        ["bookmark.fill"] = "\uE8A4", // Bookmarks
        ["flag"] = "\uE7C1", // Flag
        ["flag.fill"] = "\uE7C1", // Flag
        ["tray"] = "\uE7B8", // Package
        ["tray.full"] = "\uE7B8", // Package
        ["folder"] = "\uE8B7", // Folder
        ["folder.fill"] = "\uE8D5", // FolderFill
        ["archivebox"] = "\uE7B8", // Package
        ["square.grid.2x2"] = "\uE71D", // AllApps
        ["rectangle.grid.1x2"] = "\uE7C4", // TaskView

        // Arrows, navigation, keys.
        ["arrow.right"] = "\uE72A", // Forward
        ["arrow.left"] = "\uE72B", // Back
        ["arrow.up"] = "\uE74A", // Up
        ["arrow.down"] = "\uE74B", // Down
        ["arrow.uturn.left"] = "\uE7A7", // Undo
        ["arrow.uturn.right"] = "\uE7A6", // Redo
        ["arrow.triangle.2.circlepath"] = "\uE895", // Sync
        ["arrow.clockwise"] = "\uE72C", // Refresh
        ["arrow.up.arrow.down"] = "\uE8CB", // Sort
        ["arrow.left.arrow.right"] = "\uE8AB", // Switch
        ["arrow.right.circle"] = "\uE8AD", // Go
        ["arrowshape.turn.up.right"] = "\uE72D", // Share
        ["chevron.right"] = "\uE76C", // ChevronRight
        ["chevron.up.chevron.down"] = "\uEC8F", // ScrollUpDown
        ["magnifyingglass"] = "\uE721", // Search
        ["magnifyingglass.circle"] = "\uE721", // Search
        ["link"] = "\uE71B", // Link
        ["paperclip"] = "\uE723", // Attach
        ["command"] = "\uE765", // KeyboardClassic
        ["option"] = "\uE765", // KeyboardClassic
        ["return"] = "\uE751", // ReturnKey

        // Documents.
        ["doc"] = "\uE8A5", // Document
        ["doc.on.doc"] = "\uE8C8", // Copy
        ["doc.text"] = "\uE8A5", // Document
        ["doc.text.magnifyingglass"] = "\uE721", // Search
        ["doc.append"] = "\uEA1A", // PageAdd
        ["doc.richtext"] = "\uE8A5", // Document
        ["doc.plaintext"] = "\uE8A5", // Document
        ["clipboard"] = "\uE77F", // Paste
        ["list.clipboard"] = "\uE77F", // Paste
        ["note.text"] = "\uE70B", // QuickNote
        ["newspaper"] = "\uE7BC", // ReadingList
        ["book"] = "\uE82D", // Dictionary
        ["book.closed"] = "\uE82D", // Dictionary
        ["text.book.closed"] = "\uE82D", // Dictionary

        // Code, math, devices.
        ["terminal"] = "\uE756", // CommandPrompt
        ["chevron.left.forwardslash.chevron.right"] = "\uE943", // Code
        ["curlybraces"] = "\uE943", // Code
        ["curlybraces.square"] = "\uE943", // Code
        ["function"] = "\uE8EF", // Calculator
        ["number"] = "\uE8EF", // Calculator
        ["numbersign"] = "\uE8EF", // Calculator
        ["percent"] = "\uE94C", // CalculatorPercentage
        ["plus.forwardslash.minus"] = "\uE94D", // CalculatorNegate
        ["x.squareroot"] = "\uE94B", // CalculatorSquareroot
        ["sum"] = "\uE8EF", // Calculator
        ["chevron.left.slash.chevron.right"] = "\uE943", // Code
        ["cpu"] = "\uEEA1", // CPU
        ["memorychip"] = "\uEEA1", // CPU
        ["externaldrive"] = "\uEDA2", // HardDrive
        ["server.rack"] = "\uEDA2", // HardDrive
        ["network"] = "\uE968", // Network
        ["ladybug"] = "\uEBE8", // Bug
        ["hammer"] = "\uE90F", // Repair
        ["wrench.and.screwdriver"] = "\uE90F", // Repair
        ["gearshape"] = "\uE713", // Settings
        ["gearshape.2"] = "\uE713", // Settings
        ["slider.horizontal.3"] = "\uE9E9", // Equalizer

        // Communication, people, places.
        ["envelope"] = "\uE715", // Mail
        ["envelope.open"] = "\uE715", // Mail
        ["paperplane"] = "\uE724", // Send
        ["paperplane.fill"] = "\uE725", // SendFill
        ["message"] = "\uE8BD", // Message
        ["message.fill"] = "\uE8BD", // Message
        ["phone"] = "\uE717", // Phone
        ["bell"] = "\uEA8F", // Ringer
        ["bell.fill"] = "\uEA8F", // Ringer
        ["megaphone"] = "\uE789", // Megaphone
        ["at"] = "\uE715", // Mail
        ["person"] = "\uE77B", // Contact
        ["person.2"] = "\uE716", // People
        ["person.crop.circle"] = "\uE77B", // Contact
        ["globe.americas"] = "\uE774", // Globe
        ["globe.europe.africa"] = "\uE774", // Globe

        // Learning, help.
        ["lightbulb"] = "\uEA80", // Lightbulb
        ["lightbulb.fill"] = "\uEA80", // Lightbulb
        ["brain"] = "\uE99A", // Robot
        ["brain.head.profile"] = "\uE99A", // Robot
        ["graduationcap"] = "\uE7BE", // Education
        ["books.vertical"] = "\uE8F1", // Library
        ["character.book.closed"] = "\uE82D", // Dictionary
        ["studentdesk"] = "\uE7BE", // Education
        ["questionmark.circle"] = "\uE897", // Help
        ["exclamationmark.circle"] = "\uE783", // Error
        ["info.circle"] = "\uE946", // Info
        ["eye"] = "\uE890", // View
        ["eyeglasses"] = "\uE736", // ReadingMode

        // Time.
        ["calendar"] = "\uE787", // Calendar
        ["calendar.badge.clock"] = "\uE787", // Calendar
        ["clock"] = "\uE917", // Clock
        ["clock.arrow.circlepath"] = "\uE81C", // History
        ["alarm"] = "\uE917", // Clock
        ["timer"] = "\uE916", // Stopwatch
        ["hourglass"] = "\uE916", // Stopwatch
        ["stopwatch"] = "\uE916", // Stopwatch

        // Creative, symbols.
        ["paintbrush"] = "\uE771", // Personalize
        ["paintbrush.pointed"] = "\uE771", // Personalize
        ["paintpalette"] = "\uE790", // Color
        ["scissors"] = "\uE8C6", // Cut
        ["star"] = "\uE734", // FavoriteStar
        ["star.fill"] = "\uE735", // FavoriteStarFill
        ["heart"] = "\uEB51", // Heart
        ["heart.fill"] = "\uEB52", // HeartFill
        ["bolt"] = "\uE945", // LightningBolt
        ["bolt.fill"] = "\uE945", // LightningBolt
        ["flame"] = "\uE945", // LightningBolt
        ["flame.fill"] = "\uE945", // LightningBolt
        ["leaf"] = "\uE8BE", // Leaf
        ["leaf.fill"] = "\uE8BE", // Leaf
        ["drop"] = "\uEB42", // Drop
        ["sparkle"] = Sparkles,
        ["globe"] = "\uE774", // Globe
        ["hand.thumbsup"] = "\uE8E1", // Like
        ["hand.thumbsup.fill"] = "\uE8E1", // Like
        ["hand.raised"] = "\uE7C9", // TouchPointer
        ["face.smiling"] = "\uE76E", // Emoji2
        ["gift"] = Sparkles,
        ["crown"] = Sparkles,
        ["trophy"] = Sparkles,
        ["rosette"] = Sparkles,
        ["wand.and.stars.inverse"] = "\uE70F", // Edit
        ["scope"] = "\uE81D", // Location
        ["target"] = "\uE81D", // Location
        ["scalemass"] = "\uE9D9", // Diagnostic
        ["gauge"] = "\uEC4A", // SpeedHigh
        ["speedometer"] = "\uEC4A", // SpeedHigh
        ["lock"] = "\uE72E", // Lock
        ["lock.open"] = "\uE785", // Unlock
        ["key"] = "\uE8D7", // Permissions
        ["shield"] = "\uEA18", // Shield
        ["trash"] = "\uE74D", // Delete
        ["pin"] = "\uE718", // Pin
        ["mappin"] = "\uE707", // MapPin
        ["location"] = "\uE81D", // Location

        // Media.
        ["camera"] = "\uE722", // Camera
        ["photo"] = "\uE91B", // Photo
        ["mic"] = "\uE720", // Microphone
        ["speaker.wave.2"] = "\uE767", // Volume
        ["music.note"] = "\uEC4F", // MusicNote
        ["play"] = "\uE768", // Play
        ["waveform"] = "\uE8D6", // Audio
        ["character.book.closed.fill"] = "\uE82D", // Dictionary
        ["text.magnifyingglass"] = "\uE721", // Search

        // Action Library presets and categories not in the curated list.
        ["map"] = "\uE707", // MapPin
        ["mappin.and.ellipse"] = "\uE707", // MapPin
        ["play.rectangle"] = "\uE714", // Video
        ["film"] = "\uE8B2", // Movies
        ["cart"] = "\uE7BF", // ShoppingCart
        ["cross.case"] = "\uE95E", // Health
        ["person.wave.2"] = "\uE77B", // Contact
        ["characters.uppercase"] = "\uE8E8", // FontIncrease
        ["characters.lowercase"] = "\uE8E7", // FontDecrease
        ["minus"] = "\uE738", // Remove
        ["arrow.left.and.right"] = "\uE8AB", // Switch
        ["arrow.down.to.line"] = "\uE896", // Download
        ["arrow.uturn.down"] = "\uE7A7", // Undo
        ["shuffle"] = "\uE8B1", // Shuffle
        ["textformat.123"] = "\uE8EF", // Calculator
    };
}
