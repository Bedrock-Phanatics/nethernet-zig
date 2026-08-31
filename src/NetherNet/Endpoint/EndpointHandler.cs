using System.Collections.Concurrent;
using System.Globalization;
using System.Text;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Routing;
using NetherNet.Internal;

namespace NetherNet.Endpoint;

public sealed class EndpointHandler : ISignaling, IDisablesTrickleIce, IDisposable
{
    private readonly EndpointHandlerOptions _options;
    private readonly ConcurrentDictionary<ConnectionKey, TaskCompletionSource<Signal>> _pending = new();
    private readonly CancellationTokenSource _closed = new();
    private readonly SemaphoreSlim _offerSlots;
    private readonly object _notifierLock = new();
    private INotifier? _notifier;
    private long _notifierVersion;
    private int _disposed;

    public EndpointHandler(EndpointHandlerOptions? options = null)
    {
        _options = options ?? new EndpointHandlerOptions();
        ValidateOptions(_options);
        _offerSlots = new SemaphoreSlim(
            _options.MaximumPendingOffers,
            _options.MaximumPendingOffers);
        NetworkId = _options.NetworkId ??
            RandomId.Create().ToString(CultureInfo.InvariantCulture);
    }

    public bool DisableTrickleIce => true;
    public CancellationToken Closed => _closed.Token;
    public string NetworkId { get; }

    public void MapEndpoints(IEndpointRouteBuilder endpoints)
    {
        ArgumentNullException.ThrowIfNull(endpoints);
        endpoints.MapGet("/v1/join", static () => Results.Ok());
        endpoints.MapPost("/v1/join/{networkId}", HandleOfferAsync);
    }

    public IDisposable Notify(INotifier notifier)
    {
        ArgumentNullException.ThrowIfNull(notifier);
        ObjectDisposedException.ThrowIf(Volatile.Read(ref _disposed) != 0, this);

        long version;
        lock (_notifierLock)
        {
            if (_notifier is not null)
            {
                throw new InvalidOperationException(
                    "Only one listener can use an endpoint handler.");
            }

            _notifier = notifier;
            version = ++_notifierVersion;
        }

        return new Subscription(() => RemoveNotifier(version));
    }

    public ValueTask<Credentials?> GetCredentialsAsync(
        CancellationToken cancellationToken = default)
    {
        ObjectDisposedException.ThrowIf(Volatile.Read(ref _disposed) != 0, this);
        return _options.CredentialsProvider?.Invoke(cancellationToken) ??
            ValueTask.FromResult<Credentials?>(new Credentials());
    }

    public void SetPongData(ReadOnlySpan<byte> data)
    {
        // NOOP
    }

    public ValueTask SignalAsync(
        Signal signal,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(signal);
        ObjectDisposedException.ThrowIf(Volatile.Read(ref _disposed) != 0, this);

        switch (signal.Type)
        {
            case SignalTypes.Candidate:
                throw new NotSupportedException(
                    "HTTP endpoint signaling does not support trickle ICE.");
            case SignalTypes.Answer:
            case SignalTypes.Error:
                break;
            default:
                throw new ArgumentException(
                    $"Unexpected signal type {signal.Type}.",
                    nameof(signal));
        }

        var key = new ConnectionKey(signal.NetworkId, signal.ConnectionId);
        if (!_pending.TryGetValue(key, out var pending))
        {
            throw new InvalidOperationException($"Unexpected connection ID: {key}.");
        }

        cancellationToken.ThrowIfCancellationRequested();
        if (!pending.TrySetResult(signal))
        {
            throw new InvalidOperationException("Negotiation already completed.");
        }

        return ValueTask.CompletedTask;
    }

    private void RemoveNotifier(long version)
    {
        lock (_notifierLock)
        {
            if (_notifierVersion == version)
            {
                _notifier = null;
            }
        }
    }

    private async Task<IResult> HandleOfferAsync(HttpRequest request, string networkId)
    {
        if (!_offerSlots.Wait(0))
        {
            return Results.StatusCode(StatusCodes.Status503ServiceUnavailable);
        }

        try
        {
            return await HandleAdmittedOfferAsync(request, networkId).ConfigureAwait(false);
        }
        finally
        {
            _offerSlots.Release();
        }
    }

