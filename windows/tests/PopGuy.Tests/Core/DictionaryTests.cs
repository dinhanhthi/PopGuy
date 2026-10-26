using System.Net;
using System.Text;
using PopGuy.Core.Actions;
using PopGuy.Core.Dictionaries;
using PopGuy.Core.Providers;
using PopGuy.Core.Speak;
using PopGuy.Tests.Support;

namespace PopGuy.Tests.Core;

// Key feature and untrusted input: the dictionary engine (macOS DictionaryEngine.swift, spec-4 §3.4) returns every
// provider's definition in provider order whatever finishes first; the minhqnd and Free Dictionary API responses
// (§3.5) map to entries, a miss is "not found" and a malformed body a typed error; audio URLs from the JSON are https
// only (§1.6-1.7), and the pronunciation download is capped.
public sealed class DictionaryTests
{
    private static CancellationToken Ct => TestContext.Current.CancellationToken;

    // freedictionaryapi.com, trimmed from a real "serendipity" response.
    private const string FreeDictionaryPayload = """
        {"word":"serendipity","entries":[{"language":{"code":"en","name":"English"},"partOfSpeech":"noun",
        "pronunciations":[{"type":"ipa","text":"/ˌsɛɹ.ənˈdɪp.ɪ.ti/","tags":["US"]},{"type":"ipa","text":""}],
        "senses":[{"definition":"The phenomenon of making an unplanned, fortunate discovery.",
        "examples":["Pure serendipity brought us together.",""],"synonyms":["chance"]},{"definition":""}],
        "synonyms":["luck"]}]}
        """;

    // dict.minhqnd.com, trimmed from a real "xin chào" response.
    private const string MinhqndPayload = """
        {"exists":true,"word":"xin chào","results":[{"lang_code":"vi","lang_name":"Tiếng Việt",
        "audio":"/api/v1/tts?word=xin%20ch%C3%A0o&lang=vi",
        "meanings":[{"definition":"to cordially greet","definition_lang":"en",
        "example":"(Chúng tôi) xin (kính) chào quý vị và các bạn.","pos":"Động từ","links":["cordially","greet"]}],
        "pronunciations":[{"ipa":"[sin˧˧ t͡ɕaːw˦˩]","region":"Huế"},{"ipa":"","region":"Saigon"}],
        "relations":[{"related_word":"chào","relation_type":"Đồng nghĩa"},{"related_word":"tạm biệt","relation_type":"Trái nghĩa"}]}]}
        """;

    // api.dictionaryapi.dev (pronunciation audio only).
    private const string WordAudioPayload = """
        [{"word":"serendipity","phonetics":[
        {"text":"/x/","audio":""},
        {"text":"/x/","audio":"https://api.dictionaryapi.dev/media/pronunciations/en/serendipity-au.mp3"},
        {"text":"/x/","audio":"https://api.dictionaryapi.dev/media/pronunciations/en/serendipity-us.mp3"}]}]
        """;

    [Fact]
    public async Task FreeDictionaryMapsTheEntries()
    {
        var handler = new FakeHttpHandler(HttpStatusCode.OK, FreeDictionaryPayload);
        var provider = new FreeDictionaryProvider(new ProviderHttp(handler));

        var entry = await provider.LookupAsync(" serendipity/x ", null, "en", Ct);

        // The word is one escaped path segment.
        Assert.Equal("https://freedictionaryapi.com/api/v1/entries/en/serendipity%2Fx",
            Assert.Single(handler.Requests).Uri!.AbsoluteUri);
        Assert.Equal("serendipity", entry.Headword);
        Assert.Equal("Free Dictionary API", entry.SourceName);
        var lexical = Assert.Single(entry.LexicalEntries);
        Assert.Equal("English", lexical.Language);
        Assert.Equal("noun", lexical.PartOfSpeech);
        Assert.Null(lexical.AudioUrl);
        var pronunciation = Assert.Single(lexical.Pronunciations);
        Assert.Equal("/ˌsɛɹ.ənˈdɪp.ɪ.ti/", pronunciation.Ipa);
        Assert.Equal(["US"], pronunciation.Tags);
        var sense = Assert.Single(lexical.Senses);
        Assert.Equal("The phenomenon of making an unplanned, fortunate discovery.", sense.Definition);
        Assert.Equal(["Pure serendipity brought us together."], sense.Examples);
        Assert.Equal(["chance", "luck"], sense.Synonyms);
    }

