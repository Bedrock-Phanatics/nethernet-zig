using System.Threading.Channels;
using SIPSorcery.Net;

namespace NetherNet;

public sealed class NetherNetConnection : Stream, IAsyncDisposable
{
    public const int MaximumSegmentPayload = 262143;
    public const int DefaultMaximumQueuedPacketsPerChannel = 256;
    public const int DefaultMaximumReconstructedMessageSize = 16 * 1024 * 1024;

    private readonly RTCPeerConnection _peer;
    private readonly DataChannelState[] _channels;
    private readonly CancellationTokenSource _closed = new();
    private readonly SemaphoreSlim _readLock = new(1, 1);
    private readonly int _maximumReconstructedMessageSize;
    private byte[]? _readRemainder;
    private int _readOffset;
    private int _closeSignaled;
    private int _disposed;
    private bool _ownsPublicKey;

    internal NetherNetConnection(
        RTCPeerConnection peer,
        ulong id,
        string networkId,
        string localNetworkId,
        int maximumQueuedPacketsPerChannel = DefaultMaximumQueuedPacketsPerChannel,
        int maximumReconstructedMessageSize = DefaultMaximumReconstructedMessageSize)
    {
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(maximumQueuedPacketsPerChannel);
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(maximumReconstructedMessageSize);
        _peer = peer;
        _channels = [new(maximumQueuedPacketsPerChannel), new(maximumQueuedPacketsPerChannel)];
        _maximumReconstructedMessageSize = maximumReconstructedMessageSize;
        ConnectionId = id;
        NetworkId = networkId;
        LocalNetworkId = localNetworkId;
        _peer.onconnectionstatechange += state =>
        {
            // "disconnected" is recoverable in WebRTC and must not permanently poison the connection.
            if (state is RTCPeerConnectionState.failed or RTCPeerConnectionState.closed)
            {
                SignalClosed(new IOException($"WebRTC entered {state}."));
            }
        };
    }

