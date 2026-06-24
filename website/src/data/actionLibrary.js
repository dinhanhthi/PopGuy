import {
  ArrowDownToLine,
  ArrowUpDown,
  Undo2,
  AtSign,
  BookOpen,
  Braces,
  Calculator,
  CheckSquare,
  ChevronsDown,
  ChevronsUp,
  Clock,
  Code,
  FileSearch,
  Film,
  Globe,
  GraduationCap,
  Hash,
  HelpCircle,
  History,
  Image,
  Languages,
  LayoutGrid,
  Link,
  ListTodo,
  Map,
  MapPin,
  MessageCircle,
  MessageSquare,
  Minus,
  Music,
  Phone,
  Play,
  RotateCcw,
  Search,
  Shuffle,
  Sparkles,
  Star,
  StickyNote,
  Type,
  Video,
} from "lucide-react";

export const libraryCategories = [
  { id: "search", name: "Search Engines", icon: Search },
  { id: "websites", name: "Websites", icon: Globe },
  { id: "maps", name: "Maps", icon: Map },
  { id: "ai", name: "AI Launchers", icon: Sparkles },
  { id: "translate", name: "Translate Launchers", icon: Languages },
  { id: "text", name: "Text Transform", icon: Type },
  { id: "dev", name: "Developer Tools", icon: Code },
  { id: "apps", name: "Apps", icon: LayoutGrid }
];