    [Fact]
    public async Task MinhqndMapsTheVietnameseResult()
    {
        var handler = new FakeHttpHandler(HttpStatusCode.OK, MinhqndPayload);
        var provider = new MinhqndProvider(new ProviderHttp(handler));

        var entry = await provider.LookupAsync("xin chào", null, "en", Ct);

        Assert.Equal("https://dict.minhqnd.com/api/v1/lookup?word=xin%20ch%C3%A0o&def_lang=en",
            Assert.Single(handler.Requests).Uri!.AbsoluteUri);
        Assert.Equal(("xin chào", "minhqnd"), (entry.Headword, entry.SourceName));
        var lexical = Assert.Single(entry.LexicalEntries);
        Assert.Equal(("Tiếng Việt", "Động từ"), (lexical.Language, lexical.PartOfSpeech));
        Assert.Equal("https://dict.minhqnd.com/api/v1/tts?word=xin%20ch%C3%A0o&lang=vi", lexical.AudioUrl);
        Assert.Equal(lexical.AudioUrl, entry.PrimaryAudioUrl);
        var pronunciation = Assert.Single(lexical.Pronunciations);
        Assert.Equal("[sin˧˧ t͡ɕaːw˦˩]", pronunciation.Ipa);
        Assert.Equal(["Huế"], pronunciation.Tags);
        var sense = Assert.Single(lexical.Senses);
        Assert.Equal("to cordially greet", sense.Definition);
        Assert.Equal(["(Chúng tôi) xin (kính) chào quý vị và các bạn."], sense.Examples);
        Assert.Equal(["chào", "cordially", "greet"], sense.Synonyms);
    }

    // A miss is "not found" (never an error tab); other statuses and bodies that are not the expected JSON are typed
    // errors with the spec's messages, and never an unhandled exception.
    [Theory]
    [InlineData("free", 404, "{}", DictionaryLookupErrorKind.NotFound, "No definition found")]
    [InlineData("free", 200, """{"word":"x","entries":[]}""", DictionaryLookupErrorKind.NotFound, "No definition found")]
    [InlineData("free", 200, """{"word":5,"entries":{"a":1}}""", DictionaryLookupErrorKind.NotFound, "No definition found")]
    [InlineData("free", 429, "slow down", DictionaryLookupErrorKind.RateLimited, "Dictionary rate limit reached. Try again later.")]
    [InlineData("free", 200, "<html>oops", DictionaryLookupErrorKind.Decoding, "Could not read dictionary response: invalid JSON")]
    [InlineData("minhqnd", 404, "{}", DictionaryLookupErrorKind.NotFound, "No definition found")]
    [InlineData("minhqnd", 200, """{"exists":false,"word":"x","results":[]}""", DictionaryLookupErrorKind.NotFound, "No definition found")]
    [InlineData("minhqnd", 200, """{"exists":true,"results":[7,"x",null]}""", DictionaryLookupErrorKind.NotFound, "No definition found")]
    [InlineData("minhqnd", 429, "slow down", DictionaryLookupErrorKind.Network, "Dictionary lookup failed: HTTP 429")]
    [InlineData("minhqnd", 200, "[1,2]", DictionaryLookupErrorKind.Decoding, "Could not read dictionary response: invalid JSON")]
    public async Task MissesAndBadResponsesAreTypedErrors(
        string provider, int status, string body, DictionaryLookupErrorKind kind, string message)
    {
        var http = new ProviderHttp(new FakeHttpHandler((HttpStatusCode)status, body));
        IDictionaryProvider lookup = provider == "free" ? new FreeDictionaryProvider(http) : new MinhqndProvider(http);

        var error = await Assert.ThrowsAsync<DictionaryLookupException>(() => lookup.LookupAsync("x", null, "en", Ct));

        Assert.Equal(kind, error.Kind);
        Assert.Equal(message, error.Message);
    }

    // The audio string is untrusted: only https is used; a path is resolved against minhqnd; without one, the TTS URL is
    // built with escaped query values so a crafted headword or language cannot add parameters.
    [Theory]
    [InlineData("https://cdn.example/a.mp3", "vi", "https://cdn.example/a.mp3")]
    [InlineData(" /api/v1/tts?word=a ", "vi", "https://dict.minhqnd.com/api/v1/tts?word=a")]
    [InlineData("media/a.mp3", "vi", "https://dict.minhqnd.com/media/a.mp3")]
    [InlineData("http://dict.minhqnd.com/a.mp3", "vi", null)]
    [InlineData("file:///etc/passwd", "vi", null)]
    [InlineData("data:audio/mpeg;base64,AAAA", "vi", null)]
    [InlineData("javascript:alert(1)", "vi", null)]
    [InlineData(null, "v&i=x", "https://dict.minhqnd.com/api/v1/tts?word=a%26b%3Dc&lang=v%26i%3Dx")]
    [InlineData("", null, null)]
    public void MinhqndAudioUrlIsHttpsOnly(string? audio, string? langCode, string? expected) =>
        Assert.Equal(expected, MinhqndProvider.ResolveAudioUrl(audio, langCode, audio is null ? "a&b=c" : "a"));