    public ulong ConnectionId { get; }
    public string NetworkId { get; }
    public string LocalNetworkId { get; }
    public ECDsa? PublicKey { get; private set; }
    public CancellationToken Closed => _closed.Token;
    public NetherNetAddress LocalAddress => new(LocalNetworkId, ConnectionId);
    public NetherNetAddress RemoteAddress => new(NetworkId, ConnectionId);
    public override bool CanRead => Volatile.Read(ref _disposed) == 0 && !_closed.IsCancellationRequested;
    public override bool CanSeek => false;
    public override bool CanWrite => Volatile.Read(ref _disposed) == 0 && !_closed.IsCancellationRequested;
    public override long Length => throw new NotSupportedException();
    public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }

    internal void SetPublicKey(ECDsa key, bool ownsKey)
    {
        ArgumentNullException.ThrowIfNull(key);
        if (PublicKey is not null)
        {
            throw new InvalidOperationException("The remote public key has already been assigned.");
        }

        PublicKey = key;
        _ownsPublicKey = ownsKey;
    }

    internal void Abort(Exception error)
    {
        ArgumentNullException.ThrowIfNull(error);
        SignalClosed(error);
    }

    internal void AttachChannel(RTCDataChannel channel)
    {
        ObjectDisposedException.ThrowIf(Volatile.Read(ref _disposed) != 0, this);
        var reliability = channel.label switch
        {
            "ReliableDataChannel" => MessageReliability.Reliable,
            // SIPSorcery currently decodes a zero-retransmit DCEP channel as an
            // unordered reliable channel. The vanilla label is therefore the
            // compatibility authority for the receiev side.
            "UnreliableDataChannel" => MessageReliability.Unreliable,
            _ => throw new InvalidDataException($"Invalid NetherNet data channel {channel.label}.")
        };
        var state = _channels[(int)reliability];
        lock (state.Sync)
        {
            if (state.DataChannel is not null)
            {
                throw new InvalidDataException($"Duplicate {channel.label}.");
            }

            state.DataChannel = channel;
        }
        channel.onmessage += (_, protocol, bytes) =>
        {
            if (protocol is DataChannelPayloadProtocols.WebRTC_Binary or DataChannelPayloadProtocols.WebRTC_Binary_Empty)
            {
                HandleFragment(state, reliability, bytes);
            }
        };
        channel.onclose += () => SignalClosed(new IOException($"{channel.label} closed."));
        channel.onerror += error => SignalClosed(new IOException($"{channel.label} failed: {error}."));
        channel.onopen += () => state.Open.TrySetResult();
        if (channel.IsOpened)
        {
            state.Open.TrySetResult();
        }
    }

    internal async Task WaitForChannelsAsync(CancellationToken cancellationToken)
    {
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, _closed.Token);
        await Task.WhenAll(_channels.Select(x => x.Open.Task)).WaitAsync(linked.Token).ConfigureAwait(false);
    }

    public async ValueTask<byte[]> ReceiveAsync(
        MessageReliability reliability = MessageReliability.Reliable,
        CancellationToken cancellationToken = default)
    {
        ValidateReliability(reliability);
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, _closed.Token);
        return await _channels[(int)reliability].Packets.Reader.ReadAsync(linked.Token).ConfigureAwait(false);
    }

    public async ValueTask<int> SendAsync(
        ReadOnlyMemory<byte> data,
        MessageReliability reliability = MessageReliability.Reliable,
        CancellationToken cancellationToken = default)
    {
        ValidateReliability(reliability);
        if (data.Length > _maximumReconstructedMessageSize)
        {
            throw new ArgumentOutOfRangeException(nameof(data), $"A NetherNet message cannot exceed {_maximumReconstructedMessageSize} bytes.");
        }

        if (reliability == MessageReliability.Unreliable && data.Length > MaximumSegmentPayload)
        {
            throw new ArgumentOutOfRangeException(nameof(data));
        }

        var count = data.IsEmpty ? 0 : (data.Length - 1) / MaximumSegmentPayload + 1;
        if (count > byte.MaxValue)
        {
            throw new ArgumentOutOfRangeException(nameof(data), "A NetherNet message cannot exceed 255 segments.");
        }

        using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, _closed.Token);
        var state = _channels[(int)reliability];
        await state.Open.Task.WaitAsync(linked.Token).ConfigureAwait(false);
        await state.WriteLock.WaitAsync(linked.Token).ConfigureAwait(false);
        try
        {
            linked.Token.ThrowIfCancellationRequested();
            var remaining = count - 1;
            for (var offset = 0; offset < data.Length; offset += MaximumSegmentPayload)
            {
                var length = Math.Min(MaximumSegmentPayload, data.Length - offset);
                var fragment = new byte[length + 1];
                fragment[0] = checked((byte)remaining--);
                data.Slice(offset, length).CopyTo(fragment.AsMemory(1));
                state.DataChannel!.send(fragment, 0, fragment.Length);
            }
            return data.Length;
        }
        finally { state.WriteLock.Release(); }
    }

    private void HandleFragment(DataChannelState state, MessageReliability reliability, byte[] fragment)
    {
        if (_closed.IsCancellationRequested)
        {
            return;
        }

        if (fragment.Length < 2)
        {
            SignalClosed(new InvalidDataException("A NetherNet fragment must contain a header and payload."));
            return;
        }
        var remaining = fragment[0];
        if (reliability == MessageReliability.Unreliable && remaining != 0)
        {
            SignalClosed(new InvalidDataException("Unreliable NetherNet messages cannot be fragmented."));
            return;
        }

        lock (state.Sync)
        {
            if (state.Remaining > 0 && state.Remaining - 1 != remaining)
            {
                SignalClosed(new InvalidDataException("NetherNet fragments arrived out of sequence."));
                return;
            }
            var payloadLength = fragment.Length - 1;
            if (state.Buffer.Length + payloadLength > _maximumReconstructedMessageSize)
            {
                SignalClosed(new InvalidDataException($"A reconstructed NetherNet message exceeds {_maximumReconstructedMessageSize} bytes."));
                return;
            }
            state.Remaining = remaining;
            state.Buffer.Write(fragment, 1, payloadLength);
            if (remaining != 0)
            {
                return;
            }

            var packet = state.Buffer.ToArray();
            state.Buffer.SetLength(0);
            if (!state.Packets.Writer.TryWrite(packet))
            {
                SignalClosed(new IOException("The incoming NetherNet packet queue is full."));
            }
        }
    }

    public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
    {
        if (buffer.IsEmpty)
        {
            return 0;
        }

        await _readLock.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (_readRemainder is null || _readOffset == _readRemainder.Length)
            {
                _readRemainder = await ReceiveAsync(cancellationToken: cancellationToken).ConfigureAwait(false);
                _readOffset = 0;
            }
            var count = Math.Min(buffer.Length, _readRemainder.Length - _readOffset);
            _readRemainder.AsMemory(_readOffset, count).CopyTo(buffer);
            _readOffset += count;
            if (_readOffset == _readRemainder.Length)
            {
                _readRemainder = null;
                _readOffset = 0;
            }
            return count;
        }
        finally { _readLock.Release(); }
    }

    public override int Read(byte[] buffer, int offset, int count)
        => ReadAsync(buffer.AsMemory(offset, count)).AsTask().GetAwaiter().GetResult();
    public override Task WriteAsync(byte[] buffer, int offset, int count, CancellationToken cancellationToken)
        => SendAsync(buffer.AsMemory(offset, count), cancellationToken: cancellationToken).AsTask();
    public override async ValueTask WriteAsync(
        ReadOnlyMemory<byte> buffer,
        CancellationToken cancellationToken = default)
    {
        _ = await SendAsync(
            buffer,
            cancellationToken: cancellationToken).ConfigureAwait(false);
    }
    public override void Write(byte[] buffer, int offset, int count)
        => SendAsync(buffer.AsMemory(offset, count)).AsTask().GetAwaiter().GetResult();
    public override void Flush()
    {
        // NOOP
    }
    public override Task FlushAsync(CancellationToken cancellationToken) => Task.CompletedTask;
    public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
    public override void SetLength(long value) => throw new NotSupportedException();

    private void SignalClosed(Exception error)
    {
        if (Interlocked.Exchange(ref _closeSignaled, 1) != 0)
        {
            return;
        }

        _closed.Cancel();
        foreach (var state in _channels)
        {
            state.Open.TrySetException(error);
            state.Packets.Writer.TryComplete(error);
        }
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing && Interlocked.Exchange(ref _disposed, 1) == 0)
        {
            SignalClosed(new ObjectDisposedException(nameof(NetherNetConnection)));
            _peer.close();
            _peer.Dispose();
            if (_ownsPublicKey)
            {
                PublicKey?.Dispose();
            }

            PublicKey = null;
        }
        base.Dispose(disposing);
    }

    public override async ValueTask DisposeAsync()
    {
        Dispose();
        GC.SuppressFinalize(this);
        await base.DisposeAsync().ConfigureAwait(false);
    }

    private static void ValidateReliability(MessageReliability reliability)
    {
        if (reliability is not (MessageReliability.Reliable or MessageReliability.Unreliable))
        {
            throw new ArgumentOutOfRangeException(nameof(reliability));
        }
    }

    private sealed class DataChannelState
    {
        internal DataChannelState(int maximumQueuedPackets)
        {
            Packets = Channel.CreateBounded<byte[]>(new BoundedChannelOptions(maximumQueuedPackets)
            {
                FullMode = BoundedChannelFullMode.Wait,
                SingleReader = false,
                SingleWriter = true
            });
        }

        internal readonly object Sync = new();
        internal readonly MemoryStream Buffer = new();
        internal readonly Channel<byte[]> Packets;
        internal readonly SemaphoreSlim WriteLock = new(1, 1);
        internal readonly TaskCompletionSource Open = new(TaskCreationOptions.RunContinuationsAsynchronously);
        internal RTCDataChannel? DataChannel;
        internal byte Remaining;
    }
}
