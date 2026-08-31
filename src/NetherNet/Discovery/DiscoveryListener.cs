using System.Collections.Concurrent;
using System.Globalization;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using NetherNet.Internal;

namespace NetherNet.Discovery;

public sealed class DiscoveryListener : ISignaling, IAsyncDisposable, IDisposable
{
    public const int DefaultPort = 7551;
    private readonly UdpClient _udp;
    private readonly ulong _networkId;
    private readonly IPEndPoint? _broadcastEndpoint;
    private readonly CancellationTokenSource _closed = new();
    private readonly ConcurrentDictionary<ulong, KnownAddress> _addresses = new();
    private readonly ConcurrentDictionary<ulong, KnownResponse> _responses = new();
    private readonly ConcurrentDictionary<long, INotifier> _notifiers = new();
    private readonly Task _receiveTask;
    private readonly Task _backgroundTask;
    private readonly int _maximumDiscoveredServers;
    private byte[]? _pongData;
    private long _notifierId;
    private int _disposed;

    private DiscoveryListener(UdpClient udp, DiscoveryOptions options)
    {
        _udp = udp;
        _networkId = options.NetworkId == 0 ? RandomId.Create() : options.NetworkId;
        _broadcastEndpoint = options.BroadcastEndpoint ??
            (((IPEndPoint)udp.Client.LocalEndPoint!).Port == DefaultPort ? null : new IPEndPoint(IPAddress.Broadcast, DefaultPort));
        if (options.MaximumDiscoveredServers <= 0)
        {
            throw new ArgumentOutOfRangeException(
                nameof(options),
                options.MaximumDiscoveredServers,
                "MaximumDiscoveredServers must be greater than zero.");
        }
        _maximumDiscoveredServers = options.MaximumDiscoveredServers;
        _udp.EnableBroadcast = true;
        _receiveTask = ReceiveLoopAsync();
        _backgroundTask = BackgroundLoopAsync();
    }

    public static DiscoveryListener Listen(IPEndPoint? endpoint = null, DiscoveryOptions? options = null)
    {
        endpoint ??= new IPEndPoint(IPAddress.Any, 0);
        options ??= new DiscoveryOptions();
        var udp = new UdpClient(endpoint);
        return new DiscoveryListener(udp, options);
    }

    public string NetworkId => _networkId.ToString(CultureInfo.InvariantCulture);
    public CancellationToken Closed => _closed.Token;
    public IReadOnlyDictionary<ulong, byte[]> Responses => _responses.ToDictionary(pair => pair.Key, pair => pair.Value.Data.ToArray());

    public IDisposable Notify(INotifier notifier)
    {
        ArgumentNullException.ThrowIfNull(notifier);
        var id = Interlocked.Increment(ref _notifierId);
        _notifiers[id] = notifier;
        return new Subscription(() => _notifiers.TryRemove(id, out _));
    }

    public ValueTask<Credentials?> GetCredentialsAsync(CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        _closed.Token.ThrowIfCancellationRequested();
        return ValueTask.FromResult<Credentials?>(null);
    }

    public async ValueTask SignalAsync(Signal signal, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(signal);
        ObjectDisposedException.ThrowIf(Volatile.Read(ref _disposed) != 0, this);
        if (!ulong.TryParse(
            signal.NetworkId,
            NumberStyles.None,
            CultureInfo.InvariantCulture,
            out var networkId))
        {
            throw new ArgumentException("The network ID must be a UInt64.", nameof(signal));
        }
        if (!_addresses.TryGetValue(networkId, out var address))
        {
            throw new InvalidOperationException($"No address found for network ID {networkId}.");
        }

        await WriteAsync(
            new MessagePacket
            {
                RecipientId = networkId,
                Data = signal.ToString()
            },
            address.Endpoint,
            cancellationToken).ConfigureAwait(false);
    }

    public void SetServerData(ServerData data)
    {
        ArgumentNullException.ThrowIfNull(data);
        Interlocked.Exchange(ref _pongData, data.Marshal());
    }

    public void SetPongData(ReadOnlySpan<byte> data)
    {
        var parts = Encoding.UTF8.GetString(data).Split(';');
        if (parts.Length < 9)
        {
            throw new FormatException(
                "RakNet pong data must contain at least nine fields.");
        }
        _ = int.TryParse(parts[4], CultureInfo.InvariantCulture, out var players);
        _ = int.TryParse(parts[5], CultureInfo.InvariantCulture, out var maximum);
        var gameType = parts[8].Trim().ToUpperInvariant() switch
        {
            "CREATIVE" => GameType.Creative,
            "ADVENTURE" => GameType.Adventure,
            _ => GameType.Survival
        };
        SetServerData(new ServerData
        {
            ServerName = parts[1],
            LevelName = parts[7],
            GameType = gameType,
            PlayerCount = players,
            MaxPlayerCount = maximum,
            AcceptsOnlineAuth = true,
            AcceptsSelfSignedAuth = true,
            TransportLayer = TransportLayer.NetherNet,
            ConnectionType = 4
        });
    }