    private sealed class FakeProvider(Task<DictionaryEntry> result) : IDictionaryProvider
    {
        public List<(string Term, string? Source, string? Definition)> Calls { get; } = [];

        public Task<DictionaryEntry> LookupAsync(
            string term, string? sourceLanguage, string? definitionLanguage, CancellationToken ct)
        {
            Calls.Add((term, sourceLanguage, definitionLanguage));
            return result;
        }
    }

    private static DictionaryEntry Entry(string source) => new("word", [], source);

    // Spec-4 §3.4: providers run together; successes come back in provider order (minhqnd, then Free Dictionary API)
    // whatever finishes first, and a provider Windows lacks (the macOS Dictionary; Babylon until it is added) is
    // skipped.
    [Fact]
    public async Task LookupAllReturnsSuccessesInProviderOrder()
    {
        var minhqnd = new TaskCompletionSource<DictionaryEntry>();
        var free = new TaskCompletionSource<DictionaryEntry>();
        var providers = new Dictionary<DictionaryProviderKind, FakeProvider>
        {
            [DictionaryProviderKind.Minhqnd] = new(minhqnd.Task),
            [DictionaryProviderKind.FreeDictionaryApi] = new(free.Task),
        };
        var engine = new DictionaryEngine(kind => providers.GetValueOrDefault(kind));

        var run = engine.LookupAllAsync(" word \n", new DictionaryConfig { DefinitionLanguage = "vi" }, Ct);
        free.SetResult(Entry("Free"));
        minhqnd.SetResult(Entry("minhqnd"));
        var results = await run;

        Assert.Equal([DictionaryProviderKind.Minhqnd, DictionaryProviderKind.FreeDictionaryApi],
            results.Select(r => r.ProviderKind));
        Assert.Equal(["minhqnd", "Free"], results.Select(r => r.Entry.SourceName));
        Assert.All(providers.Values, p => Assert.Equal(("word", null, "vi"), Assert.Single(p.Calls)));

        // A single lookup with a provider Windows lacks finds nothing.
        var single = await Assert.ThrowsAsync<DictionaryLookupException>(() =>
            engine.LookupAsync("word", new DictionaryConfig { Provider = DictionaryProviderKind.MacOSBuiltin }, Ct));
        Assert.Equal(DictionaryLookupErrorKind.NotFound, single.Kind);
    }

    // One success hides the other provider's error; with none, the first error to arrive wins over "not found".
    [Theory]
    [InlineData("ok", "network", "minhqnd")]
    [InlineData("notFound", "ok", "Free")]
    [InlineData("notFound", "notFound", "NotFound")]
    [InlineData("notFound", "network", "Network")]
    [InlineData("rateLimited", "network", "Network")]
    [InlineData("crash", "notFound", "Network")]
    public async Task LookupAllPrefersAnySuccessThenTheFirstError(string minhqnd, string free, string expected)
    {
        // Free Dictionary API finishes first.
        var freeDone = new TaskCompletionSource<DictionaryEntry>();
        var minhqndDone = new TaskCompletionSource<DictionaryEntry>();
        var engine = new DictionaryEngine(kind => kind switch
        {
            DictionaryProviderKind.Minhqnd => new FakeProvider(minhqndDone.Task),
            DictionaryProviderKind.FreeDictionaryApi => new FakeProvider(freeDone.Task),
            _ => null,
        });

        var run = engine.LookupAllAsync("word", new DictionaryConfig(), Ct);
        Complete(freeDone, free, "Free");
        Complete(minhqndDone, minhqnd, "minhqnd");

        if (expected is "minhqnd" or "Free")
        {
            Assert.Equal(expected, Assert.Single(await run).Entry.SourceName);
            return;
        }
        var error = await Assert.ThrowsAsync<DictionaryLookupException>(() => run);
        Assert.Equal(Enum.Parse<DictionaryLookupErrorKind>(expected), error.Kind);

        static void Complete(TaskCompletionSource<DictionaryEntry> done, string outcome, string source)
        {
            switch (outcome)
            {
                case "ok": done.SetResult(Entry(source)); break;
                case "notFound": done.SetException(DictionaryLookupException.NotFound()); break;
                case "network": done.SetException(DictionaryLookupException.Network("HTTP 500")); break;
                case "rateLimited": done.SetException(DictionaryLookupException.RateLimited()); break;
                default: done.SetException(new InvalidOperationException("boom")); break;
            }
        }
    }

