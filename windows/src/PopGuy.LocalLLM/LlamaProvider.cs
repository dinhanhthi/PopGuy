using System.Buffers;
using System.Runtime.CompilerServices;
using System.Text;
using System.Threading.Channels;
using LLama;
using LLama.Common;
using LLama.Exceptions;
using LLama.Native;
using LLama.Sampling;
using PopGuy.Core.Providers;

namespace PopGuy.LocalLLM;

/// <summary>
/// ProviderKind <c>mlx_local</c> on Windows ("Local model (on this PC)"): a downloaded GGUF chat model run in-process
/// with llama.cpp (LLamaSharp), the counterpart of macOS <c>MLXLocalProvider</c> and its MLX helper. One model is
/// loaded at a time and kept between runs, one run streams at a time, and the weights are freed after
/// <see cref="IdleTimeout"/> without a run (the helper's idle unload). Every failure is a
/// <see cref="ProviderError"/> of kind Transport, as macOS wraps every helper failure (natives that cannot load get
/// the Visual C++ runtime hint); cancelling the token throws OperationCanceledException. Building one touches no native
/// code, so the factory lambda never throws, and a run's native work happens on the thread pool, never on the caller's
/// thread.
/// </summary>
public sealed class LlamaProvider : IProvider
{
    public const string NotDownloadedMessage =
        "The local model isn't downloaded. Download it in Settings → Providers → Local AI.";

    /// <summary>macOS <c>MLXLocalInputError.inputTooLong</c>, without the model name.</summary>
    public const string TooLongMessage =
        "This text is too long for this model. Select a shorter passage or choose another model for this action.";

    internal const string LoadFailedMessage = "The local model could not be loaded.";

    /// <summary>
    /// The llama.cpp natives need the Visual C++ runtime (msvcp140, vcruntime140), which a PC without the
    /// redistributable lacks. A native load that failed in a type initializer stays failed for the life of the process,
    /// hence the restart rather than a retry.
    /// </summary>
    internal const string RuntimeMissingMessage =
        "The local model needs the Microsoft Visual C++ Runtime, which isn't installed. Install the Visual C++ " +
        "Redistributable (2015–2022) for your PC, then restart PopGuy.";
    internal const string RunFailedMessage = "The local model stopped with an error.";

    /// <summary>How long the weights stay loaded after a run (the macOS helper's 300 s default).</summary>
    public static readonly TimeSpan IdleTimeout = TimeSpan.FromMinutes(5);

    private readonly Func<string, string?> _resolveModelPath;
    // Held for a whole run, a load and an unload: one model in memory, one answer at a time.
    private readonly SemaphoreSlim _lock = new(1, 1);
    private readonly Timer _idleTimer;
    private LoadedModel? _loaded;
    private long _lastRunEnd;

    /// <param name="resolveModelPath">The <c>.gguf</c> file of a model id, null when it is not downloaded (the
    /// catalog, task 21.2, which also maps an unknown id to the default model).</param>
    public LlamaProvider(Func<string, string?> resolveModelPath)
    {
        _resolveModelPath = resolveModelPath;
        _idleTimer = new Timer(_ => UnloadIfIdle());
    }

    public async IAsyncEnumerable<string> StreamAsync(
        string? systemPrompt, string input, string model, ProviderOptions options,
        [EnumeratorCancellation] CancellationToken ct = default)
    {
        var path = _resolveModelPath(model);
        if (path is null || !File.Exists(path)) throw ProviderError.Transport(NotDownloadedMessage);
        List<ChatMessage> messages = string.IsNullOrEmpty(systemPrompt)
            ? [new("user", input)]
            : [new("system", systemPrompt), new("user", input)];

        // The run goes on in the background, feeding a channel: loading the natives and the weights, the prefill and
        // each token's sampling are native calls that would otherwise run on the caller's (UI) thread up to their
        // first real await, and every await of this iterator would resume there. Leaving early stops the run.
        var channel = Channel.CreateUnbounded<string>(new UnboundedChannelOptions { SingleReader = true, SingleWriter = true });
        using var stop = CancellationTokenSource.CreateLinkedTokenSource(ct);
        var token = stop.Token;
        _ = Task.Run(async () =>
        {
            try
            {
                await GenerateAsync(path, messages, LlamaSettings.MaxTokens(options.MaxTokens),
                    piece => channel.Writer.TryWrite(piece), token);
                channel.Writer.TryComplete();
            }
            catch (Exception error)
            {
                channel.Writer.TryComplete(error);
            }
        }, CancellationToken.None);
        var finished = false;
        try
        {
            await foreach (var piece in channel.Reader.ReadAllAsync(ct))
                yield return piece;
            finished = true;
        }
        finally
        {
            if (!finished)
                stop.Cancel();
        }
    }