    private async Task<IResult> HandleAdmittedOfferAsync(
        HttpRequest request,
        string networkId)
    {
        if (!ulong.TryParse(
            networkId,
            NumberStyles.None,
            CultureInfo.InvariantCulture,
            out _))
        {
            return Results.BadRequest("Network ID must be uint64");
        }
        if (request.ContentLength > EndpointClient.MaximumSdpBodySize)
        {
            return Results.StatusCode(StatusCodes.Status413PayloadTooLarge);
        }

        var body = await ReadBodyAsync(
            request.Body,
            request.HttpContext.RequestAborted).ConfigureAwait(false);
        if (body is null)
        {
            return Results.StatusCode(StatusCodes.Status413PayloadTooLarge);
        }
        if (body.Length == 0)
        {
            return Results.BadRequest("Missing SDP offer in request body");
        }

        INotifier? notifier;
        lock (_notifierLock)
        {
            notifier = _notifier;
        }
        if (notifier is null)
        {
            return Results.StatusCode(StatusCodes.Status503ServiceUnavailable);
        }

        var signal = new Signal
        {
            Type = SignalTypes.Offer,
            ConnectionId = RandomId.Create(),
            Data = Encoding.UTF8.GetString(body),
            NetworkId = networkId
        };
        var key = new ConnectionKey(networkId, signal.ConnectionId);
        var completion = new TaskCompletionSource<Signal>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        if (!_pending.TryAdd(key, completion))
        {
            return Results.StatusCode(StatusCodes.Status409Conflict);
        }

        try
        {
            if (!notifier.NotifySignal(signal))
            {
                return Results.StatusCode(StatusCodes.Status503ServiceUnavailable);
            }

            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(
                request.HttpContext.RequestAborted,
                _closed.Token);
            timeout.CancelAfter(_options.NegotiationTimeout);
            var result = await completion.Task
                .WaitAsync(timeout.Token)
                .ConfigureAwait(false);

            return result.Type switch
            {
                SignalTypes.Answer => Results.Text(result.Data, "application/sdp"),
                SignalTypes.Error => Results.BadRequest(
                    $"Negotiation failed with error code: {result.Data}"),
                _ => Results.StatusCode(StatusCodes.Status500InternalServerError)
            };
        }
        catch (OperationCanceledException)
            when (!request.HttpContext.RequestAborted.IsCancellationRequested)
        {
            _ = notifier.NotifySignal(new Signal
            {
                Type = SignalTypes.Error,
                ConnectionId = signal.ConnectionId,
                Data = ErrorCodes.NegotiationTimeoutWaitingForResponse.ToString(
                    CultureInfo.InvariantCulture),
                NetworkId = networkId
            });
            return Results.StatusCode(StatusCodes.Status502BadGateway);
        }
        finally
        {
            _pending.TryRemove(key, out _);
        }
    }

    internal static async Task<byte[]?> ReadBodyAsync(
        Stream body,
        CancellationToken cancellationToken)
    {
        using var output = new MemoryStream();
        var buffer = new byte[16 * 1024];

        while (output.Length <= EndpointClient.MaximumSdpBodySize)
        {
            var remaining = EndpointClient.MaximumSdpBodySize + 1 -
                checked((int)output.Length);
            var read = await body
                .ReadAsync(
                    buffer.AsMemory(0, Math.Min(buffer.Length, remaining)),
                    cancellationToken)
                .ConfigureAwait(false);
            if (read == 0)
            {
                return output.ToArray();
            }

            await output
                .WriteAsync(buffer.AsMemory(0, read), cancellationToken)
                .ConfigureAwait(false);
        }

        return null;
    }

    private static void ValidateOptions(EndpointHandlerOptions options)
    {
        if (options.MaximumPendingOffers <= 0)
        {
            throw new ArgumentOutOfRangeException(
                nameof(options),
                options.MaximumPendingOffers,
                "MaximumPendingOffers must be greater than zero.");
        }
        if (options.NegotiationTimeout <= TimeSpan.Zero)
        {
            throw new ArgumentOutOfRangeException(
                nameof(options),
                options.NegotiationTimeout,
                "NegotiationTimeout must be greater than zero.");
        }
    }

    public void Dispose()
    {
        if (Interlocked.Exchange(ref _disposed, 1) != 0)
        {
            return;
        }

        _closed.Cancel();
        foreach (var pending in _pending.Values)
        {
            pending.TrySetCanceled(_closed.Token);
        }
        _pending.Clear();

        lock (_notifierLock)
        {
            _notifier = null;
        }
    }

    private readonly record struct ConnectionKey(string NetworkId, ulong ConnectionId);
}
