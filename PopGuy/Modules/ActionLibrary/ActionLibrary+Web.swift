// ActionLibrary+Web.swift
// PopGuy — ActionLibrary
//
// Web-category presets for the Action Library: Search Engines, Websites,
// Maps, AI Launchers, and Translate Launchers.
//
// Isolation: nonisolated / Sendable value-type namespace — pure factory, no state.

import Foundation

// nonisolated: opts out of SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor (app target).
nonisolated enum ActionLibraryWeb: Sendable {

    /// Returns all web-category presets (search, web, maps, aiLaunchers, translateLaunchers).
    /// Each call returns fresh CustomAction instances with new UUIDs.
    nonisolated static func all() -> [LibraryPreset] {
        searchPresets()
        + webPresets()
        + mapsPresets()
        + aiLauncherPresets()
        + translateLauncherPresets()
    }

    // MARK: - Search Engine Presets

    nonisolated private static func searchPresets() -> [LibraryPreset] {
        [
            searchGoogle(),
            searchBing(),
            searchDuckDuckGo(),
            searchBrave(),
            searchEcosia(),
            searchKagi(),
            searchStartpage(),
            searchYandex(),
            searchBaidu(),
            searchQwant(),
            searchNaver(),
            searchYahoo(),
        ]
    }

    nonisolated private static func searchGoogle() -> LibraryPreset {
        LibraryPreset(id: "search.google", category: .search) {
            var action = CustomAction(
                title: "Search Google",
                icon: .sfSymbol("magnifyingglass"),
                type: .openURL,
                systemPrompt: "",
                scriptSource: "https://www.google.com/search?q={text}",
                afterRun: .closeToolbar,
                appliesWhenRegex: ""
            )
            action.actionDescription = "Search Google for the selected text."
            return action
        }
    }

    nonisolated private static func searchBing() -> LibraryPreset {
        LibraryPreset(id: "search.bing", category: .search) {
            var action = CustomAction(
                title: "Search Bing",
                icon: .sfSymbol("magnifyingglass"),
                type: .openURL,
                systemPrompt: "",
                scriptSource: "https://www.bing.com/search?q={text}",
                afterRun: .closeToolbar,
                appliesWhenRegex: ""
            )
            action.actionDescription = "Search Bing for the selected text."
            return action
        }
    }

    nonisolated private static func searchDuckDuckGo() -> LibraryPreset {
        LibraryPreset(id: "search.duckduckgo", category: .search) {
            var action = CustomAction(
                title: "Search DuckDuckGo",
                icon: .sfSymbol("magnifyingglass"),
                type: .openURL,
                systemPrompt: "",
                scriptSource: "https://duckduckgo.com/?q={text}",
                afterRun: .closeToolbar,
                appliesWhenRegex: ""
            )
            action.actionDescription = "Search DuckDuckGo for the selected text."
            return action
        }
    }

    nonisolated private static func searchBrave() -> LibraryPreset {
        LibraryPreset(id: "search.brave", category: .search) {
            var action = CustomAction(
                title: "Search Brave",
                icon: .sfSymbol("magnifyingglass"),
                type: .openURL,
                systemPrompt: "",
                scriptSource: "https://search.brave.com/search?q={text}",
                afterRun: .closeToolbar,
                appliesWhenRegex: ""
            )
            action.actionDescription = "Search Brave Search for the selected text."
            return action
        }
    }

    nonisolated private static func searchEcosia() -> LibraryPreset {
        LibraryPreset(id: "search.ecosia", category: .search) {
            var action = CustomAction(
                title: "Search Ecosia",
                icon: .sfSymbol("magnifyingglass"),
                type: .openURL,
                systemPrompt: "",
                scriptSource: "https://www.ecosia.org/search?q={text}",
                afterRun: .closeToolbar,
                appliesWhenRegex: ""
            )
            action.actionDescription = "Search Ecosia (plants trees) for the selected text."
            return action
        }
    }

    nonisolated private static func searchKagi() -> LibraryPreset {
        LibraryPreset(id: "search.kagi", category: .search) {
            var action = CustomAction(
                title: "Search Kagi",
                icon: .sfSymbol("magnifyingglass"),
                type: .openURL,
                systemPrompt: "",
                scriptSource: "https://kagi.com/search?q={text}",
                afterRun: .closeToolbar,
                appliesWhenRegex: ""
            )
            action.actionDescription = "Search Kagi for the selected text."
            return action
        }
    }

    nonisolated private static func searchStartpage() -> LibraryPreset {
        LibraryPreset(id: "search.startpage", category: .search) {
            var action = CustomAction(
                title: "Search Startpage",
                icon: .sfSymbol("magnifyingglass"),
                type: .openURL,
                systemPrompt: "",
                scriptSource: "https://www.startpage.com/sp/search?query={text}",
                afterRun: .closeToolbar,
                appliesWhenRegex: ""
            )
            action.actionDescription = "Search Startpage (privacy-focused Google proxy) for the selected text."
            return action
        }
    }

    nonisolated private static func searchYandex() -> LibraryPreset {
        LibraryPreset(id: "search.yandex", category: .search) {
            var action = CustomAction(
                title: "Search Yandex",
                icon: .sfSymbol("magnifyingglass"),
                type: .openURL,
                systemPrompt: "",
                scriptSource: "https://yandex.com/search/?text={text}",
                afterRun: .closeToolbar,
                appliesWhenRegex: ""
            )
            action.actionDescription = "Search Yandex for the selected text."
            return action
        }
    }

    nonisolated private static func searchBaidu() -> LibraryPreset {
        LibraryPreset(id: "search.baidu", category: .search) {
            var action = CustomAction(
                title: "Search Baidu",
                icon: .sfSymbol("magnifyingglass"),
                type: .openURL,
                systemPrompt: "",
                scriptSource: "https://www.baidu.com/s?wd={text}",
                afterRun: .closeToolbar,
                appliesWhenRegex: ""
            )
            action.actionDescription = "Search Baidu for the selected text."
            return action
        }
    }

    nonisolated private static func searchQwant() -> LibraryPreset {
        LibraryPreset(id: "search.qwant", category: .search) {
            var action = CustomAction(
                title: "Search Qwant",
                icon: .sfSymbol("magnifyingglass"),
                type: .openURL,
                systemPrompt: "",
                scriptSource: "https://www.qwant.com/?q={text}",
                afterRun: .closeToolbar,
                appliesWhenRegex: ""
            )
            action.actionDescription = "Search Qwant (privacy-first, French) for the selected text."
            return action
        }
    }

    nonisolated private static func searchNaver() -> LibraryPreset {
        LibraryPreset(id: "search.naver", category: .search) {
            var action = CustomAction(
                title: "Search Naver",
                icon: .sfSymbol("magnifyingglass"),
                type: .openURL,
                systemPrompt: "",
                scriptSource: "https://search.naver.com/search.naver?query={text}",
                afterRun: .closeToolbar,
                appliesWhenRegex: ""
            )
            action.actionDescription = "Search Naver (South Korea) for the selected text."
            return action
        }
    }

    nonisolated private static func searchYahoo() -> LibraryPreset {
        LibraryPreset(id: "search.yahoo", category: .search) {
            var action = CustomAction(
                title: "Search Yahoo",
                icon: .sfSymbol("magnifyingglass"),
                type: .openURL,
                systemPrompt: "",
                scriptSource: "https://search.yahoo.com/search?p={text}",
                afterRun: .closeToolbar,
                appliesWhenRegex: ""
            )
            action.actionDescription = "Search Yahoo for the selected text."
            return action
        }
    }

    // MARK: - Website Presets

    nonisolated private static func webPresets() -> [LibraryPreset] {
        [
            webWikipedia(),
            webYouTube(),
            webIMDb(),
            webAmazon(),
            webGitHub(),
            webStackOverflow(),
            webMDN(),
            webDevDocs(),
            webWolframAlpha(),
            webGoogleScholar(),
            webGoogleImages(),
            webGoodreads(),
            webLetterboxd(),
            webRottenTomatoes(),
            webUrbanDictionary(),
            webWaybackMachine(),
            webPubMed(),
            webReddit(),
            webTwitter(),
            webSpotify(),
            webAppleMusic(),
        ]
    }

    nonisolated private static func webWikipedia() -> LibraryPreset {
        LibraryPreset(id: "web.wikipedia", category: .web) {
            var action = CustomAction(
                title: "Wikipedia",
                icon: .sfSymbol("book"),
                type: .openURL,
                systemPrompt: "",
                scriptSource: "https://en.wikipedia.org/w/index.php?search={text}",
                afterRun: .closeToolbar,
                appliesWhenRegex: ""
            )
            action.actionDescription = "Search Wikipedia for the selected text."
            return action
        }
    }

    nonisolated private static func webYouTube() -> LibraryPreset {
        LibraryPreset(id: "web.youtube", category: .web) {
            var action = CustomAction(
                title: "YouTube",
                icon: .sfSymbol("play.rectangle"),
                type: .openURL,
                systemPrompt: "",
                scriptSource: "https://www.youtube.com/results?search_query={text}",
                afterRun: .closeToolbar,
                appliesWhenRegex: ""
            )
            action.actionDescription = "Search YouTube for the selected text."
            return action
        }
    }

    nonisolated private static func webIMDb() -> LibraryPreset {
        LibraryPreset(id: "web.imdb", category: .web) {
            var action = CustomAction(
                title: "IMDb",
                icon: .sfSymbol("film"),
                type: .openURL,
                systemPrompt: "",
                scriptSource: "https://www.imdb.com/find/?q={text}",
                afterRun: .closeToolbar,
                appliesWhenRegex: ""
            )
            action.actionDescription = "Search IMDb for the selected text."
            return action
        }
    }

    nonisolated private static func webAmazon() -> LibraryPreset {
        LibraryPreset(id: "web.amazon", category: .web) {
            var action = CustomAction(
                title: "Amazon",
                icon: .sfSymbol("cart"),
                type: .openURL,
                systemPrompt: "",
                scriptSource: "https://www.amazon.com/s?k={text}",
                afterRun: .closeToolbar,
                appliesWhenRegex: ""
            )
            action.actionDescription = "Search Amazon for the selected text."
            return action
        }
    }

    nonisolated private static func webGitHub() -> LibraryPreset {
        LibraryPreset(id: "web.github", category: .web) {
            var action = CustomAction(
                title: "GitHub",
                icon: .sfSymbol("chevron.left.forwardslash.chevron.right"),
                type: .openURL,
                systemPrompt: "",
                scriptSource: "https://github.com/search?q={text}",
                afterRun: .closeToolbar,
                appliesWhenRegex: ""
            )
            action.actionDescription = "Search GitHub for the selected text."
            return action
        }
    }

    nonisolated private static func webStackOverflow() -> LibraryPreset {
        LibraryPreset(id: "web.stackoverflow", category: .web) {
            var action = CustomAction(
                title: "Stack Overflow",
                icon: .sfSymbol("questionmark.circle"),
                type: .openURL,
                systemPrompt: "",
                scriptSource: "https://stackoverflow.com/search?q={text}",
                afterRun: .closeToolbar,
                appliesWhenRegex: ""
            )
            action.actionDescription = "Search Stack Overflow for the selected text."
            return action
        }
    }

    nonisolated private static func webMDN() -> LibraryPreset {
        LibraryPreset(id: "web.mdn", category: .web) {
            var action = CustomAction(
                title: "MDN Web Docs",
                icon: .sfSymbol("chevron.left.forwardslash.chevron.right"),
                type: .openURL,
                systemPrompt: "",
                scriptSource: "https://developer.mozilla.org/en-US/search?q={text}",
                afterRun: .closeToolbar,
                appliesWhenRegex: ""
            )
            action.actionDescription = "Search MDN Web Docs for the selected text."
            return action
        }
    }

    nonisolated private static func webDevDocs() -> LibraryPreset {
        LibraryPreset(id: "web.devdocs", category: .web) {
            var action = CustomAction(
                title: "DevDocs",
                icon: .sfSymbol("doc.text.magnifyingglass"),
                type: .openURL,
                systemPrompt: "",
                scriptSource: "https://devdocs.io/#q={text}",
                afterRun: .closeToolbar,
                appliesWhenRegex: ""
            )
            action.actionDescription = "Search DevDocs API documentation for the selected text."
            return action
        }
    }

    nonisolated private static func webWolframAlpha() -> LibraryPreset {
        LibraryPreset(id: "web.wolframalpha", category: .web) {
            var action = CustomAction(
                title: "Wolfram Alpha",
                icon: .sfSymbol("function"),
                type: .openURL,
                systemPrompt: "",
                scriptSource: "https://www.wolframalpha.com/input?i={text}",
                afterRun: .closeToolbar,
                appliesWhenRegex: ""
            )
            action.actionDescription = "Compute or look up the selected text in Wolfram Alpha."
            return action
        }
    }

    nonisolated private static func webGoogleScholar() -> LibraryPreset {
        LibraryPreset(id: "web.googlescholar", category: .web) {
            var action = CustomAction(
                title: "Google Scholar",
                icon: .sfSymbol("graduationcap"),
                type: .openURL,
                systemPrompt: "",
                scriptSource: "https://scholar.google.com/scholar?q={text}",
                afterRun: .closeToolbar,
                appliesWhenRegex: ""
            )
            action.actionDescription = "Search Google Scholar for academic papers on the selected text."
            return action
        }
    }

    nonisolated private static func webGoogleImages() -> LibraryPreset {
        LibraryPreset(id: "web.googleimages", category: .web) {
            var action = CustomAction(
                title: "Google Images",
                icon: .sfSymbol("photo"),
                type: .openURL,
                systemPrompt: "",
                scriptSource: "https://www.google.com/search?tbm=isch&q={text}",
                afterRun: .closeToolbar,
                appliesWhenRegex: ""
            )
            action.actionDescription = "Search Google Images for the selected text."
            return action
        }
    }

    nonisolated private static func webGoodreads() -> LibraryPreset {
        LibraryPreset(id: "web.goodreads", category: .web) {
            var action = CustomAction(
                title: "Goodreads",
                icon: .sfSymbol("books.vertical"),
                type: .openURL,
                systemPrompt: "",
                scriptSource: "https://www.goodreads.com/search?q={text}",
                afterRun: .closeToolbar,
                appliesWhenRegex: ""
            )
            action.actionDescription = "Search Goodreads for books matching the selected text."
            return action
        }
    }

    nonisolated private static func webLetterboxd() -> LibraryPreset {
        LibraryPreset(id: "web.letterboxd", category: .web) {
            var action = CustomAction(
                title: "Letterboxd",
                icon: .sfSymbol("film"),
                type: .openURL,
                systemPrompt: "",
                scriptSource: "https://letterboxd.com/search/{text}/",
                afterRun: .closeToolbar,
                appliesWhenRegex: ""
            )
            action.actionDescription = "Search Letterboxd for films matching the selected text."
            return action
        }
    }

    nonisolated private static func webRottenTomatoes() -> LibraryPreset {
        LibraryPreset(id: "web.rottentomatoes", category: .web) {
            var action = CustomAction(
                title: "Rotten Tomatoes",
                icon: .sfSymbol("star"),
                type: .openURL,
                systemPrompt: "",
                scriptSource: "https://www.rottentomatoes.com/search?search={text}",
                afterRun: .closeToolbar,
                appliesWhenRegex: ""
            )
            action.actionDescription = "Search Rotten Tomatoes for the selected text."
            return action
        }
    }

    nonisolated private static func webUrbanDictionary() -> LibraryPreset {
        LibraryPreset(id: "web.urbandictionary", category: .web) {
            var action = CustomAction(
                title: "Urban Dictionary",
                icon: .sfSymbol("text.bubble"),
                type: .openURL,
                systemPrompt: "",
                scriptSource: "https://www.urbandictionary.com/define.php?term={text}",
                afterRun: .closeToolbar,
                appliesWhenRegex: ""
            )
            action.actionDescription = "Look up the selected text on Urban Dictionary."
            return action
        }
    }

    nonisolated private static func webWaybackMachine() -> LibraryPreset {
        LibraryPreset(id: "web.waybackmachine", category: .web) {
            var action = CustomAction(
                title: "Wayback Machine",
                icon: .sfSymbol("clock.arrow.circlepath"),
                type: .openURL,
                systemPrompt: "",
                scriptSource: "https://web.archive.org/web/*/{text}",
                afterRun: .closeToolbar,
                appliesWhenRegex: ""
            )
            action.actionDescription = "View archived snapshots of the selected URL on the Wayback Machine."
            return action
        }
    }

    nonisolated private static func webPubMed() -> LibraryPreset {
        LibraryPreset(id: "web.pubmed", category: .web) {
            var action = CustomAction(
                title: "PubMed",
                icon: .sfSymbol("cross.case"),
                type: .openURL,
                systemPrompt: "",
                scriptSource: "https://pubmed.ncbi.nlm.nih.gov/?term={text}",
                afterRun: .closeToolbar,
                appliesWhenRegex: ""
            )
            action.actionDescription = "Search PubMed for biomedical literature on the selected text."
            return action
        }
    }

    nonisolated private static func webReddit() -> LibraryPreset {
        LibraryPreset(id: "web.reddit", category: .web) {
            var action = CustomAction(
                title: "Reddit",
                icon: .sfSymbol("bubble.left.and.bubble.right"),
                type: .openURL,
                systemPrompt: "",
                scriptSource: "https://www.reddit.com/search/?q={text}",
                afterRun: .closeToolbar,
                appliesWhenRegex: ""
            )
            action.actionDescription = "Search Reddit for the selected text."
            return action
        }
    }

    nonisolated private static func webTwitter() -> LibraryPreset {
        LibraryPreset(id: "web.twitter", category: .web) {
            var action = CustomAction(
                title: "X (Twitter)",
                icon: .sfSymbol("at"),
                type: .openURL,
                systemPrompt: "",
                scriptSource: "https://twitter.com/search?q={text}",
                afterRun: .closeToolbar,
                appliesWhenRegex: ""
            )
            action.actionDescription = "Search X (Twitter) for the selected text."
            return action
        }
    }

    nonisolated private static func webSpotify() -> LibraryPreset {
        LibraryPreset(id: "web.spotify", category: .web) {
            var action = CustomAction(
                title: "Spotify",
                icon: .sfSymbol("music.note"),
                type: .openURL,
                systemPrompt: "",
                scriptSource: "https://open.spotify.com/search/{text}",
                afterRun: .closeToolbar,
                appliesWhenRegex: ""
            )
            action.actionDescription = "Search Spotify for the selected text."
            return action
        }
    }

    nonisolated private static func webAppleMusic() -> LibraryPreset {
        LibraryPreset(id: "web.applemusic", category: .web) {
            var action = CustomAction(
                title: "Apple Music",
                icon: .sfSymbol("music.note"),
                type: .openURL,
                systemPrompt: "",
                scriptSource: "https://music.apple.com/us/search?term={text}",
                afterRun: .closeToolbar,
                appliesWhenRegex: ""
            )
            action.actionDescription = "Search Apple Music for the selected text."
            return action
        }
    }

    // MARK: - Maps Presets

    nonisolated private static func mapsPresets() -> [LibraryPreset] {
        [
            mapsApple(),
            mapsGoogle(),
            mapsOpenStreetMap(),
            mapsWhat3Words(),
        ]
    }

    nonisolated private static func mapsApple() -> LibraryPreset {
        LibraryPreset(id: "maps.apple", category: .maps) {
            var action = CustomAction(
                title: "Apple Maps",
                icon: .sfSymbol("mappin.and.ellipse"),
                type: .openURL,
                systemPrompt: "",
                scriptSource: "https://maps.apple.com/?q={text}",
                afterRun: .closeToolbar,
                appliesWhenRegex: ""
            )
            action.actionDescription = "Search Apple Maps for the selected text."
            return action
        }
    }

    nonisolated private static func mapsGoogle() -> LibraryPreset {
        LibraryPreset(id: "maps.google", category: .maps) {
            var action = CustomAction(
                title: "Google Maps",
                icon: .sfSymbol("mappin.and.ellipse"),
                type: .openURL,
                systemPrompt: "",
                scriptSource: "https://www.google.com/maps/search/{text}",
                afterRun: .closeToolbar,
                appliesWhenRegex: ""
            )
            action.actionDescription = "Search Google Maps for the selected text."
            return action
        }
    }

    nonisolated private static func mapsOpenStreetMap() -> LibraryPreset {
        LibraryPreset(id: "maps.openstreetmap", category: .maps) {
            var action = CustomAction(
                title: "OpenStreetMap",
                icon: .sfSymbol("map"),
                type: .openURL,
                systemPrompt: "",
                scriptSource: "https://www.openstreetmap.org/search?query={text}",
                afterRun: .closeToolbar,
                appliesWhenRegex: ""
            )
            action.actionDescription = "Search OpenStreetMap for the selected text."
            return action
        }
    }

    nonisolated private static func mapsWhat3Words() -> LibraryPreset {
        LibraryPreset(id: "maps.what3words", category: .maps) {
            var action = CustomAction(
                title: "what3words",
                icon: .sfSymbol("mappin"),
                type: .openURL,
                systemPrompt: "",
                scriptSource: "https://what3words.com/{text}",
                afterRun: .closeToolbar,
                appliesWhenRegex: ""
            )
            action.actionDescription = "Look up a what3words address for the selected text."
            return action
        }
    }

    // MARK: - AI Launcher Presets

    nonisolated private static func aiLauncherPresets() -> [LibraryPreset] {
        [
            aiChatGPT(),
            aiClaude(),
            aiGrok(),
            aiPerplexity(),
            aiGemini(),
        ]
    }

    nonisolated private static func aiChatGPT() -> LibraryPreset {
        LibraryPreset(id: "ai.chatgpt", category: .aiLaunchers) {
            var action = CustomAction(
                title: "ChatGPT",
                icon: .sfSymbol("sparkles"),
                type: .openURL,
                systemPrompt: "",
                scriptSource: "https://chatgpt.com/?q={text}", // ⚠ verify scheme
                afterRun: .closeToolbar,
                appliesWhenRegex: ""
            )
            action.actionDescription = "Open ChatGPT with the selected text as a prompt."
            return action
        }
    }

    nonisolated private static func aiClaude() -> LibraryPreset {
        LibraryPreset(id: "ai.claude", category: .aiLaunchers) {
            var action = CustomAction(
                title: "Claude",
                icon: .sfSymbol("sparkles"),
                type: .openURL,
                systemPrompt: "",
                scriptSource: "https://claude.ai/new?q={text}", // ⚠ verify scheme
                afterRun: .closeToolbar,
                appliesWhenRegex: ""
            )
            action.actionDescription = "Open Claude with the selected text as a prompt."
            return action
        }
    }

    nonisolated private static func aiGrok() -> LibraryPreset {
        LibraryPreset(id: "ai.grok", category: .aiLaunchers) {
            var action = CustomAction(
                title: "Grok",
                icon: .sfSymbol("sparkles"),
                type: .openURL,
                systemPrompt: "",
                scriptSource: "https://grok.com/?q={text}", // ⚠ verify scheme
                afterRun: .closeToolbar,
                appliesWhenRegex: ""
            )
            action.actionDescription = "Open Grok with the selected text as a prompt."
            return action
        }
    }

    nonisolated private static func aiPerplexity() -> LibraryPreset {
        LibraryPreset(id: "ai.perplexity", category: .aiLaunchers) {
            var action = CustomAction(
                title: "Perplexity",
                icon: .sfSymbol("sparkles"),
                type: .openURL,
                systemPrompt: "",
                scriptSource: "https://www.perplexity.ai/search?q={text}", // ⚠ verify scheme
                afterRun: .closeToolbar,
                appliesWhenRegex: ""
            )
            action.actionDescription = "Search Perplexity AI with the selected text."
            return action
        }
    }

    nonisolated private static func aiGemini() -> LibraryPreset {
        LibraryPreset(id: "ai.gemini", category: .aiLaunchers) {
            var action = CustomAction(
                title: "Gemini",
                icon: .sfSymbol("sparkles"),
                type: .openURL,
                systemPrompt: "",
                scriptSource: "https://gemini.google.com/app?q={text}", // ⚠ verify scheme
                afterRun: .closeToolbar,
                appliesWhenRegex: ""
            )
            action.actionDescription = "Open Gemini with the selected text as a prompt."
            return action
        }
    }

    // MARK: - Translate Launcher Presets

    nonisolated private static func translateLauncherPresets() -> [LibraryPreset] {
        [
            translateGoogle(),
            translateDeepL(),
            translateBing(),
            translateReverso(),
        ]
    }

    nonisolated private static func translateGoogle() -> LibraryPreset {
        LibraryPreset(id: "translate.google", category: .translateLaunchers) {
            var action = CustomAction(
                title: "Google Translate",
                icon: .sfSymbol("character.bubble"),
                type: .openURL,
                systemPrompt: "",
                scriptSource: "https://translate.google.com/?sl=auto&tl=en&text={text}&op=translate",
                afterRun: .closeToolbar,
                appliesWhenRegex: ""
            )
            action.actionDescription = "Translate the selected text to English using Google Translate."
            return action
        }
    }

    nonisolated private static func translateDeepL() -> LibraryPreset {
        LibraryPreset(id: "translate.deepl", category: .translateLaunchers) {
            var action = CustomAction(
                title: "DeepL",
                icon: .sfSymbol("character.bubble"),
                type: .openURL,
                systemPrompt: "",
                scriptSource: "https://www.deepl.com/translator#auto/en/{text}", // ⚠ verify scheme
                afterRun: .closeToolbar,
                appliesWhenRegex: ""
            )
            action.actionDescription = "Translate the selected text to English using DeepL."
            return action
        }
    }

    nonisolated private static func translateBing() -> LibraryPreset {
        LibraryPreset(id: "translate.bing", category: .translateLaunchers) {
            var action = CustomAction(
                title: "Bing Translator",
                icon: .sfSymbol("character.bubble"),
                type: .openURL,
                systemPrompt: "",
                scriptSource: "https://www.bing.com/translator/?text={text}&from=&to=en",
                afterRun: .closeToolbar,
                appliesWhenRegex: ""
            )
            action.actionDescription = "Translate the selected text to English using Bing Translator."
            return action
        }
    }

    nonisolated private static func translateReverso() -> LibraryPreset {
        LibraryPreset(id: "translate.reverso", category: .translateLaunchers) {
            var action = CustomAction(
                title: "Reverso",
                icon: .sfSymbol("character.bubble"),
                type: .openURL,
                systemPrompt: "",
                scriptSource: "https://context.reverso.net/translation/?q={text}", // ⚠ verify scheme
                afterRun: .closeToolbar,
                appliesWhenRegex: ""
            )
            action.actionDescription = "Look up the selected text in Reverso Context."
            return action
        }
    }
}
