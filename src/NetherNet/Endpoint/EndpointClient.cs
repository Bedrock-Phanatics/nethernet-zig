using System.Collections.Concurrent;
using System.Globalization;
using System.Net.Http.Headers;
using System.Text;
using NetherNet.Internal;

namespace NetherNet.Endpoint;

public sealed class EndpointClient : ISignaling, IDisablesTrickleIce, IDisposable
{
    public const int MaximumSdpBodySize = 1 << 20;

    private readonly HttpClient _httpClient;
    private readonly bool _ownsHttpClient;
    private readonly Func<CancellationToken, ValueTask<Credentials?>>? _credentialsProvider;
    private readonly ConcurrentDictionary<long, INotifier> _notifiers = new();
    private readonly CancellationTokenSource _closed = new();
    private long _notifierId;
    private int _disposed;

    public EndpointClient(EndpointClientOptions? options = null)
    {
        options ??= new EndpointClientOptions();
        _ownsHttpClient = options.HttpClient is null;
        _httpClient = options.HttpClient ?? new HttpClient();
        _credentialsProvider = options.CredentialsProvider;
        NetworkId = options.NetworkId ??
            RandomId.Create().ToString(CultureInfo.InvariantCulture);
    }

    public bool DisableTrickleIce => true;
    public CancellationToken Closed => _closed.Token;
    public string NetworkId { get; }

    public IDisposable Notify(INotifier notifier)
    {
        ArgumentNullException.ThrowIfNull(notifier);
        ObjectDisposedException.ThrowIf(Volatile.Read(ref _disposed) != 0, this);

        var id = Interlocked.Increment(ref _notifierId);
        _notifiers[id] = notifier;
        return new Subscription(() => _notifiers.TryRemove(id, out _));
    }

    public ValueTask<Credentials?> GetCredentialsAsync(
        CancellationToken cancellationToken = default)
    {
        ObjectDisposedException.ThrowIf(Volatile.Read(ref _disposed) != 0, this);
        return _credentialsProvider?.Invoke(cancellationToken) ??
            ValueTask.FromResult<Credentials?>(new Credentials());
    }

    public void SetPongData(ReadOnlySpan<byte> data) =>
        throw new NotSupportedException("Endpoint clients do not serve pong data.");

    public async ValueTask SignalAsync(
        Signal signal,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(signal);
        ObjectDisposedException.ThrowIf(Volatile.Read(ref _disposed) != 0, this);

        using var linkedCancellation = CancellationTokenSource.CreateLinkedTokenSource(
            cancellationToken,
            _closed.Token);

        switch (signal.Type)
        {
            case SignalTypes.Offer:
                await SendOfferAsync(signal, linkedCancellation.Token).ConfigureAwait(false);
                return;
            case SignalTypes.Error:
                return;
            case SignalTypes.Candidate:
                throw new NotSupportedException(
                    "HTTP endpoint signaling does not support trickle ICE.");
            default:
                throw new ArgumentException(
                    $"Unknown signal type {signal.Type}.",
                    nameof(signal));
        }
    }

    private async Task SendOfferAsync(Signal signal, CancellationToken cancellationToken)
    {
        var endpoint = ParseEndpoint(signal);
        var target = new Uri(
            endpoint,
            $"/v1/join/{Uri.EscapeDataString(NetworkId)}");

        using var request = new HttpRequestMessage(HttpMethod.Post, target);
        request.Headers.UserAgent.ParseAdd("libhttpclient/1.0.0.0");
        request.Content = new StringContent(signal.Data);
        request.Content.Headers.ContentType = new MediaTypeHeaderValue("application/sdp");

        using var response = await _httpClient
            .SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellationToken)
            .ConfigureAwait(false);
        response.EnsureSuccessStatusCode();

        if (response.Content.Headers.ContentLength > MaximumSdpBodySize)
        {
            throw new InvalidDataException("SDP answer exceeds 1 MiB.");
        }

        var answer = await ReadAnswerAsync(response.Content, cancellationToken)
            .ConfigureAwait(false);
        if (uint.TryParse(
            answer,
            NumberStyles.None,
            CultureInfo.InvariantCulture,
            out var errorCode))
        {
            throw new InvalidDataException(
                $"Negotiation failed with error code {errorCode}.");
        }

        var answerSignal = signal with
        {
            Type = SignalTypes.Answer,
            Data = answer
        };
        foreach (var notifier in _notifiers.Values)
        {
            _ = notifier.NotifySignal(answerSignal);
        }
    }

    private static Uri ParseEndpoint(Signal signal)
    {
        if (!Uri.TryCreate(signal.NetworkId, UriKind.Absolute, out var endpoint) ||
            endpoint.Scheme is not ("http" or "https") ||
            !HasExplicitPort(endpoint) ||
            endpoint.AbsolutePath != "/")
        {
            throw new ArgumentException(
                "NetworkId must be an HTTP or HTTPS origin with an explicit port.",
                nameof(signal));
        }

        return endpoint;
    }

    private static async Task<string> ReadAnswerAsync(
        HttpContent content,
        CancellationToken cancellationToken)
    {
        using var stream = await content
            .ReadAsStreamAsync(cancellationToken)
            .ConfigureAwait(false);
        using var output = new MemoryStream();
        var buffer = new byte[16 * 1024];

        while (output.Length <= MaximumSdpBodySize)
        {
            var remaining = MaximumSdpBodySize + 1 - checked((int)output.Length);
            var read = await stream
                .ReadAsync(
                    buffer.AsMemory(0, Math.Min(buffer.Length, remaining)),
                    cancellationToken)
                .ConfigureAwait(false);
            if (read == 0)
            {
                break;
            }

            await output
                .WriteAsync(buffer.AsMemory(0, read), cancellationToken)
                .ConfigureAwait(false);
        }

        if (output.Length > MaximumSdpBodySize)
        {
            throw new InvalidDataException("SDP answer exceeds 1 MiB.");
        }
        if (output.Length == 0)
        {
            throw new InvalidDataException("Missing SDP answer.");
        }

        return Encoding.UTF8.GetString(output.GetBuffer(), 0, checked((int)output.Length));
    }

    private static bool HasExplicitPort(Uri endpoint)
    {
        var original = endpoint.OriginalString.AsSpan();
        var authorityStart = original.IndexOf("://", StringComparison.Ordinal);
        if (authorityStart < 0)
        {
            return false;
        }

        original = original[(authorityStart + 3)..];
        var authorityEnd = original.IndexOfAny('/', '?', '#');
        var authority = authorityEnd < 0 ? original : original[..authorityEnd];
        var userInfoEnd = authority.LastIndexOf('@');
        if (userInfoEnd >= 0)
        {
            authority = authority[(userInfoEnd + 1)..];
        }

        return authority.StartsWith("[", StringComparison.Ordinal)
            ? authority.IndexOf("]:", StringComparison.Ordinal) >= 0
            : authority.LastIndexOf(':') > 0;
    }

    public void Dispose()
    {
        if (Interlocked.Exchange(ref _disposed, 1) != 0)
        {
            return;
        }

        _closed.Cancel();
        _notifiers.Clear();
        if (_ownsHttpClient)
        {
            _httpClient.Dispose();
        }
        _closed.Dispose();
    }
}
