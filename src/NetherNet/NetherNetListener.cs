using System.Collections.Concurrent;
using System.Globalization;
using System.Threading.Channels;
using NetherNet.Internal;
using SIPSorcery.Net;

namespace NetherNet;

public sealed class NetherNetListener : INotifier, IAsyncDisposable, IDisposable
{
    private readonly ListenerOptions _options;
    private readonly ISignaling _signaling;
    private readonly IDisposable _subscription;
    private readonly CancellationTokenSource _closed = new();
    private readonly Channel<NetherNetConnection> _accepted;
    private readonly ConcurrentDictionary<(string NetworkId, ulong ConnectionId), PendingConnection> _connections = new();
    private readonly ConcurrentDictionary<long, Task> _negotiations = new();
    private readonly SemaphoreSlim _negotiationSlots;
    private readonly object _admissionLock = new();
    private readonly Identity _defaultIdentity;
    private long _negotiationId;
    private int _disposed;

    private NetherNetListener(ISignaling signaling, ListenerOptions options)
    {
        ValidateOptions(options);
        _signaling = signaling;
        _options = options;
        _accepted = Channel.CreateBounded<NetherNetConnection>(new BoundedChannelOptions(options.MaximumPendingAccepts)
        {
            FullMode = BoundedChannelFullMode.Wait,
            SingleReader = false,
            SingleWriter = false
        });
        _negotiationSlots = new SemaphoreSlim(options.MaximumConcurrentNegotiations, options.MaximumConcurrentNegotiations);
        _defaultIdentity = Identity.GenerateServer(ECDsa.Create(ECCurve.NamedCurves.nistP384), "self");
        _subscription = signaling.Notify(this);
    }

    public static NetherNetListener Listen(ISignaling signaling, ListenerOptions? options = null)
        => new(signaling ?? throw new ArgumentNullException(nameof(signaling)), options ?? new ListenerOptions());

    public string NetworkId => _signaling.NetworkId;
    public CancellationToken Closed => _closed.Token;
    public void SetPongData(ReadOnlySpan<byte> data) => _signaling.SetPongData(data);