const libraryPresetDefinitions = [
  // Search Engines (12)
  { id: "search.google", name: "Search Google", type: "Open URL", category: "search", icon: Search },
  { id: "search.bing", name: "Search Bing", type: "Open URL", category: "search", icon: Search },
  { id: "search.duckduckgo", name: "Search DuckDuckGo", type: "Open URL", category: "search", icon: Search },
  { id: "search.brave", name: "Search Brave", type: "Open URL", category: "search", icon: Search },
  { id: "search.ecosia", name: "Search Ecosia", type: "Open URL", category: "search", icon: Search },
  { id: "search.kagi", name: "Search Kagi", type: "Open URL", category: "search", icon: Search },
  { id: "search.startpage", name: "Search Startpage", type: "Open URL", category: "search", icon: Search },
  { id: "search.yandex", name: "Search Yandex", type: "Open URL", category: "search", icon: Search },
  { id: "search.baidu", name: "Search Baidu", type: "Open URL", category: "search", icon: Search },
  { id: "search.qwant", name: "Search Qwant", type: "Open URL", category: "search", icon: Search },
  { id: "search.naver", name: "Search Naver", type: "Open URL", category: "search", icon: Search },
  { id: "search.yahoo", name: "Search Yahoo", type: "Open URL", category: "search", icon: Search },

  // Websites (21)
  { id: "web.wikipedia", name: "Wikipedia", type: "Open URL", category: "websites", icon: BookOpen },
  { id: "web.youtube", name: "YouTube", type: "Open URL", category: "websites", icon: Play },
  { id: "web.imdb", name: "IMDb", type: "Open URL", category: "websites", icon: Film },
  { id: "web.amazon", name: "Amazon", type: "Open URL", category: "websites", icon: Globe },
  { id: "web.github", name: "GitHub", type: "Open URL", category: "websites", icon: Code },
  { id: "web.stackoverflow", name: "Stack Overflow", type: "Open URL", category: "websites", icon: HelpCircle },
  { id: "web.mdn", name: "MDN Web Docs", type: "Open URL", category: "websites", icon: Code },
  { id: "web.devdocs", name: "DevDocs", type: "Open URL", category: "websites", icon: FileSearch },
  { id: "web.wolframalpha", name: "Wolfram Alpha", type: "Open URL", category: "websites", icon: Calculator },
  { id: "web.googlescholar", name: "Google Scholar", type: "Open URL", category: "websites", icon: GraduationCap },
  { id: "web.googleimages", name: "Google Images", type: "Open URL", category: "websites", icon: Image },
  { id: "web.goodreads", name: "Goodreads", type: "Open URL", category: "websites", icon: BookOpen },
  { id: "web.letterboxd", name: "Letterboxd", type: "Open URL", category: "websites", icon: Film },
  { id: "web.rottentomatoes", name: "Rotten Tomatoes", type: "Open URL", category: "websites", icon: Star },
  { id: "web.urbandictionary", name: "Urban Dictionary", type: "Open URL", category: "websites", icon: MessageCircle },
  { id: "web.waybackmachine", name: "Wayback Machine", type: "Open URL", category: "websites", icon: History },
  { id: "web.pubmed", name: "PubMed", type: "Open URL", category: "websites", icon: FileSearch },
  { id: "web.reddit", name: "Reddit", type: "Open URL", category: "websites", icon: MessageSquare },
  { id: "web.twitter", name: "X (Twitter)", type: "Open URL", category: "websites", icon: AtSign },
  { id: "web.spotify", name: "Spotify", type: "Open URL", category: "websites", icon: Music },
  { id: "web.applemusic", name: "Apple Music", type: "Open URL", category: "websites", icon: Music },

  // Maps (4)
  { id: "maps.apple", name: "Apple Maps", type: "Open URL", category: "maps", icon: MapPin },
  { id: "maps.google", name: "Google Maps", type: "Open URL", category: "maps", icon: MapPin },
  { id: "maps.openstreetmap", name: "OpenStreetMap", type: "Open URL", category: "maps", icon: Map },
  { id: "maps.what3words", name: "what3words", type: "Open URL", category: "maps", icon: MapPin },

  // AI Launchers (5)
  { id: "ai.chatgpt", name: "ChatGPT", type: "Open URL", category: "ai", icon: Sparkles },
  { id: "ai.claude", name: "Claude", type: "Open URL", category: "ai", icon: Sparkles },
  { id: "ai.grok", name: "Grok", type: "Open URL", category: "ai", icon: Sparkles },
  { id: "ai.perplexity", name: "Perplexity", type: "Open URL", category: "ai", icon: Sparkles },
  { id: "ai.gemini", name: "Gemini", type: "Open URL", category: "ai", icon: Sparkles },

  // Translate Launchers (4)
  { id: "translate.google", name: "Google Translate", type: "Open URL", category: "translate", icon: Languages },
  { id: "translate.deepl", name: "DeepL", type: "Open URL", category: "translate", icon: Languages },
  { id: "translate.bing", name: "Bing Translator", type: "Open URL", category: "translate", icon: Languages },
  { id: "translate.reverso", name: "Reverso", type: "Open URL", category: "translate", icon: Languages },

  // Text Transform (16)
  { id: "text.uppercase", name: "UPPERCASE", type: "Shell Script", category: "text", icon: ChevronsUp },
  { id: "text.lowercase", name: "lowercase", type: "Shell Script", category: "text", icon: ChevronsDown },
  { id: "text.titlecase", name: "Title Case", type: "Shell Script", category: "text", icon: Type },
  { id: "text.capitalize", name: "Capitalize Words", type: "Shell Script", category: "text", icon: Type },
  { id: "text.sentencecase", name: "Sentence Case", type: "Shell Script", category: "text", icon: Type },
  { id: "text.slugify", name: "Slugify", type: "Shell Script", category: "text", icon: Link },
  { id: "text.hyphenate", name: "Hyphenate", type: "Shell Script", category: "text", icon: Minus },
  { id: "text.underscore", name: "Underscore", type: "Shell Script", category: "text", icon: Minus },
  { id: "text.removespaces", name: "Remove Spaces", type: "Shell Script", category: "text", icon: Type },
  { id: "text.joinlines", name: "Join Lines", type: "Shell Script", category: "text", icon: ArrowDownToLine },
  { id: "text.sortlines", name: "Sort Lines", type: "Shell Script", category: "text", icon: ArrowUpDown },
  { id: "text.reverselineorder", name: "Reverse Line Order", type: "Shell Script", category: "text", icon: RotateCcw },
  { id: "text.shufflelines", name: "Shuffle Lines", type: "Shell Script", category: "text", icon: Shuffle },
  { id: "text.alternatingcase", name: "aLtErNaTiNg CaSe", type: "Shell Script", category: "text", icon: Type },
  { id: "text.rot13", name: "ROT13", type: "Shell Script", category: "text", icon: RotateCcw },
  { id: "text.reversestring", name: "Reverse String", type: "Shell Script", category: "text", icon: Undo2 },

  // Developer Tools (15)
  { id: "dev.base64encode", name: "Base64 Encode", type: "Shell Script", category: "dev", icon: Code },
  { id: "dev.base64decode", name: "Base64 Decode", type: "Shell Script", category: "dev", icon: Code },
  { id: "dev.urlencode", name: "URL Encode", type: "Shell Script", category: "dev", icon: Link },
  { id: "dev.urldecode", name: "URL Decode", type: "Shell Script", category: "dev", icon: Link },
  { id: "dev.htmlencode", name: "HTML Encode", type: "Shell Script", category: "dev", icon: Braces },
  { id: "dev.htmldecode", name: "HTML Decode", type: "Shell Script", category: "dev", icon: Braces },
  { id: "dev.sha256", name: "SHA-256", type: "Shell Script", category: "dev", icon: Hash },
  { id: "dev.md5", name: "MD5", type: "Shell Script", category: "dev", icon: Hash },
  { id: "dev.unixtimetodate", name: "Unix Time → Date", type: "Shell Script", category: "dev", icon: Clock },
  { id: "dev.datetounixtime", name: "Date → Unix Time", type: "Shell Script", category: "dev", icon: Clock },
  { id: "dev.jsonprettyprint", name: "JSON Pretty-Print", type: "Shell Script", category: "dev", icon: Braces },
  { id: "dev.wordcount", name: "Word Count", type: "Shell Script", category: "dev", icon: Type },
  { id: "dev.charactercount", name: "Character Count", type: "Shell Script", category: "dev", icon: Type },
  { id: "dev.linecount", name: "Line Count", type: "Shell Script", category: "dev", icon: Type },
  { id: "dev.calculate", name: "Calculate", type: "Shell Script", category: "dev", icon: Calculator },

  // Apps (16)
  { id: "apps.bear", name: "Bear", type: "Open URL", category: "apps", icon: StickyNote },
  { id: "apps.drafts", name: "Drafts", type: "Open URL", category: "apps", icon: StickyNote },
  { id: "apps.obsidian", name: "Obsidian", type: "Open URL", category: "apps", icon: StickyNote },
  { id: "apps.craft", name: "Craft", type: "Open URL", category: "apps", icon: StickyNote },
  { id: "apps.dayone", name: "Day One", type: "Open URL", category: "apps", icon: StickyNote },
  { id: "apps.tot", name: "Tot", type: "Open URL", category: "apps", icon: StickyNote },
  { id: "apps.things", name: "Things", type: "Open URL", category: "apps", icon: CheckSquare },
  { id: "apps.todoist", name: "Todoist", type: "Open URL", category: "apps", icon: ListTodo },
  { id: "apps.omnifocus", name: "OmniFocus", type: "Open URL", category: "apps", icon: CheckSquare },
  { id: "apps.goodlinks", name: "GoodLinks", type: "Open URL", category: "apps", icon: Link },
  { id: "apps.anybox", name: "Anybox", type: "Open URL", category: "apps", icon: Link },
  { id: "apps.raindrop", name: "Raindrop", type: "Open URL", category: "apps", icon: Link },
  { id: "apps.pocket", name: "Pocket", type: "Open URL", category: "apps", icon: Link },
  { id: "apps.instapaper", name: "Instapaper", type: "Open URL", category: "apps", icon: Link },
  { id: "apps.call", name: "Call", type: "Open URL", category: "apps", icon: Phone },
  { id: "apps.facetime", name: "FaceTime", type: "Open URL", category: "apps", icon: Video }
];

