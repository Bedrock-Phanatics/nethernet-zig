using NetherNet.Internal;
using SIPSorcery.Net;

namespace NetherNet;

public sealed class Dialer
{
    private readonly DialerOptions _options;

    public Dialer(DialerOptions? options = null)
    {
        _options = options ?? new DialerOptions();
        ValidateOptions(options ?? _options);
    }

    public async Task<NetherNetConnection> DialAsync(
        string networkId,
        ISignaling signaling,
        CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(networkId);
        ArgumentNullException.ThrowIfNull(signaling);

        var connectionId = _options.ConnectionId == 0
            ? RandomId.Create()
            : _options.ConnectionId;
        var credentials = await signaling.GetCredentialsAsync(cancellationToken).ConfigureAwait(false);
        var peer = new RTCPeerConnection(WebRtcHelpers.CreateConfiguration(credentials));
        var connection = new NetherNetConnection(
            peer,
            connectionId,
            networkId,
            signaling.NetworkId,
            _options.MaximumQueuedPacketsPerChannel,
            _options.MaximumReconstructedMessageSize);
        var notifier = new DialNotifier(connectionId, networkId, peer, connection);
        using var subscription = signaling.Notify(notifier);

        try
        {
            await CreateDataChannelsAsync(peer, connection).ConfigureAwait(false);

            var disableTrickleIce = _options.DisableTrickleIce ||
                signaling is IDisablesTrickleIce { DisableTrickleIce: true };
            if (!disableTrickleIce)
            {
                peer.onicecandidate += candidate =>
                    _ = SignalCandidateAsync(signaling, connection, connectionId, networkId, candidate);
            }

            var offer = peer.createOffer(null);
            await peer.setLocalDescription(offer).ConfigureAwait(false);
            if (disableTrickleIce)
            {
                await WebRtcHelpers.WaitForGatheringAsync(peer, cancellationToken).ConfigureAwait(false);
            }

            var sdp = peer.localDescription.sdp.ToString();
            if (_options.Identity is not null)
            {
                sdp = WebRtcHelpers.AddIdentity(sdp, _options.Identity, peer.DtlsCertificateFingerprint);
            }

            await signaling.SignalAsync(new Signal
            {
                Type = SignalTypes.Offer,
                ConnectionId = connectionId,
                NetworkId = networkId,
                Data = sdp
            }, cancellationToken).ConfigureAwait(false);

            await notifier.Answer.WaitAsync(cancellationToken).ConfigureAwait(false);
            await notifier.Connected.WaitAsync(cancellationToken).ConfigureAwait(false);
            await connection.WaitForChannelsAsync(cancellationToken).ConfigureAwait(false);
            return connection;
        }
        catch
        {
            await connection.DisposeAsync().ConfigureAwait(false);
            throw;
        }
    }

    private static async Task CreateDataChannelsAsync(
        RTCPeerConnection peer,
        NetherNetConnection connection)
    {
        var reliable = await peer
            .createDataChannel("ReliableDataChannel", WebRtcHelpers.ReliableChannel)
            .ConfigureAwait(false);
        connection.AttachChannel(reliable);

        var unreliable = await peer
            .createDataChannel("UnreliableDataChannel", WebRtcHelpers.UnreliableChannel)
            .ConfigureAwait(false);
        connection.AttachChannel(unreliable);
    }

    private static async Task SignalCandidateAsync(
        ISignaling signaling,
        NetherNetConnection connection,
        ulong connectionId,
        string networkId,
        RTCIceCandidate candidate)
    {
        try
        {
            await signaling.SignalAsync(new Signal
            {
                Type = SignalTypes.Candidate,
                ConnectionId = connectionId,
                NetworkId = networkId,
                Data = candidate.ToString()
            }, connection.Closed).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (connection.Closed.IsCancellationRequested)
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

    private static void ValidateOptions(DialerOptions options)
    {
        if (options.MaximumQueuedPacketsPerChannel <= 0)
        {
            throw new ArgumentOutOfRangeException(
                nameof(options),
                options.MaximumQueuedPacketsPerChannel,
                "MaximumQueuedPacketsPerChannel must be greater than zero.");
        }
        if (options.MaximumReconstructedMessageSize <= 0)
        {
            throw new ArgumentOutOfRangeException(
                nameof(options),
                options.MaximumReconstructedMessageSize,
                "MaximumReconstructedMessageSize must be greater than zero.");
        }
    }

    private sealed class DialNotifier : INotifier
    {
        private readonly ulong _connectionId;
        private readonly string _networkId;
        private readonly RTCPeerConnection _peer;
        private readonly NetherNetConnection _connection;
        private readonly TaskCompletionSource _answer =
            new(TaskCreationOptions.RunContinuationsAsynchronously);
        private readonly TaskCompletionSource _connected =
            new(TaskCreationOptions.RunContinuationsAsynchronously);

        internal DialNotifier(
            ulong connectionId,
            string networkId,
            RTCPeerConnection peer,
            NetherNetConnection connection)
        {
            _connectionId = connectionId;
            _networkId = networkId;
            _peer = peer;
            _connection = connection;
            _peer.onconnectionstatechange += HandleConnectionState;
        }

        internal Task Answer => _answer.Task;
        internal Task Connected => _connected.Task;

        public bool NotifySignal(Signal signal)
        {
            if (signal.ConnectionId != _connectionId || signal.NetworkId != _networkId)
            {
                return false;
            }

            try
            {
                return signal.Type switch
                {
                    SignalTypes.Answer => HandleAnswer(signal),
                    SignalTypes.Candidate => HandleCandidate(signal),
                    SignalTypes.Error => HandleError(signal),
                    _ => false
                };
            }
            catch (Exception exception)
            {
                _answer.TrySetException(exception);
                _connected.TrySetException(exception);
                return true;
            }
        }

        private bool HandleAnswer(Signal signal)
        {
            var identity = WebRtcHelpers.ReadIdentity(signal.Data, verifyToken: true);
            if (identity is not null)
            {
                _connection.SetPublicKey(identity.Value.PublicKey, ownsKey: true);
            }

            var result = _peer.setRemoteDescription(new RTCSessionDescriptionInit
            {
                type = RTCSdpType.answer,
                sdp = signal.Data
            });
            if (result != SetDescriptionResultEnum.OK)
            {
                throw new InvalidDataException($"Could not set remote answer: {result}.");
            }

            _answer.TrySetResult();
            return true;
        }

        private bool HandleCandidate(Signal signal)
        {
            _peer.addIceCandidate(new RTCIceCandidateInit
            {
                candidate = signal.Data,
                sdpMid = "0",
                sdpMLineIndex = 0
            });
            return true;
        }

        private bool HandleError(Signal signal)
        {
            var exception = new IOException($"Remote peer reported NetherNet error {signal.Data}.");
            _answer.TrySetException(exception);
            _connected.TrySetException(exception);
            return true;
        }

        private void HandleConnectionState(RTCPeerConnectionState state)
        {
            if (state == RTCPeerConnectionState.connected)
            {
                _connected.TrySetResult();
            }
            else if (state is RTCPeerConnectionState.failed or RTCPeerConnectionState.closed)
            {
                _connected.TrySetException(new IOException($"WebRTC entered {state}."));
            }
        }
    }
}