    public async ValueTask<NetherNetConnection> AcceptAsync(CancellationToken cancellationToken = default)
    {
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, _closed.Token);
        return await _accepted.Reader.ReadAsync(linked.Token).ConfigureAwait(false);
    }

    public bool NotifySignal(Signal signal)
    {
        ArgumentNullException.ThrowIfNull(signal);
        if (Volatile.Read(ref _disposed) != 0 || _closed.IsCancellationRequested)
        {
            return false;
        }
        if (signal.Type != SignalTypes.Offer)
        {
            return _connections.TryGetValue((signal.NetworkId, signal.ConnectionId), out var pending) && pending.Notifier.NotifySignal(signal);
        }

        lock (_admissionLock)
        {
            if (Volatile.Read(ref _disposed) != 0 || _closed.IsCancellationRequested)
            {
                return false;
            }
            if (!_negotiationSlots.Wait(0))
            {
                return false;
            }

            var id = Interlocked.Increment(ref _negotiationId);
            var task = ObserveNegotiationAsync(HandleOfferAsync(signal));
            _negotiations[id] = task;
            _ = RemoveNegotiationWhenCompleteAsync(id, task);
            return true;
        }
    }

    private async Task ObserveNegotiationAsync(Task task)
    {
        try
        {
            await task.ConfigureAwait(false);
        }
        catch (Exception exception)
        {
            NetherNetDiagnostics.Report(exception);
        }
        finally
        {
            _negotiationSlots.Release();
        }
    }

    private async Task RemoveNegotiationWhenCompleteAsync(long id, Task task)
    {
        await task.ConfigureAwait(false);
        _negotiations.TryRemove(id, out _);
    }

    private async Task HandleOfferAsync(Signal signal)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(_closed.Token);
        timeout.CancelAfter(_options.NegotiationTimeout);
        NetherNetConnection? connection = null;
        RTCPeerConnection? peer = null;
        Action<RTCIceCandidate>? candidateHandler = null;
        try
        {
            var credentials = await _signaling.GetCredentialsAsync(timeout.Token).ConfigureAwait(false);
            peer = new RTCPeerConnection(WebRtcHelpers.CreateConfiguration(credentials));
            connection = new NetherNetConnection(
                peer,
                signal.ConnectionId,
                signal.NetworkId,
                NetworkId,
                _options.MaximumQueuedPacketsPerChannel,
                _options.MaximumReconstructedMessageSize);
            var notifier = new ListenerConnectionNotifier(signal.ConnectionId, signal.NetworkId, peer, connection);
            if (!_connections.TryAdd(
                (signal.NetworkId, signal.ConnectionId),
                new PendingConnection(connection, notifier)))
            {
                throw new InvalidOperationException("Connection already exists.");
            }

            peer.ondatachannel += connection.AttachChannel;
            var remoteIdentity = WebRtcHelpers.ReadIdentity(signal.Data, false);
            if (remoteIdentity is null && !_options.AllowAnonymous)
            {
                throw new CryptographicException("Anonymous NetherNet identities are not allowed.");
            }
            if (remoteIdentity is not null)
            {
                await ApplyRemoteIdentityAsync(connection, remoteIdentity.Value, signal.Data, timeout.Token).ConfigureAwait(false);
            }

            var set = peer.setRemoteDescription(new RTCSessionDescriptionInit { type = RTCSdpType.offer, sdp = signal.Data });
            if (set != SetDescriptionResultEnum.OK)
            {
                throw new InvalidDataException($"Could not set remote offer: {set}.");
            }

            var disableTrickle = _options.DisableTrickleIce || _signaling is IDisablesTrickleIce { DisableTrickleIce: true };
            if (!disableTrickle)
            {
                candidateHandler = candidate =>
                    _ = SignalCandidateAsync(signal, candidate, connection);
                peer.onicecandidate += candidateHandler;
            }

            await peer.setLocalDescription(peer.createAnswer(null)).ConfigureAwait(false);
            if (disableTrickle)
            {
                await WebRtcHelpers.WaitForGatheringAsync(peer, timeout.Token).ConfigureAwait(false);
            }

            var identity = _options.IssueServerIdentity is null
                ? _defaultIdentity
                : await _options.IssueServerIdentity(timeout.Token).ConfigureAwait(false);
            var sdp = WebRtcHelpers.AddIdentity(peer.localDescription.sdp.ToString(), identity, peer.DtlsCertificateFingerprint);
            await _signaling.SignalAsync(new Signal
            {
                Type = SignalTypes.Answer,
                ConnectionId = signal.ConnectionId,
                NetworkId = signal.NetworkId,
                Data = sdp
            }, timeout.Token).ConfigureAwait(false);

            using var connectionTimeout = CancellationTokenSource.CreateLinkedTokenSource(_closed.Token);
            connectionTimeout.CancelAfter(_options.ConnectionTimeout);
            await notifier.Connected.Task.WaitAsync(connectionTimeout.Token).ConfigureAwait(false);
            await connection.WaitForChannelsAsync(connectionTimeout.Token).ConfigureAwait(false);
            if (!_accepted.Writer.TryWrite(connection))
            {
                throw new IOException("The pending accept queue is full.");
            }
            connection = null;
        }
        catch (Exception ex)
        {
            NetherNetDiagnostics.Report(ex);
            if (!_closed.IsCancellationRequested)
            {
                try
                {
                    await _signaling.SignalAsync(new Signal
                    {
                        Type = SignalTypes.Error,
                        ConnectionId = signal.ConnectionId,
                        NetworkId = signal.NetworkId,
                        Data = MapError(ex).ToString(
                            CultureInfo.InvariantCulture)
                    }, _closed.Token).ConfigureAwait(false);
                }
                catch (OperationCanceledException) when (_closed.IsCancellationRequested)
                {
                    // NOOP
                }
                catch (Exception signalingException)
                {
                    NetherNetDiagnostics.Report(signalingException);
                }
            }
        }
        finally
        {
            if (peer is not null && candidateHandler is not null)
            {
                peer.onicecandidate -= candidateHandler;
            }
            if (connection is not null)
            {
                await connection.DisposeAsync().ConfigureAwait(false);
            }
            _connections.TryRemove((signal.NetworkId, signal.ConnectionId), out _);
        }
    }

    private async Task ApplyRemoteIdentityAsync(
        NetherNetConnection connection,
        (IdentityData Data, ECDsa PublicKey) remoteIdentity,
        string sdp,
        CancellationToken cancellationToken)
    {
        var parsedKey = remoteIdentity.PublicKey;
        try
        {
            var verifiedKey = _options.VerifyClientToken is null
                ? null
                : await _options.VerifyClientToken(remoteIdentity.Data.Assertion.Token, cancellationToken).ConfigureAwait(false);
            if (verifiedKey is null)
            {
                remoteIdentity.Data.Verify(WebRtcHelpers.ReadFingerprints(sdp), parsedKey);
                connection.SetPublicKey(parsedKey, ownsKey: true);
                parsedKey = null!;
            }
            else
            {
                remoteIdentity.Data.Verify(WebRtcHelpers.ReadFingerprints(sdp), verifiedKey);
                connection.SetPublicKey(verifiedKey, ownsKey: false);
            }
        }
        finally
        {
            parsedKey?.Dispose();
        }
    }

    private async Task SignalCandidateAsync(
        Signal source,
        RTCIceCandidate candidate,
        NetherNetConnection connection)
    {
        try
        {
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(_closed.Token);
            timeout.CancelAfter(_options.NegotiationTimeout);
            await _signaling.SignalAsync(new Signal
            {
                Type = SignalTypes.Candidate,
                ConnectionId = source.ConnectionId,
                NetworkId = source.NetworkId,
                Data = candidate.ToString()
            }, timeout.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (_closed.IsCancellationRequested)
        {
            // NOOP
        }
        catch (Exception exception)
        {
            var error = new IOException("Failed to signal a local ICE candidate.", exception);
            NetherNetDiagnostics.Report(error);
            connection.Abort(error);
        }
    }

    private static int MapError(Exception exception) => exception switch
    {
        CryptographicException => ErrorCodes.IdentityNotAllowed,
        OperationCanceledException => ErrorCodes.NegotiationTimeoutWaitingForAccept,
        InvalidDataException => ErrorCodes.FailedToSetRemoteDescription,
        _ => ErrorCodes.GenericFailure
    };

    private static void ValidateOptions(ListenerOptions options)
    {
        ValidatePositive(
            options.MaximumConcurrentNegotiations,
            nameof(options),
            "MaximumConcurrentNegotiations");
        ValidatePositive(
            options.MaximumPendingAccepts,
            nameof(options),
            "MaximumPendingAccepts");
        ValidatePositive(
            options.MaximumQueuedPacketsPerChannel,
            nameof(options),
            "MaximumQueuedPacketsPerChannel");
        ValidatePositive(
            options.MaximumReconstructedMessageSize,
            nameof(options),
            "MaximumReconstructedMessageSize");
        if (options.NegotiationTimeout <= TimeSpan.Zero)
        {
            throw new ArgumentOutOfRangeException(
                nameof(options),
                options.NegotiationTimeout,
                "NegotiationTimeout must be greater than zero.");
        }
        if (options.ConnectionTimeout <= TimeSpan.Zero)
        {
            throw new ArgumentOutOfRangeException(
                nameof(options),
                options.ConnectionTimeout,
                "ConnectionTimeout must be greater than zero.");
        }
    }

    private static void ValidatePositive(int value, string parameterName, string optionName)
    {
        if (value <= 0)
        {
            throw new ArgumentOutOfRangeException(
                parameterName,
                value,
                $"{optionName} must be greater than zero.");
        }
    }

    public void Dispose() => DisposeAsync().AsTask().GetAwaiter().GetResult();

    public async ValueTask DisposeAsync()
    {
        if (Interlocked.Exchange(ref _disposed, 1) != 0)
        {
            return;
        }

        _subscription.Dispose();
        await _closed.CancelAsync().ConfigureAwait(false);
        _accepted.Writer.TryComplete();
        foreach (var pending in _connections.Values)
        {
            pending.Connection.Dispose();
        }

        var negotiations = _negotiations.Values.ToArray();
        if (negotiations.Length != 0)
        {
            await Task.WhenAll(negotiations).ConfigureAwait(false);
        }
        while (_accepted.Reader.TryRead(out var connection))
        {
            connection.Dispose();
        }
        _connections.Clear();
        _defaultIdentity.PrivateKey.Dispose();
        _negotiationSlots.Dispose();
        _closed.Dispose();
    }

    private sealed record PendingConnection(NetherNetConnection Connection, ListenerConnectionNotifier Notifier);

    private sealed class ListenerConnectionNotifier(
        ulong id,
        string networkId,
        RTCPeerConnection peer,
        NetherNetConnection connection) : INotifier
    {
        internal readonly TaskCompletionSource Connected = CreateConnected(peer);

        private static TaskCompletionSource CreateConnected(RTCPeerConnection peer)
        {
            var completion = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            peer.onconnectionstatechange += state =>
            {
                switch (state)
                {
                    case RTCPeerConnectionState.connected:
                        completion.TrySetResult();
                        break;
                    case RTCPeerConnectionState.failed:
                    case RTCPeerConnectionState.closed:
                        completion.TrySetException(
                            new IOException($"WebRTC entered {state}."));
                        break;
                }
            };
            return completion;
        }

        public bool NotifySignal(Signal signal)
        {
            if (signal.ConnectionId != id || signal.NetworkId != networkId)
            {
                return false;
            }

            switch (signal.Type)
            {
                case SignalTypes.Candidate:
                    peer.addIceCandidate(new RTCIceCandidateInit
                    {
                        candidate = signal.Data,
                        sdpMid = "0",
                        sdpMLineIndex = 0
                    });
                    return true;
                case SignalTypes.Error:
                    connection.Dispose();
                    return true;
                default:
                    return false;
            }
        }
    }
}