    private async Task ReceiveLoopAsync()
    {
        try
        {
            while (!_closed.IsCancellationRequested)
            {
                var result = await _udp.ReceiveAsync(_closed.Token).ConfigureAwait(false);
                try
                {
                    await HandlePacketAsync(result.Buffer, result.RemoteEndPoint)
                        .ConfigureAwait(false);
                }
                catch (Exception exception)
                    when (!_closed.IsCancellationRequested && IsMalformedDatagram(exception))
                {
                    NetherNetDiagnostics.ReportMalformedDatagram(exception);
                }
            }
        }
        catch (OperationCanceledException) when (_closed.IsCancellationRequested)
        {
            return;
        }
        catch (ObjectDisposedException) when (_closed.IsCancellationRequested)
        {
            return;
        }
        finally
        {
            await _closed.CancelAsync().ConfigureAwait(false);
        }
    }

    private async Task HandlePacketAsync(byte[] bytes, IPEndPoint endpoint)
    {
        var (packet, senderId) = PacketCodec.Unmarshal(bytes);
        if (senderId == _networkId)
        {
            return;
        }
        if (!_addresses.ContainsKey(senderId) &&
            _addresses.Count >= _maximumDiscoveredServers)
        {
            return;
        }

        _addresses[senderId] = new KnownAddress(endpoint, DateTimeOffset.UtcNow);
        switch (packet)
        {
            case RequestPacket:
                var pong = Volatile.Read(ref _pongData);
                if (pong is not null)
                {
                    await WriteAsync(new ResponsePacket { ApplicationData = pong }, endpoint, _closed.Token).ConfigureAwait(false);
                }
                break;
            case ResponsePacket response:
                _responses[senderId] = new KnownResponse(response.ApplicationData);
                break;
            case MessagePacket message when message.RecipientId == _networkId && message.Data is not ("" or "Ping"):
                var signal = Signal.Parse(message.Data) with { NetworkId = senderId.ToString(CultureInfo.InvariantCulture) };
                foreach (var notifier in _notifiers.Values)
                {
                    _ = notifier.NotifySignal(signal);
                }
                break;
        }
    }

    private async Task BackgroundLoopAsync()
    {
        using var timer = new PeriodicTimer(TimeSpan.FromSeconds(2));
        try
        {
            while (await timer.WaitForNextTickAsync(_closed.Token).ConfigureAwait(false))
            {
                var cutoff = DateTimeOffset.UtcNow - TimeSpan.FromSeconds(15);
                foreach (var pair in _addresses)
                {
                    if (pair.Value.LastSeen < cutoff)
                    {
                        _addresses.TryRemove(pair.Key, out _);
                        _responses.TryRemove(pair.Key, out _);
                    }
                }
                if (_broadcastEndpoint is not null)
                {
                    await WriteAsync(new RequestPacket(), _broadcastEndpoint, _closed.Token).ConfigureAwait(false);
                }
            }
        }
        catch (OperationCanceledException) when (_closed.IsCancellationRequested)
        {
            return;
        }
    }

    private async ValueTask WriteAsync(IPacket packet, IPEndPoint endpoint, CancellationToken cancellationToken)
    {
        var bytes = PacketCodec.Marshal(packet, _networkId);
        await _udp.SendAsync(bytes, endpoint, cancellationToken).ConfigureAwait(false);
    }

    private static bool IsMalformedDatagram(Exception exception) => exception is
        InvalidDataException or
        IOException or
        CryptographicException or
        FormatException or
        ArgumentException or
        OverflowException or
        JsonException or
        DecoderFallbackException;

    public void Dispose() => DisposeAsync().AsTask().GetAwaiter().GetResult();

    public async ValueTask DisposeAsync()
    {
        if (Interlocked.Exchange(ref _disposed, 1) != 0)
        {
            return;
        }

        await _closed.CancelAsync().ConfigureAwait(false);
        _udp.Dispose();
        await Task.WhenAll(_receiveTask, _backgroundTask).ConfigureAwait(false);
        _notifiers.Clear();
        _closed.Dispose();
    }

    private sealed record KnownAddress(IPEndPoint Endpoint, DateTimeOffset LastSeen);
    private sealed record KnownResponse(byte[] Data);
}