    private async Task GenerateAsync(
        string path, List<ChatMessage> messages, int maxTokens, Action<string> write, CancellationToken ct)
    {
        await _lock.WaitAsync(ct);
        try
        {
            var loaded = await LoadAsync(path, ct);
            using var run = await Run.StartAsync(loaded, messages, maxTokens, ct);
            while (await run.NextAsync(ct) is { } piece)
                write(piece);
        }
        finally
        {
            _lastRunEnd = Environment.TickCount64;
            _idleTimer.Change(IdleTimeout, Timeout.InfiniteTimeSpan);
            _lock.Release();
        }
    }

    /// <summary>
    /// Frees the loaded model once the current run ends. llama.cpp maps the GGUF into memory, so a loaded file cannot
    /// be deleted on Windows: Settings calls this before deleting a model.
    /// </summary>
    public async Task UnloadAsync(CancellationToken ct = default)
    {
        await _lock.WaitAsync(ct);
        try
        {
            Release();
        }
        finally
        {
            _lock.Release();
        }
    }

    private void UnloadIfIdle()
    {
        // A run holds the lock: its end re-arms the timer.
        if (!_lock.Wait(0)) return;
        try
        {
            var left = IdleTimeout - TimeSpan.FromMilliseconds(Environment.TickCount64 - _lastRunEnd);
            if (left > TimeSpan.Zero) _idleTimer.Change(left, Timeout.InfiniteTimeSpan);
            else Release();
        }
        finally
        {
            _lock.Release();
        }
    }

    private void Release()
    {
        _loaded?.Weights.Dispose();
        _loaded = null;
    }

    /// <summary>The model at <paramref name="path"/>, loaded in place of any other; call with the lock held.</summary>
    private async Task<LoadedModel> LoadAsync(string path, CancellationToken ct)
    {
        if (_loaded is { } current && string.Equals(current.Path, path, StringComparison.OrdinalIgnoreCase))
            return current;
        Release();
        var context = LlamaSettings.ContextSize(GC.GetGCMemoryInfo().TotalAvailableMemoryBytes);
        try
        {
            var parameters = new ModelParams(path) { ContextSize = (uint)context };
            var weights = await LLamaWeights.LoadFromFileAsync(parameters, ct);
            try
            {
                ct.ThrowIfCancellationRequested();
                // A model trained on a shorter window than the RAM cap gets its own.
                if (weights.ContextSize > 0 && weights.ContextSize < context)
                    parameters = parameters with { ContextSize = (uint)weights.ContextSize };
                _loaded = new LoadedModel(path, weights, parameters, new LlamaPrompt(weights));
                return _loaded;
            }
            catch
            {
                weights.Dispose();
                throw;
            }
        }
        catch (Exception e) when (e is not (OperationCanceledException or ProviderError))
        {
            // A cancelled load can fail as a load error: the caller still sees a cancellation.
            ct.ThrowIfCancellationRequested();
            throw ProviderError.Transport(LlamaSettings.IsNativeLoadFailure(e) ? RuntimeMissingMessage : LoadFailedMessage);
        }
    }

    private sealed record LoadedModel(string Path, LLamaWeights Weights, ModelParams Parameters, LlamaPrompt Prompt);

    /// <summary>One answer in a fresh context (KV cache), freed when it is disposed.</summary>
    private sealed class Run : IDisposable
    {
        private readonly LLamaWeights _weights;
        private readonly LLamaContext _context;
        // MLX's defaults besides the temperature (the helper sends no top-p): no top-p, top-k or min-p.
        private readonly DefaultSamplingPipeline _sampling = new() { Temperature = 0.7f, TopP = 1f, TopK = 0, MinP = 0f };
        private readonly StreamingTokenDecoder _decoder;
        private readonly LLamaBatch _batch = new();
        private int _past;
        private int _left;
        private bool _decodePending;

        private Run(LLamaWeights weights, LLamaContext context, int maxTokens)
        {
            _weights = weights;
            _context = context;
            _decoder = new StreamingTokenDecoder(context);
            _left = maxTokens;
        }