const textDescriptions = {
  "text.uppercase": "Convert the selection to uppercase.",
  "text.lowercase": "Convert the selection to lowercase.",
  "text.titlecase": "Convert the selection to title case.",
  "text.capitalize": "Capitalize every selected word.",
  "text.sentencecase": "Convert the selection to sentence case.",
  "text.slugify": "Turn the selection into a URL slug.",
  "text.hyphenate": "Replace spaces in the selection with hyphens.",
  "text.underscore": "Replace spaces in the selection with underscores.",
  "text.removespaces": "Remove spaces from the selection.",
  "text.joinlines": "Join selected lines into one line.",
  "text.sortlines": "Sort selected lines alphabetically.",
  "text.reverselineorder": "Reverse the order of selected lines.",
  "text.shufflelines": "Shuffle selected lines into random order.",
  "text.alternatingcase": "Apply alternating uppercase and lowercase.",
  "text.rot13": "Encode or decode the selection with ROT13.",
  "text.reversestring": "Reverse the selected characters."
};

const devDescriptions = {
  "dev.base64encode": "Encode the selection as Base64.",
  "dev.base64decode": "Decode Base64 text from the selection.",
  "dev.urlencode": "Percent-encode the selection for URLs.",
  "dev.urldecode": "Decode percent-encoded URL text.",
  "dev.htmlencode": "Escape the selection for HTML.",
  "dev.htmldecode": "Decode HTML entities in the selection.",
  "dev.sha256": "Generate a SHA-256 hash of the selection.",
  "dev.md5": "Generate an MD5 hash of the selection.",
  "dev.unixtimetodate": "Convert a Unix timestamp to a date.",
  "dev.datetounixtime": "Convert a date to a Unix timestamp.",
  "dev.jsonprettyprint": "Format selected JSON for readability.",
  "dev.wordcount": "Count words in the selection.",
  "dev.charactercount": "Count characters in the selection.",
  "dev.linecount": "Count selected lines.",
  "dev.calculate": "Calculate the selected expression."
};

function describeLibraryPreset(preset) {
  if (preset.id in textDescriptions) {
    return textDescriptions[preset.id];
  }
  if (preset.id in devDescriptions) {
    return devDescriptions[preset.id];
  }
  if (preset.category === "search") {
    return `Search the selection with ${preset.name.replace("Search ", "")}.`;
  }
  if (preset.category === "websites") {
    return `Look up the selection on ${preset.name}.`;
  }
  if (preset.category === "maps") {
    return `Open the selected place in ${preset.name}.`;
  }
  if (preset.category === "ai") {
    return `Send the selection to ${preset.name}.`;
  }
  if (preset.category === "translate") {
    return `Translate the selection with ${preset.name}.`;
  }
  if (preset.category === "apps") {
    return `Send the selection to ${preset.name}.`;
  }
  return `Run ${preset.name} on the selection.`;
}

export const libraryPresets = libraryPresetDefinitions.map((preset) => ({
  ...preset,
  description: describeLibraryPreset(preset)
}));

export const libraryStats = {
  total: libraryPresets.length,
  categories: libraryCategories.length,
  local: "100% local"
};