    [Fact]
    public async Task BlankTermFindsNothingWithoutAsking()
    {
        var provider = new FakeProvider(Task.FromResult(Entry("minhqnd")));
        var engine = new DictionaryEngine(_ => provider);

        var error = await Assert.ThrowsAsync<DictionaryLookupException>(() =>
            engine.LookupAllAsync(" \n ", new DictionaryConfig(), Ct));

        Assert.Equal(DictionaryLookupErrorKind.NotFound, error.Kind);
        Assert.Empty(provider.Calls);
    }

    /// <summary>Answers each request by URL; records the URLs.</summary>
    private sealed class RoutedHandler(Func<Uri, (HttpStatusCode Status, string Body)> route) : HttpMessageHandler
    {
        public List<Uri> Requests { get; } = [];

        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            Requests.Add(request.RequestUri!);
            var (status, body) = route(request.RequestUri!);
            return Task.FromResult(new HttpResponseMessage(status) { Content = new StringContent(body) });
        }
    }

    // Spec-4 §1.7: the word (trimmed, lowercased) is looked up in English; the accent's recording is preferred, else the
    // first non-empty one; an audio URL that is not https is never fetched.
    [Theory]
    [InlineData("us", "https://api.dictionaryapi.dev/media/pronunciations/en/serendipity-us.mp3")]
    [InlineData("uk", "https://api.dictionaryapi.dev/media/pronunciations/en/serendipity-au.mp3")]
    public async Task WordAudioPicksTheAccentRecording(string variant, string expectedAudio)
    {
        var handler = new RoutedHandler(uri => uri.AbsolutePath.EndsWith(".mp3", StringComparison.Ordinal)
            ? (HttpStatusCode.OK, "mp3:" + uri.AbsoluteUri)
            : (HttpStatusCode.OK, WordAudioPayload));
        var engine = new DictionaryAudioEngine(new ProviderHttp(handler));

        var audio = await engine.FetchWordAsync(" Serendipity ", variant, Ct);

        Assert.Equal("mp3:" + expectedAudio, Encoding.UTF8.GetString(audio!));
        Assert.Equal(["https://api.dictionaryapi.dev/api/v2/entries/en/serendipity", expectedAudio],
            handler.Requests.Select(u => u.AbsoluteUri));
    }

    [Theory]
    // The JSON's audio URL is not https: no download.
    [InlineData("""[{"phonetics":[{"audio":"http://evil.example/a-us.mp3"}]}]""", HttpStatusCode.OK, 1)]
    // No audio, malformed shapes, a miss: nothing.
    [InlineData("""[{"phonetics":[{"audio":""},{"audio":5}]},{"phonetics":"x"},3]""", HttpStatusCode.OK, 1)]
    [InlineData("""{"title":"No Definitions Found"}""", HttpStatusCode.NotFound, 1)]
    [InlineData("not json", HttpStatusCode.OK, 1)]
    public async Task WordAudioWithoutAnHttpsRecordingIsNull(string payload, HttpStatusCode status, int requests)
    {
        var handler = new RoutedHandler(_ => (status, payload));
        var engine = new DictionaryAudioEngine(new ProviderHttp(handler));

        Assert.Null(await engine.FetchWordAsync("hello", "us", Ct));
        Assert.Equal(requests, handler.Requests.Count);
    }

    [Fact]
    public async Task AudioUrlIsHttpsOnlyAndCapped()
    {
        var handler = new RoutedHandler(uri => uri.AbsolutePath == "/big.mp3"
            ? (HttpStatusCode.OK, new string('x', DictionaryAudioEngine.MaxAudioBytes + 1))
            : (HttpStatusCode.OK, "mp3"));
        var engine = new DictionaryAudioEngine(new ProviderHttp(handler));

        foreach (var refused in new[] { "http://dict.minhqnd.com/a.mp3", "file:///C:/a.mp3", "/a.mp3", "not a url", "" })
            Assert.Null(await engine.FetchUrlAsync(refused, Ct));
        Assert.Empty(handler.Requests);

        Assert.Equal("mp3", Encoding.UTF8.GetString((await engine.FetchUrlAsync("https://dict.minhqnd.com/a.mp3", Ct))!));
        Assert.Null(await engine.FetchUrlAsync("https://dict.minhqnd.com/big.mp3", Ct));
    }

    // Spec-4 §1.6: only a single word (letters, "-" and "'", up to 45 characters) is looked up for its recording.
    [Theory]
    [InlineData("rock-'n'-roll", true)]
    [InlineData("chào", true)]
    [InlineData("xin chào", false)]
    [InlineData("covid19", false)]
    [InlineData("pneumonoultramicroscopicsilicovolcanoconiosiss", false)]
    public void SingleWordRule(string text, bool expected) => Assert.Equal(expected, SpeakRules.IsSingleWord(text));
}