        /// <summary>A run with the prompt of <paramref name="messages"/> read (prefilled).</summary>
        internal static async Task<Run> StartAsync(
            LoadedModel model, List<ChatMessage> messages, int maxTokens, CancellationToken ct)
        {
            var prompt = model.Prompt.Tokens(messages).Select(t => t.Token).ToList();
            ct.ThrowIfCancellationRequested();
            Run? run = null;
            try
            {
                run = new Run(model.Weights, model.Weights.CreateContext(model.Parameters), maxTokens);
                if (prompt.Count >= run._context.ContextSize) throw ProviderError.Transport(TooLongMessage);
                var (prefill, _, past) = await run._context.DecodeAsync(prompt, LLamaSeqId.Zero, run._batch, 0, ct);
                if (prefill != DecodeResult.Ok) throw ProviderError.Transport(RunFailedMessage);
                run._past = past;
                return run;
            }
            catch (Exception e)
            {
                run?.Dispose();
                if (e is OperationCanceledException or ProviderError) throw;
                ct.ThrowIfCancellationRequested();
                throw ProviderError.Transport(RunFailedMessage);
            }
        }

        /// <summary>
        /// The next piece of text, null at the model's end-of-turn token, the token cap or a full context. The token
        /// behind a piece is decoded on the next call, so each piece is shown as soon as it is sampled.
        /// </summary>
        internal async Task<string?> NextAsync(CancellationToken ct)
        {
            try
            {
                while (true)
                {
                    if (_decodePending)
                    {
                        _decodePending = false;
                        if (await _context.DecodeAsync(_batch, ct) != DecodeResult.Ok)
                            throw ProviderError.Transport(RunFailedMessage);
                    }
                    if (_left <= 0 || _past >= _context.ContextSize) return null;
                    ct.ThrowIfCancellationRequested();
                    var token = _sampling.Sample(_context.NativeHandle, _batch.TokenCount - 1);
                    if (token.IsEndOfGeneration(_weights.Vocab)) return null;
                    _left--;
                    _decoder.Add(token);
                    _batch.Clear();
                    _batch.Add(token, _past++, LLamaSeqId.Zero, true);
                    _decodePending = true;
                    var piece = _decoder.Read();
                    if (piece.Length > 0) return piece;
                }
            }
            catch (Exception e) when (e is not (OperationCanceledException or ProviderError))
            {
                ct.ThrowIfCancellationRequested();
                throw ProviderError.Transport(RunFailedMessage);
            }
        }

        public void Dispose()
        {
            _sampling.Dispose();
            _context.Dispose();
        }
    }
}

/// <summary>A chat message: <c>system</c> or <c>user</c> and its text.</summary>
internal readonly record struct ChatMessage(string Role, string Content);

/// <summary>
/// The prompt of a chat as token ids, laid out so that only the chat template makes control tokens: the template's
/// text is tokenized with special tokens parsed, each message body without (so <c>&lt;|im_end|&gt;</c> in the
/// selected text stays text), and the user-defined tokens llama.cpp matches even then (Qwen's <c>&lt;think&gt;</c>,
/// Gemma's <c>&lt;|channel&gt;</c>) are broken in the bodies first.
/// </summary>
internal sealed class LlamaPrompt
{
    private readonly LLamaWeights _weights;
    private readonly string _template;
    private readonly IReadOnlyList<string> _userDefined;
    private readonly SearchValues<char> _userDefinedStarts;

    internal LlamaPrompt(LLamaWeights weights)
    {
        _weights = weights;
        _template = weights.NativeHandle.GetTemplate(strict: false)
            ?? throw ProviderError.Transport("This model has no chat template.");
        _userDefined = UserDefinedTokens(weights.Vocab);
        _userDefinedStarts = LlamaSettings.FirstCharacters(_userDefined);
    }

    private static List<string> UserDefinedTokens(SafeLlamaModelHandle.Vocabulary vocab)
    {
        var userDefined = new List<string>();
        for (var id = 0; id < vocab.Count; id++)
        {
            LLamaToken token = id;
            if ((token.GetAttributes(vocab) & LLamaTokenAttr.UserDefined) != 0
                && vocab.LLamaTokenToString(token, isSpecialToken: true) is { Length: > 1 } text)
            {
                userDefined.Add(text);
            }
        }
        return userDefined;
    }

    /// <summary>
    /// The ids of <paramref name="messages"/> through the GGUF's chat template, each marked with whether it comes from
    /// a message body. Throws <see cref="ProviderError"/> when the template cannot be applied or a body would still
    /// hold a control or user-defined token.
    /// </summary>
    internal List<(LLamaToken Token, bool FromBody)> Tokens(IReadOnlyList<ChatMessage> messages)
    {
        var tokens = new List<(LLamaToken, bool)>();
        foreach (var part in Parts(messages))
        {
            if (part.Text.Length == 0) continue;
            var text = part.IsBody ? LlamaSettings.Neutralized(part.Text, _userDefined, _userDefinedStarts) : part.Text;
            // BOS only before the first piece, when the model wants one (Gemma yes, Qwen no).
            var ids = _weights.Tokenize(text, add_bos: tokens.Count == 0, special: !part.IsBody, Encoding.UTF8);
            foreach (var id in ids)
            {
                if (part.IsBody && (id.GetAttributes(_weights.Vocab) & (LLamaTokenAttr.Control | LLamaTokenAttr.UserDefined)) != 0)
                    throw ProviderError.Transport("The text holds a token the model reserves for its chat format.");
                tokens.Add((id, part.IsBody));
            }
        }
        return tokens;
    }

    /// <summary>
    /// Gemma 4 is laid out by hand: llama.cpp's built-in templates (all it can apply) have no Gemma 4 format. Others go
    /// through llama.cpp with a placeholder per body, then are cut at the placeholders.
    /// </summary>
    private List<PromptPart> Parts(IReadOnlyList<ChatMessage> messages)
    {
        if (LlamaSettings.IsGemma4(_template)) return LlamaSettings.Gemma4Parts(messages);
        var nonce = Guid.NewGuid().ToString("N");
        var template = new LLamaTemplate(_template) { AddAssistant = true };
        for (var i = 0; i < messages.Count; i++) template.Add(messages[i].Role, LlamaSettings.Placeholder(nonce, i));
        string rendered;
        try
        {
            rendered = LLamaTemplate.Encoding.GetString(template.Apply());
        }
        catch (RuntimeError)
        {
            // The exception's message holds the whole template source: never shown.
            throw ProviderError.Transport(LlamaSettings.UnsupportedTemplateMessage);
        }
        return LlamaSettings.SplitAtPlaceholders(LlamaSettings.WithThinkingOff(rendered, _template), messages, nonce);
    }
}

/// <summary>Pure parts of <see cref="LlamaProvider"/>; nothing here loads the llama.cpp natives.</summary>
internal static class LlamaSettings
{
    internal const string UnsupportedTemplateMessage = "llama.cpp does not support this model's chat template.";

    /// <summary>
    /// The 16 GB line, minus what Windows keeps from the OS (firmware, integrated GPU): a 16 GB PC reports about
    /// 15.4 to 15.9 GiB of physical memory.
    /// </summary>
    internal const long LargeMemoryBytes = 15L << 30;

    /// <summary>Tokens of context (KV cache) next to the weights: 16K on 16 GB PCs and up, 8K below.</summary>
    internal static int ContextSize(long totalMemoryBytes) => totalMemoryBytes >= LargeMemoryBytes ? 16_384 : 8_192;

    /// <summary>
    /// Whether <paramref name="error"/> (or an exception inside it) is the llama.cpp natives failing to load: a DLL
    /// or one of its dependencies missing (the Visual C++ runtime), the wrong architecture, or LLamaSharp's own
    /// "native library" load error, possibly wrapped in its type initializer's failure.
    /// </summary>
    internal static bool IsNativeLoadFailure(Exception error)
    {
        for (Exception? e = error; e is not null; e = e.InnerException)
        {
            if (e is DllNotFoundException or BadImageFormatException
                || (e is RuntimeError && e.Message.Contains("native library", StringComparison.OrdinalIgnoreCase)))
            {
                return true;
            }
        }
        return false;
    }

    /// <summary>The token cap of an answer, clamped to 1…16384 as the macOS helper does.</summary>
    internal static int MaxTokens(int requested) => Math.Clamp(requested, 1, 16_384);

    /// <summary>What Qwen3's template writes after the assistant header when <c>enable_thinking</c> is false.</summary>
    internal const string EmptyThinking = "<think>\n\n</think>\n\n";

    /// <summary>
    /// llama.cpp's built-in templates cannot take <c>enable_thinking</c> (the macOS helper passes false for Qwen), so a
    /// template that reads it and uses <c>&lt;think&gt;</c> blocks gets the empty block its Jinja would write.
    /// </summary>
    internal static string WithThinkingOff(string prompt, string template) =>
        template.Contains("enable_thinking", StringComparison.Ordinal)
        && template.Contains("<think>", StringComparison.Ordinal)
        && !prompt.EndsWith(EmptyThinking, StringComparison.Ordinal)
            ? prompt + EmptyThinking
            : prompt;

    /// <summary>Gemma 4's chat template (<c>&lt;|turn&gt;role … &lt;turn|&gt;</c>), which llama.cpp's built-in matcher lacks.</summary>
    internal static bool IsGemma4(string template) =>
        template.Contains("<|turn>", StringComparison.Ordinal) && template.Contains("<turn|>", StringComparison.Ordinal);

    /// <summary>
    /// What Gemma 4's Jinja writes without tools and with thinking off: each message as <c>&lt;|turn&gt;role\n</c> +
    /// its trimmed text + <c>&lt;turn|&gt;\n</c>, then <c>&lt;|turn&gt;model\n</c>; no <c>&lt;|think|&gt;</c> line,
    /// which would turn thinking on. Its <c>bos_token</c> is the tokenizer's BOS, added when the first piece is
    /// tokenized.
    /// </summary>
    internal static List<PromptPart> Gemma4Parts(IReadOnlyList<ChatMessage> messages)
    {
        var parts = new List<PromptPart>();
        var skeleton = new StringBuilder();
        foreach (var message in messages)
        {
            skeleton.Append("<|turn>").Append(message.Role).Append('\n');
            parts.Add(new(skeleton.ToString(), IsBody: false));
            parts.Add(new(message.Content.Trim(), IsBody: true));
            skeleton.Clear().Append("<turn|>\n");
        }
        parts.Add(new(skeleton.Append("<|turn>model\n").ToString(), IsBody: false));
        return parts;
    }

    /// <summary>What stands for body <paramref name="index"/> while llama.cpp applies the template.</summary>
    internal static string Placeholder(string nonce, int index) => $"⁣{nonce}:{index}⁣";

    /// <summary>
    /// <paramref name="rendered"/> cut at each body's placeholder, in order, the bodies put back as body parts.
    /// Throws <see cref="ProviderError"/> when a placeholder is missing, repeated or out of order (a template that
    /// rewrites its content).
    /// </summary>
    internal static List<PromptPart> SplitAtPlaceholders(string rendered, IReadOnlyList<ChatMessage> messages, string nonce)
    {
        var parts = new List<PromptPart>();
        var start = 0;
        for (var i = 0; i < messages.Count; i++)
        {
            var placeholder = Placeholder(nonce, i);
            var at = rendered.IndexOf(placeholder, start, StringComparison.Ordinal);
            if (at < 0 || rendered.IndexOf(placeholder, StringComparison.Ordinal) != at
                || rendered.IndexOf(placeholder, at + placeholder.Length, StringComparison.Ordinal) >= 0)
            {
                throw ProviderError.Transport(UnsupportedTemplateMessage);
            }
            parts.Add(new(rendered[start..at], IsBody: false));
            parts.Add(new(messages[i].Content, IsBody: true));
            start = at + placeholder.Length;
        }
        parts.Add(new(rendered[start..], IsBody: false));
        return parts;
    }

    /// <summary>
    /// <paramref name="text"/> with every occurrence of a <paramref name="tokens"/> text broken by a zero-width space
    /// after its first character, again until none is left (at most 8 passes), so the tokenizer cannot match it as
    /// that token.
    /// </summary>
    internal static string Neutralized(string text, IReadOnlyCollection<string> tokens) =>
        Neutralized(text, tokens, FirstCharacters(tokens));

    /// <summary>
    /// <see cref="Neutralized(string, IReadOnlyCollection{string})"/> with the first characters of
    /// <paramref name="tokens"/>: a text holding none of them is returned at once instead of scanned once per token.
    /// </summary>
    internal static string Neutralized(string text, IReadOnlyCollection<string> tokens, SearchValues<char> firstCharacters)
    {
        if (!text.AsSpan().ContainsAny(firstCharacters)) return text;
        var changed = true;
        for (var pass = 0; pass < 8 && changed; pass++)
        {
            changed = false;
            foreach (var token in tokens)
            {
                if (token.Length < 2 || !text.Contains(token, StringComparison.Ordinal)) continue;
                text = text.Replace(token, token[0] + "​" + token[1..], StringComparison.Ordinal);
                changed = true;
            }
        }
        return text;
    }

    /// <summary>The first character of each of <paramref name="tokens"/> that <see cref="Neutralized(string, IReadOnlyCollection{string})"/> breaks.</summary>
    internal static SearchValues<char> FirstCharacters(IEnumerable<string> tokens) =>
        SearchValues.Create([.. tokens.Where(t => t.Length >= 2).Select(t => t[0]).Distinct()]);
}

/// <summary>A piece of a prompt: chat template text (special tokens parsed) or a message body (never parsed).</summary>
internal readonly record struct PromptPart(string Text, bool IsBody);
